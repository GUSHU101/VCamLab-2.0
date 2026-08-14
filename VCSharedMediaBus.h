#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "VCSharedMediaProtocol.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VCSharedMediaKind) {
    VCSharedMediaKindVideo = 1,
    VCSharedMediaKindAudio = 2,
};

typedef NS_ENUM(NSUInteger, VCSharedRuntimeProcess) {
    VCSharedRuntimeProcessSpringBoard = 1,
    VCSharedRuntimeProcessMediaServer = 2,
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

/// Failure reason for the most recent shared-video read on the calling thread.
/// Call immediately after a NULL result from VCStreamCoordinator.
FOUNDATION_EXPORT VCSharedVideoFailureReason
VCSharedVideoLastFailureReason(void);

/// Canonical audio transport: interleaved Float32, 48 kHz, stereo. The storage
/// itself is a global IOSurface ring; only the tiny control word is notified.
@interface VCSharedAudioServer : NSObject
+ (instancetype)sharedServer;
- (BOOL)publishInterleavedStereoSamples:(const float *)samples
                             frameCount:(NSUInteger)frameCount;
- (void)invalidate;
- (void)handleMemoryPressure;
@end

/// Independent consumer position in the shared PCM ring. Every BW output node
/// and application delegate owns one cursor so concurrent CaptureSessions do
/// not steal audio frames from one another.
@interface VCSharedAudioCursor : NSObject
- (void)reset;
@end

@interface VCSharedAudioClient : NSObject
+ (instancetype)sharedClient;
- (BOOL)copyLatestInterleavedStereoFrames:(NSUInteger)frameCount
                                      into:(float *)destination
                                    cursor:(VCSharedAudioCursor *)cursor;
- (BOOL)hasPublishedAudioWithMaximumAge:(NSTimeInterval)maximumAge;
@end

/// The low-level hook publishes a rate-limited process-global health signal
/// only after a replacement was emitted. This is diagnostic state only:
/// application fallbacks must use per-sample replacement evidence rather than
/// letting activity in one capture graph suppress another graph.
FOUNDATION_EXPORT void VCMarkSystemPipelineActivity(VCSharedMediaKind kind);
FOUNDATION_EXPORT BOOL VCSystemPipelineIsActive(VCSharedMediaKind kind,
                                                NSTimeInterval maximumAge);

/// Process-lifetime liveness signals make stale notify state distinguishable
/// from a currently loaded SpringBoard/mediaserverd runtime. Heartbeats update
/// at a low fixed cadence and never participate in replacement correctness.
FOUNDATION_EXPORT void VCStartSharedRuntimeHeartbeat(
    VCSharedRuntimeProcess process);

/// Records the most recent mediaserverd video stage without relying on unified
/// logging. Repeated hot-path events are rate limited inside the implementation.
FOUNDATION_EXPORT void VCReportMediaServerVideoRuntimeEvent(
    VCMediaServerVideoRuntimeEvent event,
    uint8_t detail);

/// Persists the latest application-side compatibility stage so diagnostics
/// survive switching from Camera back to Settings.
FOUNDATION_EXPORT void VCReportApplicationVideoRuntimeEvent(
    VCApplicationVideoRuntimeEvent event,
    uint8_t detail);

FOUNDATION_EXPORT void VCReportProducerVideoRuntimeEvent(
    VCProducerVideoRuntimeEvent event,
    uint8_t detail);

NS_ASSUME_NONNULL_END
