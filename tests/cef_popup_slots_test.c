// The popup slot matcher (src/native/cef_popup_slots.h), run by `./build.sh test`:
// a popup's browser lands in the tab made for it (its opener's session), never
// in another opener's, whatever order CEF creates or aborts them in.
#include <stdio.h>
#include "../src/native/cef_popup_slots.h"

static int failed;
#define EXPECT(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failed = 1; } } while (0)

int main(void) {
    // slots 1..4: A (opener 10) reserved first, then B (opener 20), then A again
    pd_popup_res r[5] = {{0}};
    r[1] = (pd_popup_res){1, 10, 1, 1};
    r[2] = (pd_popup_res){1, 20, 1, 2};
    r[3] = (pd_popup_res){1, 10, 2, 3};
    // B's browser arrives first: it takes B's slot, not A's older one
    EXPECT(pd_popup_take(r, 4, 20) == 2, "B's browser takes B's slot");
    // A's take A's, in A's order
    EXPECT(pd_popup_take(r, 4, 10) == 1, "A's first browser takes A's first slot");
    // B's popup aborts: B's slot is freed, A's untouched
    EXPECT(pd_popup_find(r, 4, 20, 1) == 2, "B's abort frees B's slot");
    // A's second popup aborts: found by its popup_id, not the oldest of A's
    EXPECT(pd_popup_find(r, 4, 10, 2) == 3, "A's popup 2 abort frees slot 3");
    // a closed-before-arrival reservation (pending 2) still matches its own opener only
    r[2].pending = 2;
    EXPECT(pd_popup_take(r, 4, 20) == 2, "a cancelled reservation is still B's");
    EXPECT(pd_popup_take(r, 4, 30) == 0, "an unknown opener takes nothing");
    // round 2: an abort with no exact match (out of order, a popup_id CEF changed) releases
    // that opener's oldest reservation, so the slot is not held forever; never another opener's
    EXPECT(pd_popup_find(r, 4, 10, 9) == 1, "no exact match: the opener's oldest");
    EXPECT(pd_popup_find(r, 4, 30, 9) == 0, "an unknown opener matches nothing");
    r[1].pending = 0;
    EXPECT(pd_popup_find(r, 4, 10, 9) == 3, "then its next oldest");
    // nothing reserved
    pd_popup_res none[3] = {{0}};
    EXPECT(pd_popup_take(none, 2, 10) == 0, "no reservation");
    if (!failed) printf("cef_popup_slots: ok\n");
    return failed;
}
