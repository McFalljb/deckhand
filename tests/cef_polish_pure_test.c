// The tab polish shim's pure helpers (src/native/cef_polish_pure.h), run by `./build.sh test`.
#include <stdio.h>
#include "../src/native/cef_polish_pure.h"

static int failed;
#define EXPECT(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failed = 1; } } while (0)

static int rec(const char* in, const char* want) {
    char out[256];
    int ok = pd_url_for_record(in, out, sizeof out);
    if (!want) return !ok;
    return ok && !strcmp(out, want);
}

int main(void) {
    // the quarantine record's address: no user:password@, no query, no fragment
    EXPECT(rec("https://example.com/f.zip", "https://example.com/f.zip"), "a plain address");
    EXPECT(rec("https://" "user" ":" "pw@" "example.com/f.zip?token=abc#x", "https://example.com/f.zip"), "userinfo, query and fragment go");
    EXPECT(rec("http://example.com:8080/a/b@c.zip", "http://example.com:8080/a/b@c.zip"), "an @ in the path stays");
    EXPECT(rec("https://example.com?x=1", "https://example.com"), "a query on the host");
    EXPECT(rec("HTTPS://Example.com/x", "HTTPS://Example.com/x"), "scheme case");
    EXPECT(rec("blob:https://example.com/uuid", NULL), "blob: is not recorded");
    EXPECT(rec("file:///etc/passwd", NULL), "file: is not recorded");
    EXPECT(rec("data:text/plain,x", NULL), "data: is not recorded");
    // at most one line a second; the skipped ones counted
    double last = 0;
    int skipped = 0;
    EXPECT(pd_rate_ok(&last, &skipped, 100.0), "the first line");
    EXPECT(!pd_rate_ok(&last, &skipped, 100.2), "0.2 s later: held");
    EXPECT(!pd_rate_ok(&last, &skipped, 100.9), "0.9 s later: held");
    EXPECT(skipped == 2, "two held");
    EXPECT(pd_rate_ok(&last, &skipped, 101.1), "1.1 s later: said");
    if (failed) return 1;
    printf("cef_polish_pure: ok\n");
    return 0;
}
