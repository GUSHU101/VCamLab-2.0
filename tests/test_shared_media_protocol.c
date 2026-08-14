#include "../VCSharedMediaProtocol.h"

#include <assert.h>
#include <stdio.h>

static void testSurfaceStateRoundTrip(void) {
    uint64_t state = VCPackSurfaceState(0x12345678u, 0xfedcba98u);
    assert(VCGenerationFromSurfaceState(state) == 0x12345678u);
    assert(VCSurfaceIDFromState(state) == 0xfedcba98u);
}

static void testPipelineHeartbeatRateLimit(void) {
    assert(!VCShouldPublishPipelineHeartbeat(0, 0));
    assert(VCShouldPublishPipelineHeartbeat(1000, 0));
    assert(!VCShouldPublishPipelineHeartbeat(1249, 1000));
    assert(VCShouldPublishPipelineHeartbeat(1250, 1000));
    assert(VCShouldPublishPipelineHeartbeat(999, 1000));
}

static void testSharedTimestampFreshness(void) {
    assert(VCSharedTimestampIsRecent(5000, 4900, 100));
    assert(!VCSharedTimestampIsRecent(5001, 4900, 100));
    assert(!VCSharedTimestampIsRecent(4900, 5000, 100));
    assert(!VCSharedTimestampIsRecent(5000, 0, 100));
    assert(!VCSharedTimestampIsRecent(0, 0, 100));
}

static void testVideoControlAtomicLayout(void) {
    assert(sizeof(VCSharedVideoControl) >= 24);
    assert(offsetof(VCSharedVideoControl, surfaceState) %
        _Alignof(_Atomic(uint64_t)) == 0);
    assert(offsetof(VCSharedVideoControl, timestampMilliseconds) %
        _Alignof(_Atomic(uint64_t)) == 0);
}

static void testAudioRingWrap(void) {
    assert(VCAudioRingFrameIndex(0, 8) == 0);
    assert(VCAudioRingFrameIndex(7, 8) == 7);
    assert(VCAudioRingFrameIndex(8, 8) == 0);
    assert(VCAudioRingFrameIndex(19, 8) == 3);
    assert(VCAudioRingFrameIndex(19, 0) == 0);
}

static void testAudioReadCursor(void) {
    uint64_t start = UINT64_MAX;
    assert(VCResolveAudioReadStart(1024, 480, 4096, 2000, 0, 0, &start));
    assert(start == 544);
    assert(VCResolveAudioReadStart(2048, 480, 4096, 2000, 1, 1024, &start));
    assert(start == 1024);
    assert(!VCResolveAudioReadStart(1200, 480, 4096, 2000, 1, 1024, &start));
    assert(VCResolveAudioReadStart(10000, 480, 4096, 2000, 1, 1024, &start));
    assert(start == 9520);
    assert(VCResolveAudioReadStart(14000, 480, 10000, 2000, 1, 10000, &start));
    assert(start == 13520);
    assert(!VCResolveAudioReadStart(100, 480, 4096, 2000, 0, 0, &start));
    assert(!VCResolveAudioReadStart(1024, 0, 4096, 2000, 0, 0, &start));
    assert(!VCResolveAudioReadStart(1024, 480, 4096, 2000, 0, 0, NULL));
}

static void testResampleInputBounds(void) {
    assert(VCRequiredCanonicalInputFrames(1024, 48000.0) == 1026);
    assert(VCRequiredCanonicalInputFrames(441, 44100.0) == 482);
    assert(VCRequiredCanonicalInputFrames(960, 96000.0) == 482);
    assert(VCRequiredCanonicalInputFrames(10, 0) == 0);
    assert(VCRequiredCanonicalInputFrames(0, 48000.0) == 0);
    assert(VCRequiredCanonicalInputFrames(10, NAN) == 0);
    assert(VCRequiredCanonicalInputFrames(10, INFINITY) == 0);
    assert(VCRequiredCanonicalInputFrames(SIZE_MAX, 1.0) == 0);
}

int main(void) {
    testSurfaceStateRoundTrip();
    testPipelineHeartbeatRateLimit();
    testSharedTimestampFreshness();
    testVideoControlAtomicLayout();
    testAudioRingWrap();
    testAudioReadCursor();
    testResampleInputBounds();
    puts("shared media protocol tests passed");
    return 0;
}
