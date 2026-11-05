package pi_desk_cli

// A screenshot's PNG, checked rather than trusted (as pi-kit's desk/app.ts shotFile): after
// resolving symlinks it must be directly in realpath(PI_DESK_SHOTS_DIR), named `<tab>-<n>.png`, a
// regular file (opened without following a link) of at most SHOT_MAX bytes starting with the PNG
// signature. Only then is its path printed for Claude to Read.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

SHOT_MAX :: 8 << 20

real_path :: proc(p: string) -> (string, bool) {
	if p == "" do return "", false
	r := posix.realpath(strings.clone_to_cstring(p), nil)
	if r == nil do return "", false
	s := strings.clone(string(r))
	posix.free(rawptr(r))
	return s, true
}

shot_name_ok :: proc(tab: i64, base: string) -> bool {
	prefix := fmt.aprintf("%d-", tab)
	if !strings.has_prefix(base, prefix) || !strings.has_suffix(base, ".png") do return false
	digits := base[len(prefix):len(base) - 4]
	if len(digits) == 0 do return false
	for c in transmute([]u8)digits do if c < '0' || c > '9' do return false
	return true
}

// The checked real path, or why not.
shot_check :: proc(tab: i64, file, shots_dir: string) -> (path: string, why: string) {
	no := "not a Deckhand screenshot of this tab"
	if shots_dir == "" do return "", "PI_DESK_SHOTS_DIR is not set"
	if !strings.has_prefix(file, "/") do return "", no
	real, ok := real_path(file)
	if !ok do return "", "the file could not be read"
	want, wok := real_path(shots_dir)
	if !wok do return "", no
	if filepath.dir(real) != want || !shot_name_ok(tab, filepath.base(real)) do return "", no
	fd := posix.open(strings.clone_to_cstring(real), {.NOFOLLOW})
	if fd < 0 do return "", "the file could not be read"
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) do return "", no
	if st.st_size > SHOT_MAX do return "", "over 8 MB; ask for a smaller --rect"
	magic: [8]u8
	n := posix.read(fd, raw_data(magic[:]), 8)
	PNG :: [8]u8{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a}
	if n != 8 || magic != PNG do return "", "not a PNG"
	return real, ""
}
