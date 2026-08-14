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

#endif
