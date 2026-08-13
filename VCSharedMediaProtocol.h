#ifndef VC_SHARED_MEDIA_PROTOCOL_H
#define VC_SHARED_MEDIA_PROTOCOL_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>

#define VC_SHARED_VIDEO_RING_SIZE 3u
#define VC_SHARED_AUDIO_MAGIC 0x56434155u
#define VC_SHARED_AUDIO_VERSION 1u
#define VC_SHARED_AUDIO_SAMPLE_RATE 48000u
#define VC_SHARED_AUDIO_CHANNELS 2u
#define VC_SHARED_AUDIO_CAPACITY_FRAMES (VC_SHARED_AUDIO_SAMPLE_RATE * 3u)
#define VC_SHARED_AUDIO_MAX_LAG_FRAMES (VC_SHARED_AUDIO_SAMPLE_RATE / 4u)

static inline uint64_t VCPackSurfaceState(uint32_t generation, uint32_t surfaceID) {
    return ((uint64_t)generation << 32) | (uint64_t)surfaceID;
}

static inline uint32_t VCGenerationFromSurfaceState(uint64_t state) {
    return (uint32_t)(state >> 32);
}

static inline uint32_t VCSurfaceIDFromState(uint64_t state) {
    return (uint32_t)(state & UINT32_MAX);
}

static inline size_t VCAudioRingFrameIndex(uint64_t absoluteFrame,
                                           uint32_t capacityFrames) {
    return capacityFrames == 0 ? 0 : (size_t)(absoluteFrame % capacityFrames);
}

/// Selects the next contiguous read position in the canonical audio ring.
/// A new/overrun consumer joins at the live edge; an established consumer
/// advances monotonically and reports underflow instead of replaying samples.
static inline int VCResolveAudioReadStart(uint64_t endFrame,
                                          size_t requestedFrames,
                                          uint32_t capacityFrames,
                                          uint32_t maximumLagFrames,
                                          int cursorValid,
                                          uint64_t nextFrame,
                                          uint64_t *startFrameOut) {
    if (!startFrameOut || requestedFrames == 0 ||
        requestedFrames > capacityFrames || endFrame < requestedFrames) {
        return 0;
    }
    uint64_t latestStart = endFrame - requestedFrames;
    if (!cursorValid || nextFrame > endFrame ||
        endFrame - nextFrame > capacityFrames ||
        (maximumLagFrames > 0 && endFrame - nextFrame > maximumLagFrames)) {
        *startFrameOut = latestStart;
        return 1;
    }
    if (nextFrame > latestStart) return 0;
    *startFrameOut = nextFrame;
    return 1;
}

static inline size_t VCRequiredCanonicalInputFrames(size_t outputFrames,
                                                     double outputSampleRate) {
    if (outputFrames == 0 || !isfinite(outputSampleRate) || outputSampleRate <= 0) {
        return 0;
    }
    long double required = ceill((long double)outputFrames *
                                 VC_SHARED_AUDIO_SAMPLE_RATE /
                                 (long double)outputSampleRate);
    if (!isfinite(required) || required > (long double)(SIZE_MAX - 2u)) return 0;
    return (size_t)required + 2u;
}

#endif
