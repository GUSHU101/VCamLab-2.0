#import "VCAudioSampleConverter.h"

#import "VCSharedMediaBus.h"
#import "VCSharedMediaProtocol.h"
#import <AudioToolbox/AudioToolbox.h>
#import <float.h>
#import <math.h>
#import <os/lock.h>

static const Float64 VCCanonicalAudioSampleRate = 48000.0;

@interface VCAudioReplacementContext () {
    os_unfair_lock _lock;
    VCSharedAudioCursor *_cursor;
    float *_canonicalFrames;
    size_t _canonicalCapacityFrames;
    size_t _canonicalAvailableFrames;
    double _sourcePhase;
    Float64 _outputSampleRate;
}
- (BOOL)copyResampledStereoFrames:(size_t)outputFrameCount
                       sampleRate:(Float64)sampleRate
                             into:(float *)destination;
@end

@implementation VCAudioReplacementContext

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        _cursor = [VCSharedAudioCursor new];
    }
    return self;
}

- (void)resetLocked {
    _canonicalAvailableFrames = 0;
    _sourcePhase = 0;
    _outputSampleRate = 0;
    [_cursor reset];
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    [self resetLocked];
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)ensureCanonicalCapacityLocked:(size_t)requiredFrames {
    if (requiredFrames <= _canonicalCapacityFrames) return YES;
    if (requiredFrames > VC_SHARED_AUDIO_CAPACITY_FRAMES ||
        requiredFrames > SIZE_MAX / (2u * sizeof(float))) return NO;
    size_t capacity = MAX((size_t)1024, _canonicalCapacityFrames);
    while (capacity < requiredFrames) {
        if (capacity > VC_SHARED_AUDIO_CAPACITY_FRAMES / 2u) {
            capacity = VC_SHARED_AUDIO_CAPACITY_FRAMES;
            break;
        }
        capacity *= 2u;
    }
    float *resized = realloc(_canonicalFrames, capacity * 2u * sizeof(float));
    if (!resized) return NO;
    _canonicalFrames = resized;
    _canonicalCapacityFrames = capacity;
    return YES;
}

- (BOOL)copyResampledStereoFrames:(size_t)outputFrameCount
                       sampleRate:(Float64)sampleRate
                             into:(float *)destination {
    if (!destination || outputFrameCount == 0 || !isfinite(sampleRate) ||
        sampleRate <= 0) return NO;
    os_unfair_lock_lock(&_lock);
    if (_outputSampleRate > 0 && fabs(_outputSampleRate - sampleRate) > DBL_EPSILON) {
        [self resetLocked];
    }
    _outputSampleRate = sampleRate;

    BOOL ready = NO;
    for (NSUInteger attempt = 0; attempt < 2 && !ready; attempt++) {
        size_t requiredFrames = VCRequiredStreamingCanonicalFrames(
            outputFrameCount, sampleRate, _sourcePhase);
        if (requiredFrames == 0 || ![self ensureCanonicalCapacityLocked:requiredFrames]) {
            break;
        }
        size_t missingFrames = requiredFrames > _canonicalAvailableFrames
            ? requiredFrames - _canonicalAvailableFrames : 0;
        if (missingFrames == 0 ||
            [[VCSharedAudioClient sharedClient]
                copyLatestInterleavedStereoFrames:missingFrames
                                             into:_canonicalFrames +
                                                  _canonicalAvailableFrames * 2u
                                           cursor:_cursor]) {
            _canonicalAvailableFrames += missingFrames;
            ready = YES;
            break;
        }
        [self resetLocked];
        _outputSampleRate = sampleRate;
    }
    if (!ready) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }

    double sourceStep = VCCanonicalAudioSampleRate / sampleRate;
    for (size_t frame = 0; frame < outputFrameCount; frame++) {
        double sourcePosition = _sourcePhase + (double)frame * sourceStep;
        size_t leftIndex = (size_t)floor(sourcePosition);
        size_t rightIndex = MIN(leftIndex + 1u, _canonicalAvailableFrames - 1u);
        float fraction = (float)(sourcePosition - floor(sourcePosition));
        destination[frame * 2u] =
            _canonicalFrames[leftIndex * 2u] * (1.0f - fraction) +
            _canonicalFrames[rightIndex * 2u] * fraction;
        destination[frame * 2u + 1u] =
            _canonicalFrames[leftIndex * 2u + 1u] * (1.0f - fraction) +
            _canonicalFrames[rightIndex * 2u + 1u] * fraction;
    }

    size_t consumedFrames = 0;
    double nextPhase = 0;
    BOOL advanced = VCAdvanceStreamingResamplePhase(outputFrameCount,
                                                     sampleRate,
                                                     _sourcePhase,
                                                     &consumedFrames,
                                                     &nextPhase);
    if (!advanced || consumedFrames > _canonicalAvailableFrames) {
        [self resetLocked];
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    size_t remainingFrames = _canonicalAvailableFrames - consumedFrames;
    if (remainingFrames > 0 && consumedFrames > 0) {
        memmove(_canonicalFrames,
                _canonicalFrames + consumedFrames * 2u,
                remainingFrames * 2u * sizeof(float));
    }
    _canonicalAvailableFrames = remainingFrames;
    _sourcePhase = nextPhase;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (void)dealloc {
    free(_canonicalFrames);
}

@end

static void VCCopyDictionaryEntry(const void *key,
                                  const void *value,
                                  void *context) {
    CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
}

static void VCCopySampleAttachments(CMSampleBufferRef source,
                                    CMSampleBufferRef destination) {
    CFArrayRef sourceArray = CMSampleBufferGetSampleAttachmentsArray(source, NO);
    if (!sourceArray) return;
    CFArrayRef destinationArray = CMSampleBufferGetSampleAttachmentsArray(destination, YES);
    if (!destinationArray) return;
    CFIndex count = MIN(CFArrayGetCount(sourceArray), CFArrayGetCount(destinationArray));
    for (CFIndex index = 0; index < count; index++) {
        CFDictionaryRef sourceDictionary = CFArrayGetValueAtIndex(sourceArray, index);
        CFMutableDictionaryRef destinationDictionary =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(destinationArray, index);
        if (sourceDictionary && destinationDictionary) {
            CFDictionaryApplyFunction(sourceDictionary,
                                      VCCopyDictionaryEntry,
                                      destinationDictionary);
        }
    }
}

static float VCClampSample(float value) {
    return fmaxf(-1.0f, fminf(1.0f, value));
}

static void VCWriteIntegerSample(uint8_t *destination,
                                 UInt32 bitDepth,
                                 float sample) {
    float clamped = VCClampSample(sample);
    if (bitDepth == 16) {
        int16_t value = (int16_t)lrintf(clamped * 32767.0f);
        memcpy(destination, &value, sizeof(value));
    } else if (bitDepth == 24) {
        int32_t value = (int32_t)lrintf(clamped * 8388607.0f);
        destination[0] = (uint8_t)(value & 0xff);
        destination[1] = (uint8_t)((value >> 8) & 0xff);
        destination[2] = (uint8_t)((value >> 16) & 0xff);
    } else if (bitDepth == 32) {
        int32_t value = (int32_t)llrint((double)clamped * 2147483647.0);
        memcpy(destination, &value, sizeof(value));
    }
}

static BOOL VCWriteSample(uint8_t *destination,
                          const AudioStreamBasicDescription *asbd,
                          float sample) {
    if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (asbd->mBitsPerChannel == 32) {
            float value = VCClampSample(sample);
            memcpy(destination, &value, sizeof(value));
            return YES;
        }
        if (asbd->mBitsPerChannel == 64) {
            double value = VCClampSample(sample);
            memcpy(destination, &value, sizeof(value));
            return YES;
        }
        return NO;
    }
    if (!(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) ||
        (asbd->mBitsPerChannel != 16 && asbd->mBitsPerChannel != 24 &&
         asbd->mBitsPerChannel != 32)) return NO;
    VCWriteIntegerSample(destination, asbd->mBitsPerChannel, sample);
    return YES;
}

CMSampleBufferRef VCCopyReplacementAudioSampleBuffer(
    CMSampleBufferRef originalSampleBuffer,
    VCAudioReplacementContext *context) {
    if (!originalSampleBuffer || !context) return NULL;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(originalSampleBuffer);
    const AudioStreamBasicDescription *asbd = format
        ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    CMItemCount outputFrameCount = CMSampleBufferGetNumSamples(originalSampleBuffer);
    if (!asbd || outputFrameCount <= 0 || asbd->mFormatID != kAudioFormatLinearPCM ||
        asbd->mSampleRate < 8000 || asbd->mSampleRate > 192000 ||
        asbd->mChannelsPerFrame == 0 || asbd->mChannelsPerFrame > 8 ||
        asbd->mBytesPerFrame == 0 || asbd->mFramesPerPacket != 1 ||
        asbd->mBytesPerPacket != asbd->mBytesPerFrame ||
        (asbd->mFormatFlags & (kAudioFormatFlagIsBigEndian |
                               kAudioFormatFlagIsAlignedHigh))) return NULL;

    UInt32 bytesPerSample = MAX((UInt32)1, (asbd->mBitsPerChannel + 7) / 8);
    UInt32 channels = asbd->mChannelsPerFrame;
    BOOL nonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bufferCount = nonInterleaved ? channels : 1;
    if (!nonInterleaved && asbd->mBytesPerFrame % channels != 0) return NULL;
    UInt32 sampleStride = nonInterleaved
        ? asbd->mBytesPerFrame : asbd->mBytesPerFrame / channels;
    if (sampleStride < bytesPerSample) return NULL;

    size_t frameCount = (size_t)outputFrameCount;
    if (frameCount > SIZE_MAX / asbd->mBytesPerFrame) return NULL;
    size_t bytesPerBuffer = frameCount * asbd->mBytesPerFrame;
    if (bytesPerBuffer > UINT32_MAX || bufferCount > SIZE_MAX / bytesPerBuffer) return NULL;
    size_t totalByteCount = bytesPerBuffer * bufferCount;

    if (frameCount > SIZE_MAX / (2u * sizeof(float))) return NULL;
    float *source = calloc(frameCount * 2u, sizeof(float));
    if (!source) return NULL;
    if (![context copyResampledStereoFrames:frameCount
                                 sampleRate:asbd->mSampleRate
                                       into:source]) {
        free(source);
        return NULL;
    }

    size_t audioBufferListSize = offsetof(AudioBufferList, mBuffers) +
                                 (size_t)bufferCount * sizeof(AudioBuffer);
    AudioBufferList *audioBufferList = calloc(1, audioBufferListSize);
    uint8_t *rawBytes = calloc(1, totalByteCount);
    if (!audioBufferList || !rawBytes) {
        free(source);
        free(audioBufferList);
        free(rawBytes);
        return NULL;
    }

    audioBufferList->mNumberBuffers = bufferCount;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferCount; bufferIndex++) {
        AudioBuffer *buffer = &audioBufferList->mBuffers[bufferIndex];
        buffer->mNumberChannels = nonInterleaved ? 1 : channels;
        buffer->mDataByteSize = (UInt32)bytesPerBuffer;
        buffer->mData = rawBytes + (size_t)bufferIndex * bytesPerBuffer;
    }

    BOOL wroteAllSamples = YES;
    for (CMItemCount frame = 0; frame < outputFrameCount && wroteAllSamples; frame++) {
        float left = source[(size_t)frame * 2u];
        float right = source[(size_t)frame * 2u + 1u];
        for (UInt32 channel = 0; channel < channels; channel++) {
            float value = channels == 1 ? (left + right) * 0.5f
                                        : (channel == 0 ? left : (channel == 1 ? right : 0));
            UInt32 bufferIndex = nonInterleaved ? channel : 0;
            UInt32 channelIndex = nonInterleaved ? 0 : channel;
            uint8_t *destination = (uint8_t *)audioBufferList->mBuffers[bufferIndex].mData +
                (size_t)frame * asbd->mBytesPerFrame + channelIndex * sampleStride;
            wroteAllSamples = VCWriteSample(destination, asbd, value);
        }
    }
    free(source);
    if (!wroteAllSamples) {
        free(audioBufferList);
        free(rawBytes);
        return NULL;
    }

    CMSampleBufferRef replacement = NULL;
    OSStatus status = CMAudioSampleBufferCreateWithPacketDescriptions(
        kCFAllocatorDefault,
        NULL,
        false,
        NULL,
        NULL,
        format,
        outputFrameCount,
        CMSampleBufferGetPresentationTimeStamp(originalSampleBuffer),
        NULL,
        &replacement);
    if (status == noErr && replacement) {
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            replacement,
            kCFAllocatorDefault,
            kCFAllocatorDefault,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            audioBufferList);
    }
    if (status == noErr && replacement) {
        status = CMSampleBufferSetDataReady(replacement);
    }
    free(audioBufferList);
    free(rawBytes);
    if (status != noErr || !replacement) {
        if (replacement) CFRelease(replacement);
        return NULL;
    }

    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(
        kCFAllocatorDefault,
        originalSampleBuffer,
        kCMAttachmentMode_ShouldPropagate);
    if (attachments) {
        CMSetAttachments(replacement,
                         attachments,
                         kCMAttachmentMode_ShouldPropagate);
        CFRelease(attachments);
    }
    VCCopySampleAttachments(originalSampleBuffer, replacement);
    return replacement;
}
