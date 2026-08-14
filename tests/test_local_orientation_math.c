#include "../VCLocalOrientationMath.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static void expect_orientation(double a, double b, double c, double d,
                               int rotation, bool mirrored) {
    VCLocalTrackOrientation value =
        VCResolveLocalTrackOrientation(a, b, c, d);
    assert(value.valid);
    assert(value.rotation == rotation);
    assert(value.mirrored == mirrored);
}

int main(void) {
    expect_orientation(1, 0, 0, 1, 0, false);
    expect_orientation(0, 1, -1, 0, 90, false);
    expect_orientation(-1, 0, 0, -1, 180, false);
    expect_orientation(0, -1, 1, 0, 270, false);

    expect_orientation(-1, 0, 0, 1, 0, true);
    expect_orientation(0, -1, -1, 0, 90, true);
    expect_orientation(1, 0, 0, -1, 180, true);
    expect_orientation(0, 1, 1, 0, 270, true);

    // Scale and the small floating-point noise commonly present in container
    // matrices must not change the resolved display orientation.
    expect_orientation(0.00001, 2.0, -3.0, -0.00001, 90, false);
    expect_orientation(-2.0, 0.00001, 0.00001, 4.0, 0, true);

    VCLocalTrackOrientation arbitrary = VCResolveLocalTrackOrientation(
        cos(0.7853981633974483), sin(0.7853981633974483),
        -sin(0.7853981633974483), cos(0.7853981633974483));
    assert(!arbitrary.valid);
    assert(!VCResolveLocalTrackOrientation(0, 0, 0, 0).valid);
    assert(!VCResolveLocalTrackOrientation(NAN, 0, 0, 1).valid);

    puts("local orientation math tests passed");
    return 0;
}
