package main

// Links in terminal tabs, as Ghostty and iTerm do them: an OSC 8 hyperlink
// (libghostty-vt keeps its URI per cell) or a URL in the text (http, https,
// mailto; soft-wrapped rows are read as one line). Holding ⌘ underlines the
// link under the pointer, shows a hand and a tip with where it goes (OSC 8
// text may differ from its target); ⌘-click opens it, ⇧⌘-click opens it in
// the default browser; right-click (⌃-click) on it: a menu with Open link,
// Open in default browser and Copy link. ⌘ is needed because a plain click
// selects, or goes to the program when it tracks the mouse (pi does).
//
// Opening is the terminal_link command (the user's only): http(s) opens in
// a browser tab of the terminal's session, in front; mailto, ⇧⌘, a build
// without the browser, a browser that failed to start and Home's terminal
// (Home has no browser tabs) use the default app. Only http, https and
// mailto ever open: terminal output is untrusted, so file:, javascript:,
// data: and custom schemes are refused, from OSC 8 targets too.

import "core:c"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"

Terminal_Link :: struct {
	tab_id:   u64, // a pi or shell tab (Home's Atlas too)
	url:      string,
	external: bool, // the default browser even for http(s) (⇧⌘-click)
}

// A link on the grid: its URL and its first and last cells (viewport col,
// row; in reading order, the rows between are whole).
Term_Link :: struct {
	url:  string,
	a, b: [2]int,
	osc8: bool, // an OSC 8 hyperlink (its text may differ from its target)
}

LINK_MAX_ROWS :: 8 // soft-wrapped rows read either side of the pointer's
LINK_TIP_MAX :: 160 // runes of a URL shown in the tip

// ---- which URLs open ----

// Whether url may open from terminal output: http(s) with a host, or mailto
// with an address. Refused: spaces, control, invisible and direction
// characters (anything one_line would change), invalid UTF-8, a backslash
// anywhere (NSURL and Chromium read https://a.com\@b.com differently) and
// user info before the host (https://good@evil: the host shown must be the
// host opened). The scheme compares as ASCII (İ lowercases to i).
term_url_allowed :: proc(url: string) -> bool {
	if url == "" || !utf8.valid_string(url) do return false
	for i in 0 ..< len(url) do if url[i] <= 0x20 || url[i] == 0x7f || url[i] == '\\' do return false
	if one_line(url, context.temp_allocator) != url do return false
	for p in ([]string{"https://", "http://"}) {
		if !ascii_prefix(url, p) do continue
		rest := url[len(p):]
		if rest == "" || rest[0] == '/' || rest[0] == '?' || rest[0] == '#' do return false
		auth := rest
		if k := strings.index_any(rest, "/?#"); k >= 0 do auth = rest[:k]
		return strings.index_byte(auth, '@') < 0
	}
	if ascii_prefix(url, "mailto:") do return len(url) > len("mailto:")
	return false
}

// s starts with the lowercase ASCII prefix p, in any ASCII case.
@(private = "file")
ascii_prefix :: proc(s, p: string) -> bool {
	if len(s) < len(p) do return false
	for i in 0 ..< len(p) {
		c := s[i]
		if c >= 'A' && c <= 'Z' do c += 'a' - 'A'
		if c != p[i] do return false
	}
	return true
}

// The URL as shown in the tip and the menu: one line, at most max runes
// (max >= 2). What follows scheme://host (a mail address: up to its ?) is
// cut in its middle; a host too long for max is cut in its middle too,
// keeping its last LINK_HOST_TAIL runes, so the registrable domain shows
// (https://accounts.goo…evil.io). Temp-allocated.
LINK_HOST_TAIL :: 30
link_label :: proc(url: string, max: int) -> string {
	s := one_line(url, context.temp_allocator)
	if strings.rune_count(s) <= max do return s
	head, scheme := "", ""
	if k := strings.index(s, "://"); k >= 0 {
		end := len(s)
		if j := strings.index_any(s[k + 3:], "/?#"); j >= 0 do end = k + 3 + j
		head, scheme = s[:end], s[:k + 3]
	} else if ascii_prefix(s, "mailto:") {
		end := len(s)
		if j := strings.index_byte(s, '?'); j >= 0 do end = j
		head, scheme = s[:end], s[:len("mailto:")]
	}
	b := strings.builder_make(context.temp_allocator)
	write :: proc(b: ^strings.Builder, rr: []rune) {for r in rr do strings.write_rune(b, r)}
	hr := utf8.string_to_runes(head, context.temp_allocator)
	if len(hr) >= max {
		// the host (or address) alone does not fit: its middle goes
		sr := utf8.string_to_runes(scheme, context.temp_allocator)
		host := hr[len(sr):]
		avail := max - len(sr) - 1 // the …
		if avail < 2 {
			write(&b, hr[:max - 1])
			strings.write_string(&b, "…")
			return strings.to_string(b)
		}
		tail := min(LINK_HOST_TAIL, avail - 1)
		write(&b, sr)
		write(&b, host[:avail - tail])
		strings.write_string(&b, "…")
		write(&b, host[len(host) - tail:])
		return strings.to_string(b)
	}
	rr := utf8.string_to_runes(s[len(head):], context.temp_allocator)
	budget := max - len(hr) - 1 // the …
	write(&b, hr)
	if budget >= 2 {
		front := (budget + 1) / 2
		write(&b, rr[:front])
		strings.write_string(&b, "…")
		write(&b, rr[len(rr) - (budget - front):])
	} else do strings.write_string(&b, "…")
	return strings.to_string(b)
}

// ---- URLs in text ----

// Whether r may be part of a URL in text: printable ASCII but for spaces,
// quotes-like delimiters and a few never in URLs; letters and digits of other
// scripts (an IRI). Box drawing and empty cells end it.
@(private = "file")
url_rune :: proc(r: rune) -> bool {
	if r <= 0x20 || r == 0x7f do return false
	if r < 0x80 {
		switch r {
		case '<', '>', '"', '`', '{', '}', '|', '\\', '^':
			return false
		}
		return true
	}
	return unicode.is_letter(r) || unicode.is_digit(r)
}

@(private = "file")
ascii_lower :: proc(r: rune) -> rune {return r >= 'A' && r <= 'Z' ? r + ('a' - 'A') : r}

@(private = "file")
word_rune :: proc(r: rune) -> bool {return r > 0 && (unicode.is_letter(r) || unicode.is_digit(r))}

// The URL in rs (one rune per cell) that covers index at: its first and last
// index. A URL starts with http://, https:// or mailto: (any case) at the
// start of a word; trailing punctuation and closing brackets it did not
// open are not part of it.
find_url_at :: proc(rs: []rune, at: int) -> (lo, hi: int, ok: bool) {
	PREFIXES :: [?]string{"https://", "http://", "mailto:"}
	if at < 0 || at >= len(rs) do return 0, 0, false
	i := 0
	for i < len(rs) {
		plen := 0
		prev := i - 1
		for prev >= 0 && rs[prev] == SPACER do prev -= 1
		if prev < 0 || !word_rune(rs[prev]) {
			for p in PREFIXES {
				if i + len(p) > len(rs) do continue
				match := true
				for k in 0 ..< len(p) do if ascii_lower(rs[i + k]) != rune(p[k]) {
					match = false
					break
				}
				if match {
					plen = len(p)
					break
				}
			}
		}
		if plen == 0 {
			i += 1
			continue
		}
		end := i + plen
		// a wide character's second cell (SPACER) belongs to the character before it
		for end < len(rs) && (url_rune(rs[end]) || (rs[end] == SPACER && url_rune(rs[end - 1]))) do end += 1
		// trim: punctuation that ends a sentence, then closing brackets without an opener
		for end > i + plen {
			last := rs[end - 1]
			trim := false
			switch last {
			case '.', ',', ':', ';', '!', '?', '\'', '*':
				trim = true
			case ')', ']':
				open: rune = last == ')' ? '(' : '['
				opens, closes := 0, 0
				for r in rs[i:end] {
					if r == open do opens += 1
					else if r == last do closes += 1
				}
				trim = closes > opens
			}
			if !trim do break
			end -= 1
		}
		if end > i + plen && at >= i && at < end do return i, end - 1, true
		i = max(end, i + 1)
	}
	return 0, 0, false
}

// One cell of a line read for links: its first codepoint (0 empty, SPACER a
// wide character's second cell) and its OSC 8 target ("" none).
Link_Cell :: struct {
	r:   rune,
	uri: string,
}

// The link covering cells[at]: the cell's OSC 8 hyperlink (all the
// neighbouring cells with the same target) if it has one, else a URL in the
// text. A hyperlink with a refused target is no link at all.
link_in_cells :: proc(cells: []Link_Cell, at: int) -> (lo, hi: int, url: string, osc8: bool, ok: bool) {
	if at < 0 || at >= len(cells) do return
	if u := cells[at].uri; u != "" {
		if !term_url_allowed(u) do return
		lo, hi = at, at
		for lo > 0 && cells[lo - 1].uri == u do lo -= 1
		for hi + 1 < len(cells) && cells[hi + 1].uri == u do hi += 1
		return lo, hi, u, true, true
	}
	rs := make([]rune, len(cells), context.temp_allocator)
	for c, i in cells do rs[i] = c.r
	lo, hi, ok = find_url_at(rs, at)
	if !ok do return
	b := strings.builder_make(context.temp_allocator)
	for r in rs[lo:hi + 1] do if r > 0 do strings.write_rune(&b, r)
	url = strings.to_string(b)
	ok = term_url_allowed(url)
	return
}

// ---- reading the grid ----

@(private = "file")
grid_ref_at :: proc(gt: gh.Terminal, x, y: int) -> (gh.Grid_Ref, bool) {
	p := gh.Point{tag = .Viewport}
	p.value.coordinate = {x = u16(x), y = u32(y)}
	ref := gh.Grid_Ref{size = size_of(gh.Grid_Ref)}
	ok := gh.terminal_grid_ref(gt, p, &ref) == .Success // before ref is returned (filled)
	return ref, ok
}

// Whether viewport row y soft-wraps into the next.
@(private = "file")
row_wraps :: proc(gt: gh.Terminal, y: int) -> bool {
	ref, ok := grid_ref_at(gt, 0, y)
	if !ok do return false
	row: gh.Grid_Row
	if gh.grid_ref_row(&ref, &row) != .Success do return false
	wrap: bool
	gh.row_get(row, .Wrap, &wrap)
	return wrap
}

// The link under viewport cell vc of a terminal of cols x rows (URL in the
// temp allocator). The pointer's row is read with the rows it soft-wraps
// with, so a long URL counts as one.
term_link_at_cell :: proc(gt: gh.Terminal, cols, rows: int, vc: [2]int) -> (Term_Link, bool) {
	if vc.x < 0 || vc.y < 0 || vc.x >= cols || vc.y >= rows do return {}, false
	top, bottom := vc.y, vc.y
	for top > 0 && vc.y - top < LINK_MAX_ROWS && row_wraps(gt, top - 1) do top -= 1
	for bottom < rows - 1 && bottom - vc.y < LINK_MAX_ROWS && row_wraps(gt, bottom) do bottom += 1
	n := (bottom - top + 1) * cols
	cells := make([]Link_Cell, n, context.temp_allocator)
	last_uri := ""
	for y in top ..= bottom {
		for x in 0 ..< cols {
			ref, ok := grid_ref_at(gt, x, y)
			if !ok do continue
			lc := &cells[(y - top) * cols + x]
			raw: gh.Cell
			gh.grid_ref_cell(&ref, &raw)
			wide: gh.Cell_Wide
			gh.cell_get(raw, .Wide, &wide)
			if wide == .Spacer_Tail || wide == .Spacer_Head do lc.r = SPACER
			else {
				buf: [16]u32
				got: c.size_t
				res := gh.grid_ref_graphemes(&ref, &buf[0], len(buf), &got)
				if res == .Success && got > 0 do lc.r = rune(buf[0])
				else if res == .Out_Of_Space do lc.r = 0xFFFD
			}
			has: bool
			gh.cell_get(raw, .Has_Hyperlink, &has)
			if !has do continue
			ubuf: [512]u8
			ulen: c.size_t
			uri := ""
			res := gh.grid_ref_hyperlink_uri(&ref, &ubuf[0], len(ubuf), &ulen)
			if res == .Success {
				uri = string(ubuf[:ulen])
			} else if res == .Out_Of_Space && ulen <= 64 * 1024 {
				big := make([]u8, ulen, context.temp_allocator)
				if gh.grid_ref_hyperlink_uri(&ref, raw_data(big), len(big), &ulen) == .Success do uri = string(big[:ulen])
			}
			// neighbouring cells of one link share one copy
			if uri != last_uri do last_uri = strings.clone(uri, context.temp_allocator)
			lc.uri = last_uri
		}
	}
	at := (vc.y - top) * cols + vc.x
	lo, hi, url, osc8, ok := link_in_cells(cells, at)
	if !ok do return {}, false
	return Term_Link{url = url, a = {lo % cols, top + lo / cols}, b = {hi % cols, top + hi / cols}, osc8 = osc8}, true
}

// The link under the pointer (framebuffer px) in t's grid; none in the padding.
term_link_at :: proc(t: ^Term, mx, my: f32) -> (Term_Link, bool) {
	if t == nil || t.gt == nil || t.cols == 0 || !in_pane(t, mx, my) do return {}, false
	fx := (mx - t.x - term_pad()) / font.cell_w
	fy := (my - t.y - term_pad()) / font.cell_h
	if fx < 0 || fy < 0 do return {}, false
	return term_link_at_cell(t.gt, int(t.cols), int(t.rows), {int(fx), int(fy)})
}

// ---- hover: ⌘ held over a link ----

link_cmd_held: bool // ⌘ is down now (term_links_event); the underline and tip show only then
@(private = "file")
link_cursor: bool // the hand is ours (a link under the pointer)

// What a hover lookup depended on: looked up again only when it changes.
Link_Key :: struct {
	at:     [2]f32,
	pane:   [2]f32, // the pane's x, y (a moved pane under a still pointer)
	bytes:  int, // the terminal's output so far
	offset: u64, // its scroll position
	cols, rows: u16,
	cmd:    bool,
}

// Every input event, first (before fields, menus and sheets take keys): ⌘
// going down or up, and the modifiers mouse events carry. The window losing
// focus lets ⌘ go (its release goes to another app).
term_links_event :: proc(e: ^sapp.Event) {
	held := link_cmd_held
	#partial switch e.type {
	case .KEY_DOWN, .KEY_UP:
		if e.key_code == .LEFT_SUPER || e.key_code == .RIGHT_SUPER do held = e.type == .KEY_DOWN
		else do held = e.modifiers & sapp.MODIFIER_SUPER != 0
	case .MOUSE_MOVE, .MOUSE_DOWN, .MOUSE_UP, .MOUSE_SCROLL:
		held = e.modifiers & sapp.MODIFIER_SUPER != 0
	case .UNFOCUSED, .MOUSE_LEAVE:
		held = false
	}
	if held == link_cmd_held do return
	link_cmd_held = held
	term_links_frame()
}

// Looks up the link under pt (framebuffer px; outside the pane: none) if
// anything it depends on changed. Called before the layout and from input
// events, never while drawing: the tip and the underline only read t.link.
// True if a link is under the pointer.
term_link_tick :: proc(t: ^Term, pt: [2]f32) -> bool {
	if t == nil do return false
	sb: gh.Scrollbar
	if t.gt != nil do gh.terminal_get(t.gt, .Scrollbar, &sb)
	key := Link_Key{at = pt, pane = {t.x, t.y}, bytes = t.bytes_in, offset = sb.offset, cols = t.cols, rows = t.rows, cmd = link_cmd_held}
	if t.link_scanned && key == t.link_key do return t.link_on
	t.link_key = key
	t.link_scanned = true
	t.link_at = pt
	l, ok := Term_Link{}, false
	if link_cmd_held {
		t.link_scans += 1
		l, ok = term_link_at(t, pt.x, pt.y)
	}
	if !ok {
		if t.link_on {
			term_link_clear(t)
			t.link_scanned = true // cleared for this key
			app.redraw = true
		}
		return false
	}
	if !t.link_on || t.link.url != l.url || t.link.a != l.a || t.link.b != l.b {
		delete(t.link.url)
		t.link = l
		t.link.url = strings.clone(l.url)
		t.link_on = true
		t.changed = true
		app.redraw = true
	}
	return true
}

term_link_clear :: proc(t: ^Term) {
	t.link_scanned = false
	if !t.link_on do return
	delete(t.link.url)
	t.link = {}
	t.link_on = false
	t.changed = true
}

// Before each layout and after pointer or ⌘ changes: the terminal on screen
// and Atlas's look up the link under the pointer (each only while the
// pointer is over it); every other terminal has none. The pointer becomes a
// hand over one.
term_links_frame :: proc() {
	t, at := pane_term(hit_pane()), agent_term() // the terminal of the pane under the pointer (panes.odin)
	p := app.pointer
	none := [2]f32{-1e9, -1e9}
	in_drawer := state.home_open && inside(clay.ID("drawer"), p.x, p.y)
	on := false
	if t != nil && term_link_tick(t, in_drawer || over_overlay() ? none : p) do on = true
	if at != nil && term_link_tick(at, state.home_open && inside(clay.ID("drawer_term"), p.x, p.y) && !over_overlay() ? p : none) do on = true
	for _, x in terms do if x != t && x != at && x.link_on do term_link_clear(x)
	if on {
		link_cursor = true
		if sapp.get_mouse_cursor() != .POINTING_HAND do sapp.set_mouse_cursor(.POINTING_HAND)
	} else if link_cursor {
		link_cursor = false
		// back to the text cursor only over a terminal's text (elsewhere the chrome sets it)
		over := (t != nil && !in_drawer && in_pane(t, p.x, p.y)) || (at != nil && state.home_open && inside(clay.ID("drawer_term"), p.x, p.y))
		if over && !over_overlay() && sapp.get_mouse_cursor() == .POINTING_HAND do sapp.set_mouse_cursor(.IBEAM)
	}
}

// The tab a terminal belongs to (0: none).
term_tab_id :: proc(t: ^Term) -> u64 {
	for id, x in terms do if x == t do return id
	return 0
}

// A press in a terminal pane on a link: ⌘-click opens it (⇧⌘: in the
// default browser), right-click or ⌃-click (without ⌘) opens its menu. True if taken
// (the program and the selection never see it).
term_link_mouse_down :: proc(t: ^Term, e: ^sapp.Event) -> bool {
	// taken only as ⌘-click (open) or right-click / ⌃-click (the menu, as a
	// right click everywhere on macOS); ⌘⌃-click and anything else stay the
	// program's (or the selection's)
	cmd := e.modifiers & sapp.MODIFIER_SUPER != 0
	ctrl := e.modifiers & sapp.MODIFIER_CTRL != 0
	open_click := e.mouse_button == .LEFT && cmd && !ctrl
	menu_click := !cmd && (e.mouse_button == .RIGHT || (e.mouse_button == .LEFT && ctrl))
	if !open_click && !menu_click do return false
	l, ok := term_link_at(t, e.mouse_x, e.mouse_y)
	if !ok do return false
	tab_id := term_tab_id(t)
	if tab_id == 0 do return false
	if menu_click {
		menu_open(Menu_Term_Link{tab_id = tab_id, url = l.url}, {e.mouse_x, e.mouse_y})
		return true
	}
	ui_do(Terminal_Link{tab_id = tab_id, url = l.url, external = e.modifiers & sapp.MODIFIER_SHIFT != 0})
	app.redraw = true
	return true
}

// Draws the hovered link's underline (inside term_draw).
term_link_draw :: proc(t: ^Term, ox, oy: f32, col: Rgba) {
	// only reads: term_link_tick looked it up before the layout
	if !t.link_on || !link_cmd_held do return
	l := t.link
	lt := max(font.line_thick, 1)
	for y in l.a.y ..= l.b.y {
		x0 := y == l.a.y ? l.a.x : 0
		x1 := y == l.b.y ? l.b.x : int(t.cols) - 1
		draw_rect(ox + f32(x0) * font.cell_w, oy + f32(y) * font.cell_h + font.underline_y, f32(x1 - x0 + 1) * font.cell_w, lt, col)
	}
}

// The tip with the hovered link's URL, at the pane's bottom left (top left
// when the pointer is down there). In the overlay layer (main.odin draws
// "linktip" above the terminals).
term_link_tip_layout :: proc() {
	t: ^Term
	for x in ([]^Term{active_term(), agent_term()}) do if x != nil && x.link_on {
		t = x
		break
	}
	if t == nil || menu.open || !link_cmd_held do return
	th := theme()
	// a copy for this frame: the layout's text outlives any change to t.link
	text := strings.clone(link_label(t.link.url, LINK_TIP_MAX), context.temp_allocator)
	pad := term_pad()
	x := t.x + pad
	y := t.y + t.h - pad - px(TIP_H)
	if t.link_at.y > y - font.cell_h do y = t.y + pad
	if clay.UI(clay.ID("linktip"))({
		layout = {sizing = {clay.SizingFit({max = max(t.w - 2 * pad, 0)}), clay.SizingFixed(px(TIP_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 30},
	}) {
		clay.TextDynamic(text, txt(th.text, FONT_UI_SMALL))
	}
}

// ---- the right-click menu ----

Menu_Term_Link :: struct {
	tab_id: u64,
	url:    string, // owned by the menu
}

term_link_menu_items :: proc(m: Menu_Term_Link, items: ^[dynamic]Menu_Item) {
	shown := strings.clone(link_label(m.url, 80), context.temp_allocator)
	append(items, Menu_Item{label = shown, note = true})
	append(items, Menu_Item{sep = true})
	mail := ascii_prefix(m.url, "mailto:")
	append(items, Menu_Item{label = "Open link", keys = "⌘-click", cmd = Terminal_Link{tab_id = m.tab_id, url = m.url}})
	if !mail do append(items, Menu_Item{label = "Open in default browser", keys = "⇧⌘-click", cmd = Terminal_Link{tab_id = m.tab_id, url = m.url, external = true}})
	append(items, Menu_Item{label = "Copy link", copy = m.url})
}

// ---- the command ----

// Whether http(s) links can open in pi-desk's own browser.
@(private = "file")
browser_usable :: proc() -> bool {return CEF_BUILT_IN && cef_state != .Failed}

term_link_apply :: proc(c: Terminal_Link, caller: Caller) -> (Result, bool) {
	s, tab, _ := find_tab(c.tab_id)
	if tab == nil do return fail("no such tab"), false
	#partial switch _ in tab.kind {
	case Pi_Tab, Shell_Tab, Claude_Tab:
	case:
		return fail("not a terminal tab"), false
	}
	if !term_url_allowed(c.url) do return fail("only http, https and mailto links open from a terminal"), false
	if !ascii_prefix(c.url, "mailto:") {
		if !c.external && browser_usable() && !s.home {
			id, _ := browser_tab_open(s.id, c.url)
			if id != 0 do return {ok = true, created_id = id}, true
		}
	}
	if platform.open_url == nil do return fail("cannot open links here"), false
	if !platform.open_url(c.url) do return fail("the link could not be opened"), false
	return {ok = true}, false
}
