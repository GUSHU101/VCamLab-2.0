#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>

#import "../VCJPEGParser.h"

static CFStringRef const VCPreferencesChangedNotification = CFSTR("com.murkaska.virtualcampro/preferences.changed");
static CFStringRef const VCPreferencesDomain = CFSTR("com.murkaska.virtualcampro");
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

@interface VCPRootListController : PSListController <NSURLSessionDataDelegate> {
    VCJPEGParserState _streamTestJPEGParserState;
    NSUInteger _streamTestJPEGOffset;
}
@property (nonatomic, strong) NSURLSession *streamTestSession;
@property (nonatomic, strong) NSURLSessionDataTask *streamTestTask;
@property (nonatomic, strong) NSMutableData *streamTestData;
@property (nonatomic, copy) NSString *streamTestResponseSummary;
@property (nonatomic, strong) UIAlertController *streamTestAlert;
- (void)finishStreamTestWithTitle:(NSString *)title message:(NSString *)message;
- (void)showStreamTestResultWithTitle:(NSString *)title message:(NSString *)message;
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
