#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "../VCPreferenceValidation.h"

static void test_integer_boundaries(void) {
    int64_t value = -1;
    assert(VCPreferenceValidateInteger(1.0, 1, 240, &value));
    assert(value == 1);
    assert(VCPreferenceValidateInteger(240.0, 1, 240, &value));
    assert(value == 240);
    assert(!VCPreferenceValidateInteger(0.0, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(241.0, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(59.5, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(NAN, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(INFINITY, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(-INFINITY, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(1.0e300, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(-1.0e300, 1, 240, &value));
    assert(!VCPreferenceValidateInteger(60.0, 240, 1, &value));
}

static void test_integer_enums(void) {
    int64_t value = -1;
    const double validRotations[] = {0.0, 90.0, 180.0, 270.0};
    for (size_t index = 0; index < sizeof(validRotations) / sizeof(validRotations[0]);
         index++) {
        assert(VCPreferenceValidateInteger(validRotations[index], 0, 270, &value));
        assert(value == (int64_t)validRotations[index]);
    }
    assert(VCPreferenceValidateInteger(45.0, 0, 270, &value));
    assert(value == 45); /* Membership is intentionally checked by the caller. */
}

static void test_real_boundaries(void) {
    double value = -1.0;
    assert(VCPreferenceValidateReal(0.5, 0.5, 1.0, &value));
    assert(value == 0.5);
    assert(VCPreferenceValidateReal(1.0, 0.5, 1.0, &value));
    assert(value == 1.0);
    assert(!VCPreferenceValidateReal(0.499, 0.5, 1.0, &value));
    assert(!VCPreferenceValidateReal(1.001, 0.5, 1.0, &value));
    assert(!VCPreferenceValidateReal(NAN, 0.5, 1.0, &value));
    assert(!VCPreferenceValidateReal(INFINITY, 0.5, 1.0, &value));
    assert(!VCPreferenceValidateReal(0.75, NAN, 1.0, &value));
    assert(!VCPreferenceValidateReal(0.75, 0.5, INFINITY, &value));
    assert(!VCPreferenceValidateReal(0.75, 1.0, 0.5, &value));
}

int main(void) {
    test_integer_boundaries();
    test_integer_enums();
    test_real_boundaries();
    puts("preference validation tests passed");
    return 0;
}
