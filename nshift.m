// nshift — minimal Night Shift CLI via CoreBrightness (private framework).
// Build: clang -fobjc-arc -framework Foundation -F/System/Library/PrivateFrameworks -framework CoreBrightness nshift.m -o bin/nshift
#import <Foundation/Foundation.h>

typedef struct { int hour; int minute; } NSTime_;
typedef struct { NSTime_ fromTime; NSTime_ toTime; } NSchedule;
typedef struct {
    BOOL active;
    BOOL enabled;
    BOOL sunSchedulePermitted;
    int mode;
    NSchedule schedule;
    unsigned long long disableFlags;
    BOOL available;
} NStatus;

@interface CBBlueLightClient : NSObject
- (BOOL)setStrength:(float)strength commit:(BOOL)commit;
- (BOOL)getStrength:(float *)strength;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)setMode:(int)mode;
- (BOOL)getBlueLightStatus:(NStatus *)status;
+ (BOOL)supportsBlueLightReduction;
@end

static void usage(void) {
    fprintf(stderr, "usage: nshift on|off|status|temp <0-100>\n");
    exit(2);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) usage();
        if (![CBBlueLightClient supportsBlueLightReduction]) {
            fprintf(stderr, "nshift: Night Shift not supported on this system\n");
            return 1;
        }
        CBBlueLightClient *client = [[CBBlueLightClient alloc] init];
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"on"]) {
            if (![client setMode:0] || ![client setEnabled:YES]) return 1;
        } else if ([cmd isEqualToString:@"off"]) {
            if (![client setEnabled:NO]) return 1;
        } else if ([cmd isEqualToString:@"temp"]) {
            if (argc < 3) usage();
            float pct = strtof(argv[2], NULL);
            if (pct < 0 || pct > 100) usage();
            if (![client setStrength:pct / 100.0f commit:YES]) return 1;
            if (pct > 0 && (![client setMode:0] || ![client setEnabled:YES])) return 1;
        } else if ([cmd isEqualToString:@"status"]) {
            NStatus st;
            float strength = 0;
            [client getBlueLightStatus:&st];
            [client getStrength:&strength];
            printf("enabled=%s strength=%d mode=%d\n", st.enabled ? "yes" : "no",
                   (int)lroundf(strength * 100), st.mode);
        } else {
            usage();
        }
    }
    return 0;
}
