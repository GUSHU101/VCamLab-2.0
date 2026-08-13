#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCStreamCoordinator : NSObject

+ (instancetype)sharedCoordinator;
- (void)startMonitoring;
- (void)refreshPreferencesAndStream;
/// Returned shared buffers must be released with
/// VCReleaseSharedVideoPixelBuffer(), not CVPixelBufferRelease().
- (CVPixelBufferRef)copyLatestPixelBuffer CF_RETURNS_RETAINED;
- (CVPixelBufferRef)copyLatestPixelBufferWithAspectFill:(BOOL * _Nullable)aspectFill
                                           preferredFPS:(NSInteger * _Nullable)preferredFPS CF_RETURNS_RETAINED;
- (void)publishCompatibilityOutputPixelBuffer:(CVPixelBufferRef _Nullable)pixelBuffer;
- (CVPixelBufferRef _Nullable)copyLatestCompatibilityOutputPixelBufferWithActivePath:
    (BOOL * _Nullable)activePath CF_RETURNS_RETAINED;
- (BOOL)isReplacementActive;
- (BOOL)isSystemPipelineReplacementConfigured;
- (NSInteger)preferredFPS;
- (CGFloat)jpegQuality;
- (BOOL)aspectFill;
- (BOOL)holdLastFrame;
- (NSTimeInterval)staleFrameTimeout;
/// SpringBoard volume-up selects the next video and volume-down the previous
/// video in the selected local file's directory. Returns YES when consumed.
- (BOOL)handleLocalMediaVolumeButtonDirection:(NSInteger)direction;

@end

NS_ASSUME_NONNULL_END
