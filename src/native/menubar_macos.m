// The macOS menu bar (src/menubar.odin builds it from its table at startup,
// through src/platform_darwin.odin).
//
//  - Items of Deckhand's own (tag >= 0) call back into Odin: fire(tag) on a
//    click, state(tag) when AppKit validates them (when a menu opens or a key
//    equivalent is looked up; never per frame): bit 0 enabled, bit 1 checked.
//    Items whose title changes (the agent's name) also ask title(tag).
//  - A key equivalent of Deckhand's own is passed on to the view's keyDown:,
//    exactly as if there were no menu: the widget with the keyboard handles
//    it as it always did (main.odin), and it fires once. A click runs the item.
//  - AppKit's own items (About, Hide, Minimize, Zoom, Full screen...) use
//    their standard selectors and AppKit's validation.
//
// Built by build.sh into build/dh_platform.a, next to platform_macos.m.

#import <Cocoa/Cocoa.h>

typedef struct {
    void (*fire)(int tag);
    int (*state)(int tag);                       // bit 0 enabled, bit 1 checked
    int (*title)(int tag, char* buf, int cap);   // the current title's length (dynamic items)
} dh_menu_callbacks;

enum { DH_NATIVE_NONE, DH_ABOUT, DH_HIDE, DH_HIDE_OTHERS, DH_SHOW_ALL, DH_MINIMIZE, DH_ZOOM, DH_FULL_SCREEN, DH_FRONT };

static dh_menu_callbacks menu_cb;
static NSView* menu_view;
static NSMutableArray<NSMenu*>* stack; // the menu being filled, innermost last
static NSEvent* test_event;            // test mode: the event a test key press stands for
static int test_key_window = -1;       // test mode: 1/0 = our window is / is not the key window
static NSMutableSet<NSNumber*>* dynamic_tags;

static NSEvent* current_event(void) { return test_event ?: NSApp.currentEvent; }

// Our window has the keyboard (not the About panel or another app's sheet).
static BOOL window_is_key(void) {
    return test_key_window >= 0 ? test_key_window == 1 : menu_view.window.isKeyWindow;
}

// A key press with ⌘ or ⌃: AppKit is matching key equivalents (not a click,
// nor Enter in an open menu).
static BOOL by_key(void) {
    NSEvent* e = current_event();
    return e.type == NSEventTypeKeyDown && (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
}

@interface PdMenuTarget : NSObject <NSMenuItemValidation>
@end

@implementation PdMenuTarget
- (void)fire:(NSMenuItem*)item {
    if (by_key()) {
        // the key keeps its own handling: on to the view, as without a menu;
        // never while another window has the keyboard (validateMenuItem)
        if (window_is_key()) [menu_view keyDown:current_event()];
        return;
    }
    if (menu_cb.fire) menu_cb.fire((int)item.tag);
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (!menu_cb.state) return YES;
    if ([dynamic_tags containsObject:@(item.tag)] && menu_cb.title) {
        char buf[256];
        int n = menu_cb.title((int)item.tag, buf, sizeof buf);
        if (n > 0 && n < (int)sizeof buf) {
            NSString* t = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
            if (t && ![t isEqualToString:item.title]) item.title = t;
        }
    }
    int s = menu_cb.state((int)item.tag);
    item.state = (s & 2) ? NSControlStateValueOn : NSControlStateValueOff;
    // a key equivalent always goes on (fire:), so the key works as before
    // even where the item shows disabled; while another window (the About
    // panel) has the keyboard, our items take no keys
    if (by_key()) return window_is_key();
    return (s & 1) != 0;
}
@end

static PdMenuTarget* target;

void dh_mac_menu_begin(void* window, const dh_menu_callbacks* cb) {
    menu_cb = *cb;
    menu_view = ((__bridge NSWindow*)window).contentView;
    target = target ?: [PdMenuTarget new];
    dynamic_tags = [NSMutableSet new];
    stack = [NSMutableArray arrayWithObject:[[NSMenu alloc] initWithTitle:@"Main"]];
    // no "Show Tab Bar" / "Show All Tabs" in View: Deckhand has its own tabs
    NSWindow.allowsAutomaticWindowTabbing = NO;
}

static NSString* str(const char* s) { return [NSString stringWithUTF8String:s ?: ""] ?: @""; }

// A submenu of the menu being filled (at the top: a menu in the bar).
void dh_mac_menu_push(const char* title) {
    NSString* t = str(title);
    NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:t action:nil keyEquivalent:@""];
    NSMenu* m = [[NSMenu alloc] initWithTitle:t];
    it.submenu = m;
    [stack.lastObject addItem:it];
    [stack addObject:m];
}

void dh_mac_menu_pop(void) {
    if (stack.count > 1) [stack removeLastObject];
}

void dh_mac_menu_separator(void) { [stack.lastObject addItem:[NSMenuItem separatorItem]]; }

// key: the key equivalent's character ("" = none); mods: NSEventModifierFlags.
void dh_mac_menu_item(const char* title, const char* key, unsigned long mods, int tag, int native, int dynamic) {
    SEL sel = @selector(fire:);
    id tgt = target;
    switch (native) {
    case DH_ABOUT:       sel = @selector(orderFrontStandardAboutPanel:); tgt = NSApp; break;
    case DH_HIDE:        sel = @selector(hide:); tgt = NSApp; break;
    case DH_HIDE_OTHERS: sel = @selector(hideOtherApplications:); tgt = NSApp; break;
    case DH_SHOW_ALL:    sel = @selector(unhideAllApplications:); tgt = NSApp; break;
    case DH_MINIMIZE:    sel = @selector(performMiniaturize:); tgt = nil; break;
    case DH_ZOOM:        sel = @selector(performZoom:); tgt = nil; break;
    case DH_FULL_SCREEN: sel = @selector(toggleFullScreen:); tgt = nil; break;
    case DH_FRONT:       sel = @selector(arrangeInFront:); tgt = NSApp; break;
    }
    NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:str(title) action:sel keyEquivalent:str(key)];
    it.keyEquivalentModifierMask = (NSEventModifierFlags)mods;
    it.target = tgt;
    it.tag = tag;
    if (dynamic) [dynamic_tags addObject:@(tag)];
    [stack.lastObject addItem:it];
}

void dh_mac_menu_end(void) {
    NSMenu* bar = stack.firstObject;
    for (NSMenuItem* top in bar.itemArray) {
        if ([top.title isEqualToString:@"Window"]) NSApp.windowsMenu = top.submenu; // AppKit adds the window list
        if ([top.title isEqualToString:@"Help"]) NSApp.helpMenu = top.submenu;      // and the help search field
    }
    NSApp.mainMenu = bar;
    stack = nil;
}

// ---- test mode (in-process; never posted to the system) ----

// A key press as AppKit handles it: the menu bar's key equivalents first,
// else the view's keyDown:, then the key's release. Returns 1 if the menu
// bar took it (and passed it on, fire:), 0 if it went straight to the view.
// key_window: 0 = as if another window (the About panel) had the keyboard:
// a key the menu bar does not take goes to that window, not our view.
int dh_mac_test_menu_key(const char* chars, unsigned long mods, int key_code, int key_window) {
    NSString* s = str(chars);
    NSEvent* down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:(NSEventModifierFlags)mods
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:menu_view.window.windowNumber context:nil
        characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:(unsigned short)key_code];
    NSEvent* up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:(NSEventModifierFlags)mods
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:menu_view.window.windowNumber context:nil
        characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:(unsigned short)key_code];
    test_event = down;
    test_key_window = key_window ? 1 : 0;
    BOOL took = [NSApp.mainMenu performKeyEquivalent:down];
    test_event = nil;
    test_key_window = -1;
    if (!key_window) return took ? 1 : 0;
    if (!took) [menu_view keyDown:down];
    [menu_view keyUp:up];
    return took ? 1 : 0;
}

static void dump(NSMenu* m, NSMutableString* out, int depth) {
    [m update]; // validates the items, as opening the menu does
    for (NSMenuItem* it in m.itemArray) {
        for (int i = 0; i < depth; i++) [out appendString:@"  "];
        if (it.isSeparatorItem) {
            [out appendString:@"----\n"];
            continue;
        }
        NSMutableString* key = [NSMutableString string];
        NSEventModifierFlags f = it.keyEquivalentModifierMask;
        if (it.keyEquivalent.length > 0) {
            if (f & NSEventModifierFlagControl) [key appendString:@"⌃"];
            if (f & NSEventModifierFlagOption) [key appendString:@"⌥"];
            if (f & NSEventModifierFlagShift) [key appendString:@"⇧"];
            if (f & NSEventModifierFlagCommand) [key appendString:@"⌘"];
            unichar c = [it.keyEquivalent characterAtIndex:0];
            switch (c) {
            case NSUpArrowFunctionKey: [key appendString:@"↑"]; break;
            case NSDownArrowFunctionKey: [key appendString:@"↓"]; break;
            case '\r': [key appendString:@"↩"]; break;
            default: [key appendString:it.keyEquivalent.uppercaseString];
            }
        }
        [out appendFormat:@"%@%@%@%@%@\n", it.state == NSControlStateValueOn ? @"✓ " : @"", it.title,
            key.length ? @"  " : @"", key, it.submenu || it.isEnabled ? @"" : @"  (disabled)"];
        if (it.submenu) dump(it.submenu, out, depth + 1);
    }
}

// The menu bar as text (titles, keys, checkmarks, disabled items), validated
// now. Copies it into buf; returns its length (0 if it does not fit).
int dh_mac_menu_dump(char* buf, int cap) {
    NSMutableString* out = [NSMutableString string];
    dump(NSApp.mainMenu, out, 0);
    const char* u = out.UTF8String;
    int n = (int)strlen(u);
    if (n >= cap) return 0;
    memcpy(buf, u, (size_t)n + 1);
    return n;
}
