package main

// Another machine's browser tabs in this Mac's window (docs/plans/background-core.md §8.3 P7,
// §10.4 M6-D). Their pages are CEF's like any other, but in a request context of that machine's
// own (src/native/cef_polish.inc: its own in-memory storage), and each of their requests goes only
// if on_cef_net says so: http, https, ws or wss to a public address, or this Mac's loopback on a
// port the user forwarded from that machine (Machine_Forward); a name is looked up first
// (core.netcap_lookup: a rebinding between that lookup and Chromium's own is the stated residual).
// WebSockets never reach that check, so the context's proxy sends them to a dead port unless they
// go to a forwarded one (dh_cef_remote_forwards): another machine's page has no other WebSocket.
// They open no popups, downloads, permissions or file choosers (the shim), and only http and https
// addresses (browser_remote_url_ok; the core checked them first, src/core/machine_browser.odin).
// Their screenshots go back as bytes (app_tab.odin's frame_shot, inline). Their tabs' records are
// that machine's: a page whose tab has gone from State goes too (its core's view_drop is a window
// request, which this core drops).

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "core:time"
import "core"

REMOTE_PAGE_ORPHAN :: 60 * time.Second // a page whose tab never came: it goes then

@(private = "file")
Net_Port :: struct {
	machine: u64,
	port:    u16,
}

// The forwarded ports, as State has them (machines.N.ports), for CEF's threads.
@(private = "file")
net_ports: struct {
	mu:   sync.Mutex,
	list: [64]Net_Port,
	n:    int,
}

// Every frame with pages (browser_tick): the forwarded ports for CEF's threads and, as they change,
// for each machine's proxy (its WebSockets: dh_cef_remote_forwards); and the pages of another
// machine's tabs that went.
browser_remote_tick :: proc() {
	sync.lock(&net_ports.mu)
	before := net_ports.list
	n_before := net_ports.n
	net_ports.n = 0
	for m in state.machines do for p in m.ports do if net_ports.n < len(net_ports.list) {
		net_ports.list[net_ports.n] = {m.no, p.local}
		net_ports.n += 1
	}
	now := net_ports.list
	n_now := net_ports.n
	sync.unlock(&net_ports.mu)
	if n_now != n_before || before != now {
		// each machine in either list: its whole list now
		for e, i in before[:n_before] do if !net_has_machine(before[:i], e.machine) do net_send(e.machine, now[:n_now])
		for e, i in now[:n_now] do if !net_has_machine(now[:i], e.machine) && !net_has_machine(before[:n_before], e.machine) do net_send(e.machine, now[:n_now])
	}
	gone := make([dynamic]u64, context.temp_allocator)
	for id, b in browsers {
		if core.id_machine(id) == 0 do continue
		if _, tab, _ := find_tab(id); tab != nil {
			b.seen_tab = true
		} else if b.seen_tab || time.tick_since(b.opened_at) > REMOTE_PAGE_ORPHAN do append(&gone, id)
	}
	for id in gone do browser_drop(id)
}

@(private = "file")
net_has_machine :: proc(list: []Net_Port, machine: u64) -> bool {
	for e in list do if e.machine == machine do return true
	return false
}

// Machine machine's forwarded ports (of list) to its proxy.
@(private = "file")
net_send :: proc(machine: u64, list: []Net_Port) {
	ports: [len(net_ports.list)]u16
	k := 0
	for e in list do if e.machine == machine {
		ports[k] = e.port
		k += 1
	}
	dh_cef_remote_forwards(machine, &ports[0], c.int(k))
}

// Whether a page of tab_id may open url here: any for this Mac's tabs; another machine's, http and
// https (and test mode's fixtures) or a blank page.
browser_remote_url_ok :: proc(tab_id: u64, url: string) -> bool {
	if core.id_machine(tab_id) == 0 || url == core.BROWSER_BLANK do return true
	when core.TEST_HOOKS do if strings.has_prefix(url, "deckhand-test://") do return true
	u, ok := core.netcap_url_parts(url)
	return ok && (strings.equal_fold(u.scheme, "http") || strings.equal_fold(u.scheme, "https"))
}

// May another machine's page load url (the shim, off CEF's IO thread)? 1 yes, 0 no. lookup 0: a
// name counts as allowed (its request is looked up as it starts). Any thread: nothing here
// allocates or reads State.
on_cef_net :: proc "c" (machine: u64, url: cstring, lookup: c.int) -> c.int {
	context = runtime.default_context()
	if url == nil do return 0
	u, ok := core.netcap_url_parts(string(url))
	if !ok do return 0
	ports: [len(net_ports.list)]u16
	n := 0
	sync.lock(&net_ports.mu)
	for i in 0 ..< net_ports.n do if net_ports.list[i].machine == machine {
		ports[n] = net_ports.list[i].port
		n += 1
	}
	sync.unlock(&net_ports.mu)
	private := false
	if lookup != 0 && core.netcap_host_class(u.host) == .Name {
		buf: [256]u8 // a host name is at most 253 bytes
		if len(u.host) >= len(buf) do return 0
		copy(buf[:], u.host)
		private = core.netcap_lookup(cstring(&buf[0]))
	}
	return core.netcap_allowed(u.scheme, u.host, u.port, ports[:n], private) ? 1 : 0
}
