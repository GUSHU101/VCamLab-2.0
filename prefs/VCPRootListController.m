#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <limits.h>
#import <math.h>
#import <notify.h>

#import "../VCJPEGParser.h"

static CFStringRef const VCPreferencesChangedNotification = CFSTR("com.murkaska.virtualcampro/preferences.changed");
static CFStringRef const VCPreferencesDomain = CFSTR("com.murkaska.virtualcampro");
static CFStringRef const VCLocalMediaPathKey = CFSTR("localMediaPath");
static NSString * const VCLocalMediaDirectory = @"/var/mobile/Media/VirtualCamPro";
static NSString * const VCLocalMediaImportErrorDomain = @"com.murkaska.virtualcampro.media-import";
static const unsigned long long VCLocalMediaReserveBytes = 64ULL * 1024ULL * 1024ULL;
static const char *VCStreamStatusNotificationName =
    "com.murkaska.virtualcampro/stream.status";
static const NSUInteger VCPStreamTestMaximumBytes = 8 * 1024 * 1024;

typedef NS_ENUM(uint64_t, VCPStreamStatus) {
    VCPStreamStatusDisabled = 0,
    VCPStreamStatusConnecting = 1,
    VCPStreamStatusReceiving = 2,
    VCPStreamStatusError = 3,
    VCPStreamStatusHoldingLastFrame = 4,
};

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
    NSCharacterSet *invalidCharacters =
        [NSCharacterSet characterSetWithCharactersInString:@"/\\:"];
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
    int token = -1;
    if (notify_register_check(VCStreamStatusNotificationName, &token) != NOTIFY_STATUS_OK) {
        return NO;
    }
    uint64_t status = VCPStreamStatusDisabled;
    uint32_t result = notify_get_state(token, &status);
    notify_cancel(token);
    if (result != NOTIFY_STATUS_OK) return NO;
    if (statusOut) *statusOut = status;
    return YES;
}

@interface VCPRootListController : PSListController
    <NSURLSessionDataDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate> {
    VCJPEGParserState _streamTestJPEGParserState;
    NSUInteger _streamTestJPEGOffset;
}
@property (nonatomic, strong) NSURLSession *streamTestSession;
@property (nonatomic, strong) NSURLSessionDataTask *streamTestTask;
@property (nonatomic, strong) NSMutableData *streamTestData;
@property (nonatomic, copy) NSString *streamTestResponseSummary;
@property (nonatomic, strong) UIAlertController *streamTestAlert;
@property (nonatomic, assign) BOOL localMediaImportInProgress;
@property (nonatomic, strong) UIAlertController *localMediaImportAlert;
- (void)finishStreamTestWithTitle:(NSString *)title message:(NSString *)message;
- (void)showStreamTestResultWithTitle:(NSString *)title message:(NSString *)message;
- (void)beginImportingLocalMediaURL:(NSURL *)url
                     suggestedName:(NSString *)suggestedName
       stopSecurityScopedAccessWhenDone:(BOOL)stopSecurityScopedAccess;
- (void)finishLocalMediaImportWithURL:(NSURL *)url error:(NSError *)error;
- (void)showLocalMediaImportProgressWithMessage:(NSString *)message
                                      completion:(dispatch_block_t)completion;
- (void)showLocalMediaResultWithTitle:(NSString *)title message:(NSString *)message;
@end

@implementation VCPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        CFPreferencesAppSynchronize(VCPreferencesDomain);
        id sourceValue = CFBridgingRelease(
            CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
        NSNumber *sourceType = @([sourceValue integerValue]);
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
    [super setPreferenceValue:value specifier:specifier];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPreferencesChangedNotification,
                                         NULL,
                                         NULL,
                                          YES);
    if ([key isEqualToString:@"sourceType"]) {
        _specifiers = nil;
        [self reloadSpecifiers];
    }
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
        picker.allowsMultipleSelection = NO;
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
            configuration.selectionLimit = 1;
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

- (id)currentLocalMediaName:(PSSpecifier *)specifier {
    CFPreferencesAppSynchronize(VCPreferencesDomain);
    id pathValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(VCLocalMediaPathKey, VCPreferencesDomain));
    if (![pathValue isKindOfClass:NSString.class] || [pathValue length] == 0) {
        return @"尚未选择";
    }
    NSString *filename = [pathValue lastPathComponent];
    return filename.length > 0 ? filename : @"尚未选择";
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
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL securityAccess = [url startAccessingSecurityScopedResource];
    __weak VCPRootListController *weakSelf = self;
    [controller dismissViewControllerAnimated:YES completion:^{
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf) {
            if (securityAccess) [url stopAccessingSecurityScopedResource];
            return;
        }
        [strongSelf beginImportingLocalMediaURL:url
                                 suggestedName:url.lastPathComponent
               stopSecurityScopedAccessWhenDone:securityAccess];
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
    PHPickerResult *result = results.firstObject;
    NSItemProvider *provider = result.itemProvider;
    __weak VCPRootListController *weakSelf = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf || !provider) return;
        if (![provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
            [strongSelf showLocalMediaResultWithTitle:@"无法读取视频"
                                               message:@"照片选择结果不包含可导入的视频文件。"];
            return;
        }
        strongSelf.localMediaImportInProgress = YES;
        [strongSelf showLocalMediaImportProgressWithMessage:@"正在从“照片”读取、复制并验证视频…"
                                                 completion:^{
            [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                             completionHandler:^(NSURL *url, NSError *providerError) {
                if (!url || providerError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf finishLocalMediaImportWithURL:nil error:providerError ?:
                            VCLocalMediaError(VCLocalMediaImportErrorReadSource,
                                              @"照片没有返回可读取的视频文件。", nil)];
                    });
                    return;
                }
                NSError *importError = nil;
                NSURL *importedURL = VCImportLocalMediaURL(url, provider.suggestedName,
                                                           NO, &importError);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf finishLocalMediaImportWithURL:importedURL error:importError];
                });
            }];
        }];
    }];
}

- (void)beginImportingLocalMediaURL:(NSURL *)url
                     suggestedName:(NSString *)suggestedName
       stopSecurityScopedAccessWhenDone:(BOOL)stopSecurityScopedAccess {
    if (!url || self.localMediaImportInProgress) {
        if (stopSecurityScopedAccess) [url stopAccessingSecurityScopedResource];
        return;
    }
    self.localMediaImportInProgress = YES;
    __weak VCPRootListController *weakSelf = self;
    [self showLocalMediaImportProgressWithMessage:@"正在复制并验证媒体，请稍候…"
                                       completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError *importError = nil;
            NSURL *importedURL = VCImportLocalMediaURL(url, suggestedName,
                                                       stopSecurityScopedAccess, &importError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf finishLocalMediaImportWithURL:importedURL error:importError];
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

- (void)finishLocalMediaImportWithURL:(NSURL *)url error:(NSError *)error {
    if (![NSThread isMainThread]) {
        __weak VCPRootListController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishLocalMediaImportWithURL:url error:error];
        });
        return;
    }
    UIAlertController *progressAlert = self.localMediaImportAlert;
    self.localMediaImportAlert = nil;
    self.localMediaImportInProgress = NO;

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
            title = @"本地媒体已就绪";
            message = [NSString stringWithFormat:@"已选择：%@\n\n稳定路径：%@",
                       url.lastPathComponent, url.path];
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
    CFPreferencesAppSynchronize(VCPreferencesDomain);
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
    [self.streamTestTask cancel];
    [self.streamTestSession invalidateAndCancel];
}

@end
