// Dragging Files rows out of the window (src/files_drag_out.odin): once a tree drag's pointer
// leaves the window, AppKit's own drag session carries the rows' files to Finder, a terminal,
// another app or a browser's upload field.
//
//  - What goes on the drag pasteboard: one item per path, its file URL (NSPasteboardTypeFileURL)
//    and its shell-quoted path as text (NSPasteboardTypeString, for apps that take text only).
//    URLs of existing files only: no file promises, nothing of their contents.
//  - Copy only, and only to other apps: Finder copies (never moves the project's files out); back
//    over Deckhand's own window the drag offers nothing (no FILES_DROPPED of our own files), and
//    dh_drag_out_active says a drag of ours is on (files_drag_out_event drops one anyway).
//  - AppKit's drag takes the button's release: sokol's view never gets its mouseUp: and would go
//    on thinking the left button is down (no enter/leave events until the next click). When the
//    drag ends, a mouseUp: of our own goes to the view on the next turn of the run loop; Deckhand
//    eats that release (files_drag_out_event), so it reaches no pane or terminal.
//  - The window keeps drawing meanwhile: sokol's display link runs in the run loop's common modes,
//    the drag's tracking mode among them.
//
// Built by build.sh into build/dh_dragout.a.

#import <Cocoa/Cocoa.h>

static int session_active; // a drag of ours is on: from its start to its end

// What a drag of ours offers: a copy to another app; nothing inside Deckhand.
int dh_drag_out_mask(int outside_app) {
    return outside_app ? (int)NSDragOperationCopy : (int)NSDragOperationNone;
}

int dh_drag_out_active(void) { return session_active; }

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
    NSView* v = self.view;
    // not from inside AppKit's drag code: the next turn of the run loop
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow* w = v.window;
        if (!v || !w) return;
        // pressed again already: that press's own release lets go of sokol's button (and this one
        // would end that press early)
        if ([NSEvent pressedMouseButtons] & 1) return;
        NSPoint p = [w convertRectFromScreen:NSMakeRect(screenPoint.x, screenPoint.y, 0, 0)].origin;
        NSEvent* up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0
                                        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber
                                          context:nil eventNumber:0 clickCount:1 pressure:0];
        if (up) [v mouseUp:up]; // sokol lets go of the button; Deckhand eats the release
    });
}
@end

static DHDragOutSource* source; // the session's source (kept: the session does not own it)

// One pasteboard item per path: its file URL and its quoted path as text.
static NSArray<NSPasteboardItem*>* items_for(const char** paths, const char** texts, int n) {
    NSMutableArray<NSPasteboardItem*>* out = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        NSString* p = paths[i] ? @(paths[i]) : nil;
        if (p.length == 0) continue;
        NSURL* u = [NSURL fileURLWithPath:p];
        NSPasteboardItem* it = [NSPasteboardItem new];
        [it setString:u.absoluteString forType:NSPasteboardTypeFileURL];
        if (texts && texts[i]) [it setString:@(texts[i]) forType:NSPasteboardTypeString];
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

// Starts the drag of paths (texts: their quoted paths) from the window's content view, while the
// event being handled is that view's left-button drag and the button is still down. 1: started;
// 0: not (no such event now, the button is up, a drag of ours is on already, nothing to drag).
int dh_drag_out_begin(void* window, const char** paths, const char** texts, int n, const char* label) {
    if (session_active || n <= 0 || !window) return 0;
    NSWindow* w = (__bridge NSWindow*)window;
    NSView* v = w.contentView;
    NSEvent* e = NSApp.currentEvent;
    if (!v || !e || e.type != NSEventTypeLeftMouseDragged || e.window != w) return 0;
    if (([NSEvent pressedMouseButtons] & 1) == 0) return 0;
    NSArray<NSPasteboardItem*>* items = items_for(paths, texts, n);
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

// Tests: the items a drag of paths would carry, written to a pasteboard of their own and read
// back: one line per item, "<file URL>\t<text>\n". The bytes written (cap at most); -1: no
// pasteboard.
int dh_drag_out_test_items(const char** paths, const char** texts, int n, char* out, int cap) {
    NSPasteboard* pb = [NSPasteboard pasteboardWithUniqueName];
    if (!pb) return -1;
    [pb clearContents];
    if (![pb writeObjects:items_for(paths, texts, n)]) {
        [pb releaseGlobally];
        return -1;
    }
    NSMutableString* s = [NSMutableString string];
    for (NSPasteboardItem* it in pb.pasteboardItems) {
        NSString* u = [it stringForType:NSPasteboardTypeFileURL] ?: @"";
        NSString* t = [it stringForType:NSPasteboardTypeString] ?: @"";
        [s appendFormat:@"%@\t%@\n", u, t];
    }
    [pb releaseGlobally];
    const char* u8 = s.UTF8String;
    int len = (int)strlen(u8);
    if (len > cap) len = cap;
    memcpy(out, u8, (size_t)len);
    return len;
}
