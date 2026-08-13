#import "VCStreamCoordinator.h"

#import "AVAssetStreamAdapter.h"
#import "VCFrameConverter.h"
#import "VCPreferences.h"
#import <notify.h>
#import <os/lock.h>

static const char *VCStreamStatusNotificationName =
    "com.murkaska.virtualcampro/stream.status";
static const int VCInvalidNotifyToken = -1;

typedef NS_ENUM(uint64_t, VCStreamStatus) {
    VCStreamStatusDisabled = 0,
    VCStreamStatusConnecting = 1,
    VCStreamStatusReceiving = 2,
    VCStreamStatusError = 3,
    VCStreamStatusHoldingLastFrame = 4,
};

@interface VCStreamCoordinator () {
    os_unfair_lock _stateLock;
    CVPixelBufferRef _latestPixelBuffer;
    CFAbsoluteTime _latestFrameTime;
    CVPixelBufferRef _latestCompatibilityOutputPixelBuffer;
    CFAbsoluteTime _latestCompatibilityOutputTime;
    BOOL _compatibilityOutputPathActive;
    BOOL _replacementEnabled;
    BOOL _systemPipelineReplacementConfigured;
    NSInteger _configuredFPS;
    CGFloat _configuredJPEGQuality;
    BOOL _configuredAspectFill;
    NSInteger _configuredSourceRotation;
    BOOL _configuredMirrorSource;
    BOOL _configuredHoldLastFrame;
    NSTimeInterval _configuredStaleFrameTimeout;
    NSUInteger _preferencesRefreshGeneration;
    NSUInteger _streamGeneration;
    NSUInteger _transformGeneration;
    NSUInteger _frameProcessingGeneration;
    CVPixelBufferRef _pendingPixelBuffer;
    NSUInteger _pendingStreamGeneration;
    BOOL _frameProcessingScheduled;
    NSUInteger _coalescedFrameCount;
    CFAbsoluteTime _lastCoalescingLogTime;
    int _streamStatusToken;
    uint64_t _publishedStreamStatus;
    BOOL _loggedFirstFrame;
    BOOL _loggedStaleFrame;
}
@property (atomic, strong) AVAssetStreamAdapter *adapter;
@property (nonatomic, copy) NSURL *activeURL;
@property (nonatomic, assign) BOOL mediaServerProcess;
@property (nonatomic, strong) dispatch_source_t memoryPressureSource;
@property (nonatomic, strong) dispatch_queue_t frameProcessingQueue;
- (BOOL)hasUsableReplacementFrame;
@end

static void VCPreferencesDidChange(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    VCStreamCoordinator *coordinator = (__bridge VCStreamCoordinator *)observer;
    [coordinator refreshPreferencesAndStream];
}

@implementation VCStreamCoordinator

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateLock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        _configuredFPS = 60;
        _configuredJPEGQuality = 1.0;
        _configuredAspectFill = YES;
        _configuredSourceRotation = 0;
        _configuredMirrorSource = NO;
        _configuredHoldLastFrame = YES;
        _configuredStaleFrameTimeout = 8.0;
        _streamGeneration = 1;
        _transformGeneration = 1;
        _frameProcessingGeneration = 1;
        _streamStatusToken = VCInvalidNotifyToken;
        _publishedStreamStatus = ~(uint64_t)0;
        _frameProcessingQueue = dispatch_queue_create(
            "com.murkaska.virtualcampro.frame-processing",
            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (instancetype)sharedCoordinator {
    static VCStreamCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
        coordinator.mediaServerProcess = [NSProcessInfo.processInfo.processName isEqualToString:@"mediaserverd"];
    });
    return coordinator;
}

- (void)startMonitoring {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (self.mediaServerProcess &&
            notify_register_check(VCStreamStatusNotificationName,
                                  &self->_streamStatusToken) == NOTIFY_STATUS_OK) {
            [self publishStreamStatus:VCStreamStatusDisabled];
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        VCPreferencesDidChange,
                                        (__bridge CFStringRef)VCPreferencesChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        [self startMemoryPressureMonitoring];
        [self refreshPreferencesAndStream];
    });
}

- (void)publishStreamStatus:(VCStreamStatus)status {
    int statusToken = VCInvalidNotifyToken;
    os_unfair_lock_lock(&_stateLock);
    if (_publishedStreamStatus != status) {
        _publishedStreamStatus = status;
        statusToken = _streamStatusToken;
    }
    os_unfair_lock_unlock(&_stateLock);
    if (statusToken == VCInvalidNotifyToken) return;
    notify_set_state(statusToken, status);
    notify_post(VCStreamStatusNotificationName);
}

- (void)startMemoryPressureMonitoring {
    if (self.memoryPressureSource) return;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,
                                                       0,
                                                       DISPATCH_MEMORYPRESSURE_WARN |
                                                           DISPATCH_MEMORYPRESSURE_CRITICAL,
                                                       queue);
    if (!source) return;

    __weak VCStreamCoordinator *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        VCStreamCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        unsigned long pressure = dispatch_source_get_data(strongSelf.memoryPressureSource);
        VCFlushFrameConverterCaches(YES);
        [strongSelf.adapter handleMemoryPressure];
        if (pressure & DISPATCH_MEMORYPRESSURE_CRITICAL) {
            [strongSelf clearLatestPixelBuffer];
            [strongSelf publishStreamStatus:VCStreamStatusConnecting];
        }
        NSLog(@"[VirtualCamPro] Released conversion caches after %@ memory pressure",
              (pressure & DISPATCH_MEMORYPRESSURE_CRITICAL) ? @"critical" : @"warning");
    });
    self.memoryPressureSource = source;
    dispatch_resume(source);
}

- (BOOL)processMatchesPreferences:(VCPreferences *)preferences {
    return self.mediaServerProcess ? !preferences.compatibilityMode : preferences.compatibilityMode;
}

- (void)refreshPreferencesAndStream {
    os_unfair_lock_lock(&_stateLock);
    NSUInteger refreshGeneration = ++_preferencesRefreshGeneration;
    os_unfair_lock_unlock(&_stateLock);

    VCPreferences *preferences = [VCPreferences sharedPreferences];
    BOOL eligible = NO;
    BOOL systemPipelineReplacementConfigured = NO;
    NSURL *requestedURL = nil;
    NSInteger preferredFPS = 60;
    CGFloat jpegQuality = 1.0;
    BOOL aspectFill = YES;
    NSInteger sourceRotation = 0;
    BOOL mirrorSource = NO;
    NSInteger maximumPixelDimension = 1920;
    BOOL holdLastFrame = YES;
    NSTimeInterval staleFrameTimeout = 8.0;
    @synchronized (preferences) {
        [preferences reload];
        eligible = [self processMatchesPreferences:preferences];
        systemPipelineReplacementConfigured = preferences.isEnabled &&
            preferences.streamURL != nil && !preferences.compatibilityMode;
        requestedURL = (eligible && preferences.isEnabled) ? preferences.streamURL : nil;
        preferredFPS = preferences.preferredFPS;
        jpegQuality = preferences.jpegQuality;
        aspectFill = preferences.aspectFill;
        sourceRotation = preferences.sourceRotation;
        mirrorSource = preferences.mirrorSource;
        maximumPixelDimension = preferences.maximumPixelDimension;
        holdLastFrame = preferences.holdLastFrame;
        staleFrameTimeout = preferences.staleFrameTimeout;
    }

    // Photo hooks can run before the main-queue stream transition block. Publish
    // this read-only routing fact immediately so an early system-pipeline photo
    // is not mistaken for an inactive capture.
    os_unfair_lock_lock(&_stateLock);
    if (refreshGeneration == _preferencesRefreshGeneration) {
        _systemPipelineReplacementConfigured = systemPipelineReplacementConfigured;
    }
    os_unfair_lock_unlock(&_stateLock);

    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL sameActiveStream = requestedURL && self.adapter &&
            [self.activeURL isEqual:requestedURL];
        BOOL streamChanged = (requestedURL || self.activeURL) && !sameActiveStream;
        BOOL transformChanged = NO;
        NSUInteger streamGeneration = 0;
        os_unfair_lock_lock(&self->_stateLock);
        if (refreshGeneration != self->_preferencesRefreshGeneration) {
            os_unfair_lock_unlock(&self->_stateLock);
            return;
        }
        transformChanged = self->_configuredSourceRotation != sourceRotation ||
                           self->_configuredMirrorSource != mirrorSource;
        if (streamChanged) self->_streamGeneration++;
        if (transformChanged) self->_transformGeneration++;
        self->_replacementEnabled = requestedURL != nil;
        self->_systemPipelineReplacementConfigured = systemPipelineReplacementConfigured;
        self->_configuredFPS = preferredFPS;
        self->_configuredJPEGQuality = jpegQuality;
        self->_configuredAspectFill = aspectFill;
        self->_configuredSourceRotation = sourceRotation;
        self->_configuredMirrorSource = mirrorSource;
        self->_configuredHoldLastFrame = holdLastFrame;
        self->_configuredStaleFrameTimeout = staleFrameTimeout;
        streamGeneration = self->_streamGeneration;
        os_unfair_lock_unlock(&self->_stateLock);

        if (transformChanged && !streamChanged) {
            [self clearLatestPixelBuffer];
            if (requestedURL) [self publishStreamStatus:VCStreamStatusConnecting];
        }

        if (!requestedURL) {
            AVAssetStreamAdapter *oldAdapter = self.adapter;
            self.adapter = nil;
            self.activeURL = nil;
            oldAdapter.pixelBufferCallback = nil;
            oldAdapter.errorCallback = nil;
            [oldAdapter stopStreaming];
            [self clearLatestPixelBuffer];
            [self publishStreamStatus:VCStreamStatusDisabled];
            return;
        }

        if (self.adapter && [self.activeURL isEqual:requestedURL]) {
            self.adapter.preferredFPS = preferredFPS;
            self.adapter.maximumPixelDimension = maximumPixelDimension;
            if (!self.adapter.isRunning) {
                [self publishStreamStatus:VCStreamStatusConnecting];
                [self.adapter startStreaming];
            }
            return;
        }

        AVAssetStreamAdapter *oldAdapter = self.adapter;
        self.adapter = nil;
        oldAdapter.pixelBufferCallback = nil;
        oldAdapter.errorCallback = nil;
        [oldAdapter stopStreaming];
        [self clearLatestPixelBuffer];

        AVAssetStreamAdapter *adapter = [[AVAssetStreamAdapter alloc] initWithURL:requestedURL];
        adapter.preferredFPS = preferredFPS;
        adapter.maximumPixelDimension = maximumPixelDimension;
        __weak VCStreamCoordinator *weakSelf = self;
        adapter.pixelBufferCallback = ^(CVPixelBufferRef pixelBuffer) {
            VCStreamCoordinator *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf enqueueLatestPixelBuffer:pixelBuffer
                                streamGeneration:streamGeneration];
        };
        __weak AVAssetStreamAdapter *weakAdapter = adapter;
        adapter.errorCallback = ^(NSError *error) {
            VCStreamCoordinator *strongSelf = weakSelf;
            AVAssetStreamAdapter *strongAdapter = weakAdapter;
            if (!strongSelf || !strongAdapter || strongSelf.adapter != strongAdapter) return;
            [strongSelf publishStreamStatus:[strongSelf hasUsableReplacementFrame]
                ? VCStreamStatusHoldingLastFrame
                : VCStreamStatusError];
            NSLog(@"[VirtualCamPro] Stream error: %@", error.localizedDescription);
        };

        self.activeURL = requestedURL;
        self.adapter = adapter;
        [self publishStreamStatus:VCStreamStatusConnecting];
        [adapter startStreaming];
    });
}

- (void)enqueueLatestPixelBuffer:(CVPixelBufferRef)pixelBuffer
                 streamGeneration:(NSUInteger)streamGeneration {
    if (!pixelBuffer) return;
    CVPixelBufferRef retainedBuffer = CVPixelBufferRetain(pixelBuffer);
    CVPixelBufferRef replacedPendingBuffer = NULL;
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_stateLock);
    if (!_replacementEnabled || streamGeneration != _streamGeneration) {
        os_unfair_lock_unlock(&_stateLock);
        CVPixelBufferRelease(retainedBuffer);
        return;
    }
    replacedPendingBuffer = _pendingPixelBuffer;
    _pendingPixelBuffer = retainedBuffer;
    _pendingStreamGeneration = streamGeneration;
    if (replacedPendingBuffer) _coalescedFrameCount++;
    if (!_frameProcessingScheduled) {
        _frameProcessingScheduled = YES;
        shouldSchedule = YES;
    }
    os_unfair_lock_unlock(&_stateLock);
    if (replacedPendingBuffer) CVPixelBufferRelease(replacedPendingBuffer);
    if (!shouldSchedule) return;

    __weak VCStreamCoordinator *weakSelf = self;
    dispatch_async(self.frameProcessingQueue, ^{
        [weakSelf processPendingPixelBuffers];
    });
}

- (void)processPendingPixelBuffers {
    while (YES) {
        CVPixelBufferRef pixelBuffer = NULL;
        NSUInteger streamGeneration = 0;
        NSUInteger processingGeneration = 0;
        NSUInteger coalescedFrameCount = 0;
        os_unfair_lock_lock(&_stateLock);
        pixelBuffer = _pendingPixelBuffer;
        _pendingPixelBuffer = NULL;
        if (!pixelBuffer) {
            _frameProcessingScheduled = NO;
            os_unfair_lock_unlock(&_stateLock);
            return;
        }
        streamGeneration = _pendingStreamGeneration;
        processingGeneration = _frameProcessingGeneration;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (_coalescedFrameCount > 0 &&
            (_lastCoalescingLogTime <= 0 || now - _lastCoalescingLogTime >= 10.0)) {
            coalescedFrameCount = _coalescedFrameCount;
            _coalescedFrameCount = 0;
            _lastCoalescingLogTime = now;
        }
        os_unfair_lock_unlock(&_stateLock);

        if (coalescedFrameCount > 0) {
            NSLog(@"[VirtualCamPro] Coalesced %lu intermediate network frames to preserve low latency",
                  (unsigned long)coalescedFrameCount);
        }
        [self storeLatestPixelBuffer:pixelBuffer
                     streamGeneration:streamGeneration
                 processingGeneration:processingGeneration];
        CVPixelBufferRelease(pixelBuffer);
    }
}

- (void)storeLatestPixelBuffer:(CVPixelBufferRef)pixelBuffer
               streamGeneration:(NSUInteger)streamGeneration
           processingGeneration:(NSUInteger)processingGeneration {
    if (!pixelBuffer) return;
    NSInteger sourceRotation = 0;
    BOOL mirrorSource = NO;
    NSUInteger transformGeneration = 0;
    os_unfair_lock_lock(&_stateLock);
    if (!_replacementEnabled || streamGeneration != _streamGeneration ||
        processingGeneration != _frameProcessingGeneration) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    sourceRotation = _configuredSourceRotation;
    mirrorSource = _configuredMirrorSource;
    transformGeneration = _transformGeneration;
    os_unfair_lock_unlock(&_stateLock);

    CVPixelBufferRef retainedBuffer = VCCopyPixelBufferApplyingOrientation(pixelBuffer,
                                                                            sourceRotation,
                                                                            mirrorSource);
    if (!retainedBuffer) retainedBuffer = CVPixelBufferRetain(pixelBuffer);
    size_t retainedWidth = CVPixelBufferGetWidth(retainedBuffer);
    size_t retainedHeight = CVPixelBufferGetHeight(retainedBuffer);
    OSType retainedPixelFormat = CVPixelBufferGetPixelFormatType(retainedBuffer);
    NSInteger configuredFPS = 60;
    CVPixelBufferRef oldBuffer = NULL;
    BOOL shouldLogFirstFrame = NO;
    os_unfair_lock_lock(&_stateLock);
    if (!_replacementEnabled || streamGeneration != _streamGeneration ||
        transformGeneration != _transformGeneration ||
        processingGeneration != _frameProcessingGeneration) {
        os_unfair_lock_unlock(&_stateLock);
        CVPixelBufferRelease(retainedBuffer);
        return;
    }
    shouldLogFirstFrame = !_loggedFirstFrame;
    configuredFPS = _configuredFPS;
    _loggedFirstFrame = YES;
    _loggedStaleFrame = NO;
    oldBuffer = _latestPixelBuffer;
    _latestPixelBuffer = retainedBuffer;
    _latestFrameTime = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&_stateLock);
    if (oldBuffer) CVPixelBufferRelease(oldBuffer);
    [self publishStreamStatus:VCStreamStatusReceiving];
    if (shouldLogFirstFrame) {
        NSLog(@"[VirtualCamPro] First network frame: %zux%zu pixel format %u, rotation %ld, "
               @"mirrored %@, decode/preview cap %ld FPS",
              retainedWidth,
              retainedHeight,
              (unsigned int)retainedPixelFormat,
              (long)sourceRotation,
              mirrorSource ? @"yes" : @"no",
              (long)configuredFPS);
    }
}

- (void)clearLatestPixelBuffer {
    CVPixelBufferRef oldBuffer = NULL;
    CVPixelBufferRef pendingBuffer = NULL;
    CVPixelBufferRef compatibilityOutputBuffer = NULL;
    os_unfair_lock_lock(&_stateLock);
    oldBuffer = _latestPixelBuffer;
    pendingBuffer = _pendingPixelBuffer;
    compatibilityOutputBuffer = _latestCompatibilityOutputPixelBuffer;
    _latestPixelBuffer = NULL;
    _pendingPixelBuffer = NULL;
    _latestCompatibilityOutputPixelBuffer = NULL;
    _latestFrameTime = 0;
    _latestCompatibilityOutputTime = 0;
    _compatibilityOutputPathActive = NO;
    _frameProcessingGeneration++;
    _coalescedFrameCount = 0;
    _loggedFirstFrame = NO;
    _loggedStaleFrame = NO;
    os_unfair_lock_unlock(&_stateLock);
    if (oldBuffer) CVPixelBufferRelease(oldBuffer);
    if (pendingBuffer) CVPixelBufferRelease(pendingBuffer);
    if (compatibilityOutputBuffer) CVPixelBufferRelease(compatibilityOutputBuffer);
    VCResetFrameConverterCache();
}

- (void)publishCompatibilityOutputPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef retainedBuffer = pixelBuffer ? CVPixelBufferRetain(pixelBuffer) : NULL;
    CVPixelBufferRef oldBuffer = NULL;
    os_unfair_lock_lock(&_stateLock);
    oldBuffer = _latestCompatibilityOutputPixelBuffer;
    _latestCompatibilityOutputPixelBuffer = retainedBuffer;
    _latestCompatibilityOutputTime = CFAbsoluteTimeGetCurrent();
    _compatibilityOutputPathActive = YES;
    os_unfair_lock_unlock(&_stateLock);
    if (oldBuffer) CVPixelBufferRelease(oldBuffer);
}

- (CVPixelBufferRef)copyLatestCompatibilityOutputPixelBufferWithActivePath:
    (BOOL *)activePath {
    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferRef staleBuffer = NULL;
    os_unfair_lock_lock(&_stateLock);
    BOOL recentOutputPath = _replacementEnabled && _compatibilityOutputPathActive &&
        _latestCompatibilityOutputTime > 0 &&
        CFAbsoluteTimeGetCurrent() - _latestCompatibilityOutputTime <= 2.0;
    if (!recentOutputPath && _compatibilityOutputPathActive) {
        staleBuffer = _latestCompatibilityOutputPixelBuffer;
        _latestCompatibilityOutputPixelBuffer = NULL;
        _latestCompatibilityOutputTime = 0;
        _compatibilityOutputPathActive = NO;
    }
    if (activePath) *activePath = recentOutputPath;
    if (recentOutputPath && _latestCompatibilityOutputPixelBuffer) {
        pixelBuffer = CVPixelBufferRetain(_latestCompatibilityOutputPixelBuffer);
    }
    os_unfair_lock_unlock(&_stateLock);
    if (staleBuffer) CVPixelBufferRelease(staleBuffer);
    return pixelBuffer;
}

- (CVPixelBufferRef)copyLatestPixelBuffer {
    return [self copyLatestPixelBufferWithAspectFill:NULL preferredFPS:NULL];
}

- (BOOL)hasUsableReplacementFrame {
    os_unfair_lock_lock(&_stateLock);
    BOOL usable = _replacementEnabled && _latestPixelBuffer &&
        (_configuredHoldLastFrame ||
         (_latestFrameTime > 0 &&
          CFAbsoluteTimeGetCurrent() - _latestFrameTime <= _configuredStaleFrameTimeout));
    os_unfair_lock_unlock(&_stateLock);
    return usable;
}

- (CVPixelBufferRef)copyLatestPixelBufferWithAspectFill:(BOOL *)aspectFill
                                           preferredFPS:(NSInteger *)preferredFPS {
    BOOL shouldLogStaleFrame = NO;
    CVPixelBufferRef pixelBuffer = NULL;
    os_unfair_lock_lock(&_stateLock);
    if (aspectFill) *aspectFill = _configuredAspectFill;
    if (preferredFPS) *preferredFPS = _configuredFPS;
    if (_replacementEnabled) {
        if (!_configuredHoldLastFrame && _latestFrameTime > 0 &&
            CFAbsoluteTimeGetCurrent() - _latestFrameTime > _configuredStaleFrameTimeout) {
            shouldLogStaleFrame = !_loggedStaleFrame;
            _loggedStaleFrame = YES;
        } else {
            pixelBuffer = _latestPixelBuffer ? CVPixelBufferRetain(_latestPixelBuffer) : NULL;
        }
    }
    os_unfair_lock_unlock(&_stateLock);
    if (shouldLogStaleFrame) {
        NSLog(@"[VirtualCamPro] Latest network frame is stale; preserving real camera output");
    }
    return pixelBuffer;
}

- (BOOL)isReplacementActive {
    os_unfair_lock_lock(&_stateLock);
    BOOL value = _replacementEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (BOOL)isSystemPipelineReplacementConfigured {
    os_unfair_lock_lock(&_stateLock);
    BOOL value = _systemPipelineReplacementConfigured;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (NSInteger)preferredFPS {
    os_unfair_lock_lock(&_stateLock);
    NSInteger value = _configuredFPS;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (CGFloat)jpegQuality {
    os_unfair_lock_lock(&_stateLock);
    CGFloat value = _configuredJPEGQuality;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (BOOL)aspectFill {
    os_unfair_lock_lock(&_stateLock);
    BOOL value = _configuredAspectFill;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (BOOL)holdLastFrame {
    os_unfair_lock_lock(&_stateLock);
    BOOL value = _configuredHoldLastFrame;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (NSTimeInterval)staleFrameTimeout {
    os_unfair_lock_lock(&_stateLock);
    NSTimeInterval value = _configuredStaleFrameTimeout;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
    [self.adapter stopStreaming];
    [self clearLatestPixelBuffer];
    if (self.memoryPressureSource) dispatch_source_cancel(self.memoryPressureSource);
    if (_streamStatusToken != VCInvalidNotifyToken) notify_cancel(_streamStatusToken);
}

@end
