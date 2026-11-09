#+build darwin
package trust

// The reads behind image_allowed: our own audit token, and the signing identity of a live
// process (by its audit token: what the kernel actually ran), of this process, and of a file.
// Identifiers are in the temp allocator.
//
// And the designated-requirement checks (§5.3, §5.4): own_signature (our mode, from SecCodeCopySelf),
// code_check_token (a peer's code by its audit token: SecCodeCopyGuestWithAttributes, then
// SecCodeCheckValidity(kSecCSStrictValidate) against peer_requirement), peer_dr_check (both, and
// peer_code_allowed). Never from a forked child that has not exec'd (the keeper): Security.framework
// talks to daemons over XPC.
//
// Live processes go through the kernel (csops_audittoken: the code-signing status and identifier
// the kernel holds for exactly that pid and pidversion; a token from before an exec of the pid
// fails, ESRCH). A plain syscall, so the upgrade's keeper, a forked child that never exec'd, can
// make it: Security.framework's XPC is not safe after fork. Files go through Security.framework
// (only ever called by a process that was exec'd normally).

import "base:runtime"
import "core:c"
import "core:crypto/legacy/sha1"
import "core:encoding/hex"
import "core:strings"
import "core:sync"
import CF "core:sys/darwin/CoreFoundation"

foreign import mach "system:System"
@(default_calling_convention = "c")
foreign mach {
	mach_task_self_: u32
	task_info :: proc(task: u32, flavor: c.int, info: rawptr, count: ^u32) -> c.int ---
	csops_audittoken :: proc(pid: c.int, ops: u32, buf: rawptr, size: c.size_t, token: ^Audit_Token) -> c.int ---
}

@(private = "file")
CS_OPS_STATUS :: 0
@(private = "file")
CS_OPS_IDENTITY :: 11
@(private = "file")
CS_VALID :: 0x1

// The kernel's code-signing status of the process the token names (CS_* flags); ok = false: no
// such process (or image) any more.
@(private = "file")
kernel_flags :: proc(tok: Audit_Token) -> (flags: u32, ok: bool) {
	tok := tok
	if csops_audittoken(c.int(tok.val[5]), CS_OPS_STATUS, &flags, size_of(flags), &tok) != 0 do return 0, false
	return flags, true
}

// The kernel's view of the process the token names (that exact image).
@(private = "file")
kernel_identity :: proc(tok: Audit_Token) -> Code_Identity {
	tok := tok
	pid := c.int(tok.val[5])
	flags: u32
	if csops_audittoken(pid, CS_OPS_STATUS, &flags, size_of(flags), &tok) != 0 do return {}
	// a blob: magic u32 BE, length u32 BE, then the identifier, NUL-terminated
	buf: [1024]u8
	if csops_audittoken(pid, CS_OPS_IDENTITY, &buf[0], len(buf), &tok) != 0 do return {ok = true, valid = flags & CS_VALID != 0}
	n := int(buf[4]) << 24 | int(buf[5]) << 16 | int(buf[6]) << 8 | int(buf[7])
	if n <= 8 || n > len(buf) do return {ok = true, valid = flags & CS_VALID != 0}
	id := string(cstring(&buf[8]))
	if len(id) > n - 8 do id = id[:n - 8]
	return Code_Identity{ok = true, valid = flags & CS_VALID != 0, identifier = strings.clone(id, context.temp_allocator)}
}

TASK_AUDIT_TOKEN :: 15

// This process as a peer would see it (pid, pidversion, euid), from its own audit token.
self_peer :: proc() -> Peer {
	tok: Audit_Token
	n := u32(8) // natural_t units
	if task_info(mach_task_self_, TASK_AUDIT_TOKEN, &tok, &n) != 0 do return {}
	return peer_of_token(tok)
}

@(private = "file")
CFRef :: CF.TypeRef // Odin's own CoreFoundation package's, so its declarations and ours agree

foreign import cf "system:CoreFoundation.framework"
@(default_calling_convention = "c")
foreign cf {
	CFDictionaryGetValue :: proc(d: CFRef, key: CFRef) -> CFRef ---
	CFURLCreateFromFileSystemRepresentation :: proc(alloc: CFRef, path: [^]u8, n: c.long, is_dir: b8) -> CFRef ---
	CFGetTypeID :: proc(x: CFRef) -> c.ulong ---
	CFStringGetTypeID :: proc() -> c.ulong ---
	CFDataGetTypeID :: proc() -> c.ulong ---
	CFNumberGetTypeID :: proc() -> c.ulong ---
	CFArrayGetTypeID :: proc() -> c.ulong ---
	CFDictionaryGetTypeID :: proc() -> c.ulong ---
	CFDataCreate :: proc(alloc: CFRef, bytes: [^]u8, n: CF.Index) -> CFRef ---
	CFDataGetLength :: proc(d: CFRef) -> CF.Index ---
	CFDataGetBytePtr :: proc(d: CFRef) -> [^]u8 ---
	CFArrayGetCount :: proc(a: CFRef) -> CF.Index ---
	CFArrayGetValueAtIndex :: proc(a: CFRef, i: CF.Index) -> CFRef ---
	CFNumberGetValue :: proc(n: CFRef, type: CF.Index, out: rawptr) -> b8 ---
	CFStringCreateWithBytes :: proc(alloc: CFRef, bytes: [^]u8, n: CF.Index, encoding: u32, external: b8) -> CFRef ---
	CFDictionaryCreate :: proc(alloc: CFRef, keys: [^]CFRef, values: [^]CFRef, n: CF.Index, key_cb: rawptr, value_cb: rawptr) -> CFRef ---
	kCFTypeDictionaryKeyCallBacks:   [6]rawptr // CFDictionaryKeyCallBacks: only ever passed by address
	kCFTypeDictionaryValueCallBacks: [5]rawptr
}

foreign import sec "system:Security.framework"
@(default_calling_convention = "c")
foreign sec {
	kSecCodeInfoIdentifier:  CFRef
	kSecCodeInfoFlags:       CFRef
	kSecCodeInfoCertificates: CFRef
	kSecCodeInfoTeamIdentifier: CFRef
	kSecCodeInfoPList:       CFRef
	kSecGuestAttributeAudit: CFRef
	SecStaticCodeCreateWithPath :: proc(url: CFRef, flags: u32, code: ^CFRef) -> i32 ---
	SecStaticCodeCheckValidity :: proc(code: CFRef, flags: u32, req: CFRef) -> i32 ---
	SecCodeCopySigningInformation :: proc(code: CFRef, flags: u32, info: ^CFRef) -> i32 ---
	SecCodeCopySelf :: proc(flags: u32, self: ^CFRef) -> i32 ---
	SecCodeCopyGuestWithAttributes :: proc(host: CFRef, attrs: CFRef, flags: u32, guest: ^CFRef) -> i32 ---
	SecCodeCheckValidity :: proc(code: CFRef, flags: u32, req: CFRef) -> i32 ---
	SecRequirementCreateWithString :: proc(text: CFRef, flags: u32, req: ^CFRef) -> i32 ---
	SecCertificateCopyData :: proc(cert: CFRef) -> CFRef ---
}

errSecCSNoSuchCode :: -67065 // the token's process exec'd since, or exited
errSecCSReqFailed :: -67050 // valid, but not what the requirement asks
@(private = "file")
kSecCodeSignatureAdhoc :: 0x0002
@(private = "file")
kCFNumberSInt64Type :: 4

@(private = "file")
kSecCSSigningInformation :: 1 << 1
@(private = "file")
kSecCSStrictValidate :: 1 << 4
@(private = "file")
kCFStringEncodingUTF8 :: 0x08000100

// The signing identifier of static code; "" if none.
@(private = "file")
identifier_of :: proc(code: CFRef) -> string {
	info: CFRef
	if SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) != 0 || info == nil do return ""
	defer CF.CFRelease(info)
	v := CFDictionaryGetValue(info, kSecCodeInfoIdentifier)
	if v == nil || CFGetTypeID(v) != CFStringGetTypeID() do return ""
	buf: [256]u8
	if !CF.StringGetCString(CF.String(v), &buf[0], CF.Index(len(buf)), CF.StringEncoding(kCFStringEncodingUTF8)) do return ""
	return strings.clone(string(cstring(&buf[0])), context.temp_allocator)
}

// The running process the token names (the exact image: a token from before an exec of that
// pid has no code).
code_identity_of_token :: proc(tok: Audit_Token) -> Code_Identity {return kernel_identity(tok)}

// This process's code.
code_identity_self :: proc() -> Code_Identity {
	tok: Audit_Token
	n := u32(8)
	if task_info(mach_task_self_, TASK_AUDIT_TOKEN, &tok, &n) != 0 do return {}
	return kernel_identity(tok)
}

// A file's static code (strict validation). Only an early check: the file may change before it
// runs; the live check is code_identity_of_token.
code_identity_of_file :: proc(path: string) -> Code_Identity {
	url := CFURLCreateFromFileSystemRepresentation(nil, raw_data(path), c.long(len(path)), false)
	if url == nil do return {}
	defer CF.CFRelease(url)
	code: CFRef
	if SecStaticCodeCreateWithPath(url, 0, &code) != 0 || code == nil do return {}
	defer CF.CFRelease(code)
	id := identifier_of(code)
	if id == "" do return {}
	return Code_Identity{ok = true, valid = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, nil) == 0, identifier = id}
}

// A CFString's UTF-8 ("" if v is not a string), in the temp allocator.
@(private = "file")
cf_string :: proc(v: CFRef) -> string {
	if v == nil || CFGetTypeID(v) != CFStringGetTypeID() do return ""
	buf: [1024]u8
	if !CF.StringGetCString(CF.String(v), &buf[0], CF.Index(len(buf)), CF.StringEncoding(kCFStringEncodingUTF8)) do return ""
	return strings.clone(string(cstring(&buf[0])), context.temp_allocator)
}

@(private = "file")
cf_string_make :: proc(s: string) -> CFRef {
	return CFStringCreateWithBytes(nil, raw_data(s), CF.Index(len(s)), kCFStringEncodingUTF8, false)
}

@(private = "file")
own_sig: Own_Signature
@(private = "file")
own_sig_once: sync.Once

// Our own signature and the mode it gives (§5.4), read once per process (heap strings). Never
// from a forked child that has not exec'd. ok = false: unreadable, and every DR check fails closed.
own_signature :: proc() -> Own_Signature {
	sync.once_do(&own_sig_once, proc() {own_sig = own_signature_read()})
	return own_sig
}

@(private = "file")
own_signature_read :: proc() -> Own_Signature {
	code: CFRef
	if SecCodeCopySelf(0, &code) != 0 || code == nil do return {}
	defer CF.CFRelease(code)
	info: CFRef
	if SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) != 0 || info == nil do return {}
	defer CF.CFRelease(info)
	id := cf_string(CFDictionaryGetValue(info, kSecCodeInfoIdentifier))
	if id == "" do return {}
	flags: i64
	fv := CFDictionaryGetValue(info, kSecCodeInfoFlags)
	if fv == nil || CFGetTypeID(fv) != CFNumberGetTypeID() || !CFNumberGetValue(fv, kCFNumberSInt64Type, &flags) do return {}
	adhoc := flags & kSecCodeSignatureAdhoc != 0
	leaf := ""
	if certs := CFDictionaryGetValue(info, kSecCodeInfoCertificates); !adhoc && certs != nil && CFGetTypeID(certs) == CFArrayGetTypeID() && CFArrayGetCount(certs) > 0 {
		if der := SecCertificateCopyData(CFArrayGetValueAtIndex(certs, 0)); der != nil {
			defer CF.CFRelease(der)
			ctx: sha1.Context
			sum: [sha1.DIGEST_SIZE]u8
			sha1.init(&ctx)
			sha1.update(&ctx, CFDataGetBytePtr(der)[:int(CFDataGetLength(der))])
			sha1.final(&ctx, sum[:])
			leaf = string(hex.encode(sum[:], context.temp_allocator))
		}
	}
	team := cf_string(CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier))
	apple := false
	if !adhoc {
		if req := requirement_make("anchor apple generic"); req != nil {
			apple = SecCodeCheckValidity(code, 0, req) == 0
			CF.CFRelease(req)
		}
	}
	mode, ok := mode_of_signature(adhoc, leaf, team, apple)
	if !ok do return {}
	heap := runtime.heap_allocator() // kept for the process's life
	return Own_Signature{ok = true, mode = mode, identifier = strings.clone(id, heap), leaf_sha1 = strings.clone(leaf, heap), team_id = strings.clone(team, heap)}
}

@(private = "file")
requirement_make :: proc(text: string) -> CFRef {
	str := cf_string_make(text)
	if str == nil do return nil
	defer CF.CFRelease(str)
	req: CFRef
	if SecRequirementCreateWithString(str, 0, &req) != 0 do return nil
	return req
}

// The code of the process a saved audit token names, checked (strict) against requirement
// (peer_requirement's text). A token from before an exec of its pid, or of a process that exited,
// finds no code (errSecCSNoSuchCode). Strings in the temp allocator.
code_check_token :: proc(tok: Audit_Token, requirement: string) -> Code_Check {
	out: Code_Check
	tok := tok
	tdata := CFDataCreate(nil, ([^]u8)(rawptr(&tok)), CF.Index(size_of(tok)))
	if tdata == nil do return out
	defer CF.CFRelease(tdata)
	keys := [1]CFRef{kSecGuestAttributeAudit}
	vals := [1]CFRef{tdata}
	attrs := CFDictionaryCreate(nil, &keys[0], &vals[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	if attrs == nil do return out
	defer CF.CFRelease(attrs)
	code: CFRef
	if st := SecCodeCopyGuestWithAttributes(nil, attrs, 0, &code); st != 0 || code == nil {
		out.status = st
		return out
	}
	defer CF.CFRelease(code)
	out.found = true
	req := requirement_make(requirement)
	if req == nil {
		out.status = -1
		return out
	}
	defer CF.CFRelease(req)
	out.status = SecCodeCheckValidity(code, kSecCSStrictValidate, req)
	switch out.status {
	case 0:
		out.valid, out.meets = true, true
	case errSecCSReqFailed:
		out.valid = true
	case errSecCSNoSuchCode:
		out.found = false // it exec'd (or exited) between the two calls
		return out
	}
	info: CFRef
	if SecCodeCopySigningInformation(code, 0, &info) == 0 && info != nil {
		defer CF.CFRelease(info)
		out.identifier = cf_string(CFDictionaryGetValue(info, kSecCodeInfoIdentifier))
		if pl := CFDictionaryGetValue(info, kSecCodeInfoPList); pl != nil && CFGetTypeID(pl) == CFDictionaryGetTypeID() {
			key := cf_string_make("CFBundleShortVersionString")
			if key != nil {
				out.version = cf_string(CFDictionaryGetValue(pl, key))
				CF.CFRelease(key)
			}
		}
	}
	// the kernel's flags for that very image (the token's pidversion): hardened runtime,
	// get-task-allow (Developer_Id); none if it is gone
	if f, ok := kernel_flags(tok); ok do out.flags = f
	else do out.found = false
	return out
}

// The designated-requirement check of a peer, by the audit token read at accept, before any byte
// was read from it (§5.3): its code must be one of ids, signed as we are (own_signature's mode).
peer_dr_check :: proc(tok: Audit_Token, ids: []string) -> (Decision, Code_Check) {
	own := own_signature()
	req, rok := peer_requirement(own, ids)
	if !rok do return .No_Code, {}
	got := code_check_token(tok, req)
	return peer_code_allowed(own, ids, got), got
}
