package main

// The public half of pi-desk's release signing key (docs/DEVELOPING.md, "Update signing").
// An update is installed only when its .sig verifies under UPDATE_PUBLIC_KEY
// (src/updatesig). Base64 of the 32-byte Ed25519 public key.
//
// The key was made on 2026-11-03 with `build/update-sign keygen`; the private half stays on the
// release signer's Mac (~/.config/pi-desk/update.key), never in GitHub. Rotating it:
// docs/DEVELOPING.md, "Update signing".
UPDATE_PUBLIC_KEY :: "WLmBpaet8DK5313TmDQz0PdG2QDwJI684gSeYrcFyLI="

// Test builds only (-define:PI_DESK_UPDATE_TEST=true: `./build.sh test` and the update
// scene's own binary, tests/scripts/update.sh). A release build has neither the test key
// nor the test mode's update fixtures (PI_DESK_UPDATE_URL and the rest) compiled in.
PI_DESK_UPDATE_TEST :: #config(PI_DESK_UPDATE_TEST, false)

when PI_DESK_UPDATE_TEST {
	// A THROWAWAY key for tests only (its private half is tests/update/test-key.txt, in the
	// repository on purpose).
	UPDATE_TEST_PUBLIC_KEY :: "weWbQWXDtC7qXBK3lB7oFQJYPxbgUyo6tXdhkKq+QoA="
}
