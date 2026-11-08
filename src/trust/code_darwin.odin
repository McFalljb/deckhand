#+build darwin
package trust

// The reads behind image_allowed: our own audit token, and the signing identity of a live
// process (by its audit token: what the kernel actually ran), of this process, and of a file.
// Security.framework and CoreFoundation, called directly. Identifiers are in the temp allocator.

import "core:c"
import "core:strings"

foreign import mach "system:System"
@(default_calling_convention = "c")
foreign mach {
	mach_task_self_: u32
	task_info :: proc(task: u32, flavor: c.int, info: rawptr, count: ^u32) -> c.int ---
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
CFRef :: rawptr

foreign import cf "system:CoreFoundation.framework"
@(default_calling_convention = "c")
foreign cf {
	kCFTypeDictionaryKeyCallBacks:   [6]rawptr
	kCFTypeDictionaryValueCallBacks: [5]rawptr
	CFDataCreate :: proc(alloc: CFRef, bytes: rawptr, n: c.long) -> CFRef ---
	CFDictionaryCreate :: proc(alloc: CFRef, keys: ^CFRef, values: ^CFRef, n: c.long, kcb: rawptr, vcb: rawptr) -> CFRef ---
	CFDictionaryGetValue :: proc(d: CFRef, key: CFRef) -> CFRef ---
	CFURLCreateFromFileSystemRepresentation :: proc(alloc: CFRef, path: [^]u8, n: c.long, is_dir: b8) -> CFRef ---
	CFStringGetCString :: proc(s: CFRef, buf: [^]u8, size: c.long, encoding: u32) -> b8 ---
	CFGetTypeID :: proc(x: CFRef) -> c.ulong ---
	CFStringGetTypeID :: proc() -> c.ulong ---
	CFRelease :: proc(x: CFRef) ---
}

foreign import sec "system:Security.framework"
@(default_calling_convention = "c")
foreign sec {
	kSecGuestAttributeAudit: CFRef
	kSecCodeInfoIdentifier:  CFRef
	SecCodeCopySelf :: proc(flags: u32, code: ^CFRef) -> i32 ---
	SecCodeCopyGuestWithAttributes :: proc(host: CFRef, attrs: CFRef, flags: u32, guest: ^CFRef) -> i32 ---
	SecCodeCheckValidity :: proc(code: CFRef, flags: u32, req: CFRef) -> i32 ---
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

// The signing identifier of code (a SecCodeRef or SecStaticCodeRef); "" if none.
@(private = "file")
identifier_of :: proc(code: CFRef) -> string {
	info: CFRef
	if SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) != 0 || info == nil do return ""
	defer CFRelease(info)
	v := CFDictionaryGetValue(info, kSecCodeInfoIdentifier)
	if v == nil || CFGetTypeID(v) != CFStringGetTypeID() do return ""
	buf: [256]u8
	if !CFStringGetCString(v, &buf[0], len(buf), kCFStringEncodingUTF8) do return ""
	return strings.clone(string(cstring(&buf[0])), context.temp_allocator)
}

// The running process the token names (the exact image: a token from before an exec of that
// pid has no code, errSecCSNoSuchCode).
code_identity_of_token :: proc(tok: Audit_Token) -> Code_Identity {
	tok := tok
	data := CFDataCreate(nil, &tok, size_of(tok))
	if data == nil do return {}
	defer CFRelease(data)
	key, val := kSecGuestAttributeAudit, data
	attrs := CFDictionaryCreate(nil, &key, &val, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	if attrs == nil do return {}
	defer CFRelease(attrs)
	code: CFRef
	if SecCodeCopyGuestWithAttributes(nil, attrs, 0, &code) != 0 || code == nil do return {}
	defer CFRelease(code)
	return Code_Identity{ok = true, valid = SecCodeCheckValidity(code, 0, nil) == 0, identifier = identifier_of(code)}
}

code_identity_self :: proc() -> Code_Identity {
	code: CFRef
	if SecCodeCopySelf(0, &code) != 0 || code == nil do return {}
	defer CFRelease(code)
	return Code_Identity{ok = true, valid = SecCodeCheckValidity(code, 0, nil) == 0, identifier = identifier_of(code)}
}

// A file's static code (strict validation). Only an early check: the file may change before it
// runs; the live check is code_identity_of_token.
code_identity_of_file :: proc(path: string) -> Code_Identity {
	url := CFURLCreateFromFileSystemRepresentation(nil, raw_data(path), c.long(len(path)), false)
	if url == nil do return {}
	defer CFRelease(url)
	code: CFRef
	if SecStaticCodeCreateWithPath(url, 0, &code) != 0 || code == nil do return {}
	defer CFRelease(code)
	id := identifier_of(code)
	if id == "" do return {}
	return Code_Identity{ok = true, valid = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, nil) == 0, identifier = id}
}
