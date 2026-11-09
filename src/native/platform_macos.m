// macOS window pieces sokol does not have (src/platform_darwin.odin wraps them):
//
//  - Blended title bar: full-size content view, transparent title bar, hidden
//    title, traffic lights moved into our top bar (re-placed after resizes,
//    as AppKit lays them out again).
//  - Input methods: sokol's view gets NSTextInputClient at run time (methods
//    added with the Objective-C runtime; vendor files untouched) and its
//    keyDown: is wrapped: keys go through interpretKeyEvents first, so dead
//    keys, IMEs and the emoji picker work. Keys that do not take part in a
//    composition still go to sokol's own keyDown: (KEY_DOWN + CHAR events), so
//    terminal key encoding is unchanged. Composition and committed text go to
//    callbacks in Odin.
//  - Window drag / title-bar double-click from our own top bar, the
//    double-click interval, a folder picker.
//  - Appearance: the OS light/dark (NSApp.effectiveAppearance, observed with
//    KVO: no polling) and the window's own appearance (title bar, folder
//    picker) when the user picked light or dark.
//  - The display's rate: sokol's display link runs at the MAIN screen's maximum
//    frame rate, fixed at launch; it is retargeted to the window's own screen
//    (and again when the window moves or the screens change), and that rate and
//    scale are kept for app tabs (docs/ENGINE-BRIDGE.md §2.1, "Display rate").
//
// Built by build.sh into build/dh_platform.a.

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>

typedef struct {
    void (*insert)(const char* utf8, int len);              // committed text
    void (*marked)(const char* utf8, int len, int caret);   // composition, "" = none; caret = byte offset
    void (*caret_rect)(float* x, float* y, float* w, float* h); // framebuffer px, top-left origin
    int (*option_composes)(void);                           // 1: Option may start a dead key
} dh_ime_callbacks;

static dh_ime_callbacks cb;
static NSWindow* win;
static void display_watch(void); // the display's rate (below)
static NSView* view;
static NSString* marked_text; // current composition ("" = none)
static NSString* pending_insert; // insertText during interpretKeyEvents
static BOOL in_key_down;
static BOOL command_in_key; // doCommandBySelector during the key press (Enter, Tab, arrows)
static IMP orig_key_down;
static NSArray<NSString*>* test_ops; // test mode: replaces interpretKeyEvents for one key press
static float bar_h_pt, light_x_pt; // traffic lights: centred in a bar this tall, first one at this x

static void send_marked(NSString* s, NSUInteger caret16) {
    if (!cb.marked) return;
    NSString* head = [s substringToIndex:MIN(caret16, s.length)];
    const char* u = s.UTF8String;
    cb.marked(u, (int)strlen(u), (int)strlen(head.UTF8String));
}

static NSString* plain(id string) {
    return [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString*)string string] : (NSString*)string;
}

// ---- NSTextInputClient ----

static void ti_insertText(id self, SEL _cmd, id string, NSRange rr) {
    NSString* s = plain(string);
    if (marked_text.length > 0) {
        marked_text = @"";
        send_marked(@"", 0);
    }
    if (in_key_down) {
        // keyDown decides who gets it; an input method may commit more than once per key
        pending_insert = pending_insert ? [pending_insert stringByAppendingString:s] : [s copy];
        return;
    }
    // outside a key press: emoji picker, character viewer, dictation
    const char* u = s.UTF8String;
    if (cb.insert && u) cb.insert(u, (int)strlen(u));
}

static void ti_setMarkedText(id self, SEL _cmd, id string, NSRange sel, NSRange rr) {
    marked_text = [plain(string) copy];
    send_marked(marked_text, sel.location == NSNotFound ? marked_text.length : sel.location + sel.length);
}

static void ti_unmarkText(id self, SEL _cmd) {
    if (marked_text.length == 0) return;
    marked_text = @"";
    send_marked(@"", 0);
}

static BOOL ti_hasMarkedText(id self, SEL _cmd) { return marked_text.length > 0; }
static NSRange ti_markedRange(id self, SEL _cmd) {
    return marked_text.length > 0 ? NSMakeRange(0, marked_text.length) : NSMakeRange(NSNotFound, 0);
}
static NSRange ti_selectedRange(id self, SEL _cmd) { return NSMakeRange(0, 0); }
static NSArray* ti_validAttributes(id self, SEL _cmd) { return @[]; }
static NSAttributedString* ti_attributedSubstring(id self, SEL _cmd, NSRange r, NSRangePointer actual) { return nil; }
static NSUInteger ti_characterIndexForPoint(id self, SEL _cmd, NSPoint p) { return NSNotFound; }
// The key is a command (Enter, Tab, arrows): it goes on to sokol (dh_keyDown). No beep.
// The view's own input context. NSView makes one only for views that conform
// to NSTextInputClient when it is first asked, which happened before the
// protocol was added at run time: without this, inputContext stays nil,
// interpretKeyEvents falls back to key bindings, and every typed character
// goes to NSResponder's insertText:, up the responder chain, and beeps.
static NSTextInputContext* input_context;
static NSTextInputContext* ti_inputContext(id self, SEL _cmd) {
    if (!input_context) input_context = [[NSTextInputContext alloc] initWithClient:(id<NSTextInputClient>)self];
    return input_context;
}

// The legacy entry point (key bindings without an input context): the same
// as the input context's call, never the responder chain's beep.
static void ti_insertTextLegacy(id self, SEL _cmd, id string) {
    ti_insertText(self, _cmd, string, NSMakeRange(NSNotFound, 0));
}

static void ti_doCommandBySelector(id self, SEL _cmd, SEL sel) {
    if (in_key_down) command_in_key = YES;
}

// Where the candidate window goes: under the caret, in screen coordinates.
static NSRect ti_firstRect(id self, SEL _cmd, NSRange r, NSRangePointer actual) {
    float x = 0, y = 0, w = 0, h = 0;
    if (cb.caret_rect) cb.caret_rect(&x, &y, &w, &h);
    CGFloat s = win.backingScaleFactor;
    NSRect b = view.bounds;
    NSRect inView = NSMakeRect(x / s, view.isFlipped ? y / s : b.size.height - (y + h) / s, w / s, h / s);
    return [win convertRectToScreen:[view convertRect:inView toView:nil]];
}

// keyDown: through the input system first. Cmd and Ctrl chords, and Option
// when it acts as Alt (terminal), go straight to sokol unless a composition is
// open.
static void dh_keyDown(id self, SEL _cmd, NSEvent* ev) {
    NSEventModifierFlags m = ev.modifierFlags;
    BOOL composing = marked_text.length > 0;
    BOOL chord = (m & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    BOOL alt = (m & NSEventModifierFlagOption) != 0 && !(cb.option_composes && cb.option_composes());
    if (!composing && (chord || alt)) {
        ((void (*)(id, SEL, NSEvent*))orig_key_down)(self, _cmd, ev);
        return;
    }
    if (!composing && ev.isARepeat) {
        // a held key repeats (terminal, fields); it never opens the accent popover
        ((void (*)(id, SEL, NSEvent*))orig_key_down)(self, _cmd, ev);
        return;
    }
    pending_insert = nil;
    command_in_key = NO;
    in_key_down = YES;
    if (test_ops) {
        // test mode: what an input method would call for this key
        NSArray<NSString*>* ops = test_ops;
        test_ops = nil;
        for (NSString* op in ops) {
            NSRange none = NSMakeRange(NSNotFound, 0);
            if ([op hasPrefix:@"mark="]) {
                NSString* t = [op substringFromIndex:5];
                [(id<NSTextInputClient>)self setMarkedText:t selectedRange:NSMakeRange(t.length, 0) replacementRange:none];
            } else if ([op hasPrefix:@"insert="]) [(id<NSTextInputClient>)self insertText:[op substringFromIndex:7] replacementRange:none];
            else if ([op hasPrefix:@"cmd="]) [(id<NSTextInputClient>)self doCommandBySelector:NSSelectorFromString([op substringFromIndex:4])];
            else if ([op isEqualToString:@"unmark"]) [(id<NSTextInputClient>)self unmarkText];
        }
    } else {
        [self interpretKeyEvents:@[ ev ]];
    }
    in_key_down = NO;
    NSString* text = pending_insert;
    pending_insert = nil;
    void (*key_down)(id, SEL, NSEvent*) = (void (*)(id, SEL, NSEvent*))orig_key_down;
    if (composing || marked_text.length > 0) {
        // the input method used this key (dead key, IME): its result first...
        if (text.length > 0 && cb.insert) cb.insert(text.UTF8String, (int)strlen(text.UTF8String));
        // ...then the key itself if it also ended the composition as a command
        // (한 + Enter: commit 한, then Enter submits / runs the line)
        if (command_in_key && marked_text.length == 0) key_down(self, _cmd, ev);
        return;
    }
    if (text.length > 0 && ![text isEqualToString:ev.characters]) {
        // no composition, but the input method changed the text (Pinyin , -> ，):
        // its text, not sokol's CHAR for the key
        if (cb.insert) cb.insert(text.UTF8String, (int)strlen(text.UTF8String));
        return;
    }
    key_down(self, _cmd, ev);
}

static void add(Class cls, SEL sel, IMP imp) {
    struct objc_method_description d = protocol_getMethodDescription(@protocol(NSTextInputClient), sel, YES, YES);
    if (d.types == NULL) d = protocol_getMethodDescription(@protocol(NSTextInputClient), sel, NO, YES);
    class_addMethod(cls, sel, imp, d.types);
}

// ---- title bar ----

static void place_traffic_lights(void) {
    if (!win || (win.styleMask & NSWindowStyleMaskFullScreen)) return;
    NSButton* close = [win standardWindowButton:NSWindowCloseButton];
    NSButton* mini = [win standardWindowButton:NSWindowMiniaturizeButton];
    NSButton* zoom = [win standardWindowButton:NSWindowZoomButton];
    if (!close || !mini || !zoom) return;
    // the title bar keeps its height (28 pt): a 14 pt light centred 20 pt
    // down still fits in it, so nothing else needs to move
    NSView* tb = close.superview;
    CGFloat gap = mini.frame.origin.x - close.frame.origin.x;
    // centre of the bar, in window coordinates (y up), then in the buttons' superview
    NSPoint c = [tb convertPoint:NSMakePoint(0, win.contentView.frame.size.height - bar_h_pt / 2) fromView:nil];
    NSButton* bs[3] = {close, mini, zoom};
    for (int i = 0; i < 3; i++) {
        NSRect f = bs[i].frame;
        f.origin.x = light_x_pt + i * gap;
        f.origin.y = round(c.y - f.size.height / 2);
        if (!NSEqualPoints(f.origin, bs[i].frame.origin)) [bs[i] setFrameOrigin:f.origin];
    }
}

// AppKit lays the title bar out again on its own (activation, resizes):
// called after every drawn frame, cheap when nothing moved.
void dh_mac_place_lights(void) { place_traffic_lights(); }

// ---- API ----

// Blends the title bar into the content: our top bar is bar_h logical px tall;
// the traffic lights sit centred in it, the first at light_x.
void dh_mac_init(void* window, const dh_ime_callbacks* callbacks, float bar_h, float light_x, float min_w, float min_h) {
    // held keys repeat instead of opening the accent popover (a terminal
    // needs repeats); registered, so a user's own setting still wins
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"ApplePressAndHoldEnabled" : @NO}];
    win = (__bridge NSWindow*)window;
    view = win.contentView;
    cb = *callbacks;
    marked_text = @"";
    bar_h_pt = bar_h;
    light_x_pt = light_x;

    win.styleMask |= NSWindowStyleMaskFullSizeContentView;
    win.titlebarAppearsTransparent = YES;
    win.contentMinSize = NSMakeSize(min_w, min_h); // the chrome's layout is checked down to this size
    win.titleVisibility = NSWindowTitleHidden;
    if (@available(macOS 11.0, *)) win.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    place_traffic_lights();
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    for (NSString* n in @[ NSWindowDidResizeNotification, NSWindowDidExitFullScreenNotification, NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification ]) {
        [nc addObserverForName:n object:win queue:nil usingBlock:^(NSNotification* note) { place_traffic_lights(); }];
    }

    Class cls = object_getClass(view);
    class_addProtocol(cls, @protocol(NSTextInputClient));
    add(cls, @selector(insertText:replacementRange:), (IMP)ti_insertText);
    add(cls, @selector(setMarkedText:selectedRange:replacementRange:), (IMP)ti_setMarkedText);
    add(cls, @selector(unmarkText), (IMP)ti_unmarkText);
    add(cls, @selector(hasMarkedText), (IMP)ti_hasMarkedText);
    add(cls, @selector(markedRange), (IMP)ti_markedRange);
    add(cls, @selector(selectedRange), (IMP)ti_selectedRange);
    add(cls, @selector(validAttributesForMarkedText), (IMP)ti_validAttributes);
    add(cls, @selector(attributedSubstringForProposedRange:actualRange:), (IMP)ti_attributedSubstring);
    add(cls, @selector(characterIndexForPoint:), (IMP)ti_characterIndexForPoint);
    add(cls, @selector(firstRectForCharacterRange:actualRange:), (IMP)ti_firstRect);
    add(cls, @selector(doCommandBySelector:), (IMP)ti_doCommandBySelector);
    class_addMethod(cls, @selector(inputContext), (IMP)ti_inputContext, "@@:");
    class_addMethod(cls, @selector(insertText:), (IMP)ti_insertTextLegacy, "v@:@");
    if (win.isKeyWindow) [view.inputContext activate];
    Method kd = class_getInstanceMethod(cls, @selector(keyDown:));
    orig_key_down = method_setImplementation(kd, (IMP)dh_keyDown);
    display_watch();
}

// ---- the display's rate (app tabs pace from it; sokol's frame loop follows it) ----
//
// sokol creates its CADisplayLink with -[NSView displayLinkWithTarget:selector:] (the link
// follows the view's screen) but fixes its preferredFrameRateRange at launch to
// NSScreen.mainScreen.maximumFramesPerSecond: a window on a 240 Hz screen while the main screen
// is 60 Hz would draw at 60. dh_mac_display_hook (before sokol starts) catches that link; each
// screen change sets its range to the window's screen's maximum. Vendor files stay untouched.

static CADisplayLink* display_link; // sokol's, caught as it is made
static atomic_int display_fps = 60; // the window's screen's maximumFramesPerSecond (any thread)
static _Atomic float display_scale = 1; // its backing scale (any thread)
static int test_fps; // test mode's override (0 = the screen's)
static int link_cap = 120; // the display link asks for at most this (0 = the screen's maximum): the frame loop's choice
static IMP orig_display_link;
static void display_update(void);

static id hook_display_link(id self, SEL _cmd, id target, SEL sel) {
    id link = ((id (*)(id, SEL, id, SEL))orig_display_link)(self, _cmd, target, sel);
    display_link = link;
    // a link made again later (sokol remakes it): the window's screen and cap, once sokol has set
    // its own range right after this returns
    if (win) dispatch_async(dispatch_get_main_queue(), ^{ display_update(); });
    return link;
}

// Before sokol starts: sokol's view class gets a displayLinkWithTarget:selector: that keeps the
// link it makes (NSView's own does the work).
void dh_mac_display_hook(void) {
    Class cls = NSClassFromString(@"_sapp_macos_view");
    Method m = class_getInstanceMethod([NSView class], @selector(displayLinkWithTarget:selector:));
    if (!cls || !m) return;
    orig_display_link = method_getImplementation(m);
    class_addMethod(cls, @selector(displayLinkWithTarget:selector:), (IMP)hook_display_link, method_getTypeEncoding(m));
}

// The window's screen (else the main screen): its maximum rate and scale; the display link
// follows it. Main thread.
static void display_update(void) {
    NSScreen* scr = win.screen ? win.screen : NSScreen.mainScreen;
    NSInteger fps = scr ? scr.maximumFramesPerSecond : 60;
    if (fps <= 0) fps = 60;
    if (test_fps > 0) fps = test_fps;
    atomic_store(&display_fps, (int)fps);
    atomic_store(&display_scale, (float)(win ? win.backingScaleFactor : (scr ? scr.backingScaleFactor : 1)));
    if (display_link) {
        // as sokol sets it (swap interval 1), for this screen; capped while nothing live shows
        float f = (float)(link_cap > 0 && link_cap < fps ? link_cap : fps);
        CAFrameRateRange r = CAFrameRateRangeMake(f, f, f);
        CAFrameRateRange cur = display_link.preferredFrameRateRange;
        if (cur.minimum != r.minimum || cur.maximum != r.maximum || cur.preferred != r.preferred) display_link.preferredFrameRateRange = r;
    }
}

static void display_watch(void) {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    // moved to another screen, its backing scale changed, or a screen's mode (ProMotion, VRR,
    // a display's refresh rate in System Settings) or the screen set changed
    for (NSString* n in @[ NSWindowDidChangeScreenNotification, NSWindowDidChangeBackingPropertiesNotification ]) {
        [nc addObserverForName:n object:win queue:nil usingBlock:^(NSNotification* note) { display_update(); }];
    }
    [nc addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:nil usingBlock:^(NSNotification* note) { display_update(); }];
    display_update();
}

// The display link asks for at most cap frames per second (0 = the screen's maximum). Main
// thread, each frame: nothing happens unless it changed.
void dh_mac_display_link_cap(int cap) {
    if (cap < 0) cap = 0;
    if (cap == link_cap) return;
    link_cap = cap;
    display_update();
}

// The window's screen's maximum frames per second, and its backing scale (any thread).
int dh_mac_display_fps(void) { return atomic_load(&display_fps); }
float dh_mac_display_scale(void) { return atomic_load(&display_scale); }
// What sokol's display link asks for now (tests; 0 = no link).
float dh_mac_display_link_fps(void) { return display_link ? display_link.preferredFrameRateRange.preferred : 0; }
// Test mode: report this rate, as if the window moved to such a screen (0 = the screen's).
void dh_mac_test_display_fps(int fps) {
    test_fps = fps > 0 ? fps : 0;
    display_update();
}

// Drops an open composition (focus moved elsewhere).
void dh_mac_ime_cancel(void) {
    if (marked_text.length == 0) return;
    [view.inputContext discardMarkedText];
    marked_text = @"";
    send_marked(@"", 0);
}

// The caret moved: the candidate window follows.
void dh_mac_ime_caret_moved(void) {
    if (marked_text.length > 0) [view.inputContext invalidateCharacterCoordinates];
}

// Called while handling a mouse down in an empty part of the top bar.
void dh_mac_window_drag(void) {
    NSEvent* e = NSApp.currentEvent;
    if (e && e.type == NSEventTypeLeftMouseDown) [win performWindowDragWithEvent:e];
}

// A double-click in an empty part of the top bar, as the title bar does it
// (System Settings › Desktop & Dock › "Double-click a window's title bar to").
void dh_mac_titlebar_double_click(void) {
    NSString* a = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleActionOnDoubleClick"];
    if ([a isEqualToString:@"Minimize"]) [win performMiniaturize:nil];
    else if (![a isEqualToString:@"None"]) [win performZoom:nil];
}

double dh_mac_double_click_interval(void) { return NSEvent.doubleClickInterval; }

void dh_mac_set_title(const char* title) {
    win.title = [NSString stringWithUTF8String:title] ?: @"";
}

// Folder picker (modal). Copies the path into buf; returns its length, 0 if cancelled.
int dh_mac_pick_folder(char* buf, int cap) {
    NSOpenPanel* p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.allowsMultipleSelection = NO;
    p.canCreateDirectories = YES; // a new project can start in a new folder
    p.prompt = @"Add Project";
    p.appearance = win.appearance; // nil: follows the OS, like the window
    if ([p runModal] != NSModalResponseOK || p.URLs.count == 0) return 0;
    const char* s = p.URLs[0].path.fileSystemRepresentation;
    int n = (int)strlen(s);
    if (n >= cap) return 0;
    memcpy(buf, s, (size_t)n + 1);
    return n;
}

// ---- appearance ----

// NSApp's appearance is never set (only the window's), so its effective
// appearance is the OS's.
int dh_mac_system_light(void) {
    NSAppearanceName n = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return ![n isEqualToString:NSAppearanceNameDarkAqua];
}

@interface PdAppearanceObserver : NSObject
@property void (*changed)(int light);
@end
@implementation PdAppearanceObserver
- (void)observeValueForKeyPath:(NSString*)path ofObject:(id)obj change:(NSDictionary*)change context:(void*)ctx {
    if (self.changed) self.changed(dh_mac_system_light());
}
@end

static PdAppearanceObserver* appearance_observer;

// Calls changed(light) on the main thread whenever the OS switches between
// light and dark (System Settings, or Auto at sunset).
void dh_mac_watch_appearance(void (*changed)(int light)) {
    if (appearance_observer) return;
    appearance_observer = [PdAppearanceObserver new];
    appearance_observer.changed = changed;
    [NSApp addObserver:appearance_observer forKeyPath:@"effectiveAppearance" options:0 context:NULL];
}

// The window's appearance: 0 follows the OS, 1 light (Aqua), 2 dark (Dark Aqua).
void dh_mac_set_appearance(int mode) {
    win.appearance = mode == 1 ? [NSAppearance appearanceNamed:NSAppearanceNameAqua]
                   : mode == 2 ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
}

// Test mode: the window's effective appearance (1 light, 0 dark).
int dh_mac_test_window_light(void) {
    NSAppearanceName n = [win.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return ![n isEqualToString:NSAppearanceNameDarkAqua];
}

// Shows a file or folder in Finder (selected in its parent's window).
void dh_mac_reveal(const char* path) {
    NSString* s = [NSString stringWithUTF8String:path];
    if (!s) return;
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:s]]];
}

// Opens a web or mail link (Markdown and terminal links) with the user's
// default app. 1: handed to the app; 0: not a URL NSURL reads, or refused.
int dh_mac_open_url(const char* url) {
    NSString* s = [NSString stringWithUTF8String:url];
    if (!s) return 0;
    NSURL* u = [NSURL URLWithString:s];
    if (!u || !u.scheme) return 0;
    return [[NSWorkspace sharedWorkspace] openURL:u] ? 1 : 0;
}

// ---- test mode (DECKHAND_SCRIPT): in-process only, never posted to the system ----

// What gets a click at (x, y) framebuffer px: 1 = our view, 0 = something
// else (the title bar), -1 = nothing.
int dh_mac_test_hit(float x, float y) {
    CGFloat s = win.backingScaleFactor;
    NSView* frame = view.superview; // the window's frame view: its hitTest takes window coordinates
    NSPoint p = NSMakePoint(x / s, view.isFlipped ? y / s : view.bounds.size.height - y / s);
    NSView* hit = [frame hitTest:[view convertPoint:p toView:nil]];
    return hit == view ? 1 : (hit ? 0 : -1);
}

// Traffic light centre (logical px from the content's top-left).
void dh_mac_test_light(float* x, float* y) {
    NSButton* close = [win standardWindowButton:NSWindowCloseButton];
    NSRect r = [close convertRect:close.bounds toView:nil];
    *x = (float)NSMidX(r);
    *y = (float)(win.contentView.bounds.size.height - NSMidY(r));
}

// Drives the input client as an input method would: 0 = setMarkedText (caret
// at the end), 1 = insertText (outside a key press, like the emoji picker),
// 2 = a key press (keyCode, characters, Option if alt) through keyDown:.
// 3 = a key press (flags: 1 Option, 2 repeat) whose input method calls are
// `ops` (tab-separated: mark=TEXT, insert=TEXT, cmd=SELECTOR, unmark) instead
// of the system's: tests Deckhand's keyDown: handling without a real IME.
void dh_mac_test_ime(int kind, const char* text, int key_code, int alt, const char* ops) {
    NSString* s = [NSString stringWithUTF8String:text] ?: @"";
    if (kind == 3) {
        test_ops = [[NSString stringWithUTF8String:ops] componentsSeparatedByString:@"\t"];
        NSEvent* e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:(alt & 1) ? NSEventModifierFlagOption : 0 timestamp:NSProcessInfo.processInfo.systemUptime
            windowNumber:win.windowNumber context:nil characters:s charactersIgnoringModifiers:s
            isARepeat:(alt & 2) != 0 keyCode:(unsigned short)key_code];
        [view keyDown:e];
        test_ops = nil;
        return;
    }
    switch (kind) {
    case 0: [(id<NSTextInputClient>)view setMarkedText:s selectedRange:NSMakeRange(s.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)]; break;
    case 1: [(id<NSTextInputClient>)view insertText:s replacementRange:NSMakeRange(NSNotFound, 0)]; break;
    case 2: { // flags (alt): 1 Option, 2 repeat, 4 Cmd, 8 Ctrl, 16 Shift; then the key up
        NSEventModifierFlags m = ((alt & 1) ? NSEventModifierFlagOption : 0) | ((alt & 4) ? NSEventModifierFlagCommand : 0) |
            ((alt & 8) ? NSEventModifierFlagControl : 0) | ((alt & 16) ? NSEventModifierFlagShift : 0);
        for (int up = 0; up < 2; up++) {
            NSEvent* e = [NSEvent keyEventWithType:up ? NSEventTypeKeyUp : NSEventTypeKeyDown location:NSZeroPoint
                modifierFlags:m timestamp:NSProcessInfo.processInfo.systemUptime
                windowNumber:win.windowNumber context:nil characters:s charactersIgnoringModifiers:s
                isARepeat:(alt & 2) != 0 keyCode:(unsigned short)key_code];
            if (up) [view keyUp:e];
            else [view keyDown:e];
        }
        break;
    }
    }
}

// Test mode: counts AppKit's "nothing handled this" beeps instead of sounding
// them: a key that reaches NSResponder's own insertText: or
// doCommandBySelector: on our view goes up the responder chain and ends in a
// beep, as does noResponderFor:. Returns the count so far; the first call
// installs the counter.
static int beeps;
static void count_beep_sel(id self, SEL _cmd, SEL s) { beeps++; }
static void count_beep_obj(id self, SEL _cmd, id o) { beeps++; }
int dh_mac_test_beeps(void) {
    static BOOL installed;
    if (!installed) {
        installed = YES;
        Class cs[] = {[NSResponder class], [NSWindow class], [NSApplication class]};
        for (int i = 0; i < 3; i++) {
            Method m = class_getInstanceMethod(cs[i], @selector(noResponderFor:));
            if (m) method_setImplementation(m, (IMP)count_beep_sel);
        }
        Method ins = class_getInstanceMethod([NSResponder class], @selector(insertText:));
        if (ins) method_setImplementation(ins, (IMP)count_beep_obj);
        Method cmd = class_getInstanceMethod([NSResponder class], @selector(doCommandBySelector:));
        if (cmd) method_setImplementation(cmd, (IMP)count_beep_sel);
    }
    return beeps;
}

// Test mode: counts AppKit's Emoji & Symbols panel and dictation (the Edit
// menu's own items) instead of opening them. Returns the count so far; the
// first call installs the counter.
static int panels;
static void count_panel(id self, SEL _cmd, id sender) { panels++; }
int dh_mac_test_panels(void) {
    static BOOL installed;
    if (!installed) {
        installed = YES;
        SEL sels[] = {@selector(orderFrontCharacterPalette:), @selector(startDictation:)};
        for (int i = 0; i < 2; i++) {
            Method m = class_getInstanceMethod([NSApplication class], sels[i]);
            if (m) method_setImplementation(m, (IMP)count_panel);
        }
    }
    return panels;
}

// Test mode: whether sokol's view has an input context (input methods need one).
int dh_mac_test_has_input_context(void) { return view.inputContext != nil; }

// An OS notification from the agent. A bundled app (an identifier) uses the
// user notification center, asking for permission once; a bare binary (the
// dev build) cannot, so the Dock icon bounces once instead.
void dh_mac_notify(const char* title, const char* body) {
    NSString* t = [NSString stringWithUTF8String:title] ?: @"";
    NSString* b = [NSString stringWithUTF8String:body] ?: @"";
    if (NSBundle.mainBundle.bundleIdentifier == nil) {
        [NSApp requestUserAttention:NSInformationalRequest];
        return;
    }
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    static BOOL asked;
    if (!asked) {
        asked = YES;
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                              completionHandler:^(BOOL granted, NSError* error) {}];
    }
    UNMutableNotificationContent* content = [UNMutableNotificationContent new];
    content.title = t;
    content.body = b;
    UNNotificationRequest* req = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString] content:content trigger:nil];
    [center addNotificationRequest:req withCompletionHandler:nil];
}

// ---- quiet test mode (DECKHAND_SCRIPT, unless DECKHAND_QUIET=0) ----
//
// Scene runs must not disturb the person using the Mac. Called before sokol
// starts: the app never activates (accessory: no Dock icon, never frontmost,
// never takes the keyboard) and the window is ordered in behind the desktop
// picture, ignoring the mouse: never seen, but `screencapture -l` reads it.
// sokol's launch code (activation policy, activateIgnoringOtherApps:,
// makeKeyAndOrderFront:) is overridden at run time; vendor files stay
// untouched. Frames still come from the display
// link (or sokol's 60 Hz timer if macOS reports the window occluded).

static IMP orig_set_policy;
static BOOL quiet_set_policy(id self, SEL _cmd, NSApplicationActivationPolicy p) {
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))orig_set_policy)(self, _cmd, NSApplicationActivationPolicyAccessory);
}
static void quiet_activate_flag(id self, SEL _cmd, BOOL flag) {}
static void quiet_activate(id self, SEL _cmd) {}
static NSRect quiet_constrain(id self, SEL _cmd, NSRect r, NSScreen* s) { return r; } // `resize` may exceed the screen
static void quiet_order_front(NSWindow* self, SEL _cmd, id sender) {
    // behind the desktop picture on the main screen: hidden by it, yet on a
    // display, so Metal presents and `screencapture -l` sees the frames
    // (fully off-screen, nothing is presented and captures fail)
    self.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey) - 1;
    [self setFrameOrigin:NSScreen.mainScreen.visibleFrame.origin];
    self.ignoresMouseEvents = YES;
    self.collectionBehavior |= NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    [self orderFrontRegardless]; // ordered in (captures work), not key, app not activated
}

static void replace(Class cls, SEL sel, IMP imp, IMP* orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_setImplementation(m, imp);
    if (orig) *orig = old;
}

// The left mouse button is down right now (a drag whose mouseUp: we missed).
int dh_mac_left_button_down(void) { return ([NSEvent pressedMouseButtons] & 1) != 0; }

// ---- the clipboard's change count (browser_act.odin: a page changing it during an agent's
// input is told to the user; nothing of its contents is read) ----

long dh_mac_pasteboard_count(void) { return (long)[[NSPasteboard generalPasteboard] changeCount]; }

// A secret onto the clipboard (Copy a control token): the text plus nspasteboard.org's concealed
// and transient markers, so clipboard managers neither show nor keep it. The change count after.
long dh_mac_pasteboard_set_secret(const char* text) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:@(text) forType:NSPasteboardTypeString];
    [pb setData:[NSData data] forType:@"org.nspasteboard.ConcealedType"];
    [pb setData:[NSData data] forType:@"org.nspasteboard.TransientType"];
    return (long)[pb changeCount];
}

// Clears the clipboard if nothing changed it since count (it still holds the secret).
void dh_mac_pasteboard_clear_if(long count) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    if ((long)[pb changeCount] == count) [pb clearContents];
}

// Quit: every window out of sight before the session holder's handover and the final save (they
// can take seconds; a frozen window under a beachball looks hung). The app keeps running.
void dh_mac_hide_windows(void) {
    for (NSWindow* w in [NSApp windows]) [w orderOut:nil];
}

// A modal alert with one Quit button (instance.odin: another Deckhand or Deckhand runs).
void dh_mac_alert(const char* title, const char* text) {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert* a = [[NSAlert alloc] init];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = @(title);
    a.informativeText = @(text);
    [a addButtonWithTitle:@"Quit"];
    [a runModal];
}

void dh_mac_quiet(void) {
    Class app = [NSApplication class];
    replace(app, @selector(setActivationPolicy:), (IMP)quiet_set_policy, &orig_set_policy);
    replace(app, @selector(activateIgnoringOtherApps:), (IMP)quiet_activate_flag, NULL);
    replace(app, @selector(activate), (IMP)quiet_activate, NULL); // macOS 14+
    replace([NSWindow class], @selector(makeKeyAndOrderFront:), (IMP)quiet_order_front, NULL);
    replace([NSWindow class], @selector(constrainFrameRect:toScreen:), (IMP)quiet_constrain, NULL);
    [NSApplication sharedApplication].activationPolicy = NSApplicationActivationPolicyAccessory;
}

// ---- test mode's backing scale (DECKHAND_SCALE; docs/DEVELOPING.md) ----
//
// Deckhand renders at the same backing scale on every Mac: `scale`, whatever the display's (a
// Retina display is 2, most others and CI runners 1). Every screen and window reports it, so
// sokol's dpi_scale, the drawable's size, app tabs' rings, app_screenshot PNGs and Deckhand's own
// conversions (dh_mac_test_hit, the IME's rectangle) all agree. Not the window server: the
// `shot` command's screencapture records the window at the real display's scale. Before sokol
// starts.

static CGFloat test_scale = 1;
static CGFloat test_backing_scale(id self, SEL _cmd) { return test_scale; }

void dh_mac_test_scale(double scale) {
    test_scale = scale;
    replace([NSScreen class], @selector(backingScaleFactor), (IMP)test_backing_scale, NULL);
    replace([NSWindow class], @selector(backingScaleFactor), (IMP)test_backing_scale, NULL);
}

// ---- jobs (src/core/jobs.odin) ----

// No App Nap while a job runs (its timers stay on time).
static id job_activity;
void dh_mac_activity(int on) {
    if (on && !job_activity) {
        job_activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Deckhand: a job runs or a terminal has output"];
    } else if (!on && job_activity) {
        [[NSProcessInfo processInfo] endActivity:job_activity];
        job_activity = nil;
    }
}

// ---- Dock Quit, logout, restart, shutdown (main.odin's quit_route) ----
//
// sokol's app delegate has no applicationShouldTerminate:, so -[NSApp terminate:] (the Dock's
// Quit, a script's `quit app`, logout) went straight to applicationWillTerminate: and cleanup,
// skipping what ⌘Q does. It gets one at run time (vendor files untouched): cb(logout) says
// whether to terminate now (1) or not (0: the window carries out the quit its own way and
// terminates later). logout: the quit Apple event gives a reason (log out, restart, shut down).

static int (*terminate_cb)(int logout);

static NSApplicationTerminateReply should_terminate(id self, SEL _cmd, NSApplication* sender) {
    NSAppleEventDescriptor* e = [[NSAppleEventManager sharedAppleEventManager] currentAppleEvent];
    int logout = e != nil && e.eventClass == kCoreEventClass && e.eventID == kAEQuitApplication &&
                 [e attributeDescriptorForKeyword:kAEQuitReason] != nil;
    if (!terminate_cb || terminate_cb(logout)) return NSTerminateNow;
    return NSTerminateCancel;
}

void dh_mac_terminate_hook(int (*cb)(int logout)) {
    terminate_cb = cb;
    id d = NSApp.delegate;
    if (!d) return;
    SEL sel = @selector(applicationShouldTerminate:);
    class_replaceMethod([d class], sel, (IMP)should_terminate, "Q@:@");
}
