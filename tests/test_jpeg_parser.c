#include "../VCJPEGParser.h"

#include <assert.h>
#include <stdio.h>

static void testIncrementalBaselineAndEmbeddedThumbnail(void) {
    static const uint8_t jpeg[] = {
        0xFF, 0xD8,
        0xFF, 0xE1, 0x00, 0x0C,
        'E', 'x', 0xFF, 0xD8, 't', 'h', 0xFF, 0xD9, 'x', 'x',
        0xFF, 0xDB, 0x00, 0x05, 'q', 't', 'b',
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00,
        'p', 'i', 'x', 0xFF, 0x00, 'e', 0xFF, 0xD0, 'l', 0xFF, 0xD9,
    };
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    for (size_t length = 1; length <= sizeof(jpeg); length++) {
        VCJPEGParserResult result = VCJPEGParserConsume(jpeg,
                                                        length,
                                                        &state,
                                                        &frameLength);
        if (length < sizeof(jpeg)) {
            assert(result == VCJPEGParserResultNeedMoreData);
            assert(frameLength == 0);
        } else {
            assert(result == VCJPEGParserResultFrameComplete);
            assert(frameLength == sizeof(jpeg));
        }
    }
}

static void testProgressiveScans(void) {
    static const uint8_t jpeg[] = {
        0xFF, 0xD8,
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00,
        'a', 'b',
        0xFF, 0xC4, 0x00, 0x03, 0x01,
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00,
        'c', 'd', 0xFF, 0xD9,
    };
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    VCJPEGParserResult result = VCJPEGParserConsume(jpeg,
                                                    sizeof(jpeg),
                                                    &state,
                                                    &frameLength);
    assert(result == VCJPEGParserResultFrameComplete);
    assert(frameLength == sizeof(jpeg));
}

static void testDefineNumberOfLinesInsideScan(void) {
    static const uint8_t jpeg[] = {
        0xFF, 0xD8,
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00,
        'a',
        0xFF, 0xDC, 0x00, 0x04, 0x00, 0x10,
        'b', 0xFF, 0xD9,
    };
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    VCJPEGParserResult result = VCJPEGParserConsume(jpeg,
                                                    sizeof(jpeg),
                                                    &state,
                                                    &frameLength);
    assert(result == VCJPEGParserResultFrameComplete);
    assert(frameLength == sizeof(jpeg));
}

static void testInvalidStructure(void) {
    static const uint8_t invalid[] = {0xFF, 0xD8, 'b', 'a', 'd'};
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    assert(VCJPEGParserConsume(invalid,
                               sizeof(invalid),
                               &state,
                               &frameLength) == VCJPEGParserResultInvalid);
    assert(frameLength == 0);
}

static void testConcatenatedFramesReturnOneFrameAtATime(void) {
    static const uint8_t frames[] = {
        0xFF, 0xD8, 0xFF, 0xD9,
        0xFF, 0xD8, 0xFF, 0xD9,
    };
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    assert(VCJPEGParserConsume(frames,
                               sizeof(frames),
                               &state,
                               &frameLength) == VCJPEGParserResultFrameComplete);
    assert(frameLength == 4);
    VCJPEGParserReset(&state);
    assert(VCJPEGParserConsume(frames + frameLength,
                               sizeof(frames) - frameLength,
                               &state,
                               &frameLength) == VCJPEGParserResultFrameComplete);
    assert(frameLength == 4);
}

static void testMarkerSplitAcrossCallbacks(void) {
    static const uint8_t jpeg[] = {0xFF, 0xD8, 0xFF, 0xD9};
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    assert(VCJPEGParserConsume(jpeg,
                               3,
                               &state,
                               &frameLength) == VCJPEGParserResultNeedMoreData);
    assert(state.offset == 2);
    assert(VCJPEGParserConsume(jpeg,
                               sizeof(jpeg),
                               &state,
                               &frameLength) == VCJPEGParserResultFrameComplete);
    assert(frameLength == sizeof(jpeg));
}

static void testInvalidSegmentLengthAndMissingSOI(void) {
    static const uint8_t invalidLength[] = {
        0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x01,
    };
    static const uint8_t missingSOI[] = {0x00, 0x00, 0xFF, 0xD9};
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    assert(VCJPEGParserConsume(invalidLength,
                               sizeof(invalidLength),
                               &state,
                               &frameLength) == VCJPEGParserResultInvalid);
    VCJPEGParserReset(&state);
    assert(VCJPEGParserConsume(missingSOI,
                               sizeof(missingSOI),
                               &state,
                               &frameLength) == VCJPEGParserResultInvalid);
}

static void testFrameDimensionsSurviveIncrementalParsing(void) {
    static const uint8_t jpeg[] = {
        0xFF, 0xD8,
        // Baseline SOF, 1080 high by 1920 wide, one component.
        0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x04, 0x38, 0x07, 0x80,
        0x01, 0x01, 0x11, 0x00,
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00,
        'p', 'i', 'x', 0xFF, 0xD9,
    };
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    assert(VCJPEGParserConsume(jpeg,
                               15,
                               &state,
                               &frameLength) == VCJPEGParserResultNeedMoreData);
    assert(state.sawFrameDimensions);
    assert(state.width == 1920);
    assert(state.height == 1080);
    assert(VCJPEGParserConsume(jpeg,
                               sizeof(jpeg),
                               &state,
                               &frameLength) == VCJPEGParserResultFrameComplete);
    assert(frameLength == sizeof(jpeg));
    assert(state.sawFrameDimensions);
    assert(state.width == 1920);
    assert(state.height == 1080);
    VCJPEGParserReset(&state);
    assert(!state.sawFrameDimensions && state.width == 0 && state.height == 0);
}

static void testInvalidFrameDimensions(void) {
    static const uint8_t zeroWidth[] = {
        0xFF, 0xD8,
        0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x00,
        0x01, 0x01, 0x11, 0x00,
        0xFF, 0xD9,
    };
    VCJPEGParserState state = {0};
    size_t frameLength = 0;
    assert(VCJPEGParserConsume(zeroWidth,
                               sizeof(zeroWidth),
                               &state,
                               &frameLength) == VCJPEGParserResultInvalid);
}

int main(void) {
    testIncrementalBaselineAndEmbeddedThumbnail();
    testProgressiveScans();
    testDefineNumberOfLinesInsideScan();
    testInvalidStructure();
    testConcatenatedFramesReturnOneFrameAtATime();
    testMarkerSplitAcrossCallbacks();
    testInvalidSegmentLengthAndMissingSOI();
    testFrameDimensionsSurviveIncrementalParsing();
    testInvalidFrameDimensions();
    puts("VCJPEGParser tests passed");
    return 0;
}
