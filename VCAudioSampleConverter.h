#import <CoreMedia/CoreMedia.h>

/// Creates an LPCM sample matching the real microphone sample's ASBD, sample
/// count and timestamps. Unsupported/compressed formats return NULL so the
/// physical microphone remains available.
CMSampleBufferRef _Nullable VCCopyReplacementAudioSampleBuffer(
    CMSampleBufferRef _Nonnull originalSampleBuffer) CF_RETURNS_RETAINED;
