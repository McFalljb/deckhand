package update_sign

// pi-desk's release signing tool (docs/DEVELOPING.md, "Update signing"). Build:
//   odin build tools/update-sign -out:build/update-sign
//
//   update-sign keygen FILE              a new key pair: the private key (base64 seed) into
//                                        FILE (created 0600, never overwritten); prints only
//                                        the public key, for src/update_key.odin
//   update-sign pubkey KEYFILE           the public key of the private key
//   update-sign sign KEYFILE VERSION ZIP CDHASH SIG
//                                        writes SIG: the signature of ZIP's manifest
//                                        (version, file name, size, SHA-256, the app's CDHash)
//   update-sign verify PUBKEY VERSION ZIP SIG   exit 0 if SIG is good for ZIP under PUBKEY
//   update-sign manifest VERSION ZIP CDHASH     prints the signed manifest
//
// The private key is read only from KEYFILE, which must be a regular file of yours with
// mode 0600 (or 0400); never from the environment. It is never printed or logged.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import sig "../../src/updatesig"

usage :: proc() -> int {
	fmt.eprintln("usage: update-sign keygen FILE | pubkey KEYFILE | sign KEYFILE VERSION ZIP CDHASH SIG | verify PUBKEY VERSION ZIP SIG | manifest VERSION ZIP CDHASH")
	return 2
}

main :: proc() {
	os.exit(run(os.args[1:]))
}

run :: proc(args: []string) -> int {
	if len(args) == 0 do return usage()
	switch args[0] {
	case "keygen":
		if len(args) != 2 do return usage()
		return keygen(args[1])
	case "pubkey":
		if len(args) != 2 do return usage()
		seed, ok := private_key(args[1])
		if !ok do return 1
		pub, pok := sig.public_of(seed)
		if !pok {
			fmt.eprintln("update-sign: the private key is not a base64 Ed25519 seed (32 bytes)")
			return 1
		}
		fmt.println(pub)
		return 0
	case "sign":
		if len(args) != 6 do return usage()
		return sign(args[1], args[2], args[3], args[4], args[5])
	case "verify":
		if len(args) != 5 do return usage()
		data, rerr := os.read_entire_file(args[4], context.temp_allocator)
		if rerr != nil {
			fmt.eprintln("update-sign: cannot read", args[4])
			return 1
		}
		cd, b64, pok := sig.sig_file_parse(string(data))
		if !pok {
			fmt.eprintln("update-sign: not a Deckhand .sig file")
			return 1
		}
		m, ok := manifest_of(args[2], args[3], cd)
		if !ok do return 1
		if !sig.verify(args[1], transmute([]byte)m, b64) {
			fmt.eprintln("update-sign: BAD signature")
			return 1
		}
		fmt.println("update-sign: signature ok")
		return 0
	case "manifest":
		if len(args) != 4 do return usage()
		m, ok := manifest_of(args[1], args[2], args[3])
		if !ok do return 1
		fmt.print(m)
		return 0
	}
	return usage()
}

valid_version :: proc(v: string) -> bool {
	parts := strings.split(v, ".", context.temp_allocator)
	if len(parts) != 3 do return false
	for p in parts {
		if len(p) == 0 || len(p) > 9 || (len(p) > 1 && p[0] == '0') do return false
		for c in transmute([]byte)p do if c < '0' || c > '9' do return false
	}
	return true
}

manifest_of :: proc(version, zip, cdhash: string) -> (string, bool) {
	if !sig.cdhash_valid(cdhash) {
		fmt.eprintln("update-sign: CDHASH must be the app's CDHash (40 or 64 hex digits, codesign -dvvv)")
		return "", false
	}
	if !valid_version(version) {
		fmt.eprintln("update-sign: VERSION must be X.Y.Z (releases with a suffix are not offered as updates)")
		return "", false
	}
	name := sig.zip_name(version, context.temp_allocator)
	if filepath.base(zip) != name {
		fmt.eprintf("update-sign: %s is not named %s\n", zip, name)
		return "", false
	}
	sum, size, ok := sig.file_sha256(zip)
	if !ok {
		fmt.eprintln("update-sign: cannot read", zip)
		return "", false
	}
	return sig.manifest(version, name, size, sum, cdhash, context.temp_allocator), true
}

// The base64 seed from a key file that only its owner can read. Opened with O_NOFOLLOW (a
// link is refused) and checked on the open descriptor (fstat: a regular file, owned by this
// user, mode 600 or 400), then read from that descriptor: no path is looked up twice. Its
// folder must not be writable by group or others (they could swap the file).
private_key :: proc(path: string) -> (string, bool) {
	parent: posix.stat_t
	if posix.stat(strings.clone_to_cstring(filepath.dir(path), context.temp_allocator), &parent) != .OK {
		fmt.eprintln("update-sign: cannot read the key file's folder")
		return "", false
	}
	if .IWGRP in parent.st_mode || .IWOTH in parent.st_mode {
		fmt.eprintf("update-sign: the key file's folder %s is writable by others: chmod 700 it first\n", filepath.dir(path))
		return "", false
	}
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW})
	if fd < 0 {
		fmt.eprintln("update-sign: cannot open the key file (missing, or a link):", path)
		return "", false
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) {
		fmt.eprintln("update-sign: the key file is not a regular file:", path)
		return "", false
	}
	if st.st_uid != posix.getuid() {
		fmt.eprintln("update-sign: the key file is not yours:", path)
		return "", false
	}
	if st.st_mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH} != {} {
		fmt.eprintf("update-sign: %s is readable by others: chmod 600 it first\n", path)
		return "", false
	}
	if st.st_size <= 0 || st.st_size > 4096 {
		fmt.eprintln("update-sign: the key file is not a key (size)")
		return "", false
	}
	buf := make([]u8, int(st.st_size), context.temp_allocator)
	got := 0
	for got < len(buf) {
		n := posix.read(fd, raw_data(buf[got:]), uint(len(buf)) - uint(got))
		if n <= 0 do break
		got += int(n)
	}
	key := strings.trim_space(string(buf[:got]))
	return key, key != ""
}

sign :: proc(key_file, version, zip, cdhash, out: string) -> int {
	seed, ok := private_key(key_file)
	if !ok do return 1
	m, mok := manifest_of(version, zip, cdhash)
	if !mok do return 1
	s, sok := sig.sign(seed, transmute([]byte)m)
	if !sok {
		fmt.eprintln("update-sign: the private key is not a base64 Ed25519 seed (32 bytes)")
		return 1
	}
	if err := os.write_entire_file(out, transmute([]byte)sig.sig_file_make(cdhash, s, context.temp_allocator)); err != nil {
		fmt.eprintln("update-sign: cannot write", out)
		return 1
	}
	pub, _ := sig.public_of(seed)
	fmt.printf("update-sign: signed %s (public key %s)\n", filepath.base(zip), pub)
	return 0
}

keygen :: proc(path: string) -> int {
	seed, pub, ok := sig.generate()
	if !ok {
		fmt.eprintln("update-sign: no random source")
		return 1
	}
	// O_EXCL: never over an existing key; 0600 from the start
	f, err := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if err != nil {
		fmt.eprintf("update-sign: cannot create %s (does it exist already?)\n", path)
		return 1
	}
	_, werr := os.write_string(f, fmt.tprintf("%s\n", seed))
	os.close(f)
	if werr != nil {
		fmt.eprintln("update-sign: cannot write", path)
		return 1
	}
	fmt.printf("private key written to %s (0600; keep it secret, on this Mac only, with an offline backup)\n", path)
	fmt.printf("public key (src/update_key.odin, UPDATE_PUBLIC_KEY): %s\n", pub)
	return 0
}
