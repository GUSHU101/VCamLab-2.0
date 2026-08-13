#ifndef VCJPEGParser_h
#define VCJPEGParser_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    VCJPEGParserResultNeedMoreData = 0,
    VCJPEGParserResultFrameComplete,
    VCJPEGParserResultInvalid,
} VCJPEGParserResult;

typedef struct {
    size_t offset;
    bool insideScan;
    uint16_t width;
    uint16_t height;
    bool sawFrameDimensions;
} VCJPEGParserState;

static inline void VCJPEGParserReset(VCJPEGParserState *state) {
    if (!state) return;
    state->offset = 0;
    state->insideScan = false;
    state->width = 0;
    state->height = 0;
    state->sawFrameDimensions = false;
}

static inline bool VCJPEGParserMarkerContainsDimensions(uint8_t marker) {
    switch (marker) {
        case 0xC0: case 0xC1: case 0xC2: case 0xC3:
        case 0xC5: case 0xC6: case 0xC7:
        case 0xC9: case 0xCA: case 0xCB:
        case 0xCD: case 0xCE: case 0xCF:
            return true;
        default:
            return false;
    }
}

static inline VCJPEGParserResult VCJPEGParserSaveState(VCJPEGParserState *state,
                                                       size_t offset,
                                                       bool insideScan) {
    if (state) {
        state->offset = offset;
        state->insideScan = insideScan;
    }
    return VCJPEGParserResultNeedMoreData;
}

// Incrementally parses a JPEG that starts at bytes[0]. Segment lengths are
// honored, so SOI/EOI bytes inside EXIF thumbnails or other APP data are not
// mistaken for multipart frame boundaries.
static inline VCJPEGParserResult VCJPEGParserConsume(const uint8_t *bytes,
                                                      size_t length,
                                                      VCJPEGParserState *state,
                                                      size_t *frameLength) {
    if (frameLength) *frameLength = 0;
    if (!bytes || length < 2) return VCJPEGParserResultNeedMoreData;
    if (bytes[0] != 0xFF || bytes[1] != 0xD8) return VCJPEGParserResultInvalid;

    size_t offset = state && state->offset >= 2 && state->offset <= length
        ? state->offset
        : 2;
    bool insideScan = state && offset > 2 ? state->insideScan : false;
    while (offset < length) {
        uint8_t marker = 0;
        size_t markerStart = offset;
        bool markerFromScan = insideScan;
        if (insideScan) {
            bool foundMarker = false;
            while (offset < length) {
                const uint8_t *markerBytes = memchr(bytes + offset,
                                                    0xFF,
                                                    length - offset);
                if (!markerBytes) {
                    return VCJPEGParserSaveState(state, length, true);
                }
                markerStart = (size_t)(markerBytes - bytes);
                offset = markerStart + 1;
                if (offset >= length) {
                    return VCJPEGParserSaveState(state, markerStart, true);
                }
                while (offset < length && bytes[offset] == 0xFF) offset++;
                if (offset >= length) {
                    return VCJPEGParserSaveState(state, markerStart, true);
                }
                marker = bytes[offset++];
                if (marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7)) continue;
                foundMarker = true;
                break;
            }
            if (!foundMarker) return VCJPEGParserResultNeedMoreData;
            insideScan = false;
        } else {
            if (bytes[offset++] != 0xFF) return VCJPEGParserResultInvalid;
            if (offset >= length) {
                return VCJPEGParserSaveState(state, markerStart, false);
            }
            while (offset < length && bytes[offset] == 0xFF) offset++;
            if (offset >= length) {
                return VCJPEGParserSaveState(state, markerStart, false);
            }
            marker = bytes[offset++];
        }

        if (marker == 0xD9) {
            if (frameLength) *frameLength = offset;
            return VCJPEGParserResultFrameComplete;
        }
        if (marker == 0xD8 || marker == 0x00) return VCJPEGParserResultInvalid;
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
            insideScan = markerFromScan;
            continue;
        }
        if (offset + 2 > length) {
            return VCJPEGParserSaveState(state, markerStart, markerFromScan);
        }

        size_t segmentLength = ((size_t)bytes[offset] << 8) | bytes[offset + 1];
        if (segmentLength < 2) return VCJPEGParserResultInvalid;
        if (segmentLength > length - offset) {
            return VCJPEGParserSaveState(state, markerStart, markerFromScan);
        }
        if (VCJPEGParserMarkerContainsDimensions(marker)) {
            // SOF payload: precision (1), height (2), width (2), components...
            // Reading it while parsing avoids an ImageIO properties pass for
            // every live frame on the decoder hot path.
            if (segmentLength < 8) return VCJPEGParserResultInvalid;
            uint16_t height = (uint16_t)(((uint16_t)bytes[offset + 3] << 8) |
                                         bytes[offset + 4]);
            uint16_t width = (uint16_t)(((uint16_t)bytes[offset + 5] << 8) |
                                        bytes[offset + 6]);
            if (width == 0 || height == 0) return VCJPEGParserResultInvalid;
            if (state) {
                state->width = width;
                state->height = height;
                state->sawFrameDimensions = true;
            }
        }
        offset += segmentLength;
        insideScan = marker == 0xDA || (markerFromScan && marker == 0xDC);
    }
    return VCJPEGParserSaveState(state, offset, insideScan);
}

#endif
