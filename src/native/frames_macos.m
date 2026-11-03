// The frame channel between pi-desk and an app tab's process (docs/ENGINE-BRIDGE.md §2):
// a ring of IOSurfaces pi-desk owns, moved to the app over plain Mach messages
// found through a per-process bootstrap name. Plain C; ObjC only for Metal.
//
// Two halves in one file:
//  - serve (pi-desk, src/frames.odin): one checked-in receive port shared by
//    every app tab, drained on a serial background queue that only records
//    what arrived (the frame loop never waits on it); rings, RELEASE after
//    pi-desk's own GPU frame that last sampled a slot has completed.
//    A local channel (browser tabs: CEF paints in pi-desk's own process) is
//    the same ring with no Mach peer: the producer takes a free slot
//    (pd_frames_local_acquire), FRAME is a call (pd_frames_local_frame) and
//    RELEASE marks the slot free again, at the same moments as for an app.
//  - connect (the app: tests/fake-app, later a real engine): bootstrap_look_up, HELLO,
//    RING -> wrapped MTLTextures, FRAME from an empty command buffer's
//    completed handler, RELEASE and RING_DONE.
//
// Messages: fixed little-endian structs after the Mach header; msgh_id picks
// the type. Only FRAME may be dropped (sent with a 0 timeout); HELLO and
// RING_DONE are sent with no timeout; RING and RELEASE with 250 ms from
// pi-desk's Mach queue (a timeout marks the app stalled; never retried).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurfaceRef.h>
#include <bsm/libbsm.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/notify.h>
#include <os/lock.h>
#include <servers/bootstrap.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

// ---- messages (shared) ----

enum { PDF_HELLO = 1, PDF_RING = 2, PDF_RING_DONE = 3, PDF_FRAME = 4, PDF_RELEASE = 5 };
#define PDF_SLOTS 3
#define PDF_SEND_TIMEOUT_MS 250
#define PDF_QLIMIT_SERVE 1024
#define PDF_QLIMIT_APP 64

typedef struct { mach_msg_header_t h; uint8_t key[32]; uint64_t tab_id; } pdf_hello;
typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t ports[PDF_SLOTS];
    uint32_t gen, count, w, hgt;
    float scale;
    uint32_t pixel_format;
} pdf_ring;
typedef struct { mach_msg_header_t h; uint32_t gen; } pdf_ring_done;
typedef struct { mach_msg_header_t h; uint32_t gen, slot; uint64_t seq, tick; } pdf_frame;
typedef struct { mach_msg_header_t h; uint32_t gen, slot; } pdf_release;

typedef union {
    mach_msg_header_t h;
    pdf_hello hello;
    pdf_ring ring;
    pdf_ring_done done;
    pdf_frame frame;
    pdf_release release;
    mach_dead_name_notification_t dead;
    uint8_t raw[512];
} pdf_any;
typedef struct { pdf_any m; mach_msg_audit_trailer_t pad; } pdf_rcv;

#define PDF_RCV_OPTS (MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT))

static double pdf_now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static void pdf_fill(mach_msg_header_t* h, uint32_t size, mach_port_t remote, int id) {
    memset(h, 0, size);
    h->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    h->msgh_size = size;
    h->msgh_remote_port = remote;
    h->msgh_id = id;
}

// ---- pure rules (unit-tested from src/frames_test.odin) ----

// Constant-time compare of two 32-byte keys: 1 when equal.
int pd_frames_key_equal(const uint8_t* a, const uint8_t* b) {
    uint8_t d = 0;
    for (int i = 0; i < 32; i++) d |= a[i] ^ b[i];
    return d == 0;
}

// The sender's pid may send for a tab whose process group is pgid and
// session sid when it is in that group or that session.
int pd_frames_sender_in(int sender_pgid, int sender_sid, int pgid, int sid) {
    if (sender_pgid <= 0 && sender_sid <= 0) return 0;
    return (pgid > 0 && sender_pgid == pgid) || (sid > 0 && sender_sid == sid);
}

// What a FRAME does to the latest-not-yet-shown slot. cur_gen: the ring the
// app must use now; has_latest/latest_slot: an unshown frame already waiting.
// Returns 0 = drop (stale gen or bad slot), 1 = take it, 2 = take it and
// release *release_slot (the older unshown latest, replaced).
int pd_frames_on_frame(uint32_t cur_gen, int has_latest, uint32_t latest_slot, uint32_t gen, uint32_t slot, uint32_t* release_slot) {
    if (gen != cur_gen || cur_gen == 0 || slot >= PDF_SLOTS) return 0;
    if (has_latest && latest_slot != slot) {
        *release_slot = latest_slot;
        return 2;
    }
    return 1;
}

// Message encodings, for the tests: fills buf (at least 128 bytes) and
// returns the message size.
int pd_frames_encode(int id, uint32_t a, uint32_t b, uint64_t c, uint64_t d, uint8_t* buf) {
    switch (id) {
    case PDF_FRAME: {
        pdf_frame* m = (pdf_frame*)buf;
        pdf_fill(&m->h, sizeof *m, MACH_PORT_NULL, PDF_FRAME);
        m->gen = a; m->slot = b; m->seq = c; m->tick = d;
        return sizeof *m;
    }
    case PDF_RELEASE: {
        pdf_release* m = (pdf_release*)buf;
        pdf_fill(&m->h, sizeof *m, MACH_PORT_NULL, PDF_RELEASE);
        m->gen = a; m->slot = b;
        return sizeof *m;
    }
    case PDF_RING_DONE: {
        pdf_ring_done* m = (pdf_ring_done*)buf;
        pdf_fill(&m->h, sizeof *m, MACH_PORT_NULL, PDF_RING_DONE);
        m->gen = a;
        return sizeof *m;
    }
    case PDF_HELLO: {
        pdf_hello* m = (pdf_hello*)buf;
        pdf_fill(&m->h, sizeof *m, MACH_PORT_NULL, PDF_HELLO);
        m->tab_id = c;
        return sizeof *m;
    }
    case PDF_RING: return sizeof(pdf_ring);
    }
    return 0;
}

// ======================================================================
// serve half (pi-desk)
// ======================================================================

#define PDF_CHANS 64
#define PDF_RINGS 4
#define PDF_LAT_N 512

typedef struct {
    uint32_t gen; // 0 = unused
    int w, h;
    float scale;
    IOSurfaceRef surf[PDF_SLOTS];
    void* tex[PDF_SLOTS]; // id<MTLTexture>, retained (CFBridgingRetain)
    // local channels only, under g_lock: who has each slot
    int state[PDF_SLOTS]; // PDF_SLOT_*
} pdf_ring_store;

enum {
    PDF_SLOT_FREE = 0, // the producer may write it
    PDF_SLOT_WRITING = 1, // acquired, its FRAME not given yet
    PDF_SLOT_PIDESK = 2, // FRAME given: pi-desk's until RELEASE
};

enum {
    PDF_F_CONNECTED = 1, // HELLO accepted
    PDF_F_DEAD = 2, // the app's port died
    PDF_F_STALLED = 4, // a RING or RELEASE send timed out
    PDF_F_REJECTED = 8, // a HELLO for this tab was refused
};

typedef struct {
    int used;
    int draining; // closed; the Mach queue has not dropped its send right yet (not reusable)
    int local; // in-process producer (a browser tab): no Mach peer, no HELLO
    uint64_t tab_id;
    // under g_lock
    uint8_t key[32];
    int pgid, sid; // the tab's process group and session
    int accepting; // waiting for HELLO
    uint32_t epoch; // bumped by open and stop: Mach-queue work for an older one is skipped
    uint32_t flags; // PDF_F_*, cleared by poll
    uint32_t cur_gen; // the ring the app must use (the last RING queued)
    uint32_t done_gen; // the highest gen the app gave back (RING_DONE)
    int has_latest;
    uint32_t latest_gen, latest_slot;
    uint64_t latest_seq, latest_tick;
    double latest_t; // received (ms)
    uint64_t rx, replaced, stale, rejected;
    double lat[PDF_LAT_N]; // received -> pi-desk's GPU frame that drew it completed (ms)
    int lat_n;
    uint64_t reclaimed; // local: an unshown frame's slot written again (its frame replaced)
    uint32_t latest_cw, latest_ch; // local: the latest frame's content size (px, from the slot's top-left)
    // Mach queue only
    mach_port_t peer; // send right to the app's reply port
    uint32_t peer_epoch; // the epoch whose HELLO gave it
    int hung; // a send timed out: nothing more is sent
    // main thread only
    pdf_ring_store rings[PDF_RINGS];
} pdf_chan;

static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static pdf_chan g_chans[PDF_CHANS];
static mach_port_t g_port;
static dispatch_queue_t g_q;
static dispatch_source_t g_src;
static char g_service[128];
static id<MTLDevice> g_device;
static atomic_int g_wake;
static int g_started;

typedef struct { uint64_t tab_id; uint32_t gen, slot; } pdf_retired;
static pdf_retired g_retired[256];
static int g_retired_n;
typedef struct { uint64_t tab_id; double t; } pdf_shown;
static pdf_shown g_shown[64];
static int g_shown_n;

// Test mode (pd_frames_test_track): every texture a GPU frame not completed
// yet samples, counted per frame that drew it; a producer handed one of them
// is a write into a texture the GPU may still read (g_inflight_writes).
// lag_ms holds back the completed handler's work (as a slow GPU would),
// before the in-flight set shrinks and before any RELEASE.
static int g_track, g_lag_ms;
typedef struct { void* tex; int n; } pdf_inflight;
static pdf_inflight g_inflight[64]; // under g_lock
static void* g_sampled[64]; // drawn by the frame being built (main thread)
static int g_sampled_n;
static uint64_t g_inflight_writes; // under g_lock

static pdf_chan* chan_by_tab(uint64_t tab_id) {
    for (int i = 0; i < PDF_CHANS; i++) if (g_chans[i].used && g_chans[i].tab_id == tab_id) return &g_chans[i];
    return NULL;
}

// Mach queue: a send that must arrive (RING, RELEASE). A timeout marks the
// app hung; a dead destination marks it dead. Returns the kern_return_t.
static kern_return_t q_send(pdf_chan* c, mach_msg_header_t* h) {
    if (c->hung || c->peer == MACH_PORT_NULL) {
        mach_msg_destroy(h);
        return KERN_FAILURE;
    }
    kern_return_t kr = mach_msg(h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, h->msgh_size, 0, MACH_PORT_NULL, PDF_SEND_TIMEOUT_MS, MACH_PORT_NULL);
    if (kr == KERN_SUCCESS) return kr;
    // not sent: the rights it carried came back (pseudo-receive) and are freed
    // here; any other error left the message as it was, so its descriptors'
    // moved rights are still ours (the header's copied right is not)
    // (the header's remote is COPY_SEND: its bits are kept for destroy only in the pseudo-receive case, cleared otherwise)
    if (kr != MACH_SEND_TIMED_OUT && kr != MACH_SEND_INVALID_DEST && kr != MACH_SEND_INTERRUPTED) h->msgh_bits &= MACH_MSGH_BITS_COMPLEX;
    mach_msg_destroy(h);
    os_unfair_lock_lock(&g_lock);
    if (kr == MACH_SEND_TIMED_OUT) c->flags |= PDF_F_STALLED;
    else c->flags |= PDF_F_DEAD;
    os_unfair_lock_unlock(&g_lock);
    c->hung = 1;
    atomic_store(&g_wake, 1);
    return kr;
}

static pdf_ring_store* ring_of(pdf_chan* c, uint32_t gen) {
    for (int r = 0; r < PDF_RINGS; r++) if (gen != 0 && c->rings[r].gen == gen) return &c->rings[r];
    return NULL;
}

// RELEASE on a local channel: the slot is the producer's again (any thread).
static void local_release(pdf_chan* c, uint32_t gen, uint32_t slot) {
    os_unfair_lock_lock(&g_lock);
    pdf_ring_store* r = slot < PDF_SLOTS ? ring_of(c, gen) : NULL;
    if (r && r->state[slot] == PDF_SLOT_PIDESK) r->state[slot] = PDF_SLOT_FREE;
    os_unfair_lock_unlock(&g_lock);
}

static void q_release(pdf_chan* c, uint32_t gen, uint32_t slot) {
    if (c->local) {
        local_release(c, gen, slot);
        return;
    }
    pdf_release m;
    pdf_fill(&m.h, sizeof m, c->peer, PDF_RELEASE);
    m.gen = gen;
    m.slot = slot;
    q_send(c, &m.h);
}

static void q_drop_peer(pdf_chan* c) {
    if (c->peer != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), c->peer);
    c->peer = MACH_PORT_NULL;
}

// Mach queue: drops a send right that an older epoch's HELLO gave.
static void q_drop_older(pdf_chan* c, uint64_t tab_id, uint32_t epoch) {
    os_unfair_lock_lock(&g_lock);
    int same = c->used && c->tab_id == tab_id;
    os_unfair_lock_unlock(&g_lock);
    if (same && c->peer_epoch != epoch) {
        q_drop_peer(c);
        c->hung = 1;
    }
}

static void q_hello(pdf_hello* m, mach_msg_audit_trailer_t* t) {
    mach_port_t reply = m->h.msgh_remote_port; // a send right (the app's MAKE_SEND)
    pid_t pid = audit_token_to_pid(t->msgh_audit);
    int spg = pid > 0 ? getpgid(pid) : -1, ssid = pid > 0 ? getsid(pid) : -1;
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(m->tab_id);
    if (c && c->local) c = NULL; // never an app's
    int ok = c && c->accepting && pd_frames_key_equal(c->key, m->key) && pd_frames_sender_in(spg, ssid, c->pgid, c->sid) && reply != MACH_PORT_NULL;
    uint32_t epoch = c ? c->epoch : 0; // the epoch this HELLO was accepted in (a stop may bump it after the unlock)
    if (c && !ok) {
        c->rejected++;
        c->flags |= PDF_F_REJECTED;
    }
    if (ok) {
        c->accepting = 0;
        c->flags |= PDF_F_CONNECTED;
        c->flags &= ~(uint32_t)(PDF_F_DEAD | PDF_F_STALLED);
        c->has_latest = 0;
    }
    os_unfair_lock_unlock(&g_lock);
    atomic_store(&g_wake, 1);
    if (!ok) {
        if (reply != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), reply);
        return;
    }
    q_drop_peer(c);
    c->peer = reply;
    c->peer_epoch = epoch; // Mach queue only
    c->hung = 0;
    mach_port_t prev = MACH_PORT_NULL;
    kern_return_t kr = mach_port_request_notification(mach_task_self(), reply, MACH_NOTIFY_DEAD_NAME, 1, g_port, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
    if (prev != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), prev);
    if (kr != KERN_SUCCESS) { // already dead
        os_unfair_lock_lock(&g_lock);
        c->flags |= PDF_F_DEAD;
        os_unfair_lock_unlock(&g_lock);
    }
}

// The sender (audit pid) belongs to the channel's process group or session.
// FRAME names no tab: the gen does (gens are unique across tabs and
// restarts), and the sender must be in that tab's group or session.
static void q_frame(pdf_frame* m, mach_msg_audit_trailer_t* t) {
    uint32_t rel = 0;
    int action = 0;
    pdf_chan* c = NULL;
    os_unfair_lock_lock(&g_lock);
    for (int i = 0; i < PDF_CHANS; i++) {
        pdf_chan* x = &g_chans[i];
        if (x->used && !x->local && x->cur_gen == m->gen && x->cur_gen != 0) { c = x; break; }
    }
    int pgid = c ? c->pgid : 0, sid = c ? c->sid : 0;
    os_unfair_lock_unlock(&g_lock);
    if (!c) return; // stale gen: dropped, never answered
    pid_t pid = audit_token_to_pid(t->msgh_audit);
    if (pid <= 0 || !pd_frames_sender_in(getpgid(pid), getsid(pid), pgid, sid)) return;
    os_unfair_lock_lock(&g_lock);
    action = c->cur_gen == m->gen ? pd_frames_on_frame(c->cur_gen, c->has_latest, c->latest_slot, m->gen, m->slot, &rel) : 0;
    if (action == 0) c->stale++;
    else {
        if (action == 2) c->replaced++;
        c->rx++;
        c->has_latest = 1;
        c->latest_gen = m->gen;
        c->latest_slot = m->slot;
        c->latest_seq = m->seq;
        c->latest_tick = m->tick;
        c->latest_t = pdf_now_ms();
    }
    os_unfair_lock_unlock(&g_lock);
    if (action == 2) q_release(c, m->gen, rel); // never shown: back at once
    if (action) atomic_store(&g_wake, 1);
}

static void q_ring_done(pdf_ring_done* m, mach_msg_audit_trailer_t* t) {
    pid_t pid = audit_token_to_pid(t->msgh_audit);
    int spg = pid > 0 ? getpgid(pid) : -1, ssid = pid > 0 ? getsid(pid) : -1;
    os_unfair_lock_lock(&g_lock);
    for (int i = 0; i < PDF_CHANS; i++) {
        pdf_chan* c = &g_chans[i];
        if (!c->used || !pd_frames_sender_in(spg, ssid, c->pgid, c->sid)) continue;
        if (m->gen != c->cur_gen && m->gen > c->done_gen && m->gen < c->cur_gen) c->done_gen = m->gen;
    }
    os_unfair_lock_unlock(&g_lock);
    atomic_store(&g_wake, 1);
}

static void q_dead(mach_dead_name_notification_t* n) {
    mach_port_t name = n->not_port;
    for (int i = 0; i < PDF_CHANS; i++) {
        pdf_chan* c = &g_chans[i];
        if (!c->used || c->peer != name) continue;
        os_unfair_lock_lock(&g_lock);
        c->flags |= PDF_F_DEAD;
        os_unfair_lock_unlock(&g_lock);
        q_drop_peer(c);
        c->hung = 1;
    }
    mach_port_deallocate(mach_task_self(), name); // the notification's own reference
    atomic_store(&g_wake, 1);
}

static void q_drain(void) {
    for (;;) {
        pdf_rcv r;
        memset(&r.m.h, 0, sizeof r.m.h);
        kern_return_t kr = mach_msg(&r.m.h, PDF_RCV_OPTS, 0, sizeof r, g_port, 0, MACH_PORT_NULL);
        if (kr == MACH_RCV_TOO_LARGE) continue; // dropped by the kernel (no MACH_RCV_LARGE)
        if (kr != KERN_SUCCESS) return;
        mach_msg_audit_trailer_t* t = (mach_msg_audit_trailer_t*)((uint8_t*)&r.m + round_msg(r.m.h.msgh_size));
        int complex = (r.m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
        uint32_t size = r.m.h.msgh_size;
        switch (r.m.h.msgh_id) {
        case PDF_HELLO:
            if (!complex && size == sizeof(pdf_hello)) { q_hello(&r.m.hello, t); continue; }
            break;
        case PDF_FRAME:
            if (!complex && size == sizeof(pdf_frame)) { q_frame(&r.m.frame, t); mach_msg_destroy(&r.m.h); continue; }
            break;
        case PDF_RING_DONE:
            if (!complex && size == sizeof(pdf_ring_done)) { q_ring_done(&r.m.done, t); mach_msg_destroy(&r.m.h); continue; }
            break;
        case MACH_NOTIFY_DEAD_NAME:
            // only the kernel sends notifications (audit pid 0)
            if (!complex && audit_token_to_pid(t->msgh_audit) == 0 && size >= sizeof(mach_dead_name_notification_t) - sizeof(mach_msg_format_0_trailer_t)) { q_dead(&r.m.dead); continue; }
            break;
        }
        mach_msg_destroy(&r.m.h); // anything else: its rights are freed, nothing is answered
    }
}

// Checks in "dev.pi-desk.frames.<pid>" once per process and starts the queue.
// mtl_device: sokol's MTLDevice (the app must render on the same GPU).
int pd_frames_serve_start(void* mtl_device) {
    if (g_started) return g_started > 0;
    g_started = -1;
    g_device = (__bridge id<MTLDevice>)mtl_device;
    snprintf(g_service, sizeof g_service, "dev.pi-desk.frames.%d", getpid());
    kern_return_t kr = bootstrap_check_in(bootstrap_port, g_service, &g_port);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "pi-desk: frames: bootstrap_check_in(%s) = %d (%s)\n", g_service, kr, bootstrap_strerror(kr));
        return 0;
    }
    mach_port_limits_t lim = {.mpl_qlimit = PDF_QLIMIT_SERVE};
    kr = mach_port_set_attributes(mach_task_self(), g_port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&lim, MACH_PORT_LIMITS_INFO_COUNT);
    if (kr != KERN_SUCCESS) fprintf(stderr, "pi-desk: frames: queue limit not raised (%d)\n", kr);
    if (!g_q) g_q = dispatch_queue_create("dev.pi-desk.frames", DISPATCH_QUEUE_SERIAL);
    g_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, g_port, 0, g_q);
    dispatch_source_set_event_handler(g_src, ^{ q_drain(); });
    dispatch_resume(g_src);
    g_started = 1;
    return 1;
}

const char* pd_frames_service(void) { return g_service; }
uint64_t pd_frames_device_id(void) { return g_device ? g_device.registryID : 0; }
int pd_frames_qlimit(void) {
    mach_port_limits_t lim = {0};
    mach_msg_type_number_t n = MACH_PORT_LIMITS_INFO_COUNT;
    if (mach_port_get_attributes(mach_task_self(), g_port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&lim, &n) != KERN_SUCCESS) return -1;
    return (int)lim.mpl_qlimit;
}

// Something arrived since the last call (any thread set it; the frame loop reads it).
int pd_frames_take_wake(void) { return atomic_exchange(&g_wake, 0); }

// A channel for a tab (new, or reset for a restarted process): HELLO is
// accepted once, from pgid's group or sid's session, with key. Rings stay
// (the last frame shows until the new process draws).
int pd_frames_chan_open(uint64_t tab_id, const uint8_t* key, int pgid, int sid) {
    if (!g_started) return 0;
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    if (!c) for (int i = 0; i < PDF_CHANS; i++) if (!g_chans[i].used && !g_chans[i].draining) { c = &g_chans[i]; memset(c, 0, sizeof *c); break; }
    if (c) {
        c->used = 1;
        c->tab_id = tab_id;
        memcpy(c->key, key, 32);
        c->pgid = pgid;
        c->sid = sid;
        c->accepting = 1;
        c->flags = 0;
        c->cur_gen = 0; // nothing from the old process counts any more
        c->has_latest = 0;
        c->epoch++;
    }
    uint32_t epoch = c ? c->epoch : 0;
    os_unfair_lock_unlock(&g_lock);
    if (!c) return 0;
    dispatch_async(g_q, ^{ q_drop_older(c, tab_id, epoch); });
    return 1;
}

// The process the channel belongs to, once spawned (HELLO, FRAME and
// RING_DONE must come from its group or session; 0 matches nothing).
void pd_frames_chan_set_proc(uint64_t tab_id, int pgid, int sid) {
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    if (c) {
        c->pgid = pgid;
        c->sid = sid;
    }
    os_unfair_lock_unlock(&g_lock);
}

// The key of a tab's channel (for the hello reply; any thread). 1 if found.
int pd_frames_chan_key(uint64_t tab_id, uint8_t* out) {
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    if (c) memcpy(out, c->key, 32);
    os_unfair_lock_unlock(&g_lock);
    return c != NULL;
}

// The app is gone (exited, or the tab closes): no more HELLO, its send right
// is dropped, nothing more is sent. Rings stay until freed.
void pd_frames_chan_stop(uint64_t tab_id) {
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    if (c) {
        c->accepting = 0;
        memset(c->key, 0, 32);
        c->cur_gen = 0;
        c->has_latest = 0;
        c->epoch++;
    }
    uint32_t epoch = c ? c->epoch : 0;
    os_unfair_lock_unlock(&g_lock);
    if (c) dispatch_async(g_q, ^{ q_drop_older(c, tab_id, epoch); });
}

// The store is emptied under g_lock (a local channel's RELEASE reads it from
// the Mach queue); the objects are released after the unlock.
static void ring_store_free(pdf_ring_store* r, int keep_slot) {
    void* gone[2 * PDF_SLOTS];
    int n = 0;
    os_unfair_lock_lock(&g_lock);
    for (int s = 0; s < PDF_SLOTS; s++) {
        if (s == keep_slot) continue;
        if (r->tex[s]) gone[n++] = r->tex[s];
        if (r->surf[s]) gone[n++] = (void*)r->surf[s];
        r->tex[s] = NULL;
        r->surf[s] = NULL;
    }
    if (keep_slot < 0) memset(r, 0, sizeof *r);
    os_unfair_lock_unlock(&g_lock);
    for (int i = 0; i < n; i++) CFRelease(gone[i]);
}

// Frees a ring's surfaces (main thread): all, or all but keep_slot (the
// dimmed last frame of an app that died). Callers have destroyed their
// sokol images of it first.
void pd_frames_ring_free(uint64_t tab_id, uint32_t gen, int keep_slot) {
    pdf_chan* c = chan_by_tab(tab_id);
    if (!c) return;
    for (int r = 0; r < PDF_RINGS; r++) if (c->rings[r].gen == gen) ring_store_free(&c->rings[r], keep_slot);
}

// The tab is closed: everything goes (main thread). The send right goes on
// the Mach queue, keyed to the close itself (not to `used`, which is 0 by
// then); the slot is reused only after that.
void pd_frames_chan_close(uint64_t tab_id) {
    pdf_chan* c = chan_by_tab(tab_id);
    if (!c) return;
    for (int r = 0; r < PDF_RINGS; r++) ring_store_free(&c->rings[r], -1);
    os_unfair_lock_lock(&g_lock);
    c->accepting = 0;
    memset(c->key, 0, 32);
    c->cur_gen = 0;
    c->has_latest = 0;
    c->epoch++;
    c->used = 0;
    c->draining = 1;
    os_unfair_lock_unlock(&g_lock);
    dispatch_async(g_q, ^{
        q_drop_peer(c); // no HELLO can set a new one: the channel is not used
        c->hung = 1;
        os_unfair_lock_lock(&g_lock);
        c->draining = 0;
        os_unfair_lock_unlock(&g_lock);
    });
}

static IOSurfaceRef make_surface(int w, int h) {
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * 4);
    size_t size = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr * (size_t)h);
    NSDictionary* p = @{
        (id)kIOSurfaceWidth: @(w),
        (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(bpr),
        (id)kIOSurfaceAllocSize: @(size),
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)p);
}

// A new ring (gen+1) of 3 BGRA8 surfaces, w x h px, wrapped as textures
// pi-desk samples; RING goes to the app from the Mach queue. Main thread.
// Returns the new gen (0 = failed: no channel, no room, no surfaces).
uint32_t pd_frames_ring_new(uint64_t tab_id, int w, int h, float scale) {
    pdf_chan* c = chan_by_tab(tab_id);
    if (!c || w <= 0 || h <= 0 || !g_device) return 0;
    pdf_ring_store* slot = NULL;
    uint32_t top = 0;
    for (int r = 0; r < PDF_RINGS; r++) if (c->rings[r].gen > top) top = c->rings[r].gen;
    for (int r = 0; r < PDF_RINGS; r++) if (c->rings[r].gen == 0 && !c->rings[r].surf[0] && !c->rings[r].surf[1] && !c->rings[r].surf[2]) { slot = &c->rings[r]; break; }
    if (!slot) return 0;
    static uint32_t next_gen; // rising across tabs and restarts: a stale FRAME never matches
    next_gen = (next_gen > top ? next_gen : top) + 1;
    uint32_t gen = next_gen;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = g_device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
    for (int s = 0; s < PDF_SLOTS; s++) {
        slot->surf[s] = make_surface(w, h);
        id<MTLTexture> t = slot->surf[s] ? [g_device newTextureWithDescriptor:d iosurface:slot->surf[s] plane:0] : nil;
        if (!t) {
            ring_store_free(slot, -1);
            return 0;
        }
        slot->tex[s] = (void*)CFBridgingRetain(t);
    }
    os_unfair_lock_lock(&g_lock);
    slot->gen = gen;
    slot->w = w;
    slot->h = h;
    slot->scale = scale;
    for (int s = 0; s < PDF_SLOTS; s++) slot->state[s] = PDF_SLOT_FREE;
    c->cur_gen = gen;
    c->has_latest = 0; // a frame of the old ring waiting unshown is stale now
    uint32_t epoch = c->epoch;
    int local = c->local;
    os_unfair_lock_unlock(&g_lock);
    if (local) return gen; // the producer takes it at its next acquire (no RING, no RING_DONE)
    struct { IOSurfaceRef s[PDF_SLOTS]; } surf; // (blocks capture structs, not arrays)
    for (int s = 0; s < PDF_SLOTS; s++) surf.s[s] = (IOSurfaceRef)CFRetain(slot->surf[s]);
    dispatch_async(g_q, ^{
        os_unfair_lock_lock(&g_lock);
        int same = c->used && c->tab_id == tab_id && c->epoch == epoch && c->peer_epoch == epoch;
        os_unfair_lock_unlock(&g_lock);
        if (!same) {
            for (int s = 0; s < PDF_SLOTS; s++) CFRelease(surf.s[s]);
            return;
        }
        pdf_ring m;
        pdf_fill(&m.h, sizeof m, c->peer, PDF_RING);
        m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
        m.body.msgh_descriptor_count = PDF_SLOTS;
        for (int s = 0; s < PDF_SLOTS; s++) {
            m.ports[s].name = IOSurfaceCreateMachPort(surf.s[s]);
            m.ports[s].disposition = MACH_MSG_TYPE_MOVE_SEND;
            m.ports[s].type = MACH_MSG_PORT_DESCRIPTOR;
            CFRelease(surf.s[s]);
        }
        m.gen = gen;
        m.count = PDF_SLOTS;
        m.w = (uint32_t)w;
        m.hgt = (uint32_t)h;
        m.scale = scale;
        m.pixel_format = 'BGRA';
        q_send(c, &m.h);
    });
    return gen;
}

// The texture of a ring slot (an unretained id<MTLTexture>) for sokol, or NULL.
void* pd_frames_slot_texture(uint64_t tab_id, uint32_t gen, int slot) {
    pdf_chan* c = chan_by_tab(tab_id);
    if (!c || slot < 0 || slot >= PDF_SLOTS) return NULL;
    for (int r = 0; r < PDF_RINGS; r++) if (c->rings[r].gen == gen) return c->rings[r].tex[slot];
    return NULL;
}

// What arrived for a tab since the last poll (main thread, each frame).
typedef struct {
    uint32_t flags; // PDF_F_*
    int has_frame;
    uint32_t gen, slot;
    uint64_t seq, tick;
    double recv_ms;
    uint32_t cur_gen, done_gen;
    uint64_t rx, replaced, stale, rejected;
    uint32_t content_w, content_h; // local channels: the frame's size in the slot (px)
} pd_frames_poll_t;

int pd_frames_poll(uint64_t tab_id, pd_frames_poll_t* out) {
    memset(out, 0, sizeof *out);
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    if (c) {
        out->flags = c->flags;
        c->flags &= PDF_F_DEAD | PDF_F_STALLED; // these stay until the next HELLO
        if (c->has_latest && c->latest_gen == c->cur_gen) {
            out->has_frame = 1;
            out->gen = c->latest_gen;
            out->slot = c->latest_slot;
            out->seq = c->latest_seq;
            out->tick = c->latest_tick;
            out->recv_ms = c->latest_t;
            out->content_w = c->latest_cw;
            out->content_h = c->latest_ch;
        }
        c->has_latest = 0;
        out->cur_gen = c->cur_gen;
        out->done_gen = c->done_gen;
        out->rx = c->rx;
        out->replaced = c->replaced;
        out->stale = c->stale;
        out->rejected = c->rejected;
    }
    os_unfair_lock_unlock(&g_lock);
    return c != NULL;
}

// A slot pi-desk took but never drew (its tab is hidden): back at once.
void pd_frames_release_now(uint64_t tab_id, uint32_t gen, uint32_t slot) {
    if (!g_q) return;
    dispatch_async(g_q, ^{
        os_unfair_lock_lock(&g_lock);
        pdf_chan* c = chan_by_tab(tab_id);
        int ok = c && c->cur_gen == gen;
        os_unfair_lock_unlock(&g_lock);
        if (ok) q_release(c, gen, slot);
    });
}

// The frame being drawn no longer samples this slot (a newer frame replaced
// it): it goes back after this frame's GPU work completes.
void pd_frames_retire(uint64_t tab_id, uint32_t gen, uint32_t slot) {
    if (g_retired_n < (int)(sizeof g_retired / sizeof g_retired[0])) g_retired[g_retired_n++] = (pdf_retired){tab_id, gen, slot};
}

// The frame being drawn shows a new frame received at recv_ms (latency).
void pd_frames_shown(uint64_t tab_id, double recv_ms) {
    if (g_shown_n < (int)(sizeof g_shown / sizeof g_shown[0])) g_shown[g_shown_n++] = (pdf_shown){tab_id, recv_ms};
}

static void inflight_add(void* t) { // under g_lock
    int free_i = -1;
    for (int i = 0; i < 64; i++) {
        if (g_inflight[i].tex == t) { g_inflight[i].n++; return; }
        if (!g_inflight[i].tex && free_i < 0) free_i = i;
    }
    if (free_i >= 0) g_inflight[free_i] = (pdf_inflight){t, 1};
}

static void inflight_remove(void* t) { // under g_lock
    for (int i = 0; i < 64; i++) if (g_inflight[i].tex == t && --g_inflight[i].n <= 0) g_inflight[i] = (pdf_inflight){0};
}

static int inflight_has(void* t) { // under g_lock
    for (int i = 0; i < 64; i++) if (g_inflight[i].tex == t && g_inflight[i].n > 0) return 1;
    return 0;
}

void pd_frames_test_track(int on, int lag_ms) {
    g_track = on;
    g_lag_ms = lag_ms > 0 ? lag_ms : 0;
}

// The frame being built samples this slot texture (test mode; main thread).
void pd_frames_sampled(void* tex) {
    if (g_track && tex && g_sampled_n < 64) g_sampled[g_sampled_n++] = tex;
}

uint64_t pd_frames_inflight_writes(void) {
    os_unfair_lock_lock(&g_lock);
    uint64_t n = g_inflight_writes;
    os_unfair_lock_unlock(&g_lock);
    return n;
}

// After sg_commit (main thread): if anything retired or was shown, one empty
// command buffer on sokol's queue; its completed handler fires after this
// frame's work on that queue (empirically ordered: ENGINE-BRIDGE §2.3) and
// posts the RELEASEs to the Mach queue.
void pd_frames_committed(void* mtl_queue) {
    if ((g_retired_n == 0 && g_shown_n == 0 && g_sampled_n == 0) || !mtl_queue || !g_q) {
        g_sampled_n = 0;
        return;
    }
    int nq = g_sampled_n;
    void** qs = malloc(sizeof(void*) * (nq ? nq : 1));
    memcpy(qs, g_sampled, sizeof(void*) * nq);
    g_sampled_n = 0;
    os_unfair_lock_lock(&g_lock);
    for (int i = 0; i < nq; i++) inflight_add(qs[i]);
    os_unfair_lock_unlock(&g_lock);
    int nr = g_retired_n, ns = g_shown_n;
    pdf_retired* rs = malloc(sizeof(pdf_retired) * (nr ? nr : 1));
    pdf_shown* ss = malloc(sizeof(pdf_shown) * (ns ? ns : 1));
    memcpy(rs, g_retired, sizeof(pdf_retired) * nr);
    memcpy(ss, g_shown, sizeof(pdf_shown) * ns);
    g_retired_n = g_shown_n = 0;
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)mtl_queue;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    int lag = g_lag_ms;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
        double now = pdf_now_ms();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)lag * NSEC_PER_MSEC), g_q, ^{
            // the frame's GPU work is done: it samples nothing any more (before any RELEASE)
            os_unfair_lock_lock(&g_lock);
            for (int i = 0; i < nq; i++) inflight_remove(qs[i]);
            os_unfair_lock_unlock(&g_lock);
            free(qs);
            for (int i = 0; i < ns; i++) {
                os_unfair_lock_lock(&g_lock);
                pdf_chan* c = chan_by_tab(ss[i].tab_id);
                if (c) c->lat[c->lat_n++ % PDF_LAT_N] = now - ss[i].t;
                os_unfair_lock_unlock(&g_lock);
            }
            for (int i = 0; i < nr; i++) {
                os_unfair_lock_lock(&g_lock);
                pdf_chan* c = chan_by_tab(rs[i].tab_id);
                int ok = c && c->cur_gen == rs[i].gen; // an old ring's slots came back with RING_DONE
                os_unfair_lock_unlock(&g_lock);
                if (ok) q_release(c, rs[i].gen, rs[i].slot);
            }
            free(rs);
            free(ss);
        });
    }];
    [cb commit];
}

// Latency samples (ms, oldest first is not kept): copies up to cap, returns the count.
int pd_frames_latency(uint64_t tab_id, double* out, int cap) {
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    int n = 0;
    if (c) {
        n = c->lat_n < PDF_LAT_N ? c->lat_n : PDF_LAT_N;
        if (n > cap) n = cap;
        memcpy(out, c->lat, sizeof(double) * n);
    }
    os_unfair_lock_unlock(&g_lock);
    return n;
}

// One pixel of a ring slot at framebuffer px (x, y), as 0xRRGGBB (tests,
// later tab.capture). Safe while pi-desk holds the slot. 1 if read.
int pd_frames_pixel(uint64_t tab_id, uint32_t gen, int slot, int x, int y, uint32_t* rgb) {
    pdf_chan* c = chan_by_tab(tab_id);
    if (!c || slot < 0 || slot >= PDF_SLOTS) return 0;
    for (int r = 0; r < PDF_RINGS; r++) {
        pdf_ring_store* rs = &c->rings[r];
        if (rs->gen != gen || !rs->surf[slot]) continue;
        IOSurfaceRef s = rs->surf[slot];
        if (x < 0 || y < 0 || x >= (int)IOSurfaceGetWidth(s) || y >= (int)IOSurfaceGetHeight(s)) return 0;
        IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
        uint8_t* p = (uint8_t*)IOSurfaceGetBaseAddress(s) + (size_t)y * IOSurfaceGetBytesPerRow(s) + (size_t)x * 4;
        *rgb = ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
        return 1;
    }
    return 0;
}

// A rect of a ring slot (framebuffer px, inside the surface) into dst as
// BGRA rows of w*4 bytes (app_screenshot). Main thread; safe while pi-desk
// holds the slot (the shown one, until a newer frame replaces it). 1 if read.
int pd_frames_read(uint64_t tab_id, uint32_t gen, int slot, int x, int y, int w, int h, uint8_t* dst) {
    pdf_chan* c = chan_by_tab(tab_id);
    if (!c || slot < 0 || slot >= PDF_SLOTS || w <= 0 || h <= 0 || x < 0 || y < 0) return 0;
    for (int r = 0; r < PDF_RINGS; r++) {
        pdf_ring_store* rs = &c->rings[r];
        if (rs->gen != gen || !rs->surf[slot]) continue;
        IOSurfaceRef s = rs->surf[slot];
        if (x + w > (int)IOSurfaceGetWidth(s) || y + h > (int)IOSurfaceGetHeight(s)) return 0;
        IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
        size_t bpr = IOSurfaceGetBytesPerRow(s);
        const uint8_t* base = (const uint8_t*)IOSurfaceGetBaseAddress(s);
        for (int row = 0; row < h; row++) memcpy(dst + (size_t)row * w * 4, base + (size_t)(y + row) * bpr + (size_t)x * 4, (size_t)w * 4);
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
        return 1;
    }
    return 0;
}

// Surfaces alive for a tab (tests: old rings are freed).
int pd_frames_surface_count(uint64_t tab_id) {
    pdf_chan* c = chan_by_tab(tab_id);
    int n = 0;
    if (c) for (int r = 0; r < PDF_RINGS; r++) for (int s = 0; s < PDF_SLOTS; s++) n += c->rings[r].surf[s] != NULL;
    return n;
}

static int surface_total(int local) {
    int n = 0;
    os_unfair_lock_lock(&g_lock);
    for (int i = 0; i < PDF_CHANS; i++) {
        if (g_chans[i].local != local) continue;
        for (int r = 0; r < PDF_RINGS; r++) for (int s = 0; s < PDF_SLOTS; s++) n += g_chans[i].rings[r].surf[s] != NULL;
    }
    os_unfair_lock_unlock(&g_lock);
    return n;
}

// Surfaces alive in every app channel (tests: all freed once the app tabs closed).
int pd_frames_surface_total(void) { return surface_total(0); }

// Surfaces alive in every local channel (tests: all freed once the browser tabs closed).
int pd_frames_surface_total_local(void) { return surface_total(1); }

// Bytes of a tab's surfaces (IOSurface allocations; stats).
uint64_t pd_frames_surface_bytes(uint64_t tab_id) {
    pdf_chan* c = chan_by_tab(tab_id);
    uint64_t n = 0;
    if (c) for (int r = 0; r < PDF_RINGS; r++) for (int s = 0; s < PDF_SLOTS; s++) if (c->rings[r].surf[s]) n += IOSurfaceGetAllocSize(c->rings[r].surf[s]);
    return n;
}

// Send rights to apps the Mach queue still holds, in any channel slot, used
// or not (tests: none once the app tabs closed).
int pd_frames_peers(void) {
    if (!g_q) return 0;
    __block int n = 0;
    dispatch_sync(g_q, ^{
        for (int i = 0; i < PDF_CHANS; i++) n += g_chans[i].peer != MACH_PORT_NULL;
    });
    return n;
}

// ---- local channels (an in-process producer: browser tabs) ----

// A local channel for a tab (main thread): rings as for an app, the producer
// is this process. mtl_device: sokol's. 1 = open.
int pd_frames_local_open(uint64_t tab_id, void* mtl_device) {
    if (!g_device) g_device = (__bridge id<MTLDevice>)mtl_device;
    if (!g_q) g_q = dispatch_queue_create("dev.pi-desk.frames", DISPATCH_QUEUE_SERIAL);
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    if (c && !c->local) c = NULL; // an app's tab id: never
    else if (!c) for (int i = 0; i < PDF_CHANS; i++) if (!g_chans[i].used && !g_chans[i].draining) { c = &g_chans[i]; memset(c, 0, sizeof *c); break; }
    if (c) {
        c->used = 1;
        c->local = 1;
        c->tab_id = tab_id;
        c->hung = 1; // nothing is ever sent over Mach
    }
    os_unfair_lock_unlock(&g_lock);
    return c != NULL;
}

// The producer wants a slot of the current ring to write a w x h px frame
// into, at its top-left (the ring may be larger: headroom). Main thread. 1: *gen, *slot, *texture (id<MTLTexture>, borrowed) and
// *surface (borrowed) are its, until pd_frames_local_frame or _unacquire.
// A free slot first; else the slot of a frame pi-desk has not taken yet
// (never drawn: its frame is dropped for this one). 0: no ring of that size
// (or larger: make one with pd_frames_ring_new, then ask again). -1: every slot is
// pi-desk's (on screen, or drawn by a frame whose GPU work runs): drop the
// frame. -2: no such local channel.
int pd_frames_local_acquire(uint64_t tab_id, int w, int h, uint32_t* gen, int* slot, void** texture, IOSurfaceRef* surface) {
    int ret = -2;
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    if (c && c->local) {
        pdf_ring_store* r = ring_of(c, c->cur_gen);
        ret = 0;
        if (r && w <= r->w && h <= r->h && r->surf[0]) {
            int got = -1;
            for (int s = 0; s < PDF_SLOTS && got < 0; s++) if (r->state[s] == PDF_SLOT_FREE) got = s;
            if (got < 0 && c->has_latest && c->latest_gen == r->gen && r->state[c->latest_slot] == PDF_SLOT_PIDESK) {
                got = (int)c->latest_slot;
                c->has_latest = 0;
                c->reclaimed++;
            }
            ret = -1;
            if (got >= 0) {
                if (g_track && inflight_has(r->tex[got])) g_inflight_writes++; // a bug: the GPU may still read it
                r->state[got] = PDF_SLOT_WRITING;
                *gen = r->gen;
                *slot = got;
                *texture = r->tex[got];
                *surface = r->surf[got];
                ret = 1;
            }
        }
    }
    os_unfair_lock_unlock(&g_lock);
    return ret;
}

// The producer could not write the slot it acquired: it is free again.
void pd_frames_local_unacquire(uint64_t tab_id, uint32_t gen, int slot) {
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    pdf_ring_store* r = c && c->local && slot >= 0 && slot < PDF_SLOTS ? ring_of(c, gen) : NULL;
    if (r && r->state[slot] == PDF_SLOT_WRITING) r->state[slot] = PDF_SLOT_FREE;
    os_unfair_lock_unlock(&g_lock);
}

// FRAME, in process: the slot holds a finished w x h px frame at its
// top-left (its GPU writes have completed). It is pi-desk's now; the frame loop takes it at its next poll.
// An older frame waiting unshown is replaced and its slot freed at once (it
// was never drawn). 1 = taken.
int pd_frames_local_frame(uint64_t tab_id, uint32_t gen, int slot, uint64_t seq, int w, int h) {
    int action = 0;
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    pdf_ring_store* r = c && c->local && slot >= 0 && slot < PDF_SLOTS ? ring_of(c, gen) : NULL;
    if (r && r->state[slot] == PDF_SLOT_WRITING) {
        uint32_t rel = 0;
        action = pd_frames_on_frame(c->cur_gen, c->has_latest, c->latest_slot, gen, (uint32_t)slot, &rel);
        if (action == 0) {
            c->stale++;
            r->state[slot] = PDF_SLOT_FREE;
        } else {
            if (action == 2) {
                c->replaced++;
                if (r->state[rel] == PDF_SLOT_PIDESK) r->state[rel] = PDF_SLOT_FREE;
            }
            r->state[slot] = PDF_SLOT_PIDESK;
            c->rx++;
            c->has_latest = 1;
            c->latest_gen = gen;
            c->latest_slot = (uint32_t)slot;
            c->latest_seq = seq;
            c->latest_tick = 0;
            c->latest_cw = (uint32_t)w;
            c->latest_ch = (uint32_t)h;
            c->latest_t = pdf_now_ms();
        }
    }
    os_unfair_lock_unlock(&g_lock);
    if (action) atomic_store(&g_wake, 1);
    return action != 0;
}

// A local slot's state (PDF_SLOT_*; -1: no such slot). Tests.
int pd_frames_local_slot_state(uint64_t tab_id, uint32_t gen, int slot) {
    int st = -1;
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    pdf_ring_store* r = c && c->local && slot >= 0 && slot < PDF_SLOTS ? ring_of(c, gen) : NULL;
    if (r && r->surf[slot]) st = r->state[slot];
    os_unfair_lock_unlock(&g_lock);
    return st;
}

// Local channels open or still draining after a close (tests: none once the browser tabs closed).
int pd_frames_local_chans(void) {
    int n = 0;
    os_unfair_lock_lock(&g_lock);
    for (int i = 0; i < PDF_CHANS; i++) n += g_chans[i].local && (g_chans[i].used || g_chans[i].draining);
    os_unfair_lock_unlock(&g_lock);
    return n;
}

uint64_t pd_frames_local_reclaimed(uint64_t tab_id) {
    os_unfair_lock_lock(&g_lock);
    pdf_chan* c = chan_by_tab(tab_id);
    uint64_t n = c ? c->reclaimed : 0;
    os_unfair_lock_unlock(&g_lock);
    return n;
}

// ======================================================================
// connect half (the app)
// ======================================================================

typedef struct pd_frames_conn {
    mach_port_t server, reply;
    dispatch_queue_t q;
    dispatch_source_t src;
    int suspended;
    os_unfair_lock lock;
    id<MTLDevice> device;
    // under lock
    uint32_t gen; // the ring in use (0 = none yet)
    int w, h;
    float scale;
    id<MTLTexture> tex[PDF_SLOTS];
    int state[PDF_SLOTS]; // 0 = the app's and free, 1 = being rendered, 2 = pi-desk's (FRAME sent)
    // a RING that arrived: adopted at the next frame boundary
    int pending;
    uint32_t p_gen;
    int p_w, p_h;
    float p_scale;
    id<MTLTexture> p_tex[PDF_SLOTS];
    int dead;
    uint64_t frames_sent, frames_dropped, rings;
} pd_frames_conn;

static void conn_ring(pd_frames_conn* c, pdf_ring* m) {
    id<MTLTexture> t[PDF_SLOTS] = {nil};
    int ok = m->count == PDF_SLOTS && m->body.msgh_descriptor_count == PDF_SLOTS && m->w > 0 && m->hgt > 0;
    for (int s = 0; ok && s < PDF_SLOTS; s++) {
        IOSurfaceRef surf = IOSurfaceLookupFromMachPort(m->ports[s].name);
        if (!surf) { ok = 0; break; }
        MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:m->w height:m->hgt mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = c->device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
        t[s] = [c->device newTextureWithDescriptor:d iosurface:surf plane:0];
        CFRelease(surf);
        if (!t[s]) ok = 0;
    }
    mach_msg_destroy(&m->h); // the port rights (the textures keep the surfaces)
    if (!ok) return;
    os_unfair_lock_lock(&c->lock);
    c->pending = 1;
    c->p_gen = m->gen;
    c->p_w = (int)m->w;
    c->p_h = (int)m->hgt;
    c->p_scale = m->scale;
    for (int s = 0; s < PDF_SLOTS; s++) c->p_tex[s] = t[s];
    c->rings++;
    os_unfair_lock_unlock(&c->lock);
}

static void conn_drain(pd_frames_conn* c) {
    for (;;) {
        pdf_rcv r;
        memset(&r.m.h, 0, sizeof r.m.h);
        kern_return_t kr = mach_msg(&r.m.h, PDF_RCV_OPTS, 0, sizeof r, c->reply, 0, MACH_PORT_NULL);
        if (kr == MACH_RCV_TOO_LARGE) continue;
        if (kr != KERN_SUCCESS) return;
        mach_msg_audit_trailer_t* t = (mach_msg_audit_trailer_t*)((uint8_t*)&r.m + round_msg(r.m.h.msgh_size));
        int complex = (r.m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
        switch (r.m.h.msgh_id) {
        case PDF_RING:
            if (complex && r.m.h.msgh_size == sizeof(pdf_ring)) { conn_ring(c, &r.m.ring); continue; }
            break;
        case PDF_RELEASE:
            if (!complex && r.m.h.msgh_size == sizeof(pdf_release)) {
                os_unfair_lock_lock(&c->lock);
                if (r.m.release.gen == c->gen && r.m.release.slot < PDF_SLOTS && c->state[r.m.release.slot] == 2) c->state[r.m.release.slot] = 0;
                os_unfair_lock_unlock(&c->lock);
            }
            break;
        case MACH_NOTIFY_DEAD_NAME:
            if (!complex && audit_token_to_pid(t->msgh_audit) == 0) {
                os_unfair_lock_lock(&c->lock);
                c->dead = 1;
                os_unfair_lock_unlock(&c->lock);
                mach_port_deallocate(mach_task_self(), r.m.dead.not_port);
                continue;
            }
            break;
        }
        mach_msg_destroy(&r.m.h);
    }
}

// Looks the service up, sends HELLO {key, tab_id} with a reply port (queue
// limit 64), and starts draining it. NULL on failure (err says why).
pd_frames_conn* pd_frames_connect(const char* service, const uint8_t* key, uint64_t tab_id, void* mtl_device, char* err, int errcap) {
    pd_frames_conn* c = calloc(1, sizeof *c);
    c->lock = OS_UNFAIR_LOCK_INIT;
    c->device = (__bridge id<MTLDevice>)mtl_device;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, service, &c->server);
    if (kr != KERN_SUCCESS) {
        snprintf(err, errcap, "bootstrap_look_up(%s) = %d (%s)", service, kr, bootstrap_strerror(kr));
        free(c);
        return NULL;
    }
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &c->reply);
    mach_port_limits_t lim = {.mpl_qlimit = PDF_QLIMIT_APP};
    mach_port_set_attributes(mach_task_self(), c->reply, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&lim, MACH_PORT_LIMITS_INFO_COUNT);
    mach_port_t prev = MACH_PORT_NULL;
    mach_port_request_notification(mach_task_self(), c->server, MACH_NOTIFY_DEAD_NAME, 1, c->reply, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
    c->q = dispatch_queue_create("dev.pi-desk.frames.app", DISPATCH_QUEUE_SERIAL);
    c->src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, c->reply, 0, c->q);
    dispatch_source_set_event_handler(c->src, ^{ conn_drain(c); });
    dispatch_resume(c->src);
    pdf_hello m;
    pdf_fill(&m.h, sizeof m, c->server, PDF_HELLO);
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND);
    m.h.msgh_local_port = c->reply;
    memcpy(m.key, key, 32);
    m.tab_id = tab_id;
    kr = mach_msg(&m.h, MACH_SEND_MSG, sizeof m, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        snprintf(err, errcap, "HELLO send = %d", kr);
        return c; // dead or refused: the caller sees no RING
    }
    return c;
}

// Stops (or resumes) reading the reply port: a hung app (tests).
void pd_frames_conn_suspend(pd_frames_conn* c, int on) {
    if (on && !c->suspended) dispatch_suspend(c->src);
    if (!on && c->suspended) dispatch_resume(c->src);
    c->suspended = on;
}

int pd_frames_conn_dead(pd_frames_conn* c) {
    os_unfair_lock_lock(&c->lock);
    int d = c->dead;
    os_unfair_lock_unlock(&c->lock);
    return d;
}

// A slot to render into this frame. At the frame boundary a RING that came
// is adopted (RING_DONE {old gen} goes back first). Returns 0 when no slot
// is held (skip rendering; keep ticking).
int pd_frames_acquire(pd_frames_conn* c, uint32_t* gen, int* slot, int* w, int* h, float* scale, void** texture) {
    uint32_t done = 0;
    os_unfair_lock_lock(&c->lock);
    if (c->pending) {
        done = c->gen;
        c->gen = c->p_gen;
        c->w = c->p_w;
        c->h = c->p_h;
        c->scale = c->p_scale;
        for (int s = 0; s < PDF_SLOTS; s++) {
            c->tex[s] = c->p_tex[s];
            c->p_tex[s] = nil;
            c->state[s] = 0;
        }
        c->pending = 0;
    }
    int got = -1;
    if (c->gen) for (int s = 0; s < PDF_SLOTS; s++) if (c->state[s] == 0) { got = s; break; }
    if (got >= 0) {
        c->state[got] = 1;
        *gen = c->gen;
        *slot = got;
        *w = c->w;
        *h = c->h;
        *scale = c->scale;
        *texture = (__bridge void*)c->tex[got];
    }
    os_unfair_lock_unlock(&c->lock);
    if (done) {
        pdf_ring_done m;
        pdf_fill(&m.h, sizeof m, c->server, PDF_RING_DONE);
        m.gen = done;
        mach_msg(&m.h, MACH_SEND_MSG, sizeof m, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
    return got >= 0;
}

// Gives a slot back without a frame (rendering was skipped).
void pd_frames_unacquire(pd_frames_conn* c, int slot) {
    os_unfair_lock_lock(&c->lock);
    if (slot >= 0 && slot < PDF_SLOTS && c->state[slot] == 1) c->state[slot] = 0;
    os_unfair_lock_unlock(&c->lock);
}

// After the frame's command buffers were committed on mtl_queue: one empty
// command buffer whose completed handler sends FRAME (0 timeout: dropped
// if pi-desk's queue is full; then the slot is the app's again at once).
void pd_frames_present(pd_frames_conn* c, uint32_t gen, int slot, uint64_t seq, uint64_t tick, void* mtl_queue) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)mtl_queue;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    mach_port_t server = c->server;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
        pdf_frame m;
        pdf_fill(&m.h, sizeof m, server, PDF_FRAME);
        m.gen = gen;
        m.slot = (uint32_t)slot;
        m.seq = seq;
        m.tick = tick;
        os_unfair_lock_lock(&c->lock);
        if (c->gen == gen && c->state[slot] == 1) c->state[slot] = 2;
        os_unfair_lock_unlock(&c->lock);
        kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        os_unfair_lock_lock(&c->lock);
        if (kr == KERN_SUCCESS) c->frames_sent++;
        else {
            c->frames_dropped++;
            if (c->gen == gen && c->state[slot] == 2) c->state[slot] = 0;
        }
        os_unfair_lock_unlock(&c->lock);
    }];
    [cb commit];
}

void pd_frames_conn_stats(pd_frames_conn* c, uint64_t* sent, uint64_t* dropped, uint64_t* rings, uint32_t* gen, int* w, int* h) {
    os_unfair_lock_lock(&c->lock);
    *sent = c->frames_sent;
    *dropped = c->frames_dropped;
    *rings = c->rings;
    *gen = c->gen;
    *w = c->w;
    *h = c->h;
    os_unfair_lock_unlock(&c->lock);
}

// The MTLDevice with this registry id (pi-desk's GPU), or the default one.
void* pd_frames_device_for(uint64_t registry_id) {
    NSArray<id<MTLDevice>>* all = MTLCopyAllDevices();
    for (id<MTLDevice> d in all) if (d.registryID == registry_id) return (void*)CFBridgingRetain(d);
    return (void*)CFBridgingRetain(MTLCreateSystemDefaultDevice());
}
