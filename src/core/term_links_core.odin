package core

import "core:strings"
import "core:unicode/utf8"

// From src/term_links.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Terminal_Link :: struct {
	tab_id:   u64, // a pi or shell tab (Home's Atlas too)
	url:      string,
	external: bool, // the default browser even for http(s) (⌘-click, Open link; ⇧⌘-click: a browser tab)
}

// A link on the grid: its URL and its first and last cells (viewport col,
// row; in reading order, the rows between are whole).
Term_Link :: struct {
	url:  string,
	a, b: [2]int,
	osc8: bool, // an OSC 8 hyperlink (its text may differ from its target)
}

// What a hover lookup depended on: looked up again only when it changes.
Link_Key :: struct {
	at:     [2]f32,
	pane:   [2]f32, // the pane's x, y (a moved pane under a still pointer)
	bytes:  int, // the terminal's output so far
	offset: u64, // its scroll position
	cols, rows: u16,
	cmd:    bool,
}

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
ascii_prefix :: proc(s, p: string) -> bool {
	if len(s) < len(p) do return false
	for i in 0 ..< len(p) {
		c := s[i]
		if c >= 'A' && c <= 'Z' do c += 'a' - 'A'
		if c != p[i] do return false
	}
	return true
}
