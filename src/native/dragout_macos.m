// Dragging Files rows out of the window (src/files_drag_out.odin): once a tree drag's pointer
// leaves the window, AppKit's own drag session carries the rows' files to Finder, a terminal,
// another app or a browser's upload field.
//
//  - What goes on the drag pasteboard: one item per path, its file URL (NSPasteboardTypeFileURL);
//    the first item also has the text (NSPasteboardTypeString, for apps that take text only): every
//    path shell-quoted, on one line, space-separated. URLs of existing files only: no file
//    promises, nothing of their contents.
//  - Copy only, and only to other apps: Finder copies (never moves the project's files out); back
//    over Deckhand's own window the drag offers nothing (no FILES_DROPPED of our own files), and
//    dh_drag_out_active says a drag of ours is on (files_drag_out_event drops one anyway).
//  - AppKit's drag takes the button's release: sokol's view never gets its mouseUp: and would go
//    on thinking the left button is down (no enter/leave events until the next click). When the
//    drag ends and the left button is up (Esc ends it with the button still held: then once the
//    button is let go), a mouseUp: of our own goes to the view; dh_drag_out_synthetic says so
//    while it is delivered, and Deckhand eats it (files_drag_out_event): it reaches no pane or
//    terminal.
//  - The window keeps drawing meanwhile: sokol's display link runs in the run loop's common modes,
//    the drag's tracking mode among them.
//
// Built by build.sh into build/dh_dragout.a (the test hook, dragout_test_macos.m, is a member of
// its own: linked only into builds that call it).

#import <Cocoa/Cocoa.h>

static int session_active; // a drag of ours is on: from its start to its end
static int synthetic_up;   // our own mouseUp: is being delivered to sokol's view

// What a drag of ours offers: a copy to another app; nothing inside Deckhand.
int dh_drag_out_mask(int outside_app) {
    return outside_app ? (int)NSDragOperationCopy : (int)NSDragOperationNone;
}

int dh_drag_out_active(void) { return session_active; }
int dh_drag_out_synthetic(void) { return synthetic_up; }

// Waiting for the left button to be let go after a drag ended: every RELEASE_POLL, at most
// RELEASE_TRIES times (then the release goes anyway: Deckhand eats it either way).
#define RELEASE_POLL 0.05
#define RELEASE_TRIES 1200

// Sends sokol's view our own left mouseUp: once the left button is up.
static void release_when_up(NSView* view, NSPoint screen_point, int tries) {
    __weak NSView* weak_view = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, tries == 0 ? 0 : (int64_t)(RELEASE_POLL * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSView* v = weak_view;
        NSWindow* w = v.window;
        if (!v || !w) return;
        if (([NSEvent pressedMouseButtons] & 1) && tries < RELEASE_TRIES) {
            release_when_up(v, screen_point, tries + 1);
            return;
        }
        NSPoint p = [w convertRectFromScreen:NSMakeRect(screen_point.x, screen_point.y, 0, 0)].origin;
        NSEvent* up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0
                                        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber
                                          context:nil eventNumber:0 clickCount:1 pressure:0];
        if (!up) return;
        synthetic_up = 1;
        [v mouseUp:up]; // sokol lets go of the button; Deckhand eats the release
        synthetic_up = 0;
    });
}

@interface DHDragOutSource : NSObject <NSDraggingSource>
@property (weak) NSView* view;
@end

@implementation DHDragOutSource
- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return (NSDragOperation)dh_drag_out_mask(context == NSDraggingContextOutsideApplication);
}
// ⌘ or ⌥ held over Finder cannot turn the copy into a move or a link
- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession*)session { return YES; }
- (void)draggingSession:(NSDraggingSession*)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    session_active = 0;
    if (self.view) release_when_up(self.view, screenPoint, 0); // not from inside AppKit's drag code
}
@end

static DHDragOutSource* source; // the session's source (kept: the session does not own it)

// One pasteboard item per path, its file URL; the first also the text. Also the test hook's.
NSArray<NSPasteboardItem*>* dh_drag_out_items(const char** paths, int n, const char* text) {
    NSMutableArray<NSPasteboardItem*>* out = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        NSString* p = paths[i] ? @(paths[i]) : nil;
        if (p.length == 0) continue;
        NSPasteboardItem* it = [NSPasteboardItem new];
        [it setString:[NSURL fileURLWithPath:p].absoluteString forType:NSPasteboardTypeFileURL];
        if (out.count == 0 && text && text[0]) [it setString:@(text) forType:NSPasteboardTypeString];
        [out addObject:it];
    }
    return out;
}

// The drag's picture: the label ("name" or "N items") on a small rounded plate.
static NSImage* label_image(NSString* text) {
    NSDictionary* attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : NSColor.labelColor,
    };
    NSSize ts = [text sizeWithAttributes:attrs];
    NSSize sz = NSMakeSize(ceil(ts.width) + 16, ceil(ts.height) + 8);
    return [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.92] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5] fill];
        [text drawAtPoint:NSMakePoint(8, 4) withAttributes:attrs];
        return YES;
    }];
}

// Starts the drag of paths (text: all of them quoted, one line) from the window's content view,
// while the event being handled is that view's left-button drag and the button is still down.
// 1: started; 0: not (no such event now, the button is up, a drag of ours is on already, nothing
// to drag).
int dh_drag_out_begin(void* window, const char** paths, int n, const char* text, const char* label) {
    if (session_active || n <= 0 || !window) return 0;
    NSWindow* w = (__bridge NSWindow*)window;
    NSView* v = w.contentView;
    NSEvent* e = NSApp.currentEvent;
    if (!v || !e || e.type != NSEventTypeLeftMouseDragged || e.window != w) return 0;
    if (([NSEvent pressedMouseButtons] & 1) == 0) return 0;
    NSArray<NSPasteboardItem*>* items = dh_drag_out_items(paths, n, text);
    if (items.count == 0) return 0;
    NSImage* img = label_image(label ? @(label) : @"");
    NSPoint at = [v convertPoint:e.locationInWindow fromView:nil];
    NSRect frame = NSMakeRect(at.x - 8, at.y - img.size.height / 2, img.size.width, img.size.height);
    NSMutableArray<NSDraggingItem*>* drag = [NSMutableArray array];
    for (NSPasteboardItem* it in items) {
        NSDraggingItem* d = [[NSDraggingItem alloc] initWithPasteboardWriter:it];
        [d setDraggingFrame:frame contents:img]; // one picture: the items lie on top of each other
        [drag addObject:d];
    }
    source = [DHDragOutSource new];
    source.view = v;
    NSDraggingSession* s = [v beginDraggingSessionWithItems:drag event:e source:source];
    if (!s) return 0;
    s.animatesToStartingPositionsOnCancelOrFail = YES;
    s.draggingFormation = NSDraggingFormationNone;
    session_active = 1;
    return 1;
}
