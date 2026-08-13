#import "VCScreenCaptureSource.h"

#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <mach/kern_return.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

static NSString * const VCScreenCaptureErrorDomain =
    @"com.murkaska.virtualcampro.screen-capture";
static const NSUInteger VCScreenMaximumOutstandingBuffers = 5;

// Private CoreAnimation SPI is resolved at runtime and called only from
// SpringBoard. Keeping the symbol out of the static import table lets the tweak
// fail open on builds where Apple changes the renderer.
typedef void (*VCRenderDisplayFunction)(uint32_t contextID,
                                        CFStringRef displayName,
                                        IOSurfaceRef destination,
                                        int32_t x,
                                        int32_t y);

@interface VCScreenCaptureSource () {
    os_unfair_lock _lock;
    CVPixelBufferPoolRef _pool;
    size_t _poolWidth;
    size_t _poolHeight;
    BOOL _reportedUnavailableRenderer;
}
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, assign) VCRenderDisplayFunction renderDisplay;
@end

@implementation VCScreenCaptureSource

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        _preferredFPS = 60;
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                     QOS_CLASS_USER_INTERACTIVE,
                                                     0);
        _captureQueue = dispatch_queue_create(
            "com.murkaska.virtualcampro.screen-capture", attributes);
        _renderDisplay = (VCRenderDisplayFunction)dlsym(RTLD_DEFAULT,
                                                         "CARenderServerRenderDisplay");
    }
    return self;
}

- (void)setPreferredFPS:(NSInteger)preferredFPS {
    NSInteger clamped = MAX(1, MIN(120, preferredFPS));
    @synchronized (self) { _preferredFPS = clamped; }
    dispatch_source_t timer = self.timer;
    if (timer) {
        uint64_t interval = NSEC_PER_SEC / (uint64_t)clamped;
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  interval,
                                  MAX((uint64_t)1, interval / 12));
    }
}

- (NSInteger)preferredFPS {
    @synchronized (self) { return _preferredFPS; }
}

- (void)start {
    @synchronized (self) {
        if (self.running) return;
        self.running = YES;
    }
    if (!self.renderDisplay) {
        [self reportErrorOnce:@"CARenderServerRenderDisplay is unavailable on this iOS build"];
        self.running = NO;
        return;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                       0,
                                                       0,
                                                       self.captureQueue);
    if (!timer) {
        [self reportErrorOnce:@"Unable to create the screen capture timer"];
        self.running = NO;
        return;
    }
    __weak VCScreenCaptureSource *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{ [weakSelf captureFrame]; });
    self.timer = timer;
    NSInteger fps = self.preferredFPS;
    uint64_t interval = NSEC_PER_SEC / (uint64_t)fps;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval,
                              MAX((uint64_t)1, interval / 12));
    dispatch_resume(timer);
}

- (void)stop {
    @synchronized (self) {
        if (!self.running && !self.timer) return;
        self.running = NO;
    }
    dispatch_source_t timer = self.timer;
    self.timer = nil;
    if (timer) dispatch_source_cancel(timer);
    [self releasePool];
}

- (void)captureFrame {
    if (!self.running || !self.renderDisplay) return;
    __block CGRect bounds = CGRectZero;
    __block CGFloat scale = 1.0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        Class screenClass = NSClassFromString(@"UIScreen");
        SEL mainScreenSelector = sel_registerName("mainScreen");
        id screen = screenClass && [screenClass respondsToSelector:mainScreenSelector]
            ? ((id (*)(id, SEL))objc_msgSend)((id)screenClass, mainScreenSelector) : nil;
        if (!screen) return;
        SEL boundsSelector = sel_registerName("bounds");
        SEL nativeScaleSelector = sel_registerName("nativeScale");
        SEL scaleSelector = sel_registerName("scale");
        if ([screen respondsToSelector:boundsSelector]) {
            bounds = ((CGRect (*)(id, SEL))objc_msgSend)(screen, boundsSelector);
        }
        if ([screen respondsToSelector:nativeScaleSelector]) {
            scale = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, nativeScaleSelector);
        } else if ([screen respondsToSelector:scaleSelector]) {
            scale = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, scaleSelector);
        }
    });
    if (CGRectIsEmpty(bounds)) {
        [self reportErrorOnce:@"UIScreen geometry is unavailable in SpringBoard"];
        return;
    }
    size_t width = MAX((size_t)1, (size_t)llround(CGRectGetWidth(bounds) * scale));
    size_t height = MAX((size_t)1, (size_t)llround(CGRectGetHeight(bounds) * scale));
    CVPixelBufferPoolRef pool = [self copyPoolForWidth:width height:height];
    if (!pool) return;

    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *auxiliary = @{
        (id)kCVPixelBufferPoolAllocationThresholdKey:
            @(VCScreenMaximumOutstandingBuffers)
    };
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault,
        pool,
        (__bridge CFDictionaryRef)auxiliary,
        &pixelBuffer);
    CFRelease(pool);
    if (result != kCVReturnSuccess || !pixelBuffer) return;

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!surface) {
        CVPixelBufferRelease(pixelBuffer);
        [self reportErrorOnce:@"Screen pool returned a non-IOSurface buffer"];
        return;
    }
    kern_return_t lockResult = IOSurfaceLock(surface, 0, NULL);
    if (lockResult != KERN_SUCCESS) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    self.renderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    IOSurfaceUnlock(surface, 0, NULL);
    VCScreenFrameCallback callback = self.frameCallback;
    if (callback && self.running) callback(pixelBuffer);
    CVPixelBufferRelease(pixelBuffer);
}

- (CVPixelBufferPoolRef)copyPoolForWidth:(size_t)width
                                  height:(size_t)height CF_RETURNS_RETAINED {
    CVPixelBufferPoolRef result = NULL;
    os_unfair_lock_lock(&_lock);
    if (!_pool || _poolWidth != width || _poolHeight != height) {
        if (_pool) CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
        _poolWidth = width;
        _poolHeight = height;
        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        };
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{
                (id)kIOSurfaceIsGlobal: @YES,
            },
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)poolAttributes,
                                (__bridge CFDictionaryRef)pixelAttributes,
                                &_pool);
    }
    if (_pool) result = (CVPixelBufferPoolRef)CFRetain(_pool);
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (void)reportErrorOnce:(NSString *)description {
    @synchronized (self) {
        if (_reportedUnavailableRenderer) return;
        _reportedUnavailableRenderer = YES;
    }
    NSError *error = [NSError errorWithDomain:VCScreenCaptureErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
    VCScreenErrorCallback callback = self.errorCallback;
    if (callback) callback(error);
    NSLog(@"[VirtualCamPro] Screen capture unavailable: %@", description);
}

- (void)releasePool {
    CVPixelBufferPoolRef pool = NULL;
    os_unfair_lock_lock(&_lock);
    pool = _pool;
    _pool = NULL;
    _poolWidth = 0;
    _poolHeight = 0;
    os_unfair_lock_unlock(&_lock);
    if (pool) CVPixelBufferPoolRelease(pool);
}

- (void)handleMemoryPressure {
    os_unfair_lock_lock(&_lock);
    if (_pool) CVPixelBufferPoolFlush(_pool, kCVPixelBufferPoolFlushExcessBuffers);
    os_unfair_lock_unlock(&_lock);
}

- (void)dealloc { [self stop]; }
@end
