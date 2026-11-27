#!/bin/sh
# scripts/check-env-reads.py on a temporary tree: known names pass, by a literal or a same-file
# constant; an unknown name fails by either; any other way to the environment fails unless its
# line is marked (TypeScript's process.env as a whole, an alias of it read by key; Objective-C's
# NSProcessInfo environment). Under a second; run by ./build.sh test.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/envreads.XXXXXX")
trap 'rm -rf "$T"' EXIT
CHECK="python3 -I $ROOT/scripts/check-env-reads.py --root $T"
mkdir -p "$T/src/native" "$T/tools" "$T/integrations/pi/lib"
reset() {
  rm -f "$T/src/bad.odin" "$T/src/native/bad.m" "$T/integrations/pi/lib/bad.ts"
  cat > "$T/src/ok.odin" <<'ODIN'
package ok
HOME_VAR :: "HOME"
a :: proc() {
	_ = os.get_env("HOME", context.temp_allocator)
	_ = os.get_env(HOME_VAR, context.temp_allocator) // a constant: HOME
	_ = os.get_env(name, context.temp_allocator) // env-read-ok: a wrapper whose callers are checked
	/* os.get_env("DECKHAND_IN_A_COMMENT") */
}
ODIN
  cat > "$T/src/native/ok.m" <<'OBJC'
static void f(void) {
	NSString* h = [[NSProcessInfo processInfo] environment][@"HOME"];
	NSString* p = [NSProcessInfo.processInfo.environment objectForKey:@"PATH"];
	NSDictionary* all = [[NSProcessInfo processInfo] environment]; // env-read-ok: logged keys only
	const char* s = getenv("SHELL");
}
OBJC
  cat > "$T/integrations/pi/lib/ok.ts" <<'TS'
/** process.env in a doc comment is not a read */
const SOCK = "DECKHAND_SOCKET";
export const TOKEN = "DECKHAND_TOKEN" as const;
const a = process.env.PI_KIT_NOTES_DIR;
const b = process.env["PI_CODING_AGENT_DIR"];
const c = process.env[SOCK];
const d = deckhandEnv(TOKEN);
for (const k of Object.keys(process.env)) { // env-read-ok: names only
}
TS
}
reset
$CHECK > "$T/out" 2>&1 || { echo "check-env-reads-test: a clean tree failed:"; cat "$T/out"; exit 1; }

# each bad line, alone in its file (where: odin | m | ts), is refused on line 2
refused() {
  reset
  case $1 in
    odin) f="$T/src/bad.odin"; printf 'package bad\n%s\n' "$2" > "$f" ;;
    m)    f="$T/src/native/bad.m"; printf '// bad\n%s\n' "$2" > "$f" ;;
    ts)   f="$T/integrations/pi/lib/bad.ts"; printf '// bad\n%s\n' "$2" > "$f" ;;
  esac
  [ -n "${3:-}" ] && printf '%s\n' "$3" >> "$f"
  if $CHECK > "$T/out" 2>&1; then echo "check-env-reads-test: not refused ($1): $2"; exit 1; fi
  grep -q "bad\.[a-z]*:2:" "$T/out" || { echo "check-env-reads-test: no line 2 for ($1): $2"; cat "$T/out"; exit 1; }
}
refused odin 'x := os.get_env("DECKHAND_FOO", context.temp_allocator)'
refused odin 'x := os.get_env(FOO, context.temp_allocator)' 'FOO :: "DECKHAND_FOO"'
refused odin 'x := os.get_env(name, context.temp_allocator)'
refused odin 'v, _ := env_lookup(env, FOO)' 'FOO :: "DECKHAND_FOO"'
refused m 'const char* s = getenv("DECKHAND_FOO");'
refused m 'NSString* s = [[NSProcessInfo processInfo] environment][@"DECKHAND_FOO"];'
refused m 'NSString* s = [[NSProcessInfo processInfo] environment][key];'
refused m 'NSDictionary* all = NSProcessInfo.processInfo.environment;'
refused ts 'const x = process.env.DECKHAND_FOO;'
refused ts 'const x = process.env[X];' 'const X = "DECKHAND_FOO";'
refused ts 'const x = deckhandEnv(X);' 'const X = "DECKHAND_FOO";'
refused ts 'const x = process.env[name];'
refused ts 'const env = process.env; const x = env[X];' 'const X = "DECKHAND_FOO";'
refused ts 'const { DECKHAND_FOO } = process.env;'
refused ts 'spawn("sh", [], { env: { ...process.env } });'
refused ts 'const x = process["env"].DECKHAND_FOO;'
refused ts 'const x = globalThis.process.env;'
echo "check-env-reads-test: ok"
