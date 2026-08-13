#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCStreamCoordinator : NSObject

+ (instancetype)sharedCoordinator;
- (void)startMonitoring;
- (void)refreshPreferencesAndStream;
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

@end

NS_ASSUME_NONNULL_END
