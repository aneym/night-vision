#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import "brightness_mapping.h"

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);

typedef struct {
    double logical;
    double hardware;
    double software;
    int mappingVersion;
} NVState;

static NSString *statePath(void) {
    return [@"~/.local/state/night-vision/brightness-state.json" stringByExpandingTildeInPath];
}

static void usage(void) {
    fprintf(stderr, "usage: nvbrightness get | set <0-1> | reapply | status\n");
    exit(2);
}

static CGDirectDisplayID builtinDisplay(void) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return 0;
    CGDirectDisplayID displays[count];
    if (CGGetOnlineDisplayList(count, displays, &count) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i])) return displays[i];
    }
    return 0;
}

static BOOL readState(NVState *state) {
    NSData *data = [NSData dataWithContentsOfFile:statePath()];
    if (!data) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return NO;
    NSNumber *logical = json[@"logical"];
    NSNumber *hardware = json[@"hardware"];
    NSNumber *software = json[@"software"];
    NSNumber *version = json[@"mappingVersion"];
    if (!logical || !hardware || !software || !version) return NO;
    state->logical = logical.doubleValue;
    state->hardware = hardware.doubleValue;
    state->software = software.doubleValue;
    state->mappingVersion = version.intValue;
    return state->mappingVersion == NV_BRIGHTNESS_MAPPING_VERSION;
}

static BOOL writeState(NVState state) {
    NSDictionary *json = @{
        @"logical": @(state.logical),
        @"hardware": @(state.hardware),
        @"software": @(state.software),
        @"mappingVersion": @(state.mappingVersion),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:nil];
    if (!data) return NO;
    NSString *path = statePath();
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSString *temporary = [path stringByAppendingString:@".tmp"];
    if (![data writeToFile:temporary options:NSDataWritingAtomic error:nil]) return NO;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    return [NSFileManager.defaultManager moveItemAtPath:temporary toPath:path error:nil];
}

static int readHardware(CGDirectDisplayID display, float *value) {
    return DisplayServicesGetBrightness(display, value);
}

static int applyHardware(CGDirectDisplayID display, double value) {
    return DisplayServicesSetBrightness(display, (float)value);
}

static CGError applySoftware(CGDirectDisplayID display, double factor) {
    enum { count = 256 };
    CGGammaValue red[count], green[count], blue[count];
    for (uint32_t i = 0; i < count; i++) {
        CGGammaValue value = (CGGammaValue)((double)i / (double)(count - 1) * factor);
        red[i] = value;
        green[i] = value;
        blue[i] = value;
    }
    return CGSetDisplayTransferByTable(display, count, red, green, blue);
}

static double gammaMaximum(CGDirectDisplayID display) {
    CGGammaValue red[256], green[256], blue[256];
    uint32_t count = 0;
    if (CGGetDisplayTransferByTable(display, 256, red, green, blue, &count) != kCGErrorSuccess || !count) return -1;
    return red[count - 1];
}

static int applyPoint(CGDirectDisplayID display, double logical, BOOL persist) {
    NVBrightnessPoint point = NVBrightnessMap(logical);
    int error = applyHardware(display, point.hardware);
    if (error) {
        fprintf(stderr, "DisplayServicesSetBrightness failed: %d\n", error);
        return 1;
    }
    CGError gammaError = applySoftware(display, point.software);
    if (gammaError != kCGErrorSuccess) {
        fprintf(stderr, "CGSetDisplayTransferByTable failed: %d\n", gammaError);
        return 1;
    }
    if (persist) {
        NVState state = {NVClamp(logical, 0, 1), point.hardware, point.software,
                         NV_BRIGHTNESS_MAPPING_VERSION};
        if (!writeState(state)) {
            fprintf(stderr, "failed to persist expanded brightness state\n");
            return 1;
        }
    }
    return 0;
}

static double currentLogical(float hardware, NVState *stateOut) {
    NVState state;
    if (readState(&state)) {
        /* An outside hardware adjustment exits the software-only region cleanly. */
        if (fabs(hardware - state.hardware) <= 0.03) {
            if (stateOut) *stateOut = state;
            return state.logical;
        }
    }
    state = (NVState){NVBrightnessUnmap(hardware, 1.0), hardware, 1.0,
                      NV_BRIGHTNESS_MAPPING_VERSION};
    if (stateOut) *stateOut = state;
    return state.logical;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) usage();
        CGDirectDisplayID display = builtinDisplay();
        if (!display) {
            fprintf(stderr, "no built-in display is online\n");
            return 1;
        }

        if (!strcmp(argv[1], "set") && argc == 3) {
            char *end = NULL;
            double value = strtod(argv[2], &end);
            if (!end || *end || !isfinite(value) || value < 0 || value > 1) usage();
            return applyPoint(display, value, YES);
        }

        if (!strcmp(argv[1], "reapply")) {
            NVState state;
            if (!readState(&state)) return 0;
            return applyPoint(display, state.logical, NO);
        }

        float hardware = 0;
        int error = readHardware(display, &hardware);
        if (error) {
            fprintf(stderr, "DisplayServicesGetBrightness failed: %d\n", error);
            return 1;
        }
        NVState state;
        double logical = currentLogical(hardware, &state);

        if (!strcmp(argv[1], "get")) {
            printf("%.6f\n", logical);
            return 0;
        }

        if (!strcmp(argv[1], "status")) {
            NSDictionary *json = @{
                @"displayID": @(display),
                @"builtin": @YES,
                @"logical": @(logical),
                @"hardware": @(hardware),
                @"software": @(state.software),
                @"gammaMax": @(gammaMaximum(display)),
                @"mappingVersion": @(NV_BRIGHTNESS_MAPPING_VERSION),
                @"lowEndBoundary": @(NV_BRIGHTNESS_LOW_END),
                @"normalMaxBoundary": @(NV_BRIGHTNESS_NORMAL_MAX),
                @"boostMax": @(NV_BRIGHTNESS_BOOST_MAX),
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:nil];
            fwrite(data.bytes, 1, data.length, stdout);
            fputc('\n', stdout);
            return 0;
        }
        usage();
    }
}
