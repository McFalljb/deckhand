// Test hook for dragout_macos.m: the pasteboard items a Files drag out of the window carries,
// as AppKit reads them back. Its own member of build/dh_dragout.a, called only under
// `when core.TEST_HOOKS` (src/files_drag_out_darwin.odin): a release build never links it.

#import <Cocoa/Cocoa.h>

NSArray<NSPasteboardItem*>* dh_drag_out_items(const char** paths, int n, const char* text);

// The items written to a pasteboard of their own and read back: one line per item,
// "<file URL>\t<text>\n" (text "" when the item has none). The bytes written (cap at most);
// -1: no pasteboard.
int dh_drag_out_test_items(const char** paths, int n, const char* text, char* out, int cap) {
    NSPasteboard* pb = [NSPasteboard pasteboardWithUniqueName];
    if (!pb) return -1;
    [pb clearContents];
    if (![pb writeObjects:dh_drag_out_items(paths, n, text)]) {
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
