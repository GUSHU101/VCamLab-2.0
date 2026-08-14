#ifndef VC_LOCAL_ORIENTATION_MATH_H
#define VC_LOCAL_ORIENTATION_MATH_H

#include <stdbool.h>
#include <math.h>

typedef struct {
    int rotation;
    bool mirrored;
    bool valid;
} VCLocalTrackOrientation;

/// Resolves the linear portion of an AVAssetTrack preferredTransform into the
/// right-angle rotation/reflection that camera files use. Translation and
/// scale are intentionally ignored. Arbitrary affine rotations fail closed.
static inline VCLocalTrackOrientation VCResolveLocalTrackOrientation(double a,
                                                                      double b,
                                                                      double c,
                                                                      double d) {
    VCLocalTrackOrientation result = {0, false, false};
    if (!isfinite(a) || !isfinite(b) || !isfinite(c) || !isfinite(d)) {
        return result;
    }
    double determinant = a * d - b * c;
    if (!isfinite(determinant) || fabs(determinant) < 0.0000001) return result;
    bool mirrored = determinant < 0.0;
    double x = mirrored ? -a : a;
    double y = mirrored ? -b : b;
    double magnitude = hypot(x, y);
    if (!isfinite(magnitude) || magnitude < 0.0001) return result;

    static const double halfPi = 1.57079632679489661923;
    double angle = atan2(y, x);
    long quadrant = lround(angle / halfPi);
    if (fabs(angle - (double)quadrant * halfPi) > 0.02) return result;

    int rotation = (int)((quadrant * 90L) % 360L);
    if (rotation < 0) rotation += 360;
    result.rotation = rotation;
    result.mirrored = mirrored;
    result.valid = true;
    return result;
}

#endif
