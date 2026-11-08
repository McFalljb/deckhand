#+build darwin
package trust

// The reads behind image_allowed: our own audit token, and the signing identity of a live
// process (by its audit token: what the kernel actually ran), of this process, and of a file.
// Identifiers are in the temp allocator.
//
// Live processes go through the kernel (csops_audittoken: the code-signing status and identifier
// the kernel holds for exactly that pid and pidversion; a token from before an exec of the pid
// fails, ESRCH). A plain syscall, so the upgrade's keeper, a forked child that never exec'd, can
// make it: Security.framework's XPC is not safe after fork. Files go through Security.framework
// (only ever called by a process that was exec'd normally).

import "core:c"
import "core:strings"
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
}

foreign import sec "system:Security.framework"
@(default_calling_convention = "c")
foreign sec {
	kSecCodeInfoIdentifier:  CFRef
	SecStaticCodeCreateWithPath :: proc(url: CFRef, flags: u32, code: ^CFRef) -> i32 ---
	SecStaticCodeCheckValidity :: proc(code: CFRef, flags: u32, req: CFRef) -> i32 ---
	SecCodeCopySigningInformation :: proc(code: CFRef, flags: u32, info: ^CFRef) -> i32 ---
}

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
