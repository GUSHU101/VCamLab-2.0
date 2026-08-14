#import <CoreMedia/CoreMedia.h>

/// Per-output streaming state. It owns an independent shared-ring cursor plus
/// fractional resampling phase/look-ahead, preventing concurrent camera nodes
/// from stealing samples or inserting a discontinuity at each callback.
@interface VCAudioReplacementContext : NSObject
- (void)reset;
@end

/// Creates an LPCM sample matching the real microphone sample's ASBD, sample
/// count and timestamps. Unsupported/compressed formats return NULL so the
/// physical microphone remains available.
CMSampleBufferRef _Nullable VCCopyReplacementAudioSampleBuffer(
    CMSampleBufferRef _Nonnull originalSampleBuffer,
    VCAudioReplacementContext * _Nonnull context) CF_RETURNS_RETAINED;
