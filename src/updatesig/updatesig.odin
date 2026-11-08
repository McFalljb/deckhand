package updatesig

// Deckhand's release signatures (docs/DEVELOPING.md, "Update signing"): shared by the
// app's updater (src/update*.odin) and the release tool (tools/update-sign).
//
// A release ships deckhand-<v>-macos-arm64.zip and deckhand-<v>-macos-arm64.zip.sig. The
// .sig (SIG_FILE_HEAD, then "cdhash HEX", then "signature BASE64") carries a 64-byte
// Ed25519 signature over the MANIFEST below, which names the version, the file name, its
// size, its SHA-256 and the app's CDHash (the main executable's code directory hash, as
// `codesign -dvvv` prints it: it covers Info.plist and the resource seal, so every file
// of the bundle). Signing the manifest instead of the raw zip binds the version (an old
// signed zip cannot be offered as a newer release) and the unpacked bundle (its CDHash is
// checked again right before it replaces Deckhand); the verifier never holds the ~340 MB
// zip in memory; the zip's bytes are still covered through SHA-256.
//
// Keys: the private key is the 32-byte Ed25519 seed, base64 (44 characters), in a 0600
// file on the release signer's Mac only (scripts/release.sh); the public key is 32
// bytes, base64, compiled into the app (src/update_key.odin).

import "core:crypto"
import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

// the formats' names, kept from Deckhand (the rename to Deckhand changed no format)
MANIFEST_HEAD :: "pi-desk update v2"
SIG_FILE_HEAD :: "pi-desk-update-sig v2"
SIG_SIZE :: ed25519.SIGNATURE_SIZE // 64
SEED_SIZE :: ed25519.PRIVATE_KEY_SIZE // 32
PUB_SIZE :: ed25519.PUBLIC_KEY_SIZE // 32
// src/update_key.odin's value until a real key is put in; release.sh refuses to ship it
PLACEHOLDER_PREFIX :: "PLACEHOLDER"

// The signed message: one field per line, "\n"-terminated, nothing else.
manifest :: proc(version, file_name: string, size: i64, sha256_hex, cdhash: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s\nversion %s\nfile %s\nsize %d\nsha256 %s\ncdhash %s\n", MANIFEST_HEAD, version, file_name, size, strings.to_lower(sha256_hex, context.temp_allocator), strings.to_lower(cdhash, context.temp_allocator), allocator = allocator)
}

// A CDHash as codesign prints it: 40 (SHA-256 truncated) or 64 hex digits.
cdhash_valid :: proc(s: string) -> bool {
	if len(s) != 40 && len(s) != 64 do return false
	for c in transmute([]byte)s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case:
			return false
		}
	}
	return true
}

// The .sig file's text.
sig_file_make :: proc(cdhash, sig_b64: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s\ncdhash %s\nsignature %s\n", SIG_FILE_HEAD, strings.to_lower(cdhash, context.temp_allocator), sig_b64, allocator = allocator)
}

// A .sig file: its CDHash (lower case) and signature (temp allocator), or ok = false. Exactly
// the three lines, in order.
sig_file_parse :: proc(text: string) -> (cdhash, sig_b64: string, ok: bool) {
	if len(text) > 4096 do return
	lines := strings.split_lines(strings.trim_right(text, "\n"), context.temp_allocator)
	if len(lines) != 3 || lines[0] != SIG_FILE_HEAD do return
	if !strings.has_prefix(lines[1], "cdhash ") || !strings.has_prefix(lines[2], "signature ") do return
	cdhash = strings.to_lower(lines[1][len("cdhash "):], context.temp_allocator)
	sig_b64 = lines[2][len("signature "):]
	if !cdhash_valid(cdhash) || len(sig_b64) == 0 do return "", "", false
	return cdhash, sig_b64, true
}

// A release's zip: ZIP_PREFIX + X.Y.Z + ZIP_SUFFIX (scripts/release.sh reads both from here)
ZIP_PREFIX :: "deckhand-"
ZIP_SUFFIX :: "-macos-arm64.zip"

// The release asset's name for a version.
zip_name :: proc(version: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s%s%s", ZIP_PREFIX, version, ZIP_SUFFIX, allocator = allocator)
}

// Base64 of exactly n bytes (surrounding whitespace ignored), or ok = false.
decode_exact :: proc(s: string, n: int, dst: []byte) -> bool {
	t := strings.trim_space(s)
	if len(t) == 0 || len(t) > 4 * ((n + 2) / 3) || len(dst) < n do return false
	for c in transmute([]byte)t {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/', '=':
		case:
			return false
		}
	}
	b, err := base64.decode(t, allocator = context.temp_allocator)
	if err != nil || len(b) != n do return false
	copy(dst, b)
	return true
}

is_placeholder :: proc(pub_b64: string) -> bool {
	return strings.has_prefix(pub_b64, PLACEHOLDER_PREFIX)
}

// Whether sig_b64 is a valid signature of msg by pub_b64. A placeholder or malformed key
// never verifies.
verify :: proc(pub_b64: string, msg: []byte, sig_b64: string) -> bool {
	if is_placeholder(pub_b64) do return false
	pub_raw: [PUB_SIZE]byte
	sig: [SIG_SIZE]byte
	if !decode_exact(pub_b64, PUB_SIZE, pub_raw[:]) do return false
	if !decode_exact(sig_b64, SIG_SIZE, sig[:]) do return false
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, pub_raw[:]) do return false
	defer ed25519.public_key_clear(&pk)
	return ed25519.verify(&pk, msg, sig[:])
}

// The base64 signature of msg with a base64 seed (temp allocator), or ok = false.
sign :: proc(seed_b64: string, msg: []byte) -> (sig_b64: string, ok: bool) {
	seed: [SEED_SIZE]byte
	defer crypto.zero_explicit(&seed, size_of(seed))
	if !decode_exact(seed_b64, SEED_SIZE, seed[:]) do return "", false
	sk: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&sk, seed[:]) do return "", false
	defer ed25519.private_key_clear(&sk)
	sig: [SIG_SIZE]byte
	ed25519.sign(&sk, msg, sig[:])
	out, err := base64.encode(sig[:], allocator = context.temp_allocator)
	if err != nil do return "", false
	return out, true
}

// The base64 public key of a base64 seed (temp allocator).
public_of :: proc(seed_b64: string) -> (pub_b64: string, ok: bool) {
	seed: [SEED_SIZE]byte
	defer crypto.zero_explicit(&seed, size_of(seed))
	if !decode_exact(seed_b64, SEED_SIZE, seed[:]) do return "", false
	sk: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&sk, seed[:]) do return "", false
	defer ed25519.private_key_clear(&sk)
	pub: [PUB_SIZE]byte
	ed25519.private_key_public_bytes(&sk, pub[:])
	out, err := base64.encode(pub[:], allocator = context.temp_allocator)
	if err != nil do return "", false
	return out, true
}

// A new key pair (temp allocator), from the system's random source.
generate :: proc() -> (seed_b64, pub_b64: string, ok: bool) {
	sk: ed25519.Private_Key
	if !ed25519.private_key_generate(&sk) do return "", "", false
	defer ed25519.private_key_clear(&sk)
	seed: [SEED_SIZE]byte
	defer crypto.zero_explicit(&seed, size_of(seed))
	ed25519.private_key_bytes(&sk, seed[:])
	pub: [PUB_SIZE]byte
	ed25519.private_key_public_bytes(&sk, pub[:])
	s, e1 := base64.encode(seed[:], allocator = context.temp_allocator)
	p, e2 := base64.encode(pub[:], allocator = context.temp_allocator)
	if e1 != nil || e2 != nil do return "", "", false
	return s, p, true
}

// A file's SHA-256 (lower-case hex, temp allocator) and size, read in pieces.
file_sha256 :: proc(path: string) -> (sum: string, size: i64, ok: bool) {
	f, err := os.open(path)
	if err != nil do return "", 0, false
	defer os.close(f)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buf := make([]byte, 1 << 20, context.temp_allocator)
	for {
		n, rerr := os.read(f, buf)
		if n > 0 {
			sha2.update(&ctx, buf[:n])
			size += i64(n)
		}
		if rerr == .EOF || (rerr == nil && n == 0) do break
		if rerr != nil do return "", 0, false
	}
	d: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, d[:])
	return string(hex.encode(d[:], context.temp_allocator)), size, true
}
