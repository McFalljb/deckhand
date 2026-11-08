// Deckhand's CEF helper (docs/BROWSER.md §1.5): one binary cloned into the
// five "Deckhand Helper (…).app" bundles. Chromium starts it for renderer,
// GPU, network, plugin and alert processes. It starts the sandbox, loads the
// framework at run time (sandboxed helpers must not link it), checks the API
// hash and hands over to cef_execute_process, with an app that registers
// Deckhand's deckhand-test scheme (as the browser process does, cef_macos.m:
// every process must agree that it is a standard scheme).
//
// Built by build.sh: clang, the pinned distribution's headers only (no C++
// wrapper, no CMake).

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/cef_sandbox_mac.h"

static void* load(const char* dir, const char* rel) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, rel);
    void* h = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (!h) fprintf(stderr, "Deckhand Helper: dlopen %s: %s\n", path, dlerror());
    return h;
}

static __typeof__(cef_string_utf8_to_utf16)* to16;
static __typeof__(cef_string_utf16_clear)* clear16;

static void CEF_CALLBACK ref_add(cef_base_ref_counted_t* self) {}
static int CEF_CALLBACK ref_release(cef_base_ref_counted_t* self) { return 0; }
static int CEF_CALLBACK ref_one(cef_base_ref_counted_t* self) { return 1; }

static void CEF_CALLBACK on_register_schemes(cef_app_t* self, cef_scheme_registrar_t* reg) {
    cef_string_t n = {0};
    to16("deckhand-test", 13, &n);
    reg->add_custom_scheme(reg, &n, CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE | CEF_SCHEME_OPTION_CORS_ENABLED);
    clear16(&n);
}

static cef_app_t app;

int main(int argc, char** argv) {
    char exe[PATH_MAX];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) return 1;
    // …/Contents/Frameworks/Deckhand Helper (X).app/Contents/MacOS/Deckhand Helper (X)
    char dir[PATH_MAX];
    strncpy(dir, dirname(exe), sizeof dir - 1);
    dir[sizeof dir - 1] = 0;

    void* sb = load(dir, "../../../Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib");
    if (!sb) return 1;
    __typeof__(cef_sandbox_initialize)* sandbox_init = (__typeof__(cef_sandbox_initialize)*)dlsym(sb, "cef_sandbox_initialize");
    if (!sandbox_init || !sandbox_init(argc, argv)) {
        fprintf(stderr, "Deckhand Helper: sandbox did not start\n");
        return 1;
    }

    void* fw = load(dir, "../../../Chromium Embedded Framework.framework/Chromium Embedded Framework");
    if (!fw) return 1;
    __typeof__(cef_api_hash)* api_hash = (__typeof__(cef_api_hash)*)dlsym(fw, "cef_api_hash");
    __typeof__(cef_execute_process)* execute = (__typeof__(cef_execute_process)*)dlsym(fw, "cef_execute_process");
    to16 = (__typeof__(cef_string_utf8_to_utf16)*)dlsym(fw, "cef_string_utf8_to_utf16");
    clear16 = (__typeof__(cef_string_utf16_clear)*)dlsym(fw, "cef_string_utf16_clear");
    if (!api_hash || !execute || !to16 || !clear16) return 1;
    const char* hash = api_hash(CEF_API_VERSION, 0);
    if (!hash || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
        fprintf(stderr, "Deckhand Helper: CEF API hash mismatch\n");
        return 1;
    }
    cef_main_args_t args = {.argc = argc, .argv = argv};
    memset(&app, 0, sizeof app);
    app.base.size = sizeof app;
    app.base.add_ref = ref_add;
    app.base.release = ref_release;
    app.base.has_one_ref = ref_one;
    app.base.has_at_least_one_ref = ref_one;
    app.on_register_custom_schemes = on_register_schemes;
    return execute(&args, &app, NULL);
}
