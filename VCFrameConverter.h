#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyPixelBufferMatchingTemplate(
    CVPixelBufferRef source,
    CVPixelBufferRef templateBuffer,
    BOOL aspectFill) CF_RETURNS_RETAINED;

/// Creates a process-local pixel copy whose storage no longer depends on a
/// cross-process IOSurface lease. Intended for asynchronous consumers such as
/// AVCapturePhoto snapshots.
FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyStablePixelBuffer(
    CVPixelBufferRef source) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyPixelBufferApplyingOrientation(
    CVPixelBufferRef source,
    NSInteger clockwiseRotation,
    BOOL mirrorHorizontally) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyDisplayPixelBuffer(
    CVPixelBufferRef source) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT CMSampleBufferRef _Nullable VCCopyReplacementSampleBuffer(
    CMSampleBufferRef original,
    CVPixelBufferRef source,
    BOOL aspectFill,
    NSInteger preferredFPS) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT BOOL VCIsSupportedReplacementPixelFormat(OSType pixelFormat);
FOUNDATION_EXPORT void VCResetFrameConverterCache(void);
FOUNDATION_EXPORT void VCFlushFrameConverterCaches(BOOL releasePoolsAndSession);

NS_ASSUME_NONNULL_END
