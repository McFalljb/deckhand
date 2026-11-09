# Code signing for every Deckhand build (docs/DEVELOPING.md "Code signing"). Sourced by build.sh,
# scripts/bundle-app.sh and scripts/release.sh; not run on its own.
#
# The identity: SIGN_IDENTITY_DEFAULT below, the one line to change (committed, so it never
# depends on the environment: Deckhand's terminals drop DECKHAND_* from the login environment,
# src/core/login_env.odin). DECKHAND_SIGN_IDENTITY overrides it for one build. The name (or SHA-1) of
# a code-signing identity in the keychain (scripts/make-signing-identity.sh makes the default). A stable
# certificate gives the app a stable designated requirement (identifier + certificate leaf hash),
# so macOS keeps its privacy grants (Desktop, Documents, Downloads, camera...) across rebuilds and
# updates; ad hoc ("-") ties them to the CDHash, which every build changes. A Developer ID later:
# "Developer ID Application: NAME (TEAM)" (release.sh then also signs with the hardened runtime and
# a timestamp). "-": ad hoc on purpose, without the warning (a release too).
# Not in the keychain (a CI runner, another Mac): ad hoc with a warning; a release
# (DECKHAND_SIGN_REQUIRED=1, set by release.sh) stops instead.
#
#   sign_resolve           sets SIGN_AS (the identity, or "-") once; exported, so the scripts that
#                          build.sh runs reuse it without asking the keychain (or warning) again
#   sign_code ARGS... PATH codesign --force --sign "$SIGN_AS" ARGS... PATH
SIGN_IDENTITY_DEFAULT="Deckhand Self-Signed"
DECKHAND_SIGN_IDENTITY=${DECKHAND_SIGN_IDENTITY:-$SIGN_IDENTITY_DEFAULT}

sign_resolve() {
  if [ -n "${SIGN_AS:-}" ] && [ "${SIGN_FOR:-}" = "$DECKHAND_SIGN_IDENTITY" ]; then return 0; fi
  SIGN_FOR=$DECKHAND_SIGN_IDENTITY
  if [ "$DECKHAND_SIGN_IDENTITY" = - ]; then
    SIGN_AS=-
  # every code-signing identity, trusted or not (-v would leave out a self-signed one, which
  # codesign signs with all the same)
  elif security find-identity -p codesigning 2>/dev/null | grep -qF "\"$DECKHAND_SIGN_IDENTITY\"" ||
       security find-identity -p codesigning 2>/dev/null | grep -qiF " $DECKHAND_SIGN_IDENTITY "; then
    SIGN_AS=$DECKHAND_SIGN_IDENTITY
  elif [ "${DECKHAND_SIGN_REQUIRED:-0}" = 1 ]; then
    echo "sign: no code-signing identity \"$DECKHAND_SIGN_IDENTITY\" in the keychain (scripts/make-signing-identity.sh makes it; docs/DEVELOPING.md \"Code signing\")" >&2
    return 1
  else
    SIGN_AS=-
    {
      echo "sign: ************************************************************************"
      echo "sign: WARNING: no code-signing identity \"$DECKHAND_SIGN_IDENTITY\": signing AD HOC."
      echo "sign: macOS forgets this build's privacy grants (Desktop, Documents...) at the next one."
      echo "sign: Make it with scripts/make-signing-identity.sh, or DECKHAND_SIGN_IDENTITY=- for ad hoc."
      echo "sign: ************************************************************************"
    } >&2
  fi
  export SIGN_AS SIGN_FOR
}

sign_code() {
  # quiet when it works ("replacing existing signature"), all of it when it does not
  _sign_out=$(codesign --force --sign "$SIGN_AS" "$@" 2>&1) || {
    printf '%s\n' "$_sign_out" >&2
    echo "sign: codesign failed with \"$SIGN_AS\" (a locked login keychain? security unlock-keychain; or DECKHAND_SIGN_IDENTITY=- for ad hoc)" >&2
    return 1
  }
}
