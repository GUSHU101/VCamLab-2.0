#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "VCFrameConverter.h"
#import "VCStreamCoordinator.h"

static void (*VCOriginalEmitSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;
static BOOL VCMediaServerHookInstalled = NO;
static BOOL VCMediaServerRetryScheduled = NO;
static BOOL VCMediaServerCanQueryVideoMediaType = NO;
static SEL VCMediaTypeIsVideoSelector = NULL;
static dispatch_once_t VCConversionFailureLogToken;
static dispatch_once_t VCUnsupportedPixelFormatLogToken;

static void VCInstallMediaServerHook(NSUInteger attempt);

static BOOL VCMethodAcceptsSampleBuffer(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;

    char returnType[16] = {0};
    char argumentType[128] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));

    const char *unqualifiedType = argumentType;
    while (*unqualifiedType == 'r' || *unqualifiedType == 'n' ||
           *unqualifiedType == 'N' || *unqualifiedType == 'o' ||
           *unqualifiedType == 'O' || *unqualifiedType == 'R' ||
           *unqualifiedType == 'V') {
        unqualifiedType++;
    }
    return returnType[0] == 'v' && unqualifiedType[0] == '^';
}

static BOOL VCMethodReturnsBoolean(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *unqualifiedType = returnType;
    while (*unqualifiedType == 'r' || *unqualifiedType == 'n' ||
           *unqualifiedType == 'N' || *unqualifiedType == 'o' ||
           *unqualifiedType == 'O' || *unqualifiedType == 'R' ||
           *unqualifiedType == 'V') {
        unqualifiedType++;
    }
    return unqualifiedType[0] == 'B' || unqualifiedType[0] == 'c';
}

static BOOL VCNodeOutputIsVideo(id object) {
    if (!VCMediaServerCanQueryVideoMediaType || !VCMediaTypeIsVideoSelector) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, VCMediaTypeIsVideoSelector);
}

static void VCMediaServerEmitSampleBuffer(id object, SEL selector, CMSampleBufferRef originalBuffer) {
    if (!VCOriginalEmitSampleBuffer) return;
    @autoreleasepool {
        if (!originalBuffer || !VCNodeOutputIsVideo(object)) {
            VCOriginalEmitSampleBuffer(object, selector, originalBuffer);
            return;
        }

        CVPixelBufferRef originalPixelBuffer = CMSampleBufferGetImageBuffer(originalBuffer);
        if (!originalPixelBuffer) {
            VCOriginalEmitSampleBuffer(object, selector, originalBuffer);
            return;
        }
        OSType originalPixelFormat = CVPixelBufferGetPixelFormatType(originalPixelBuffer);
        if (!VCIsSupportedReplacementPixelFormat(originalPixelFormat)) {
            dispatch_once(&VCUnsupportedPixelFormatLogToken, ^{
                NSLog(@"[VirtualCamPro] Skipping non-color or unsupported BWNodeOutput pixel format %u",
                      (unsigned int)originalPixelFormat);
            });
            VCOriginalEmitSampleBuffer(object, selector, originalBuffer);
            return;
        }

        VCStreamCoordinator *coordinator = [VCStreamCoordinator sharedCoordinator];
        BOOL aspectFill = YES;
        NSInteger preferredFPS = 60;
        CVPixelBufferRef source = [coordinator copyLatestPixelBufferWithAspectFill:&aspectFill
                                                                     preferredFPS:&preferredFPS];
        if (!source) {
            VCOriginalEmitSampleBuffer(object, selector, originalBuffer);
            return;
        }

        CMSampleBufferRef replacement = VCCopyReplacementSampleBuffer(originalBuffer,
                                                                       source,
                                                                       aspectFill,
                                                                       preferredFPS);
        CVPixelBufferRelease(source);
        if (!replacement) {
            dispatch_once(&VCConversionFailureLogToken, ^{
                NSLog(@"[VirtualCamPro] Frame conversion failed for %zux%zu pixel format %u; preserving real frame",
                      CVPixelBufferGetWidth(originalPixelBuffer),
                      CVPixelBufferGetHeight(originalPixelBuffer),
                      (unsigned int)originalPixelFormat);
            });
        }
        VCOriginalEmitSampleBuffer(object, selector, replacement ?: originalBuffer);
        if (replacement) CFRelease(replacement);
    }
}

static void VCInstallMediaServerHook(NSUInteger attempt) {
    if (VCMediaServerHookInstalled) return;

    Class nodeOutputClass = objc_getClass("BWNodeOutput");
    SEL emitSelector = sel_registerName("emitSampleBuffer:");
    Method method = nodeOutputClass ? class_getInstanceMethod(nodeOutputClass, emitSelector) : NULL;
    if (method) {
        if (!VCMethodAcceptsSampleBuffer(method)) {
            NSLog(@"[VirtualCamPro] BWNodeOutput emitSampleBuffer: has an unexpected runtime signature");
            return;
        }
        VCMediaTypeIsVideoSelector = sel_registerName("mediaTypeIsVideo");
        Method videoMethod = class_getInstanceMethod(nodeOutputClass,
                                                      VCMediaTypeIsVideoSelector);
        VCMediaServerCanQueryVideoMediaType = VCMethodReturnsBoolean(videoMethod);
        VCMediaServerRetryScheduled = NO;
        MSHookMessageEx(nodeOutputClass,
                        emitSelector,
                        (IMP)VCMediaServerEmitSampleBuffer,
                        (IMP *)&VCOriginalEmitSampleBuffer);
        VCMediaServerHookInstalled = VCOriginalEmitSampleBuffer != NULL;
        NSLog(@"[VirtualCamPro] mediaserverd BWNodeOutput hook %@ (video-type filter %@)",
              VCMediaServerHookInstalled ? @"installed" : @"failed",
              VCMediaServerCanQueryVideoMediaType ? @"enabled" : @"unavailable");
        return;
    }

    if (attempt >= 20) {
        NSLog(@"[VirtualCamPro] BWNodeOutput emitSampleBuffer: unavailable on this iOS build");
        return;
    }
    if (VCMediaServerRetryScheduled) return;
    VCMediaServerRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VCMediaServerRetryScheduled = NO;
        VCInstallMediaServerHook(attempt + 1);
    });
}

static void VCMediaServerImageDidLoad(const struct mach_header *header, intptr_t slide) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VCInstallMediaServerHook(0);
    });
}


%ctor {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"mediaserverd"]) return;
        [[VCStreamCoordinator sharedCoordinator] startMonitoring];
        _dyld_register_func_for_add_image(VCMediaServerImageDidLoad);
        dispatch_async(dispatch_get_main_queue(), ^{
            VCInstallMediaServerHook(0);
        });
    }
}
