#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCStreamProtocol) {
    VCStreamProtocolHLS,
    VCStreamProtocolMJPEG,
};

typedef void (^AVAssetPixelBufferCallback)(CVPixelBufferRef buffer);
typedef void (^AVAssetErrorCallback)(NSError *error);

@interface AVAssetStreamAdapter : NSObject <NSURLSessionDataDelegate>

@property (nonatomic, strong, readonly) NSURL *streamURL;
@property (nonatomic, assign, readonly) VCStreamProtocol streamProtocol;
@property (atomic, assign, readonly, getter=isRunning) BOOL running;
@property (atomic, assign, readonly, getter=isConnecting) BOOL connecting;
@property (atomic, assign, readonly) NSUInteger frameCount;
@property (atomic, assign, readonly) CFAbsoluteTime lastFrameTime;
@property (atomic, assign) NSInteger preferredFPS;
@property (atomic, assign) NSInteger maximumPixelDimension;

@property (atomic, copy, nullable) AVAssetPixelBufferCallback pixelBufferCallback;
@property (atomic, copy, nullable) AVAssetErrorCallback errorCallback;

- (instancetype)initWithURL:(NSURL *)url;
- (void)startStreaming;
- (void)stopStreaming;
- (void)handleMemoryPressure;

@end

NS_ASSUME_NONNULL_END
