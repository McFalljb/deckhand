package main

// The public half of pi-desk's release signing key (docs/DEVELOPING.md, "Update signing").
// An update is installed only when its .sig verifies under UPDATE_PUBLIC_KEY
// (src/updatesig). Base64 of the 32-byte Ed25519 public key.
//
// !!! PLACEHOLDER: no real key yet. While it is, this build checks for updates but refuses
// to install any, and scripts/release.sh refuses to make a release. To go live:
// `build/update-sign keygen ~/.config/pi-desk/update.key` on the release signer's Mac and put
// the printed public key here. The private key stays in that file, never in GitHub.
UPDATE_PUBLIC_KEY :: "PLACEHOLDER-no-release-key-yet"

// Test builds only (-define:PI_DESK_UPDATE_TEST=true: `./build.sh test` and the update
// scene's own binary, tests/scripts/update.sh). A release build has neither the test key
// nor the test mode's update fixtures (PI_DESK_UPDATE_URL and the rest) compiled in.
PI_DESK_UPDATE_TEST :: #config(PI_DESK_UPDATE_TEST, false)

when PI_DESK_UPDATE_TEST {
	// A THROWAWAY key for tests only (its private half is tests/update/test-key.txt, in the
	// repository on purpose).
	UPDATE_TEST_PUBLIC_KEY :: "weWbQWXDtC7qXBK3lB7oFQJYPxbgUyo6tXdhkKq+QoA="
}
