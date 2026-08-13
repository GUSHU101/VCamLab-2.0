#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VCPreferencesDomain;
FOUNDATION_EXPORT NSString * const VCPreferencesChangedNotification;
FOUNDATION_EXPORT NSString * const VCEnabledKey;
FOUNDATION_EXPORT NSString * const VCStreamURLKey;
FOUNDATION_EXPORT NSString * const VCPreferredFPSKey;
FOUNDATION_EXPORT NSString * const VCSourceRotationKey;
FOUNDATION_EXPORT NSString * const VCMirrorSourceKey;
FOUNDATION_EXPORT NSString * const VCMaximumPixelDimensionKey;
FOUNDATION_EXPORT NSString * const VCJPEGQualityKey;
FOUNDATION_EXPORT NSString * const VCAspectFillKey;
FOUNDATION_EXPORT NSString * const VCCompatibilityModeKey;
FOUNDATION_EXPORT NSString * const VCHoldLastFrameKey;
FOUNDATION_EXPORT NSString * const VCStaleFrameTimeoutKey;

@interface VCPreferences : NSObject

@property (atomic, assign, readonly, getter=isEnabled) BOOL enabled;
@property (atomic, copy, readonly, nullable) NSURL *streamURL;
@property (atomic, assign, readonly) NSInteger preferredFPS;
@property (atomic, assign, readonly) NSInteger sourceRotation;
@property (atomic, assign, readonly) BOOL mirrorSource;
@property (atomic, assign, readonly) NSInteger maximumPixelDimension;
@property (atomic, assign, readonly) CGFloat jpegQuality;
@property (atomic, assign, readonly) BOOL aspectFill;
@property (atomic, assign, readonly) BOOL compatibilityMode;
@property (atomic, assign, readonly) BOOL holdLastFrame;
@property (atomic, assign, readonly) NSTimeInterval staleFrameTimeout;

+ (instancetype)sharedPreferences;
- (BOOL)reload;

@end

NS_ASSUME_NONNULL_END
