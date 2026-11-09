// CEF inside Deckhand (docs/BROWSER.md §1): a thin shim over CEF's C API
// (include/capi), compiled against the pinned distribution's headers so every
// struct layout is checked by the compiler, not hand-copied. Odin calls the
// flat dh_cef_* functions below (src/browser_cef.odin); nothing of CEF's
// types crosses into Odin.
//
//  - The framework is loaded lazily with dlopen on the first browser tab
//    (dh_cef_start), so Deckhand's own launch never maps 240 MB of Chromium.
//  - Message loop: external pump (settings.external_message_pump). CEF's
//    on_schedule_message_pump_work arms one main-queue GCD timer that runs
//    cef_do_message_loop_work; after each pump the timer is re-armed at most
//    33 ms out while a browser is visible or loading, 1 s otherwise. Never
//    re-entrant. The frame loop also runs a pump that is overdue
//    (dh_cef_pump_due): while every frame is drawn, each blocks in
//    nextDrawable and the main queue can wait seconds for its turn.
//  - Rendering: windowless (OSR) into the tab's frame ring, the one app tabs
//    use (src/native/frames_macos.m, local channel; docs/BROWSER.md §1.1):
//    each paint takes a slot Deckhand does not sample (dh_frames_local_acquire),
//    fills it, and hands it over (dh_frames_local_frame); the frame loop shows
//    it and gives the slot back only after the GPU frame that last drew it
//    completed. So a paint never writes the texture on screen. With shared
//    textures on, on_accelerated_paint's IOSurface is wrapped as an
//    MTLTexture and blitted into the slot (sokol's Metal device, our own
//    queue, waited on: CEF takes the surface back when the callback
//    returns). Otherwise on_paint's BGRA buffer is copied into the slot's
//    IOSurface whole (a slot may hold an older frame: dirty rects are not
//    enough). A paint goes to the slot's top-left; a paint larger than the
//    ring asks Deckhand for a bigger one (callbacks.ring): made at once, or
//    (during a drag) a little later by the frame loop, which then
//    invalidates the view. A paint with no free slot is dropped and the
//    view invalidated a frame later, so the last paint is never lost.
//  - NSApp: Chromium wants CrAppControlProtocol (isHandlingSendEvent,
//    setHandlingSendEvent:). sokol makes a plain NSApplication, so the methods
//    and the protocol are added at run time and sendEvent: sets the flag.
//
//  - Navigation (step 2): the main frame's address, the back/forward state
//    and loading go to Deckhand (callbacks.address, callbacks.nav);
//    dh_cef_navigate / dh_cef_history drive it. Popups (target=_blank,
//    window.open, ⌘-click) become new windowless browsers in deckhand tabs of
//    the opener's session (callbacks.popup decides and makes the tab; a
//    slot is reserved before CEF creates the browser and taken in
//    on_after_created), so window.opener keeps working.
//  - Test mode: deckhand-test://web/NAME serves tests/web/NAME (a scheme
//    handler; no network), dh_cef_test_scheme.
//
// SPIKE (step 1): fixed slots, no context menus, no IME, no
// DevTools window (the protocol, in process: the last section); the key
// translation (dh_cef_key) gets the macOS key code from the Odin side's
// table rather than the NSEvent.
//
// Built by build.sh into build/dh_cef.a unless DECKHAND_NO_CEF=1.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <IOSurface/IOSurfaceRef.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_devtools_message_observer_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_keyboard_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_registration_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_resource_handler_capi.h"
#include "include/capi/cef_response_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "cef_popup_slots.h"
#include "include/internal/cef_string.h"

// the frame ring's in-process producer (src/native/frames_macos.m)
int dh_frames_local_acquire(uint64_t tab_id, int w, int h, uint32_t* gen, int* slot, void** texture, IOSurfaceRef* surface);
void dh_frames_local_unacquire(uint64_t tab_id, uint32_t gen, int slot);
int dh_frames_local_frame(uint64_t tab_id, uint32_t gen, int slot, uint64_t seq, int w, int h);

typedef struct {
    void (*painted)(int id, int width, int height, int accelerated, void* written); // a new frame is in written (an id<MTLTexture>, a ring slot)
    int (*ring)(uint64_t tab_id, int width, int height); // no ring fits a w x h px paint: make one now (1 = made; 0: later, with dh_cef_invalidate)
    void (*title)(int id, const char* utf8);
    void (*loading)(int id, int loading);
    void (*closed)(int id);
    void (*log)(const char* utf8);
    // step 2 (navigation): the main frame's URL; loading and history; a popup
    // the page asks for (slot: the browser id it will have; 0 = refused, else
    // the Deckhand tab made for it)
    void (*address)(int id, const char* utf8);
    void (*nav)(int id, int loading, int can_back, int can_forward);
    uint64_t (*popup)(int opener, int slot, const char* url, int user_gesture, int background);
} dh_cef_callbacks;

// ---- the framework's entry points (dlsym'd; prototypes from the headers) ----

#define CEF_FNS(X)                         \
    X(cef_api_hash)                        \
    X(cef_initialize)                      \
    X(cef_shutdown)                        \
    X(cef_do_message_loop_work)            \
    X(cef_browser_host_create_browser_sync) \
    X(cef_string_utf8_to_utf16)            \
    X(cef_string_utf16_to_utf8)            \
    X(cef_string_utf16_clear)              \
    X(cef_string_utf8_clear)               \
    X(cef_string_userfree_utf16_free)      \
    X(cef_register_scheme_handler_factory)
#define DECL(name) static __typeof__(name)* p_##name;
CEF_FNS(DECL)

static void* framework;
static int started; // 1 running, -1 failed to start (never retried)
static int shutting_down;
static dh_cef_callbacks cb;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static int shared_textures;

static void say(NSString* s) {
    if (cb.log) cb.log(s.UTF8String);
    else fprintf(stderr, "Deckhand cef: %s\n", s.UTF8String);
}

static cef_string_t str16(const char* s) {
    cef_string_t out = {0};
    if (s) p_cef_string_utf8_to_utf16(s, strlen(s), &out);
    return out;
}

// ---- browsers ----

#define MAX_BROWSERS 8
typedef struct {
    cef_browser_t* browser; // our reference (released in on_before_close)
    int cef_id;
    int w, h; // view size, logical px
    float scale;
    int hidden;
    int loading;
    int closing;
    int pending; // a popup's slot, reserved until on_after_created brings its browser (2: its tab closed meanwhile)
    int opener_cef, popup_id; // a reservation's opener (CEF browser id) and on_before_popup's popup_id
    unsigned long long res_seq; // reservation order
    uint64_t tab_id; // its frame ring's channel (Deckhand's tab id; 0 once closed)
    uint64_t seq; // frames handed over
    uint64_t dropped; // paints with no slot to go into
    int retry; // an invalidate is due (a paint was dropped)
    int fails; // paints in a row whose copy into the slot failed
    uint64_t paints_gpu, paints_cpu;
    double created_at, first_paint_at; // seconds (mach)
} Slot;
static Slot slots[MAX_BROWSERS + 1]; // index 0 unused: ids are 1..MAX
static int creating; // slot being created (create_browser_sync calls back before it returns)

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static int slot_of(cef_browser_t* b) {
    int id = b->get_identifier(b);
    for (int i = 1; i <= MAX_BROWSERS; i++)
        if (slots[i].browser && slots[i].cef_id == id) return i;
    return creating; // during create_browser_sync, before we hold the browser
}

static cef_browser_host_t* host_of(int i) {
    if (i < 1 || i > MAX_BROWSERS || !slots[i].browser || slots[i].closing) return NULL;
    return slots[i].browser->get_host(slots[i].browser); // caller releases
}
#define RELEASE(p) ((cef_base_ref_counted_t*)(p))->release((cef_base_ref_counted_t*)(p))

// Long-lived handler structs: static storage, so their ref counts are no-ops.
static void CEF_CALLBACK ref_add(cef_base_ref_counted_t* self) {}
static int CEF_CALLBACK ref_release(cef_base_ref_counted_t* self) { return 0; }
static int CEF_CALLBACK ref_one(cef_base_ref_counted_t* self) { return 1; }
#define INIT_BASE(obj)                                       \
    do {                                                     \
        memset(&(obj), 0, sizeof(obj));                      \
        (obj).base.size = sizeof(obj);                       \
        (obj).base.add_ref = ref_add;                        \
        (obj).base.release = ref_release;                    \
        (obj).base.has_one_ref = ref_one;                    \
        (obj).base.has_at_least_one_ref = ref_one;           \
    } while (0)

// ---- the pump ----

static dispatch_source_t pump_timer;
static int pumping;
static double last_activity; // input, a paint, a navigation: the fast pulse runs 1 s after it
static void touch(void) { last_activity = now_s(); }
// The fast pulse (33 ms) while a page loads or just had input or a paint;
// otherwise 1 s and Chromium's own hints (on_schedule_message_pump_work).
static int any_open(void) {
    for (int i = 1; i <= MAX_BROWSERS; i++)
        if (slots[i].browser || slots[i].closing || slots[i].pending) return 1;
    return 0;
}
static int any_active(void) {
    for (int i = 1; i <= MAX_BROWSERS; i++) {
        if (!slots[i].browser) continue;
        if (slots[i].loading) return 1;
        if (!slots[i].hidden && now_s() - last_activity < 1.0) return 1;
    }
    return 0;
}
static uint64_t pumps;

static double due_at; // when the armed pump is due (0: none): dh_cef_pump_due
static void arm(int64_t delay_ms) {
    if (delay_ms < 0) delay_ms = 0;
    due_at = now_s() + delay_ms / 1000.0;
    dispatch_source_set_timer(pump_timer, dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
                              DISPATCH_TIME_FOREVER, 2 * NSEC_PER_MSEC);
}

static int64_t asked_ms = -1; // work Chromium asked for while we were pumping

static void pump(void) {
    if (started != 1 || pumping) return;
    due_at = 0;
    pumping = 1;
    asked_ms = -1;
    pumps++;
    p_cef_do_message_loop_work();
    pumping = 0;
    // the hints are incomplete: keep a pulse (BROWSER.md §1.3), sooner if
    // asked; with no browser left only Chromium's own requests wake us
    int64_t next = any_open() ? (any_active() ? 33 : 1000) : -1;
    if (asked_ms >= 0 && (next < 0 || asked_ms < next)) next = asked_ms;
    if (next >= 0) arm(next);
    else {
        due_at = 0;
        dispatch_source_set_timer(pump_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    }
}

static void schedule(int64_t delay_ms) {
    if (pumping) {
        if (asked_ms < 0 || delay_ms < asked_ms) asked_ms = delay_ms;
        return;
    }
    arm(delay_ms);
}

static void CEF_CALLBACK on_schedule_work(cef_browser_process_handler_t* self, int64_t delay_ms) {
    if (delay_ms > 1000) delay_ms = 1000;
    if (delay_ms < 0) delay_ms = 0;
    if ([NSThread isMainThread]) {
        schedule(delay_ms);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ schedule(delay_ms); });
}

// ---- app, browser process handler ----

static cef_app_t app;
static cef_browser_process_handler_t bph;
static cef_client_t client;
static cef_render_handler_t render;
static cef_life_span_handler_t life;
static cef_load_handler_t load;
static cef_display_handler_t display;
static cef_keyboard_handler_t keyboard;

static void add_switch(cef_command_line_t* cl, const char* name) {
    cef_string_t s = str16(name);
    cl->append_switch(cl, &s);
    p_cef_string_utf16_clear(&s);
}

static void add_switch_value(cef_command_line_t* cl, const char* name, const char* value) {
    cef_string_t n = str16(name), v = str16(value);
    cl->append_switch_with_value(cl, &n, &v);
    p_cef_string_utf16_clear(&n);
    p_cef_string_utf16_clear(&v);
}

// Adds features to --disable-features, keeping any already there.
static void disable_features(cef_command_line_t* cl, const char* features) {
    cef_string_t n = str16("disable-features");
    char merged[1024];
    snprintf(merged, sizeof merged, "%s", features);
    cef_string_userfree_t had = cl->has_switch(cl, &n) ? cl->get_switch_value(cl, &n) : NULL;
    if (had) {
        cef_string_utf8_t u = {0};
        p_cef_string_utf16_to_utf8(had->str, had->length, &u);
        if (u.str && u.str[0]) snprintf(merged, sizeof merged, "%s,%s", u.str, features);
        say([NSString stringWithFormat:@"--disable-features was %s", u.str ? u.str : ""]);
        p_cef_string_utf8_clear(&u);
        p_cef_string_userfree_utf16_free(had);
    }
    p_cef_string_utf16_clear(&n);
    add_switch_value(cl, "disable-features", merged);
}

static int offline; // dh_cef_start: no network at all (test mode)

// Chromium features that phone home, off (network policy, BROWSER.md).
// Unknown names are ignored by Chromium: tests/scripts/browser-netpolicy.sh
// checks what is still tried.
#define DH_CEF_DISABLED_FEATURES                                                          \
    "NetworkTimeServiceQuerying,"                    /* clients2.google.com/time */      \
    "OptimizationHints,OptimizationHintsFetching,OptimizationGuideModelDownloading,"     \
    "OptimizationTargetPrediction,OptimizationGuideOnDeviceModel,"                       \
    "Translate,TranslateUI,"                                                             \
    "AutofillServerCommunication,"                                                       \
    "MediaRouter,DialMediaRouteProvider,CastMediaRouteProvider,GlobalMediaControls,"     \
    "CertificateTransparencyComponentUpdater,"                                           \
    "InterestFeedContentSuggestions,SegmentationPlatformFeature,"                        \
    "PushMessaging,GCMUseDedicatedNetworkThread,"                                        \
    "UseDnsHttpsSvcbAlpn,"                                                               \
    "AIModeOmniboxEntryPoint,AiModeOmniboxEntryPoint,LensOverlay,LensStandalone,"         \
    "AimServerEligibility,AimEligibilityService,AimEnabled,"     /* www.google.com/async/folae */ \
    "PreconnectToSearch,"                                        /* google.com preconnect */ \
    "OnDeviceModelBackgroundDownload,IwaPolicyManagerOnDemandComponentUpdate" /* update.googleapis.com */

static void CEF_CALLBACK on_before_cmdline(cef_app_t* self, const cef_string_t* process_type, cef_command_line_t* cl) {
    // the browser process only (process_type empty): helpers get these passed on
    if (process_type && process_type->length > 0) return;
    // Cookies: never the login Keychain ("Chromium Safe Storage", which would
    // prompt): a fixed key, so the profile is protected by its file
    // permissions (0700, browser.odin) alone.
    add_switch(cl, "use-mock-keychain");
    add_switch(cl, "no-first-run");
    add_switch(cl, "no-default-browser-check");
    // Network policy (BROWSER.md "Network policy"):
    // Safe Browsing stays; what else phones home is off. Not
    // --disable-background-networking: it stops Safe Browsing updates too.
    add_switch(cl, "disable-sync");
    add_switch(cl, "disable-component-update");
    // the update client still checks (on-demand components): to a dead loopback port
    add_switch_value(cl, "component-updater", "url-source=http://127.0.0.1:9/");
    add_switch(cl, "disable-domain-reliability");
    add_switch(cl, "disable-default-apps");
    add_switch(cl, "disable-breakpad");
    add_switch(cl, "metrics-recording-only"); // UMA: recorded locally, never uploaded
    add_switch(cl, "no-pings");                // <a ping> hyperlink auditing
    // Web notifications stay (the user allows the prompt); web push is off
    // (PushMessaging below), since it needs GCM.
    // no warm spare renderer kept for the next navigation (~70-85 MB RSS);
    // DECKHAND_CEF_SPARE=1 keeps Chromium's default (the spike measured both)
#ifndef DH_RELEASE // test and development knobs: not in a release build (src/core/test_hooks.odin)
    const char* spare = getenv("DECKHAND_CEF_SPARE");
    if (!spare || strcmp(spare, "1") != 0)
#endif
        disable_features(cl, "SpareRendererForSitePerProcess");
    disable_features(cl, DH_CEF_DISABLED_FEATURES);
#ifndef DH_RELEASE
    // tests/scripts/browser-netpolicy.sh: Chromium's own log of what it tries to reach
    const char* netlog = getenv("DECKHAND_CEF_NETLOG");
    if (netlog && netlog[0]) add_switch_value(cl, "log-net-log", netlog);
#endif
    if (offline) {
        // Test mode: Chromium's own background services (Safe Browsing, GCM,
        // component and model downloads) reach Google even with the switches
        // above. No name resolves, every connection goes to a dead proxy
        // (IP literals too), no QUIC: pages come from file:// only.
        add_switch_value(cl, "host-resolver-rules", "MAP * ~NOTFOUND");
        add_switch_value(cl, "proxy-server", "http://127.0.0.1:9");
        add_switch_value(cl, "proxy-bypass-list", "<-loopback>");
        add_switch(cl, "disable-quic");
    } else {
        // RLZ's ping host (also held off by rlz_ping_delay, browser.odin):
        // belt and braces: RLZ's store is Deckhand's own (framework_search_path),
        // and a ping could carry whatever it holds
        add_switch_value(cl, "host-resolver-rules", "MAP clients1.google.com ~NOTFOUND");
    }
}

static cef_browser_process_handler_t* CEF_CALLBACK get_bph(cef_app_t* self) { return &bph; }

// ---- client handlers ----

static void CEF_CALLBACK get_view_rect(cef_render_handler_t* self, cef_browser_t* b, cef_rect_t* r) {
    int i = slot_of(b);
    r->x = r->y = 0;
    r->width = i ? (slots[i].w > 0 ? slots[i].w : 1) : 800;
    r->height = i ? (slots[i].h > 0 ? slots[i].h : 1) : 600;
    RELEASE(b);
}

static int CEF_CALLBACK get_screen_info(cef_render_handler_t* self, cef_browser_t* b, cef_screen_info_t* si) {
    int i = slot_of(b);
    si->device_scale_factor = i ? slots[i].scale : 2;
    si->depth = 24;
    si->depth_per_component = 8;
    si->rect = (cef_rect_t){0, 0, i ? slots[i].w : 800, i ? slots[i].h : 600};
    si->available_rect = si->rect;
    RELEASE(b);
    return 1;
}

// A paint went nowhere (every slot Deckhand's, or its copy failed): ask for it again a frame
// later, once (Chromium paints only what changed: a dropped last paint would
// leave the old frame on screen).
static void dropped(int i) {
    Slot* s = &slots[i];
    s->dropped++;
    if (s->retry) return;
    s->retry = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        s->retry = 0;
        cef_browser_host_t* hst = host_of(i);
        if (!hst) return;
        if (!s->hidden) hst->invalidate(hst, PET_VIEW);
        RELEASE(hst);
        arm(0);
    });
}

// A ring slot for a w x h px paint, or 0 (dropped).
static int acquire(int i, int w, int h, uint32_t* gen, int* slot, id<MTLTexture>* tex, IOSurfaceRef* surf) {
    Slot* s = &slots[i];
    if (!s->tab_id) return 0; // closing
    void* t = NULL;
    int r = dh_frames_local_acquire(s->tab_id, w, h, gen, slot, &t, surf);
    if (r == 0 && cb.ring && cb.ring(s->tab_id, w, h)) r = dh_frames_local_acquire(s->tab_id, w, h, gen, slot, &t, surf);
    if (r != 1) {
        if (r == -1) dropped(i); // every slot Deckhand's: free again within a frame or two
        else if (r == 0) s->dropped++; // no ring fits yet: Deckhand makes one and invalidates (dh_cef_invalidate)
        return 0;
    }
    *tex = (__bridge id<MTLTexture>)t;
    return 1;
}

// The copy into an acquired slot failed: the slot is free again and the
// paint is asked for again (its slot may have held the newest frame, now
// dropped), up to 3 times in a row: a failure that stays would spin.
static void copy_failed(int i, uint32_t gen, int k) {
    dh_frames_local_unacquire(slots[i].tab_id, gen, k);
    if (slots[i].fails++ < 3) dropped(i);
    else slots[i].dropped++;
}

static void painted(int i, int w, int h, int gpu, id<MTLTexture> written_tex) {
    Slot* s = &slots[i];
    s->fails = 0;
    void* written = (__bridge void*)written_tex;
    if (gpu) s->paints_gpu++;
    else s->paints_cpu++;
    if (s->first_paint_at == 0) s->first_paint_at = now_s();
    touch();
    if (cb.painted) cb.painted(i, w, h, gpu, written);
}

static void CEF_CALLBACK on_paint(cef_render_handler_t* self, cef_browser_t* b, cef_paint_element_type_t type,
                                  size_t ndirty, const cef_rect_t* dirty, const void* buffer, int w, int h) {
    int i = slot_of(b);
    RELEASE(b);
    if (!i || type != PET_VIEW || w <= 0 || h <= 0) return;
    uint32_t gen;
    int k;
    id<MTLTexture> t;
    IOSurfaceRef surf;
    if (!acquire(i, w, h, &gen, &k, &t, &surf)) return;
    // the whole frame: the slot may hold one from several paints ago
    if (IOSurfaceLock(surf, 0, NULL) != kIOReturnSuccess) {
        copy_failed(i, gen, k);
        return;
    }
    uint8_t* base = IOSurfaceGetBaseAddress(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    for (int y = 0; y < h; y++) memcpy(base + (size_t)y * bpr, (const uint8_t*)buffer + (size_t)y * w * 4, (size_t)w * 4);
    IOSurfaceUnlock(surf, 0, NULL);
    dh_frames_local_frame(slots[i].tab_id, gen, k, ++slots[i].seq, w, h);
    painted(i, w, h, 0, t);
}

static void CEF_CALLBACK on_accelerated_paint(cef_render_handler_t* self, cef_browser_t* b, cef_paint_element_type_t type,
                                              size_t ndirty, const cef_rect_t* dirty, const cef_accelerated_paint_info_t* info) {
    int i = slot_of(b);
    RELEASE(b);
    if (!i || type != PET_VIEW || !info || !info->shared_texture_io_surface) return;
    IOSurfaceRef surf = (IOSurfaceRef)info->shared_texture_io_surface;
    int w = (int)IOSurfaceGetWidth(surf), h = (int)IOSurfaceGetHeight(surf);
    if (w <= 0 || h <= 0) return;
    if (info->format != CEF_COLOR_TYPE_BGRA_8888) {
        static int warned;
        if (!warned++) say([NSString stringWithFormat:@"shared texture format %d (not BGRA): skipped", info->format]);
        return;
    }
    uint32_t gen;
    int k;
    id<MTLTexture> dst;
    IOSurfaceRef dst_surf;
    int ok = 0;
    if (!acquire(i, w, h, &gen, &k, &dst, &dst_surf)) return;
    @autoreleasepool {
        MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> src = [device newTextureWithDescriptor:d iosurface:surf plane:0];
        id<MTLCommandBuffer> cmd = src ? [queue commandBuffer] : nil;
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (blit) {
            [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1) toTexture:dst destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            [cmd commit];
            // CEF's surface goes back to its pool when we return (cef_types_mac.h,
            // cef_accelerated_paint_info_t): the copy must be done by then. Done,
            // the slot holds the whole frame and is handed over.
            [cmd waitUntilCompleted];
            ok = cmd.status == MTLCommandBufferStatusCompleted;
        }
    }
    if (!ok) {
        copy_failed(i, gen, k);
        return;
    }
    dh_frames_local_frame(slots[i].tab_id, gen, k, ++slots[i].seq, w, h);
    painted(i, w, h, 1, dst);
}

static cef_render_handler_t* CEF_CALLBACK get_render(cef_client_t* self) { return &render; }
static cef_life_span_handler_t* CEF_CALLBACK get_life(cef_client_t* self) { return &life; }
static cef_load_handler_t* CEF_CALLBACK get_load(cef_client_t* self) { return &load; }
static cef_display_handler_t* CEF_CALLBACK get_display(cef_client_t* self) { return &display; }
static cef_keyboard_handler_t* CEF_CALLBACK get_keyboard(cef_client_t* self) { return &keyboard; }

// A key the page did not handle stops here. Else CEF offers it to the menu
// bar (performKeyEquivalent: with an NSEvent of its own), where AppKit's
// hidden Edit items take a plain key: e opened Emoji & Symbols (fn E), d
// started dictation (fn D). Deckhand's own shortcuts are ⌘ keys and never
// reach the page (browser_event); a ⌘ key that does still goes on.
static int CEF_CALLBACK on_key_event(cef_keyboard_handler_t* self, cef_browser_t* b, const cef_key_event_t* e, cef_event_handle_t os) {
    return (e->modifiers & EVENTFLAG_COMMAND_DOWN) == 0;
}

static void devtools_forget(int i); // the DevTools section below
static void polish_install(void); // step 3 (cef_polish.inc, the end of this file)

static void CEF_CALLBACK on_before_close(cef_life_span_handler_t* self, cef_browser_t* b) {
    int i = slot_of(b);
    RELEASE(b);
    if (!i) return;
    devtools_forget(i);
    RELEASE(slots[i].browser);
    slots[i] = (Slot){0}; // free again (closing cleared): dh_cef_open may reuse it
    if (cb.closed) cb.closed(i);
}

static void CEF_CALLBACK on_loading_state(cef_load_handler_t* self, cef_browser_t* b, int loading, int back, int fwd) {
    int i = slot_of(b);
    RELEASE(b);
    if (!i) return;
    slots[i].loading = loading;
    if (cb.loading) cb.loading(i, loading);
    if (cb.nav) cb.nav(i, loading, back, fwd);
}

static void CEF_CALLBACK on_title(cef_display_handler_t* self, cef_browser_t* b, const cef_string_t* title) {
    int i = slot_of(b);
    RELEASE(b);
    if (!i || !cb.title) return;
    cef_string_utf8_t u = {0};
    if (title) p_cef_string_utf16_to_utf8(title->str, title->length, &u);
    cb.title(i, u.str ? u.str : "");
    p_cef_string_utf8_clear(&u);
}

static char* utf8_of(const cef_string_t* s) {
    cef_string_utf8_t u = {0};
    if (s) p_cef_string_utf16_to_utf8(s->str, s->length, &u);
    char* out = strdup(u.str ? u.str : "");
    p_cef_string_utf8_clear(&u);
    return out;
}

// The main frame's URL (a link, a redirect, back/forward, pushState).
static void CEF_CALLBACK on_address(cef_display_handler_t* self, cef_browser_t* b, cef_frame_t* f, const cef_string_t* url) {
    int i = slot_of(b);
    RELEASE(b);
    int main = f && f->is_main(f);
    if (f) RELEASE(f);
    if (!i || !main || !cb.address) return;
    char* u = utf8_of(url);
    cb.address(i, u);
    free(u);
}

// ---- popups: target=_blank, window.open, ⌘-click (docs/BROWSER.md §2.5) ----
//
// Deckhand decides (callbacks.popup: refused without a user gesture) and makes
// a tab for it in the opener's session; the new browser is windowless like
// every other and gets a reserved slot, taken in on_after_created. CEF
// creates it with the opener's client, so window.opener is kept.

static int free_slot(void) {
    for (int i = 1; i <= MAX_BROWSERS; i++)
        if (!slots[i].browser && !slots[i].closing && !slots[i].pending) return i;
    return 0;
}

static int CEF_CALLBACK on_before_popup(cef_life_span_handler_t* self, cef_browser_t* b, cef_frame_t* f, int popup_id,
                                        const cef_string_t* target_url, const cef_string_t* target_frame_name,
                                        cef_window_open_disposition_t disposition, int user_gesture,
                                        const cef_popup_features_t* features, cef_window_info_t* wi, cef_client_t** cl,
                                        cef_browser_settings_t* bs, cef_dictionary_value_t** extra, int* no_js) {
    int opener = slot_of(b);
    RELEASE(b);
    if (f) RELEASE(f);
    if (!opener || !cb.popup || shutting_down) return 1;
    int i = free_slot();
    char* url = utf8_of(target_url);
    // no slot left: Deckhand still hears of it (refused), the page gets nothing
    uint64_t tab = cb.popup(opener, i, url, user_gesture, disposition == CEF_WOD_NEW_BACKGROUND_TAB);
    free(url);
    if (!i || !tab) return 1;
    static unsigned long long res_seq;
    Slot* s = &slots[i];
    *s = (Slot){0};
    s->pending = 1;
    s->opener_cef = slots[opener].cef_id;
    s->popup_id = popup_id;
    s->res_seq = ++res_seq;
    s->w = slots[opener].w, s->h = slots[opener].h, s->scale = slots[opener].scale;
    s->tab_id = tab;
    s->created_at = now_s();
    wi->windowless_rendering_enabled = 1;
    wi->shared_texture_enabled = shared_textures;
    wi->runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    wi->parent_view = NULL;
    bs->windowless_frame_rate = 60;
    bs->background_color = 0xFFFFFFFF;
    arm(0);
    return 0; // CEF creates it (client: the opener's, ours)
}

// The reservations, for the matcher (cef_popup_slots.h).
static void reservations(dh_popup_res r[MAX_BROWSERS + 1]) {
    memset(r, 0, sizeof(dh_popup_res) * (MAX_BROWSERS + 1));
    for (int i = 1; i <= MAX_BROWSERS; i++)
        if (slots[i].pending) r[i] = (dh_popup_res){slots[i].pending, slots[i].opener_cef, slots[i].popup_id, slots[i].res_seq};
}

static void close_now(cef_browser_t* b) {
    cef_browser_host_t* hst = b->get_host(b);
    if (hst) {
        hst->close_browser(hst, 1);
        RELEASE(hst);
    }
}

// A popup's browser exists: it takes its opener's oldest reservation (never
// another opener's: that tab may be in another session).
static void CEF_CALLBACK on_after_created(cef_life_span_handler_t* self, cef_browser_t* b) {
    int id = b->get_identifier(b);
    for (int i = 1; i <= MAX_BROWSERS; i++)
        if (slots[i].browser && slots[i].cef_id == id) {
            RELEASE(b);
            return;
        }
    if (creating || !b->is_popup(b)) {
        RELEASE(b); // dh_cef_open's: it keeps the one create_browser_sync returns
        return;
    }
    int opener = 0;
    cef_browser_host_t* oh = b->get_host(b);
    if (oh) {
        opener = oh->get_opener_identifier(oh);
        RELEASE(oh);
    }
    dh_popup_res r[MAX_BROWSERS + 1];
    reservations(r);
    int k = shutting_down ? 0 : dh_popup_take(r, MAX_BROWSERS, opener);
    if (!k) {
        // nothing reserved it (Deckhand is shutting down, or an abort released
        // its reservation: cef_popup_slots.h): close it again
        close_now(b);
        RELEASE(b);
        return;
    }
    Slot* s = &slots[k];
    int cancelled = s->pending == 2; // its tab closed meanwhile (dh_cef_close)
    s->pending = 0;
    s->browser = b; // our reference (released in on_before_close)
    s->cef_id = id;
    s->loading = 1;
    cef_browser_host_t* hst = b->get_host(b);
    if (hst) {
        if (cancelled) {
            s->closing = 1;
            hst->close_browser(hst, 1);
        } else {
            // created at a guessed size: paint at the slot's
            hst->was_resized(hst);
            hst->invalidate(hst, PET_VIEW);
        }
        RELEASE(hst);
    }
    arm(0);
}

// A popup allowed in on_before_popup failed before its browser existed.
static void CEF_CALLBACK on_popup_aborted(cef_life_span_handler_t* self, cef_browser_t* b, int popup_id) {
    int opener = b->get_identifier(b);
    RELEASE(b);
    dh_popup_res r[MAX_BROWSERS + 1];
    reservations(r);
    int k = dh_popup_find(r, MAX_BROWSERS, opener, popup_id);
    if (!k) return;
    int cancelled = slots[k].pending == 2;
    slots[k] = (Slot){0};
    if (!cancelled && cb.closed) cb.closed(k); // Deckhand's tab says the page closed
}

// ---- deckhand-test://web/NAME: tests/web/NAME in test mode (no network) ----

static char test_root[PATH_MAX]; // "" = no handler (real use)

typedef struct {
    cef_resource_handler_t h;
    _Atomic int refs;
    char* data;
    size_t len, pos;
    int status;
    const char* mime;
} Test_Res;

static void CEF_CALLBACK tr_add(cef_base_ref_counted_t* self) { ((Test_Res*)self)->refs++; }
static int CEF_CALLBACK tr_release(cef_base_ref_counted_t* self) {
    Test_Res* r = (Test_Res*)self;
    if (--r->refs > 0) return 0;
    free(r->data);
    free(r);
    return 1;
}
static int CEF_CALLBACK tr_one(cef_base_ref_counted_t* self) { return ((Test_Res*)self)->refs == 1; }
static int CEF_CALLBACK tr_some(cef_base_ref_counted_t* self) { return ((Test_Res*)self)->refs >= 1; }

static int CEF_CALLBACK tr_open(cef_resource_handler_t* self, cef_request_t* req, int* handle, cef_callback_t* callback) {
    Test_Res* r = (Test_Res*)self;
    *handle = 1;
    r->status = 404;
    r->mime = "text/plain";
    cef_string_userfree_t u = req->get_url(req);
    RELEASE(req);
    if (callback) RELEASE(callback);
    char* url = u ? utf8_of(u) : strdup("");
    if (u) p_cef_string_userfree_utf16_free(u);
    const char* prefix = "deckhand-test://web/";
    char path[PATH_MAX];
    if (strncmp(url, prefix, strlen(prefix)) == 0) {
        char name[PATH_MAX];
        snprintf(name, sizeof name, "%s", url + strlen(prefix));
        name[strcspn(name, "?#")] = 0;
        // a plain name under the root: no "..", no absolute or hidden parts
        if (name[0] && name[0] != '/' && !strstr(name, "..") && !strstr(name, "/.") && name[0] != '.') {
            snprintf(path, sizeof path, "%s/%s", test_root, name);
            FILE* fp = fopen(path, "rb");
            if (fp) {
                fseek(fp, 0, SEEK_END);
                long n = ftell(fp);
                fseek(fp, 0, SEEK_SET);
                if (n >= 0 && n < 16 * 1024 * 1024) {
                    r->data = malloc(n ? n : 1);
                    r->len = fread(r->data, 1, n, fp);
                    r->status = 200;
                    const char* ext = strrchr(name, '.');
                    r->mime = !ext ? "application/octet-stream" : !strcmp(ext, ".html") ? "text/html" : !strcmp(ext, ".js") ? "text/javascript"
                            : !strcmp(ext, ".css") ? "text/css" : !strcmp(ext, ".png") ? "image/png" : "text/plain";
                }
                fclose(fp);
            }
        }
    }
    free(url);
    if (r->status != 200) {
        r->data = strdup("not found");
        r->len = strlen(r->data);
    }
    return 1;
}

static void CEF_CALLBACK tr_headers(cef_resource_handler_t* self, cef_response_t* resp, int64_t* len, cef_string_t* redirect) {
    Test_Res* r = (Test_Res*)self;
    resp->set_status(resp, r->status);
    cef_string_t m = str16(r->mime);
    resp->set_mime_type(resp, &m);
    p_cef_string_utf16_clear(&m);
    RELEASE(resp);
    *len = (int64_t)r->len;
}

static int CEF_CALLBACK tr_read(cef_resource_handler_t* self, void* out, int want, int* got, cef_resource_read_callback_t* callback) {
    Test_Res* r = (Test_Res*)self;
    if (callback) RELEASE(callback);
    size_t n = r->len - r->pos;
    if (n == 0) {
        *got = 0;
        return 0; // done
    }
    if (n > (size_t)want) n = (size_t)want;
    memcpy(out, r->data + r->pos, n);
    r->pos += n;
    *got = (int)n;
    return 1;
}

static void CEF_CALLBACK tr_cancel(cef_resource_handler_t* self) {}

static cef_resource_handler_t* CEF_CALLBACK test_factory_create(cef_scheme_handler_factory_t* self, cef_browser_t* b, cef_frame_t* f,
                                                                const cef_string_t* scheme, cef_request_t* req) {
    if (b) RELEASE(b);
    if (f) RELEASE(f);
    if (req) RELEASE(req);
    Test_Res* r = calloc(1, sizeof *r);
    r->h.base.size = sizeof(cef_resource_handler_t);
    r->h.base.add_ref = tr_add;
    r->h.base.release = tr_release;
    r->h.base.has_one_ref = tr_one;
    r->h.base.has_at_least_one_ref = tr_some;
    r->h.open = tr_open;
    r->h.get_response_headers = tr_headers;
    r->h.read = tr_read;
    r->h.cancel = tr_cancel;
    r->refs = 1; // the caller's
    return &r->h;
}

static cef_scheme_handler_factory_t test_factory;

// Every process registers the scheme (the helper too, cef_helper.c): standard,
// so relative links resolve; secure, so fixtures may ask what needs a secure
// context (notifications, location: browser-polish.txt). Only test mode serves it (dh_cef_test_scheme).
static void CEF_CALLBACK on_register_schemes(cef_app_t* self, cef_scheme_registrar_t* reg) {
    cef_string_t n = str16("deckhand-test");
    reg->add_custom_scheme(reg, &n, CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE | CEF_SCHEME_OPTION_CORS_ENABLED);
    p_cef_string_utf16_clear(&n); // the registrar is scoped (not ref-counted): never released
}

// ---- NSApp: CrAppControlProtocol (Chromium checks NSApp conforms) ----

@protocol CrAppProtocol
- (BOOL)isHandlingSendEvent;
@end
@protocol CrAppControlProtocol <CrAppProtocol>
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end
@protocol CefAppProtocol <CrAppControlProtocol>
@end

static BOOL handling_send_event;
static IMP orig_send_event;
static BOOL app_is_handling(id self, SEL _cmd) { return handling_send_event; }
static void app_set_handling(id self, SEL _cmd, BOOL v) { handling_send_event = v; }
static void app_send_event(id self, SEL _cmd, NSEvent* e) {
    BOOL was = handling_send_event;
    handling_send_event = YES;
    ((void (*)(id, SEL, NSEvent*))orig_send_event)(self, _cmd, e);
    handling_send_event = was;
}

static void nsapp_conform(void) {
    Class c = [NSApp class];
    class_addMethod(c, @selector(isHandlingSendEvent), (IMP)app_is_handling, "c@:");
    class_addMethod(c, @selector(setHandlingSendEvent:), (IMP)app_set_handling, "v@:c");
    Method m = class_getInstanceMethod(c, @selector(sendEvent:));
    orig_send_event = method_getImplementation(m);
    // on the class itself (NSApplication's own method otherwise gets replaced for every subclass)
    if (!class_addMethod(c, @selector(sendEvent:), (IMP)app_send_event, method_getTypeEncoding(m)))
        method_setImplementation(m, (IMP)app_send_event);
    class_addProtocol(c, @protocol(CrAppProtocol));
    class_addProtocol(c, @protocol(CrAppControlProtocol));
    class_addProtocol(c, @protocol(CefAppProtocol));
}

// ---- Chromium's own Library ----
//
// Chromium finds the user's Library with NSSearchPathForDirectoriesInDomains
// (base::apple::GetUserLibraryPath) and keeps things there that Google Chrome
// shares, RLZ's ~/Library/Application Support/Google/RLZ above all. Deckhand's
// Chromium must never touch them (another browser's files are not ours): the framework's
// calls (its GOT entry, nothing else in the process) get a Library inside
// Deckhand's data dir instead. Deckhand's own lookups are unchanged.
static char lib_home[PATH_MAX]; // <data dir>/browser/home

static NSArray<NSString*>* framework_search_path(NSSearchPathDirectory dir, NSSearchPathDomainMask mask, BOOL expand) {
    NSString* sub = nil;
    if (dir == NSLibraryDirectory) sub = @"Library";
    else if (dir == NSApplicationSupportDirectory) sub = @"Library/Application Support";
    else if (dir == NSCachesDirectory) sub = @"Library/Caches";
    else if (dir == NSAllLibrariesDirectory) sub = @"Library";
    if (!sub || !(mask & NSUserDomainMask)) return NSSearchPathForDirectoriesInDomains(dir, mask, expand);
    NSMutableArray* out = [NSMutableArray arrayWithObject:[@(lib_home) stringByAppendingPathComponent:sub]];
    NSSearchPathDomainMask rest = mask & ~NSUserDomainMask;
    if (rest) [out addObjectsFromArray:NSSearchPathForDirectoriesInDomains(dir, rest, expand)];
    return out;
}

// Rewrites the framework's GOT entry for NSSearchPathForDirectoriesInDomains.
// fw: the path dh_cef_start passed to dlopen; only that image is changed.
// Returns the number of entries changed (0: refuse to start CEF).
static int redirect_framework_library(const char* fw, const char* home) {
    if (strlen(home) >= sizeof(lib_home)) return 0;
    strcpy(lib_home, home);
    char want[PATH_MAX], have[PATH_MAX];
    if (!realpath(fw, want)) return 0;
    void* real = (void*)&NSSearchPathForDirectoriesInDomains;
    int changed = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char* name = _dyld_get_image_name(i);
        if (!name || !realpath(name, have) || strcmp(have, want) != 0) continue;
        const struct mach_header_64* h = (const struct mach_header_64*)_dyld_get_image_header(i);
        // the non-lazy bindings: read-only once dyld has bound them
        const char* sects[] = {"__got", "__auth_got"};
        for (size_t k = 0; k < sizeof(sects) / sizeof(sects[0]); k++) {
            unsigned long size = 0;
            void** got = (void**)getsectiondata(h, "__DATA_CONST", sects[k], &size);
            if (!got) continue;
            for (unsigned long j = 0; j < size / sizeof(void*); j++) {
                if (got[j] != real) continue;
                // put the page back the way it was found
                mach_vm_address_t addr = (mach_vm_address_t)&got[j];
                mach_vm_size_t len = 0;
                vm_region_basic_info_data_64_t info;
                mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
                mach_port_t obj = MACH_PORT_NULL;
                if (mach_vm_region(mach_task_self(), &addr, &len, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS)
                    return 0;
                if (addr > (mach_vm_address_t)&got[j]) return 0; // not mapped
                int prot = (info.protection & VM_PROT_READ ? PROT_READ : 0) | (info.protection & VM_PROT_WRITE ? PROT_WRITE : 0) |
                           (info.protection & VM_PROT_EXECUTE ? PROT_EXEC : 0);
                uintptr_t page = (uintptr_t)&got[j] & ~(uintptr_t)(getpagesize() - 1);
                if (mprotect((void*)page, getpagesize(), prot | PROT_WRITE) != 0) return 0;
                got[j] = (void*)&framework_search_path;
                if (mprotect((void*)page, getpagesize(), prot) != 0) return 0;
                changed++;
            }
        }
        break; // the one image
    }
    return changed;
}

// ---- public API ----

// Starts CEF once (later calls return the first result). root_cache: the
// profile directory; log_file: CEF's log ("" = none). 1 = running.
int dh_cef_start(void* mtl_device, const char* root_cache, const char* log_file, int shared, int no_network, const dh_cef_callbacks* callbacks) {
    if (started) return started == 1;
    started = -1;
    if (callbacks) cb = *callbacks;
    NSString* fw = [NSBundle.mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
    if (!NSBundle.mainBundle.bundleIdentifier || ![NSFileManager.defaultManager fileExistsAtPath:fw]) {
        say(@"not running from Deckhand.app (no framework): browser unavailable");
        return 0;
    }
    double t0 = now_s();
    framework = dlopen(fw.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (!framework) {
        say([NSString stringWithFormat:@"dlopen: %s", dlerror()]);
        return 0;
    }
#define LOAD(name)                                                       \
    p_##name = (__typeof__(name)*)dlsym(framework, #name);               \
    if (!p_##name) {                                                     \
        say(@"missing symbol " #name);                                   \
        return 0;                                                        \
    }
    CEF_FNS(LOAD)
    {
        // <data dir>/browser/profile -> <data dir>/browser/home (made 0700)
        NSString* home = [[@(root_cache) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"home"];
        NSString* support = [home stringByAppendingPathComponent:@"Library/Application Support"];
        [NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions : @0700} error:nil];
        chmod(home.fileSystemRepresentation, 0700);
        int n = redirect_framework_library(fw.fileSystemRepresentation, home.fileSystemRepresentation);
        if (n == 0) {
            say(@"could not give Chromium its own Library: browser unavailable");
            return 0;
        }
    }
    // Chromium's Mac brand lookup (google_brand::GetBrand) reads
    // ~/Library/Google/Google Chrome Brand.plist, which Google Chrome shares,
    // unless the app's Info.plist has a KSBrandID: it expands the ~ inside
    // Foundation, out of the GOT's reach. scripts/bundle-app.sh writes "" (no
    // brand, organic, as before); refuse to start without it.
    if (![NSBundle.mainBundle.infoDictionary[@"KSBrandID"] isKindOfClass:NSString.class]) {
        say(@"Info.plist has no KSBrandID (Chromium would read Google Chrome's brand file): browser unavailable");
        return 0;
    }
    // the API version these headers describe; the framework refuses a mismatch
    const char* hash = p_cef_api_hash(CEF_API_VERSION, 0);
    if (!hash || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
        say([NSString stringWithFormat:@"API hash mismatch: framework %s, headers %s", hash ? hash : "(null)", CEF_API_HASH_PLATFORM]);
        return 0;
    }
    device = (__bridge id<MTLDevice>)mtl_device;
    queue = [device newCommandQueue];
    shared_textures = shared;
    offline = no_network;
    nsapp_conform();

    INIT_BASE(app);
    app.on_before_command_line_processing = on_before_cmdline;
    app.get_browser_process_handler = get_bph;
    app.on_register_custom_schemes = on_register_schemes;
    INIT_BASE(bph);
    bph.on_schedule_message_pump_work = on_schedule_work;
    INIT_BASE(client);
    client.get_render_handler = get_render;
    client.get_life_span_handler = get_life;
    client.get_load_handler = get_load;
    client.get_display_handler = get_display;
    client.get_keyboard_handler = get_keyboard;
    INIT_BASE(render);
    render.get_view_rect = get_view_rect;
    render.get_screen_info = get_screen_info;
    render.on_paint = on_paint;
    render.on_accelerated_paint = on_accelerated_paint;
    INIT_BASE(life);
    life.on_before_close = on_before_close;
    life.on_before_popup = on_before_popup;
    life.on_after_created = on_after_created;
    life.on_before_popup_aborted = on_popup_aborted;
    INIT_BASE(load);
    load.on_loading_state_change = on_loading_state;
    INIT_BASE(display);
    display.on_title_change = on_title;
    display.on_address_change = on_address;
    INIT_BASE(keyboard);
    keyboard.on_key_event = on_key_event;
    polish_install(); // step 3: dialogs, find, zoom, downloads, permissions, menus, crashes (cef_polish.inc)

    pump_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(pump_timer, ^{ pump(); });
    dispatch_source_set_timer(pump_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(pump_timer);

    cef_settings_t s;
    memset(&s, 0, sizeof s);
    s.size = sizeof s;
    s.no_sandbox = 0;
    s.external_message_pump = 1;
    s.windowless_rendering_enabled = 1;
    s.multi_threaded_message_loop = 0;
    s.persist_session_cookies = 1;
    s.root_cache_path = str16(root_cache);
    s.cache_path = str16(root_cache); // the one shared profile lives at the root
    if (log_file && log_file[0]) {
        s.log_file = str16(log_file);
        s.log_severity = LOGSEVERITY_WARNING;
    } else
        s.log_severity = LOGSEVERITY_DISABLE;
    // NSApp's args are Deckhand's own: CEF must not parse them as switches
    s.command_line_args_disabled = 1;
    s.background_color = 0xFFFFFFFF;
    char* argv0 = (char*)NSProcessInfo.processInfo.arguments.firstObject.UTF8String;
    char* argv[] = {argv0, NULL};
    cef_main_args_t args = {.argc = 1, .argv = argv};
    started = 1; // the pump may be asked for during cef_initialize
    if (!p_cef_initialize(&args, &s, &app, NULL)) {
        started = -1;
        say(@"cef_initialize failed");
        return 0;
    }
    say([NSString stringWithFormat:@"started CEF %s in %.0f ms (shared textures %s)", CEF_API_HASH_PLATFORM,
                                   (now_s() - t0) * 1000, shared ? "on" : "off"]);
    arm(0);
    return 1;
}

// Every frame (main.odin): the pump, if its timer is overdue. While the frame loop draws every
// frame (an agent's command waiting redraws each one), each frame can block in -[CAMetalLayer
// nextDrawable] until a drawable comes back, and the main queue, where the timer fires, gets no
// turn for seconds: Chromium then does nothing (a page behind the view never loads, a woken tab
// never paints). Measured: pumps due in 33 ms ran 1-5 s late.
void dh_cef_pump_due(void) {
    if (due_at > 0 && now_s() >= due_at + 0.005) pump();
}

int dh_cef_running(void) { return started == 1 && !shutting_down; }

// A windowless browser for url, w x h logical px at scale. Returns its id
// (1..8) or 0.
int dh_cef_open(const char* url, int w, int h, float scale, uint64_t tab_id) {
    if (!dh_cef_running()) return 0;
    int i = free_slot();
    if (!i) return 0;
    Slot* s = &slots[i];
    *s = (Slot){0};
    s->w = w, s->h = h, s->scale = scale > 0 ? scale : 1;
    s->tab_id = tab_id;
    s->created_at = now_s();
    cef_window_info_t wi;
    memset(&wi, 0, sizeof wi);
    wi.size = sizeof wi;
    wi.windowless_rendering_enabled = 1;
    wi.shared_texture_enabled = shared_textures;
    wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY; // windowless needs Alloy
    cef_browser_settings_t bs;
    memset(&bs, 0, sizeof bs);
    bs.size = sizeof bs;
    bs.windowless_frame_rate = 60;
    bs.background_color = 0xFFFFFFFF;
    cef_string_t u = str16(url);
    creating = i;
    cef_browser_t* b = p_cef_browser_host_create_browser_sync(&wi, &client, &u, &bs, NULL, NULL);
    creating = 0;
    p_cef_string_utf16_clear(&u);
    if (!b) {
        say(@"create_browser_sync failed");
        return 0;
    }
    s->browser = b;
    s->cef_id = b->get_identifier(b);
    s->loading = 1;
    arm(0);
    return i;
}

void dh_cef_resize(int i, int w, int h, float scale) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    int scale_changed = scale != slots[i].scale;
    if (w == slots[i].w && h == slots[i].h && !scale_changed) {
        RELEASE(hst);
        return;
    }
    slots[i].w = w, slots[i].h = h, slots[i].scale = scale;
    if (scale_changed) hst->notify_screen_info_changed(hst);
    hst->was_resized(hst);
    RELEASE(hst);
}

void dh_cef_set_hidden(int i, int hidden) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    if (slots[i].hidden != hidden) {
        slots[i].hidden = hidden;
        hst->was_hidden(hst, hidden);
        // a paint that came while hidden was given back undrawn: paint again
        if (!hidden) hst->invalidate(hst, PET_VIEW);
        if (!hidden) arm(0);
    }
    RELEASE(hst);
}

// Paint the whole view again (a ring that fits it is ready).
void dh_cef_invalidate(int i) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    hst->invalidate(hst, PET_VIEW);
    RELEASE(hst);
    arm(0);
}

void dh_cef_focus(int i, int focused) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    hst->set_focus(hst, focused);
    RELEASE(hst);
}

// Mouse in view coordinates (logical px). button: 0 left, 1 middle, 2 right.
void dh_cef_mouse_move(int i, int x, int y, int mods, int leave) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    cef_mouse_event_t e = {.x = x, .y = y, .modifiers = (uint32_t)mods};
    hst->send_mouse_move_event(hst, &e, leave);
    RELEASE(hst);
    touch();
    arm(0);
}

void dh_cef_mouse_click(int i, int x, int y, int mods, int button, int up, int count) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    cef_mouse_event_t e = {.x = x, .y = y, .modifiers = (uint32_t)mods};
    hst->send_mouse_click_event(hst, &e, (cef_mouse_button_type_t)button, up, count);
    RELEASE(hst);
    touch();
    arm(0);
}

void dh_cef_wheel(int i, int x, int y, int mods, int dx, int dy) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    cef_mouse_event_t e = {.x = x, .y = y, .modifiers = (uint32_t)mods};
    hst->send_mouse_wheel_event(hst, &e, dx, dy);
    RELEASE(hst);
    touch();
    arm(0);
}

// type: 0 RAWKEYDOWN, 2 KEYUP, 3 CHAR (cef_key_event_type_t). native: the
// macOS virtual key code; ch / unmod: UTF-16 characters (0 = none).
void dh_cef_key(int i, int type, int native, int mods, unsigned short ch, unsigned short unmod) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    cef_key_event_t e;
    memset(&e, 0, sizeof e);
    e.size = sizeof e;
    e.type = (cef_key_event_type_t)type;
    e.modifiers = (uint32_t)mods;
    e.native_key_code = native;
    e.character = ch;
    e.unmodified_character = unmod ? unmod : ch;
    hst->send_key_event(hst, &e);
    RELEASE(hst);
    touch();
    arm(0);
}

// The main frame loads url (the URL field, browser_navigate).
void dh_cef_navigate(int i, const char* url) {
    if (i < 1 || i > MAX_BROWSERS || !slots[i].browser || slots[i].closing) return;
    cef_frame_t* f = slots[i].browser->get_main_frame(slots[i].browser);
    if (!f) return;
    cef_string_t u = str16(url);
    f->load_url(f, &u);
    p_cef_string_utf16_clear(&u);
    RELEASE(f);
    touch();
    arm(0);
}

// what: 0 back, 1 forward, 2 reload, 3 stop.
void dh_cef_history(int i, int what) {
    if (i < 1 || i > MAX_BROWSERS || !slots[i].browser || slots[i].closing) return;
    cef_browser_t* b = slots[i].browser;
    switch (what) {
    case 0: b->go_back(b); break;
    case 1: b->go_forward(b); break;
    case 2: b->reload(b); break;
    case 3: b->stop_load(b); break;
    }
    touch();
    arm(0);
}

// Test mode: deckhand-test://web/NAME serves root/NAME (tests/web). 1 = registered.
int dh_cef_test_scheme(const char* root) {
    if (started != 1 || !root || strlen(root) >= sizeof test_root) return 0;
    snprintf(test_root, sizeof test_root, "%s", root);
    INIT_BASE(test_factory);
    test_factory.create = test_factory_create;
    cef_string_t n = str16("deckhand-test"), d = str16("");
    int ok = p_cef_register_scheme_handler_factory(&n, &d, &test_factory);
    p_cef_string_utf16_clear(&n);
    p_cef_string_utf16_clear(&d);
    return ok;
}

void dh_cef_exec_js(int i, const char* js) {
    if (i < 1 || i > MAX_BROWSERS || !slots[i].browser || slots[i].closing) return;
    cef_frame_t* f = slots[i].browser->get_main_frame(slots[i].browser);
    if (!f) return;
    cef_string_t code = str16(js), url = str16("deckhand://test");
    f->execute_java_script(f, &code, &url, 0);
    p_cef_string_utf16_clear(&code);
    p_cef_string_utf16_clear(&url);
    RELEASE(f);
    arm(0);
}

// Counters for the spike's report: paints by path, first paint after create
// (ms), pumps, paints dropped (no ring slot free).
void dh_cef_stats(int i, uint64_t* gpu, uint64_t* cpu, double* first_paint_ms, uint64_t* pump_count, uint64_t* dropped_n) {
    *pump_count = pumps;
    if (i < 1 || i > MAX_BROWSERS) return;
    *gpu = slots[i].paints_gpu;
    *cpu = slots[i].paints_cpu;
    *dropped_n = slots[i].dropped;
    *first_paint_ms = slots[i].first_paint_at > 0 ? (slots[i].first_paint_at - slots[i].created_at) * 1000 : -1;
}

// Slots no browser holds or waits for (Deckhand's page planner, browser.odin);
// closing: also those whose browser is closing (free in a moment).
int dh_cef_free_slots(int closing) {
    int n = 0;
    for (int i = 1; i <= MAX_BROWSERS; i++) n += !slots[i].pending && (slots[i].browser ? closing && slots[i].closing : 1);
    return n;
}

// 1: the browser exists (a popup's arrives a little after its tab: on_after_created).
int dh_cef_ready(int i) { return i >= 1 && i <= MAX_BROWSERS && slots[i].browser && !slots[i].closing; }

void dh_cef_close(int i) {
    if (i >= 1 && i <= MAX_BROWSERS && slots[i].pending) {
        slots[i].pending = 2; // closed as soon as it arrives
        slots[i].tab_id = 0;
        return;
    }
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    slots[i].closing = 1;
    slots[i].tab_id = 0; // its ring goes with the tab: later paints go nowhere
    hst->close_browser(hst, 1);
    RELEASE(hst);
    touch();
    arm(0);
}

// On quit: close every browser, pump until each is gone (at most 2 s), then
// cef_shutdown on the main thread.
void dh_cef_shutdown(void) {
    if (started != 1 || shutting_down) return;
    double t0 = now_s();
    for (int i = 1; i <= MAX_BROWSERS; i++) {
        cef_browser_host_t* hst = slots[i].browser ? slots[i].browser->get_host(slots[i].browser) : NULL;
        if (!hst) continue;
        slots[i].closing = 1;
        hst->close_browser(hst, 1);
        RELEASE(hst);
    }
    shutting_down = 1;
    dispatch_source_cancel(pump_timer);
    for (;;) {
        int open = 0;
        for (int i = 1; i <= MAX_BROWSERS; i++) open += slots[i].browser != NULL;
        if (!open || now_s() - t0 > 2) break;
        p_cef_do_message_loop_work();
        usleep(2000);
    }
    int left = 0;
    for (int i = 1; i <= MAX_BROWSERS; i++) left += slots[i].browser != NULL;
    if (left) say([NSString stringWithFormat:@"%d browser(s) did not close in 2 s", left]);
    // a few more turns for in-flight tasks, as cefclient does
    for (int k = 0; k < 10; k++) p_cef_do_message_loop_work();
    p_cef_shutdown();
    started = -1;
    say([NSString stringWithFormat:@"shut down in %.0f ms", (now_s() - t0) * 1000]);
}

// ---- DevTools protocol, in process (docs/BROWSER.md §3.3: annotation) ----
//
// Deckhand talks CDP to a browser through send_dev_tools_message and one
// observer per browser (registered on its first message): no remote
// debugging port. Results and events go to Deckhand's callback on the main
// thread (the UI thread: the pump runs there), as JSON. src/browser_annotate.odin.

typedef void (*dh_cef_devtools_fn)(int id, int msg_id, int ok, const char* method, const char* json, size_t len);
static dh_cef_devtools_fn devtools_cb;
static cef_dev_tools_message_observer_t devtools_obs;
static cef_registration_t* devtools_reg[MAX_BROWSERS + 1];
static int devtools_reg_cef[MAX_BROWSERS + 1]; // the CEF browser its registration observes

static int devtools_slot(cef_browser_t* b) {
    int id = b->get_identifier(b);
    for (int i = 1; i <= MAX_BROWSERS; i++)
        if (slots[i].browser && slots[i].cef_id == id && !slots[i].closing) return i;
    return 0;
}

static void CEF_CALLBACK on_devtools_result(cef_dev_tools_message_observer_t* self, cef_browser_t* b, int msg_id, int ok,
                                            const void* result, size_t size) {
    int i = devtools_slot(b);
    RELEASE(b);
    if (i && devtools_cb) devtools_cb(i, msg_id, ok, NULL, result ? (const char*)result : "", result ? size : 0);
}

static void CEF_CALLBACK on_devtools_event(cef_dev_tools_message_observer_t* self, cef_browser_t* b, const cef_string_t* method,
                                           const void* params, size_t size) {
    int i = devtools_slot(b);
    RELEASE(b);
    if (!i || !devtools_cb) return;
    cef_string_utf8_t m = {0};
    if (method) p_cef_string_utf16_to_utf8(method->str, method->length, &m);
    devtools_cb(i, 0, 1, m.str ? m.str : "", params ? (const char*)params : "", params ? size : 0);
    p_cef_string_utf8_clear(&m);
}

static void devtools_forget(int i) {
    if (devtools_reg[i]) RELEASE(devtools_reg[i]); // unregisters the observer
    devtools_reg[i] = NULL;
    devtools_reg_cef[i] = 0;
}

void dh_cef_devtools_callback(dh_cef_devtools_fn fn) { devtools_cb = fn; }

// Sends one CDP message ({"id":N,"method":…,"params":…}, UTF-8 JSON) to
// browser i. 1 = submitted (a result comes back through the callback).
int dh_cef_devtools_send(int i, const char* json, size_t len) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return 0;
    if (!devtools_obs.base.size) {
        INIT_BASE(devtools_obs);
        devtools_obs.on_dev_tools_method_result = on_devtools_result;
        devtools_obs.on_dev_tools_event = on_devtools_event;
    }
    if (devtools_reg[i] && devtools_reg_cef[i] != slots[i].cef_id) devtools_forget(i); // a browser before it in this slot
    if (!devtools_reg[i]) {
        devtools_reg[i] = hst->add_dev_tools_message_observer(hst, &devtools_obs);
        devtools_reg_cef[i] = slots[i].cef_id;
    }
    int ok = hst->send_dev_tools_message(hst, json, len);
    RELEASE(hst);
    touch();
    arm(0);
    return ok;
}

// ---- step 3: tab polish (cursor, tooltips, context menu, JS dialogs, find, zoom, downloads,
// permissions, crashes, DevTools) ----
#include "cef_polish.inc"
