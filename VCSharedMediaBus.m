#import "VCSharedMediaBus.h"
#import "VCSharedMediaProtocol.h"

#import <IOSurface/IOSurface.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <os/lock.h>
#import <stdatomic.h>

static const char *VCVideoSurfaceNotification =
    "com.murkaska.virtualcampro/media.video.surface.v1";
static const char *VCVideoTimestampNotification =
    "com.murkaska.virtualcampro/media.video.timestamp.v1";
static const char *VCAudioSurfaceNotification =
    "com.murkaska.virtualcampro/media.audio.surface.v1";
static const char *VCAudioTimestampNotification =
    "com.murkaska.virtualcampro/media.audio.timestamp.v1";
static const char *VCVideoPipelineHeartbeat =
    "com.murkaska.virtualcampro/pipeline.video.heartbeat.v1";
static const char *VCAudioPipelineHeartbeat =
    "com.murkaska.virtualcampro/pipeline.audio.heartbeat.v1";

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t reserved;
    _Atomic(uint64_t) totalFramesWritten;
    _Atomic(uint64_t) sequence;
    float samples[];
} VCSharedAudioRing;

static uint64_t VCMonotonicMilliseconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mach_timebase_info(&timebase); });
    uint64_t ticks = mach_continuous_time();
    long double nanos = ((long double)ticks * timebase.numer) / timebase.denom;
    return (uint64_t)(nanos / 1000000.0L);
}

static BOOL VCNotifyWriteState(const char *name, uint64_t state) {
    int token = -1;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return NO;
    uint32_t result = notify_set_state(token, state);
    notify_post(name);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK;
}

static BOOL VCNotifyReadState(const char *name, uint64_t *state) {
    if (!state) return NO;
    int token = -1;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return NO;
    uint32_t result = notify_get_state(token, state);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK;
}

static BOOL VCStateIsRecent(const char *timestampName, NSTimeInterval maximumAge) {
    uint64_t timestamp = 0;
    if (!VCNotifyReadState(timestampName, &timestamp) || timestamp == 0) return NO;
    uint64_t now = VCMonotonicMilliseconds();
    if (now < timestamp) return NO;
    uint64_t maximumAgeMilliseconds = (uint64_t)(MAX(0.05, maximumAge) * 1000.0);
    return now - timestamp <= maximumAgeMilliseconds;
}

@interface VCSharedVideoServer () {
    os_unfair_lock _lock;
    CVPixelBufferRef _surfaceRing[VC_SHARED_VIDEO_RING_SIZE];
    NSUInteger _ringIndex;
    uint32_t _generation;
}
@end

@implementation VCSharedVideoServer

+ (instancetype)sharedServer {
    static VCSharedVideoServer *server;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ server = [[self alloc] init]; });
    return server;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        _generation = 1;
    }
    return self;
}

- (BOOL)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NO;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!surface) {
        NSLog(@"[VirtualCamPro] Producer returned a non-IOSurface video frame; dropping it");
        return NO;
    }

    IOSurfaceID surfaceID = IOSurfaceGetID(surface);
    if (surfaceID == 0) return NO;
    CVPixelBufferRef retained = CVPixelBufferRetain(pixelBuffer);
    CVPixelBufferRef retired = NULL;
    uint32_t generation = 0;

    os_unfair_lock_lock(&_lock);
    NSUInteger slot = _ringIndex++ % VC_SHARED_VIDEO_RING_SIZE;
    retired = _surfaceRing[slot];
    _surfaceRing[slot] = retained;
    generation = ++_generation;
    if (generation == 0) generation = ++_generation;
    os_unfair_lock_unlock(&_lock);

    uint64_t state = VCPackSurfaceState(generation, surfaceID);
    BOOL published = VCNotifyWriteState(VCVideoTimestampNotification,
                                        VCMonotonicMilliseconds()) &&
                     VCNotifyWriteState(VCVideoSurfaceNotification, state);
    if (retired) CVPixelBufferRelease(retired);
    return published;
}

- (void)invalidate {
    CVPixelBufferRef retired[VC_SHARED_VIDEO_RING_SIZE] = {0};
    os_unfair_lock_lock(&_lock);
    for (NSUInteger index = 0; index < VC_SHARED_VIDEO_RING_SIZE; index++) {
        retired[index] = _surfaceRing[index];
        _surfaceRing[index] = NULL;
    }
    _ringIndex = 0;
    _generation++;
    os_unfair_lock_unlock(&_lock);
    VCNotifyWriteState(VCVideoTimestampNotification, 0);
    VCNotifyWriteState(VCVideoSurfaceNotification, 0);
    for (NSUInteger index = 0; index < VC_SHARED_VIDEO_RING_SIZE; index++) {
        if (retired[index]) CVPixelBufferRelease(retired[index]);
    }
}

- (void)handleMemoryPressure {
    // Keep only the newest slot. This preserves fail-open continuity while
    // promptly releasing the two surfaces used solely as race protection.
    CVPixelBufferRef retired[VC_SHARED_VIDEO_RING_SIZE] = {0};
    os_unfair_lock_lock(&_lock);
    NSUInteger newest = _ringIndex == 0 ? NSNotFound
                                        : (_ringIndex - 1) % VC_SHARED_VIDEO_RING_SIZE;
    for (NSUInteger index = 0; index < VC_SHARED_VIDEO_RING_SIZE; index++) {
        if (index != newest) {
            retired[index] = _surfaceRing[index];
            _surfaceRing[index] = NULL;
        }
    }
    os_unfair_lock_unlock(&_lock);
    for (NSUInteger index = 0; index < VC_SHARED_VIDEO_RING_SIZE; index++) {
        if (retired[index]) CVPixelBufferRelease(retired[index]);
    }
}

- (void)dealloc { [self invalidate]; }
@end

@interface VCSharedVideoClient () {
    os_unfair_lock _lock;
    uint64_t _cachedSurfaceState;
    CVPixelBufferRef _cachedPixelBuffer;
}
@end

@implementation VCSharedVideoClient

+ (instancetype)sharedClient {
    static VCSharedVideoClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ client = [[self alloc] init]; });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) _lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
    return self;
}

- (CVPixelBufferRef)copyLatestPixelBufferWithMaximumAge:(NSTimeInterval)maximumAge {
    if (!VCStateIsRecent(VCVideoTimestampNotification, maximumAge)) return NULL;

    // A producer can advance while we look up the surface. Retrying the control
    // word closes that race; the producer also retains three generations.
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        uint64_t before = 0;
        if (!VCNotifyReadState(VCVideoSurfaceNotification, &before) || before == 0) {
            return NULL;
        }
        CVPixelBufferRef cached = NULL;
        os_unfair_lock_lock(&_lock);
        if (_cachedSurfaceState == before && _cachedPixelBuffer) {
            cached = CVPixelBufferRetain(_cachedPixelBuffer);
        }
        os_unfair_lock_unlock(&_lock);
        if (cached) {
            IOSurfaceRef cachedSurface = CVPixelBufferGetIOSurface(cached);
            if (!cachedSurface) {
                CVPixelBufferRelease(cached);
                continue;
            }
            IOSurfaceIncrementUseCount(cachedSurface);
            uint64_t after = 0;
            if (VCNotifyReadState(VCVideoSurfaceNotification, &after) && before == after) {
                return cached;
            }
            IOSurfaceDecrementUseCount(cachedSurface);
            CVPixelBufferRelease(cached);
            continue;
        }
        IOSurfaceID surfaceID = (IOSurfaceID)VCSurfaceIDFromState(before);
        IOSurfaceRef surface = IOSurfaceLookup(surfaceID);
        if (!surface) continue;

        // CVPixelBufferPool does not automatically honor cross-process users
        // when a surface is passed by global IOSurfaceID. The explicit use
        // count is the lease that prevents the producer pool from recycling
        // these bytes until the caller finishes its synchronous conversion.
        IOSurfaceIncrementUseCount(surface);

        CVPixelBufferRef pixelBuffer = NULL;
        CVReturn result = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault,
                                                            surface,
                                                            NULL,
                                                            &pixelBuffer);
        if (result != kCVReturnSuccess || !pixelBuffer) {
            IOSurfaceDecrementUseCount(surface);
            CFRelease(surface);
            continue;
        }

        uint64_t after = 0;
        if (VCNotifyReadState(VCVideoSurfaceNotification, &after) && before == after) {
            CVPixelBufferRef retired = NULL;
            CVPixelBufferRef raced = NULL;
            os_unfair_lock_lock(&_lock);
            if (_cachedSurfaceState == before && _cachedPixelBuffer) {
                raced = CVPixelBufferRetain(_cachedPixelBuffer);
            } else {
                retired = _cachedPixelBuffer;
                _cachedPixelBuffer = CVPixelBufferRetain(pixelBuffer);
                _cachedSurfaceState = before;
            }
            os_unfair_lock_unlock(&_lock);
            if (retired) CVPixelBufferRelease(retired);
            if (raced) {
                CVPixelBufferRelease(pixelBuffer);
                CFRelease(surface);
                return raced;
            }
            CFRelease(surface);
            return pixelBuffer;
        }
        IOSurfaceDecrementUseCount(surface);
        CFRelease(surface);
        CVPixelBufferRelease(pixelBuffer);
    }
    return NULL;
}

- (BOOL)hasPublishedFrameWithMaximumAge:(NSTimeInterval)maximumAge {
    if (!VCStateIsRecent(VCVideoTimestampNotification, maximumAge)) return NO;
    uint64_t state = 0;
    return VCNotifyReadState(VCVideoSurfaceNotification, &state) && state != 0;
}

- (void)dealloc {
    if (_cachedPixelBuffer) CVPixelBufferRelease(_cachedPixelBuffer);
}
@end

void VCReleaseSharedVideoPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (surface) IOSurfaceDecrementUseCount(surface);
    CVPixelBufferRelease(pixelBuffer);
}

@interface VCSharedAudioServer () {
    os_unfair_lock _lock;
    IOSurfaceRef _surface;
    VCSharedAudioRing *_ring;
    uint32_t _generation;
}
@end


@implementation VCSharedAudioServer

+ (instancetype)sharedServer {
    static VCSharedAudioServer *server;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ server = [[self alloc] init]; });
    return server;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        _generation = 1;
    }
    return self;
}

- (BOOL)ensureRingLocked {
    if (_surface && _ring) return YES;
    size_t byteCount = sizeof(VCSharedAudioRing) +
        (size_t)VC_SHARED_AUDIO_CAPACITY_FRAMES * VC_SHARED_AUDIO_CHANNELS * sizeof(float);
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(byteCount),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1,
        (id)kIOSurfaceBytesPerRow: @(byteCount),
        (id)kIOSurfaceAllocSize: @(byteCount),
        (id)kIOSurfaceIsGlobal: @YES,
    };
    _surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!_surface) return NO;
    IOSurfaceLock(_surface, 0, NULL);
    _ring = (VCSharedAudioRing *)IOSurfaceGetBaseAddress(_surface);
    if (_ring) {
        memset(_ring, 0, byteCount);
        _ring->magic = VC_SHARED_AUDIO_MAGIC;
        _ring->version = VC_SHARED_AUDIO_VERSION;
        _ring->sampleRate = VC_SHARED_AUDIO_SAMPLE_RATE;
        _ring->channelCount = VC_SHARED_AUDIO_CHANNELS;
        _ring->capacityFrames = VC_SHARED_AUDIO_CAPACITY_FRAMES;
    }
    IOSurfaceUnlock(_surface, 0, NULL);
    return _ring != NULL;
}

- (BOOL)publishInterleavedStereoSamples:(const float *)samples
                             frameCount:(NSUInteger)frameCount {
    if (!samples || frameCount == 0) return NO;
    IOSurfaceID surfaceID = 0;
    uint32_t generation = 0;
    os_unfair_lock_lock(&_lock);
    if (![self ensureRingLocked]) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    IOSurfaceLock(_surface, 0, NULL);
    uint64_t start = atomic_load_explicit(&_ring->totalFramesWritten,
                                          memory_order_relaxed);
    NSUInteger skip = frameCount > _ring->capacityFrames
        ? frameCount - _ring->capacityFrames : 0;
    samples += skip * VC_SHARED_AUDIO_CHANNELS;
    frameCount -= skip;
    for (NSUInteger frame = 0; frame < frameCount; frame++) {
        size_t target = VCAudioRingFrameIndex(start + frame, _ring->capacityFrames);
        _ring->samples[target * 2] = samples[frame * 2];
        _ring->samples[target * 2 + 1] = samples[frame * 2 + 1];
    }
    atomic_store_explicit(&_ring->totalFramesWritten,
                          start + frameCount,
                          memory_order_release);
    atomic_fetch_add_explicit(&_ring->sequence, 1, memory_order_release);
    IOSurfaceUnlock(_surface, 0, NULL);
    surfaceID = IOSurfaceGetID(_surface);
    generation = ++_generation;
    os_unfair_lock_unlock(&_lock);

    uint64_t state = VCPackSurfaceState(generation, surfaceID);
    return VCNotifyWriteState(VCAudioTimestampNotification,
                              VCMonotonicMilliseconds()) &&
           VCNotifyWriteState(VCAudioSurfaceNotification, state);
}

- (void)invalidate {
    IOSurfaceRef surface = NULL;
    os_unfair_lock_lock(&_lock);
    surface = _surface;
    _surface = NULL;
    _ring = NULL;
    _generation++;
    os_unfair_lock_unlock(&_lock);
    VCNotifyWriteState(VCAudioTimestampNotification, 0);
    VCNotifyWriteState(VCAudioSurfaceNotification, 0);
    if (surface) CFRelease(surface);
}

- (void)handleMemoryPressure { [self invalidate]; }
- (void)dealloc { [self invalidate]; }
@end

@interface VCSharedAudioClient () {
    os_unfair_lock _lock;
    IOSurfaceRef _surface;
    IOSurfaceID _surfaceID;
    IOSurfaceID _readSurfaceID;
    uint64_t _nextReadFrame;
    BOOL _readCursorValid;
}
@end

@implementation VCSharedAudioClient

+ (instancetype)sharedClient {
    static VCSharedAudioClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ client = [[self alloc] init]; });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) _lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
    return self;
}

- (IOSurfaceRef)copyCurrentSurface {
    uint64_t state = 0;
    if (!VCNotifyReadState(VCAudioSurfaceNotification, &state) || state == 0) return NULL;
    IOSurfaceID requestedID = (IOSurfaceID)VCSurfaceIDFromState(state);
    os_unfair_lock_lock(&_lock);
    if (!_surface || _surfaceID != requestedID) {
        IOSurfaceRef replacement = IOSurfaceLookup(requestedID);
        if (_surface) CFRelease(_surface);
        _surface = replacement;
        _surfaceID = replacement ? requestedID : 0;
    }
    IOSurfaceRef result = _surface ? (IOSurfaceRef)CFRetain(_surface) : NULL;
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (BOOL)copyLatestInterleavedStereoFrames:(NSUInteger)frameCount
                                      into:(float *)destination {
    if (!destination || frameCount == 0 ||
        !VCStateIsRecent(VCAudioTimestampNotification, 2.0)) return NO;
    IOSurfaceRef surface = [self copyCurrentSurface];
    if (!surface) return NO;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    VCSharedAudioRing *ring = (VCSharedAudioRing *)IOSurfaceGetBaseAddress(surface);
    BOOL valid = ring && ring->magic == VC_SHARED_AUDIO_MAGIC &&
        ring->version == VC_SHARED_AUDIO_VERSION &&
        ring->sampleRate == VC_SHARED_AUDIO_SAMPLE_RATE &&
        ring->channelCount == VC_SHARED_AUDIO_CHANNELS &&
        frameCount <= ring->capacityFrames;
    if (valid) {
        uint64_t end = atomic_load_explicit(&ring->totalFramesWritten,
                                            memory_order_acquire);
        uint64_t start = 0;
        IOSurfaceID currentSurfaceID = IOSurfaceGetID(surface);
        os_unfair_lock_lock(&_lock);
        BOOL cursorMatchesSurface = _readCursorValid &&
            _readSurfaceID == currentSurfaceID;
        valid = VCResolveAudioReadStart(end,
                                        frameCount,
                                        ring->capacityFrames,
                                        VC_SHARED_AUDIO_MAX_LAG_FRAMES,
                                        cursorMatchesSurface,
                                        _nextReadFrame,
                                        &start);
        if (valid) {
            for (NSUInteger frame = 0; frame < frameCount; frame++) {
                size_t source = VCAudioRingFrameIndex(start + frame,
                                                      ring->capacityFrames);
                destination[frame * 2] = ring->samples[source * 2];
                destination[frame * 2 + 1] = ring->samples[source * 2 + 1];
            }
            atomic_thread_fence(memory_order_acquire);
            uint64_t endAfterCopy = atomic_load_explicit(&ring->totalFramesWritten,
                                                         memory_order_acquire);
            valid = endAfterCopy - start <= ring->capacityFrames;
            if (valid) {
                _readSurfaceID = currentSurfaceID;
                _nextReadFrame = start + frameCount;
                _readCursorValid = YES;
            } else {
                _readCursorValid = NO;
            }
        }
        os_unfair_lock_unlock(&_lock);
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);
    return valid;
}

- (BOOL)hasPublishedAudioWithMaximumAge:(NSTimeInterval)maximumAge {
    if (!VCStateIsRecent(VCAudioTimestampNotification, maximumAge)) return NO;
    uint64_t state = 0;
    return VCNotifyReadState(VCAudioSurfaceNotification, &state) && state != 0;
}

- (void)dealloc {
    if (_surface) CFRelease(_surface);
}
@end

void VCMarkSystemPipelineActivity(VCSharedMediaKind kind) {
    const char *name = kind == VCSharedMediaKindAudio
        ? VCAudioPipelineHeartbeat : VCVideoPipelineHeartbeat;
    VCNotifyWriteState(name, VCMonotonicMilliseconds());
}

BOOL VCSystemPipelineIsActive(VCSharedMediaKind kind, NSTimeInterval maximumAge) {
    const char *name = kind == VCSharedMediaKindAudio
        ? VCAudioPipelineHeartbeat : VCVideoPipelineHeartbeat;
    return VCStateIsRecent(name, maximumAge);
}
