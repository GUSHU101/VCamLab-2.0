#import "VCSharedMediaBus.h"
#import "VCSharedMediaProtocol.h"

#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <os/lock.h>
#import <stdatomic.h>

typedef NS_ENUM(NSUInteger, VCNotifyChannel) {
    VCNotifyChannelVideoControl = 0,
    VCNotifyChannelAudioSurface,
    VCNotifyChannelVideoPipelineHeartbeat,
    VCNotifyChannelAudioPipelineHeartbeat,
    VCNotifyChannelSpringBoardRuntimeHeartbeat,
    VCNotifyChannelMediaServerRuntimeHeartbeat,
    VCNotifyChannelMediaServerVideoRuntime,
    VCNotifyChannelApplicationVideoRuntime,
    VCNotifyChannelCount,
};

static const char *VCNotifyChannelNames[VCNotifyChannelCount] = {
    [VCNotifyChannelVideoControl] =
        "com.murkaska.virtualcampro/media.video.control.v2",
    [VCNotifyChannelAudioSurface] =
        "com.murkaska.virtualcampro/media.audio.surface.v2",
    [VCNotifyChannelVideoPipelineHeartbeat] =
        "com.murkaska.virtualcampro/pipeline.video.heartbeat.v1",
    [VCNotifyChannelAudioPipelineHeartbeat] =
        "com.murkaska.virtualcampro/pipeline.audio.heartbeat.v1",
    [VCNotifyChannelSpringBoardRuntimeHeartbeat] =
        "com.murkaska.virtualcampro/runtime.springboard.heartbeat.v1",
    [VCNotifyChannelMediaServerRuntimeHeartbeat] =
        "com.murkaska.virtualcampro/runtime.mediaserverd.heartbeat.v1",
    [VCNotifyChannelMediaServerVideoRuntime] =
        "com.murkaska.virtualcampro/runtime.mediaserverd.video.v1",
    [VCNotifyChannelApplicationVideoRuntime] =
        "com.murkaska.virtualcampro/runtime.application.video.v1",
};

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t reserved;
    _Atomic(uint64_t) totalFramesWritten;
    _Atomic(uint64_t) sequence;
    _Atomic(uint64_t) timestampMilliseconds;
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

static int VCNotifyTokenForChannel(VCNotifyChannel channel) {
    static dispatch_once_t onceToken;
    static _Atomic(int) tokens[VCNotifyChannelCount];
    static uint64_t lastAttemptMilliseconds[VCNotifyChannelCount];
    static os_unfair_lock tokenLock = OS_UNFAIR_LOCK_INIT;
    dispatch_once(&onceToken, ^{
        for (NSUInteger index = 0; index < VCNotifyChannelCount; index++) {
            atomic_init(&tokens[index], -1);
        }
    });
    if (channel >= VCNotifyChannelCount) return -1;

    // Successful registrations stay lock-free on every media-frame hot path.
    // A transient notifyd failure is retried at a bounded cadence instead of
    // disabling shared video/audio discovery for the lifetime of the process.
    int token = atomic_load_explicit(&tokens[channel], memory_order_acquire);
    if (token >= 0) return token;

    os_unfair_lock_lock(&tokenLock);
    token = atomic_load_explicit(&tokens[channel], memory_order_relaxed);
    uint64_t now = VCMonotonicMilliseconds();
    uint64_t lastAttempt = lastAttemptMilliseconds[channel];
    BOOL retryDue = lastAttempt == 0 || now < lastAttempt ||
                    now - lastAttempt >= 5000;
    if (token < 0 && retryDue) {
        lastAttemptMilliseconds[channel] = now;
        int candidate = -1;
        if (notify_register_check(VCNotifyChannelNames[channel], &candidate) ==
            NOTIFY_STATUS_OK) {
            atomic_store_explicit(&tokens[channel], candidate, memory_order_release);
            token = candidate;
        }
    }
    os_unfair_lock_unlock(&tokenLock);
    return token;
}

static BOOL VCNotifyWriteState(VCNotifyChannel channel,
                               uint64_t state,
                               BOOL postNotification) {
    int token = VCNotifyTokenForChannel(channel);
    if (token < 0) return NO;
    uint32_t result = notify_set_state(token, state);
    if (result == NOTIFY_STATUS_OK && postNotification) {
        notify_post(VCNotifyChannelNames[channel]);
    }
    return result == NOTIFY_STATUS_OK;
}

static BOOL VCNotifyCheckChanged(VCNotifyChannel channel) {
    int token = VCNotifyTokenForChannel(channel);
    if (token < 0) return YES;
    int changed = 0;
    return notify_check(token, &changed) != NOTIFY_STATUS_OK || changed != 0;
}

static BOOL VCNotifyReadState(VCNotifyChannel channel, uint64_t *state) {
    if (!state) return NO;
    int token = VCNotifyTokenForChannel(channel);
    if (token < 0) return NO;
    uint32_t result = notify_get_state(token, state);
    return result == NOTIFY_STATUS_OK;
}

static BOOL VCNotifyStateIsRecent(VCNotifyChannel timestampChannel,
                                  NSTimeInterval maximumAge) {
    uint64_t timestamp = 0;
    if (!VCNotifyReadState(timestampChannel, &timestamp) || timestamp == 0) return NO;
    uint64_t now = VCMonotonicMilliseconds();
    if (now < timestamp) return NO;
    uint64_t maximumAgeMilliseconds = (uint64_t)(MAX(0.05, maximumAge) * 1000.0);
    return now - timestamp <= maximumAgeMilliseconds;
}

void VCStartSharedRuntimeHeartbeat(VCSharedRuntimeProcess process) {
    static dispatch_source_t heartbeatTimers[3];
    static os_unfair_lock heartbeatLock = OS_UNFAIR_LOCK_INIT;
    VCNotifyChannel channel = VCNotifyChannelCount;
    switch (process) {
        case VCSharedRuntimeProcessSpringBoard:
            channel = VCNotifyChannelSpringBoardRuntimeHeartbeat;
            break;
        case VCSharedRuntimeProcessMediaServer:
            channel = VCNotifyChannelMediaServerRuntimeHeartbeat;
            break;
        default:
            return;
    }

    os_unfair_lock_lock(&heartbeatLock);
    if (heartbeatTimers[process]) {
        os_unfair_lock_unlock(&heartbeatLock);
        return;
    }
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!timer) {
        os_unfair_lock_unlock(&heartbeatLock);
        return;
    }
    heartbeatTimers[process] = timer;
    os_unfair_lock_unlock(&heartbeatLock);

    VCNotifyWriteState(channel, VCMonotonicMilliseconds(), NO);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(2.0 * NSEC_PER_SEC)),
                              (uint64_t)(2.0 * NSEC_PER_SEC),
                              (uint64_t)(0.25 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        VCNotifyWriteState(channel, VCMonotonicMilliseconds(), NO);
    });
    dispatch_resume(timer);
}

static BOOL VCRuntimeEventNeedsImmediateTransition(VCNotifyChannel channel,
                                                   uint8_t event) {
    if (channel == VCNotifyChannelMediaServerVideoRuntime) {
        return event >= VCMediaServerVideoRuntimeInjected &&
            event <= VCMediaServerVideoRuntimeHookCapacityExceeded;
    }
    if (channel == VCNotifyChannelApplicationVideoRuntime) {
        return event == VCApplicationVideoRuntimeDelegateWrapped ||
            event == VCApplicationVideoRuntimePreviewOverlayInstalled ||
            event == VCApplicationVideoRuntimePhotoReplacementSucceeded ||
            event == VCApplicationVideoRuntimePhotoReplacementFailed;
    }
    return NO;
}

static void VCReportRuntimeEvent(VCNotifyChannel channel,
                                 uint8_t event,
                                 uint8_t detail,
                                 _Atomic(uint64_t) *lastRuntimeState) {
    uint64_t now = VCMonotonicMilliseconds();
    uint64_t next = VCPackRuntimeEventState(event, detail, now);
    uint64_t observed = atomic_load_explicit(lastRuntimeState,
                                              memory_order_relaxed);
    do {
        uint8_t previousEvent = (uint8_t)VCEventFromRuntimeState(observed);
        uint8_t previousDetail = VCDetailFromRuntimeState(observed);
        uint64_t previousTimestamp = VCTimestampFromRuntimeState(observed);
        if (now >= previousTimestamp) {
            BOOL sameEvent = previousEvent == event && previousDetail == detail;
            uint64_t minimumInterval = sameEvent
                ? 1000
                : (VCRuntimeEventNeedsImmediateTransition(channel, event)
                    ? 0
                    : 250);
            if (now - previousTimestamp < minimumInterval) return;
        }
    } while (!atomic_compare_exchange_weak_explicit(lastRuntimeState,
                                                     &observed,
                                                     next,
                                                     memory_order_relaxed,
                                                     memory_order_relaxed));
    VCNotifyWriteState(channel, next, NO);
}

void VCReportMediaServerVideoRuntimeEvent(
    VCMediaServerVideoRuntimeEvent event,
    uint8_t detail) {
    static _Atomic(uint64_t) lastRuntimeState = 0;
    VCReportRuntimeEvent(VCNotifyChannelMediaServerVideoRuntime,
                         (uint8_t)event,
                         detail,
                         &lastRuntimeState);
}

void VCReportApplicationVideoRuntimeEvent(
    VCApplicationVideoRuntimeEvent event,
    uint8_t detail) {
    static _Atomic(uint64_t) lastRuntimeState = 0;
    VCReportRuntimeEvent(VCNotifyChannelApplicationVideoRuntime,
                         (uint8_t)event,
                         detail,
                         &lastRuntimeState);
}

@interface VCSharedVideoServer () {
    os_unfair_lock _lock;
    CVPixelBufferRef _surfaceRing[VC_SHARED_VIDEO_RING_SIZE];
    NSUInteger _ringIndex;
    uint32_t _generation;
    IOSurfaceRef _controlSurface;
    VCSharedVideoControl *_control;
    BOOL _controlStatePublished;
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

- (BOOL)ensureControlSurfaceLocked {
    if (_controlSurface && _control) return YES;
    size_t byteCount = sizeof(VCSharedVideoControl);
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(byteCount),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1,
        (id)kIOSurfaceBytesPerRow: @(byteCount),
        (id)kIOSurfaceAllocSize: @(byteCount),
        (id)kIOSurfaceIsGlobal: @YES,
    };
    IOSurfaceRef created = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!created) return NO;
    IOSurfaceLock(created, 0, NULL);
    VCSharedVideoControl *control =
        (VCSharedVideoControl *)IOSurfaceGetBaseAddress(created);
    if (control) {
        memset(control, 0, byteCount);
        control->magic = VC_SHARED_VIDEO_CONTROL_MAGIC;
        control->version = VC_SHARED_VIDEO_CONTROL_VERSION;
        atomic_init(&control->surfaceState, 0);
        atomic_init(&control->timestampMilliseconds, 0);
    }
    IOSurfaceUnlock(created, 0, NULL);
    if (!control) {
        CFRelease(created);
        return NO;
    }
    if (IOSurfaceGetID(created) == 0) {
        CFRelease(created);
        return NO;
    }
    _controlSurface = created;
    _control = control;
    _controlStatePublished = NO;
    return YES;
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
    uint64_t now = VCMonotonicMilliseconds();
    IOSurfaceID controlSurfaceID = 0;
    BOOL controlStateDue = NO;

    os_unfair_lock_lock(&_lock);
    if (![self ensureControlSurfaceLocked]) {
        os_unfair_lock_unlock(&_lock);
        CVPixelBufferRelease(retained);
        return NO;
    }
    NSUInteger slot = _ringIndex++ % VC_SHARED_VIDEO_RING_SIZE;
    retired = _surfaceRing[slot];
    _surfaceRing[slot] = retained;
    generation = ++_generation;
    if (generation == 0) generation = ++_generation;
    uint64_t state = VCPackSurfaceState(generation, surfaceID);
    atomic_store_explicit(&_control->timestampMilliseconds,
                          now,
                          memory_order_relaxed);
    atomic_store_explicit(&_control->surfaceState, state, memory_order_release);
    controlSurfaceID = IOSurfaceGetID(_controlSurface);
    controlStateDue = !_controlStatePublished;
    os_unfair_lock_unlock(&_lock);

    BOOL controlStatePublished = !controlStateDue ||
        VCNotifyWriteState(VCNotifyChannelVideoControl,
                           (uint64_t)controlSurfaceID,
                           YES);
    if (controlStateDue && controlStatePublished) {
        os_unfair_lock_lock(&_lock);
        if (_controlSurface && IOSurfaceGetID(_controlSurface) == controlSurfaceID) {
            _controlStatePublished = YES;
        }
        os_unfair_lock_unlock(&_lock);
    }
    if (retired) CVPixelBufferRelease(retired);
    return controlStatePublished;
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
    if (_control) {
        atomic_store_explicit(&_control->timestampMilliseconds, 0, memory_order_relaxed);
        atomic_store_explicit(&_control->surfaceState, 0, memory_order_release);
    }
    os_unfair_lock_unlock(&_lock);
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

- (void)dealloc {
    [self invalidate];
    if (_controlSurface) CFRelease(_controlSurface);
}
@end

@interface VCSharedVideoClient () {
    os_unfair_lock _lock;
    IOSurfaceRef _controlSurface;
    VCSharedVideoControl *_control;
    IOSurfaceID _controlSurfaceID;
    BOOL _controlRefreshPending;
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

- (BOOL)refreshControlSurfaceLocked {
    BOOL shouldRefresh = !_controlSurface || _controlRefreshPending ||
        VCNotifyCheckChanged(VCNotifyChannelVideoControl);
    if (!shouldRefresh) return _control != NULL;

    uint64_t state = 0;
    if (!VCNotifyReadState(VCNotifyChannelVideoControl, &state) || state == 0) {
        if (_cachedPixelBuffer) CVPixelBufferRelease(_cachedPixelBuffer);
        if (_controlSurface) CFRelease(_controlSurface);
        _cachedPixelBuffer = NULL;
        _cachedSurfaceState = 0;
        _controlSurface = NULL;
        _control = NULL;
        _controlSurfaceID = 0;
        _controlRefreshPending = NO;
        return NO;
    }
    IOSurfaceID requestedID = (IOSurfaceID)state;
    if (_controlSurface && _controlSurfaceID == requestedID && _control) {
        _controlRefreshPending = NO;
        return YES;
    }

    IOSurfaceRef surface = IOSurfaceLookup(requestedID);
    if (!surface) {
        _controlRefreshPending = YES;
        return NO;
    }
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    VCSharedVideoControl *control =
        (VCSharedVideoControl *)IOSurfaceGetBaseAddress(surface);
    BOOL valid = control && control->magic == VC_SHARED_VIDEO_CONTROL_MAGIC &&
        control->version == VC_SHARED_VIDEO_CONTROL_VERSION;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    if (!valid) {
        CFRelease(surface);
        _controlRefreshPending = YES;
        return NO;
    }

    if (_cachedPixelBuffer) CVPixelBufferRelease(_cachedPixelBuffer);
    if (_controlSurface) CFRelease(_controlSurface);
    _cachedPixelBuffer = NULL;
    _cachedSurfaceState = 0;
    _controlSurface = surface;
    _control = control;
    _controlSurfaceID = requestedID;
    _controlRefreshPending = NO;
    return YES;
}

- (BOOL)readControlSurfaceState:(uint64_t *)surfaceState
           timestampMilliseconds:(uint64_t *)timestampMilliseconds {
    os_unfair_lock_lock(&_lock);
    BOOL valid = [self refreshControlSurfaceLocked];
    uint64_t state = 0;
    uint64_t timestamp = 0;
    if (valid && _control) {
        state = atomic_load_explicit(&_control->surfaceState, memory_order_acquire);
        timestamp = atomic_load_explicit(&_control->timestampMilliseconds,
                                         memory_order_relaxed);
    }
    os_unfair_lock_unlock(&_lock);
    if (surfaceState) *surfaceState = state;
    if (timestampMilliseconds) *timestampMilliseconds = timestamp;
    return valid;
}

- (CVPixelBufferRef)copyLatestPixelBufferWithMaximumAge:(NSTimeInterval)maximumAge {
    uint64_t initialState = 0;
    uint64_t timestamp = 0;
    if (![self readControlSurfaceState:&initialState
                 timestampMilliseconds:&timestamp]) return NULL;
    uint64_t maximumAgeMilliseconds =
        (uint64_t)(MAX(0.05, maximumAge) * 1000.0);
    if (!VCSharedTimestampIsRecent(VCMonotonicMilliseconds(),
                                   timestamp,
                                   maximumAgeMilliseconds)) return NULL;

    // A producer can advance while we look up the surface. Retrying the control
    // word closes that race; the producer also retains three generations.
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        uint64_t before = attempt == 0 ? initialState : 0;
        if (attempt > 0 && ![self readControlSurfaceState:&before
                                    timestampMilliseconds:NULL]) return NULL;
        if (before == 0) return NULL;
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
            if ([self readControlSurfaceState:&after timestampMilliseconds:NULL] &&
                before == after) {
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
        if ([self readControlSurfaceState:&after timestampMilliseconds:NULL] &&
            before == after) {
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
                // The cache winner and the wrapper created above represent the
                // same published state. Give the returned wrapper its own
                // explicit IOSurface lease before retiring the losing wrapper's
                // lease. This is a net-zero use-count change and removes the
                // previous implicit lease-transfer invariant.
                IOSurfaceRef racedSurface = CVPixelBufferGetIOSurface(raced);
                if (!racedSurface) {
                    CVPixelBufferRelease(raced);
                    IOSurfaceDecrementUseCount(surface);
                    CVPixelBufferRelease(pixelBuffer);
                    CFRelease(surface);
                    continue;
                }
                IOSurfaceIncrementUseCount(racedSurface);
                IOSurfaceDecrementUseCount(surface);
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
    uint64_t state = 0;
    uint64_t timestamp = 0;
    if (![self readControlSurfaceState:&state
                 timestampMilliseconds:&timestamp] || state == 0) return NO;
    uint64_t maximumAgeMilliseconds =
        (uint64_t)(MAX(0.05, maximumAge) * 1000.0);
    return VCSharedTimestampIsRecent(VCMonotonicMilliseconds(),
                                     timestamp,
                                     maximumAgeMilliseconds);
}

- (void)dealloc {
    if (_cachedPixelBuffer) CVPixelBufferRelease(_cachedPixelBuffer);
    if (_controlSurface) CFRelease(_controlSurface);
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
    BOOL _surfaceStatePublished;
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
    if (!_ring || IOSurfaceGetID(_surface) == 0) {
        CFRelease(_surface);
        _surface = NULL;
        _ring = NULL;
        return NO;
    }
    return YES;
}

- (BOOL)publishInterleavedStereoSamples:(const float *)samples
                             frameCount:(NSUInteger)frameCount {
    if (!samples || frameCount == 0) return NO;
    IOSurfaceID surfaceID = 0;
    uint32_t generation = 0;
    uint64_t now = VCMonotonicMilliseconds();
    BOOL surfaceStateDue = NO;
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
    atomic_store_explicit(&_ring->timestampMilliseconds,
                          now,
                          memory_order_release);
    IOSurfaceUnlock(_surface, 0, NULL);
    surfaceID = IOSurfaceGetID(_surface);
    generation = _generation;
    surfaceStateDue = !_surfaceStatePublished;
    os_unfair_lock_unlock(&_lock);

    uint64_t state = VCPackSurfaceState(generation, surfaceID);
    BOOL surfaceStatePublished = !surfaceStateDue ||
        VCNotifyWriteState(VCNotifyChannelAudioSurface, state, YES);
    if (surfaceStateDue && surfaceStatePublished) {
        os_unfair_lock_lock(&_lock);
        if (_surface && IOSurfaceGetID(_surface) == surfaceID) {
            _surfaceStatePublished = YES;
        }
        os_unfair_lock_unlock(&_lock);
    }
    return surfaceStatePublished;
}

- (void)invalidate {
    IOSurfaceRef surface = NULL;
    os_unfair_lock_lock(&_lock);
    surface = _surface;
    if (_surface && _ring) {
        IOSurfaceLock(_surface, 0, NULL);
        atomic_store_explicit(&_ring->timestampMilliseconds, 0, memory_order_release);
        IOSurfaceUnlock(_surface, 0, NULL);
    }
    _surface = NULL;
    _ring = NULL;
    _generation++;
    _surfaceStatePublished = NO;
    os_unfair_lock_unlock(&_lock);
    VCNotifyWriteState(VCNotifyChannelAudioSurface, 0, YES);
    if (surface) CFRelease(surface);
}

- (void)handleMemoryPressure { [self invalidate]; }
- (void)dealloc { [self invalidate]; }
@end

@interface VCSharedAudioClient () {
    os_unfair_lock _lock;
    IOSurfaceRef _surface;
    uint64_t _surfaceState;
    BOOL _surfaceRefreshPending;
}
@end

@interface VCSharedAudioCursor () {
@package
    os_unfair_lock _lock;
    uint64_t _surfaceState;
    uint64_t _nextReadFrame;
    BOOL _valid;
}
@end

@implementation VCSharedAudioCursor

- (instancetype)init {
    self = [super init];
    if (self) _lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
    return self;
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    _surfaceState = 0;
    _nextReadFrame = 0;
    _valid = NO;
    os_unfair_lock_unlock(&_lock);
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

- (IOSurfaceRef)copyCurrentSurfaceWithState:(uint64_t *)surfaceStateOut {
    os_unfair_lock_lock(&_lock);
    BOOL shouldRefresh = !_surface || _surfaceRefreshPending ||
        VCNotifyCheckChanged(VCNotifyChannelAudioSurface);
    if (shouldRefresh) {
        uint64_t state = 0;
        if (!VCNotifyReadState(VCNotifyChannelAudioSurface, &state) || state == 0) {
            if (_surface) CFRelease(_surface);
            _surface = NULL;
            _surfaceState = 0;
            _surfaceRefreshPending = NO;
            os_unfair_lock_unlock(&_lock);
            return NULL;
        }
        IOSurfaceID requestedID = (IOSurfaceID)VCSurfaceIDFromState(state);
        if (!_surface || _surfaceState != state) {
            IOSurfaceRef replacement = IOSurfaceLookup(requestedID);
            if (!replacement) {
                _surfaceRefreshPending = YES;
                os_unfair_lock_unlock(&_lock);
                return NULL;
            }
            IOSurfaceLock(replacement, kIOSurfaceLockReadOnly, NULL);
            VCSharedAudioRing *ring =
                (VCSharedAudioRing *)IOSurfaceGetBaseAddress(replacement);
            BOOL valid = ring && ring->magic == VC_SHARED_AUDIO_MAGIC &&
                ring->version == VC_SHARED_AUDIO_VERSION &&
                ring->sampleRate == VC_SHARED_AUDIO_SAMPLE_RATE &&
                ring->channelCount == VC_SHARED_AUDIO_CHANNELS &&
                ring->capacityFrames == VC_SHARED_AUDIO_CAPACITY_FRAMES;
            IOSurfaceUnlock(replacement, kIOSurfaceLockReadOnly, NULL);
            if (!valid) {
                CFRelease(replacement);
                _surfaceRefreshPending = YES;
                os_unfair_lock_unlock(&_lock);
                return NULL;
            }
            if (_surface) CFRelease(_surface);
            _surface = replacement;
            _surfaceState = state;
        }
        _surfaceRefreshPending = NO;
    }
    IOSurfaceRef result = _surface ? (IOSurfaceRef)CFRetain(_surface) : NULL;
    if (surfaceStateOut) *surfaceStateOut = result ? _surfaceState : 0;
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (BOOL)copyLatestInterleavedStereoFrames:(NSUInteger)frameCount
                                      into:(float *)destination
                                    cursor:(VCSharedAudioCursor *)cursor {
    if (!destination || frameCount == 0 || !cursor) return NO;
    uint64_t surfaceState = 0;
    IOSurfaceRef surface = [self copyCurrentSurfaceWithState:&surfaceState];
    if (!surface) return NO;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    VCSharedAudioRing *ring = (VCSharedAudioRing *)IOSurfaceGetBaseAddress(surface);
    BOOL valid = ring && ring->magic == VC_SHARED_AUDIO_MAGIC &&
        ring->version == VC_SHARED_AUDIO_VERSION &&
        ring->sampleRate == VC_SHARED_AUDIO_SAMPLE_RATE &&
        ring->channelCount == VC_SHARED_AUDIO_CHANNELS &&
        frameCount <= ring->capacityFrames;
    if (valid) {
        uint64_t timestamp = atomic_load_explicit(&ring->timestampMilliseconds,
                                                   memory_order_acquire);
        valid = VCSharedTimestampIsRecent(VCMonotonicMilliseconds(),
                                          timestamp,
                                          2000);
    }
    if (valid) {
        uint64_t end = atomic_load_explicit(&ring->totalFramesWritten,
                                            memory_order_acquire);
        uint64_t start = 0;
        os_unfair_lock_lock(&cursor->_lock);
        BOOL cursorMatchesSurface = cursor->_valid &&
            cursor->_surfaceState == surfaceState;
        valid = VCResolveAudioReadStart(end,
                                        frameCount,
                                        ring->capacityFrames,
                                        VC_SHARED_AUDIO_MAX_LAG_FRAMES,
                                        VC_SHARED_AUDIO_TARGET_LEAD_FRAMES,
                                        cursorMatchesSurface,
                                        cursor->_nextReadFrame,
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
                cursor->_surfaceState = surfaceState;
                cursor->_nextReadFrame = start + frameCount;
                cursor->_valid = YES;
            } else {
                cursor->_valid = NO;
            }
        }
        os_unfair_lock_unlock(&cursor->_lock);
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);
    return valid;
}

- (BOOL)hasPublishedAudioWithMaximumAge:(NSTimeInterval)maximumAge {
    IOSurfaceRef surface = [self copyCurrentSurfaceWithState:NULL];
    if (!surface) return NO;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    VCSharedAudioRing *ring = (VCSharedAudioRing *)IOSurfaceGetBaseAddress(surface);
    BOOL valid = ring && ring->magic == VC_SHARED_AUDIO_MAGIC &&
        ring->version == VC_SHARED_AUDIO_VERSION &&
        ring->sampleRate == VC_SHARED_AUDIO_SAMPLE_RATE &&
        ring->channelCount == VC_SHARED_AUDIO_CHANNELS;
    uint64_t timestamp = valid
        ? atomic_load_explicit(&ring->timestampMilliseconds, memory_order_acquire)
        : 0;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);
    uint64_t maximumAgeMilliseconds =
        (uint64_t)(MAX(0.05, maximumAge) * 1000.0);
    return valid && VCSharedTimestampIsRecent(VCMonotonicMilliseconds(),
                                              timestamp,
                                              maximumAgeMilliseconds);
}

- (void)dealloc {
    if (_surface) CFRelease(_surface);
}
@end

void VCMarkSystemPipelineActivity(VCSharedMediaKind kind) {
    static _Atomic(uint64_t) lastVideoHeartbeat = 0;
    static _Atomic(uint64_t) lastAudioHeartbeat = 0;
    _Atomic(uint64_t) *lastHeartbeat = kind == VCSharedMediaKindAudio
        ? &lastAudioHeartbeat : &lastVideoHeartbeat;
    uint64_t now = VCMonotonicMilliseconds();
    uint64_t observed = atomic_load_explicit(lastHeartbeat, memory_order_relaxed);
    do {
        if (!VCShouldPublishPipelineHeartbeat(now, observed)) return;
    } while (!atomic_compare_exchange_weak_explicit(lastHeartbeat,
                                                     &observed,
                                                     now,
                                                     memory_order_relaxed,
                                                     memory_order_relaxed));
    VCNotifyChannel channel = kind == VCSharedMediaKindAudio
        ? VCNotifyChannelAudioPipelineHeartbeat
        : VCNotifyChannelVideoPipelineHeartbeat;
    // Health readers poll state. Posting a Darwin notification here would add
    // IPC on the camera hot path without improving fallback correctness.
    VCNotifyWriteState(channel, now, NO);
}

BOOL VCSystemPipelineIsActive(VCSharedMediaKind kind, NSTimeInterval maximumAge) {
    VCNotifyChannel channel = kind == VCSharedMediaKindAudio
        ? VCNotifyChannelAudioPipelineHeartbeat
        : VCNotifyChannelVideoPipelineHeartbeat;
    return VCNotifyStateIsRecent(channel, maximumAge);
}
