#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <substrate.h>

#import "VCAudioSampleConverter.h"
#import "VCFrameConverter.h"
#import "VCSharedMediaBus.h"
#import "VCStreamCoordinator.h"

typedef void (*VCEmitSampleBufferFunction)(id, SEL, CMSampleBufferRef);
typedef void (*VCVolumeButtonFunction)(id, SEL);
typedef struct {
    Class nodeClass;
    VCEmitSampleBufferFunction original;
} VCNodeOutputHook;

static const NSUInteger VCMaximumNodeOutputHooks = 64;
static VCNodeOutputHook VCNodeOutputHooks[64];
static _Atomic(uint32_t) VCNodeOutputHookCount = 0;
static BOOL VCMediaServerHookInstalled = NO;
static BOOL VCMediaServerRetryScheduled = NO;
static _Atomic(uint32_t) VCMediaServerRescanScheduled = 0;
static BOOL VCMediaServerCanQueryVideoMediaType = NO;
static BOOL VCMediaServerCanQueryAudioMediaType = NO;
static SEL VCMediaTypeIsVideoSelector = NULL;
static SEL VCMediaTypeIsAudioSelector = NULL;
static dispatch_once_t VCConversionFailureLogToken;
static dispatch_once_t VCUnsupportedPixelFormatLogToken;
static CFStringRef const VCReplacedSampleAttachmentKey =
    CFSTR("com.murkaska.virtualcampro.system-replacement.v1");
static VCVolumeButtonFunction VCOriginalIncreaseVolume = NULL;
static VCVolumeButtonFunction VCOriginalDecreaseVolume = NULL;
static BOOL VCIncreaseVolumeHookInstalled = NO;
static BOOL VCDecreaseVolumeHookInstalled = NO;

static void VCInstallMediaServerHook(NSUInteger attempt);
static void VCInstallSpringBoardVolumeHooks(NSUInteger attempt);

static BOOL VCMethodIsVoidWithNoExplicitArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'v';
}

static void VCSpringBoardIncreaseVolume(id object, SEL selector) {
    if ([[VCStreamCoordinator sharedCoordinator]
            handleLocalMediaVolumeButtonDirection:1]) return;
    if (VCOriginalIncreaseVolume) VCOriginalIncreaseVolume(object, selector);
}

static void VCSpringBoardDecreaseVolume(id object, SEL selector) {
    if ([[VCStreamCoordinator sharedCoordinator]
            handleLocalMediaVolumeButtonDirection:-1]) return;
    if (VCOriginalDecreaseVolume) VCOriginalDecreaseVolume(object, selector);
}

static void VCInstallSpringBoardVolumeHooks(NSUInteger attempt) {
    Class volumeControlClass = objc_getClass("SBVolumeControl");
    if (volumeControlClass) {
        SEL increaseSelector = sel_registerName("increaseVolume");
        SEL decreaseSelector = sel_registerName("decreaseVolume");
        Method increaseMethod = class_getInstanceMethod(volumeControlClass, increaseSelector);
        Method decreaseMethod = class_getInstanceMethod(volumeControlClass, decreaseSelector);
        if (!VCIncreaseVolumeHookInstalled &&
            VCMethodIsVoidWithNoExplicitArguments(increaseMethod)) {
            MSHookMessageEx(volumeControlClass,
                            increaseSelector,
                            (IMP)VCSpringBoardIncreaseVolume,
                            (IMP *)&VCOriginalIncreaseVolume);
            VCIncreaseVolumeHookInstalled = VCOriginalIncreaseVolume != NULL;
        }
        if (!VCDecreaseVolumeHookInstalled &&
            VCMethodIsVoidWithNoExplicitArguments(decreaseMethod)) {
            MSHookMessageEx(volumeControlClass,
                            decreaseSelector,
                            (IMP)VCSpringBoardDecreaseVolume,
                            (IMP *)&VCOriginalDecreaseVolume);
            VCDecreaseVolumeHookInstalled = VCOriginalDecreaseVolume != NULL;
        }
        if (VCIncreaseVolumeHookInstalled && VCDecreaseVolumeHookInstalled) {
            NSLog(@"[VirtualCamPro] SpringBoard local-playlist volume controls installed");
            return;
        }
    }
    if (attempt >= 20) {
        NSLog(@"[VirtualCamPro] SBVolumeControl selectors unavailable; volume keeps its original behavior");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VCInstallSpringBoardVolumeHooks(attempt + 1);
    });
}

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

static BOOL VCNodeOutputIsAudio(id object) {
    if (!VCMediaServerCanQueryAudioMediaType || !VCMediaTypeIsAudioSelector) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, VCMediaTypeIsAudioSelector);
}

static VCEmitSampleBufferFunction VCOriginalEmitForObject(id object) {
    uint32_t count = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_acquire);
    for (Class current = object_getClass(object); current; current = class_getSuperclass(current)) {
        for (uint32_t index = 0; index < count; index++) {
            if (VCNodeOutputHooks[index].nodeClass == current) {
                return VCNodeOutputHooks[index].original;
            }
        }
    }
    return NULL;
}

static void VCMediaServerEmitSampleBuffer(id object, SEL selector, CMSampleBufferRef originalBuffer) {
    VCEmitSampleBufferFunction originalEmit = VCOriginalEmitForObject(object);
    if (!originalEmit) return;
    @autoreleasepool {
        if (!originalBuffer) {
            originalEmit(object, selector, originalBuffer);
            return;
        }
        if (CMGetAttachment(originalBuffer,
                            VCReplacedSampleAttachmentKey,
                            NULL) == kCFBooleanTrue) {
            originalEmit(object, selector, originalBuffer);
            return;
        }

        CVPixelBufferRef originalPixelBuffer = CMSampleBufferGetImageBuffer(originalBuffer);
        if (originalPixelBuffer && VCNodeOutputIsVideo(object)) {
            OSType originalPixelFormat = CVPixelBufferGetPixelFormatType(originalPixelBuffer);
            if (!VCIsSupportedReplacementPixelFormat(originalPixelFormat)) {
                dispatch_once(&VCUnsupportedPixelFormatLogToken, ^{
                    NSLog(@"[VirtualCamPro] Preserving non-color BWNodeOutput pixel format %u",
                          (unsigned int)originalPixelFormat);
                });
                originalEmit(object, selector, originalBuffer);
                return;
            }

            VCStreamCoordinator *coordinator = VCStreamCoordinator.sharedCoordinator;
            BOOL aspectFill = YES;
            NSInteger preferredFPS = 60;
            CVPixelBufferRef source = [coordinator
                copyLatestPixelBufferWithAspectFill:&aspectFill preferredFPS:&preferredFPS];
            if (!source) {
                originalEmit(object, selector, originalBuffer);
                return;
            }
            CMSampleBufferRef replacement = VCCopyReplacementSampleBuffer(originalBuffer,
                                                                           source,
                                                                           aspectFill,
                                                                           preferredFPS);
            VCReleaseSharedVideoPixelBuffer(source);
            if (!replacement) {
                dispatch_once(&VCConversionFailureLogToken, ^{
                    NSLog(@"[VirtualCamPro] System video conversion failed for %zux%zu/%u; fail-open",
                          CVPixelBufferGetWidth(originalPixelBuffer),
                          CVPixelBufferGetHeight(originalPixelBuffer),
                          (unsigned int)originalPixelFormat);
                });
            } else {
                CMSetAttachment(replacement,
                                VCReplacedSampleAttachmentKey,
                                kCFBooleanTrue,
                                kCMAttachmentMode_ShouldNotPropagate);
            }
            originalEmit(object, selector, replacement ?: originalBuffer);
            if (replacement) {
                VCMarkSystemPipelineActivity(VCSharedMediaKindVideo);
                CFRelease(replacement);
            }
            return;
        }

        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(originalBuffer);
        const AudioStreamBasicDescription *asbd = format
            ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
        if (asbd && VCNodeOutputIsAudio(object) &&
            [[VCSharedAudioClient sharedClient] hasPublishedAudioWithMaximumAge:2.0]) {
            CMSampleBufferRef replacement =
                VCCopyReplacementAudioSampleBuffer(originalBuffer);
            if (replacement) {
                CMSetAttachment(replacement,
                                VCReplacedSampleAttachmentKey,
                                kCFBooleanTrue,
                                kCMAttachmentMode_ShouldNotPropagate);
            }
            originalEmit(object, selector, replacement ?: originalBuffer);
            if (replacement) {
                VCMarkSystemPipelineActivity(VCSharedMediaKindAudio);
                CFRelease(replacement);
            }
            return;
        }

        // Depth, disparity, metadata and compressed auxiliary streams never
        // enter either replacement path.
        originalEmit(object, selector, originalBuffer);
    }
}

static BOOL VCClassIsSubclassOfClass(Class candidate, Class baseClass) {
    for (Class current = candidate; current; current = class_getSuperclass(current)) {
        if (current == baseClass) return YES;
    }
    return NO;
}

static Method VCDirectInstanceMethod(Class candidate, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(candidate, &methodCount);
    Method result = NULL;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL VCClassAlreadyHooked(Class candidate) {
    uint32_t count = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_acquire);
    for (uint32_t index = 0; index < count; index++) {
        if (VCNodeOutputHooks[index].nodeClass == candidate) return YES;
    }
    return NO;
}

static BOOL VCHookNodeOutputClass(Class candidate, SEL emitSelector) {
    if (!candidate || VCClassAlreadyHooked(candidate)) return NO;
    Method method = VCDirectInstanceMethod(candidate, emitSelector);
    if (!method) return NO;
    if (!VCMethodAcceptsSampleBuffer(method)) {
        NSLog(@"[VirtualCamPro] Refusing unexpected %@ emitSampleBuffer: signature",
              NSStringFromClass(candidate));
        return NO;
    }
    uint32_t slot = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_relaxed);
    if (slot >= VCMaximumNodeOutputHooks) {
        NSLog(@"[VirtualCamPro] BWNodeOutput subclass hook limit reached");
        return NO;
    }
    VCNodeOutputHooks[slot].nodeClass = candidate;
    VCNodeOutputHooks[slot].original =
        (VCEmitSampleBufferFunction)method_getImplementation(method);
    atomic_store_explicit(&VCNodeOutputHookCount, slot + 1, memory_order_release);
    MSHookMessageEx(candidate,
                    emitSelector,
                    (IMP)VCMediaServerEmitSampleBuffer,
                    (IMP *)&VCNodeOutputHooks[slot].original);
    return VCNodeOutputHooks[slot].original != NULL;
}

static void VCInstallMediaServerHook(NSUInteger attempt) {
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
        VCMediaTypeIsAudioSelector = sel_registerName("mediaTypeIsAudio");
        Method audioMethod = class_getInstanceMethod(nodeOutputClass,
                                                      VCMediaTypeIsAudioSelector);
        VCMediaServerCanQueryAudioMediaType = VCMethodReturnsBoolean(audioMethod);
        VCMediaServerRetryScheduled = NO;
        uint32_t previousCount = atomic_load_explicit(&VCNodeOutputHookCount,
                                                       memory_order_acquire);
        VCHookNodeOutputClass(nodeOutputClass, emitSelector);

        int classCount = objc_getClassList(NULL, 0);
        if (classCount > 0) {
            Class *classes = calloc((size_t)classCount, sizeof(Class));
            int populated = classes ? objc_getClassList(classes, classCount) : 0;
            for (int index = 0; index < populated; index++) {
                Class candidate = classes[index];
                if (candidate != nodeOutputClass &&
                    VCClassIsSubclassOfClass(candidate, nodeOutputClass)) {
                    VCHookNodeOutputClass(candidate, emitSelector);
                }
            }
            free(classes);
        }
        uint32_t installedCount = atomic_load_explicit(&VCNodeOutputHookCount,
                                                        memory_order_acquire);
        VCMediaServerHookInstalled = installedCount > 0;
        if (installedCount != previousCount) {
            NSLog(@"[VirtualCamPro] mediaserverd BWNodeOutput hooks %@ (%u classes, video %@, audio %@)",
                  VCMediaServerHookInstalled ? @"installed" : @"failed",
                  installedCount,
                  VCMediaServerCanQueryVideoMediaType ? @"typed" : @"sample-classified",
                  VCMediaServerCanQueryAudioMediaType ? @"typed" : @"sample-classified");
        }
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
    if (atomic_exchange_explicit(&VCMediaServerRescanScheduled,
                                 1,
                                 memory_order_acq_rel) != 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(&VCMediaServerRescanScheduled, 0, memory_order_release);
        VCInstallMediaServerHook(0);
    });
}


%ctor {
    @autoreleasepool {
        NSString *processName = NSProcessInfo.processInfo.processName;
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if ([processName isEqualToString:@"SpringBoard"] ||
            [bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            [[VCStreamCoordinator sharedCoordinator] startMonitoring];
            dispatch_async(dispatch_get_main_queue(), ^{
                VCInstallSpringBoardVolumeHooks(0);
            });
            return;
        }
        if (![processName isEqualToString:@"mediaserverd"]) return;
        [[VCStreamCoordinator sharedCoordinator] startMonitoring];
        _dyld_register_func_for_add_image(VCMediaServerImageDidLoad);
        dispatch_async(dispatch_get_main_queue(), ^{
            VCInstallMediaServerHook(0);
        });
    }
}
