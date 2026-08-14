#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdint.h>
#import <substrate.h>
#import <float.h>
#import <math.h>

#import "VCAudioSampleConverter.h"
#import "VCFrameConverter.h"
#import "VCSharedMediaBus.h"
#import "VCSharedMediaProtocol.h"
#import "VCStreamCoordinator.h"

typedef void (*VCEmitSampleBufferFunction)(id, SEL, CMSampleBufferRef);
typedef void (*VCVolumeButtonFunction)(id, SEL);
typedef void (*VCVolumeDeltaFunction)(id, SEL, CGFloat);
typedef struct {
    Class nodeClass;
    VCEmitSampleBufferFunction original;
} VCNodeOutputHook;

typedef struct {
    _Atomic(Class) runtimeClass;
    _Atomic(VCEmitSampleBufferFunction) original;
} VCNodeOutputDispatchEntry;

static const NSUInteger VCMaximumNodeOutputHooks = 64;
static VCNodeOutputHook VCNodeOutputHooks[64];
static _Atomic(uint32_t) VCNodeOutputHookCount = 0;
static const NSUInteger VCNodeOutputDispatchCacheSize = 128;
static VCNodeOutputDispatchEntry VCNodeOutputDispatchCache[128];
static BOOL VCMediaServerHookInstalled = NO;
static BOOL VCMediaServerRetryScheduled = NO;
static _Atomic(uint32_t) VCMediaServerRescanScheduled = 0;
static BOOL VCMediaServerCanQueryVideoMediaType = NO;
static BOOL VCMediaServerCanQueryAudioMediaType = NO;
static SEL VCMediaTypeIsVideoSelector = NULL;
static SEL VCMediaTypeIsAudioSelector = NULL;
static dispatch_once_t VCConversionFailureLogToken;
static dispatch_once_t VCUnsupportedPixelFormatLogToken;
static dispatch_once_t VCHookUnavailableLogToken;
static CFStringRef const VCReplacedSampleAttachmentKey =
    CFSTR(VC_SYSTEM_REPLACEMENT_ATTACHMENT_KEY);
static char VCAudioReplacementContextAssociationKey;
static VCVolumeButtonFunction VCOriginalIncreaseVolume = NULL;
static VCVolumeButtonFunction VCOriginalDecreaseVolume = NULL;
static BOOL VCIncreaseVolumeHookInstalled = NO;
static BOOL VCDecreaseVolumeHookInstalled = NO;
static VCVolumeDeltaFunction VCOriginalChangeVolumeByDelta = NULL;
static BOOL VCChangeVolumeByDeltaHookInstalled = NO;
static const char *VCLocalVolumeHookStatusNotificationName =
    "com.murkaska.virtualcampro/local-volume-hook.status";

static void VCInstallMediaServerHook(NSUInteger attempt);
static void VCInstallSpringBoardVolumeHooks(NSUInteger attempt);

static void VCPublishVolumeHookStatus(void) {
    int token = -1;
    if (notify_register_check(VCLocalVolumeHookStatusNotificationName, &token) !=
        NOTIFY_STATUS_OK) return;
    BOOL buttonPair = VCIncreaseVolumeHookInstalled && VCDecreaseVolumeHookInstalled;
    uint64_t state = (buttonPair || VCChangeVolumeByDeltaHookInstalled) ? 1ULL : 0ULL;
    if (buttonPair) state |= 1ULL << 1;
    if (VCChangeVolumeByDeltaHookInstalled) state |= 1ULL << 2;
    notify_set_state(token, state);
    notify_post(VCLocalVolumeHookStatusNotificationName);
    notify_cancel(token);
}

static BOOL VCMethodIsVoidWithNoExplicitArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'v';
}

static BOOL VCMethodIsVoidWithCGFloatArgument(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char returnType[16] = {0};
    char argumentType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *type = argumentType;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') type++;
    // All supported devices are arm64/arm64e, where CGFloat is encoded as a
    // double. Refuse an unexpected ABI instead of corrupting SpringBoard state.
    return returnType[0] == 'v' && type[0] == 'd';
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

static void VCSpringBoardChangeVolumeByDelta(id object, SEL selector, CGFloat delta) {
    if (isfinite(delta) && fabs(delta) > DBL_EPSILON &&
        [[VCStreamCoordinator sharedCoordinator]
            handleLocalMediaVolumeButtonDirection:delta > 0.0 ? 1 : -1]) return;
    if (VCOriginalChangeVolumeByDelta) {
        VCOriginalChangeVolumeByDelta(object, selector, delta);
    }
}

static void VCInstallSpringBoardVolumeHooks(NSUInteger attempt) {
    if (attempt == 0) VCPublishVolumeHookStatus();
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
        if (!VCChangeVolumeByDeltaHookInstalled) {
            const char *deltaSelectorNames[] = {
                "_changeVolumeByDelta:",
                "changeVolumeByDelta:",
            };
            for (NSUInteger index = 0;
                 index < sizeof(deltaSelectorNames) / sizeof(deltaSelectorNames[0]);
                 index++) {
                SEL deltaSelector = sel_registerName(deltaSelectorNames[index]);
                Method deltaMethod = class_getInstanceMethod(volumeControlClass, deltaSelector);
                if (!VCMethodIsVoidWithCGFloatArgument(deltaMethod)) continue;
                MSHookMessageEx(volumeControlClass,
                                deltaSelector,
                                (IMP)VCSpringBoardChangeVolumeByDelta,
                                (IMP *)&VCOriginalChangeVolumeByDelta);
                VCChangeVolumeByDeltaHookInstalled =
                    VCOriginalChangeVolumeByDelta != NULL;
                if (VCChangeVolumeByDeltaHookInstalled) break;
            }
        }
        if ((VCIncreaseVolumeHookInstalled && VCDecreaseVolumeHookInstalled) ||
            VCChangeVolumeByDeltaHookInstalled) {
            VCPublishVolumeHookStatus();
            NSLog(@"[VirtualCamPro] SpringBoard local-playlist volume controls installed "
                   "(buttons=%@, delta=%@)",
                  (VCIncreaseVolumeHookInstalled && VCDecreaseVolumeHookInstalled)
                      ? @"YES" : @"NO",
                  VCChangeVolumeByDeltaHookInstalled ? @"YES" : @"NO");
            return;
        }
    }
    if (attempt >= 20) {
        VCPublishVolumeHookStatus();
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

static VCAudioReplacementContext *VCAudioContextForNode(id object) {
    if (!object) return nil;
    @synchronized (object) {
        VCAudioReplacementContext *context = objc_getAssociatedObject(
            object,
            &VCAudioReplacementContextAssociationKey);
        if (!context) {
            context = [VCAudioReplacementContext new];
            objc_setAssociatedObject(object,
                                     &VCAudioReplacementContextAssociationKey,
                                     context,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return context;
    }
}

static NSUInteger VCNodeOutputDispatchIndex(Class runtimeClass) {
    return (((uintptr_t)runtimeClass) >> 4) &
        (VCNodeOutputDispatchCacheSize - 1);
}

static VCEmitSampleBufferFunction VCCachedOriginalEmitForClass(Class runtimeClass) {
    if (!runtimeClass) return NULL;
    NSUInteger start = VCNodeOutputDispatchIndex(runtimeClass);
    for (NSUInteger probe = 0; probe < VCNodeOutputDispatchCacheSize; probe++) {
        NSUInteger index = (start + probe) & (VCNodeOutputDispatchCacheSize - 1);
        Class cachedClass = atomic_load_explicit(
            &VCNodeOutputDispatchCache[index].runtimeClass,
            memory_order_acquire);
        if (cachedClass == runtimeClass) {
            return atomic_load_explicit(&VCNodeOutputDispatchCache[index].original,
                                        memory_order_acquire);
        }
        if (!cachedClass) return NULL;
    }
    return NULL;
}

static void VCCacheOriginalEmitForClass(Class runtimeClass,
                                        VCEmitSampleBufferFunction original) {
    if (!runtimeClass || !original) return;
    NSUInteger start = VCNodeOutputDispatchIndex(runtimeClass);
    for (NSUInteger probe = 0; probe < VCNodeOutputDispatchCacheSize; probe++) {
        NSUInteger index = (start + probe) & (VCNodeOutputDispatchCacheSize - 1);
        Class cachedClass = atomic_load_explicit(
            &VCNodeOutputDispatchCache[index].runtimeClass,
            memory_order_acquire);
        if (cachedClass == runtimeClass) {
            atomic_store_explicit(&VCNodeOutputDispatchCache[index].original,
                                  original,
                                  memory_order_release);
            return;
        }
        if (!cachedClass) {
            Class empty = Nil;
            if (atomic_compare_exchange_strong_explicit(
                    &VCNodeOutputDispatchCache[index].runtimeClass,
                    &empty,
                    runtimeClass,
                    memory_order_acq_rel,
                    memory_order_acquire)) {
                atomic_store_explicit(&VCNodeOutputDispatchCache[index].original,
                                      original,
                                      memory_order_release);
                return;
            }
        }
    }
}

static VCEmitSampleBufferFunction VCOriginalEmitForObject(id object) {
    Class runtimeClass = object_getClass(object);
    VCEmitSampleBufferFunction cached =
        VCCachedOriginalEmitForClass(runtimeClass);
    if (cached) return cached;
    uint32_t count = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_acquire);
    for (Class current = runtimeClass; current; current = class_getSuperclass(current)) {
        for (uint32_t index = 0; index < count; index++) {
            if (VCNodeOutputHooks[index].nodeClass == current) {
                VCEmitSampleBufferFunction original =
                    VCNodeOutputHooks[index].original;
                VCCacheOriginalEmitForClass(runtimeClass, original);
                return original;
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
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeUnsupportedPixelFormat,
                    0);
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
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeSourceUnavailable,
                    0);
                originalEmit(object, selector, originalBuffer);
                return;
            }
            CMSampleBufferRef replacement = VCCopyReplacementSampleBuffer(originalBuffer,
                                                                           source,
                                                                           aspectFill,
                                                                           preferredFPS);
            VCReleaseSharedVideoPixelBuffer(source);
            if (!replacement) {
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeConversionFailed,
                    0);
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
                                kCMAttachmentMode_ShouldPropagate);
                CVPixelBufferRef replacementPixelBuffer =
                    CMSampleBufferGetImageBuffer(replacement);
                if (replacementPixelBuffer) {
                    CVBufferSetAttachment(replacementPixelBuffer,
                                          VCReplacedSampleAttachmentKey,
                                          kCFBooleanTrue,
                                          kCVAttachmentMode_ShouldPropagate);
                }
            }
            originalEmit(object, selector, replacement ?: originalBuffer);
            if (replacement) {
                VCMarkSystemPipelineActivity(VCSharedMediaKindVideo);
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeReplacementSucceeded,
                    0);
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
                VCCopyReplacementAudioSampleBuffer(originalBuffer,
                                                    VCAudioContextForNode(object));
            if (replacement) {
                CMSetAttachment(replacement,
                                VCReplacedSampleAttachmentKey,
                                kCFBooleanTrue,
                                kCMAttachmentMode_ShouldPropagate);
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

static BOOL VCHookNodeOutputClass(Class candidate,
                                  SEL emitSelector,
                                  BOOL allowInheritedMethod) {
    if (!candidate || VCClassAlreadyHooked(candidate)) return NO;
    // Some iOS 15 point releases inherit emitSampleBuffer: into BWNodeOutput
    // instead of declaring it directly. Hook that inherited implementation at
    // the BWNodeOutput boundary, while subclasses are still limited to direct
    // overrides so the same inherited IMP is never wrapped repeatedly.
    Method method = allowInheritedMethod
        ? class_getInstanceMethod(candidate, emitSelector)
        : VCDirectInstanceMethod(candidate, emitSelector);
    if (!method) return NO;
    if (!VCMethodAcceptsSampleBuffer(method)) {
        VCReportMediaServerVideoRuntimeEvent(
            VCMediaServerVideoRuntimeIncompatibleSignature,
            0);
        NSLog(@"[VirtualCamPro] Refusing unexpected %@ emitSampleBuffer: signature",
              NSStringFromClass(candidate));
        return NO;
    }
    uint32_t slot = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_relaxed);
    if (slot >= VCMaximumNodeOutputHooks) {
        VCReportMediaServerVideoRuntimeEvent(
            VCMediaServerVideoRuntimeHookCapacityExceeded,
            UINT8_MAX);
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
    VCCacheOriginalEmitForClass(candidate, VCNodeOutputHooks[slot].original);
    return VCNodeOutputHooks[slot].original != NULL;
}

static void VCScheduleMediaServerHookRetry(NSUInteger attempt,
                                           NSTimeInterval delay) {
    if (VCMediaServerRetryScheduled) return;
    VCMediaServerRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VCMediaServerRetryScheduled = NO;
        VCInstallMediaServerHook(attempt);
    });
}

static void VCInstallMediaServerHook(NSUInteger attempt) {
    VCReportMediaServerVideoRuntimeEvent(
        VCMediaServerVideoRuntimeScanning,
        (uint8_t)MIN(attempt, (NSUInteger)UINT8_MAX));
    Class nodeOutputClass = objc_getClass("BWNodeOutput");
    SEL emitSelector = sel_registerName("emitSampleBuffer:");
    if (nodeOutputClass) {
        VCMediaTypeIsVideoSelector = sel_registerName("mediaTypeIsVideo");
        Method videoMethod = class_getInstanceMethod(nodeOutputClass,
                                                      VCMediaTypeIsVideoSelector);
        VCMediaServerCanQueryVideoMediaType = VCMethodReturnsBoolean(videoMethod);
        VCMediaTypeIsAudioSelector = sel_registerName("mediaTypeIsAudio");
        Method audioMethod = class_getInstanceMethod(nodeOutputClass,
                                                      VCMediaTypeIsAudioSelector);
        VCMediaServerCanQueryAudioMediaType = VCMethodReturnsBoolean(audioMethod);
        uint32_t previousCount = atomic_load_explicit(&VCNodeOutputHookCount,
                                                       memory_order_acquire);
        VCHookNodeOutputClass(nodeOutputClass, emitSelector, YES);

        int classCount = objc_getClassList(NULL, 0);
        if (classCount > 0) {
            Class __unsafe_unretained *classes =
                (__unsafe_unretained Class *)calloc((size_t)classCount,
                                                     sizeof(Class));
            int populated = classes ? objc_getClassList(classes, classCount) : 0;
            for (int index = 0; index < populated; index++) {
                Class candidate = classes[index];
                if (candidate != nodeOutputClass &&
                    VCClassIsSubclassOfClass(candidate, nodeOutputClass)) {
                    VCHookNodeOutputClass(candidate, emitSelector, NO);
                }
            }
            free(classes);
        }
        uint32_t installedCount = atomic_load_explicit(&VCNodeOutputHookCount,
                                                        memory_order_acquire);
        VCMediaServerHookInstalled = installedCount > 0;
        if (VCMediaServerHookInstalled) {
            VCReportMediaServerVideoRuntimeEvent(
                VCMediaServerVideoRuntimeHookInstalled,
                (uint8_t)MIN(installedCount, (uint32_t)UINT8_MAX));
        }
        if (installedCount != previousCount) {
            NSLog(@"[VirtualCamPro] mediaserverd BWNodeOutput hooks %@ (%u classes, video %@, audio %@)",
                  VCMediaServerHookInstalled ? @"installed" : @"failed",
                  installedCount,
                  VCMediaServerCanQueryVideoMediaType ? @"typed" : @"sample-classified",
                  VCMediaServerCanQueryAudioMediaType ? @"typed" : @"sample-classified");
        }
        if (VCMediaServerHookInstalled) return;
    }

    if (attempt >= 20) {
        VCMediaServerVideoRuntimeEvent event = nodeOutputClass
            ? VCMediaServerVideoRuntimeIncompatibleSignature
            : VCMediaServerVideoRuntimeNodeClassUnavailable;
        VCReportMediaServerVideoRuntimeEvent(event, 0);
        dispatch_once(&VCHookUnavailableLogToken, ^{
            NSLog(@"[VirtualCamPro] BWNodeOutput has no compatible "
                   "emitSampleBuffer: entry point yet; continuing low-frequency scans");
        });
        // Camera internals can register well after mediaserverd starts. Keep a
        // low-frequency scan alive instead of making the first ten seconds a
        // permanent success/failure boundary.
        VCScheduleMediaServerHookRetry(attempt, 5.0);
        return;
    }
    VCScheduleMediaServerHookRetry(attempt + 1, 0.5);
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
            VCStartSharedRuntimeHeartbeat(VCSharedRuntimeProcessSpringBoard);
            [[VCStreamCoordinator sharedCoordinator] startMonitoring];
            dispatch_async(dispatch_get_main_queue(), ^{
                VCInstallSpringBoardVolumeHooks(0);
            });
            return;
        }
        if (![processName isEqualToString:@"mediaserverd"]) return;
        VCStartSharedRuntimeHeartbeat(VCSharedRuntimeProcessMediaServer);
        VCReportMediaServerVideoRuntimeEvent(
            VCMediaServerVideoRuntimeInjected,
            0);
        [[VCStreamCoordinator sharedCoordinator] startMonitoring];
        _dyld_register_func_for_add_image(VCMediaServerImageDidLoad);
        dispatch_async(dispatch_get_main_queue(), ^{
            VCInstallMediaServerHook(0);
        });
    }
}
