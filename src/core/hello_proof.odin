package core

// The challenge hello's proofs (docs/PROTOCOL.md §2 "The challenge hello"; docs/plans/
// background-core.md §10.3 M4-B). A bridge's reconnect token never crosses the socket again:
// each side proves it knows the token's key with an HMAC over both sides' nonces, the core
// first, so a program listening where the core should be learns nothing it can use.
//
//   key       = SHA-256(token)                    what tokens.json keeps (token_hash)
//   token_id  = HMAC-SHA256(key, "deckhand-token-id-v1")          names the token, reveals nothing
//   proof(r)  = HMAC-SHA256(key, "deckhand-hello-v1\n" r "\n" token_id "\n" client_nonce "\n"
//                                core_nonce "\n" pid)               r: "core" or "client"
//
// Everything is lowercase hex (64 digits) and pid is decimal: the connecting process's pid as
// the core reads it from the socket (LOCAL_PEERPID) and as the client knows itself
// (process.pid). Binding the pid stops a relay: a program that forwards a bridge's hello to the
// core is the core's peer, so the core's proof names its pid, which the bridge refuses, and the
// bridge's proof names the bridge's pid, which the core refuses.
//
// The same computation is in integrations/pi/lib/protocol.ts (helloProof); hello_proof_test.odin
// and integrations/pi/test/unit.test.ts check both against one vector.

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:fmt"

HELLO_TOKEN_ID_TAG :: "deckhand-token-id-v1"
HELLO_PROOF_TAG :: "deckhand-hello-v1"

// The token's name in a challenge hello, from its key (SHA-256 of the token).
hello_token_id :: proc(key: [32]u8) -> (id: [32]u8) {
	k := key
	tag := HELLO_TOKEN_ID_TAG
	hmac.sum(hash.Algorithm.SHA256, id[:], transmute([]u8)tag, k[:])
	return
}

hello_proof :: proc(key: [32]u8, role: string, token_id, client_nonce, core_nonce: string, pid: i32) -> (p: [32]u8) {
	k := key
	msg := fmt.tprintf("%s\n%s\n%s\n%s\n%s\n%d", HELLO_PROOF_TAG, role, token_id, client_nonce, core_nonce, pid)
	hmac.sum(hash.Algorithm.SHA256, p[:], transmute([]u8)msg, k[:])
	return
}

// Whether s is 64 lowercase hex digits (a nonce, a token id or a proof on the wire).
hex64_ok :: proc(s: string) -> bool {
	if len(s) != 64 do return false
	for ch in transmute([]u8)s do if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) do return false
	return true
}

hex32 :: proc(b: [32]u8, allocator := context.temp_allocator) -> string {
	x := b
	return string(hex.encode(x[:], allocator))
}

// Constant time: whether two 64-digit hex strings are equal.
hex64_equal :: proc(a, b: string) -> bool {
	if len(a) != 64 || len(b) != 64 do return false
	return crypto.compare_constant_time(transmute([]u8)a, transmute([]u8)b) == 1
}
