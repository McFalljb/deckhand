package main

// Settings › Machines › Web access's Pair a browser… (core/web.odin): the code web_pair answered,
// kept in the window only (never in State), shown under the row while the core says a code is
// open (state.live.web.pairing) and until it expires.

import "core:strings"
import "core:time"

import "core"

web_pair: struct {
	code:    string, // heap: ABCD-EFGH
	address: string, // heap: the listen address
	until:   i64, // unix seconds
}

// Pair…: a fresh code from the core.
web_pair_start :: proc() {
	r := client_run(core.Web_Pair{}) // with its data (ui_run keeps none)
	if !r.ok {
		toast_show(r.error, true)
		return
	}
	delete(web_pair.code)
	delete(web_pair.address)
	web_pair.code = strings.clone(core.json_path(r.data, "code"))
	web_pair.address = strings.clone(core.json_path(r.data, "address"))
	until := core.json_path(r.data, "until")
	web_pair.until = 0
	for ch in transmute([]u8)until do if ch >= '0' && ch <= '9' do web_pair.until = web_pair.until * 10 + i64(ch - '0')
}

// A code is shown: one was made here, the core still has one open, and it has not expired.
web_pair_open :: proc() -> bool {
	if web_pair.code == "" || state.live.web.pairing == 0 do return false
	return time.to_unix_seconds(time.now()) <= web_pair.until
}

web_pair_hint :: proc(hint: string) -> string {
	return web_pair_open() ? "Type the code below in the browser" : hint
}

// The address to open: a wildcard listen address is any of this Mac's.
web_pair_address :: proc() -> string {
	a := web_pair.address
	if strings.has_prefix(a, "0.0.0.0:") do return strings.concatenate({"<this Mac's address>:", a[len("0.0.0.0:"):]}, context.temp_allocator)
	if strings.has_prefix(a, "[::]:") do return strings.concatenate({"<this Mac's address>:", a[len("[::]:"):]}, context.temp_allocator)
	return a
}
