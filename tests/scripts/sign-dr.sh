#!/bin/sh
# The designated-requirement checks with real signatures (docs/plans/background-core.md §5.4,
# §10.3 M4-A; src/trust): a checker (tests/sign-dr/) signed with "Deckhand Self-Signed" checks a
# tiny peer program over a socketpair:
#   the peer signed with Deckhand Self-Signed and the expected identifier: Allow (and its version,
#     from its signed Info.plist)
#   the same program ad hoc: Wrong_Signer; under another identifier: Wrong_Identity
#   a token saved before the peer exec'd: No_Code, errSecCSNoSuchCode (-67065)
#   the checker itself ad hoc: Adhoc mode, the ad-hoc peer passes on its identifier alone
#   the built Deckhand Core.app (if there) meets the requirement the checker writes for it
# The identity is only used to sign (read only): never made, changed or removed here, and no
# keychain is touched. Skipped (exit 0) when it is not in the keychain (CI, another Mac).
# Usage: tests/scripts/sign-dr.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
ID="Deckhand Self-Signed"
if ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$ID\""; then
  echo "sign-dr: skipped (no \"$ID\" code-signing identity in the keychain: scripts/make-signing-identity.sh)"
  exit 0
fi
W="$ROOT/build/sign-dr"
rm -rf "$W"
mkdir -p "$W"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
sign() { codesign -f -s "$@" >/dev/null 2>&1 || { echo "sign-dr: codesign $* failed (a locked keychain? security unlock-keychain)"; exit 1; }; }

odin build tests/sign-dr -out:"$W/check" -minimum-os-version:14.0
cat > "$W/peer.c" <<'C'
#include <unistd.h>
int main(int argc, char **argv) {
    char b = 'x';
    if (write(3, &b, 1) != 1 || read(3, &b, 1) != 1) return 1;
    if (argc > 1) execv(argv[1], argv + 1);
    return 0;
}
C
cat > "$W/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.deckhand.signdr</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
</dict></plist>
P
cc -o "$W/peer" "$W/peer.c" -Wl,-sectcreate,__TEXT,__info_plist,"$W/Info.plist"
for v in self adhoc other; do cp "$W/peer" "$W/peer-$v"; done
sign "$ID" -i dev.deckhand.signdr "$W/peer-self"
sign - -i dev.deckhand.signdr "$W/peer-adhoc"
sign "$ID" -i dev.deckhand.other "$W/peer-other"
cp "$W/check" "$W/check-adhoc"
sign "$ID" -i dev.deckhand.signdr.check "$W/check"
sign - -i dev.deckhand.signdr.check "$W/check-adhoc"

expect() { # WHAT WANT CMD...
  what=$1 want=$2; shift 2
  got=$("$@" 2>&1 | tr '\n' ' ' | sed 's/ $//') || true
  [ "$got" = "$want" ] && ok "$what: $got" || bad "$what: got \"$got\", want \"$want\""
}
expect "the checker's own mode" "Self_Signed" "$W/check" mode
expect "a peer signed as we are" "Allow 1.2.3" "$W/check" peer dev.deckhand.signdr "$W/peer-self"
expect "the same program ad hoc" "Wrong_Signer 1.2.3" "$W/check" peer dev.deckhand.signdr "$W/peer-adhoc"
expect "signed as we are, another identifier" "Wrong_Identity 1.2.3" "$W/check" peer dev.deckhand.signdr "$W/peer-other"
expect "a peer that exec'd since" "Allow 1.2.3 No_Code -67065" "$W/check" exec dev.deckhand.signdr "$W/peer-self"
expect "an ad-hoc checker's own mode" "Adhoc" "$W/check-adhoc" mode
expect "ad hoc: the identifier alone" "Allow 1.2.3" "$W/check-adhoc" peer dev.deckhand.signdr "$W/peer-adhoc"
expect "ad hoc: another identifier" "Wrong_Identity 1.2.3" "$W/check-adhoc" peer dev.deckhand.signdr "$W/peer-other"

# the requirement the checks write, against the bundle build.sh made (when it is there and signed
# with the identity: its leaf hash is the checker's)
CORE="build/Deckhand.app/Contents/Helpers/Deckhand Core.app"
if [ -d "$CORE" ] && codesign -dvv "$CORE" 2>&1 | grep -qxF "Authority=$ID"; then
  REQ=$("$W/check" req dev.deckhand.core)
  case "$REQ" in 'identifier "dev.deckhand.core" and certificate leaf = H"'*) ok "the requirement: $REQ" ;; *) bad "the requirement: $REQ" ;; esac
  codesign --verify --strict --deep -R "=$REQ" "$CORE" && ok "$CORE meets it" || bad "$CORE does not meet $REQ"
  codesign -dr - "$CORE" 2>&1 | grep -qF "designated => $REQ" && ok "and it is the bundle's own designated requirement" || bad "$CORE's designated requirement is not $REQ"
else
  echo "sign-dr: $CORE not built with \"$ID\": its check skipped"
fi
if [ $fail = 1 ]; then echo "sign-dr: FAILED"; exit 1; fi
rm -rf "$W"
echo "sign-dr: ok"
