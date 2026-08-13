#import "VCPreferences.h"
#import <float.h>
#import <math.h>

NSString * const VCPreferencesDomain = @"com.murkaska.virtualcampro";
NSString * const VCPreferencesChangedNotification = @"com.murkaska.virtualcampro/preferences.changed";
NSString * const VCEnabledKey = @"enabled";
NSString * const VCStreamURLKey = @"streamURL";
NSString * const VCPreferredFPSKey = @"preferredFPS";
NSString * const VCSourceRotationKey = @"sourceRotation";
NSString * const VCMirrorSourceKey = @"mirrorSource";
NSString * const VCMaximumPixelDimensionKey = @"maximumPixelDimension";
NSString * const VCJPEGQualityKey = @"jpegQuality";
NSString * const VCAspectFillKey = @"aspectFill";
NSString * const VCCompatibilityModeKey = @"compatibilityMode";
NSString * const VCHoldLastFrameKey = @"holdLastFrame";
NSString * const VCStaleFrameTimeoutKey = @"staleFrameTimeout";

static NSString * const VCLegacyPreferencesPath = @"/var/mobile/Library/Preferences/com.apple.avfoundation.cs.plist";

@interface VCPreferences ()
@property (atomic, assign, readwrite, getter=isEnabled) BOOL enabled;
@property (atomic, copy, readwrite, nullable) NSURL *streamURL;
@property (atomic, assign, readwrite) NSInteger preferredFPS;
@property (atomic, assign, readwrite) NSInteger sourceRotation;
@property (atomic, assign, readwrite) BOOL mirrorSource;
@property (atomic, assign, readwrite) NSInteger maximumPixelDimension;
@property (atomic, assign, readwrite) CGFloat jpegQuality;
@property (atomic, assign, readwrite) BOOL aspectFill;
@property (atomic, assign, readwrite) BOOL compatibilityMode;
@property (atomic, assign, readwrite) BOOL holdLastFrame;
@property (atomic, assign, readwrite) NSTimeInterval staleFrameTimeout;
@end

@implementation VCPreferences

+ (instancetype)sharedPreferences {
    static VCPreferences *preferences;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        preferences = [[self alloc] init];
        [preferences reload];
    });
    return preferences;
}

static id VCReadPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)VCPreferencesDomain);
    return CFBridgingRelease(value);
}

- (BOOL)reload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCPreferencesDomain);

    id enabledValue = VCReadPreference(VCEnabledKey);
    id streamValue = VCReadPreference(VCStreamURLKey);
    id fpsValue = VCReadPreference(VCPreferredFPSKey);
    id sourceRotationValue = VCReadPreference(VCSourceRotationKey);
    id mirrorSourceValue = VCReadPreference(VCMirrorSourceKey);
    id maximumPixelDimensionValue = VCReadPreference(VCMaximumPixelDimensionKey);
    id qualityValue = VCReadPreference(VCJPEGQualityKey);
    id aspectFillValue = VCReadPreference(VCAspectFillKey);
    id compatibilityModeValue = VCReadPreference(VCCompatibilityModeKey);
    id holdLastFrameValue = VCReadPreference(VCHoldLastFrameKey);
    id staleFrameTimeoutValue = VCReadPreference(VCStaleFrameTimeoutKey);

    // Read the original project's preference file as a migration fallback.
    if (!enabledValue || !streamValue) {
        NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:VCLegacyPreferencesPath];
        enabledValue = enabledValue ?: legacy[VCEnabledKey];
        streamValue = streamValue ?: legacy[VCStreamURLKey];
    }

    BOOL enabled = enabledValue ? [enabledValue boolValue] : NO;
    NSInteger preferredFPS = fpsValue ? [fpsValue integerValue] : 60;
    preferredFPS = MAX(1, MIN(240, preferredFPS));

    NSInteger sourceRotation = sourceRotationValue ? [sourceRotationValue integerValue] : 0;
    if (sourceRotation != 90 && sourceRotation != 180 && sourceRotation != 270) {
        sourceRotation = 0;
    }
    BOOL mirrorSource = mirrorSourceValue ? [mirrorSourceValue boolValue] : NO;

    NSInteger maximumPixelDimension = maximumPixelDimensionValue
        ? [maximumPixelDimensionValue integerValue]
        : 1920;
    if (maximumPixelDimension != 1280 && maximumPixelDimension != 1920 &&
        maximumPixelDimension != 2560 && maximumPixelDimension != 3840) {
        maximumPixelDimension = 1920;
    }

    CGFloat jpegQuality = qualityValue ? [qualityValue doubleValue] : 1.0;
    jpegQuality = MAX(0.50, MIN(1.0, jpegQuality));

    BOOL aspectFill = aspectFillValue ? [aspectFillValue boolValue] : YES;
    BOOL compatibilityMode = compatibilityModeValue ? [compatibilityModeValue boolValue] : NO;
    BOOL holdLastFrame = holdLastFrameValue ? [holdLastFrameValue boolValue] : YES;
    NSTimeInterval staleFrameTimeout = staleFrameTimeoutValue ? [staleFrameTimeoutValue doubleValue] : 8.0;
    staleFrameTimeout = MAX(2.0, MIN(30.0, staleFrameTimeout));

    NSURL *streamURL = nil;
    if ([streamValue isKindOfClass:[NSString class]] && [streamValue length] > 0) {
        NSURL *candidate = [NSURL URLWithString:[streamValue stringByTrimmingCharactersInSet:
                                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        NSString *scheme = candidate.scheme.lowercaseString;
        if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
            candidate.host.length > 0 && candidate.user.length == 0 &&
            candidate.password.length == 0 && candidate.fragment.length == 0 &&
            candidate.absoluteString.length <= 4096) {
            streamURL = candidate;
        }
    }

    @synchronized (self) {
        BOOL changed = self.enabled != enabled ||
                       self.preferredFPS != preferredFPS ||
                       self.sourceRotation != sourceRotation ||
                       self.mirrorSource != mirrorSource ||
                       self.maximumPixelDimension != maximumPixelDimension ||
                       fabs(self.jpegQuality - jpegQuality) > DBL_EPSILON ||
                       self.aspectFill != aspectFill ||
                       self.compatibilityMode != compatibilityMode ||
                       self.holdLastFrame != holdLastFrame ||
                       fabs(self.staleFrameTimeout - staleFrameTimeout) > DBL_EPSILON ||
                       !((self.streamURL == streamURL) || [self.streamURL isEqual:streamURL]);

        self.enabled = enabled;
        self.streamURL = streamURL;
        self.preferredFPS = preferredFPS;
        self.sourceRotation = sourceRotation;
        self.mirrorSource = mirrorSource;
        self.maximumPixelDimension = maximumPixelDimension;
        self.jpegQuality = jpegQuality;
        self.aspectFill = aspectFill;
        self.compatibilityMode = compatibilityMode;
        self.holdLastFrame = holdLastFrame;
        self.staleFrameTimeout = staleFrameTimeout;
        return changed;
    }
}

@end
