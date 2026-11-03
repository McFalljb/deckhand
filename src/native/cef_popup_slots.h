// Which reserved slot a popup's browser belongs to (cef_macos.m; docs/BROWSER.md §2.5).
// on_before_popup reserves a slot for the tab pi-desk made in the opener's
// session; CEF then brings the browser (on_after_created) or aborts it
// (on_before_popup_aborted). Pure, so tests/cef_popup_slots_test.c checks it.
#ifndef PD_CEF_POPUP_SLOTS_H
#define PD_CEF_POPUP_SLOTS_H

typedef struct {
    int pending;  // 0: not a reservation; 1 waiting for its browser; 2 its tab closed meanwhile
    int opener;   // the opener browser's CEF identifier
    int popup_id; // on_before_popup's popup_id (unique per opener)
    unsigned long long seq; // reservation order
} pd_popup_res;

// The reservation a new popup browser takes: its opener's oldest one (CEF
// creates one opener's popups in order). Index into r (1..n); 0 = none.
static inline int pd_popup_take(const pd_popup_res* r, int n, int opener) {
    int k = 0;
    for (int i = 1; i <= n; i++)
        if (r[i].pending && r[i].opener == opener && (!k || r[i].seq < r[k].seq)) k = i;
    return k;
}

// The reservation an aborted popup had (its opener and popup_id); with no
// exact match (aborts out of order, an id CEF did not keep), that opener's
// oldest, so its slot is not held forever; never another opener's. 0 = none.
static inline int pd_popup_find(const pd_popup_res* r, int n, int opener, int popup_id) {
    for (int i = 1; i <= n; i++)
        if (r[i].pending && r[i].opener == opener && r[i].popup_id == popup_id) return i;
    return pd_popup_take(r, n, opener);
}

#endif
