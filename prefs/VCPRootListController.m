#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <limits.h>
#import <mach/mach_time.h>
#import <math.h>
#import <notify.h>

#import "../VCJPEGParser.h"

static CFStringRef const VCPreferencesChangedNotification = CFSTR("com.murkaska.virtualcampro/preferences.changed");
static CFStringRef const VCPreferencesDomain = CFSTR("com.murkaska.virtualcampro");
static CFStringRef const VCLocalMediaPathKey = CFSTR("localMediaPath");
static CFStringRef const VCSourceRestartTokenKey = CFSTR("sourceRestartToken");
static NSString * const VCLocalMediaDirectory = @"/var/mobile/Media/VirtualCamPro";
static NSString * const VCLocalMediaImportErrorDomain = @"com.murkaska.virtualcampro.media-import";
static const unsigned long long VCLocalMediaReserveBytes = 64ULL * 1024ULL * 1024ULL;
static const NSUInteger VCPStreamTestMaximumBytes = 8 * 1024 * 1024;

typedef NS_ENUM(NSUInteger, VCPNotifyChannel) {
    VCPNotifyChannelStreamStatus = 0,
    VCPNotifyChannelLocalTransform,
    VCPNotifyChannelLocalVolumeHook,
    VCPNotifyChannelVideoPipeline,
    VCPNotifyChannelCount,
};

static const char *VCPNotifyChannelNames[VCPNotifyChannelCount] = {
    [VCPNotifyChannelStreamStatus] =
        "com.murkaska.virtualcampro/stream.status",
    [VCPNotifyChannelLocalTransform] =
        "com.murkaska.virtualcampro/local-transform.status",
    [VCPNotifyChannelLocalVolumeHook] =
        "com.murkaska.virtualcampro/local-volume-hook.status",
    [VCPNotifyChannelVideoPipeline] =
        "com.murkaska.virtualcampro/pipeline.video.heartbeat.v1",
};

static BOOL VCPGetNotifyChannelState(VCPNotifyChannel channel,
                                     uint64_t *stateOut);

typedef NS_ENUM(uint64_t, VCPStreamStatus) {
    VCPStreamStatusDisabled = 0,
    VCPStreamStatusConnecting = 1,
    VCPStreamStatusReceiving = 2,
    VCPStreamStatusError = 3,
    VCPStreamStatusHoldingLastFrame = 4,
    VCPStreamStatusCompleted = 5,
};

@interface VCPDashboardHeaderView : UIView
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UILabel *pipelineLabel;
- (void)updateEnabled:(BOOL)enabled
               status:(VCPStreamStatus)status
               source:(NSString *)source
             pipeline:(NSString *)pipeline
              version:(NSString *)version;
@end

@implementation VCPDashboardHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    _cardView = [UIView new];
    _cardView.translatesAutoresizingMaskIntoConstraints = NO;
    _cardView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    _cardView.accessibilityIdentifier = @"VirtualCamProStatusCard";
    [self addSubview:_cardView];

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.text = @"VirtualCamPro";
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    _versionLabel = [UILabel new];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _versionLabel.adjustsFontForContentSizeCategory = YES;
    _versionLabel.textColor = UIColor.secondaryLabelColor;
    _versionLabel.textAlignment = NSTextAlignmentRight;
    [_versionLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                   forAxis:UILayoutConstraintAxisHorizontal];

    _statusLabel = [UILabel new];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    _statusLabel.numberOfLines = 2;

    _sourceLabel = [UILabel new];
    _sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _sourceLabel.adjustsFontForContentSizeCategory = YES;
    _sourceLabel.textColor = UIColor.secondaryLabelColor;
    _sourceLabel.numberOfLines = 2;

    _pipelineLabel = [UILabel new];
    _pipelineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pipelineLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _pipelineLabel.adjustsFontForContentSizeCategory = YES;
    _pipelineLabel.textColor = UIColor.tertiaryLabelColor;
    _pipelineLabel.numberOfLines = 2;

    [_cardView addSubview:_titleLabel];
    [_cardView addSubview:_versionLabel];
    [_cardView addSubview:_statusLabel];
    [_cardView addSubview:_sourceLabel];
    [_cardView addSubview:_pipelineLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_cardView.topAnchor constraintEqualToAnchor:self.topAnchor constant:10.0],
        [_cardView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [_cardView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
        [_cardView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8.0],
        [_titleLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:15.0],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16.0],
        [_versionLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_versionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor
                                                                 constant:8.0],
        [_versionLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-16.0],
        [_statusLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:11.0],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_versionLabel.trailingAnchor],
        [_sourceLabel.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:6.0],
        [_sourceLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_sourceLabel.trailingAnchor constraintEqualToAnchor:_versionLabel.trailingAnchor],
        [_pipelineLabel.topAnchor constraintEqualToAnchor:_sourceLabel.bottomAnchor constant:5.0],
        [_pipelineLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_pipelineLabel.trailingAnchor constraintEqualToAnchor:_versionLabel.trailingAnchor],
        [_pipelineLabel.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-15.0],
    ]];
    return self;
}

- (void)updateEnabled:(BOOL)enabled
               status:(VCPStreamStatus)status
               source:(NSString *)source
             pipeline:(NSString *)pipeline
              version:(NSString *)version {
    NSString *statusText = @"已停用 · 真实相机与麦克风保持原样";
    UIColor *statusColor = UIColor.secondaryLabelColor;
    BOOL sourceNeedsAttention = [source containsString:@"尚未"] ||
                                [source containsString:@"无效"] ||
                                [source containsString:@"不存在"];
    if (enabled && sourceNeedsAttention) {
        statusText = @"● 请先完成当前来源配置";
        statusColor = UIColor.systemRedColor;
    } else if (enabled) {
        switch (status) {
            case VCPStreamStatusConnecting:
                statusText = @"● 正在初始化来源";
                statusColor = UIColor.systemOrangeColor;
                break;
            case VCPStreamStatusReceiving:
                statusText = @"● 替换来源正在工作";
                statusColor = UIColor.systemGreenColor;
                break;
            case VCPStreamStatusError:
                statusText = @"● 来源异常，正在自动恢复";
                statusColor = UIColor.systemRedColor;
                break;
            case VCPStreamStatusHoldingLastFrame:
                statusText = @"● 断流保护：保持最后一帧";
                statusColor = UIColor.systemOrangeColor;
                break;
            case VCPStreamStatusCompleted:
                statusText = @"● 本地媒体播放完成";
                statusColor = UIColor.systemBlueColor;
                break;
            default:
                statusText = @"● 等待 SpringBoard 接管";
                statusColor = UIColor.systemOrangeColor;
                break;
        }
    }
    self.statusLabel.text = statusText;
    self.statusLabel.textColor = statusColor;
    self.sourceLabel.text = [@"来源：" stringByAppendingString:source ?: @"未配置"];
    self.pipelineLabel.text = [@"系统管线：" stringByAppendingString:pipeline ?: @"状态不可用"];
    self.versionLabel.text = version.length > 0
        ? [@"v" stringByAppendingString:version] : @"";
}

@end

typedef NS_ENUM(NSInteger, VCLocalMediaImportError) {
    VCLocalMediaImportErrorInvalidSource = 1,
    VCLocalMediaImportErrorCreateDirectory = 2,
    VCLocalMediaImportErrorReadSource = 3,
    VCLocalMediaImportErrorInsufficientSpace = 4,
    VCLocalMediaImportErrorCopy = 5,
    VCLocalMediaImportErrorUnsupportedMedia = 6,
    VCLocalMediaImportErrorFinalize = 7,
};

static NSError *VCLocalMediaError(VCLocalMediaImportError code,
                                  NSString *message,
                                  NSError *underlyingError) {
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: message ?: @"导入媒体失败。"}
                                      mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:VCLocalMediaImportErrorDomain code:code userInfo:userInfo];
}

static NSString *VCSafeLocalMediaFilename(NSURL *sourceURL, NSString *suggestedName) {
    NSString *filename = suggestedName.lastPathComponent;
    if (filename.length == 0) filename = sourceURL.lastPathComponent;
    if (filename.length == 0) filename = @"media.mov";
    NSMutableCharacterSet *invalidCharacters =
        [NSCharacterSet.controlCharacterSet mutableCopy];
    [invalidCharacters addCharactersInString:@"/\\:"];
    filename = [[filename componentsSeparatedByCharactersInSet:invalidCharacters]
        componentsJoinedByString:@"_"];
    filename = [filename stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (filename.length == 0 || [filename isEqualToString:@"."] ||
        [filename isEqualToString:@".."]) {
        filename = @"media.mov";
    }
    return filename;
}

static NSString *VCPDisplaySafeFilename(NSString *filename) {
    if (![filename isKindOfClass:NSString.class] || filename.length == 0) {
        return @"未命名媒体";
    }
    NSArray<NSString *> *parts = [filename componentsSeparatedByCharactersInSet:
        NSCharacterSet.controlCharacterSet];
    NSString *safe = [[parts componentsJoinedByString:@" "]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return safe.length > 0 ? safe : @"未命名媒体";
}

static NSURL *VCUniqueLocalMediaDestination(NSString *directory, NSString *filename) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *extension = filename.pathExtension;
    NSString *stem = filename.stringByDeletingPathExtension;
    for (NSUInteger index = 0; index < 1000; index++) {
        NSString *candidateName = filename;
        if (index > 0) {
            NSString *suffix = [NSString stringWithFormat:@"-%lu", (unsigned long)(index + 1)];
            candidateName = extension.length > 0
                ? [NSString stringWithFormat:@"%@%@.%@", stem, suffix, extension]
                : [stem stringByAppendingString:suffix];
        }
        NSString *candidatePath = [directory stringByAppendingPathComponent:candidateName];
        if (![fileManager fileExistsAtPath:candidatePath]) {
            return [NSURL fileURLWithPath:candidatePath isDirectory:NO];
        }
    }
    NSString *fallbackName = extension.length > 0
        ? [NSString stringWithFormat:@"%@-%@.%@", stem, NSUUID.UUID.UUIDString, extension]
        : [NSString stringWithFormat:@"%@-%@", stem, NSUUID.UUID.UUIDString];
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:fallbackName]
                     isDirectory:NO];
}

static NSURL *VCImportLocalMediaURL(NSURL *sourceURL,
                                    NSString *suggestedName,
                                    BOOL stopSecurityScopedAccess,
                                    NSError **errorOut) {
    if (!sourceURL.isFileURL || sourceURL.path.length == 0) {
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorInvalidSource,
                                          @"选择结果不是可读取的本地文件。", nil);
        }
        if (stopSecurityScopedAccess) [sourceURL stopAccessingSecurityScopedResource];
        return nil;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *directoryError = nil;
    if (![fileManager createDirectoryAtPath:VCLocalMediaDirectory
                withIntermediateDirectories:YES
                                 attributes:@{NSFileProtectionKey:
                                     NSFileProtectionCompleteUntilFirstUserAuthentication}
                                      error:&directoryError]) {
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorCreateDirectory,
                                          @"无法创建稳定的媒体保存目录。", directoryError);
        }
        if (stopSecurityScopedAccess) [sourceURL stopAccessingSecurityScopedResource];
        return nil;
    }

    NSString *filename = VCSafeLocalMediaFilename(sourceURL, suggestedName);
    NSString *extension = filename.pathExtension;
    NSString *stagingName = extension.length > 0
        ? [NSString stringWithFormat:@".%@.importing.%@", NSUUID.UUID.UUIDString, extension]
        : [NSString stringWithFormat:@".%@.importing", NSUUID.UUID.UUIDString];
    NSURL *stagingURL = [NSURL fileURLWithPath:
        [VCLocalMediaDirectory stringByAppendingPathComponent:stagingName]];
    NSURL *destinationURL = VCUniqueLocalMediaDestination(VCLocalMediaDirectory, filename);

    __block NSError *accessError = nil;
    __block BOOL copied = NO;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordinationError = nil;
    [coordinator coordinateReadingItemAtURL:sourceURL
                                    options:0
                                      error:&coordinationError
                                 byAccessor:^(NSURL *coordinatedURL) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:coordinatedURL.path
                                                                  error:&accessError];
        if (!attributes) return;
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) {
            accessError = VCLocalMediaError(VCLocalMediaImportErrorReadSource,
                                            @"所选项目不是普通媒体文件。", nil);
            return;
        }
        unsigned long long sourceSize = [attributes[NSFileSize] unsignedLongLongValue];
        if (sourceSize == 0) {
            accessError = VCLocalMediaError(VCLocalMediaImportErrorReadSource,
                                            @"所选媒体文件为空。", nil);
            return;
        }
        NSDictionary *fileSystem =
            [fileManager attributesOfFileSystemForPath:VCLocalMediaDirectory error:&accessError];
        if (!fileSystem) return;
        unsigned long long freeBytes = [fileSystem[NSFileSystemFreeSize] unsignedLongLongValue];
        unsigned long long requiredBytes = sourceSize > ULLONG_MAX - VCLocalMediaReserveBytes
            ? ULLONG_MAX : sourceSize + VCLocalMediaReserveBytes;
        if (freeBytes < requiredBytes) {
            accessError = VCLocalMediaError(VCLocalMediaImportErrorInsufficientSpace,
                [NSString stringWithFormat:@"存储空间不足：至少需要 %.1f MiB 可用空间（含安全余量）。",
                    (double)requiredBytes / (1024.0 * 1024.0)], nil);
            return;
        }
        copied = [fileManager copyItemAtURL:coordinatedURL toURL:stagingURL error:&accessError];
    }];
    if (stopSecurityScopedAccess) [sourceURL stopAccessingSecurityScopedResource];

    NSError *finalError = accessError ?: coordinationError;
    if (!copied || finalError) {
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorCopy,
                                          @"无法把媒体复制到稳定目录。", finalError);
        }
        return nil;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:stagingURL
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    BOOL containsVideo = [asset tracksWithMediaType:AVMediaTypeVideo].count > 0;
    BOOL containsAudio = [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
    if (!containsVideo && !containsAudio) {
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorUnsupportedMedia,
                                          @"所选文件不包含可识别的视频或音频轨道。", nil);
        }
        return nil;
    }

    NSError *moveError = nil;
    if (![fileManager moveItemAtURL:stagingURL toURL:destinationURL error:&moveError]) {
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorFinalize,
                                          @"媒体已经验证，但无法完成原子保存。", moveError);
        }
        return nil;
    }
    [fileManager setAttributes:@{NSFileProtectionKey:
        NSFileProtectionCompleteUntilFirstUserAuthentication}
                         ofItemAtPath:destinationURL.path error:nil];
    return destinationURL;
}

static BOOL VCPGetSystemStreamStatus(uint64_t *statusOut) {
    return VCPGetNotifyChannelState(VCPNotifyChannelStreamStatus, statusOut);
}

static uint64_t VCPMonotonicMilliseconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mach_timebase_info(&timebase); });
    uint64_t ticks = mach_continuous_time();
    long double nanos = ((long double)ticks * timebase.numer) / timebase.denom;
    return (uint64_t)(nanos / 1000000.0L);
}

static int VCPNotifyTokenForChannel(VCPNotifyChannel channel) {
    static dispatch_once_t onceToken;
    static int tokens[VCPNotifyChannelCount];
    dispatch_once(&onceToken, ^{
        for (NSUInteger index = 0; index < VCPNotifyChannelCount; index++) {
            tokens[index] = -1;
            int token = -1;
            if (notify_register_check(VCPNotifyChannelNames[index], &token) ==
                NOTIFY_STATUS_OK) {
                tokens[index] = token;
            }
        }
    });
    return channel < VCPNotifyChannelCount ? tokens[channel] : -1;
}

static BOOL VCPGetNotifyChannelState(VCPNotifyChannel channel,
                                     uint64_t *stateOut) {
    if (!stateOut) return NO;
    int token = VCPNotifyTokenForChannel(channel);
    return token >= 0 && notify_get_state(token, stateOut) == NOTIFY_STATUS_OK;
}

static BOOL VCPReadFinitePreferenceNumber(id value, double *numberOut) {
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class]) {
        return NO;
    }
    double number = [value doubleValue];
    if (!isfinite(number)) return NO;
    if (numberOut) *numberOut = number;
    return YES;
}

static BOOL VCPNumberIsIntegral(double number) {
    return isfinite(number) && fabs(number - round(number)) < 0.000001;
}

static BOOL VCPSetPreferenceValueIfDifferent(CFStringRef key, id value) {
    id current = CFBridgingRelease(CFPreferencesCopyAppValue(key,
                                                             VCPreferencesDomain));
    if ((current == value) || [current isEqual:value]) return NO;
    CFPreferencesSetAppValue(key, (__bridge CFPropertyListRef)value,
                             VCPreferencesDomain);
    return YES;
}

static BOOL VCPRepairStoredPreferences(void) {
    __block BOOL changed = NO;
    NSArray<NSDictionary *> *integerRules = @[
        @{ @"key": @"sourceType", @"default": @0,
           @"allowed": @[@0, @1, @2] },
        @{ @"key": @"preferredFPS", @"default": @60,
           @"minimum": @1, @"maximum": @240 },
        @{ @"key": @"sourceRotation", @"default": @0,
           @"allowed": @[@0, @90, @180, @270] },
        @{ @"key": @"maximumPixelDimension", @"default": @1920,
           @"allowed": @[@1280, @1920, @2560, @3840] },
    ];
    for (NSDictionary *rule in integerRules) {
        NSString *key = rule[@"key"];
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        double number = 0;
        BOOL valid = VCPReadFinitePreferenceNumber(value, &number) &&
                     VCPNumberIsIntegral(number);
        NSInteger integer = valid ? (NSInteger)llround(number) : 0;
        NSArray<NSNumber *> *allowed = rule[@"allowed"];
        if (valid && allowed) valid = [allowed containsObject:@(integer)];
        NSNumber *minimum = rule[@"minimum"];
        NSNumber *maximum = rule[@"maximum"];
        if (valid && minimum) valid = integer >= minimum.integerValue;
        if (valid && maximum) valid = integer <= maximum.integerValue;
        NSNumber *normalized = valid ? @(integer) : rule[@"default"];
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }

    NSArray<NSDictionary *> *realRules = @[
        @{ @"key": @"jpegQuality", @"default": @1.0,
           @"minimum": @0.5, @"maximum": @1.0 },
        @{ @"key": @"staleFrameTimeout", @"default": @8.0,
           @"minimum": @2.0, @"maximum": @30.0 },
    ];
    for (NSDictionary *rule in realRules) {
        NSString *key = rule[@"key"];
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        double number = 0;
        BOOL valid = VCPReadFinitePreferenceNumber(value, &number) &&
                     number >= [rule[@"minimum"] doubleValue] &&
                     number <= [rule[@"maximum"] doubleValue];
        NSNumber *normalized = valid ? @(number) : rule[@"default"];
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }

    NSDictionary<NSString *, NSNumber *> *booleanDefaults = @{
        @"enabled": @NO,
        @"loopLocalMedia": @YES,
        @"mirrorSource": @NO,
        @"aspectFill": @YES,
        @"holdLastFrame": @YES,
    };
    [booleanDefaults enumerateKeysAndObjectsUsingBlock:^(
        NSString *key, NSNumber *defaultValue, __unused BOOL *stop) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        NSNumber *normalized = nil;
        if ([value isKindOfClass:NSNumber.class] ||
            [value isKindOfClass:NSString.class]) {
            normalized = @([value boolValue]);
        } else {
            normalized = defaultValue;
        }
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }];

    NSDictionary<NSString *, NSString *> *stringDefaults = @{
        @"streamURL": @"",
        @"localMediaPath": @"",
        @"sourceRestartToken": @"",
    };
    [stringDefaults enumerateKeysAndObjectsUsingBlock:^(
        NSString *key, NSString *defaultValue, __unused BOOL *stop) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        NSString *normalized = [value isKindOfClass:NSString.class]
            ? value : defaultValue;
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }];

    if (changed) CFPreferencesAppSynchronize(VCPreferencesDomain);
    return changed;
}

@interface VCPRootListController : PSListController
    <NSURLSessionDataDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate> {
    VCJPEGParserState _streamTestJPEGParserState;
    NSUInteger _streamTestJPEGOffset;
    uint64_t _lastPreferencesSyncMilliseconds;
    BOOL _runtimePresentationDisabled;
    BOOL _dashboardLayoutInProgress;
}
@property (nonatomic, strong) NSURLSession *streamTestSession;
@property (nonatomic, strong) NSURLSessionDataTask *streamTestTask;
@property (nonatomic, strong) NSMutableData *streamTestData;
@property (nonatomic, copy) NSString *streamTestResponseSummary;
@property (nonatomic, strong) UIAlertController *streamTestAlert;
@property (nonatomic, assign) BOOL localMediaImportInProgress;
@property (nonatomic, strong) UIAlertController *localMediaImportAlert;
@property (nonatomic, strong) VCPDashboardHeaderView *dashboardHeader;
@property (nonatomic, strong) NSTimer *statusRefreshTimer;
- (void)finishStreamTestWithTitle:(NSString *)title message:(NSString *)message;
- (void)showStreamTestResultWithTitle:(NSString *)title message:(NSString *)message;
- (void)beginImportingLocalMediaURLs:(NSArray<NSURL *> *)urls
                      suggestedNames:(NSArray<NSString *> *)suggestedNames
                 securityAccessFlags:(NSArray<NSNumber *> *)securityAccessFlags;
- (void)finishLocalMediaImportsWithURLs:(NSArray<NSURL *> *)urls
                                  errors:(NSArray<NSError *> *)errors;
- (void)showLocalMediaImportProgressWithMessage:(NSString *)message
                                      completion:(dispatch_block_t)completion;
- (void)showLocalMediaResultWithTitle:(NSString *)title message:(NSString *)message;
- (void)installDashboardHeaderIfNeeded;
- (void)refreshRuntimePresentation;
- (void)layoutDashboardHeaderIfNeeded;
- (void)startStatusRefreshTimer;
- (void)stopStatusRefreshTimer;
- (void)performSafeRuntimePresentationRefresh;
- (void)disableRuntimePresentationAfterException:(NSException *)exception;
- (void)synchronizePreferencesIfNeeded:(BOOL)force;
- (NSArray<NSURL *> *)localMediaLibraryEntries;
- (id)currentPackageVersion:(PSSpecifier *)specifier;
- (id)currentNetworkEndpointSummary:(PSSpecifier *)specifier;
- (id)currentSourceConfigurationSummary:(PSSpecifier *)specifier;
- (id)currentLocalMediaName:(PSSpecifier *)specifier;
- (id)currentLocalMediaLibrarySummary:(PSSpecifier *)specifier;
- (id)currentSourceRuntimeStatus:(PSSpecifier *)specifier;
- (id)currentSystemVideoPipelineStatus:(PSSpecifier *)specifier;
- (id)currentLocalTransformStatus:(PSSpecifier *)specifier;
- (id)currentLocalVolumeHookStatus:(PSSpecifier *)specifier;
@end

@implementation VCPRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VirtualCamPro";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                            target:self
                            action:@selector(refreshControlPanel:)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"刷新运行状态";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    @try {
        if (_specifiers) [self reloadSpecifiers];
    } @catch (NSException *exception) {
        [self disableRuntimePresentationAfterException:exception];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Preferences.framework is private and differs between iOS point releases.
    // Wait until its table transition is complete before touching individual
    // rows; a failed optional refresh must never terminate the Settings app.
    [self performSafeRuntimePresentationRefresh];
    [self startStatusRefreshTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopStatusRefreshTimer];
}

- (void)installDashboardHeaderIfNeeded {
    UITableView *tableView = [self table];
    if (!tableView) return;
    if (!self.dashboardHeader) {
        self.dashboardHeader = [[VCPDashboardHeaderView alloc]
            initWithFrame:CGRectMake(0, 0, CGRectGetWidth(tableView.bounds), 150.0)];
    }
    if (tableView.tableHeaderView != self.dashboardHeader) {
        tableView.tableHeaderView = self.dashboardHeader;
    }
    [self layoutDashboardHeaderIfNeeded];
}

- (void)layoutDashboardHeaderIfNeeded {
    if (_dashboardLayoutInProgress || _runtimePresentationDisabled) return;
    UITableView *tableView = [self table];
    VCPDashboardHeaderView *header = self.dashboardHeader;
    CGFloat width = CGRectGetWidth(tableView.bounds);
    if (!tableView || !header || width <= 0) return;
    _dashboardLayoutInProgress = YES;
    @try {
        header.frame = CGRectMake(0, 0, width, MAX(1.0, CGRectGetHeight(header.frame)));
        CGSize fittingSize = [header systemLayoutSizeFittingSize:CGSizeMake(width, 1.0)
                                  withHorizontalFittingPriority:UILayoutPriorityRequired
                                        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        CGFloat height = MAX(142.0, ceil(fittingSize.height));
        if (fabs(CGRectGetHeight(header.frame) - height) > 0.5 ||
            fabs(CGRectGetWidth(header.frame) - width) > 0.5) {
            header.frame = CGRectMake(0, 0, width, height);
            tableView.tableHeaderView = header;
        }
    } @finally {
        _dashboardLayoutInProgress = NO;
    }
}

- (void)startStatusRefreshTimer {
    if (_runtimePresentationDisabled || self.statusRefreshTimer || !self.view.window) return;
    __weak VCPRootListController *weakSelf = self;
    self.statusRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                              repeats:YES
                                                                block:^(__unused NSTimer *timer) {
        VCPRootListController *strongSelf = weakSelf;
        if (strongSelf.view.window) [strongSelf performSafeRuntimePresentationRefresh];
    }];
    self.statusRefreshTimer.tolerance = 0.20;
}

- (void)stopStatusRefreshTimer {
    [self.statusRefreshTimer invalidate];
    self.statusRefreshTimer = nil;
}

- (void)performSafeRuntimePresentationRefresh {
    if (_runtimePresentationDisabled || !NSThread.isMainThread) return;
    @try {
        [self refreshRuntimePresentation];
    } @catch (NSException *exception) {
        [self disableRuntimePresentationAfterException:exception];
    }
}

- (void)disableRuntimePresentationAfterException:(NSException *)exception {
    if (_runtimePresentationDisabled) return;
    _runtimePresentationDisabled = YES;
    [self stopStatusRefreshTimer];
    NSLog(@"[VirtualCamPro] Optional Settings dashboard disabled after %@: %@",
          exception.name ?: @"exception", exception.reason ?: @"unknown reason");
    // Keep the native PreferenceLoader rows usable. The dashboard is optional,
    // so any layout/runtime incompatibility degrades to the static list.
    @try {
        UITableView *tableView = [self table];
        if (tableView.tableHeaderView == self.dashboardHeader) {
            tableView.tableHeaderView = nil;
        }
        self.dashboardHeader = nil;
        self.navigationItem.rightBarButtonItem = nil;
    } @catch (__unused NSException *cleanupException) {
    }
}

- (void)synchronizePreferencesIfNeeded:(BOOL)force {
    uint64_t now = VCPMonotonicMilliseconds();
    if (!force && _lastPreferencesSyncMilliseconds > 0 &&
        now >= _lastPreferencesSyncMilliseconds &&
        now - _lastPreferencesSyncMilliseconds < 750) {
        return;
    }
    CFPreferencesAppSynchronize(VCPreferencesDomain);
    _lastPreferencesSyncMilliseconds = now;
}

- (void)refreshControlPanel:(id)sender {
    [self performSafeRuntimePresentationRefresh];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

- (void)refreshRuntimePresentation {
    [self synchronizePreferencesIfNeeded:NO];
    // Only lightweight, read-only status rows opt into the one-second refresh.
    // Editing cells and sliders are never reloaded under the user's finger.
    for (PSSpecifier *specifier in [_specifiers copy]) {
        if ([[specifier propertyForKey:@"vcLiveStatus"] boolValue]) {
            // The one-argument selector exists across older iOS 15
            // Preferences.framework variants and internally requests a
            // non-animated reload.
            [self reloadSpecifier:specifier];
        }
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        VCPRepairStoredPreferences();
        [self synchronizePreferencesIfNeeded:YES];
        id sourceValue = CFBridgingRelease(
            CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
        NSInteger sourceTypeValue = [sourceValue integerValue];
        if (sourceTypeValue < 0 || sourceTypeValue > 2) sourceTypeValue = 0;
        NSNumber *sourceType = @(sourceTypeValue);
        NSArray *allSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        NSMutableArray *visible = [NSMutableArray arrayWithCapacity:allSpecifiers.count];
        for (PSSpecifier *specifier in allSpecifiers) {
            NSArray *sourceTypes = [specifier propertyForKey:@"vcSourceTypes"];
            if (![sourceTypes isKindOfClass:NSArray.class] ||
                [sourceTypes containsObject:sourceType]) {
                [visible addObject:specifier];
            }
        }
        _specifiers = visible;
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"preferredFPS"]) {
        NSInteger roundedFPS = (NSInteger)llround([value doubleValue]);
        value = @(MAX(1, MIN(240, roundedFPS)));
    }
    if ([key isEqualToString:@"streamURL"] && [value isKindOfClass:NSString.class]) {
        value = [value stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    [super setPreferenceValue:value specifier:specifier];
    [self synchronizePreferencesIfNeeded:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPreferencesChangedNotification,
                                         NULL,
                                         NULL,
                                          YES);
    if ([key isEqualToString:@"sourceType"]) {
        _specifiers = nil;
        @try {
            [self reloadSpecifiers];
        } @catch (NSException *exception) {
            [self disableRuntimePresentationAfterException:exception];
        }
    }
    for (PSSpecifier *statusSpecifier in [_specifiers copy]) {
        if ([[statusSpecifier propertyForKey:@"vcConfigurationStatus"] boolValue]) {
            @try {
                [self reloadSpecifier:statusSpecifier];
            } @catch (NSException *exception) {
                [self disableRuntimePresentationAfterException:exception];
                break;
            }
        }
    }
    [self performSafeRuntimePresentationRefresh];
}

- (void)chooseLocalMedia:(PSSpecifier *)specifier {
    if (self.localMediaImportInProgress || self.presentedViewController) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择本地媒体"
                                                                    message:@"选择后会复制并验证文件，随后自动设为当前替换来源。"
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    __weak VCPRootListController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"从“文件”选择视频或音频"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf) return;
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc]
                initWithDocumentTypes:@[@"public.movie", @"public.audio",
                                        @"public.audiovisual-content"]
                                 inMode:UIDocumentPickerModeOpen];
        picker.delegate = strongSelf;
        picker.allowsMultipleSelection = YES;
        if (@available(iOS 13.0, *)) picker.shouldShowFileExtensions = YES;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    }]];
    if (@available(iOS 14.0, *)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"从“照片”选择视频"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            VCPRootListController *strongSelf = weakSelf;
            if (!strongSelf) return;
            PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
            configuration.filter = PHPickerFilter.videosFilter;
            // A bounded batch makes the stable import directory immediately
            // useful as a volume-button playlist without opening unbounded
            // parallel iCloud downloads.
            configuration.selectionLimit = 20;
            configuration.preferredAssetRepresentationMode =
                PHPickerConfigurationAssetRepresentationModeCurrent;
            PHPickerViewController *picker =
                [[PHPickerViewController alloc] initWithConfiguration:configuration];
            picker.delegate = strongSelf;
            [strongSelf presentViewController:picker animated:YES completion:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                        CGRectGetMidY(self.view.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (id)currentPackageVersion:(PSSpecifier *)specifier {
    NSString *version = [[NSBundle bundleForClass:self.class]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && version.length > 0
        ? version : @"未知";
}

- (id)currentNetworkEndpointSummary:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id value = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("streamURL"), VCPreferencesDomain));
    if (![value isKindOfClass:NSString.class] || [value length] == 0) {
        return @"尚未配置 URL";
    }
    NSURL *url = [NSURL URLWithString:[value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    NSString *scheme = url.scheme.lowercaseString;
    if ((!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) ||
        url.host.length == 0 || url.user.length > 0 || url.password.length > 0 ||
        url.fragment.length > 0 || url.absoluteString.length > 4096) {
        return @"URL 格式无效";
    }
    BOOL hls = [url.absoluteString.lowercaseString containsString:@".m3u8"];
    NSString *host = url.port
        ? [NSString stringWithFormat:@"%@:%@", url.host, url.port] : url.host;
    return [NSString stringWithFormat:@"%@ · %@", hls ? @"HLS" : @"MJPEG", host];
}

- (id)currentSourceConfigurationSummary:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id sourceValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
    switch ([sourceValue integerValue]) {
        case 1:
            return @"设备屏幕实时镜像 · 系统方向";
        case 2: {
            NSString *name = [self currentLocalMediaName:nil];
            if ([name isEqualToString:@"尚未选择"]) {
                return @"手机本地媒体 · 尚未选择文件";
            }
            id pathValue = CFBridgingRelease(
                CFPreferencesCopyAppValue(VCLocalMediaPathKey, VCPreferencesDomain));
            if (![pathValue isKindOfClass:NSString.class] ||
                ![NSFileManager.defaultManager fileExistsAtPath:pathValue]) {
                return [NSString stringWithFormat:@"手机本地媒体 · %@（文件不存在）", name];
            }
            return [@"手机本地媒体 · " stringByAppendingString:name];
        }
        default:
            return [@"网络流 · " stringByAppendingString:
                [self currentNetworkEndpointSummary:nil]];
    }
}

- (NSArray<NSURL *> *)localMediaLibraryEntries {
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:[NSURL fileURLWithPath:VCLocalMediaDirectory isDirectory:YES]
       includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                            error:nil];
    NSIndexSet *regularIndexes = [entries indexesOfObjectsPassingTest:^BOOL(
        NSURL *entry, NSUInteger index, BOOL *stop) {
        NSNumber *regular = nil;
        [entry getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        return regular.boolValue;
    }];
    return [[entries objectsAtIndexes:regularIndexes]
        sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent localizedStandardCompare:right.lastPathComponent];
    }];
}

- (id)currentLocalMediaLibrarySummary:(PSSpecifier *)specifier {
    NSArray<NSURL *> *entries = [self localMediaLibraryEntries];
    unsigned long long totalBytes = 0;
    for (NSURL *entry in entries) {
        NSNumber *fileSize = nil;
        [entry getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        unsigned long long bytes = fileSize.unsignedLongLongValue;
        totalBytes = ULLONG_MAX - totalBytes < bytes ? ULLONG_MAX : totalBytes + bytes;
    }
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    NSString *size = [formatter stringFromByteCount:
        totalBytes > (unsigned long long)LLONG_MAX ? LLONG_MAX : (long long)totalBytes];
    return [NSString stringWithFormat:@"%lu 个文件 · %@",
        (unsigned long)entries.count, size ?: @"0 字节"];
}

- (id)currentLocalMediaName:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id pathValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(VCLocalMediaPathKey, VCPreferencesDomain));
    if (![pathValue isKindOfClass:NSString.class] || [pathValue length] == 0) {
        return @"尚未选择";
    }
    NSString *filename = [pathValue lastPathComponent];
    return filename.length > 0 ? VCPDisplaySafeFilename(filename) : @"尚未选择";
}

- (id)currentLocalVideoPlaylistSummary:(PSSpecifier *)specifier {
    static NSSet<NSString *> *videoExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExtensions = [NSSet setWithArray:@[
            @"mp4", @"mov", @"m4v", @"3gp", @"3g2", @"avi",
            @"mpg", @"mpeg", @"ts", @"mts", @"m2ts",
        ]];
    });
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:[NSURL fileURLWithPath:VCLocalMediaDirectory isDirectory:YES]
       includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                            error:nil];
    NSUInteger count = 0;
    for (NSURL *entry in entries) {
        NSNumber *regular = nil;
        [entry getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (regular.boolValue &&
            [videoExtensions containsObject:entry.pathExtension.lowercaseString]) {
            count++;
        }
    }
    return count >= 2
        ? [NSString stringWithFormat:@"%lu 段，可用音量 +/− 切换", (unsigned long)count]
        : [NSString stringWithFormat:@"%lu 段，至少需要 2 段", (unsigned long)count];
}

- (id)currentLocalTransformStatus:(PSSpecifier *)specifier {
    uint64_t state = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelLocalTransform, &state)) {
        return @"SpringBoard 状态不可用";
    }
    if (!(state & 1ULL)) {
        return @"等待启用本地媒体";
    }
    BOOL ready = (state & (1ULL << 1)) != 0;
    BOOL userMirror = (state & (1ULL << 2)) != 0;
    BOOL aspectFill = (state & (1ULL << 3)) != 0;
    BOOL trackMirror = (state & (1ULL << 4)) != 0;
    NSInteger userRotation = (NSInteger)((state >> 8) & 0x3) * 90;
    NSInteger trackRotation = (NSInteger)((state >> 10) & 0x3) * 90;
    NSInteger finalRotation = (trackRotation + userRotation) % 360;
    BOOL finalMirror = trackMirror != userMirror;
    return [NSString stringWithFormat:@"%@：%ld° · %@ · %@",
        ready ? @"已应用" : @"等待首帧",
        (long)finalRotation,
        finalMirror ? @"镜像" : @"不镜像",
        aspectFill ? @"填满" : @"完整显示"];
}

- (id)currentLocalVolumeHookStatus:(PSSpecifier *)specifier {
    uint64_t state = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelLocalVolumeHook, &state)) {
        return @"SpringBoard 状态不可用";
    }
    if (!(state & 1ULL)) return @"未安装，保留系统音量";
    BOOL buttons = (state & (1ULL << 1)) != 0;
    BOOL delta = (state & (1ULL << 2)) != 0;
    if (buttons && delta) return @"已安装：按键 + 增量双路径";
    return buttons ? @"已安装：音量按键路径" : @"已安装：音量增量路径";
}

- (id)currentSourceRuntimeStatus:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    if (![enabledValue boolValue]) return @"已停用";
    uint64_t status = VCPStreamStatusDisabled;
    if (!VCPGetSystemStreamStatus(&status)) return @"SpringBoard 状态不可用";
    switch (status) {
        case VCPStreamStatusConnecting: return @"正在初始化 / 重连";
        case VCPStreamStatusReceiving: return @"正在稳定产帧";
        case VCPStreamStatusError: return @"来源错误，正在恢复";
        case VCPStreamStatusHoldingLastFrame: return @"断流，保持最后一帧";
        case VCPStreamStatusCompleted: return @"本地媒体播放完成";
        default: return @"等待 SpringBoard 接管";
    }
}

- (id)currentSystemVideoPipelineStatus:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    if (![enabledValue boolValue]) return @"已停用";
    uint64_t timestamp = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelVideoPipeline, &timestamp) ||
        timestamp == 0) {
        return @"等待相机应用调用";
    }
    uint64_t now = VCPMonotonicMilliseconds();
    if (now >= timestamp && now - timestamp <= 1500) {
        return @"mediaserverd 最近已替换视频";
    }
    return @"当前无活跃系统视频输出";
}

- (void)reloadCurrentSource:(PSSpecifier *)specifier {
    NSString *token = NSUUID.UUID.UUIDString;
    CFPreferencesSetAppValue(VCSourceRestartTokenKey,
                             (__bridge CFStringRef)token,
                             VCPreferencesDomain);
    if (!CFPreferencesAppSynchronize(VCPreferencesDomain)) {
        [self showLocalMediaResultWithTitle:@"重载失败"
                                    message:@"内部重载代次无法保存，请稍后重试。"];
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPreferencesChangedNotification,
                                         NULL, NULL, YES);
    _specifiers = nil;
    [self reloadSpecifiers];
    [self showLocalMediaResultWithTitle:@"已请求重载"
                                message:@"SpringBoard 正在原子停止并重建当前来源；URL、本地文件和画面参数均保持不变。"];
}

- (void)showCurrentSourceGuide:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:YES];
    id sourceValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
    NSString *title = @"网络流使用顺序";
    NSString *message = @"1. 在 Windows 控制中心启动 OBS 桥接。\n2. 填写手机可访问的 HTTP/HTTPS URL。\n3. 点击“检测当前网络流”。\n4. 启用替换并重新打开相机应用。\n\n网络方向、帧率和质量全部由 OBS/发送端决定；手机保留原生麦克风。";
    switch ([sourceValue integerValue]) {
        case 1:
            title = @"屏幕镜像使用顺序";
            message = @"1. 选择设备屏幕实时镜像。\n2. 启用系统摄像头替换。\n3. 打开目标相机应用。\n\n屏幕方向和刷新节奏自动跟随设备；本地视频的旋转、镜像、FPS 和质量设置不会作用于屏幕来源。";
            break;
        case 2:
            title = @"本地媒体使用顺序";
            message = @"1. 点击“选择本地视频 / 音频”完成导入。\n2. 调整本地视频专用的旋转、镜像、FPS 和质量。\n3. 启用替换并打开相机应用。\n\n同一目录至少有两段视频时，音量加/减可切换下一段/上一段；纯音频文件只替换麦克风。";
            break;
        default:
            break;
    }
    [self showLocalMediaResultWithTitle:title message:message];
}

- (void)showLocalMediaLibrary:(PSSpecifier *)specifier {
    NSArray<NSURL *> *entries = [self localMediaLibraryEntries];
    NSString *selectedName = [self currentLocalMediaName:nil];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger visibleCount = MIN((NSUInteger)15, entries.count);
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    for (NSUInteger index = 0; index < visibleCount; index++) {
        NSURL *entry = entries[index];
        NSNumber *fileSize = nil;
        [entry getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        NSString *size = [formatter stringFromByteCount:fileSize.longLongValue];
        NSString *displayName = VCPDisplaySafeFilename(entry.lastPathComponent);
        NSString *marker = [displayName isEqualToString:selectedName] ? @"●" : @"○";
        [lines addObject:[NSString stringWithFormat:@"%@ %@  %@",
            marker, displayName, size ?: @""]];
    }
    if (entries.count > visibleCount) {
        [lines addObject:[NSString stringWithFormat:@"…另有 %lu 个文件",
            (unsigned long)(entries.count - visibleCount)]];
    }
    NSString *message = entries.count > 0
        ? [lines componentsJoinedByString:@"\n"]
        : @"媒体库目前为空。请使用“选择本地视频 / 音频”导入文件。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"本地媒体库 · %@",
            [self currentLocalMediaLibrarySummary:nil]]
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制媒体目录"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = VCLocalMediaDirectory;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyRuntimeDiagnostics:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:YES];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    id holdValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("holdLastFrame"), VCPreferencesDomain));
    id staleValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("staleFrameTimeout"), VCPreferencesDomain));
    id fpsValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("preferredFPS"), VCPreferencesDomain));
    id rotationValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceRotation"), VCPreferencesDomain));
    id mirrorValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("mirrorSource"), VCPreferencesDomain));
    id dimensionValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("maximumPixelDimension"), VCPreferencesDomain));
    NSISO8601DateFormatter *dateFormatter = [NSISO8601DateFormatter new];
    NSString *report = [NSString stringWithFormat:
        @"VirtualCamPro %@ runtime diagnostics\n"
         "generated=%@\n"
         "device=%@ / iOS %@\n"
         "enabled=%@\n"
         "source=%@\n"
         "sourceStatus=%@\n"
         "systemVideoPipeline=%@\n"
         "networkEndpoint=%@\n"
         "localMedia=%@\n"
         "localLibrary=%@\n"
         "localTransform=%@\n"
         "volumeHook=%@\n"
         "localFPS=%@ rotation=%@ mirror=%@ maxDimension=%@\n"
         "holdLastFrame=%@ staleTimeout=%@\n",
        [self currentPackageVersion:nil],
        [dateFormatter stringFromDate:NSDate.date],
        UIDevice.currentDevice.model,
        UIDevice.currentDevice.systemVersion,
        [enabledValue boolValue] ? @"yes" : @"no",
        [self currentSourceConfigurationSummary:nil],
        [self currentSourceRuntimeStatus:nil],
        [self currentSystemVideoPipelineStatus:nil],
        [self currentNetworkEndpointSummary:nil],
        [self currentLocalMediaName:nil],
        [self currentLocalMediaLibrarySummary:nil],
        [self currentLocalTransformStatus:nil],
        [self currentLocalVolumeHookStatus:nil],
        fpsValue ?: @60,
        rotationValue ?: @0,
        [mirrorValue boolValue] ? @"yes" : @"no",
        dimensionValue ?: @1920,
        holdValue ? ([holdValue boolValue] ? @"yes" : @"no") : @"yes",
        staleValue ?: @8];
    UIPasteboard.generalPasteboard.string = report;
    [self showLocalMediaResultWithTitle:@"诊断信息已复制"
                                message:@"已复制运行状态和安全化来源摘要；网络 URL 的查询参数和访问令牌不会写入诊断文本。"];
}

- (void)clearLocalMedia:(PSSpecifier *)specifier {
    if (self.localMediaImportInProgress) {
        [self showLocalMediaResultWithTitle:@"正在导入"
                                    message:@"请等待当前媒体完成复制和验证后再清除。"];
        return;
    }
    CFPreferencesSetAppValue(VCLocalMediaPathKey, NULL, VCPreferencesDomain);
    BOOL synchronized = CFPreferencesAppSynchronize(VCPreferencesDomain);
    if (!synchronized) {
        [self showLocalMediaResultWithTitle:@"清除失败"
                                    message:@"设置暂时无法保存，请稍后重试。"];
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPreferencesChangedNotification,
                                         NULL, NULL, YES);
    _specifiers = nil;
    [self reloadSpecifiers];
    [self showLocalMediaResultWithTitle:@"已清除当前选择"
                                message:@"已导入的文件仍保留在媒体目录中，不会被自动删除。"];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
   didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSArray<NSURL *> *selectedURLs = urls.count > 64
        ? [urls subarrayWithRange:NSMakeRange(0, 64)] : urls;
    if (selectedURLs.count == 0) return;
    NSMutableArray<NSNumber *> *securityFlags =
        [NSMutableArray arrayWithCapacity:selectedURLs.count];
    NSMutableArray<NSString *> *suggestedNames =
        [NSMutableArray arrayWithCapacity:selectedURLs.count];
    for (NSURL *url in selectedURLs) {
        [securityFlags addObject:@([url startAccessingSecurityScopedResource])];
        [suggestedNames addObject:url.lastPathComponent ?: @"media.mov"];
    }
    __weak VCPRootListController *weakSelf = self;
    [controller dismissViewControllerAnimated:YES completion:^{
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf) {
            [selectedURLs enumerateObjectsUsingBlock:^(NSURL *url,
                                                       NSUInteger index,
                                                       BOOL *stop) {
                if ([securityFlags[index] boolValue]) {
                    [url stopAccessingSecurityScopedResource];
                }
            }];
            return;
        }
        [strongSelf beginImportingLocalMediaURLs:selectedURLs
                                  suggestedNames:suggestedNames
                             securityAccessFlags:securityFlags];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:url ? @[url] : @[]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    __weak VCPRootListController *weakSelf = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf || results.count == 0) return;
        BOOL containsVideo = [results indexOfObjectPassingTest:^BOOL(
            PHPickerResult *result, NSUInteger index, BOOL *stop) {
            return [result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"];
        }] != NSNotFound;
        if (!containsVideo) {
            [strongSelf showLocalMediaResultWithTitle:@"无法读取视频"
                                               message:@"照片选择结果不包含可导入的视频文件。"];
            return;
        }
        strongSelf.localMediaImportInProgress = YES;
        [strongSelf showLocalMediaImportProgressWithMessage:@"正在从“照片”读取、复制并验证视频…"
                                                 completion:^{
            NSMutableArray *orderedURLs = [NSMutableArray arrayWithCapacity:results.count];
            NSMutableArray *orderedErrors = [NSMutableArray arrayWithCapacity:results.count];
            for (NSUInteger index = 0; index < results.count; index++) {
                [orderedURLs addObject:NSNull.null];
                [orderedErrors addObject:NSNull.null];
            }
            dispatch_group_t group = dispatch_group_create();
            [results enumerateObjectsUsingBlock:^(PHPickerResult *result,
                                                   NSUInteger index,
                                                   BOOL *stop) {
                NSItemProvider *provider = result.itemProvider;
                if (![provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
                    @synchronized (orderedURLs) {
                        orderedErrors[index] = VCLocalMediaError(
                            VCLocalMediaImportErrorReadSource,
                            @"一个照片项目不包含视频文件。", nil);
                    }
                    return;
                }
                dispatch_group_enter(group);
                [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                    completionHandler:^(NSURL *url, NSError *providerError) {
                    NSError *importError = providerError;
                    NSURL *importedURL = nil;
                    if (url && !providerError) {
                        // Providers may callback concurrently and temporary URLs
                        // are only valid inside this block. Serialize final-name
                        // reservation/copy while keeping each URL alive.
                        @synchronized ([VCPRootListController class]) {
                            importedURL = VCImportLocalMediaURL(url,
                                                               provider.suggestedName,
                                                               NO,
                                                               &importError);
                        }
                    }
                    if (!url && !importError) {
                        importError = VCLocalMediaError(VCLocalMediaImportErrorReadSource,
                            @"照片没有返回可读取的视频文件。", nil);
                    }
                    @synchronized (orderedURLs) {
                        if (importedURL) orderedURLs[index] = importedURL;
                        if (importError) orderedErrors[index] = importError;
                    }
                    dispatch_group_leave(group);
                }];
            }];
            dispatch_group_notify(group,
                                  dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSMutableArray<NSURL *> *imported = [NSMutableArray array];
                NSMutableArray<NSError *> *errors = [NSMutableArray array];
                @synchronized (orderedURLs) {
                    for (NSUInteger index = 0; index < orderedURLs.count; index++) {
                        if ([orderedURLs[index] isKindOfClass:NSURL.class]) {
                            [imported addObject:orderedURLs[index]];
                        }
                        if ([orderedErrors[index] isKindOfClass:NSError.class]) {
                            [errors addObject:orderedErrors[index]];
                        }
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf finishLocalMediaImportsWithURLs:imported errors:errors];
                });
            });
        }];
    }];
}

- (void)beginImportingLocalMediaURLs:(NSArray<NSURL *> *)urls
                      suggestedNames:(NSArray<NSString *> *)suggestedNames
                 securityAccessFlags:(NSArray<NSNumber *> *)securityAccessFlags {
    if (urls.count == 0 || self.localMediaImportInProgress) {
        [urls enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger index, BOOL *stop) {
            if (index < securityAccessFlags.count && securityAccessFlags[index].boolValue) {
                [url stopAccessingSecurityScopedResource];
            }
        }];
        return;
    }
    self.localMediaImportInProgress = YES;
    __weak VCPRootListController *weakSelf = self;
    [self showLocalMediaImportProgressWithMessage:@"正在复制并验证媒体，请稍候…"
                                       completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSMutableArray<NSURL *> *importedURLs = [NSMutableArray array];
            NSMutableArray<NSError *> *importErrors = [NSMutableArray array];
            [urls enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger index, BOOL *stop) {
                NSError *importError = nil;
                NSString *suggestedName = index < suggestedNames.count
                    ? suggestedNames[index] : url.lastPathComponent;
                BOOL stopSecurityAccess = index < securityAccessFlags.count
                    ? securityAccessFlags[index].boolValue : NO;
                NSURL *importedURL = VCImportLocalMediaURL(url,
                                                           suggestedName,
                                                           stopSecurityAccess,
                                                           &importError);
                if (importedURL) [importedURLs addObject:importedURL];
                if (importError) [importErrors addObject:importError];
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf finishLocalMediaImportsWithURLs:importedURLs errors:importErrors];
            });
        });
    }];
}

- (void)showLocalMediaImportProgressWithMessage:(NSString *)message
                                      completion:(dispatch_block_t)completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"正在导入本地媒体"
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = nil;
    if (@available(iOS 13.0, *)) {
        indicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    } else {
        indicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    }
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-18.0],
    ]];
    self.localMediaImportAlert = alert;
    [self presentViewController:alert animated:YES completion:completion];
}

- (void)finishLocalMediaImportsWithURLs:(NSArray<NSURL *> *)urls
                                  errors:(NSArray<NSError *> *)errors {
    if (![NSThread isMainThread]) {
        __weak VCPRootListController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishLocalMediaImportsWithURLs:urls errors:errors];
        });
        return;
    }
    UIAlertController *progressAlert = self.localMediaImportAlert;
    self.localMediaImportAlert = nil;
    self.localMediaImportInProgress = NO;

    NSURL *url = urls.firstObject;
    NSError *error = errors.firstObject;
    NSString *title = @"导入失败";
    NSString *message = error.localizedDescription ?: @"无法导入所选媒体。";
    if (url) {
        CFPreferencesSetAppValue(VCLocalMediaPathKey,
                                 (__bridge CFPropertyListRef)url.path,
                                 VCPreferencesDomain);
        if (CFPreferencesAppSynchronize(VCPreferencesDomain)) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 VCPreferencesChangedNotification,
                                                 NULL, NULL, YES);
            _specifiers = nil;
            [self reloadSpecifiers];
            title = urls.count > 1 ? @"本地视频播放列表已就绪" : @"本地媒体已就绪";
            message = urls.count > 1
                ? [NSString stringWithFormat:
                    @"已成功导入 %lu 个媒体文件，当前从 %@ 开始。音量加/减可切换稳定目录中的下一段/上一段视频。%@",
                    (unsigned long)urls.count,
                    url.lastPathComponent,
                    errors.count > 0
                        ? [NSString stringWithFormat:@"\n\n另有 %lu 个文件导入失败。",
                            (unsigned long)errors.count] : @""]
                : [NSString stringWithFormat:@"已选择：%@\n\n稳定路径：%@%@",
                    url.lastPathComponent,
                    url.path,
                    errors.count > 0 ? @"\n\n其余选择项导入失败。" : @""];
        } else {
            title = @"媒体已复制，但设置保存失败";
            message = [NSString stringWithFormat:@"文件保存在 %@，请重新选择一次。", url.path];
        }
    }

    void (^showResult)(void) = ^{
        [self showLocalMediaResultWithTitle:title message:message];
    };
    if (progressAlert.presentingViewController) {
        [progressAlert dismissViewControllerAnimated:YES completion:showResult];
    } else {
        showResult();
    }
}

- (void)showLocalMediaResultWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)testStreamConnection:(PSSpecifier *)specifier {
    if (self.streamTestTask) return;
    [self synchronizePreferencesIfNeeded:YES];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    id sourceTypeValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
    NSString *streamValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("streamURL"), VCPreferencesDomain));
    NSString *trimmedValue = [streamValue isKindOfClass:[NSString class]]
        ? [streamValue stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    NSURL *streamURL = [NSURL URLWithString:trimmedValue];
    if (sourceTypeValue && [sourceTypeValue integerValue] != 0) {
        [self showStreamTestResultWithTitle:@"当前不是网络来源"
                                   message:@"请将“替换来源”切换为网络 HLS / MJPEG 后再检测 URL。屏幕和本地媒体由 SpringBoard 本地读取，不建立网络连接。"];
        return;
    }
    NSString *scheme = streamURL.scheme.lowercaseString;
    if ((!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) ||
        streamURL.host.length == 0 || streamURL.user.length > 0 ||
        streamURL.password.length > 0 || streamURL.fragment.length > 0 ||
        streamURL.absoluteString.length > 4096) {
        [self showStreamTestResultWithTitle:@"URL 无效"
                                   message:@"请先填写完整的 HTTP/HTTPS 网络流 URL。"];
        return;
    }

    if ([enabledValue boolValue]) {
        uint64_t status = VCPStreamStatusDisabled;
        VCPGetSystemStreamStatus(&status);
        switch (status) {
            case VCPStreamStatusReceiving:
                [self showStreamTestResultWithTitle:@"网络流可用"
                                           message:@"SpringBoard 媒体服务正在接收有效网络帧；无需建立第二条测试连接。"];
                return;
            case VCPStreamStatusConnecting:
                [self showStreamTestResultWithTitle:@"正在连接"
                                           message:@"SpringBoard 媒体服务正在连接当前 URL。请确认 Windows 桥接已启动，稍后再检测。"];
                return;
            case VCPStreamStatusError:
                [self showStreamTestResultWithTitle:@"连接需要恢复"
                                           message:@"SpringBoard 媒体服务已检测到断流并正在自动重连。请检查 Windows 桥接、IP 与防火墙。"];
                return;
            case VCPStreamStatusHoldingLastFrame:
                [self showStreamTestResultWithTitle:@"正在保持最后一帧"
                                           message:@"网络连接正在恢复，系统相机仍输出最后收到的替换帧；请检查 Windows 桥接和网络稳定性。"];
                return;
            default:
                [self showStreamTestResultWithTitle:@"媒体服务尚未接管"
                                           message:@"替换已启用，但 SpringBoard 尚未报告来源状态。请确认 SpringBoard 注入成功并检查系统日志。"];
                return;
        }
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 8.0;
    configuration.timeoutIntervalForResource = 8.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.HTTPMaximumConnectionsPerHost = 1;
    self.streamTestData = [NSMutableData data];
    _streamTestJPEGOffset = NSNotFound;
    VCJPEGParserReset(&_streamTestJPEGParserState);
    self.streamTestResponseSummary = @"服务器已响应";
    self.streamTestSession = [NSURLSession sessionWithConfiguration:configuration
                                                           delegate:self
                                                      delegateQueue:[NSOperationQueue mainQueue]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:streamURL];
    [request setValue:@"multipart/x-mixed-replace,image/jpeg,application/vnd.apple.mpegurl,*/*;q=0.1"
   forHTTPHeaderField:@"Accept"];
    self.streamTestTask = [self.streamTestSession dataTaskWithRequest:request];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"正在检测网络流"
                                                                    message:@"等待服务器返回有效画面数据…"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak VCPRootListController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf finishStreamTestWithTitle:@"已取消" message:@"网络流检测已取消。"];
    }]];
    self.streamTestAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
    [self.streamTestTask resume];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if (session != self.streamTestSession || dataTask != self.streamTestTask) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)response : nil;
    if (httpResponse && (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300)) {
        completionHandler(NSURLSessionResponseCancel);
        [self finishStreamTestWithTitle:@"连接失败"
                                message:[NSString stringWithFormat:@"服务器返回 HTTP %ld。",
                                         (long)httpResponse.statusCode]];
        return;
    }
    NSString *mimeType = response.MIMEType.lowercaseString ?: @"未知类型";
    if ([mimeType isEqualToString:@"text/html"] ||
        [mimeType isEqualToString:@"application/json"]) {
        completionHandler(NSURLSessionResponseCancel);
        [self finishStreamTestWithTitle:@"内容类型不正确"
                                message:[NSString stringWithFormat:@"服务器返回 %@，不是视频流。",
                                         mimeType]];
        return;
    }
    self.streamTestResponseSummary = [NSString stringWithFormat:@"HTTP 连接正常，内容类型：%@", mimeType];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (session != self.streamTestSession || dataTask != self.streamTestTask || data.length == 0) return;
    NSUInteger remainingCapacity = self.streamTestData.length < VCPStreamTestMaximumBytes
        ? VCPStreamTestMaximumBytes - self.streamTestData.length : 0;
    if (remainingCapacity > 0) {
        [self.streamTestData appendBytes:data.bytes
                                  length:MIN(data.length, remainingCapacity)];
    }

    static NSData *jpegStartMarker;
    static NSData *hlsHeader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        static const unsigned char markerBytes[] = {0xFF, 0xD8};
        jpegStartMarker = [NSData dataWithBytes:markerBytes length:sizeof(markerBytes)];
        hlsHeader = [@"#EXTM3U" dataUsingEncoding:NSUTF8StringEncoding];
    });
    NSRange range = NSMakeRange(0, self.streamTestData.length);
    BOOL containsJPEG = NO;
    while (!containsJPEG && self.streamTestData.length >= 2) {
        if (_streamTestJPEGOffset == NSNotFound) {
            NSRange jpegStart = [self.streamTestData rangeOfData:jpegStartMarker
                                                         options:0
                                                           range:range];
            if (jpegStart.location == NSNotFound) break;
            _streamTestJPEGOffset = jpegStart.location;
            VCJPEGParserReset(&_streamTestJPEGParserState);
        }
        const uint8_t *jpegBytes =
            (const uint8_t *)self.streamTestData.bytes + _streamTestJPEGOffset;
        NSUInteger jpegBytesLength = self.streamTestData.length - _streamTestJPEGOffset;
        size_t parsedFrameLength = 0;
        VCJPEGParserResult parserResult = VCJPEGParserConsume(jpegBytes,
                                                               jpegBytesLength,
                                                               &_streamTestJPEGParserState,
                                                               &parsedFrameLength);
        if (parserResult == VCJPEGParserResultFrameComplete) {
            containsJPEG = parsedFrameLength > 0;
            break;
        }
        if (parserResult == VCJPEGParserResultNeedMoreData) break;

        NSUInteger nextSearchOffset = _streamTestJPEGOffset + jpegStartMarker.length;
        VCJPEGParserReset(&_streamTestJPEGParserState);
        _streamTestJPEGOffset = NSNotFound;
        if (nextSearchOffset >= self.streamTestData.length) break;
        NSRange nextRange = NSMakeRange(nextSearchOffset,
                                        self.streamTestData.length - nextSearchOffset);
        NSRange nextStart = [self.streamTestData rangeOfData:jpegStartMarker
                                                     options:0
                                                       range:nextRange];
        if (nextStart.location == NSNotFound) break;
        _streamTestJPEGOffset = nextStart.location;
    }
    BOOL containsHLS = [self.streamTestData rangeOfData:hlsHeader
                                                options:0
                                                  range:range].location != NSNotFound;
    if (containsJPEG || containsHLS) {
        NSString *format = containsJPEG ? @"MJPEG/JPEG" : @"HLS";
        [self finishStreamTestWithTitle:@"网络流可用"
                                message:[NSString stringWithFormat:@"%@；已收到有效 %@ 数据。",
                                         self.streamTestResponseSummary, format]];
    } else if (self.streamTestData.length >= VCPStreamTestMaximumBytes) {
        [self finishStreamTestWithTitle:@"未识别到画面"
                                message:@"服务器可连接，但前 8 MiB 中没有完整 JPEG 或 HLS 标记。"];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (session != self.streamTestSession || task != self.streamTestTask) return;
    NSString *message = error.localizedDescription ?: @"服务器在返回画面前关闭了连接。";
    [self finishStreamTestWithTitle:@"连接失败" message:message];
}

- (void)finishStreamTestWithTitle:(NSString *)title message:(NSString *)message {
    if (!self.streamTestTask) return;
    NSURLSessionDataTask *task = self.streamTestTask;
    NSURLSession *session = self.streamTestSession;
    UIAlertController *progressAlert = self.streamTestAlert;
    self.streamTestTask = nil;
    self.streamTestSession = nil;
    self.streamTestData = nil;
    self.streamTestResponseSummary = nil;
    self.streamTestAlert = nil;
    _streamTestJPEGOffset = NSNotFound;
    VCJPEGParserReset(&_streamTestJPEGParserState);
    [task cancel];
    [session invalidateAndCancel];

    void (^showResult)(void) = ^{
        [self showStreamTestResultWithTitle:title message:message];
    };
    if (progressAlert.presentingViewController) {
        [progressAlert dismissViewControllerAnimated:YES completion:showResult];
    } else {
        showResult();
    }
}

- (void)showStreamTestResultWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc {
    [self stopStatusRefreshTimer];
    [self.streamTestTask cancel];
    [self.streamTestSession invalidateAndCancel];
}

@end
