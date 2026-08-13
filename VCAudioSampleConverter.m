#import "VCAudioSampleConverter.h"

#import "VCSharedMediaBus.h"
#import "VCSharedMediaProtocol.h"
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>

static const Float64 VCCanonicalAudioSampleRate = 48000.0;

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
    CMSampleBufferRef originalSampleBuffer) {
    if (!originalSampleBuffer) return NULL;
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

    NSUInteger inputFrameCount = VCRequiredCanonicalInputFrames(
        frameCount, asbd->mSampleRate);
    if (inputFrameCount == 0 || inputFrameCount > SIZE_MAX / (2 * sizeof(float))) {
        return NULL;
    }
    float *source = calloc(inputFrameCount * 2, sizeof(float));
    if (!source) return NULL;
    if (![[VCSharedAudioClient sharedClient]
            copyLatestInterleavedStereoFrames:inputFrameCount into:source]) {
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

    double sourceStep = VCCanonicalAudioSampleRate / asbd->mSampleRate;
    BOOL wroteAllSamples = YES;
    for (CMItemCount frame = 0; frame < outputFrameCount && wroteAllSamples; frame++) {
        double sourcePosition = (double)frame * sourceStep;
        NSUInteger leftIndex = MIN((NSUInteger)floor(sourcePosition), inputFrameCount - 1);
        NSUInteger rightIndex = MIN(leftIndex + 1, inputFrameCount - 1);
        float fraction = (float)(sourcePosition - floor(sourcePosition));
        float left = source[leftIndex * 2] * (1.0f - fraction) +
                     source[rightIndex * 2] * fraction;
        float right = source[leftIndex * 2 + 1] * (1.0f - fraction) +
                      source[rightIndex * 2 + 1] * fraction;
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
