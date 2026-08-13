#import "VCFrameConverter.h"

#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>

static os_unfair_lock VCTransferLock = OS_UNFAIR_LOCK_INIT;
static VTPixelTransferSessionRef VCTransferSession = NULL;
static CVPixelBufferRef VCCachedSourceBuffer = NULL;
static CIContext *VCOrientationContext = nil;

static CGColorSpaceRef VCSharedDeviceRGBColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return colorSpace;
}

enum {
    VCMaximumCachedFormats = 12,
    VCMaximumOutstandingBuffersPerFormat = 6,
};

typedef struct {
    size_t width;
    size_t height;
    OSType pixelFormat;
    CVPixelBufferPoolRef pool;
    uint64_t lastUse;
} VCPixelBufferPoolEntry;

typedef struct {
    size_t width;
    size_t height;
    OSType pixelFormat;
    BOOL aspectFill;
    CMFormatDescriptionRef templateDescription;
    CMVideoFormatDescriptionRef replacementDescription;
    CVPixelBufferRef buffer;
} VCConvertedFrameEntry;

static VCPixelBufferPoolEntry VCPixelBufferPoolEntries[VCMaximumCachedFormats];
static VCConvertedFrameEntry VCConvertedFrameEntries[VCMaximumCachedFormats];
static size_t VCPixelBufferPoolEntryCount = 0;
static size_t VCConvertedFrameEntryCount = 0;
static uint64_t VCPixelBufferPoolUseCounter = 0;

static CFDictionaryRef VCBoundedPixelBufferAllocationAttributes(void) {
    static NSDictionary *attributes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        attributes = @{
            (id)kCVPixelBufferPoolAllocationThresholdKey:
                @(VCMaximumOutstandingBuffersPerFormat),
        };
    });
    return (__bridge CFDictionaryRef)attributes;
}

static CVPixelBufferRef VCCopyPixelBufferMatchingTemplateAndDescription(
    CVPixelBufferRef source,
    CVPixelBufferRef templateBuffer,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription,
    CMVideoFormatDescriptionRef _Nullable * _Nullable replacementDescriptionOut) CF_RETURNS_RETAINED;

BOOL VCIsSupportedReplacementPixelFormat(OSType pixelFormat) {
    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8Planar:
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        case kCVPixelFormatType_422YpCbCr8:
        case kCVPixelFormatType_422YpCbCr8_yuvs:
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_32ARGB:
            return YES;
        default:
            return NO;
    }
}

static void VCCopyDictionaryEntry(const void *key, const void *value, void *context) {
    CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
}

static VTPixelTransferSessionRef VCLockedTransferSession(void) {
    if (!VCTransferSession) {
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &VCTransferSession);
        if (VCTransferSession) {
            VTSessionSetProperty(VCTransferSession,
                                 kVTPixelTransferPropertyKey_RealTime,
                                 kCFBooleanTrue);
        }
    }
    return VCTransferSession;
}

static CIContext *VCSharedOrientationContext(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCOrientationContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextCacheIntermediates: @NO,
        }];
    });
    return VCOrientationContext;
}

static void VCLockedClearConvertedFrames(void) {
    for (size_t index = 0; index < VCConvertedFrameEntryCount; index++) {
        if (VCConvertedFrameEntries[index].buffer) {
            CVPixelBufferRelease(VCConvertedFrameEntries[index].buffer);
        }
        if (VCConvertedFrameEntries[index].templateDescription) {
            CFRelease(VCConvertedFrameEntries[index].templateDescription);
        }
        if (VCConvertedFrameEntries[index].replacementDescription) {
            CFRelease(VCConvertedFrameEntries[index].replacementDescription);
        }
        VCConvertedFrameEntries[index] = (VCConvertedFrameEntry){0};
    }
    VCConvertedFrameEntryCount = 0;
}

static void VCLockedReleasePixelBufferPools(void) {
    for (size_t index = 0; index < VCPixelBufferPoolEntryCount; index++) {
        if (VCPixelBufferPoolEntries[index].pool) {
            CVPixelBufferPoolFlush(VCPixelBufferPoolEntries[index].pool,
                                   kCVPixelBufferPoolFlushExcessBuffers);
            CVPixelBufferPoolRelease(VCPixelBufferPoolEntries[index].pool);
        }
        VCPixelBufferPoolEntries[index] = (VCPixelBufferPoolEntry){0};
    }
    VCPixelBufferPoolEntryCount = 0;
    VCPixelBufferPoolUseCounter = 0;
}

static CVPixelBufferPoolRef VCLockedPixelBufferPool(size_t width,
                                                    size_t height,
                                                    OSType pixelFormat) {
    for (size_t index = 0; index < VCPixelBufferPoolEntryCount; index++) {
        VCPixelBufferPoolEntry *entry = &VCPixelBufferPoolEntries[index];
        if (entry->width == width && entry->height == height &&
            entry->pixelFormat == pixelFormat) {
            entry->lastUse = ++VCPixelBufferPoolUseCounter;
            return entry->pool;
        }
    }

    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferPoolRef createdPool = NULL;
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                              (__bridge CFDictionaryRef)poolAttributes,
                                              (__bridge CFDictionaryRef)bufferAttributes,
                                              &createdPool);
    if (result != kCVReturnSuccess || !createdPool) return NULL;

    size_t destinationIndex = VCPixelBufferPoolEntryCount;
    if (destinationIndex < VCMaximumCachedFormats) {
        VCPixelBufferPoolEntryCount++;
    } else {
        destinationIndex = 0;
        for (size_t index = 1; index < VCMaximumCachedFormats; index++) {
            if (VCPixelBufferPoolEntries[index].lastUse <
                VCPixelBufferPoolEntries[destinationIndex].lastUse) {
                destinationIndex = index;
            }
        }
        CVPixelBufferPoolFlush(VCPixelBufferPoolEntries[destinationIndex].pool,
                               kCVPixelBufferPoolFlushExcessBuffers);
        CVPixelBufferPoolRelease(VCPixelBufferPoolEntries[destinationIndex].pool);
    }

    VCPixelBufferPoolEntries[destinationIndex] = (VCPixelBufferPoolEntry){
        .width = width,
        .height = height,
        .pixelFormat = pixelFormat,
        .pool = createdPool,
        .lastUse = ++VCPixelBufferPoolUseCounter,
    };
    return createdPool;
}

CVPixelBufferRef VCCopyPixelBufferApplyingOrientation(CVPixelBufferRef source,
                                                       NSInteger clockwiseRotation,
                                                       BOOL mirrorHorizontally) {
    if (!source) return NULL;
    NSInteger rotation = ((clockwiseRotation % 360) + 360) % 360;
    if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
    if (rotation == 0 && !mirrorHorizontally) return CVPixelBufferRetain(source);

    CGImagePropertyOrientation orientation = kCGImagePropertyOrientationUp;
    switch (rotation) {
        case 90:
            orientation = mirrorHorizontally
                ? kCGImagePropertyOrientationRightMirrored
                : kCGImagePropertyOrientationRight;
            break;
        case 180:
            orientation = mirrorHorizontally
                ? kCGImagePropertyOrientationDownMirrored
                : kCGImagePropertyOrientationDown;
            break;
        case 270:
            orientation = mirrorHorizontally
                ? kCGImagePropertyOrientationLeftMirrored
                : kCGImagePropertyOrientationLeft;
            break;
        default:
            orientation = mirrorHorizontally
                ? kCGImagePropertyOrientationUpMirrored
                : kCGImagePropertyOrientationUp;
            break;
    }

    CIImage *inputImage = [CIImage imageWithCVPixelBuffer:source];
    if (!inputImage) return NULL;
    CIImage *orientedImage = [inputImage imageByApplyingCGOrientation:orientation];
    if (!orientedImage) return NULL;
    CGRect extent = CGRectIntegral(orientedImage.extent);
    if (CGRectIsEmpty(extent) || extent.size.width > 8192.0 ||
        extent.size.height > 8192.0) {
        return NULL;
    }
    if (extent.origin.x != 0.0 || extent.origin.y != 0.0) {
        orientedImage = [orientedImage imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        extent.origin = CGPointZero;
    }

    size_t width = (size_t)extent.size.width;
    size_t height = (size_t)extent.size.height;
    CVPixelBufferRef destination = NULL;
    os_unfair_lock_lock(&VCTransferLock);
    CVPixelBufferPoolRef pool = VCLockedPixelBufferPool(width,
                                                        height,
                                                        kCVPixelFormatType_32BGRA);
    CVReturn result = pool
        ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            VCBoundedPixelBufferAllocationAttributes(),
            &destination)
        : kCVReturnInvalidArgument;
    os_unfair_lock_unlock(&VCTransferLock);
    if (result != kCVReturnSuccess || !destination) return NULL;

    CIContext *context = VCSharedOrientationContext();
    CGColorSpaceRef colorSpace = VCSharedDeviceRGBColorSpace();
    if (!context || !colorSpace) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    [context render:orientedImage
      toCVPixelBuffer:destination
               bounds:CGRectMake(0, 0, width, height)
           colorSpace:colorSpace];
    return destination;
}

CVPixelBufferRef VCCopyDisplayPixelBuffer(CVPixelBufferRef source) {
    if (!source) return NULL;
    if (CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA) {
        return CVPixelBufferRetain(source);
    }

    size_t width = CVPixelBufferGetWidth(source);
    size_t height = CVPixelBufferGetHeight(source);
    if (width == 0 || height == 0 || width > 8192 || height > 8192) return NULL;
    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    if (!image) return NULL;

    CVPixelBufferRef destination = NULL;
    os_unfair_lock_lock(&VCTransferLock);
    CVPixelBufferPoolRef pool = VCLockedPixelBufferPool(width,
                                                        height,
                                                        kCVPixelFormatType_32BGRA);
    CVReturn result = pool
        ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            VCBoundedPixelBufferAllocationAttributes(),
            &destination)
        : kCVReturnInvalidArgument;
    os_unfair_lock_unlock(&VCTransferLock);
    if (result != kCVReturnSuccess || !destination) return NULL;

    CIContext *context = VCSharedOrientationContext();
    CGColorSpaceRef colorSpace = VCSharedDeviceRGBColorSpace();
    if (!context || !colorSpace) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    [context render:image
      toCVPixelBuffer:destination
               bounds:CGRectMake(0, 0, width, height)
           colorSpace:colorSpace];
    return destination;
}

void VCResetFrameConverterCache(void) {
    VCFlushFrameConverterCaches(NO);
}

void VCFlushFrameConverterCaches(BOOL releasePoolsAndSession) {
    os_unfair_lock_lock(&VCTransferLock);
    VCLockedClearConvertedFrames();
    if (VCCachedSourceBuffer) {
        CVPixelBufferRelease(VCCachedSourceBuffer);
        VCCachedSourceBuffer = NULL;
    }
    if (releasePoolsAndSession) {
        VCLockedReleasePixelBufferPools();
        if (VCTransferSession) {
            VTPixelTransferSessionInvalidate(VCTransferSession);
            CFRelease(VCTransferSession);
            VCTransferSession = NULL;
        }
    }
    os_unfair_lock_unlock(&VCTransferLock);
    if (releasePoolsAndSession && VCOrientationContext) {
        [VCOrientationContext clearCaches];
    }
}

CVPixelBufferRef VCCopyPixelBufferMatchingTemplate(CVPixelBufferRef source,
                                                    CVPixelBufferRef templateBuffer,
                                                    BOOL aspectFill) {
    return VCCopyPixelBufferMatchingTemplateAndDescription(source,
                                                            templateBuffer,
                                                            aspectFill,
                                                            NULL,
                                                            NULL);
}

static CVPixelBufferRef VCCopyPixelBufferMatchingTemplateAndDescription(
    CVPixelBufferRef source,
    CVPixelBufferRef templateBuffer,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription,
    CMVideoFormatDescriptionRef *replacementDescriptionOut) {
    if (!source || !templateBuffer) return NULL;
    if (replacementDescriptionOut) *replacementDescriptionOut = NULL;

    size_t width = CVPixelBufferGetWidth(templateBuffer);
    size_t height = CVPixelBufferGetHeight(templateBuffer);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(templateBuffer);
    if (width == 0 || height == 0 || !VCIsSupportedReplacementPixelFormat(pixelFormat)) {
        return NULL;
    }

    CVPixelBufferRef destination = NULL;
    os_unfair_lock_lock(&VCTransferLock);

    if (VCCachedSourceBuffer != source) {
        VCLockedClearConvertedFrames();
        if (VCCachedSourceBuffer) CVPixelBufferRelease(VCCachedSourceBuffer);
        VCCachedSourceBuffer = CVPixelBufferRetain(source);
    }

    for (size_t index = 0; index < VCConvertedFrameEntryCount; index++) {
        VCConvertedFrameEntry *entry = &VCConvertedFrameEntries[index];
        if (entry->width == width && entry->height == height &&
            entry->pixelFormat == pixelFormat && entry->aspectFill == aspectFill &&
            (entry->templateDescription == templateDescription ||
             (entry->templateDescription && templateDescription &&
              CFEqual(entry->templateDescription, templateDescription)))) {
            destination = CVPixelBufferRetain(entry->buffer);
            if (replacementDescriptionOut && entry->replacementDescription) {
                *replacementDescriptionOut =
                    (CMVideoFormatDescriptionRef)CFRetain(entry->replacementDescription);
            }
            os_unfair_lock_unlock(&VCTransferLock);
            return destination;
        }
    }

    CVPixelBufferPoolRef pool = VCLockedPixelBufferPool(width, height, pixelFormat);
    CVReturn result = pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                                kCFAllocatorDefault,
                                pool,
                                VCBoundedPixelBufferAllocationAttributes(),
                                &destination)
                           : kCVReturnInvalidArgument;
    if (result != kCVReturnSuccess || !destination) {
        os_unfair_lock_unlock(&VCTransferLock);
        return NULL;
    }

    // Destination color-space and clean-aperture attachments can influence the
    // transfer. Install the camera template metadata before converting pixels.
    CVBufferPropagateAttachments(templateBuffer, destination);
    VTPixelTransferSessionRef session = VCLockedTransferSession();
    OSStatus status = kVTPixelTransferNotSupportedErr;
    if (session) {
        CFStringRef scalingMode = aspectFill ? kVTScalingMode_Trim : kVTScalingMode_Letterbox;
        VTSessionSetProperty(session, kVTPixelTransferPropertyKey_ScalingMode, scalingMode);
        status = VTPixelTransferSessionTransferImage(session, source, destination);
    }
    if (status != noErr) {
        os_unfair_lock_unlock(&VCTransferLock);
        CVPixelBufferRelease(destination);
        return NULL;
    }

    CMVideoFormatDescriptionRef replacementDescription = NULL;
    if (templateDescription) {
        if (CMVideoFormatDescriptionMatchesImageBuffer(
                (CMVideoFormatDescriptionRef)templateDescription,
                destination)) {
            replacementDescription =
                (CMVideoFormatDescriptionRef)CFRetain(templateDescription);
        } else {
            status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                   destination,
                                                                   &replacementDescription);
        }
        if (status != noErr || !replacementDescription) {
            if (replacementDescription) CFRelease(replacementDescription);
            os_unfair_lock_unlock(&VCTransferLock);
            CVPixelBufferRelease(destination);
            return NULL;
        }
    }

    if (VCConvertedFrameEntryCount >= VCMaximumCachedFormats) {
        VCLockedClearConvertedFrames();
    }
    VCConvertedFrameEntries[VCConvertedFrameEntryCount++] = (VCConvertedFrameEntry){
        .width = width,
        .height = height,
        .pixelFormat = pixelFormat,
        .aspectFill = aspectFill,
        .templateDescription = templateDescription
            ? (CMFormatDescriptionRef)CFRetain(templateDescription)
            : NULL,
        .replacementDescription = replacementDescription,
        .buffer = CVPixelBufferRetain(destination),
    };
    if (replacementDescriptionOut && replacementDescription) {
        *replacementDescriptionOut =
            (CMVideoFormatDescriptionRef)CFRetain(replacementDescription);
    }
    os_unfair_lock_unlock(&VCTransferLock);

    return destination;
}

CMSampleBufferRef VCCopyReplacementSampleBuffer(CMSampleBufferRef original,
                                                 CVPixelBufferRef source,
                                                 BOOL aspectFill,
                                                 NSInteger preferredFPS) {
    if (!original || !source) return NULL;

    CMFormatDescriptionRef originalDescription = CMSampleBufferGetFormatDescription(original);
    if (!originalDescription || CMFormatDescriptionGetMediaType(originalDescription) != kCMMediaType_Video) {
        return NULL;
    }

    CVPixelBufferRef templateBuffer = CMSampleBufferGetImageBuffer(original);
    if (!templateBuffer) return NULL;
    OSType templatePixelFormat = CVPixelBufferGetPixelFormatType(templateBuffer);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(
        (CMVideoFormatDescriptionRef)originalDescription);
    if (!VCIsSupportedReplacementPixelFormat(templatePixelFormat) ||
        CMFormatDescriptionGetMediaSubType(originalDescription) != templatePixelFormat ||
        dimensions.width <= 0 || dimensions.height <= 0 ||
        (size_t)dimensions.width != CVPixelBufferGetWidth(templateBuffer) ||
        (size_t)dimensions.height != CVPixelBufferGetHeight(templateBuffer)) {
        return NULL;
    }

    CMVideoFormatDescriptionRef replacementDescription = NULL;
    CVPixelBufferRef replacementBuffer = VCCopyPixelBufferMatchingTemplateAndDescription(
        source,
        templateBuffer,
        aspectFill,
        originalDescription,
        &replacementDescription);
    if (!replacementBuffer) return NULL;
    if (!replacementDescription) {
        CVPixelBufferRelease(replacementBuffer);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)MAX(1, preferredFPS)),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleTimingInfo originalTiming;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &originalTiming) == noErr) {
        timing = originalTiming;
        if (!CMTIME_IS_VALID(timing.duration) || CMTIME_IS_INDEFINITE(timing.duration)) {
            timing.duration = CMTimeMake(1, (int32_t)MAX(1, preferredFPS));
        }
    }

    CMSampleBufferRef replacement = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                                replacementBuffer,
                                                                replacementDescription,
                                                                &timing,
                                                                &replacement);
    CFRelease(replacementDescription);
    CVPixelBufferRelease(replacementBuffer);
    if (status != noErr || !replacement) return NULL;

    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                 original,
                                                                 kCMAttachmentMode_ShouldPropagate);
    if (attachments) {
        CMSetAttachments(replacement, attachments, kCMAttachmentMode_ShouldPropagate);
        CFRelease(attachments);
    }

    CFArrayRef originalSampleAttachments = CMSampleBufferGetSampleAttachmentsArray(original, false);
    CFArrayRef replacementSampleAttachments = CMSampleBufferGetSampleAttachmentsArray(replacement, true);
    if (originalSampleAttachments && replacementSampleAttachments &&
        CFArrayGetCount(originalSampleAttachments) > 0 &&
        CFArrayGetCount(replacementSampleAttachments) > 0) {
        CFDictionaryRef sourceDictionary = CFArrayGetValueAtIndex(originalSampleAttachments, 0);
        CFMutableDictionaryRef destinationDictionary =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(replacementSampleAttachments, 0);
        if (sourceDictionary && destinationDictionary) {
            CFDictionaryApplyFunction(sourceDictionary,
                                      VCCopyDictionaryEntry,
                                      destinationDictionary);
        }
    }
    return replacement;
}
