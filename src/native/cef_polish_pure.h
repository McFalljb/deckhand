// Pure helpers of the tab polish shim (src/native/cef_polish.inc), tested by
// tests/cef_polish_pure_test.c in `./build.sh test`.
#pragma once
#include <stddef.h>
#include <string.h>
#include <strings.h>

// The address a download is recorded as coming from (its quarantine record): http and https
// only, without a user:password@ part, the query or the fragment. 0: none (another scheme, too
// long).
static int dh_url_for_record(const char* in, char* out, size_t cap) {
    if (!in || !out || cap == 0) return 0;
    size_t skip;
    if (!strncasecmp(in, "http://", 7)) skip = 7;
    else if (!strncasecmp(in, "https://", 8)) skip = 8;
    else return 0;
    // the authority ends at the first / ? or #; a user:password@ part is up to its last @
    const char* auth = in + skip;
    size_t alen = strcspn(auth, "/?#");
    const char* host = auth;
    for (size_t k = 0; k < alen; k++)
        if (auth[k] == '@') host = auth + k + 1;
    size_t hlen = alen - (size_t)(host - auth);
    // the path, without the query or the fragment
    const char* path = auth + alen;
    size_t plen = strcspn(path, "?#");
    if (hlen == 0 || skip + hlen + plen + 1 > cap) return 0;
    memcpy(out, in, skip);
    memcpy(out + skip, host, hlen);
    memcpy(out + skip + hlen, path, plen);
    out[skip + hlen + plen] = 0;
    return 1;
}

// At most one line a second: 1 when a line may be said at now (seconds; *skipped back to 0);
// otherwise the line is counted in *skipped (said with the next one).
static int dh_rate_ok(double* last, int* skipped, double now) {
    if (*last != 0 && now - *last < 1.0) {
        (*skipped)++;
        return 0;
    }
    *last = now;
    *skipped = 0;
    return 1;
}
