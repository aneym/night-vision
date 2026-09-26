#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../brightness_mapping.h"

static void near(double actual, double expected, double tolerance) {
    if (fabs(actual - expected) > tolerance) {
        fprintf(stderr, "expected %.9f, got %.9f\n", expected, actual);
        assert(0);
    }
}

int main(void) {
    NVBrightnessPoint p;

    p = NVBrightnessMap(0.0);
    near(p.hardware, 0.0, 1e-9);
    near(p.software, NV_BRIGHTNESS_DIM_FLOOR, 1e-9);

    p = NVBrightnessMap(NV_BRIGHTNESS_LOW_END);
    near(p.hardware, 0.0, 1e-9);
    near(p.software, 1.0, 1e-9);

    p = NVBrightnessMap(1.0);
    near(p.hardware, 1.0, 1e-9);
    near(p.software, 1.0, 1e-9);

    double previous = -1.0;
    for (int i = 0; i <= 10000; i++) {
        double logical = i / 10000.0;
        p = NVBrightnessMap(logical);
        double effective = NVBrightnessPerceptualOutput(p);
        assert(effective + 1e-9 >= previous);
        previous = effective;
        near(NVBrightnessUnmap(p.hardware, p.software), logical, 2e-6);
    }

    NVBrightnessPoint belowLow = NVBrightnessMap(NV_BRIGHTNESS_LOW_END - 1e-7);
    NVBrightnessPoint aboveLow = NVBrightnessMap(NV_BRIGHTNESS_LOW_END + 1e-7);
    near(belowLow.software, 1.0, 1e-5);
    near(aboveLow.hardware, 0.0, 1e-5);

    puts("brightness mapping: all boundaries, round-trips, and continuity checks passed");
    return 0;
}
