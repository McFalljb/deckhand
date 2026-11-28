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

// Replaces the watched folders (n == 0 stops watching). 0: watching (or stopped); 1: the stream
// could not be made, 2: it could not be started.
int dh_fsw_set(const char **paths, int n, dh_fsw_cb cb) {
	if (stream) {
		FSEventStreamStop(stream);
		FSEventStreamInvalidate(stream);
		FSEventStreamRelease(stream);
		stream = NULL;
	}
	if (n == 0) return 0;
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
	if (!stream) return 1;
	FSEventStreamSetDispatchQueue(stream, queue);
	if (!FSEventStreamStart(stream)) {
		FSEventStreamInvalidate(stream);
		FSEventStreamRelease(stream);
		stream = NULL;
		return 2;
	}
	return 0;
}

// Moves path to the Trash. 0 on success. where (where_len bytes, NUL-terminated) gets the path
// the Trash put it at ("" when it did not say or it does not fit): restore_path brings it back.
int dh_trash(const char *path, char *where, int where_len) {
	@autoreleasepool {
		if (where && where_len > 0) where[0] = 0;
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		NSError *err = nil;
		NSURL *put = nil;
		BOOL ok = [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:&put error:&err];
		if (!ok) return 1;
		const char *p = put.isFileURL ? put.fileSystemRepresentation : NULL;
		if (where && p && (int)strlen(p) < where_len) memcpy(where, p, strlen(p) + 1);
		return 0;
	}
}

// Shows path selected in a Finder window.
void dh_reveal(const char *path) {
	@autoreleasepool {
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ url ]];
	}
}
