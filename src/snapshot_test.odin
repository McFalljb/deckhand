package main

// Terminal snapshots (snapshot.odin, design §5.5 and §7.2).

import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core"
import gh "ghostty"

// Every terminal tracks its unfinished escape from creation, so it can be
// snapshotted at any byte offset: one from term_init and one from term_start.
@(test)
term_tracks_continuation :: proc(t: ^testing.T) {
	core.app_context = context
	check :: proc(t: ^testing.T, gt: gh.Terminal, what: string) {
		limit: c.size_t
		gh.terminal_get(gt, .Continuation_Max_Bytes, &limit)
		testing.expectf(t, limit == core.TERM_CONTINUATION_MAX, "%s: continuation limit %d", what, limit)
		s := "abc\x1b[38;2;10;20"
		gh.terminal_vt_write(gt, raw_data(s), len(s))
		p: [^]u8
		n: c.size_t
		r := gh.snapshot_encode_alloc(gt, nil, &p, &n)
		testing.expectf(t, r == .Success, "%s: snapshot mid-escape: %v", what, r)
		if r == .Success do gh.free(nil, p, n)
	}
	term := new(core.Term)
	defer free(term)
	testing.expect(t, core.term_init(term, 40, 5))
	check(t, term.gt, "term_init")
	core.term_start(term, {"/bin/sh", "-c", "exit 0"}, "/tmp")
	check(t, term.gt, "term_start")
	core.term_free(term)
}

// ---- the corpus (a subset of S1's; the full run is tools/vt-snapshot-spike on spike/vt-snapshot) ----

@(private = "file")
Snap_Resize :: struct {
	cols, rows: u16,
}
@(private = "file")
Snap_Event :: union {
	string,
	Snap_Resize,
}
@(private = "file")
Snap_Case :: struct {
	name:       string,
	cols, rows: u16,
	events:     []Snap_Event,
}

ESC :: "\x1b"

// Built once, outside the tests' allocators (the tests reset the temp one).
@(private = "file")
snap_corpus_cache: []Snap_Case

@(private = "file")
snap_corpus :: proc() -> []Snap_Case {
	if snap_corpus_cache == nil do snap_corpus_cache = snap_corpus_build()
	return snap_corpus_cache
}

@(private = "file")
snap_corpus_build :: proc() -> []Snap_Case {
	a := runtime.heap_allocator()
	out := make([dynamic]Snap_Case, a)
	ls, _ := os.read_entire_file("tests/vt-corpus/ls.bin", a)
	append(&out, Snap_Case{"ls-real", 120, 40, slice.clone([]Snap_Event{string(ls), "$ "}, a)})

	vim := strings.builder_make(a)
	strings.write_string(&vim, ESC + "]0;vim main.odin\x07" + ESC + "[?1049h" + ESC + "[?1h" + ESC + "=" + ESC + "[?2004h" + ESC + "[?1002h" + ESC + "[?1006h" + ESC + "[?25l")
	strings.write_string(&vim, ESC + "[H" + ESC + "[2J" + ESC + "[1;18r")
	for y in 1 ..= 18 do fmt.sbprintf(&vim, ESC + "[%d;1H" + ESC + "[38;5;244m%3d " + ESC + "[0m" + ESC + "[38;2;200;120;%dmproc" + ESC + "[0m " + ESC + "[1;3mname_%d" + ESC + "[0m", y, y, y * 8, y)
	strings.write_string(&vim, ESC + "[19;1H" + ESC + "[7m main.odin [+]" + ESC + "[K" + ESC + "[0m" + ESC + "[20;1H-- INSERT --")
	strings.write_string(&vim, ESC + "[18;1H\n\n" + ESC + "[38;5;196mscrolled" + ESC + "[0m" + ESC + "[1;1H" + ESC + "M" + "top" + ESC + "[2S" + ESC + "[1T")
	strings.write_string(&vim, ESC + "[?6h" + ESC + "[5;10Horigin" + ESC + "[?6l" + ESC + "[4 q" + ESC + "[?25h" + ESC + "[10;20H" + ESC + "7")
	append(&out, Snap_Case{"vim-alt", 80, 20, slice.clone([]Snap_Event{"$ history\r\n$ vim main.odin\r\n", strings.to_string(vim), ESC + "[12;5Htyping" + ESC + "[4hINS" + ESC + "[4l"}, a)})

	htop := strings.builder_make(a)
	state := rand.create(7)
	gen := rand.default_random_generator(&state)
	strings.write_string(&htop, ESC + "[?1049h" + ESC + "[?1000h")
	sgr := [?]string{"[1;4m", "[2;9m", "[4:3m" + ESC + "[58;2;255;0;0m", "[53;5m", "[7;8m", "[0m", "[22;24;27;28m"}
	for _ in 0 ..< 3 {
		for y in 1 ..= 24 {
			fmt.sbprintf(&htop, ESC + "[%d;1H", y)
			for x := 0; x < 70; {
				switch rand.int_max(4, gen) {
				case 0: fmt.sbprintf(&htop, ESC + "[38;5;%dm", rand.int_max(256, gen))
				case 1: fmt.sbprintf(&htop, ESC + "[48;2;%d;%d;%dm", rand.int_max(256, gen), rand.int_max(256, gen), rand.int_max(256, gen))
				case: strings.write_string(&htop, ESC); strings.write_string(&htop, sgr[rand.int_max(len(sgr), gen)])
				}
				n := 1 + rand.int_max(10, gen)
				for _ in 0 ..< n do strings.write_byte(&htop, u8('a' + rand.int_max(26, gen)))
				x += n
			}
			strings.write_string(&htop, ESC + "[K")
		}
	}
	append(&out, Snap_Case{"htop-sgr", 80, 24, slice.clone([]Snap_Event{strings.to_string(htop)}, a)})

	uni := strings.builder_make(a)
	for i in 0 ..< 20 do fmt.sbprintf(&uni, "日本語 中文 한국어 👨‍👩‍👧 🇯🇵 👍🏽 ❤️ e\u0301 " + ESC + "[3%dm%d" + ESC + "[0m\r\n", i % 8, i)
	strings.write_string(&uni, ESC + "[5;40H漢字" + ESC + "[8;39H😀😀")
	append(&out, Snap_Case{"unicode", 40, 12, slice.clone([]Snap_Event{strings.to_string(uni)}, a)})

	links := strings.builder_make(a)
	for i in 0 ..< 20 do fmt.sbprintf(&links, "see " + ESC + "]8;id=l%d;https://example.com/%d" + ESC + "\\link" + ESC + "]8;;" + ESC + "\\ " + ESC + "]8;;file:///tmp/f%d\x07" + ESC + "[4mfile" + ESC + "[24m" + ESC + "]8;;\x07\r\n", i, i, i)
	strings.write_string(&links, ESC + "]8;;https://open.example/" + ESC + "\\open")
	append(&out, Snap_Case{"osc8", 60, 12, slice.clone([]Snap_Event{strings.to_string(links)}, a)})

	append(&out, Snap_Case{"partial-esc", 60, 10, slice.clone([]Snap_Event{"hello " + ESC + "[1mbold" + ESC + "[0m\r\n", ESC + "[38;2;10", ";20;30mtrue" + ESC + "[0m ", "\xe6\x97", "\xa5 " + ESC + "]2;partial ti", "tle" + ESC + "\\" + ESC + "P", "+q544e" + ESC + "\\dcs\r\n" + ESC, "[31mred" + ESC + "[0m"}, a)})

	long := strings.builder_make(a)
	for i in 0 ..< 80 do fmt.sbprintf(&long, ESC + "[3%dmline %d " + ESC + "[0m%s\r\n", i % 8, i, strings.repeat("wrapping text ", 1 + i % 6, a))
	append(&out, Snap_Case{"resize", 60, 16, slice.clone([]Snap_Event{strings.to_string(long), Snap_Resize{90, 20}, strings.concatenate({"grown ", strings.repeat("x", 120, a), "\r\n"}, a), Snap_Resize{40, 12}, "shrunk " + ESC + "[1;1Htop", ESC + "[?1049h alt " + ESC + "[5;5Hin alt", Snap_Resize{50, 14}, "more"}, a)})

	misc := strings.builder_make(a)
	strings.write_string(&misc, "shell\r\n" + ESC + "]7;file://host/tmp/proj" + ESC + "\\" + ESC + "]4;1;rgb:12/34/56" + ESC + "\\" + ESC + "]10;rgb:ee/dd/cc" + ESC + "\\" + ESC + "]11;rgb:11/22/33" + ESC + "\\" + ESC + "]12;rgb:ff/00/ff" + ESC + "\\")
	strings.write_string(&misc, ESC + "[3g" + ESC + "[1;5H" + ESC + "H" + ESC + "[1;13H" + ESC + "H" + ESC + "[H\tA\tB\r\n" + ESC + "(0lqqk" + ESC + "(B\r\n" + ESC + ")0\x0elqk\x0f SO/SI\r\n")
	strings.write_string(&misc, ESC + "[1\"qprotected" + ESC + "[0\"q not\r\n" + ESC + "[?69h" + ESC + "[5;60s" + ESC + "[5;20r" + ESC + "[?7l" + ESC + "[6;55Hno autowrap past the margin" + ESC + "[?7h")
	strings.write_string(&misc, ESC + "[?45h" + ESC + "[?1004h" + ESC + "[?2031h" + ESC + "[>1u" + ESC + "[>4;2m" + ESC + "[20h" + ESC + "[?5h" + ESC + "[?12h")
	strings.write_string(&misc, ESC + "]133;A" + ESC + "\\$ " + ESC + "]133;B" + ESC + "\\ls" + ESC + "]133;C" + ESC + "\\")
	strings.write_string(&misc, ESC + "[1;3;38;5;208m" + ESC + "[10;8H" + ESC + "7" + ESC + "[15;30H" + ESC + "[0;48;5;22m" + ESC + "[24;80HX")
	append(&out, Snap_Case{"misc-state", 80, 24, slice.clone([]Snap_Event{strings.to_string(misc)}, a)})
	return out[:]
}

// A terminal as Deckhand makes one (term_new_gt), without a Term.
@(private = "file")
snap_gt :: proc(cols, rows: u16) -> gh.Terminal {
	gt: gh.Terminal
	gh.terminal_new(nil, &gt, cols, rows)
	sb := uint(core.TERM_SCROLLBACK_MAX)
	gh.terminal_set(gt, .Scrollback_Max_Bytes, &sb)
	limit := core.TERM_CONTINUATION_MAX
	gh.terminal_set(gt, .Continuation_Max_Bytes, &limit)
	mc := gh.Mode_Config{mode = gh.mode_dec(2027), value = true}
	gh.terminal_set(gt, .Mode, &mc)
	return gt
}

@(private = "file")
snap_write :: proc(gt: gh.Terminal, s: string) {if len(s) > 0 do gh.terminal_vt_write(gt, raw_data(s), len(s))}

// Feeds s in random chunks, heavy on small ones so escapes split.
@(private = "file")
snap_feed :: proc(gt: gh.Terminal, s: string, gen: rand.Generator) {
	for i := 0; i < len(s); {
		n: int
		switch rand.int_max(3, gen) {
		case 0: n = 1 + rand.int_max(3, gen)
		case 1: n = 1 + rand.int_max(64, gen)
		case: n = 1 + rand.int_max(4096, gen)
		}
		n = min(n, len(s) - i)
		snap_write(gt, s[i:i + n])
		i += n
	}
}

@(private = "file")
snap_apply :: proc(gt: gh.Terminal, ev: Snap_Event, gen: rand.Generator) {
	switch e in ev {
	case string: snap_feed(gt, e, gen)
	case Snap_Resize: gh.terminal_resize(gt, e.cols, e.rows, 8, 16)
	}
}

@(private = "file")
snap_dump :: proc(gt: gh.Terminal) -> string {
	sb := strings.builder_make(context.temp_allocator)
	core.screen_dump(gt, &sb)
	return strings.to_string(sb)
}

// Equal dumps, or the first differing line.
@(private = "file")
snap_same :: proc(t: ^testing.T, a, b: gh.Terminal, what: string) -> bool {
	da, db := snap_dump(a), snap_dump(b)
	if da == db do return true
	la, lb := strings.split_lines(da, context.temp_allocator), strings.split_lines(db, context.temp_allocator)
	for i in 0 ..< max(len(la), len(lb)) {
		x := i < len(la) ? la[i] : "<none>"
		y := i < len(lb) ? lb[i] : "<none>"
		if x != y {
			testing.expectf(t, false, "%s: line %d differs\n  A: %.200s\n  B: %.200s", what, i, x, y)
			break
		}
	}
	return false
}

// Snapshot at a random byte of a random event, rebuild, feed both the rest
// (resizes at the same offset), compare before and after the probes.
@(private = "file")
snap_roundtrip :: proc(t: ^testing.T, cs: Snap_Case, seed: u64, formats: []string) -> (exact: bool, meta: core.Snapshot_Meta) {
	state := rand.create(seed)
	gen := rand.default_random_generator(&state)
	a := snap_gt(cs.cols, cs.rows)
	defer gh.terminal_free(a)
	b: gh.Terminal
	defer if b != nil do gh.terminal_free(b)
	at := rand.int_max(len(cs.events) + 1, gen)
	take :: proc(t: ^testing.T, a: gh.Terminal, formats: []string, cs: Snap_Case, meta: ^core.Snapshot_Meta) -> gh.Terminal {
		blob, used, err := core.snapshot_encode(a, {offset = 42}, formats, true, context.temp_allocator)
		if !testing.expectf(t, err == .None, "%s: encode %v", cs.name, err) do return nil
		gt, m, derr := core.snapshot_decode(blob)
		testing.expectf(t, derr == .None, "%s: decode %v", cs.name, derr)
		testing.expect_value(t, m.format, used.format)
		testing.expect_value(t, m.offset, 42)
		meta^ = m
		return gt
	}
	for ev, i in cs.events {
		if i == at {
			if s, ok := ev.(string); ok {
				cut := rand.int_max(len(s) + 1, gen)
				snap_feed(a, s[:cut], gen)
				b = take(t, a, formats, cs, &meta)
				if b == nil do return false, meta
				s2 := rand.create(seed ~ 0x5eed)
				g2 := rand.default_random_generator(&s2)
				s3 := s2
				g3 := rand.default_random_generator(&s3)
				snap_feed(a, s[cut:], g2)
				snap_feed(b, s[cut:], g3)
				continue
			}
			b = take(t, a, formats, cs, &meta)
			if b == nil do return false, meta
		}
		if b == nil {
			snap_apply(a, ev, gen)
		} else {
			s2 := rand.create(seed + u64(i))
			g2 := rand.default_random_generator(&s2)
			s3 := s2
			g3 := rand.default_random_generator(&s3)
			snap_apply(a, ev, g2)
			snap_apply(b, ev, g3)
		}
	}
	if b == nil do b = take(t, a, formats, cs, &meta)
	if b == nil do return false, meta
	return core.screen_equal_probed(a, b), meta
}

@(test)
snapshot_corpus_roundtrip :: proc(t: ^testing.T) {
	for cs in snap_corpus() {
		for s in 0 ..< 10 {
			seed := t.seed + u64(s) * 104729
			exact, meta := snap_roundtrip(t, cs, seed, core.SNAPSHOT_FORMATS[:])
			testing.expectf(t, exact, "%s: GHOSTSNP round trip not exact (seed %d)", cs.name, seed)
			testing.expect_value(t, meta.format, core.SNAPSHOT_GHOSTSNP)
			testing.expect(t, !meta.inexact)
			free_all(context.temp_allocator)
		}
	}
}

// Same bytes, different chunking: the same screen hash.
@(test)
snapshot_determinism :: proc(t: ^testing.T) {
	for cs in snap_corpus() {
		hashes: [3]u64
		for s in 0 ..< 3 {
			state := rand.create(t.seed + u64(s))
			gen := rand.default_random_generator(&state)
			gt := snap_gt(cs.cols, cs.rows)
			for ev in cs.events do snap_apply(gt, ev, gen)
			both: bool
			hashes[s], both = core.screen_hash(gt)
			testing.expect(t, both)
			gh.terminal_free(gt)
		}
		testing.expectf(t, hashes[0] == hashes[1] && hashes[1] == hashes[2], "%s: hashes %v", cs.name, hashes)
		free_all(context.temp_allocator)
	}
}

// The VT fallback, for a peer without GHOSTSNP: inexact, exact where S1 found
// it so, and missing the screen behind the alt screen.
@(test)
snapshot_vt_fallback :: proc(t: ^testing.T) {
	vt_only := []string{core.SNAPSHOT_VT}
	corpus := snap_corpus()
	for cs in corpus {
		if cs.name != "ls-real" && cs.name != "unicode" && cs.name != "vim-alt" do continue
		a := snap_gt(cs.cols, cs.rows)
		for ev in cs.events do if s, ok := ev.(string); ok do snap_write(a, s)
		blob, meta, err := core.snapshot_encode(a, {}, vt_only, false, context.temp_allocator)
		testing.expect_value(t, err, core.Snapshot_Error.None)
		testing.expect_value(t, meta.format, core.SNAPSHOT_VT)
		testing.expect(t, meta.inexact)
		b, _, derr := core.snapshot_decode(blob)
		testing.expect_value(t, derr, core.Snapshot_Error.None)
		ha, _ := core.screen_hash(a)
		hb, _ := core.screen_hash(b)
		if cs.name == "vim-alt" {
			testing.expectf(t, ha != hb, "vim-alt: the VT fallback now keeps the primary screen; update §5.5")
			// what is there matches: the alt screen itself
			testing.expect(t, strings.contains(snap_dump(b), "-- INSERT --"))
		} else {
			snap_same(t, a, b, fmt.tprintf("%s via vt", cs.name))
		}
		gh.terminal_free(a)
		gh.terminal_free(b)
		free_all(context.temp_allocator)
	}
	_, _, err := core.snapshot_encode(nil, {}, []string{"ghostsnp/9"}, true)
	testing.expect_value(t, err, core.Snapshot_Error.No_Common_Format)
	testing.expect_value(t, core.snapshot_pick_format({"vt", "ghostsnp/1"}), core.SNAPSHOT_GHOSTSNP)
	testing.expect_value(t, core.snapshot_pick_format({"ghostsnp/2"}), "")
}

// An unfinished sequence over the continuation limit: GHOSTSNP can't encode
// until it ends; a handover may take the VT fallback meanwhile.
@(test)
snapshot_over_limit :: proc(t: ^testing.T) {
	gt := snap_gt(40, 10)
	defer gh.terminal_free(gt)
	small: c.size_t = 64 * 1024
	gh.terminal_set(gt, .Continuation_Max_Bytes, &small)
	snap_write(gt, "before\r\n" + ESC + "]52;c;")
	snap_write(gt, strings.repeat("QUFB", 25 * 1024, context.temp_allocator)) // 100 KiB
	_, _, err := core.snapshot_encode(gt, {}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	testing.expect_value(t, err, core.Snapshot_Error.Unfinished)
	_, _, err = core.snapshot_encode(gt, {}, []string{core.SNAPSHOT_GHOSTSNP}, true, context.temp_allocator)
	testing.expect_value(t, err, core.Snapshot_Error.Unfinished) // no VT to fall back to
	blob, meta, err2 := core.snapshot_encode(gt, {}, core.SNAPSHOT_FORMATS[:], true, context.temp_allocator)
	testing.expect_value(t, err2, core.Snapshot_Error.None)
	testing.expect_value(t, meta.format, core.SNAPSHOT_VT)
	testing.expect(t, meta.inexact)
	_, both := core.screen_hash(gt)
	testing.expect(t, !both)
	b, _, _ := core.snapshot_decode(blob)
	testing.expect(t, strings.contains(snap_dump(b), "before"))
	gh.terminal_free(b)
	// the sequence ends: exact again
	snap_write(gt, "\x07after")
	blob, meta, err = core.snapshot_encode(gt, {}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	testing.expect_value(t, err, core.Snapshot_Error.None)
	testing.expect_value(t, meta.format, core.SNAPSHOT_GHOSTSNP)
	b, _, _ = core.snapshot_decode(blob)
	snap_same(t, gt, b, "after the OSC ended")
	gh.terminal_free(b)
	free_all(context.temp_allocator)
}

@(test)
snapshot_continuation_trim :: proc(t: ^testing.T) {
	gt := snap_gt(40, 10)
	defer gh.terminal_free(gt)
	snap_write(gt, ESC + "]52;c;")
	snap_write(gt, strings.repeat("QUFB", 512 * 1024, context.temp_allocator)) // 2 MiB
	testing.expect(t, !core.term_continuation_trim(gt)) // mid-sequence: left alone
	snap_write(gt, "\x07" + ESC + "[1")
	testing.expect(t, !core.term_continuation_trim(gt))
	snap_write(gt, "mX")
	testing.expect(t, core.term_continuation_trim(gt))
	limit: c.size_t
	gh.terminal_get(gt, .Continuation_Max_Bytes, &limit)
	testing.expect_value(t, limit, core.TERM_CONTINUATION_MAX)
	snap_write(gt, ESC + "[3") // and tracking still works
	_, _, err := core.snapshot_encode(gt, {}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	testing.expect_value(t, err, core.Snapshot_Error.None)
	free_all(context.temp_allocator)
}

@(test)
snapshot_bad_input :: proc(t: ^testing.T) {
	gt := snap_gt(20, 4)
	defer gh.terminal_free(gt)
	snap_write(gt, "hi")
	blob, _, _ := core.snapshot_encode(gt, {offset = 7}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	cases := [?][]u8{blob[:2], blob[:len(blob) / 2], blob[:len(blob) - 1], slice.concatenate([][]u8{blob, {1, 2, 3}}, context.temp_allocator)}
	for b, i in cases {
		_, _, err := core.snapshot_decode(b)
		testing.expectf(t, err == .Bad_Snapshot, "case %d: %v", i, err)
	}
	pack :: proc(meta: string, body: string) -> []u8 {
		out := make([dynamic]u8, context.temp_allocator)
		n := [4]u8{u8(len(meta)), 0, 0, 0}
		append(&out, ..n[:])
		append(&out, meta)
		append(&out, body)
		return out[:]
	}
	_, _, err := core.snapshot_decode(pack(`{"format":"ghostsnp/7","cols":20,"rows":4}`, "x"))
	testing.expect_value(t, err, core.Snapshot_Error.Unknown_Format)
	_, _, err = core.snapshot_decode(pack(`{"format":"vt","cols":0,"rows":4}`, "x"))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	_, _, err = core.snapshot_decode(pack(`[1]`, ""))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	// a newer side's extra meta fields are ignored
	g2, m, e2 := core.snapshot_decode(pack(`{"format":"vt","cols":20,"rows":4,"future":{"x":1}}`, "ok"))
	testing.expect_value(t, e2, core.Snapshot_Error.None)
	testing.expect_value(t, m.cols, 20)
	if g2 != nil do gh.terminal_free(g2)
	free_all(context.temp_allocator)
}

// Snapshots written by the libghostty-vt this branch shipped with
// (tests/vt-corpus/ghostsnp-1/) still decode to the same screen as a live
// terminal fed the same bytes. This is the libghostty bump check (DEVELOPING.md):
// a failure after a bump means old snapshots no longer restore exactly.
// VT_CORPUS_WRITE=1 writes missing files (only when adding a case).
@(test)
snapshot_stored_corpus :: proc(t: ^testing.T) {
	write := os.get_env("VT_CORPUS_WRITE", context.temp_allocator) == "1"
	stored := 0
	for cs in snap_corpus() {
		if cs.name == "ls-real" || cs.name == "htop-sgr" || cs.name == "resize" do continue // size; covered live
		a := snap_gt(cs.cols, cs.rows)
		for ev in cs.events {
			switch e in ev {
			case string: snap_write(a, e)
			case Snap_Resize: gh.terminal_resize(a, e.cols, e.rows, 8, 16)
			}
		}
		path := fmt.tprintf("tests/vt-corpus/ghostsnp-1/%s.snap", cs.name)
		if write {
			if _, err := os.stat(path, context.temp_allocator); err != nil {
				os.make_directory_all("tests/vt-corpus/ghostsnp-1")
				blob, _, _ := core.snapshot_encode(a, {offset = 1}, {core.SNAPSHOT_GHOSTSNP}, false, context.temp_allocator)
				_ = os.write_entire_file(path, blob)
			}
		}
		data, err := os.read_entire_file(path, context.temp_allocator)
		if testing.expectf(t, err == nil, "%s missing", path) {
			b, meta, derr := core.snapshot_decode(data)
			if testing.expectf(t, derr == .None, "%s: %v", path, derr) {
				testing.expect_value(t, meta.format, core.SNAPSHOT_GHOSTSNP)
				snap_same(t, a, b, path)
				gh.terminal_free(b)
				stored += 1
			}
		}
		gh.terminal_free(a)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, stored, 5)
}

// A decoded terminal joins a Term: callbacks (query replies), the limit and the
// size come back.
@(test)
snapshot_adopt :: proc(t: ^testing.T) {
	core.app_context = context
	core.term_cell = {10, 20} // the window's cells (fonts_apply): a new terminal takes them
	defer core.term_cell = {}
	src := snap_gt(30, 6)
	small := uint(1024 * 1024)
	gh.terminal_set(src, .Scrollback_Max_Bytes, &small)
	snap_write(src, "restored " + ESC + "[1;31mred")
	blob, _, _ := core.snapshot_encode(src, {}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	gh.terminal_free(src)
	gt, _, err := core.snapshot_decode(blob)
	testing.expect_value(t, err, core.Snapshot_Error.None)
	term := new(core.Term)
	defer free(term)
	testing.expect(t, core.term_init(term, 80, 24))
	fds: [2]posix.FD
	posix.pipe(&fds)
	term.pty.fd = i32(fds[1])
	term.running = true
	core.term_adopt_gt(term, gt)
	testing.expect_value(t, term.cols, 30)
	testing.expect_value(t, term.rows, 6)
	limit: c.size_t
	gh.terminal_get(term.gt, .Continuation_Max_Bytes, &limit)
	testing.expect_value(t, limit, core.TERM_CONTINUATION_MAX)
	// as term_start sets them: the scrollback limit and the cell pixel size (CSI 14 t below)
	sbmax: c.size_t
	gh.terminal_get(term.gt, .Scrollback_Max_Bytes, &sbmax)
	testing.expect_value(t, sbmax, core.TERM_SCROLLBACK_MAX)
	snap_write(term.gt, ESC + "[6n") // cursor position report: answered through Write_Pty
	posix.fcntl(fds[0], .SETFL, posix.O_NONBLOCK)
	buf: [64]u8
	n := posix.read(fds[0], &buf[0], len(buf))
	testing.expect_value(t, n > 0 ? string(buf[:n]) : "", ESC + "[1;13R")
	w, h: u32
	gh.terminal_get(term.gt, .Width_Px, &w)
	gh.terminal_get(term.gt, .Height_Px, &h)
	testing.expect_value(t, w, 300) // 30x6 cells of 10x20 px
	testing.expect_value(t, h, 120)
	term.running = false
	core.term_free(term)
	posix.close(fds[0])
	free_all(context.temp_allocator)
}

// Review findings 1 and 2: hostile meta (deep nesting, huge, an absurd size) is
// refused before parsing or allocating a grid.
@(test)
snapshot_hostile_meta :: proc(t: ^testing.T) {
	pack :: proc(meta: string, body: string) -> []u8 {
		out := make([dynamic]u8, context.temp_allocator)
		n: [4]u8
		endian.put_u32(n[:], .Little, u32(len(meta)))
		append(&out, ..n[:])
		append(&out, meta)
		append(&out, body)
		return out[:]
	}
	deep := strings.concatenate({`{"format":"vt","cols":20,"rows":4,"x":`, strings.repeat("[", 100_000, context.temp_allocator)}, context.temp_allocator)
	_, _, err := core.snapshot_decode(pack(deep, ""))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	big := strings.concatenate({`{"format":"vt","cols":20,"rows":4,"pad":"`, strings.repeat("x", 70_000, context.temp_allocator), `"}`}, context.temp_allocator)
	_, _, err = core.snapshot_decode(pack(big, ""))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	_, _, err = core.snapshot_decode(pack(`{"format":"vt","cols":65535,"rows":65535}`, "hello\x1b[2J"))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	_, _, err = core.snapshot_decode(pack(`{"format":"vt","cols":2001,"rows":4}`, ""))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	nl := strings.concatenate({"{\"format\":[\"\n,", strings.repeat("[", 60_000, context.temp_allocator)}, context.temp_allocator)
	_, _, err = core.snapshot_decode(pack(nl, ""))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	// GHOSTSNP whose grid disagrees with its meta
	gt := snap_gt(30, 6)
	defer gh.terminal_free(gt)
	blob, _, _ := core.snapshot_encode(gt, {}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	meta, body, _ := core.snapshot_unpack(blob)
	meta.cols = 31
	mj, _ := json.marshal(meta, {}, context.temp_allocator)
	_, _, err = core.snapshot_decode(pack(string(mj), string(body)))
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	free_all(context.temp_allocator)
}

// The advertised "ghostsnp/1" is what the library writes: GHOSTSNP version 1
// (body bytes 8-9, LE). A bump that changes it must add the new format name.
@(test)
snapshot_ghostsnp_version :: proc(t: ^testing.T) {
	gt := snap_gt(10, 2)
	defer gh.terminal_free(gt)
	p: [^]u8
	n: c.size_t
	testing.expect_value(t, gh.snapshot_encode_alloc(gt, nil, &p, &n), gh.Result.Success)
	defer gh.free(nil, p, n)
	testing.expect_value(t, string(p[:8]), "GHOSTSNP")
	ver := u16(p[8]) | u16(p[9]) << 8
	testing.expect_value(t, ver, 1)
	testing.expect_value(t, core.SNAPSHOT_GHOSTSNP, fmt.tprintf("ghostsnp/%d", ver))
	blob, _, _ := core.snapshot_encode(gt, {}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	meta, body, _ := core.snapshot_unpack(blob)
	testing.expect_value(t, meta.format, core.SNAPSHOT_GHOSTSNP)
	testing.expect_value(t, u16(body[8]) | u16(body[9]) << 8, 1)
	free_all(context.temp_allocator)
}

// The GHOSTSNP pre-check reads the grid from the TERMINAL record (body[20:24])
// before the codec allocates it: a valid-CRC body larger than its meta is refused.
@(test)
snapshot_ghostsnp_precheck :: proc(t: ^testing.T) {
	gt := snap_gt(30, 6)
	defer gh.terminal_free(gt)
	blob, _, _ := core.snapshot_encode(gt, {}, core.SNAPSHOT_FORMATS[:], false, context.temp_allocator)
	meta, body, _ := core.snapshot_unpack(blob)
	cols, _ := endian.get_u16(body[20:22], .Little)
	rows, _ := endian.get_u16(body[22:24], .Little)
	tag, _ := endian.get_u16(body[10:12], .Little)
	testing.expect_value(t, tag, 1)
	testing.expect_value(t, cols, 30)
	testing.expect_value(t, rows, 6)
	cols_ok, _ := core.snapshot_ghostsnp_grid(body)
	testing.expect(t, cols_ok)
	// a body claiming 2000x1000 (CRC fixed up) under a 30x6 meta
	evil := slice.clone(body, context.temp_allocator)
	endian.put_u16(evil[20:22], .Little, 2000)
	endian.put_u16(evil[22:24], .Little, 1000)
	plen, _ := endian.get_u32(evil[12:16], .Little)
	crc := crc32c(evil[10:16], 0)
	crc = crc32c(evil[20:20 + plen], crc)
	endian.put_u32(evil[16:20], .Little, crc)
	mj, _ := json.marshal(meta, {}, context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	n: [4]u8
	endian.put_u32(n[:], .Little, u32(len(mj)))
	append(&out, ..n[:])
	append(&out, ..mj)
	append(&out, ..evil)
	_, _, err := core.snapshot_decode(out[:])
	testing.expect_value(t, err, core.Snapshot_Error.Bad_Snapshot)
	ok, _ := core.snapshot_ghostsnp_grid(evil)
	testing.expect(t, ok) // well formed: refused for disagreeing with the meta
	short_ok, _ := core.snapshot_ghostsnp_grid(body[:23])
	testing.expect(t, !short_ok)
	free_all(context.temp_allocator)
}

// CRC32C (Castagnoli), as GHOSTSNP records use.
@(private = "file")
crc32c :: proc(b: []u8, prev: u32) -> u32 {
	crc := ~prev
	for x in b {
		crc ~= u32(x)
		for _ in 0 ..< 8 do crc = (crc >> 1) ~ (0x82F63B78 & (0 - (crc & 1)))
	}
	return ~crc
}

// The grid never exceeds what a snapshot may carry (round 2: a small font on
// an ultrawide display).
@(test)
term_rect_clamped :: proc(t: ^testing.T) {
	core.app_context = context
	font.cell_w, font.cell_h = 1, 1
	term := new(core.Term)
	defer free(term)
	testing.expect(t, core.term_init(term, 80, 24))
	term_set_rect(term, 0, 0, 10_000, 5_000)
	testing.expect_value(t, int(term.cols), core.MAX_TERM_COLS)
	testing.expect_value(t, int(term.rows), core.MAX_TERM_ROWS)
	gt_cols: u16
	gh.terminal_get(term.gt, .Cols, &gt_cols)
	testing.expect_value(t, int(gt_cols), core.MAX_TERM_COLS)
	core.term_free(term)
}
