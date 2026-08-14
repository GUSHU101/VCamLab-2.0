#ifndef VCPreferenceValidation_h
#define VCPreferenceValidation_h

#include <stdbool.h>
#include <stdint.h>
#include <math.h>

static inline bool VCPreferenceValidateInteger(double value,
                                               int64_t minimum,
                                               int64_t maximum,
                                               int64_t *valueOut) {
    if (!isfinite(value) || minimum > maximum) return false;
    if (value < (double)minimum || value > (double)maximum) return false;

    double rounded = round(value);
    if (fabs(value - rounded) >= 0.000001) return false;
    if (rounded < (double)minimum || rounded > (double)maximum) return false;

    int64_t integer = (int64_t)rounded;
    if (integer < minimum || integer > maximum) return false;
    if (valueOut) *valueOut = integer;
    return true;
}

static inline bool VCPreferenceValidateReal(double value,
                                            double minimum,
                                            double maximum,
                                            double *valueOut) {
    if (!isfinite(value) || !isfinite(minimum) || !isfinite(maximum) ||
        minimum > maximum || value < minimum || value > maximum) {
        return false;
    }
    if (valueOut) *valueOut = value;
    return true;
}

#endif
