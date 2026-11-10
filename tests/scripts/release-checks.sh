#!/bin/sh
# The release flow's guards without building a release or touching GitHub (docs/DEVELOPING.md,
# "Releases"): build/update-sign's key-file rules, and scripts/release.sh's refusals before
# it builds anything, in a temp git repo holding the few files they need, with the THROWAWAY
# test key (tests/update/test-key.txt) and a fake `gh` that fails if it is ever called.
#   key file: readable by others, a link, in a folder others can write: refused
#   release.sh: a dirty tree, HEAD not exactly vX.Y.Z, another version's tag, the placeholder
#   key, a key file readable by others, a key that is not UPDATE_PUBLIC_KEY, a rotation bridge
#   whose key is not the old one: refused
#   test hooks (src/core/test_hooks.odin): src built with -define:DECKHAND_TEST_HOOKS=false holds no
#   hook name, --print-token or test key (scripts/check-release-build.sh passes it), binaries
#   planted with a single hook string, or any DECKHAND_ name the check does not allow, fail it;
#   the source lint (scripts/check-env-reads.py) refuses an env read of a built or unknown name;
#   release.sh builds with DECKHAND_RELEASE=1 and runs the check; build.sh refuses it for tests
#   the Linux tarball (scripts/release-linux.sh, with a fake gh serving a run, its artifact and its
#   log): signed v3 with cdhash none when it all holds; refused with no run for the tag's push at
#   its commit, a failed or unfinished run, no artifact, a sha256 that is not the log's (or none,
#   or two), a member with .., absolute, outside its folder, a link, a missing binary, a hook
#   string; update-sign's none rules; release.sh refusing before its build
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
mkdir -p "$R/scripts" "$R/src/core" "$R/src/updatesig" "$R/tools/update-sign" "$R/build" "$W/bin"
cp scripts/release.sh scripts/release-linux.sh scripts/sign.sh "$R/scripts/"
cp src/updatesig/updatesig.odin "$R/src/updatesig/"
cp src/core/update_core.odin "$R/src/core/" # UPDATE_REPO, the repository release.sh uploads to
cp tools/update-sign/main.odin "$R/tools/update-sign/"
cp build/update-sign "$R/build/"
touch "$R/build/update-sign"
printf 'build/\ndist/\n' > "$R/.gitignore"
printf '#!/bin/sh\necho "fake gh: must not be called" >&2\nexit 1\n' > "$W/bin/gh"
chmod +x "$W/bin/gh"
keyfile() { printf 'package core\nUPDATE_PUBLIC_KEY :: "%s"\n' "$1" > "$R/src/core/update_key.odin"; }
keyfile "$TEST_PUB"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm one
rel() { (cd "$R" && PATH="${GH_BIN:-$W/bin}:$PATH" HOME="$W/home" scripts/release.sh --key "$K/private/k" "$@") > "$W/out.txt" 2>&1; }
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
refused "a key that is not UPDATE_PUBLIC_KEY" "is not src/core/update_key.odin's UPDATE_PUBLIC_KEY" --version 0.4.0 --no-upload
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

# ---- the Linux core's tarball (scripts/release-linux.sh): CI's run, its sha256, its signature ----
# a fake gh serving one run list, one artifact and one log from $FAKE_GH (no network)
G="$W/gh"
mkdir -p "$G/bin"
cat > "$G/bin/gh" <<'GH'
#!/bin/sh
D=${FAKE_GH:?}
echo "$*" >> "$D/calls"
case "$1 $2" in
  "run list") cat "$D/runs.tsv" ;;
  "run download")
    dir=""
    while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done
    [ -n "$dir" ] && [ -d "$D/artifact" ] || { echo "no artifact" >&2; exit 1; }
    cp "$D/artifact/"* "$dir/" ;;
  "run view") cat "$D/log.txt" ;;
  *) echo "fake gh: not expected: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$G/bin/gh"
LV=0.9.0
LNAME=deckhand-core-$LV-linux-x86_64.tar.gz
LTOP=${LNAME%.tar.gz}
LC=0123456789abcdef0123456789abcdef01234567
T=$(printf '\t')
fixture() { # KIND: the artifact, a passed run of it, and its log's sha256 line
  rm -rf "$G/artifact" "$G/calls"; mkdir -p "$G/artifact"
  python3 -I tests/scripts/release-fixture.py "$G/artifact/$LNAME" "$LTOP" "$1" /usr/bin/true
  printf '%s\n' "42${T}push${T}v$LV${T}$LC${T}completed${T}success" > "$G/runs.tsv"
  printf 'tarball\tpack\t2026-11-09T00:00:00Z tarball-sha256 %s %s\n' "$(shasum -a 256 "$G/artifact/$LNAME" | cut -d' ' -f1)" "$LNAME" > "$G/log.txt"
}
LOUT="$W/linux-out"
mkdir -p "$W/tmp"
lin() { (PATH="$G/bin:$PATH" FAKE_GH="$G" TMPDIR="$W/tmp" scripts/release-linux.sh --version $LV --commit $LC --repo someone/deckhand "$@") > "$W/out.txt" 2>&1; }
lin_fetch() { rm -rf "$LOUT"; lin --key "$K/private/k" --pub "$TEST_PUB" --out "$LOUT"; }
lin_refused() { # WHAT WANT_TEXT [--preflight]
  what=$1 want=$2; shift 2
  rm -rf "$LOUT"
  if [ "${1:-}" = --preflight ]; then lin --preflight; else lin_fetch; fi && { bad "linux: $what: went ahead"; return; }
  if grep -q -- "$want" "$W/out.txt"; then ok "linux: $what refused"; else bad "linux: $what: refused for another reason: $(tail -1 "$W/out.txt")"; fi
  [ ! -e "$LOUT/$LNAME.sig" ] || bad "linux: $what: a .sig was written"
}

fixture good
if lin_fetch; then
  build/update-sign verify "$TEST_PUB" $LV "$LOUT/$LNAME" "$LOUT/$LNAME.sig" >/dev/null && ok "linux: the tarball is fetched, checked and signed" || bad "linux: its .sig does not verify"
  [ "$(head -2 "$LOUT/$LNAME.sig")" = "deckhand-update-sig v3
cdhash none" ] && ok "linux: the .sig is v3 with cdhash none" || bad "linux: the .sig's head: $(head -2 "$LOUT/$LNAME.sig")"
  (cd "$LOUT" && shasum -a 256 -c "$LNAME.sha256") >/dev/null 2>&1 && ok "linux: its .sha256 checks" || bad "linux: its .sha256 does not check"
  grep -qF "$(cat "$K/private/k")" "$W/out.txt" && bad "linux: the private key is in the output" || ok "linux: the private key is not printed"
  grep -q -- "--workflow release-linux.yml --event push" "$G/calls" && ok "linux: the run is the workflow's, for a push" || bad "linux: gh run list was: $(head -1 "$G/calls")"
else bad "linux: a good tarball was refused: $(tail -1 "$W/out.txt")"; fi
[ -z "$(ls -A "$W/tmp")" ] && ok "linux: no temp folder left" || bad "linux: a temp folder was left in $W/tmp"

fixture good; : > "$G/runs.tsv"
lin_refused "no run" "push the tag (git push origin v$LV), wait for that workflow" --preflight
lin_refused "no run (fetch)" "release-linux.yml"
fixture good; printf '%s\n' "42${T}push${T}v$LV${T}fedcba9876543210fedcba9876543210fedcba98${T}completed${T}success" > "$G/runs.tsv"
lin_refused "a run at another commit" "no run of"
fixture good; printf '%s\n' "42${T}push${T}v0.8.0${T}$LC${T}completed${T}success" > "$G/runs.tsv"
lin_refused "a run for another tag" "no run of"
fixture good; printf '%s\n' "42${T}workflow_dispatch${T}v$LV${T}$LC${T}completed${T}success" > "$G/runs.tsv"
lin_refused "a run by hand, not the tag's push" "no run of"
fixture good; printf '%s\n' "42${T}push${T}v$LV${T}$LC${T}completed${T}failure" > "$G/runs.tsv"
lin_refused "a failed run" "ended failure" --preflight
lin_refused "a failed run (fetch)" "ended failure"
fixture good; printf '%s\n' "42${T}push${T}v$LV${T}$LC${T}in_progress${T}" > "$G/runs.tsv"
lin --preflight && ok "linux: a run still going passes the preflight" || bad "linux: preflight refused a run still going: $(tail -1 "$W/out.txt")"
lin_refused "a run still going (fetch)" "is in_progress: wait for it"
fixture good; rm -rf "$G/artifact"
lin_refused "no artifact" "has no artifact $LNAME"
fixture good; sed -i '' 's/tarball-sha256 [0-9a-f]*/tarball-sha256 0000000000000000000000000000000000000000000000000000000000000000/' "$G/log.txt"
lin_refused "a sha256 mismatch" "is not the one run 42 printed"
fixture good; : > "$G/log.txt"
lin_refused "no sha256 in the log" "has no \"tarball-sha256"
fixture good; printf 'x\ty\tz tarball-sha256 %s %s\n' 1111111111111111111111111111111111111111111111111111111111111111 "$LNAME" >> "$G/log.txt"
lin_refused "two sha256 values in the log" "more than one sha256"
fixture good; printf 'x\ty\tz tarball-sha256 %s %s.evil\n' 1111111111111111111111111111111111111111111111111111111111111111 "$LNAME" >> "$G/log.txt"
lin_fetch && ok "linux: a sha256 line for another name is ignored" || bad "linux: another name's line counted: $(tail -1 "$W/out.txt")"
for k in dotdot:"a member with .." abs:"a member outside" symlink:"not a file or a folder" hardlink:"not a file or a folder" outside:"a member outside" missing:"has no $LTOP/deckhand-core" hook:"test hooks"; do
  fixture "${k%%:*}"
  lin_refused "a tarball with ${k%%:*}" "${k#*:}"
done
# update-sign: none only for the tarball, and only in v3; a zip still needs its CDHash
U="$W/usign"; rm -rf "$U"; mkdir -p "$U"
echo x > "$U/$LNAME"; echo x > "$U/deckhand-$LV-macos-arm64.zip"
build/update-sign sign "$K/private/k" $LV "$U/$LNAME" none "$U/s" >/dev/null 2>&1 && bad "update-sign: a v2 tarball .sig was made" || ok "update-sign: a tarball needs --v3"
build/update-sign sign --v3 "$K/private/k" $LV "$U/$LNAME" 0123456789abcdef0123456789abcdef01234567 "$U/s" >/dev/null 2>&1 && bad "update-sign: a tarball signed with a CDHash" || ok "update-sign: a tarball's cdhash is none"
build/update-sign sign --v3 "$K/private/k" $LV "$U/deckhand-$LV-macos-arm64.zip" none "$U/s" >/dev/null 2>&1 && bad "update-sign: a zip signed with cdhash none" || ok "update-sign: a zip needs its CDHash"
build/update-sign sign --v3 "$K/private/k" $LV "$U/$LNAME" none "$U/t.sig" >/dev/null
sed 's/^deckhand-update-sig v3$/pi-desk-update-sig v2/' "$U/t.sig" > "$U/t2.sig"
build/update-sign verify "$TEST_PUB" $LV "$U/$LNAME" "$U/t2.sig" >/dev/null 2>&1 && bad "update-sign: a v2 cdhash none .sig verified" || ok "update-sign: a v2 cdhash none .sig refused"
cp "$U/$LNAME" "$U/deckhand-$LV-macos-arm64.zip"; cp "$U/t.sig" "$U/z.sig"
build/update-sign verify "$TEST_PUB" $LV "$U/deckhand-$LV-macos-arm64.zip" "$U/z.sig" >/dev/null 2>&1 && bad "update-sign: a cdhash none .sig verified a zip" || ok "update-sign: a cdhash none .sig never verifies a zip"
# release.sh: the run is looked for before the build, and the tarball fetched after the Mac files
(export DECKHAND_SIGN_IDENTITY=- FAKE_GH="$G" GH_BIN="$G/bin"; : > "$G/runs.tsv"
 refused "release.sh with no Linux run for the tag" "no run of the \"Linux release tarball\" workflow" --version 0.5.0 --no-upload)
(export DECKHAND_SIGN_IDENTITY=- FAKE_GH="$G" GH_BIN="$G/bin"; printf '%s\n' "42${T}push${T}v0.5.0${T}$(git -C "$R" rev-parse HEAD)${T}completed${T}failure" > "$G/runs.tsv"
 refused "release.sh with a failed Linux run" "ended failure" --version 0.5.0 --no-upload)
grep -q '^scripts/release-linux.sh --preflight --version "$VERSION" --commit "$COMMIT" --repo "$REPO"' scripts/release.sh && ok "release.sh looks for the Linux run before building" || bad "release.sh has no Linux preflight"
grep -q '^scripts/release-linux.sh --version "$VERSION" --commit "$COMMIT" --repo "$REPO" --key "$KEY" --pub "$SIGN_PUB" --out "$DIST"' scripts/release.sh && ok "release.sh fetches and signs the Linux tarball" || bad "release.sh does not fetch the Linux tarball"
[ "$(grep -c '"$DIST/$LINUX_TAR" "$DIST/$LINUX_TAR.sha256" "$DIST/$LINUX_TAR.sig"' scripts/release.sh)" = 3 ] && ok "release.sh checks and uploads the Linux files" || bad "release.sh does not upload the Linux files (create and upload)"
# the release's names come from the app's source: none there, no release
sed -i '' '/^UPDATE_APP ::/d' "$R/src/core/update_core.odin"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam noapp
git -C "$R" tag v0.6.0
refused "no UPDATE_APP in src/core/update_core.odin" "UPDATE_APP" --version 0.6.0 --no-upload
git -C "$R" checkout -q HEAD~1 -- src/core/update_core.odin
sed -i '' '/^ZIP_PREFIX ::/d' "$R/src/updatesig/updatesig.odin"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qam nozip
git -C "$R" tag v0.7.0
refused "no ZIP_PREFIX in src/updatesig/updatesig.odin" "ZIP_PREFIX" --version 0.7.0 --no-upload

# ---- test hooks out of release builds (src/core/test_hooks.odin) ----------------------------------
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
# (the old PI_DESK_ names too: an old hook name, a knob under the old prefix)
for s in DECKHAND_NEW_KNOB DECKHAND_CEF_NETLOG DECKHAND_CEF_SPARE DECKHAND_x PI_DESK_SCRIPT PI_DESK_DATA_DIR PI_DESK_NEW_KNOB PI_DESK_x; do
  cp /usr/bin/true "$H/planted"
  printf '\001%s\001' "$s" >> "$H/planted"
  scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && bad "a binary holding $s passed" || ok "a binary holding $s refused"
done
cp /usr/bin/true "$H/planted"
printf '\001DECKHAND_SOCKET\001DECKHAND_GUI_LAUNCH\001DECKHAND_*\001' >> "$H/planted"
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && ok "the allowed DECKHAND_ names pass" || bad "an allowed name refused: $(cat "$H/out.txt")"
cp /usr/bin/true "$H/planted"
printf '\001PI_DESK_SOCKET\001PI_DESK_CLAUDE_TOKEN\001PI_DESK_CLI\001PI_DESK_GUI_LAUNCH\001PI_DESK_\001' >> "$H/planted"
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && ok "the old names the rename still sets pass" || bad "an allowed old name refused: $(cat "$H/out.txt")"
# an optimised build keeps some compared strings as aligned 16-byte pieces (__literal16): a piece
# that starts an allowed name passes, run on into its neighbours or not; any other piece fails
plant16() { # BYTES...: /usr/bin/true padded to a 16-byte boundary, then the bytes
  cp /usr/bin/true "$H/planted"
  n=$(( (16 - $(wc -c < "$H/planted") % 16) % 16 ))
  [ "$n" = 0 ] || head -c "$n" /dev/zero >> "$H/planted"
  printf "$@" >> "$H/planted"
}
plant16 'DECKHAND_SUCCESS/deckhand-core-sPI_DESK_CEF_SHARDECKHAND_CEF_SHACLAUDE_CONFIG_DI\001'
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && ok "16-byte pieces of allowed names pass" || bad "a 16-byte piece of an allowed name refused: $(cat "$H/out.txt")"
plant16 'DECKHAND_SCRIPT_\001'
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && bad "a 16-byte piece of a hook name passed" || ok "a 16-byte piece of a hook name refused"
plant16 'DECKHAND_CLAUDE_\001'
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && bad "a piece shared by a hook (DECKHAND_CLAUDE_BIN) passed" || ok "a piece shared by a hook refused"
plant16 'DECKHAND_SUCCESSDECKHAND_CLI\001'
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && ok "a piece run on into an allowed name passes" || bad "a piece run on into an allowed name refused: $(cat "$H/out.txt")"
plant16 '\001DECKHAND_SUCCESS\001'
scripts/check-release-build.sh "$H/planted" >"$H/out.txt" 2>&1 && bad "an unaligned piece passed" || ok "an unaligned piece refused"
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
lint "an old name the rename reads" pass 'v := os.get_env("PI_DESK_SOCKET")'
lint "an old test hook's name" fail 'v := os.get_env("PI_DESK_SCRIPT")'
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
grep 'scripts/check-release-build.sh "$EXE"' scripts/release.sh | grep -qF '$CORE_REL/Contents/MacOS/deckhand-core" "$BUILT/$CORE_REL/Contents/MacOS/deckhand-core-serve" "$BUILT/$CORE_REL/Contents/MacOS/deckhand"' && ok "release.sh checks Deckhand Core.app's binaries" || bad "release.sh does not check Deckhand Core.app's binaries"
DECKHAND_RELEASE=1 ./build.sh test >"$H/out.txt" 2>&1 && bad "build.sh test ran without hooks" || ok "build.sh refuses DECKHAND_RELEASE=1 for tests"

if [ $fail = 1 ]; then echo "release checks failed (last output: $W/out.txt)"; exit 1; fi
echo "release checks ok"
