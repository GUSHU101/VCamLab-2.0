#import "AVAssetStreamAdapter.h"
#import "VCJPEGParser.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <os/lock.h>

static NSString * const VCStreamErrorDomain = @"com.murkaska.virtualcampro.stream";
static void *VCPlayerItemStatusContext = &VCPlayerItemStatusContext;
static const NSUInteger VCMaximumJPEGFrameBytes = 24 * 1024 * 1024;
static const NSUInteger VCMaximumMJPEGBufferBytes = 32 * 1024 * 1024;
static const NSUInteger VCMJPEGBufferCompactionThresholdBytes = 1024 * 1024;
static const NSUInteger VCMaximumOutstandingMJPEGBuffers = 6;
static const NSInteger VCMaximumPreferredFPS = 240;

static CGColorSpaceRef VCSharedRGBColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return colorSpace;
}

@interface AVAssetStreamAdapter () {
    CVPixelBufferPoolRef _mjpegPixelBufferPool;
    size_t _mjpegPoolWidth;
    size_t _mjpegPoolHeight;
    CFAbsoluteTime _lastMJPEGDecodeTime;
    CFAbsoluteTime _lastMJPEGErrorReportTime;
    VCJPEGParserState _mjpegParserState;
    NSUInteger _mjpegBufferOffset;
    os_unfair_lock _mjpegReceiveLock;
}
@property (nonatomic, strong, readwrite) NSURL *streamURL;
@property (nonatomic, assign, readwrite) VCStreamProtocol streamProtocol;
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (atomic, assign, readwrite, getter=isConnecting) BOOL connecting;
@property (atomic, assign, readwrite) NSUInteger frameCount;
@property (atomic, assign, readwrite) CFAbsoluteTime lastFrameTime;

@property (atomic, strong) NSURLSession *session;
@property (atomic, strong) NSURLSessionDataTask *task;
@property (atomic, strong) NSOperationQueue *delegateQueue;
@property (atomic, strong) NSMutableData *imageData;

@property (atomic, strong) AVPlayer *hlsPlayer;
@property (atomic, strong) AVPlayerItem *hlsPlayerItem;
@property (atomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) dispatch_source_t frameTimer;
@property (nonatomic, strong) dispatch_source_t healthTimer;
@property (nonatomic, strong) dispatch_queue_t hlsFrameQueue;
@property (nonatomic, assign) BOOL observingPlayerItem;

@property (atomic, assign) NSUInteger reconnectAttempt;
@property (atomic, assign) NSUInteger lifecycleGeneration;
@property (atomic, assign) BOOL reconnectScheduled;
@property (atomic, assign) CFAbsoluteTime attemptStartTime;

- (CVPixelBufferPoolRef)mjpegPixelBufferPoolForWidth:(size_t)width
                                              height:(size_t)height;
- (void)releaseMJPEGPixelBufferPool;
- (void)resetMJPEGReceiveBufferLocked;
- (void)compactMJPEGReceiveBufferLockedIfNeeded:(BOOL)force;
- (void)reportMalformedMJPEGStream:(NSString *)description;
@end

@implementation AVAssetStreamAdapter

@synthesize preferredFPS = _preferredFPS;

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _streamURL = url;
        _preferredFPS = 60;
        _maximumPixelDimension = 1920;
        _mjpegReceiveLock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        dispatch_queue_attr_t hlsQueueAttributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                     QOS_CLASS_USER_INTERACTIVE,
                                                     0);
        _hlsFrameQueue = dispatch_queue_create("com.murkaska.virtualcampro.hls-frames",
                                               hlsQueueAttributes);
        NSString *absoluteString = url.absoluteString.lowercaseString;
        _streamProtocol = [absoluteString containsString:@".m3u8"] ? VCStreamProtocolHLS : VCStreamProtocolMJPEG;
    }
    return self;
}

- (void)setPreferredFPS:(NSInteger)preferredFPS {
    NSInteger clampedFPS = MAX(1, MIN(VCMaximumPreferredFPS, preferredFPS));
    @synchronized (self) {
        _preferredFPS = clampedFPS;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.frameTimer) return;
        uint64_t interval = NSEC_PER_SEC / (uint64_t)clampedFPS;
        dispatch_source_set_timer(self.frameTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  interval,
                                  interval / 10);
    });
}

- (NSInteger)preferredFPS {
    @synchronized (self) {
        return _preferredFPS;
    }
}

- (void)startStreaming {
    @synchronized (self) {
        if (self.running) return;
        self.running = YES;
        self.connecting = YES;
        self.reconnectAttempt = 0;
        self.reconnectScheduled = NO;
        self.frameCount = 0;
        self.lastFrameTime = 0;
        self.attemptStartTime = CFAbsoluteTimeGetCurrent();
        self.lifecycleGeneration++;
    }

    [self startHealthMonitor];

    if (self.streamProtocol == VCStreamProtocolHLS) {
        [self startHLSStream];
    } else {
        [self startMJPEGStream];
    }
}

- (void)stopStreaming {
    @synchronized (self) {
        if (!self.running && !self.connecting) return;
        self.running = NO;
        self.connecting = NO;
        self.reconnectScheduled = NO;
        self.lifecycleGeneration++;
    }

    [self stopMJPEGStream];
    [self stopHLSStream];
    [self stopHealthMonitor];
}

- (void)handleMemoryPressure {
    NSOperationQueue *queue = self.delegateQueue;
    if (queue) {
        __weak AVAssetStreamAdapter *weakSelf = self;
        [queue addOperationWithBlock:^{
            AVAssetStreamAdapter *strongSelf = weakSelf;
            if (!strongSelf) return;
            os_unfair_lock_lock(&strongSelf->_mjpegReceiveLock);
            [strongSelf resetMJPEGReceiveBufferLocked];
            [strongSelf releaseMJPEGPixelBufferPool];
            os_unfair_lock_unlock(&strongSelf->_mjpegReceiveLock);
        }];
    } else {
        os_unfair_lock_lock(&_mjpegReceiveLock);
        [self resetMJPEGReceiveBufferLocked];
        [self releaseMJPEGPixelBufferPool];
        os_unfair_lock_unlock(&_mjpegReceiveLock);
    }
}

#pragma mark - Shared state

- (void)deliverPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;

    AVAssetPixelBufferCallback callback = nil;
    @synchronized (self) {
        if (!self.running) return;
        self.frameCount++;
        self.lastFrameTime = CFAbsoluteTimeGetCurrent();
        self.connecting = NO;
        self.reconnectAttempt = 0;
        if (self.reconnectScheduled) {
            self.reconnectScheduled = NO;
            self.lifecycleGeneration++;
        }
        callback = [self.pixelBufferCallback copy];
    }
    if (callback) callback(pixelBuffer);
}

- (void)reportError:(NSError *)error {
    AVAssetErrorCallback callback = [self.errorCallback copy];
    if (!error || !callback) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        callback(error);
    });
}

- (void)scheduleReconnectAfterError:(NSError *)error {
    NSUInteger attempt;
    NSUInteger generation;
    @synchronized (self) {
        if (!self.running || self.reconnectScheduled) return;
        self.reconnectScheduled = YES;
        self.connecting = YES;
        attempt = MIN(self.reconnectAttempt, 5);
        self.reconnectAttempt++;
        generation = self.lifecycleGeneration;
    }
    [self reportError:error];

    NSTimeInterval delay = MIN(30.0, pow(2.0, attempt));

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (!self.running || generation != self.lifecycleGeneration) return;
            self.reconnectScheduled = NO;
        }

        if (self.streamProtocol == VCStreamProtocolHLS) {
            [self stopHLSStreamImmediately];
            [self startHLSStreamImmediately];
        } else {
            [self stopMJPEGStream];
            [self startMJPEGStream];
        }
    });
}

- (void)startHealthMonitor {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.running || self.healthTimer) return;
        self.healthTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                  0,
                                                  0,
                                                  dispatch_get_main_queue());
        dispatch_source_set_timer(self.healthTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC,
                                  NSEC_PER_SEC / 5);
        __weak AVAssetStreamAdapter *weakSelf = self;
        dispatch_source_set_event_handler(self.healthTimer, ^{
            [weakSelf verifyStreamHealth];
        });
        dispatch_resume(self.healthTimer);
    });
}

- (void)stopHealthMonitor {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.healthTimer) return;
        dispatch_source_cancel(self.healthTimer);
        self.healthTimer = nil;
    });
}

- (void)verifyStreamHealth {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime referenceTime;
    NSTimeInterval timeout;
    BOOL receivedFrameInThisAttempt;
    @synchronized (self) {
        if (!self.running || self.reconnectScheduled) return;
        receivedFrameInThisAttempt = self.lastFrameTime > 0;
        if (receivedFrameInThisAttempt) {
            referenceTime = self.lastFrameTime;
            timeout = 8.0;
        } else {
            referenceTime = self.attemptStartTime;
            timeout = 15.0;
        }
    }
    if (referenceTime <= 0 || now - referenceTime <= timeout) return;

    NSString *description = receivedFrameInThisAttempt
        ? @"Stream stopped producing frames"
        : @"Stream did not produce its first frame";
    NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
    [self scheduleReconnectAfterError:error];
}

#pragma mark - HLS

- (void)startHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.running) return;
        [self startHLSStreamImmediately];
    });
}

- (void)startHLSStreamImmediately {
    if (!self.running || self.hlsPlayerItem) return;
    @synchronized (self) {
        self.attemptStartTime = CFAbsoluteTimeGetCurrent();
        self.lastFrameTime = 0;
    }

    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.streamURL];
    item.preferredForwardBufferDuration = 1.0;
    AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc]
                                       initWithPixelBufferAttributes:pixelBufferAttributes];
    output.suppressesPlayerRendering = YES;
    [item addOutput:output];

    self.hlsPlayerItem = item;
    self.videoOutput = output;
    self.hlsPlayer = [AVPlayer playerWithPlayerItem:item];
    self.hlsPlayer.automaticallyWaitsToMinimizeStalling = NO;
    self.hlsPlayer.muted = YES;

    [item addObserver:self
           forKeyPath:@"status"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:VCPlayerItemStatusContext];
    self.observingPlayerItem = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(playerItemDidReachEnd:)
                   name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [center addObserver:self selector:@selector(playerItemPlaybackStalled:)
                   name:AVPlayerItemPlaybackStalledNotification object:item];

    NSInteger framesPerSecond = MAX(1, MIN(VCMaximumPreferredFPS, self.preferredFPS));
    uint64_t interval = NSEC_PER_SEC / (uint64_t)framesPerSecond;
    self.frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                              0,
                                              0,
                                              self.hlsFrameQueue);
    dispatch_source_set_timer(self.frameTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval,
                              interval / 10);
    __weak AVAssetStreamAdapter *weakSelf = self;
    dispatch_source_set_event_handler(self.frameTimer, ^{
        [weakSelf pullHLSFrame];
    });
    dispatch_resume(self.frameTimer);
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != VCPlayerItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    AVPlayerItem *item = object;
    if (item != self.hlsPlayerItem || !self.running) return;

    if (item.status == AVPlayerItemStatusReadyToPlay) {
        @synchronized (self) {
            self.connecting = NO;
            self.reconnectAttempt = 0;
        }
        [self.hlsPlayer play];
    } else if (item.status == AVPlayerItemStatusFailed) {
        NSError *error = item.error ?: [NSError errorWithDomain:VCStreamErrorDomain
                                                               code:1001
                                                           userInfo:@{NSLocalizedDescriptionKey: @"HLS stream failed to load"}];
        [self scheduleReconnectAfterError:error];
    }
}

- (void)pullHLSFrame {
    AVPlayerItem *playerItem = self.hlsPlayerItem;
    AVPlayerItemVideoOutput *videoOutput = self.videoOutput;
    AVPlayer *player = self.hlsPlayer;
    if (!self.running || !playerItem || !videoOutput ||
        playerItem.status != AVPlayerItemStatusReadyToPlay) return;

    CMTime itemTime = [videoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_VALID(itemTime)) itemTime = player.currentTime;
    if (![videoOutput hasNewPixelBufferForItemTime:itemTime]) return;

    CVPixelBufferRef pixelBuffer = [videoOutput copyPixelBufferForItemTime:itemTime
                                                        itemTimeForDisplay:nil];
    if (!pixelBuffer) return;
    [self deliverPixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    if (!self.running) return;
    [self.hlsPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
        if (finished && self.running) [self.hlsPlayer play];
    }];
}

- (void)playerItemPlaybackStalled:(NSNotification *)notification {
    NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"HLS playback stalled"}];
    [self scheduleReconnectAfterError:error];
}

- (void)stopHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopHLSStreamImmediately];
    });
}

- (void)stopHLSStreamImmediately {
    if (self.observingPlayerItem && self.hlsPlayerItem) {
        [self.hlsPlayerItem removeObserver:self forKeyPath:@"status" context:VCPlayerItemStatusContext];
        self.observingPlayerItem = NO;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:self.hlsPlayerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemPlaybackStalledNotification
                                                  object:self.hlsPlayerItem];
    if (self.frameTimer) {
        dispatch_source_cancel(self.frameTimer);
        self.frameTimer = nil;
    }
    [self.hlsPlayer pause];
    self.hlsPlayer = nil;
    self.hlsPlayerItem = nil;
    self.videoOutput = nil;
}

#pragma mark - MJPEG

- (void)startMJPEGStream {
    if (!self.running || self.task) return;
    @synchronized (self) {
        self.attemptStartTime = CFAbsoluteTimeGetCurrent();
        self.lastFrameTime = 0;
    }
    os_unfair_lock_lock(&_mjpegReceiveLock);
    _lastMJPEGDecodeTime = 0;
    _lastMJPEGErrorReportTime = 0;
    self.imageData = [NSMutableData data];
    [self resetMJPEGReceiveBufferLocked];
    os_unfair_lock_unlock(&_mjpegReceiveLock);

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 20.0;
    // A multipart response is intentionally long-lived. Reconnect once a day so a
    // half-open connection cannot survive forever without exercising recovery.
    configuration.timeoutIntervalForResource = 24.0 * 60.0 * 60.0;
    configuration.HTTPMaximumConnectionsPerHost = 1;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    self.delegateQueue = [[NSOperationQueue alloc] init];
    self.delegateQueue.maxConcurrentOperationCount = 1;
    self.delegateQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    self.session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:self.delegateQueue];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.streamURL];
    [request setValue:@"multipart/x-mixed-replace,image/jpeg;q=0.9,*/*;q=0.1"
   forHTTPHeaderField:@"Accept"];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)stopMJPEGStream {
    NSURLSessionDataTask *task = self.task;
    NSURLSession *session = self.session;
    self.task = nil;
    self.session = nil;
    self.delegateQueue = nil;
    os_unfair_lock_lock(&_mjpegReceiveLock);
    self.imageData = nil;
    [self resetMJPEGReceiveBufferLocked];
    os_unfair_lock_unlock(&_mjpegReceiveLock);
    [task cancel];
    [session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if (session != self.session || dataTask != self.task || !self.running) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
                                         ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    if (httpResponse && (statusCode < 200 || statusCode >= 300)) {
        NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                         code:statusCode
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"MJPEG server returned HTTP %ld", (long)statusCode]}];
        completionHandler(NSURLSessionResponseCancel);
        [self scheduleReconnectAfterError:error];
        return;
    }

    NSString *mimeType = response.MIMEType.lowercaseString;
    if ([mimeType isEqualToString:@"text/html"] ||
        [mimeType isEqualToString:@"application/json"] ||
        [mimeType containsString:@"mpegurl"]) {
        NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                         code:1005
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                        @"Unexpected MJPEG content type: %@",
                                                        mimeType]}];
        completionHandler(NSURLSessionResponseCancel);
        [self scheduleReconnectAfterError:error];
        return;
    }

    @synchronized (self) {
        self.connecting = NO;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (CVPixelBufferRef)copyPixelBufferFromJPEGData:(NSData *)jpegData CF_RETURNS_RETAINED {
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
    if (!imageSource) return NULL;
    NSDictionary *decodeOptions = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1280, MIN(3840, self.maximumPixelDimension))),
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource,
                                                              0,
                                                              (__bridge CFDictionaryRef)decodeOptions);
    CFRelease(imageSource);
    if (!cgImage) return NULL;

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0 || width > 4096 || height > 4096 || width * height > 16000000) {
        CGImageRelease(cgImage);
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferPoolRef pool = [self mjpegPixelBufferPoolForWidth:width height:height];
    static NSDictionary *allocationAttributes;
    static dispatch_once_t allocationAttributesToken;
    dispatch_once(&allocationAttributesToken, ^{
        allocationAttributes = @{
            (id)kCVPixelBufferPoolAllocationThresholdKey:
                @(VCMaximumOutstandingMJPEGBuffers),
        };
    });
    CVReturn result = pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                                kCFAllocatorDefault,
                                pool,
                                (__bridge CFDictionaryRef)allocationAttributes,
                                &pixelBuffer)
                           : kCVReturnInvalidArgument;
    if (result != kCVReturnSuccess || !pixelBuffer) {
        CGImageRelease(cgImage);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = VCSharedRGBColorSpace();
    CGContextRef context = CGBitmapContextCreate(baseAddress,
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

    if (!context) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        CGImageRelease(cgImage);
        return NULL;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    CGImageRelease(cgImage);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (CVPixelBufferPoolRef)mjpegPixelBufferPoolForWidth:(size_t)width
                                              height:(size_t)height {
    if (_mjpegPixelBufferPool && _mjpegPoolWidth == width && _mjpegPoolHeight == height) {
        return _mjpegPixelBufferPool;
    }

    if (_mjpegPixelBufferPool) {
        CVPixelBufferPoolRelease(_mjpegPixelBufferPool);
        _mjpegPixelBufferPool = NULL;
    }
    _mjpegPoolWidth = 0;
    _mjpegPoolHeight = 0;

    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                               (__bridge CFDictionaryRef)poolAttributes,
                                               (__bridge CFDictionaryRef)bufferAttributes,
                                               &_mjpegPixelBufferPool);
    if (result != kCVReturnSuccess || !_mjpegPixelBufferPool) return NULL;
    _mjpegPoolWidth = width;
    _mjpegPoolHeight = height;
    return _mjpegPixelBufferPool;
}

- (void)releaseMJPEGPixelBufferPool {
    if (_mjpegPixelBufferPool) {
        CVPixelBufferPoolFlush(_mjpegPixelBufferPool,
                               kCVPixelBufferPoolFlushExcessBuffers);
        CVPixelBufferPoolRelease(_mjpegPixelBufferPool);
        _mjpegPixelBufferPool = NULL;
    }
    _mjpegPoolWidth = 0;
    _mjpegPoolHeight = 0;
}

- (void)resetMJPEGReceiveBufferLocked {
    [self.imageData setLength:0];
    _mjpegBufferOffset = 0;
    VCJPEGParserReset(&_mjpegParserState);
}

- (void)compactMJPEGReceiveBufferLockedIfNeeded:(BOOL)force {
    NSMutableData *imageData = self.imageData;
    if (!imageData || _mjpegBufferOffset == 0) return;
    if (_mjpegBufferOffset >= imageData.length) {
        [imageData setLength:0];
        _mjpegBufferOffset = 0;
        return;
    }
    if (!force && _mjpegBufferOffset < VCMJPEGBufferCompactionThresholdBytes) return;
    [imageData replaceBytesInRange:NSMakeRange(0, _mjpegBufferOffset)
                         withBytes:NULL
                            length:0];
    _mjpegBufferOffset = 0;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (session != self.session || dataTask != self.task || !self.running || data.length == 0) return;
    CVPixelBufferRef pixelBuffer = NULL;
    os_unfair_lock_lock(&_mjpegReceiveLock);
    if (session != self.session || dataTask != self.task || !self.running) {
        os_unfair_lock_unlock(&_mjpegReceiveLock);
        return;
    }
    NSMutableData *imageData = self.imageData;
    if (!imageData) {
        os_unfair_lock_unlock(&_mjpegReceiveLock);
        return;
    }

    if (_mjpegBufferOffset > imageData.length) {
        [self resetMJPEGReceiveBufferLocked];
    } else if (_mjpegBufferOffset > 0 &&
               (imageData.length > VCMaximumMJPEGBufferBytes - MIN(data.length,
                                                                    VCMaximumMJPEGBufferBytes) ||
                _mjpegBufferOffset >= VCMJPEGBufferCompactionThresholdBytes)) {
        [self compactMJPEGReceiveBufferLockedIfNeeded:YES];
    }
    NSUInteger activeBufferLength = imageData.length - _mjpegBufferOffset;
    if (data.length > VCMaximumMJPEGBufferBytes ||
        activeBufferLength > VCMaximumMJPEGBufferBytes - data.length) {
        [self resetMJPEGReceiveBufferLocked];
        [self reportMalformedMJPEGStream:@"MJPEG receive buffer exceeded its safety limit"];
        if (data.length > VCMaximumMJPEGBufferBytes) {
            os_unfair_lock_unlock(&_mjpegReceiveLock);
            return;
        }
    }
    [imageData appendData:data];

    CFAbsoluteTime decodeWindowTime = CFAbsoluteTimeGetCurrent();
    NSTimeInterval minimumInterval = 1.0 / MAX(1, self.preferredFPS);
    BOOL decodeWindowOpen = _lastMJPEGDecodeTime <= 0 ||
        decodeWindowTime - _lastMJPEGDecodeTime >= minimumInterval * 0.85;
    NSData *latestJPEGData = nil;

    static NSData *startMarker;
    static dispatch_once_t markerToken;
    dispatch_once(&markerToken, ^{
        static const unsigned char startBytes[] = {0xFF, 0xD8};
        startMarker = [NSData dataWithBytes:startBytes length:sizeof(startBytes)];
    });

    while (imageData.length - _mjpegBufferOffset >= 2) {
        NSRange fullRange = NSMakeRange(_mjpegBufferOffset,
                                       imageData.length - _mjpegBufferOffset);
        NSRange startRange = [imageData rangeOfData:startMarker options:0 range:fullRange];
        if (startRange.location == NSNotFound) {
            unsigned char trailingByte = ((const unsigned char *)imageData.bytes)[imageData.length - 1];
            [self resetMJPEGReceiveBufferLocked];
            if (trailingByte == 0xFF) [imageData appendBytes:&trailingByte length:1];
            break;
        }

        if (startRange.location > _mjpegBufferOffset) {
            _mjpegBufferOffset = startRange.location;
            VCJPEGParserReset(&_mjpegParserState);
        }

        NSUInteger availableImageBytes = imageData.length - _mjpegBufferOffset;
        const uint8_t *imageBytes = (const uint8_t *)imageData.bytes + _mjpegBufferOffset;
        size_t parsedImageLength = 0;
        VCJPEGParserResult parserResult = VCJPEGParserConsume(imageBytes,
                                                              availableImageBytes,
                                                              &_mjpegParserState,
                                                              &parsedImageLength);
        if (parserResult == VCJPEGParserResultInvalid) {
            _mjpegBufferOffset += startMarker.length;
            VCJPEGParserReset(&_mjpegParserState);
            [self compactMJPEGReceiveBufferLockedIfNeeded:NO];
            [self reportMalformedMJPEGStream:@"MJPEG stream contained an invalid JPEG frame"];
            continue;
        }
        if (parserResult == VCJPEGParserResultNeedMoreData) {
            if (availableImageBytes > VCMaximumJPEGFrameBytes) {
                [self resetMJPEGReceiveBufferLocked];
                [self reportMalformedMJPEGStream:@"MJPEG frame exceeded its safety limit"];
            }
            break;
        }
        if (parsedImageLength > VCMaximumJPEGFrameBytes ||
            parsedImageLength > availableImageBytes) {
            [self resetMJPEGReceiveBufferLocked];
            [self reportMalformedMJPEGStream:@"MJPEG frame exceeded its safety limit"];
            continue;
        }
        NSUInteger imageLength = (NSUInteger)parsedImageLength;

        // A network callback can contain several complete frames after Wi-Fi
        // jitter or temporary decoder pressure. Keep only the newest complete
        // JPEG in this callback so recovery catches up instead of displaying a
        // stale backlog frame-by-frame.
        if (decodeWindowOpen) {
            latestJPEGData = [imageData subdataWithRange:NSMakeRange(_mjpegBufferOffset,
                                                                     imageLength)];
        }
        _mjpegBufferOffset += imageLength;
        VCJPEGParserReset(&_mjpegParserState);
        [self compactMJPEGReceiveBufferLockedIfNeeded:NO];
    }

    if (latestJPEGData) {
        _lastMJPEGDecodeTime = CFAbsoluteTimeGetCurrent();
        pixelBuffer = [self copyPixelBufferFromJPEGData:latestJPEGData];
        if (!pixelBuffer) {
            [self reportMalformedMJPEGStream:@"MJPEG JPEG decoding failed"];
        }
    }
    os_unfair_lock_unlock(&_mjpegReceiveLock);

    if (pixelBuffer) {
        if (session == self.session && dataTask == self.task && self.running) {
            [self deliverPixelBuffer:pixelBuffer];
        }
        CVPixelBufferRelease(pixelBuffer);
    }
}

- (void)reportMalformedMJPEGStream:(NSString *)description {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_lastMJPEGErrorReportTime > 0 && now - _lastMJPEGErrorReportTime < 30.0) return;
    _lastMJPEGErrorReportTime = now;
    NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                     code:1006
                                 userInfo:@{NSLocalizedDescriptionKey: description}];
    [self reportError:error];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (session != self.session) {
        [session finishTasksAndInvalidate];
        return;
    }

    self.task = nil;
    self.session = nil;
    self.delegateQueue = nil;
    os_unfair_lock_lock(&_mjpegReceiveLock);
    self.imageData = nil;
    [self resetMJPEGReceiveBufferLocked];
    os_unfair_lock_unlock(&_mjpegReceiveLock);
    [session finishTasksAndInvalidate];

    if (!self.running) return;
    NSError *finalError = error ?: [NSError errorWithDomain:VCStreamErrorDomain
                                                            code:1003
                                                        userInfo:@{NSLocalizedDescriptionKey: @"MJPEG stream ended"}];
    [self scheduleReconnectAfterError:finalError];
}

- (void)dealloc {
    if (self.observingPlayerItem && self.hlsPlayerItem) {
        @try {
            [self.hlsPlayerItem removeObserver:self forKeyPath:@"status" context:VCPlayerItemStatusContext];
        } @catch (__unused NSException *exception) {
        }
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.frameTimer) dispatch_source_cancel(self.frameTimer);
    if (self.healthTimer) dispatch_source_cancel(self.healthTimer);
    [self.task cancel];
    [self.session invalidateAndCancel];
    [self releaseMJPEGPixelBufferPool];
}

@end
