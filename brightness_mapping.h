#ifndef NIGHT_VISION_BRIGHTNESS_MAPPING_H
#define NIGHT_VISION_BRIGHTNESS_MAPPING_H

#include <math.h>

#define NV_BRIGHTNESS_LOW_END 0.15
#define NV_BRIGHTNESS_NORMAL_MAX 1.0
#define NV_BRIGHTNESS_DIM_FLOOR 0.02
#define NV_BRIGHTNESS_BOOST_MAX 1.0
#define NV_BRIGHTNESS_MAPPING_VERSION 2

typedef struct {
    double hardware;
    double software;
} NVBrightnessPoint;

static inline double NVClamp(double value, double low, double high) {
    return fmin(high, fmax(low, value));
}

/*
 * One continuous perceptual slider:
 *   0.00...0.15  hardware minimum + software dimming
 *   0.15...1.00  native hardware brightness
 *
 * High-brightness EDR is deliberately not mapped here: on Book/macOS 26.5.2,
 * the compositor did not expose current EDR headroom to Night Vision's helper,
 * so applying gain above 1.0 would report a fictitious range.
 */
static inline NVBrightnessPoint NVBrightnessMap(double logical) {
    logical = NVClamp(logical, 0.0, 1.0);
    if (logical < NV_BRIGHTNESS_LOW_END) {
        double t = logical / NV_BRIGHTNESS_LOW_END;
        return (NVBrightnessPoint){0.0,
            NV_BRIGHTNESS_DIM_FLOOR + t * (1.0 - NV_BRIGHTNESS_DIM_FLOOR)};
    }
    if (logical <= NV_BRIGHTNESS_NORMAL_MAX) {
        double t = (logical - NV_BRIGHTNESS_LOW_END) /
            (NV_BRIGHTNESS_NORMAL_MAX - NV_BRIGHTNESS_LOW_END);
        return (NVBrightnessPoint){t, 1.0};
    }
    return (NVBrightnessPoint){1.0, 1.0};
}

static inline double NVBrightnessUnmap(double hardware, double software) {
    hardware = NVClamp(hardware, 0.0, 1.0);
    software = NVClamp(software, NV_BRIGHTNESS_DIM_FLOOR, NV_BRIGHTNESS_BOOST_MAX);
    if (software < 1.0 - 1e-5) {
        double t = (software - NV_BRIGHTNESS_DIM_FLOOR) /
            (1.0 - NV_BRIGHTNESS_DIM_FLOOR);
        return NVClamp(t * NV_BRIGHTNESS_LOW_END, 0.0, NV_BRIGHTNESS_LOW_END);
    }
    return NV_BRIGHTNESS_LOW_END + hardware *
        (NV_BRIGHTNESS_NORMAL_MAX - NV_BRIGHTNESS_LOW_END);
}

/* A normalized monotonic proxy used to verify boundary continuity. */
static inline double NVBrightnessPerceptualOutput(NVBrightnessPoint point) {
    const double hardwareMinimum = 0.05;
    if (point.software < 1.0) return hardwareMinimum * point.software;
    if (point.software > 1.0) return point.software;
    return hardwareMinimum + point.hardware * (1.0 - hardwareMinimum);
}

#endif
