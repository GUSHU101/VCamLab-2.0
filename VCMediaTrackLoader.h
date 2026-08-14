#ifndef VCMediaTrackLoader_h
#define VCMediaTrackLoader_h

#import <AVFoundation/AVFoundation.h>
#include <math.h>

typedef NS_ENUM(NSInteger, VCMediaTrackLoadResult) {
    VCMediaTrackLoadResultLoaded = 0,
    VCMediaTrackLoadResultFailed = 1,
    VCMediaTrackLoadResultTimedOut = 2,
    VCMediaTrackLoadResultCancelled = 3,
};

typedef BOOL (^VCMediaTrackLoadCancellationBlock)(void);
typedef void (^VCMediaTrackAssetObserverBlock)(AVURLAsset *asset, BOOL loading);

static inline BOOL VCMediaWaitForRetryDelay(
    NSTimeInterval delay,
    VCMediaTrackLoadCancellationBlock cancellationBlock) {
    if (!isfinite(delay) || delay <= 0) {
        return !(cancellationBlock && cancellationBlock());
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + delay;
    dispatch_semaphore_t waitSemaphore = dispatch_semaphore_create(0);
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        if (cancellationBlock && cancellationBlock()) return NO;
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        int64_t slice = (int64_t)(MIN(0.05, MAX(0.001, remaining)) * NSEC_PER_SEC);
        dispatch_semaphore_wait(waitSemaphore,
                                dispatch_time(DISPATCH_TIME_NOW, slice));
    }
    return !(cancellationBlock && cancellationBlock());
}

static inline VCMediaTrackLoadResult VCMediaLoadVideoTrackGeometry(
    AVAsset *asset,
    AVAssetTrack *videoTrack,
    NSTimeInterval timeout,
    VCMediaTrackLoadCancellationBlock cancellationBlock,
    CGAffineTransform *preferredTransformOut,
    CGSize *naturalSizeOut,
    NSError * __autoreleasing *loadingErrorOut) {
    if (preferredTransformOut) *preferredTransformOut = CGAffineTransformIdentity;
    if (naturalSizeOut) *naturalSizeOut = CGSizeZero;
    if (loadingErrorOut) *loadingErrorOut = nil;
    if (!asset || !videoTrack || !isfinite(timeout) || timeout <= 0) {
        return VCMediaTrackLoadResultFailed;
    }

    dispatch_semaphore_t loadingSemaphore = dispatch_semaphore_create(0);
    [videoTrack loadValuesAsynchronouslyForKeys:@[@"preferredTransform", @"naturalSize"]
                              completionHandler:^{
        dispatch_semaphore_signal(loadingSemaphore);
    }];

    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (dispatch_semaphore_wait(
        loadingSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC))) != 0) {
        if (cancellationBlock && cancellationBlock()) {
            [asset cancelLoading];
            return VCMediaTrackLoadResultCancelled;
        }
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            [asset cancelLoading];
            return VCMediaTrackLoadResultTimedOut;
        }
    }

    NSError *transformError = nil;
    NSError *sizeError = nil;
    AVKeyValueStatus transformStatus =
        [videoTrack statusOfValueForKey:@"preferredTransform" error:&transformError];
    AVKeyValueStatus sizeStatus =
        [videoTrack statusOfValueForKey:@"naturalSize" error:&sizeError];
    if (transformStatus == AVKeyValueStatusCancelled ||
        sizeStatus == AVKeyValueStatusCancelled) {
        return VCMediaTrackLoadResultCancelled;
    }
    if (transformStatus != AVKeyValueStatusLoaded ||
        sizeStatus != AVKeyValueStatusLoaded) {
        if (loadingErrorOut) *loadingErrorOut = transformError ?: sizeError;
        return VCMediaTrackLoadResultFailed;
    }
    if (preferredTransformOut) *preferredTransformOut = videoTrack.preferredTransform;
    if (naturalSizeOut) *naturalSizeOut = videoTrack.naturalSize;
    return VCMediaTrackLoadResultLoaded;
}

static inline VCMediaTrackLoadResult VCMediaLoadTracks(
    AVAsset *asset,
    NSTimeInterval timeout,
    VCMediaTrackLoadCancellationBlock cancellationBlock,
    NSArray<AVAssetTrack *> * __autoreleasing *videoTracksOut,
    NSArray<AVAssetTrack *> * __autoreleasing *audioTracksOut,
    NSError * __autoreleasing *loadingErrorOut) {
    if (videoTracksOut) *videoTracksOut = nil;
    if (audioTracksOut) *audioTracksOut = nil;
    if (loadingErrorOut) *loadingErrorOut = nil;
    if (!asset || !isfinite(timeout) || timeout <= 0) {
        return VCMediaTrackLoadResultFailed;
    }

    dispatch_group_t loadingGroup = dispatch_group_create();
    __block NSArray<AVAssetTrack *> *videoTracks = nil;
    __block NSArray<AVAssetTrack *> *audioTracks = nil;
    __block NSError *videoError = nil;
    __block NSError *audioError = nil;

    dispatch_group_enter(loadingGroup);
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        videoTracks = tracks;
        videoError = error;
        dispatch_group_leave(loadingGroup);
    }];
    dispatch_group_enter(loadingGroup);
    [asset loadTracksWithMediaType:AVMediaTypeAudio
                 completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        audioTracks = tracks;
        audioError = error;
        dispatch_group_leave(loadingGroup);
    }];

    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (dispatch_group_wait(
        loadingGroup,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC))) != 0) {
        if (cancellationBlock && cancellationBlock()) {
            [asset cancelLoading];
            return VCMediaTrackLoadResultCancelled;
        }
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            [asset cancelLoading];
            return VCMediaTrackLoadResultTimedOut;
        }
    }

    if (videoTracksOut) *videoTracksOut = videoTracks;
    if (audioTracksOut) *audioTracksOut = audioTracks;
    if (videoTracks.count > 0 || audioTracks.count > 0 ||
        (!videoError && !audioError)) {
        return VCMediaTrackLoadResultLoaded;
    }
    if (loadingErrorOut) *loadingErrorOut = videoError ?: audioError;
    return VCMediaTrackLoadResultFailed;
}

// File-provider and Photos URLs can become readable just before AVFoundation's
// metadata cache observes the completed file. A second request on the same
// AVURLAsset can reuse that empty/failed cache, so retries deliberately create
// a fresh asset while sharing one overall timeout budget.
static inline VCMediaTrackLoadResult VCMediaLoadTracksFromURL(
    NSURL *url,
    NSDictionary *options,
    NSTimeInterval timeout,
    NSUInteger maximumAttempts,
    VCMediaTrackLoadCancellationBlock cancellationBlock,
    VCMediaTrackAssetObserverBlock assetObserver,
    AVURLAsset * __autoreleasing *loadedAssetOut,
    NSArray<AVAssetTrack *> * __autoreleasing *videoTracksOut,
    NSArray<AVAssetTrack *> * __autoreleasing *audioTracksOut,
    NSError * __autoreleasing *loadingErrorOut) {
    if (loadedAssetOut) *loadedAssetOut = nil;
    if (videoTracksOut) *videoTracksOut = nil;
    if (audioTracksOut) *audioTracksOut = nil;
    if (loadingErrorOut) *loadingErrorOut = nil;
    if (!url.isFileURL || !isfinite(timeout) || timeout <= 0) {
        return VCMediaTrackLoadResultFailed;
    }

    NSUInteger attempts = MAX((NSUInteger)1, MIN((NSUInteger)3, maximumAttempts));
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    VCMediaTrackLoadResult finalResult = VCMediaTrackLoadResultFailed;
    NSError *finalError = nil;

    for (NSUInteger attempt = 0; attempt < attempts; attempt++) {
        if (cancellationBlock && cancellationBlock()) {
            finalResult = VCMediaTrackLoadResultCancelled;
            break;
        }
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) {
            finalResult = VCMediaTrackLoadResultTimedOut;
            break;
        }

        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
        if (assetObserver) assetObserver(asset, YES);
        NSArray<AVAssetTrack *> *videoTracks = nil;
        NSArray<AVAssetTrack *> *audioTracks = nil;
        NSError *attemptError = nil;
        VCMediaTrackLoadResult result = VCMediaLoadTracks(asset,
                                                           remaining,
                                                           cancellationBlock,
                                                           &videoTracks,
                                                           &audioTracks,
                                                           &attemptError);
        if (result == VCMediaTrackLoadResultLoaded &&
            (videoTracks.count > 0 || audioTracks.count > 0)) {
            if (loadedAssetOut) *loadedAssetOut = asset;
            if (videoTracksOut) *videoTracksOut = videoTracks;
            if (audioTracksOut) *audioTracksOut = audioTracks;
            return VCMediaTrackLoadResultLoaded;
        }

        if (assetObserver) assetObserver(asset, NO);
        finalResult = result;
        finalError = attemptError;
        [asset cancelLoading];
        if (result == VCMediaTrackLoadResultCancelled ||
            result == VCMediaTrackLoadResultTimedOut) {
            break;
        }
        if (attempt + 1 < attempts &&
            !VCMediaWaitForRetryDelay(0.12, cancellationBlock)) {
            finalResult = VCMediaTrackLoadResultCancelled;
            break;
        }
    }

    if (loadingErrorOut) *loadingErrorOut = finalError;
    return finalResult;
}

#endif
