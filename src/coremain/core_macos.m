// deckhand-core serve's few Cocoa calls (src/coremain/serve.odin): App Nap held off while output
// flows or a job runs (platform.activity), and the Trash. Never linked into src/core.
#import <Foundation/Foundation.h>

static id core_activity;

void dh_core_activity(int on) {
    if (on && !core_activity) {
        core_activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Deckhand Core: a job runs or a terminal has output"];
    } else if (!on && core_activity) {
        [[NSProcessInfo processInfo] endActivity:core_activity];
        core_activity = nil;
    }
}

int dh_core_trash(const char *path) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        return [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:nil] ? 1 : 0;
    }
}
