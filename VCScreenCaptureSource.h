#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VCScreenFrameCallback)(CVPixelBufferRef pixelBuffer);
typedef void (^VCScreenErrorCallback)(NSError *error);

/// Runs only inside SpringBoard. CoreAnimation renders the display directly
/// into a global IOSurface, so publishing the frame to camera consumers does
/// not add a CPU copy.
@interface VCScreenCaptureSource : NSObject
@property (atomic, assign) NSInteger preferredFPS;
@property (atomic, copy, nullable) VCScreenFrameCallback frameCallback;
@property (atomic, copy, nullable) VCScreenErrorCallback errorCallback;
@property (atomic, assign, readonly, getter=isRunning) BOOL running;
- (void)start;
- (void)stop;
- (void)handleMemoryPressure;
@end

NS_ASSUME_NONNULL_END
