// Browser tabs, step 3 ("tab polish", docs/BROWSER.md §6): the rest of what CEF expects from
// its host, #included at the end of cef_macos.m (it uses that file's slots and helpers).
// pi-desk decides and draws; this only translates (src/browser_polish.odin):
//
//  - cursor and tooltip (display handler): the page's cursor type and title text;
//  - the context menu: Chromium's own is emptied (on_before_context_menu clears the model, so
//    none shows); what was under the pointer goes to pi-desk, which draws its own menu;
//    pd_cef_edit runs Copy, Paste… in the focused frame;
//  - JS dialogs (alert, confirm, prompt, beforeunload): the callback is kept until pi-desk's
//    bar answers (pd_cef_dialog_answer), one per browser; more while one is open are suppressed;
//  - find in page (host find / stop_finding; on_find_result);
//  - zoom (get/set_zoom_level: Chromium keeps it per host);
//  - downloads: pi-desk decides and names the file (callbacks.download_path: go now with a
//    safe, new name in the downloads folder; refuse; or ask first: the callback is held until
//    pi-desk's bar answers, pd_cef_download_answer) and hears progress; pd_cef_download_cancel;
//    a finished file is quarantined (and pi-desk hears whether that worked);
//  - permission prompts (notifications, location; camera and microphone through the media
//    request): one per browser, kept until pi-desk's bar answers; other kinds get CEF's
//    default (Alloy: not granted); a main-frame navigation denies a camera or microphone
//    request still waiting (on_before_browse);
//  - a renderer that died (request handler) and DevTools in a window of its own
//    (show_dev_tools, in process: no remote debugging port);
//  - popups without a user gesture: Chromium's own blocker would refuse window.open before
//    on_before_popup is asked, so pi-desk could never offer them; --disable-popup-blocking
//    leaves that to on_before_popup, which refuses them as before (blocked_popup) and pi-desk
//    shows its bar with Open;
//  - native file choosers (dialog handler): cancelled while an agent's action runs on the tab
//    (callbacks.file_dialog; the agent hears use_browser_upload), the default panel otherwise.

#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_dialog_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_download_item_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_menu_model_capi.h"
#include "include/capi/cef_permission_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "cef_polish_pure.h"

typedef struct {
    void (*cursor)(int id, int type);         // cef_cursor_type_t
    void (*tooltip)(int id, const char* utf8); // "" = none
    // a right click in the page: flags (CM_TYPEFLAG_*), edit (CM_EDITFLAG_*), the link under it ("" = none)
    void (*context_menu)(int id, int flags, int edit, const char* link);
    // kind: 0 alert, 1 confirm, 2 prompt, 3 leave (beforeunload), 4 leave on reload; -1: gone
    void (*dialog)(int id, int kind, const char* message, const char* default_text, const char* origin);
    void (*find)(int id, int request, int count, int active, int final_update);
    // the file a download goes to (out, at most cap bytes with its NUL): 1 = go there now;
    // 0 = refused; 2 = ask first (pd_cef_download_answer answers later)
    int (*download_path)(int id, uint32_t dl, const char* suggested, const char* url, char* out, int cap);
    // state: 1 going, 2 done, 3 cancelled, 4 failed; quarantined: a done file was marked as downloaded
    void (*download)(int id, uint32_t dl, int state, int64_t received, int64_t total, const char* path, int quarantined);
    // what: cef_permission_request_types_t bits (camera and microphone as CAMERA_STREAM / MIC_STREAM); 0: gone
    void (*permission)(int id, uint32_t what, const char* origin);
    void (*crashed)(int id, int status); // cef_termination_status_t
    void (*navigated)(int id);           // a main-frame navigation starts
    // a native file chooser is opening: 1 = cancel it (an agent's action runs on the tab)
    int (*file_dialog)(int id);
} pd_cef_polish_callbacks;

static pd_cef_polish_callbacks pcb;
static cef_jsdialog_handler_t pol_jsdialog;
static cef_find_handler_t pol_find;
static cef_download_handler_t pol_download;
static cef_permission_handler_t pol_permission;
static cef_context_menu_handler_t pol_menu;
static cef_request_handler_t pol_request;
static cef_client_t pol_devtools_client; // DevTools' own window: none of our handlers (on_after_created would close it)

static cef_jsdialog_callback_t* pol_dialog[MAX_BROWSERS + 1];
static cef_permission_prompt_callback_t* pol_prompt[MAX_BROWSERS + 1];
static uint64_t pol_prompt_id[MAX_BROWSERS + 1];
static cef_media_access_callback_t* pol_media[MAX_BROWSERS + 1];
static uint32_t pol_media_perms[MAX_BROWSERS + 1];
static cef_before_download_callback_t* pol_ask[MAX_BROWSERS + 1]; // a download waiting for pi-desk's bar
static uint32_t pol_ask_id[MAX_BROWSERS + 1];
// refusals said at most once a second per browser (a page can ask in a loop): dialogs, permissions
static double pol_said_at[MAX_BROWSERS + 1][2];
static int pol_said_skipped[MAX_BROWSERS + 1][2];

static void pol_say_limited(int i, int what, NSString* line) {
    if (i < 0 || i > MAX_BROWSERS) i = 0;
    int skipped = pol_said_skipped[i][what];
    if (!pd_rate_ok(&pol_said_at[i][what], &pol_said_skipped[i][what], CFAbsoluteTimeGetCurrent())) return;
    say(skipped ? [NSString stringWithFormat:@"%@ (and %d more in the last second)", line, skipped] : line);
}

#define POL_DOWNLOADS 32
static struct {
    uint32_t id;
    cef_download_item_callback_t* cb; // cancel (held while it runs)
} pol_dl[POL_DOWNLOADS];

void pd_cef_polish_callbacks_set(const pd_cef_polish_callbacks* c) { pcb = *c; }

static int pol_slot(cef_browser_t* b) {
    if (!b) return 0;
    int i = slot_of(b);
    RELEASE(b);
    return i;
}

// ---- cursor, tooltip ----

static int CEF_CALLBACK pol_on_cursor(cef_display_handler_t* self, cef_browser_t* b, cef_cursor_handle_t cursor, cef_cursor_type_t type,
                                      const cef_cursor_info_t* info) {
    int i = pol_slot(b);
    if (i && pcb.cursor) pcb.cursor(i, type);
    return 1; // pi-desk sets the pointer
}

static int CEF_CALLBACK pol_on_tooltip(cef_display_handler_t* self, cef_browser_t* b, cef_string_t* text) {
    int i = pol_slot(b);
    if (!i || !pcb.tooltip) return 1;
    char* t = utf8_of(text);
    pcb.tooltip(i, t);
    free(t);
    return 1;
}

// ---- the context menu: Chromium's is emptied, pi-desk draws its own ----

static void CEF_CALLBACK pol_on_menu(cef_context_menu_handler_t* self, cef_browser_t* b, cef_frame_t* f, cef_context_menu_params_t* params,
                                     cef_menu_model_t* model) {
    int i = pol_slot(b);
    if (f) RELEASE(f);
    if (model) {
        model->clear(model); // nothing to show: CEF opens no menu of its own
        RELEASE(model);
    }
    if (!params) return;
    int flags = params->get_type_flags(params), edit = params->get_edit_state_flags(params);
    cef_string_userfree_t link = (flags & CM_TYPEFLAG_LINK) ? params->get_link_url(params) : NULL;
    RELEASE(params);
    char* l = link ? utf8_of(link) : strdup("");
    if (link) p_cef_string_userfree_utf16_free(link);
    if (i && pcb.context_menu) pcb.context_menu(i, flags, edit, l);
    free(l);
}

// 0 undo, 1 redo, 2 cut, 3 copy, 4 paste, 5 select all: in the focused frame.
void pd_cef_edit(int i, int op) {
    if (i < 1 || i > MAX_BROWSERS || !slots[i].browser || slots[i].closing) return;
    cef_frame_t* f = slots[i].browser->get_focused_frame(slots[i].browser);
    if (!f) f = slots[i].browser->get_main_frame(slots[i].browser);
    if (!f) return;
    switch (op) {
    case 0: f->undo(f); break;
    case 1: f->redo(f); break;
    case 2: f->cut(f); break;
    case 3: f->copy(f); break;
    case 4: f->paste(f); break;
    case 5: f->select_all(f); break;
    }
    RELEASE(f);
    touch();
    arm(0);
}

// ---- JS dialogs: a bar in the tab, answered by pd_cef_dialog_answer ----

static void pol_dialog_drop(int i) {
    cef_jsdialog_callback_t* cb_ = pol_dialog[i];
    pol_dialog[i] = NULL;
    if (cb_) RELEASE(cb_);
}

static int pol_dialog_take(cef_browser_t* b, cef_jsdialog_callback_t* callback, int kind, const cef_string_t* msg,
                           const cef_string_t* def, const cef_string_t* origin) {
    int i = pol_slot(b);
    // one at a time (Chromium's own rule); none for a closing browser
    if (!i || !pcb.dialog || slots[i].closing || pol_dialog[i] || !callback) {
        pol_say_limited(i, 0, [NSString stringWithFormat:@"JS dialog (kind %d) refused: %s", kind, !i ? "no such browser" : pol_dialog[i] ? "one is open" : "closing"]);
        if (callback) RELEASE(callback);
        return 0;
    }
    pol_dialog[i] = callback;
    char *m = utf8_of(msg), *d = utf8_of(def), *o = utf8_of(origin);
    pcb.dialog(i, kind, m, d, o);
    free(m), free(d), free(o);
    touch();
    return 1;
}

static int CEF_CALLBACK pol_on_jsdialog(cef_jsdialog_handler_t* self, cef_browser_t* b, const cef_string_t* origin, cef_jsdialog_type_t type,
                                        const cef_string_t* msg, const cef_string_t* def, cef_jsdialog_callback_t* callback, int* suppress) {
    int kind = type == JSDIALOGTYPE_CONFIRM ? 1 : type == JSDIALOGTYPE_PROMPT ? 2 : 0;
    int ok = pol_dialog_take(b, callback, kind, msg, type == JSDIALOGTYPE_PROMPT ? def : NULL, origin);
    *suppress = !ok; // refused: suppressed (the page's call returns at once), never Chromium's own dialog
    return ok;
}

static int CEF_CALLBACK pol_on_unload(cef_jsdialog_handler_t* self, cef_browser_t* b, const cef_string_t* msg, int is_reload,
                                      cef_jsdialog_callback_t* callback) {
    if (pol_dialog_take(b, callback, is_reload ? 4 : 3, msg, NULL, NULL)) return 1;
    // refused (one is open already): leave, as a page cannot hold the user there
    return 0;
}

static void pol_dialog_gone(cef_browser_t* b) {
    int i = pol_slot(b);
    if (!i) return;
    pol_dialog_drop(i);
    if (pcb.dialog) pcb.dialog(i, -1, "", "", "");
}

static void CEF_CALLBACK pol_on_dialog_reset(cef_jsdialog_handler_t* self, cef_browser_t* b) { pol_dialog_gone(b); }
static void CEF_CALLBACK pol_on_dialog_closed(cef_jsdialog_handler_t* self, cef_browser_t* b) { pol_dialog_gone(b); }

// The bar's OK (ok=1, text: a prompt's answer) or Cancel. 0: no dialog open.
int pd_cef_dialog_answer(int i, int ok, const char* text) {
    if (i < 1 || i > MAX_BROWSERS || !pol_dialog[i]) return 0;
    cef_jsdialog_callback_t* cb_ = pol_dialog[i];
    pol_dialog[i] = NULL; // before cont: on_dialog_closed may come from inside it
    cef_string_t t = str16(text ? text : "");
    cb_->cont(cb_, ok, &t);
    p_cef_string_utf16_clear(&t);
    RELEASE(cb_);
    touch();
    arm(0);
    return 1;
}

// ---- find in page ----

static void CEF_CALLBACK pol_on_find(cef_find_handler_t* self, cef_browser_t* b, int request, int count, const cef_rect_t* sel, int active,
                                     int final_update) {
    int i = pol_slot(b);
    if (i && pcb.find) pcb.find(i, request, count, active, final_update);
}

// text: what to find; forward 0: backwards; next 1: the next match of the same text.
void pd_cef_find(int i, const char* text, int forward, int next) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    cef_string_t t = str16(text);
    hst->find(hst, &t, forward, 0, next);
    p_cef_string_utf16_clear(&t);
    RELEASE(hst);
    touch();
    arm(0);
}

void pd_cef_find_stop(int i) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    hst->stop_finding(hst, 1);
    RELEASE(hst);
    arm(0);
}

// ---- zoom (Chromium's zoom level: factor = 1.2^level; per host) ----

double pd_cef_zoom_get(int i) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return 0;
    double z = hst->get_zoom_level(hst);
    RELEASE(hst);
    return z;
}

void pd_cef_zoom_set(int i, double level) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    hst->set_zoom_level(hst, level);
    RELEASE(hst);
    touch();
    arm(0);
}

// ---- downloads: pi-desk picks the file; progress comes back ----

static int CEF_CALLBACK pol_can_download(cef_download_handler_t* self, cef_browser_t* b, const cef_string_t* url, const cef_string_t* method) {
    if (b) RELEASE(b);
    // Chromium asks here for downloads a page starts by script too (no user gesture known
    // here): pi-desk decides in on_before_download (download_policy: the user's own click in
    // the tab just now, or a bar that asks)
    return 1;
}

static int CEF_CALLBACK pol_before_download(cef_download_handler_t* self, cef_browser_t* b, cef_download_item_t* item, const cef_string_t* suggested,
                                            cef_before_download_callback_t* callback) {
    int i = pol_slot(b);
    uint32_t id = item ? item->get_id(item) : 0;
    cef_string_userfree_t u = item ? item->get_url(item) : NULL;
    if (item) RELEASE(item);
    char* url = u ? utf8_of(u) : strdup("");
    if (u) p_cef_string_userfree_utf16_free(u);
    char* name = utf8_of(suggested);
    char path[PATH_MAX];
    path[0] = 0;
    int how = callback && pcb.download_path ? pcb.download_path(i, id, name, url, path, (int)sizeof path) : 0;
    free(url), free(name);
    if (how == 2 && i && !pol_ask[i]) {
        // pi-desk's bar asks first: held (released unanswered = cancelled)
        pol_ask[i] = callback;
        pol_ask_id[i] = id;
        touch();
        return 1;
    }
    if (how != 1 || path[0] != '/') {
        if (callback) RELEASE(callback);
        return 0; // Alloy's default: cancelled
    }
    cef_string_t p = str16(path);
    callback->cont(callback, &p, 0);
    p_cef_string_utf16_clear(&p);
    RELEASE(callback);
    arm(0);
    return 1;
}

// The bar's answer to a download that asked first: path (a new file pi-desk reserved) = go there;
// NULL = cancelled. 0: no such download waiting.
int pd_cef_download_answer(int i, uint32_t dl, const char* path) {
    if (i < 1 || i > MAX_BROWSERS || !pol_ask[i] || pol_ask_id[i] != dl) return 0;
    cef_before_download_callback_t* cb_ = pol_ask[i];
    pol_ask[i] = NULL;
    pol_ask_id[i] = 0;
    if (path && path[0] == '/') {
        cef_string_t p = str16(path);
        cb_->cont(cb_, &p, 0);
        p_cef_string_utf16_clear(&p);
    }
    RELEASE(cb_); // unanswered: CEF cancels the download
    touch();
    arm(0);
    return 1;
}

// A finished download is marked as one (com.apple.quarantine, as Safari and Chrome do): Gatekeeper
// checks it when it is opened (the bar's Open), so a downloaded app never runs unchecked.
// Chromium's content layer sets only its "where from" here. The address recorded has no
// user:password@, query or fragment (pd_url_for_record). 1: marked.
static int pol_quarantine(const char* path, const char* url) {
    @autoreleasepool {
        NSURL* file = [NSURL fileURLWithPath:@(path)];
        NSMutableDictionary* q = [@{
            (__bridge NSString*)kLSQuarantineTypeKey : (__bridge NSString*)kLSQuarantineTypeWebDownload,
            (__bridge NSString*)kLSQuarantineAgentNameKey : @"pi-desk",
        } mutableCopy];
        char rec[2048];
        NSURL* from = url && pd_url_for_record(url, rec, sizeof rec) ? [NSURL URLWithString:@(rec)] : nil;
        if (from) q[(__bridge NSString*)kLSQuarantineDataURLKey] = from;
        NSError* err = nil;
        if (![file setResourceValue:q forKey:NSURLQuarantinePropertiesKey error:&err]) {
            say([NSString stringWithFormat:@"could not mark %s as downloaded: %@", path, err.localizedDescription]);
            return 0;
        }
        return 1;
    }
}

static void CEF_CALLBACK pol_download_updated(cef_download_handler_t* self, cef_browser_t* b, cef_download_item_t* item,
                                              cef_download_item_callback_t* callback) {
    int i = pol_slot(b);
    if (!item) {
        if (callback) RELEASE(callback);
        return;
    }
    uint32_t id = item->get_id(item);
    int state = item->is_complete(item) ? 2 : item->is_canceled(item) ? 3 : item->is_interrupted(item) ? 4 : 1;
    int64_t got = item->get_received_bytes(item), total = item->get_total_bytes(item);
    cef_string_userfree_t fp = item->get_full_path(item);
    char* path = fp ? utf8_of(fp) : strdup("");
    if (fp) p_cef_string_userfree_utf16_free(fp);
    int quarantined = 0;
    if (state == 2 && path[0] == '/') {
        cef_string_userfree_t u = item->get_url(item);
        char* url = u ? utf8_of(u) : strdup("");
        if (u) p_cef_string_userfree_utf16_free(u);
        quarantined = pol_quarantine(path, url);
        free(url);
    }
    RELEASE(item);
    // the cancel callback: held while it runs
    int k = -1, free_k = -1;
    for (int j = 0; j < POL_DOWNLOADS; j++) {
        if (pol_dl[j].cb && pol_dl[j].id == id) k = j;
        else if (!pol_dl[j].cb && free_k < 0) free_k = j;
    }
    if (state == 1 && k < 0 && free_k >= 0 && callback) {
        pol_dl[free_k].id = id;
        pol_dl[free_k].cb = callback;
        callback = NULL;
    } else if (state != 1 && k >= 0) {
        RELEASE(pol_dl[k].cb);
        pol_dl[k].cb = NULL;
    }
    if (callback) RELEASE(callback);
    if (pcb.download) pcb.download(i, id, state, got, total, path, quarantined);
    free(path);
}

void pd_cef_download_cancel(uint32_t id) {
    for (int j = 0; j < POL_DOWNLOADS; j++)
        if (pol_dl[j].cb && pol_dl[j].id == id) {
            pol_dl[j].cb->cancel(pol_dl[j].cb);
            arm(0);
            return;
        }
}

// ---- permission prompts: a bar in the tab ----

#define POL_PERMS (CEF_PERMISSION_TYPE_NOTIFICATIONS | CEF_PERMISSION_TYPE_GEOLOCATION | CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM)

static int pol_perm_busy(int i) { return pol_prompt[i] || pol_media[i]; }

static int CEF_CALLBACK pol_on_prompt(cef_permission_handler_t* self, cef_browser_t* b, uint64_t prompt_id, const cef_string_t* origin,
                                      uint32_t perms, cef_permission_prompt_callback_t* callback) {
    int i = pol_slot(b);
    // Chromium's own "multiple automatic downloads" question: granted here, as pi-desk asks
    // per download itself (download_take: one per user gesture, otherwise its bar)
    if (perms == CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS && callback) {
        callback->cont(callback, CEF_PERMISSION_RESULT_ACCEPT);
        RELEASE(callback);
        return 1;
    }
    // only what the bar names; one at a time; anything else: CEF's default (not granted)
    if (!i || !pcb.permission || slots[i].closing || !perms || (perms & ~POL_PERMS) || pol_perm_busy(i) || !callback) {
        pol_say_limited(i, 1, [NSString stringWithFormat:@"permission prompt 0x%x refused (CEF's default: not granted)", perms]);
        if (callback) RELEASE(callback);
        return 0;
    }
    pol_prompt[i] = callback;
    pol_prompt_id[i] = prompt_id;
    char* o = utf8_of(origin);
    pcb.permission(i, perms, o);
    free(o);
    touch();
    return 1;
}

static void CEF_CALLBACK pol_on_prompt_dismissed(cef_permission_handler_t* self, cef_browser_t* b, uint64_t prompt_id,
                                                 cef_permission_request_result_t result) {
    int i = pol_slot(b);
    if (!i || pol_prompt_id[i] != prompt_id) return;
    cef_permission_prompt_callback_t* cb_ = pol_prompt[i];
    pol_prompt[i] = NULL;
    pol_prompt_id[i] = 0;
    if (cb_) RELEASE(cb_);
    if (pcb.permission) pcb.permission(i, 0, "");
}

static int CEF_CALLBACK pol_on_media(cef_permission_handler_t* self, cef_browser_t* b, cef_frame_t* f, const cef_string_t* origin,
                                     uint32_t perms, cef_media_access_callback_t* callback) {
    int i = pol_slot(b);
    if (f) RELEASE(f);
    uint32_t cam_mic = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    // the camera and the microphone only (never the screen); one at a time
    if (!i || !pcb.permission || slots[i].closing || !perms || (perms & ~cam_mic) || pol_perm_busy(i) || !callback) {
        if (callback) RELEASE(callback);
        return 0; // Alloy's default: denied
    }
    pol_media[i] = callback;
    pol_media_perms[i] = perms;
    uint32_t what = (perms & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE ? CEF_PERMISSION_TYPE_CAMERA_STREAM : 0) |
                    (perms & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE ? CEF_PERMISSION_TYPE_MIC_STREAM : 0);
    char* o = utf8_of(origin);
    pcb.permission(i, what, o);
    free(o);
    touch();
    return 1;
}

// The bar's Allow (1) or Block (0). 0: nothing asked.
int pd_cef_permission_answer(int i, int allow) {
    if (i < 1 || i > MAX_BROWSERS) return 0;
    if (pol_prompt[i]) {
        cef_permission_prompt_callback_t* cb_ = pol_prompt[i];
        pol_prompt[i] = NULL; // before cont: the dismissal may come from inside it
        cb_->cont(cb_, allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
        RELEASE(cb_);
    } else if (pol_media[i]) {
        cef_media_access_callback_t* cb_ = pol_media[i];
        pol_media[i] = NULL;
        if (allow) cb_->cont(cb_, pol_media_perms[i]);
        else cb_->cancel(cb_);
        RELEASE(cb_);
    } else
        return 0;
    pol_prompt_id[i] = 0;
    if (pcb.permission) pcb.permission(i, 0, "");
    touch();
    arm(0);
    return 1;
}

// A main-frame navigation: a camera or microphone request still waiting is denied and its bar
// goes (the page that asked is leaving); pi-desk drops a download still asking
// (callbacks.navigated). Navigations are never cancelled here.
static int CEF_CALLBACK pol_on_before_browse(cef_request_handler_t* self, cef_browser_t* b, cef_frame_t* f, cef_request_t* req, int user_gesture,
                                             int is_redirect) {
    int main_frame = f && f->is_main(f);
    if (f) RELEASE(f);
    if (req) RELEASE(req);
    int i = pol_slot(b);
    if (i && main_frame && pol_media[i]) pd_cef_permission_answer(i, 0);
    if (i && main_frame && pcb.navigated) pcb.navigated(i);
    return 0;
}

// ---- native file choosers: cancelled under an agent's action (pi-desk decides) ----

static cef_dialog_handler_t pol_dialog_handler;
static int CEF_CALLBACK pol_on_file_dialog(cef_dialog_handler_t* self, cef_browser_t* b, cef_file_dialog_mode_t mode, const cef_string_t* title,
                                           const cef_string_t* default_file_path, cef_string_list_t accept_filters,
                                           cef_string_list_t accept_extensions, cef_string_list_t accept_descriptions,
                                           cef_file_dialog_callback_t* callback) {
    int i = pol_slot(b);
    if (i && pcb.file_dialog && pcb.file_dialog(i)) {
        if (callback) {
            callback->cancel(callback);
            RELEASE(callback);
        }
        return 1;
    }
    if (callback) RELEASE(callback);
    return 0; // the user's own: the default panel
}
static cef_dialog_handler_t* CEF_CALLBACK pol_get_dialog(cef_client_t* self) { return &pol_dialog_handler; }

// ---- a renderer that died ----

static void CEF_CALLBACK pol_on_terminated(cef_request_handler_t* self, cef_browser_t* b, cef_termination_status_t status, int code,
                                           const cef_string_t* err) {
    int i = pol_slot(b);
    if (!i) return;
    // its dialog and prompt went with it
    pol_dialog_drop(i);
    if (pcb.dialog) pcb.dialog(i, -1, "", "", "");
    if (pol_perm_busy(i)) pd_cef_permission_answer(i, 0);
    if (pcb.crashed) pcb.crashed(i, status);
}

// ---- DevTools: Chromium's own, in a window of its own (in process) ----

// x, y: inspect the element there (view px); -1: just open.
int pd_cef_devtools_show(int i, int x, int y) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return 0;
    cef_window_info_t wi;
    memset(&wi, 0, sizeof wi);
    wi.size = sizeof wi;
    wi.bounds = (cef_rect_t){120, 120, 1100, 760};
    wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    cef_browser_settings_t bs;
    memset(&bs, 0, sizeof bs);
    bs.size = sizeof bs;
    cef_point_t at = {x, y};
    hst->show_dev_tools(hst, &wi, &pol_devtools_client, &bs, x >= 0 && y >= 0 ? &at : NULL);
    RELEASE(hst);
    arm(0);
    return 1;
}

int pd_cef_devtools_open(int i) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return 0;
    int open = hst->has_dev_tools(hst);
    RELEASE(hst);
    return open;
}

void pd_cef_devtools_close(int i) {
    cef_browser_host_t* hst = host_of(i);
    if (!hst) return;
    hst->close_dev_tools(hst);
    RELEASE(hst);
    arm(0);
}

// Test mode only (browser_polish.odin's page_crash): the renderer dies as a crash would.
void pd_cef_test_crash(int i) { pd_cef_navigate(i, "chrome://crash"); }

// ---- wiring (pd_cef_start, before cef_initialize) ----

static cef_jsdialog_handler_t* CEF_CALLBACK pol_get_jsdialog(cef_client_t* self) { return &pol_jsdialog; }
static cef_find_handler_t* CEF_CALLBACK pol_get_find(cef_client_t* self) { return &pol_find; }
static cef_download_handler_t* CEF_CALLBACK pol_get_download(cef_client_t* self) { return &pol_download; }
static cef_permission_handler_t* CEF_CALLBACK pol_get_permission(cef_client_t* self) { return &pol_permission; }
static cef_context_menu_handler_t* CEF_CALLBACK pol_get_menu(cef_client_t* self) { return &pol_menu; }
static cef_request_handler_t* CEF_CALLBACK pol_get_request(cef_client_t* self) { return &pol_request; }

// A browser went (on_before_close): what it held goes back.
static void (CEF_CALLBACK* pol_prev_before_close)(cef_life_span_handler_t*, cef_browser_t*);
static void CEF_CALLBACK pol_before_close(cef_life_span_handler_t* self, cef_browser_t* b) {
    int id = b->get_identifier(b);
    for (int i = 1; i <= MAX_BROWSERS; i++) {
        if (!slots[i].browser || slots[i].cef_id != id) continue;
        pol_dialog_drop(i);
        if (pol_ask[i]) {
            RELEASE(pol_ask[i]); // unanswered: cancelled
            pol_ask[i] = NULL, pol_ask_id[i] = 0;
        }
        if (pol_perm_busy(i)) {
            if (pol_prompt[i]) RELEASE(pol_prompt[i]);
            if (pol_media[i]) {
                pol_media[i]->cancel(pol_media[i]);
                RELEASE(pol_media[i]);
            }
            pol_prompt[i] = NULL, pol_media[i] = NULL, pol_prompt_id[i] = 0;
        }
    }
    pol_prev_before_close(self, b); // releases b
}

static void (CEF_CALLBACK* pol_prev_cmdline)(cef_app_t*, const cef_string_t*, cef_command_line_t*);
static void CEF_CALLBACK pol_cmdline(cef_app_t* self, const cef_string_t* process_type, cef_command_line_t* cl) {
    pol_prev_cmdline(self, process_type, cl);
    if (process_type && process_type->length > 0) return;
    // window.open without a user gesture reaches on_before_popup (refused there, with a bar)
    add_switch(cl, "disable-popup-blocking");
}

static void polish_install(void) {
    display.on_cursor_change = pol_on_cursor;
    display.on_tooltip = pol_on_tooltip;
    INIT_BASE(pol_jsdialog);
    pol_jsdialog.on_jsdialog = pol_on_jsdialog;
    pol_jsdialog.on_before_unload_dialog = pol_on_unload;
    pol_jsdialog.on_reset_dialog_state = pol_on_dialog_reset;
    pol_jsdialog.on_dialog_closed = pol_on_dialog_closed;
    INIT_BASE(pol_find);
    pol_find.on_find_result = pol_on_find;
    INIT_BASE(pol_download);
    pol_download.can_download = pol_can_download;
    pol_download.on_before_download = pol_before_download;
    pol_download.on_download_updated = pol_download_updated;
    INIT_BASE(pol_permission);
    pol_permission.on_show_permission_prompt = pol_on_prompt;
    pol_permission.on_dismiss_permission_prompt = pol_on_prompt_dismissed;
    pol_permission.on_request_media_access_permission = pol_on_media;
    INIT_BASE(pol_menu);
    pol_menu.on_before_context_menu = pol_on_menu;
    INIT_BASE(pol_request);
    pol_request.on_render_process_terminated = pol_on_terminated;
    pol_request.on_before_browse = pol_on_before_browse;
    INIT_BASE(pol_devtools_client);
    INIT_BASE(pol_dialog_handler);
    pol_dialog_handler.on_file_dialog = pol_on_file_dialog;
    client.get_dialog_handler = pol_get_dialog;
    client.get_jsdialog_handler = pol_get_jsdialog;
    client.get_find_handler = pol_get_find;
    client.get_download_handler = pol_get_download;
    client.get_permission_handler = pol_get_permission;
    client.get_context_menu_handler = pol_get_menu;
    client.get_request_handler = pol_get_request;
    pol_prev_before_close = life.on_before_close;
    life.on_before_close = pol_before_close;
    pol_prev_cmdline = app.on_before_command_line_processing;
    app.on_before_command_line_processing = pol_cmdline;
}
