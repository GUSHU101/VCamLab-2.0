#ifndef VC_SHARED_MEDIA_PROTOCOL_H
#define VC_SHARED_MEDIA_PROTOCOL_H

#include <math.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>

#define VC_SHARED_VIDEO_RING_SIZE 3u
#define VC_SHARED_VIDEO_CONTROL_MAGIC 0x56435643u
#define VC_SHARED_VIDEO_CONTROL_VERSION 1u
#define VC_SHARED_AUDIO_MAGIC 0x56434155u
#define VC_SHARED_AUDIO_VERSION 2u
#define VC_SHARED_AUDIO_SAMPLE_RATE 48000u
#define VC_SHARED_AUDIO_CHANNELS 2u
#define VC_SHARED_AUDIO_CAPACITY_FRAMES (VC_SHARED_AUDIO_SAMPLE_RATE * 3u)
#define VC_SHARED_AUDIO_MAX_LAG_FRAMES (VC_SHARED_AUDIO_SAMPLE_RATE / 4u)
#define VC_SHARED_AUDIO_TARGET_LEAD_FRAMES \
    (VC_SHARED_AUDIO_SAMPLE_RATE * 30u / 1000u)
#define VC_SYSTEM_REPLACEMENT_ATTACHMENT_KEY \
    "com.murkaska.virtualcampro.system-replacement.v1"
#define VC_PIPELINE_HEARTBEAT_MIN_INTERVAL_MS 250u
#define VC_RUNTIME_HEARTBEAT_MAX_AGE_MS 6000u
#define VC_RUNTIME_EVENT_TIMESTAMP_MASK UINT64_C(0x0000ffffffffffff)
#define VC_VOLUME_HOOK_STATUS_INSTALLED (UINT64_C(1) << 0)
#define VC_VOLUME_HOOK_STATUS_BUTTON_PAIR (UINT64_C(1) << 1)
#define VC_VOLUME_HOOK_STATUS_DELTA (UINT64_C(1) << 2)
#define VC_VOLUME_HOOK_STATUS_SCAN_COMPLETE (UINT64_C(1) << 3)

typedef enum {
    VCMediaServerVideoRuntimeUnknown = 0,
    VCMediaServerVideoRuntimeInjected = 1,
    VCMediaServerVideoRuntimeScanning = 2,
    VCMediaServerVideoRuntimeHookInstalled = 3,
    VCMediaServerVideoRuntimeNodeClassUnavailable = 4,
    VCMediaServerVideoRuntimeIncompatibleSignature = 5,
    VCMediaServerVideoRuntimeHookCapacityExceeded = 6,
    VCMediaServerVideoRuntimeSampleObserved = 7,
    VCMediaServerVideoRuntimeSourceUnavailable = 8,
    VCMediaServerVideoRuntimeUnsupportedPixelFormat = 9,
    VCMediaServerVideoRuntimeConversionFailed = 10,
    VCMediaServerVideoRuntimeReplacementSucceeded = 11,
} VCMediaServerVideoRuntimeEvent;

typedef enum {
    VCApplicationVideoRuntimeUnknown = 0,
    VCApplicationVideoRuntimeInjected = 1,
    VCApplicationVideoRuntimeDelegateWrapped = 2,
    VCApplicationVideoRuntimeSystemReplacementObserved = 3,
    VCApplicationVideoRuntimeSourceUnavailable = 4,
    VCApplicationVideoRuntimeConversionFailed = 5,
    VCApplicationVideoRuntimeReplacementSucceeded = 6,
    VCApplicationVideoRuntimePreviewOverlayInstalled = 7,
    VCApplicationVideoRuntimePreviewSourceUnavailable = 8,
    VCApplicationVideoRuntimePreviewFrameDisplayed = 9,
    VCApplicationVideoRuntimePhotoReplacementSucceeded = 10,
    VCApplicationVideoRuntimePhotoReplacementFailed = 11,
} VCApplicationVideoRuntimeEvent;

typedef enum {
    VCSharedVideoFailureNone = 0,
    VCSharedVideoFailureControlStateUnavailable = 1,
    VCSharedVideoFailureControlSurfaceLookup = 2,
    VCSharedVideoFailureControlSurfaceInvalid = 3,
    VCSharedVideoFailureDirectStateUnavailable = 4,
    VCSharedVideoFailureNoPublishedFrame = 5,
    VCSharedVideoFailureFrameStale = 6,
    VCSharedVideoFailureFrameSurfaceLookup = 7,
    VCSharedVideoFailurePixelBufferWrap = 8,
    VCSharedVideoFailurePublicationRace = 9,
} VCSharedVideoFailureReason;

typedef enum {
    VCProducerVideoRuntimeUnknown = 0,
    VCProducerVideoRuntimeNoIOSurface = 1,
    VCProducerVideoRuntimeSurfaceIDUnavailable = 2,
    VCProducerVideoRuntimeControlSurfaceUnavailable = 3,
    VCProducerVideoRuntimeControlStatePublishFailed = 4,
    VCProducerVideoRuntimeDirectStatePublishFailed = 5,
    VCProducerVideoRuntimePublishedControlAndDirect = 6,
    VCProducerVideoRuntimePublishedDirectFallback = 7,
    VCProducerVideoRuntimePublishedControlOnly = 8,
} VCProducerVideoRuntimeEvent;

typedef struct {
    uint32_t magic;
    uint32_t version;
    _Atomic(uint64_t) surfaceState;
    _Atomic(uint64_t) timestampMilliseconds;
} VCSharedVideoControl;

static inline uint64_t VCPackSurfaceState(uint32_t generation, uint32_t surfaceID) {
    return ((uint64_t)generation << 32) | (uint64_t)surfaceID;
}

static inline uint32_t VCGenerationFromSurfaceState(uint64_t state) {
    return (uint32_t)(state >> 32);
}

static inline uint32_t VCSurfaceIDFromState(uint64_t state) {
    return (uint32_t)(state & UINT32_MAX);
}

/// Runtime telemetry reserves the low 48 bits for monotonic milliseconds and
/// the high bytes for a stable event code plus one bounded detail value. The
/// timestamp horizon is thousands of years and the layout stays safe for
/// notify(3)'s single uint64_t state slot.
static inline uint64_t VCPackRuntimeEventState(
    uint8_t event,
    uint8_t detail,
    uint64_t timestampMilliseconds) {
    return ((uint64_t)((uint8_t)event) << 56) |
        ((uint64_t)detail << 48) |
        (timestampMilliseconds & VC_RUNTIME_EVENT_TIMESTAMP_MASK);
}

static inline uint8_t VCEventFromRuntimeState(uint64_t state) {
    return (uint8_t)((state >> 56) & UINT8_MAX);
}

static inline uint8_t VCDetailFromRuntimeState(uint64_t state) {
    return (uint8_t)((state >> 48) & UINT8_MAX);
}

static inline uint64_t VCTimestampFromRuntimeState(uint64_t state) {
    return state & VC_RUNTIME_EVENT_TIMESTAMP_MASK;
}

/// SpringBoard volume-hook diagnostics use a compact, backwards-compatible
/// bit field. The low nibble preserves the original capability flags while
/// the upper bytes expose how many ABI-validated entry points were installed.
static inline uint64_t VCPackVolumeHookStatus(int scanComplete,
                                              int hasVolumeUp,
                                              int hasVolumeDown,
                                              int hasDelta,
                                              uint8_t directionalHookCount,
                                              uint8_t deltaHookCount) {
    uint64_t state = 0;
    if (directionalHookCount > 0 || deltaHookCount > 0) {
        state |= VC_VOLUME_HOOK_STATUS_INSTALLED;
    }
    if (hasVolumeUp && hasVolumeDown) {
        state |= VC_VOLUME_HOOK_STATUS_BUTTON_PAIR;
    }
    if (hasDelta) state |= VC_VOLUME_HOOK_STATUS_DELTA;
    if (scanComplete) state |= VC_VOLUME_HOOK_STATUS_SCAN_COMPLETE;
    state |= (uint64_t)directionalHookCount << 8;
    state |= (uint64_t)deltaHookCount << 16;
    return state;
}

static inline uint8_t VCDirectionalHookCountFromStatus(uint64_t state) {
    return (uint8_t)((state >> 8) & UINT8_MAX);
}

static inline uint8_t VCDeltaHookCountFromStatus(uint64_t state) {
    return (uint8_t)((state >> 16) & UINT8_MAX);
}

/// Pipeline heartbeats are diagnostics, not an application-fallback gate. A
/// four-Hz update is enough for a 1.5-second health window and avoids one
/// mediaserverd notify state write for every emitted camera sample.
static inline int VCShouldPublishPipelineHeartbeat(uint64_t nowMilliseconds,
                                                   uint64_t lastMilliseconds) {
    if (nowMilliseconds == 0) return 0;
    if (lastMilliseconds == 0 || nowMilliseconds < lastMilliseconds) return 1;
    return nowMilliseconds - lastMilliseconds >=
        VC_PIPELINE_HEARTBEAT_MIN_INTERVAL_MS;
}

static inline int VCSharedTimestampIsRecent(uint64_t nowMilliseconds,
                                           uint64_t timestampMilliseconds,
                                           uint64_t maximumAgeMilliseconds) {
    if (nowMilliseconds == 0 || timestampMilliseconds == 0 ||
        nowMilliseconds < timestampMilliseconds) return 0;
    return nowMilliseconds - timestampMilliseconds <= maximumAgeMilliseconds;
}

/// Resolves shared-frame freshness in the consumer's own monotonic clock
/// domain. Some iOS 15 notifyd paths can expose a valid generation/IOSurface
/// pair while the separately mirrored producer timestamp is zero, ahead of the
/// reader, or temporarily stuck. A locally observed generation or changing
/// producer-runtime heartbeat is authoritative evidence that publication is
/// active; otherwise the newest sane timestamp is allowed to age normally.
static inline uint64_t VCResolveConsumerFrameTimestamp(
    uint64_t nowMilliseconds,
    uint64_t producerTimestampMilliseconds,
    uint64_t locallyObservedMilliseconds,
    int producerPublicationActive) {
    if (nowMilliseconds == 0) return 0;
    if (producerPublicationActive) return nowMilliseconds;
    uint64_t resolved = 0;
    if (producerTimestampMilliseconds > 0 &&
        producerTimestampMilliseconds <= nowMilliseconds) {
        resolved = producerTimestampMilliseconds;
    }
    if (locallyObservedMilliseconds > resolved &&
        locallyObservedMilliseconds <= nowMilliseconds) {
        resolved = locallyObservedMilliseconds;
    }
    return resolved;
}

static inline size_t VCAudioRingFrameIndex(uint64_t absoluteFrame,
                                           uint32_t capacityFrames) {
    return capacityFrames == 0 ? 0 : (size_t)(absoluteFrame % capacityFrames);
}

/// Selects the next contiguous read position in the canonical audio ring.
/// A new/overrun consumer joins with a bounded reservoir behind the live edge;
/// an established consumer advances monotonically and reports underflow instead
/// of replaying samples. The reservoir absorbs the mismatch between batched
/// AVAssetReader PCM delivery and smaller microphone callbacks.
static inline int VCResolveAudioReadStart(uint64_t endFrame,
                                          size_t requestedFrames,
                                          uint32_t capacityFrames,
                                          uint32_t maximumLagFrames,
                                          uint32_t targetLeadFrames,
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
        size_t desiredLead = targetLeadFrames > requestedFrames
            ? targetLeadFrames : requestedFrames;
        if (desiredLead > capacityFrames || endFrame < desiredLead) return 0;
        *startFrameOut = endFrame - desiredLead;
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

/// A streaming resampler retains unread look-ahead samples between callbacks.
/// This returns the total canonical FIFO occupancy required to render one
/// output callback from the current fractional source phase.
static inline size_t VCRequiredStreamingCanonicalFrames(size_t outputFrames,
                                                         double outputSampleRate,
                                                         double sourcePhase) {
    if (outputFrames == 0 || !isfinite(outputSampleRate) ||
        outputSampleRate <= 0 || !isfinite(sourcePhase) ||
        sourcePhase < 0 || sourcePhase >= 1.0) {
        return 0;
    }
    long double advance = (long double)sourcePhase +
        (long double)outputFrames * VC_SHARED_AUDIO_SAMPLE_RATE /
        (long double)outputSampleRate;
    if (!isfinite(advance) || advance > (long double)(SIZE_MAX - 2u)) return 0;
    return (size_t)floorl(advance) + 2u;
}

/// Advances a streaming resampler without discarding its fractional phase.
/// `consumedFramesOut` is the number of complete canonical FIFO frames that
/// may be removed after producing the output callback.
static inline int VCAdvanceStreamingResamplePhase(size_t outputFrames,
                                                   double outputSampleRate,
                                                   double sourcePhase,
                                                   size_t *consumedFramesOut,
                                                   double *nextPhaseOut) {
    if (!consumedFramesOut || !nextPhaseOut) return 0;
    size_t required = VCRequiredStreamingCanonicalFrames(outputFrames,
                                                          outputSampleRate,
                                                          sourcePhase);
    if (required == 0) return 0;
    long double advance = (long double)sourcePhase +
        (long double)outputFrames * VC_SHARED_AUDIO_SAMPLE_RATE /
        (long double)outputSampleRate;
    long double complete = floorl(advance);
    *consumedFramesOut = (size_t)complete;
    *nextPhaseOut = (double)(advance - complete);
    return 1;
}

#endif
