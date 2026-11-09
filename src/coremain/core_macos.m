// deckhand-core serve's few Cocoa calls (src/coremain/serve.odin): App Nap held off while output
// flows or a job runs (platform.activity), the Trash, and notifications while no window is
// attached (Deckhand Core's own banners). Never linked into src/core.
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

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

// A banner from Deckhand Core (no window attached), asking for permission once. 0: not shown (a
// bare binary has no bundle to post as).
int dh_core_notify(const char *title, const char *body) {
    @autoreleasepool {
        if (NSBundle.mainBundle.bundleIdentifier == nil) return 0;
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        static BOOL asked;
        if (!asked) {
            asked = YES;
            [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                  completionHandler:^(BOOL granted, NSError *error) {}];
        }
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = [NSString stringWithUTF8String:title] ?: @"";
        content.body = [NSString stringWithUTF8String:body] ?: @"";
        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString] content:content trigger:nil];
        [center addNotificationRequest:req withCompletionHandler:nil];
        return 1;
    }
}
