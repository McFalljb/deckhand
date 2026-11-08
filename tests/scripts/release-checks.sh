#!/bin/sh
# The release flow's guards without building a release or touching GitHub (docs/DEVELOPING.md,
# "Releases"): build/update-sign's key-file rules, and scripts/release.sh's refusals before
# it builds anything, in a temp git repo holding the few files they need, with the THROWAWAY
# test key (tests/update/test-key.txt) and a fake `gh` that fails if it is ever called.
#   key file: readable by others, a link, in a folder others can write: refused
#   release.sh: a dirty tree, HEAD not exactly vX.Y.Z, another version's tag, the placeholder
#   key, a key file readable by others, a key that is not UPDATE_PUBLIC_KEY, a rotation bridge
#   whose key is not the old one: refused
#   test hooks (src/test_hooks.odin): src built with -define:DECKHAND_TEST_HOOKS=false holds no
#   hook name, --print-token or test key (scripts/check-release-build.sh passes it), binaries
#   planted with a single hook string, or any DECKHAND_ name the check does not allow, fail it;
#   the source lint (scripts/check-env-reads.py) refuses an env read of a built or unknown name;
#   release.sh builds with DECKHAND_RELEASE=1 and runs the check; build.sh refuses it for tests
# Usage: tests/scripts/release-checks.sh   (builds build/update-sign)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/release-checks"
rm -rf "$W"
mkdir -p "$W"
odin build tools/update-sign -out:build/update-sign
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# ---- the key file -------------------------------------------------------------------------
K="$W/keys"
mkdir -p "$K/private" "$K/shared"
chmod 700 "$K/private"
cp tests/update/test-key.txt "$K/private/k"
chmod 600 "$K/private/k"
TEST_PUB=$(build/update-sign pubkey "$K/private/k") && ok "a 0600 key in a private folder" || bad "a good key file was refused"
chmod 644 "$K/private/k"
build/update-sign pubkey "$K/private/k" >/dev/null 2>&1 && bad "a key readable by others was read" || ok "a key readable by others refused"
chmod 600 "$K/private/k"
ln -s "$K/private/k" "$K/private/link"
build/update-sign pubkey "$K/private/link" >/dev/null 2>&1 && bad "a key through a link was read" || ok "a key through a link refused"
cp "$K/private/k" "$K/shared/k"
chmod 600 "$K/shared/k"
chmod 777 "$K/shared"
build/update-sign pubkey "$K/shared/k" >/dev/null 2>&1 && bad "a key in a folder others can write was read" || ok "a key in a folder others can write refused"
chmod 770 "$K/shared"
build/update-sign pubkey "$K/shared/k" >/dev/null 2>&1 && bad "a key in a group-writable folder was read" || ok "a key in a group-writable folder refused"
chmod 700 "$K/shared"

# ---- release.sh's refusals, before any build -----------------------------------------------
R="$W/repo"
mkdir -p "$R/scripts" "$R/src/updatesig" "$R/tools/update-sign" "$R/build" "$W/bin"
cp scripts/release.sh scripts/sign.sh "$R/scripts/"
cp src/updatesig/updatesig.odin "$R/src/updatesig/"
cp src/update_core.odin "$R/src/" # UPDATE_REPO, the repository release.sh uploads to
cp tools/update-sign/main.odin "$R/tools/update-sign/"
cp build/update-sign "$R/build/"
touch "$R/build/update-sign"
printf 'build/\ndist/\n' > "$R/.gitignore"
printf '#!/bin/sh\necho "fake gh: must not be called" >&2\nexit 1\n' > "$W/bin/gh"
chmod +x "$W/bin/gh"
keyfile() { printf 'package main\nUPDATE_PUBLIC_KEY :: "%s"\n' "$1" > "$R/src/update_key.odin"; }
keyfile "$TEST_PUB"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm one
rel() { (cd "$R" && PATH="$W/bin:$PATH" HOME="$W/home" scripts/release.sh --key "$K/private/k" "$@") > "$W/out.txt" 2>&1; }
refused() { # WHAT WANT_TEXT ARGS...
  what=$1 want=$2; shift 2
  if rel "$@"; then bad "$what: release.sh went ahead"
  elif grep -q "$want" "$W/out.txt"; then ok "$what refused"
  else bad "$what: refused for another reason: $(tail -1 "$W/out.txt")"; fi
}

refused "HEAD without a tag" "is not exactly the tag v0.2.0" --version 0.2.0 --no-upload
git -C "$R" tag v0.1.9
refused "another version's tag" "is not exactly the tag v0.2.0" --version 0.2.0 --no-upload
git -C "$R" tag v0.2.0
echo x > "$R/scripts/extra.txt"
refused "an untracked file" "not clean" --version 0.2.0 --no-upload
rm "$R/scripts/extra.txt"
echo "# edit" >> "$R/scripts/release.sh"
refused "a changed file" "not clean" --version 0.2.0 --no-upload
git -C "$R" checkout -q scripts/release.sh
keyfile "PLACEHOLDER-no-release-key-yet"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam placeholder
git -C "$R" tag v0.3.0
refused "the placeholder key" "placeholder" --version 0.3.0 --no-upload
build/update-sign keygen "$K/private/other" > /dev/null
keyfile "$(build/update-sign pubkey "$K/private/other")"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam otherkey
git -C "$R" tag v0.4.0
refused "a key that is not UPDATE_PUBLIC_KEY" "is not src/update_key.odin's UPDATE_PUBLIC_KEY" --version 0.4.0 --no-upload
keyfile "$TEST_PUB"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam testkey
git -C "$R" tag v0.5.0
chmod 644 "$K/private/k"
refused "a key file readable by others" "readable by others" --version 0.5.0 --no-upload
chmod 600 "$K/private/k"
refused "a pre-release" "pre-release" --version 0.5.0-rc.1 --no-upload
OTHER_PUB=$(build/update-sign pubkey "$K/private/other")
refused "--rotating-from with a key that is not OLDPUB" "is not OLDPUB" --version 0.5.0 --no-upload --rotating-from "$OTHER_PUB"
refused "--rotating-from the key the app already has" "they are the same here" --version 0.5.0 --no-upload --rotating-from "$TEST_PUB"
# the repository: the app's (UPDATE_REPO) unless --allow-other-repo says otherwise
refused "--repo another repository" "is not the repository the app updates from" --version 0.5.0 --no-upload --repo someone/fork
(export DECKHAND_RELEASE_REPO=someone/fork; refused "DECKHAND_RELEASE_REPO another repository" "is not the repository the app updates from" --version 0.5.0 --no-upload)
if rel --version 0.5.0 --upload-only --repo someone/fork --allow-other-repo; then bad "--allow-other-repo: went ahead with no dist/"
elif grep -q "is not the repository" "$W/out.txt"; then bad "--allow-other-repo: still refused for the repository"
else ok "--allow-other-repo lets another repository through"; fi
# the signing identity (scripts/sign.sh): one the keychain holds, or ad hoc only when asked (-)
(export DECKHAND_SIGN_IDENTITY="Deckhand No Such Identity $$"; refused "a signing identity not in the keychain" "no code-signing identity" --version 0.5.0 --no-upload)
(export DECKHAND_SIGN_IDENTITY=-; rel --version 0.5.0 --no-upload || true)
grep -q "an AD-HOC release, on purpose" "$W/out.txt" && ok "DECKHAND_SIGN_IDENTITY=- goes on to an ad-hoc release" || bad "DECKHAND_SIGN_IDENTITY=-: $(tail -1 "$W/out.txt")"
# the release's names come from the app's source: none there, no release
sed -i '' '/^UPDATE_APP ::/d' "$R/src/update_core.odin"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam noapp
git -C "$R" tag v0.6.0
refused "no UPDATE_APP in src/update_core.odin" "UPDATE_APP" --version 0.6.0 --no-upload
git -C "$R" checkout -q HEAD~1 -- src/update_core.odin
sed -i '' '/^ZIP_PREFIX ::/d' "$R/src/updatesig/updatesig.odin"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam nozip
git -C "$R" tag v0.7.0
refused "no ZIP_PREFIX in src/updatesig/updatesig.odin" "ZIP_PREFIX" --version 0.7.0 --no-upload

# ---- test hooks out of release builds (src/test_hooks.odin) ----------------------------------
H="$W/hooks"
mkdir -p "$H"
odin build src -out:"$H/nohooks" -define:DECKHAND_TEST_HOOKS=false -minimum-os-version:14.0 >"$H/build.log" 2>&1 || { cat "$H/build.log"; bad "src did not build without hooks"; }
scripts/check-release-build.sh "$H/nohooks" >"$H/out.txt" 2>&1 && ok "a build without hooks passes the check" || bad "a build without hooks: $(cat "$H/out.txt")"
for s in DECKHAND_SCRIPT DECKHAND_DATA_DIR DECKHAND_RUNTIME_DIR DECKHAND_UPDATE_URL --print-token; do
  cp /usr/bin/true "$H/planted"
  printf 'x%sx' "$s" >> "$H/planted"
  scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && bad "a binary holding $s passed" || ok "a binary holding $s refused"
done
# the catch-all: any other DECKHAND_ name fails too (a knob outside HOOK_ENV); the allowed ones pass
for s in DECKHAND_NEW_KNOB DECKHAND_CEF_NETLOG DECKHAND_CEF_SPARE DECKHAND_x; do
  cp /usr/bin/true "$H/planted"
  printf '\001%s\001' "$s" >> "$H/planted"
  scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && bad "a binary holding $s passed" || ok "a binary holding $s refused"
done
cp /usr/bin/true "$H/planted"
printf '\001DECKHAND_SOCKET\001DECKHAND_GUI_LAUNCH\001DECKHAND_*\001' >> "$H/planted"
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && ok "the allowed DECKHAND_ names pass" || bad "an allowed name refused: $(cat "$H/out.txt")"
cp /usr/bin/true "$H/planted"
printf '\001DECKHAND_HOLDER_HOOKS\001' >> "$H/planted"
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && bad "a binary holding DECKHAND_HOLDER_HOOKS passed" || ok "a binary holding DECKHAND_HOLDER_HOOKS refused"
# the source lint (scripts/check-env-reads.py): a name built at run time, or an unknown one, fails
L="$H/lint"
lint() { # WHAT WANT(pass|fail) LINE
  rm -rf "$L"; mkdir -p "$L/src" "$L/scripts"
  printf 'package main\nf :: proc() {\n\t%b\n}\n' "$3" > "$L/src/x.odin" # %b: a \\n in LINE is a new line
  if python3 -I scripts/check-env-reads.py --root "$L" >"$H/out.txt" 2>&1; then got=pass; else got=fail; fi
  [ "$got" = "$2" ] && ok "env lint: $1 ($2)" || bad "env lint: $1: $got, want $2: $(cat "$H/out.txt")"
}
lint "a built name" fail 'v := os.get_env(fmt.tprintf("DECKHAND_%s", x))'
lint "an unknown literal" fail 'v := os.get_env("DECKHAND_NEW_KNOB")'
lint "a C getenv of a knob" fail 'const char* v = getenv("DECKHAND_NEW_KNOB");'
lint "a known literal" pass 'v := os.get_env("HOME")'
lint "env_lookup of a built name" fail 'v, _ := env_lookup(child_base_env(), fmt.tprintf("DECKHAND_%s", x))'
lint "env_lookup of an unknown literal" fail 'v, _ := env_lookup(child_base_env(), "DECKHAND_NEW_KNOB")'
lint "env_lookup of a known literal" pass 'v, _ := env_lookup(child_base_env(), "PATH")'
lint "the name on the next line" fail 'v := os.get_env(\n\t\t"DECKHAND_NEW_KNOB")'
lint "a // inside a string before the call" fail 'u := "http://x"; v := os.get_env(fmt.tprintf("DECKHAND_%s", x))'
lint "a non-literal without the marker" fail 'v := os.get_env(name)'
lint "a non-literal with the marker" pass 'v := os.get_env(name) // env-read-ok: test'
lint "the marker in a string is no marker" fail 'v := os.get_env(name); s := "// env-read-ok: no"'
python3 -I scripts/check-env-reads.py >"$H/out.txt" 2>&1 && ok "env lint: the tree passes" || bad "env lint: $(cat "$H/out.txt")"
grep -q -- '-DDH_RELEASE=1' build.sh && grep -q '#ifndef DH_RELEASE' src/native/cef_macos.m && ok "the CEF shim's knobs are out of release builds" || bad "build.sh or cef_macos.m lost DH_RELEASE"
grep -q '^DECKHAND_RELEASE=1 ./build.sh$' scripts/release.sh && ok "release.sh builds without hooks" || bad "release.sh does not build with DECKHAND_RELEASE=1"
grep -q 'scripts/check-release-build.sh "$EXE"' scripts/release.sh && ok "release.sh checks its binaries" || bad "release.sh does not run check-release-build.sh"
DECKHAND_RELEASE=1 ./build.sh test >"$H/out.txt" 2>&1 && bad "build.sh test ran without hooks" || ok "build.sh refuses DECKHAND_RELEASE=1 for tests"

if [ $fail = 1 ]; then echo "release checks failed (last output: $W/out.txt)"; exit 1; fi
echo "release checks ok"
