// macOS pieces for the editor and the file-system model (src/editor_watch.odin,
// src/core/fs_model.odin): an FSEvents stream over the watched folders (file
// events, ~50 ms latency, delivered on a private serial queue), moving to
// the Trash, and revealing in Finder.

#import <Cocoa/Cocoa.h>
#include <CoreServices/CoreServices.h>

typedef void (*dh_fsw_cb)(const char *path, unsigned flags);

static FSEventStreamRef stream;
static dispatch_queue_t queue;
static dh_fsw_cb callback;

static void on_events(ConstFSEventStreamRef s, void *info, size_t n, void *paths, const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
	char **p = (char **)paths;
	for (size_t i = 0; i < n; i++) callback(p[i], (unsigned)flags[i]);
}

// Replaces the watched folders (n == 0 stops watching).
void dh_fsw_set(const char **paths, int n, dh_fsw_cb cb) {
	if (stream) {
		FSEventStreamStop(stream);
		FSEventStreamInvalidate(stream);
		FSEventStreamRelease(stream);
		stream = NULL;
	}
	if (n == 0) return;
	if (!queue) queue = dispatch_queue_create("deckhand.fswatch", DISPATCH_QUEUE_SERIAL);
	callback = cb;
	CFMutableArrayRef list = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
	for (int i = 0; i < n; i++) {
		CFStringRef s = CFStringCreateWithCString(NULL, paths[i], kCFStringEncodingUTF8);
		if (s) {
			CFArrayAppendValue(list, s);
			CFRelease(s);
		}
	}
	stream = FSEventStreamCreate(NULL, on_events, NULL, list, kFSEventStreamEventIdSinceNow, 0.05,
		kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot);
	CFRelease(list);
	if (!stream) return;
	FSEventStreamSetDispatchQueue(stream, queue);
	FSEventStreamStart(stream);
}

// Moves path to the Trash. 0 on success.
int dh_trash(const char *path) {
	@autoreleasepool {
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		NSError *err = nil;
		BOOL ok = [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:&err];
		return ok ? 0 : 1;
	}
}

// Shows path selected in a Finder window.
void dh_reveal(const char *path) {
	@autoreleasepool {
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ url ]];
	}
}
