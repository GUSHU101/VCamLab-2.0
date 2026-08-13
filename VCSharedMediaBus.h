#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VCSharedMediaKind) {
    VCSharedMediaKindVideo = 1,
    VCSharedMediaKindAudio = 2,
};

/// SpringBoard-side publisher. Frames stay IOSurface-backed and are never
/// serialized when another process consumes them.
@interface VCSharedVideoServer : NSObject
+ (instancetype)sharedServer;
- (BOOL)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)invalidate;
- (void)handleMemoryPressure;
@end

/// Consumer used by mediaserverd and the AVFoundation application fallback.
@interface VCSharedVideoClient : NSObject
+ (instancetype)sharedClient;
/// The returned buffer owns both a CoreVideo retain and an IOSurface use-count
/// lease. Release it only with VCReleaseSharedVideoPixelBuffer so a producer
/// pool cannot recycle the backing store while another process is reading it.
- (CVPixelBufferRef _Nullable)copyLatestPixelBufferWithMaximumAge:
    (NSTimeInterval)maximumAge CF_RETURNS_RETAINED;
- (BOOL)hasPublishedFrameWithMaximumAge:(NSTimeInterval)maximumAge;
@end

FOUNDATION_EXPORT void VCReleaseSharedVideoPixelBuffer(
    CVPixelBufferRef _Nullable pixelBuffer);

/// Canonical audio transport: interleaved Float32, 48 kHz, stereo. The storage
/// itself is a global IOSurface ring; only the tiny control word is notified.
@interface VCSharedAudioServer : NSObject
+ (instancetype)sharedServer;
- (BOOL)publishInterleavedStereoSamples:(const float *)samples
                             frameCount:(NSUInteger)frameCount;
- (void)invalidate;
- (void)handleMemoryPressure;
@end

@interface VCSharedAudioClient : NSObject
+ (instancetype)sharedClient;
- (BOOL)copyLatestInterleavedStereoFrames:(NSUInteger)frameCount
                                      into:(float *)destination;
- (BOOL)hasPublishedAudioWithMaximumAge:(NSTimeInterval)maximumAge;
@end

/// The low-level hook publishes a short heartbeat only after a replacement was
/// actually emitted. Application hooks use it for automatic failover, removing
/// the old user-facing "compatibility mode" switch.
FOUNDATION_EXPORT void VCMarkSystemPipelineActivity(VCSharedMediaKind kind);
FOUNDATION_EXPORT BOOL VCSystemPipelineIsActive(VCSharedMediaKind kind,
                                                NSTimeInterval maximumAge);

NS_ASSUME_NONNULL_END
