#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VCLocalVideoCallback)(CVPixelBufferRef pixelBuffer);
typedef void (^VCLocalAudioCallback)(const float *interleavedStereoSamples,
                                     NSUInteger frameCount);
typedef void (^VCLocalMediaErrorCallback)(NSError *error);

/// SpringBoard-only local file reader. Video and audio are paced from the same
/// asset timeline; a pure MP3 therefore leaves the physical camera video alone
/// while its PCM is exposed through the microphone replacement path.
@interface VCLocalMediaSource : NSObject
- (instancetype)initWithFileURL:(NSURL *)fileURL;
@property (nonatomic, strong, readonly) NSURL *fileURL;
@property (atomic, assign) BOOL loops;
/// Device-side rate and decode-size controls apply only to local files.
@property (atomic, assign) NSInteger preferredFPS;
@property (atomic, assign) NSInteger maximumPixelDimension;
@property (atomic, copy, nullable) VCLocalVideoCallback videoCallback;
@property (atomic, copy, nullable) VCLocalAudioCallback audioCallback;
@property (atomic, copy, nullable) VCLocalMediaErrorCallback errorCallback;
@property (atomic, assign, readonly, getter=isRunning) BOOL running;
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
