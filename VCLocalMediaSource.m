#import "VCLocalMediaSource.h"
#import "VCLocalOrientationMath.h"
#import "VCMediaTrackLoader.h"

#import <AVFoundation/AVFoundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSString * const VCLocalMediaErrorDomain =
    @"com.murkaska.virtualcampro.local-media";
static const NSTimeInterval VCLocalMediaTrackLoadingTimeout = 30.0;

@interface VCLocalMediaSource ()
@property (nonatomic, strong, readwrite) NSURL *fileURL;
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (atomic, assign, readwrite) NSInteger trackRotation;
@property (atomic, assign, readwrite, getter=isTrackMirrored) BOOL trackMirrored;
@property (atomic, assign) NSUInteger lifecycleGeneration;
@property (atomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVURLAsset *loadingAsset;
@property (nonatomic, strong) AVURLAsset *preparedAsset;
@property (nonatomic, copy) NSArray<AVAssetTrack *> *preparedVideoTracks;
@property (nonatomic, copy) NSArray<AVAssetTrack *> *preparedAudioTracks;
@property (nonatomic, assign) CGAffineTransform preparedTrackTransform;
@property (nonatomic, assign) CGSize preparedTrackNaturalSize;
@property (nonatomic, assign) BOOL preparedTrackGeometryReady;
@property (nonatomic, strong) dispatch_queue_t readerQueue;
@property (nonatomic, strong) dispatch_semaphore_t wakeSemaphore;
@end

@implementation VCLocalMediaSource

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (self) {
        _fileURL = fileURL;
        _loops = YES;
        _preferredFPS = 60;
        _maximumPixelDimension = 1920;
        _trackRotation = 0;
        _trackMirrored = NO;
        _readerQueue = dispatch_queue_create(
            "com.murkaska.virtualcampro.local-media-reader",
            DISPATCH_QUEUE_SERIAL);
        _wakeSemaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)start {
    @synchronized (self) {
        if (self.running) return;
        self.running = YES;
        self.lifecycleGeneration++;
    }
    NSUInteger generation = self.lifecycleGeneration;
    __weak VCLocalMediaSource *weakSelf = self;
    dispatch_async(self.readerQueue, ^{ [weakSelf runGeneration:generation]; });
}

- (void)stop {
    AVURLAsset *loadingAsset = nil;
    @synchronized (self) {
        self.running = NO;
        self.lifecycleGeneration++;
        loadingAsset = self.loadingAsset;
        self.loadingAsset = nil;
        self.preparedAsset = nil;
        self.preparedVideoTracks = nil;
        self.preparedAudioTracks = nil;
        self.preparedTrackTransform = CGAffineTransformIdentity;
        self.preparedTrackNaturalSize = CGSizeZero;
        self.preparedTrackGeometryReady = NO;
        [self.reader cancelReading];
        self.reader = nil;
    }
    [loadingAsset cancelLoading];
    dispatch_semaphore_signal(self.wakeSemaphore);
}

- (BOOL)isGenerationCurrent:(NSUInteger)generation {
    @synchronized (self) {
        return self.running && self.lifecycleGeneration == generation;
    }
}

- (void)runGeneration:(NSUInteger)generation {
    @autoreleasepool {
        BOOL reachedNaturalEnd = NO;
        NSUInteger consecutiveReadFailures = 0;
        while ([self isGenerationCurrent:generation]) {
            NSError *error = nil;
            BOOL completed = [self readOnePassForGeneration:generation error:&error];
            if (![self isGenerationCurrent:generation]) return;
            if (!completed && error) {
                if (consecutiveReadFailures == 0) {
                    consecutiveReadFailures++;
                    @synchronized (self) {
                        if (self.lifecycleGeneration == generation && self.running) {
                            self.preparedAsset = nil;
                            self.preparedVideoTracks = nil;
                            self.preparedAudioTracks = nil;
                            self.preparedTrackTransform = CGAffineTransformIdentity;
                            self.preparedTrackNaturalSize = CGSizeZero;
                            self.preparedTrackGeometryReady = NO;
                        }
                    }
                    NSLog(@"[VirtualCamPro] Retrying local media after a transient read error: %@",
                          error.localizedDescription);
                    if (!VCMediaWaitForRetryDelay(0.20, ^BOOL{
                            return ![self isGenerationCurrent:generation];
                        })) {
                        return;
                    }
                    continue;
                }
                VCLocalMediaErrorCallback callback = self.errorCallback;
                if (callback) callback(error);
                NSLog(@"[VirtualCamPro] Local media error: %@", error.localizedDescription);
            }
            if (!completed) break;
            consecutiveReadFailures = 0;
            if (!self.loops) {
                reachedNaturalEnd = YES;
                break;
            }
        }
        BOOL notifyCompletion = NO;
        @synchronized (self) {
            if (self.lifecycleGeneration == generation) {
                self.running = NO;
                self.reader = nil;
                notifyCompletion = reachedNaturalEnd;
            }
        }
        if (notifyCompletion) {
            VCLocalMediaCompletionCallback callback = nil;
            @synchronized (self) {
                if (self.lifecycleGeneration == generation && !self.running) {
                    callback = self.completionCallback;
                }
            }
            if (callback) callback();
        }
    }
}

- (BOOL)readOnePassForGeneration:(NSUInteger)generation
                            error:(NSError **)errorOut {
    AVURLAsset *asset = nil;
    NSArray<AVAssetTrack *> *videoTracks = nil;
    NSArray<AVAssetTrack *> *audioTracks = nil;
    CGAffineTransform preferredTransform = CGAffineTransformIdentity;
    CGSize naturalSize = CGSizeZero;
    BOOL geometryReady = NO;
    @synchronized (self) {
        if (!self.running || self.lifecycleGeneration != generation) return NO;
        asset = self.preparedAsset;
        videoTracks = self.preparedVideoTracks;
        audioTracks = self.preparedAudioTracks;
        preferredTransform = self.preparedTrackTransform;
        naturalSize = self.preparedTrackNaturalSize;
        geometryReady = self.preparedTrackGeometryReady;
    }
    if (!asset) {
        NSError *loadingError = nil;
        VCMediaTrackLoadResult loadingResult = VCMediaLoadTracksFromURL(
            self.fileURL,
            @{AVURLAssetPreferPreciseDurationAndTimingKey: @NO},
            VCLocalMediaTrackLoadingTimeout,
            2,
            ^BOOL{
                return ![self isGenerationCurrent:generation];
            },
            ^(AVURLAsset *observedAsset, BOOL loading) {
                BOOL cancelObservedAsset = NO;
                @synchronized (self) {
                    BOOL current = self.running &&
                        self.lifecycleGeneration == generation;
                    if (loading && current) {
                        self.loadingAsset = observedAsset;
                    } else if (loading) {
                        cancelObservedAsset = YES;
                    } else if (self.loadingAsset == observedAsset) {
                        self.loadingAsset = nil;
                    }
                }
                if (cancelObservedAsset) [observedAsset cancelLoading];
            },
            &asset,
            &videoTracks,
            &audioTracks,
            &loadingError);
        VCMediaTrackLoadResult geometryResult = VCMediaTrackLoadResultLoaded;
        if (loadingResult == VCMediaTrackLoadResultLoaded &&
            ![self isGenerationCurrent:generation]) {
            [asset cancelLoading];
            geometryResult = VCMediaTrackLoadResultCancelled;
        } else if (loadingResult == VCMediaTrackLoadResultLoaded &&
                   videoTracks.firstObject) {
            geometryResult = VCMediaLoadVideoTrackGeometry(
                asset,
                videoTracks.firstObject,
                VCLocalMediaTrackLoadingTimeout,
                ^BOOL{
                    return ![self isGenerationCurrent:generation];
                },
                &preferredTransform,
                &naturalSize,
                &loadingError);
            geometryReady = geometryResult == VCMediaTrackLoadResultLoaded;
        } else if (loadingResult == VCMediaTrackLoadResultLoaded) {
            geometryReady = YES;
        }
        BOOL current = NO;
        @synchronized (self) {
            if (self.loadingAsset == asset) self.loadingAsset = nil;
            current = self.running && self.lifecycleGeneration == generation;
            if (current && loadingResult == VCMediaTrackLoadResultLoaded &&
                geometryResult == VCMediaTrackLoadResultLoaded &&
                (videoTracks.count > 0 || audioTracks.count > 0)) {
                self.preparedAsset = asset;
                self.preparedVideoTracks = videoTracks ?: @[];
                self.preparedAudioTracks = audioTracks ?: @[];
                self.preparedTrackTransform = preferredTransform;
                self.preparedTrackNaturalSize = naturalSize;
                self.preparedTrackGeometryReady = geometryReady;
            }
        }
        if (!current || loadingResult == VCMediaTrackLoadResultCancelled ||
            geometryResult == VCMediaTrackLoadResultCancelled) return NO;
        if (loadingResult == VCMediaTrackLoadResultTimedOut) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:VCLocalMediaErrorDomain
                                                 code:3
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"Timed out while loading local media tracks"}];
            }
            return NO;
        }
        if (geometryResult == VCMediaTrackLoadResultTimedOut) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:VCLocalMediaErrorDomain
                                                 code:5
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"Timed out while loading local video geometry"}];
            }
            return NO;
        }
        if (geometryResult == VCMediaTrackLoadResultFailed) {
            if (errorOut) {
                NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey:
                    @"AVFoundation could not load local video geometry"} mutableCopy];
                if (loadingError) userInfo[NSUnderlyingErrorKey] = loadingError;
                *errorOut = [NSError errorWithDomain:VCLocalMediaErrorDomain
                                                 code:6
                                             userInfo:userInfo];
            }
            return NO;
        }
        if (loadingResult == VCMediaTrackLoadResultFailed) {
            if (errorOut) {
                NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey:
                    @"AVFoundation could not load local media tracks"} mutableCopy];
                if (loadingError) userInfo[NSUnderlyingErrorKey] = loadingError;
                *errorOut = [NSError errorWithDomain:VCLocalMediaErrorDomain
                                                 code:4
                                             userInfo:userInfo];
            }
            return NO;
        }
    }
    if (videoTracks.count == 0 && audioTracks.count == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:VCLocalMediaErrorDomain
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"The selected file has no video or audio track"}];
        }
        return NO;
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (!reader) {
        if (errorOut) *errorOut = readerError;
        return NO;
    }
    AVAssetReaderTrackOutput *videoOutput = nil;
    AVAssetReaderTrackOutput *audioOutput = nil;
    if (videoTracks.firstObject) {
        AVAssetTrack *videoTrack = videoTracks.firstObject;
        if (!geometryReady) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:VCLocalMediaErrorDomain
                                                 code:7
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"Local video geometry was not prepared"}];
            }
            return NO;
        }
        VCLocalTrackOrientation orientation = VCResolveLocalTrackOrientation(
            preferredTransform.a,
            preferredTransform.b,
            preferredTransform.c,
            preferredTransform.d);
        NSInteger trackRotation = orientation.valid ? orientation.rotation : 0;
        BOOL trackMirrored = orientation.valid ? orientation.mirrored : NO;
        self.trackRotation = trackRotation;
        self.trackMirrored = trackMirrored;
        NSLog(@"[VirtualCamPro] Local track display transform: rotation=%ld mirror=%@",
              (long)trackRotation, trackMirrored ? @"YES" : @"NO");
        // AVAssetReaderTrackOutput emits encoded pixel orientation; it does not
        // apply preferredTransform. Scale that actual raster here and leave all
        // orientation decisions to the explicit local-file controls downstream.
        CGFloat sourceWidth = fabs(naturalSize.width);
        CGFloat sourceHeight = fabs(naturalSize.height);
        NSMutableDictionary *settings = [@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{
                (id)kIOSurfaceIsGlobal: @YES,
            },
        } mutableCopy];
        if (isfinite(sourceWidth) && isfinite(sourceHeight) &&
            sourceWidth >= 2.0 && sourceHeight >= 2.0) {
            NSInteger dimensionLimit = MAX(1280, MIN(3840, self.maximumPixelDimension));
            CGFloat scale = MIN(1.0, dimensionLimit / MAX(sourceWidth, sourceHeight));
            size_t outputWidth = MAX(2, (size_t)llround(sourceWidth * scale));
            size_t outputHeight = MAX(2, (size_t)llround(sourceHeight * scale));
            outputWidth &= ~(size_t)1;
            outputHeight &= ~(size_t)1;
            settings[(id)kCVPixelBufferWidthKey] = @(outputWidth);
            settings[(id)kCVPixelBufferHeightKey] = @(outputHeight);
        }
        videoOutput = [[AVAssetReaderTrackOutput alloc]
            initWithTrack:videoTrack outputSettings:settings];
        videoOutput.alwaysCopiesSampleData = NO;
        if ([reader canAddOutput:videoOutput]) [reader addOutput:videoOutput];
        else videoOutput = nil;
    }
    if (audioTracks.firstObject) {
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @2,
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        audioOutput = [[AVAssetReaderTrackOutput alloc]
            initWithTrack:audioTracks.firstObject outputSettings:settings];
        audioOutput.alwaysCopiesSampleData = NO;
        if ([reader canAddOutput:audioOutput]) [reader addOutput:audioOutput];
        else audioOutput = nil;
    }
    if (!videoOutput && !audioOutput) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:VCLocalMediaErrorDomain
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"No asset track can be decoded on this device"}];
        }
        return NO;
    }

    @synchronized (self) {
        if (![self isGenerationCurrent:generation]) return NO;
        self.reader = reader;
    }
    if (![reader startReading]) {
        if (errorOut) *errorOut = reader.error;
        return NO;
    }

    CMSampleBufferRef nextVideo = videoOutput ? [videoOutput copyNextSampleBuffer] : NULL;
    CMSampleBufferRef nextAudio = audioOutput ? [audioOutput copyNextSampleBuffer] : NULL;
    CMTime firstPTS = kCMTimeInvalid;
    CMTime lastDeliveredVideoPTS = kCMTimeInvalid;
    CFTimeInterval wallStart = CACurrentMediaTime();
    NSInteger preferredFPS = MAX(1, MIN(240, self.preferredFPS));
    Float64 minimumVideoInterval = 1.0 / preferredFPS;

    while ([self isGenerationCurrent:generation] && (nextVideo || nextAudio)) {
        BOOL useVideo = nextVideo && (!nextAudio ||
            CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(nextVideo),
                          CMSampleBufferGetPresentationTimeStamp(nextAudio)) <= 0);
        CMSampleBufferRef sample = useVideo ? nextVideo : nextAudio;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        if (!CMTIME_IS_VALID(firstPTS)) {
            firstPTS = pts;
            wallStart = CACurrentMediaTime();
        }
        Float64 relativeSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS));
        if (isfinite(relativeSeconds) && relativeSeconds > 0) {
            CFTimeInterval deadline = wallStart + relativeSeconds;
            while ([self isGenerationCurrent:generation]) {
                CFTimeInterval remaining = deadline - CACurrentMediaTime();
                if (remaining <= 0) break;
                int64_t slice = (int64_t)(MIN(remaining, 0.02) * NSEC_PER_SEC);
                dispatch_semaphore_wait(self.wakeSemaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, slice));
            }
        }
        if (![self isGenerationCurrent:generation]) break;

        if (useVideo) {
            BOOL rateEligible = !CMTIME_IS_VALID(lastDeliveredVideoPTS) ||
                CMTimeGetSeconds(CMTimeSubtract(pts, lastDeliveredVideoPTS)) >=
                    minimumVideoInterval * 0.90;
            CFTimeInterval lateness = CACurrentMediaTime() - (wallStart + MAX(0, relativeSeconds));
            BOOL tooLate = isfinite(lateness) &&
                lateness > MAX(0.080, minimumVideoInterval * 2.0);
            CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
            VCLocalVideoCallback callback = self.videoCallback;
            if (rateEligible && !tooLate && imageBuffer && callback) {
                callback(imageBuffer);
                lastDeliveredVideoPTS = pts;
            }
            CFRelease(nextVideo);
            nextVideo = [videoOutput copyNextSampleBuffer];
        } else {
            [self publishAudioSampleBuffer:sample];
            CFRelease(nextAudio);
            nextAudio = [audioOutput copyNextSampleBuffer];
        }
    }
    if (nextVideo) CFRelease(nextVideo);
    if (nextAudio) CFRelease(nextAudio);

    AVAssetReaderStatus status = reader.status;
    NSError *finalError = reader.error;
    @synchronized (self) {
        if (self.reader == reader) self.reader = nil;
    }
    if (status == AVAssetReaderStatusFailed) {
        if (errorOut) *errorOut = finalError;
        return NO;
    }
    return status == AVAssetReaderStatusCompleted;
}

- (void)publishAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (!dataBuffer || frameCount <= 0) return;
    size_t requiredBytes = (size_t)frameCount * 2 * sizeof(float);
    if (CMBlockBufferGetDataLength(dataBuffer) < requiredBytes) return;
    VCLocalAudioCallback callback = self.audioCallback;
    if (!callback) return;
    char *contiguousBytes = NULL;
    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    OSStatus pointerStatus = CMBlockBufferGetDataPointer(dataBuffer,
                                                         0,
                                                         &lengthAtOffset,
                                                         &totalLength,
                                                         &contiguousBytes);
    if (pointerStatus == noErr && contiguousBytes && lengthAtOffset >= requiredBytes) {
        callback((const float *)contiguousBytes, (NSUInteger)frameCount);
        return;
    }
    float *samples = malloc(requiredBytes);
    if (!samples) return;
    OSStatus status = CMBlockBufferCopyDataBytes(dataBuffer, 0, requiredBytes, samples);
    if (status == noErr) callback(samples, (NSUInteger)frameCount);
    free(samples);
}

- (void)dealloc { [self stop]; }
@end
