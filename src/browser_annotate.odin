package main

// Comment mode in browser tabs (docs/BROWSER.md §3, steps 4 and 6): Annotate (the bar's button,
// or ⌘⇧.) turns it on; the element under the pointer is outlined, a click picks it, a drag
// picks an area, and the new-comment bar (ui_comments.odin) opens: Add makes a pending comment
// (comments.odin) for the tab's session's pi with the crop taken at the pick. Esc closes the bar,
// then leaves the mode. Each pending comment made here has a marker: a numbered badge (its number
// in the session's list) at the element or area, following scroll and resize, an edge arrow when
// it is off screen; a click on a badge edits the comment in the list.
//
// The page finds, Deckhand draws (§3.2). The overlay script (src/native/browser_overlay.js) runs
// in the "deckhand" isolated world of the page's top frame, through the DevTools protocol in
// process (cef_macos.m: dh_cef_devtools_send and its observer; no debugging port). It answers
// Deckhand's questions (what is at x,y; what does this area cover; where are these markers now)
// through a binding that exists in that world only (Runtime.addBinding with
// executionContextName), so page scripts cannot call it. Only calls from the context of the
// latest document's overlay are taken (its `hello` names it); a reply to an older question is
// dropped (seq). Nothing of Deckhand's is added to the page's DOM. The Runtime domain stays off
// (Runtime.enable is what bot checks look for, and would send every console message here). The
// binding's calls arrive without it, but Runtime.addBinding then reaches only contexts that exist
// when it is called: on each top-frame Page.frameNavigated, Deckhand takes our world's context on
// the new document (Page.createIsolatedWorld), adds the binding to it and runs the overlay there
// (already running from the document's start, it says hello again). A question the old document
// never answers is asked again (ANNOT_HOVER_RETRY).
//
// Markers live here (runtime, keyed by comment id; a comment deleted, sent or cleared takes its
// marker with it). Each remembers the address of the document it was made on: a new document
// at another address hides them (the comments stay pending: they have their crops), and back on
// that address they show again where their selector still resolves ("not found" otherwise).
// Element markers follow the element (the page reports document rects when they change); area
// markers keep document coordinates. The top document only: iframes are not looked into.
//
// What the page says (selector, element text, title, address) is page-controlled: it is capped,
// put on one line and quoted (annot_pick_what), so it reads as a name in the block pi gets,
// never as a line of its own (comments_block).

import "core:c"
import "core:encoding/json"
import "core"
import jg "jsonguard"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"

ANNOT_WORLD :: "deckhand"
ANNOT_BINDING :: "__pdAnnot"
ANNOT_JS :: #load("native/browser_overlay.js", string)
ANNOT_DRAG_MIN :: 4 // logical px the pointer moves before a press becomes an area drag
ANNOT_HOVER_RETRY :: 500 * time.Millisecond // a hover question with no answer: ask again

Annot_Kind :: enum u8 {
	Element,
	Area,
}

// What a click or a drag picked, as the page described it (owned strings).
Annot_Pick :: struct {
	kind:     Annot_Kind,
	seq:      int, // the page's handle on the element (its overlay keeps it while connected)
	tag:      string,
	role:     string,
	name:     string,
	selector: string,
	text:     string, // "[value hidden]" for a form field or editable content (the overlay never reads values)
	itype:    string, // a form field's type ("text", "password", "select-one")
	els:      [dynamic]string, // an area: selectors of what it mostly covers (at most 5)
	box:      [4]f32, // viewport CSS px at the pick
	scroll:   [2]f32, // the page's scroll then
	url:      string,
	title:    string,
}

// A pending comment's place on its page.
Annot_Marker :: struct {
	tab_id:   u64,
	kind:     Annot_Kind,
	seq:      int,
	selector: string, // owned
	url:      string, // owned: the document's address, without its fragment
	doc:      [4]f32, // document CSS px (an element's: as the page last reported it)
	found:    bool, // shown in the document on screen now
}

// Per browser tab (runtime).
Annot :: struct {
	tab_id:      u64,
	on:          bool, // comment mode
	cef:         c.int, // the browser the overlay was installed in (0 = none yet)
	next_msg:    c.int,
	pending:     map[c.int]Annot_Call, // CDP calls whose results matter
	ctx:         i64, // the overlay's execution context (its last `hello`); 0 = none
	url:         string, // the document's address (owned)
	title:       string, // owned
	scroll:      [2]f32, // CSS px
	view:        [2]f32, // the viewport, CSS px
	zoom:        f32, // page zoom (CSS px -> view px); 1 until step 3's zoom
	seq:         int, // questions asked (hover, pick, area)
	hover_seq:   int, // the hover question in flight (0 = none)
	hover_at:    time.Tick,
	hover_again: bool, // the pointer moved while one was in flight
	hover:       [4]f32, // viewport CSS px
	has_hover:   bool,
	hover_label: string, // owned
	ptr:         [2]f32, // the pointer, viewport CSS px
	ptr_in:      bool,
	press:       bool, // a left press in comment mode, not released yet
	press_at:    [2]f32,
	dragging:    bool,
	pick_seq:    int, // the pick or area awaited (0 = none)
	tracked:     string, // the marker list the overlay has (owned): sent again when it changes
	layouts:     int, // marker reports received (tests)
	sent:        map[string]int, // CDP methods sent, by name (tests: never Runtime.enable)
}

Annot_Call :: enum u8 {
	None,
	Frame_Tree, // Page.getFrameTree: the main frame, for the world on the page already there
	World, // Page.createIsolatedWorld: its context, to run the overlay in
}

annots: map[u64]^Annot
annot_markers: map[u64]Annot_Marker // by comment id
@(private = "file")
callback_set: bool

// Badges drawn in the last frame (framebuffer px), for clicks.
@(private = "file")
Badge_Hit :: struct {
	comment_id: u64,
	rect:       [4]f32,
}
@(private = "file")
badges: [dynamic]Badge_Hit

annot_of :: proc(tab_id: u64) -> ^Annot {return annots[tab_id] or_else nil}

// ---- pure: coordinates ----

// A rect in document CSS px -> framebuffer px: scroll off, zoom and DPI on, at the pane's top-left.
annot_doc_to_fb :: proc(r: [4]f32, scroll: [2]f32, zoom, dpi: f32, origin: [2]f32) -> [4]f32 {
	k := zoom * dpi
	return {origin.x + (r.x - scroll.x) * k, origin.y + (r.y - scroll.y) * k, r[2] * k, r[3] * k}
}

// A framebuffer point -> viewport CSS px.
annot_fb_to_css :: proc(p: [2]f32, zoom, dpi: f32, origin: [2]f32) -> [2]f32 {
	k := zoom * dpi
	if k <= 0 do return {}
	return {(p.x - origin.x) / k, (p.y - origin.y) / k}
}

Annot_Where :: enum u8 {
	On, // in the viewport
	Above,
	Below,
	Left,
	Right,
	Not_Found, // its document is on screen but its element is not
	Other_Page, // another document is on screen
}
ANNOT_WHERE_NAMES := [Annot_Where]string {
	.On         = "on",
	.Above      = "above",
	.Below      = "below",
	.Left       = "left",
	.Right      = "right",
	.Not_Found  = "not_found",
	.Other_Page = "other_page",
}

// Where a document rect is against the viewport, and its badge's place in viewport CSS px: the
// rect's top-left clamped into the viewport (an edge arrow's place when it is off screen).
annot_place :: proc(doc: [4]f32, scroll, view: [2]f32) -> (at_: Annot_Where, badge: [2]f32) {
	x, y := doc.x - scroll.x, doc.y - scroll.y
	badge = {clamp(x, 0, max(view.x, 0)), clamp(y, 0, max(view.y, 0))}
	switch {
	case y + doc[3] <= 0:  at_ = .Above
	case y >= view.y:      at_ = .Below
	case x + doc[2] <= 0:  at_ = .Left
	case x >= view.x:      at_ = .Right
	case:                  at_ = .On
	}
	return
}

// An address without its fragment (markers belong to a document, not a place in it).
annot_url_key :: proc(url: string) -> string {
	if i := strings.index_byte(url, '#'); i >= 0 do return url[:i]
	return url
}

// ---- pure: what pi reads ----

// s on one line (runs of spaces as one), in double quotes with " and \ escaped, at most n bytes
// with its quotes (cut at a character, with "…").
annot_quote :: proc(s: string, n: int) -> string {
	quote :: proc(s: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '"')
		for r in s {
			if r == '"' || r == '\\' do strings.write_byte(&b, '\\')
			strings.write_rune(&b, r)
		}
		strings.write_byte(&b, '"')
		return strings.to_string(b)
	}
	t := strings.join(strings.fields(core.one_line(s, context.temp_allocator), context.temp_allocator), " ", context.temp_allocator)
	q := quote(t)
	for len(q) > n && len(t) > 0 {
		t = core.cut_utf8(t, max(len(t) * (n - 6) / len(q), 0)) // escapes make q longer than t
		q = quote(strings.concatenate({t, "…"}, context.temp_allocator))
	}
	return q
}

// A tag name as the page gave it, kept only if it looks like one.
@(private = "file")
tag_name :: proc(s: string) -> string {
	if len(s) == 0 || len(s) > 24 do return "element"
	for ch in transmute([]u8)s do if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-') do return "element"
	return s
}

// The comment's label for pi (temp allocator), at most COMMENT_WHAT_MAX bytes: the element (tag,
// name, selector, text) or the area (what it covers), its box in document px, the page's title
// and address. Every page-controlled part is quoted on one line (annot_quote).
annot_pick_what :: proc(p: ^Annot_Pick) -> string {
	b := strings.builder_make(context.temp_allocator)
	doc := [4]int{int(math.round(p.box.x + p.scroll.x)), int(math.round(p.box.y + p.scroll.y)), int(math.round(p.box[2])), int(math.round(p.box[3]))}
	switch p.kind {
	case .Element:
		strings.write_string(&b, tag_name(p.tag))
		if p.name != "" do fmt.sbprintf(&b, " %s", annot_quote(p.name, 50))
		if p.itype != "" do fmt.sbprintf(&b, " type %s", annot_quote(p.itype, 24))
		fmt.sbprintf(&b, " (selector %s", annot_quote(p.selector, 120))
		if p.text != "" && p.text != p.name do fmt.sbprintf(&b, ", text %s", annot_quote(p.text, 100))
		strings.write_byte(&b, ')')
	case .Area:
		strings.write_string(&b, "area")
	}
	fmt.sbprintf(&b, " at %d,%d %d×%d", doc[0], doc[1], doc[2], doc[3])
	if p.kind == .Area && len(p.els) > 0 {
		strings.write_string(&b, " covering ")
		for e, i in p.els {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, annot_quote(e, 50))
		}
	}
	fmt.sbprintf(&b, " on %s (%s)", annot_quote(p.title != "" ? p.title : "untitled page", 70), annot_quote(p.url, 150))
	return strings.to_string(b)
}

// The new-comment bar's head for a pick (temp): `button "Save"`, `area 10,20 300×40`.
annot_pick_head :: proc(p: ^Annot_Pick) -> string {
	if p.kind == .Area do return fmt.tprintf("area %d,%d %d×%d", int(p.box.x + p.scroll.x), int(p.box.y + p.scroll.y), int(p.box[2]), int(p.box[3]))
	label := p.name != "" ? p.name : p.text != "" ? p.text : p.selector
	return fmt.tprintf("%s %s", tag_name(p.tag), annot_quote(label, 60))
}

annot_pick_free :: proc(p: ^Annot_Pick) {
	if p == nil do return
	delete(p.tag)
	delete(p.role)
	delete(p.name)
	delete(p.selector)
	delete(p.text)
	delete(p.itype)
	for e in p.els do delete(e)
	delete(p.els)
	delete(p.url)
	delete(p.title)
	free(p)
}

// The new-comment bar's Add for a pick (ui_comments.odin): the comment for the tab's session's pi
// with the crop taken at the pick (the comment owns its file now, or it is removed on a refusal),
// and its marker.
annot_pick_add :: proc(tab_id: u64, p: ^Annot_Pick, text, crop: string) -> (id: u64, err: string) {
	r := client_call(core.Comment_Add{source = .Browser, tab_id = tab_id, what = annot_pick_what(p), text = text, crop = crop}, .Internal)
	if !r.ok {
		if crop != "" do os.remove(crop)
		return 0, r.error
	}
	doc := [4]f32{p.box.x + p.scroll.x, p.box.y + p.scroll.y, p.box[2], p.box[3]}
	annot_markers[r.created_id] = {
		tab_id   = tab_id,
		kind     = p.kind,
		seq      = p.seq,
		selector = strings.clone(p.selector),
		url      = strings.clone(annot_url_key(p.url)),
		doc      = doc,
		found    = true,
	}
	app.redraw = true
	return r.created_id, ""
}

@(private = "file")
marker_free :: proc(m: Annot_Marker) {
	delete(m.selector)
	delete(m.url)
}

// ---- the DevTools protocol ----

// Sends one CDP call to the tab's browser; its id (0: not sent).
@(private = "file")
cdp :: proc(a: ^Annot, b: ^Browser, method: string, params: string, call := Annot_Call.None) -> c.int {
	if b == nil || b.cef == 0 do return 0
	a.next_msg += 1
	id := a.next_msg
	s := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&s, `%s"id":%d,"method":"%s","params":%s%s`, "{", id, method, params, "}")
	msg := strings.to_string(s)
	if dh_cef_devtools_send(b.cef, raw_data(msg), c.size_t(len(msg))) == 0 do return 0
	if call != .None do a.pending[id] = call
	if core.autotest_active {
		if _, has := a.sent[method]; !has do a.sent[strings.clone(method)] = 0
		a.sent[method] += 1
	}
	return id
}

// Runs code in the overlay's world (no result: answers come through the binding).
@(private = "file")
run :: proc(a: ^Annot, b: ^Browser, code: string, ctx: i64) {
	p := strings.builder_make(context.temp_allocator)
	strings.write_string(&p, `{"expression":`)
	core.json_quote(&p, code)
	fmt.sbprintf(&p, `,"contextId":%d,"silent":true%s`, ctx, "}")
	cdp(a, b, "Runtime.evaluate", strings.to_string(p))
}

// The overlay in this browser: the script for every new document (in our world, from its start),
// and our world on the document there now (attach_world, again on each top-frame navigation).
@(private = "file")
install :: proc(a: ^Annot, b: ^Browser) {
	if !callback_set {
		dh_cef_devtools_callback(on_cef_devtools)
		callback_set = true
	}
	a.cef = b.cef
	a.ctx = 0
	a.hover_seq, a.pick_seq, a.has_hover = 0, 0, false
	clear(&a.pending)
	delete(a.tracked)
	a.tracked = ""
	p := strings.builder_make(context.temp_allocator)
	cdp(a, b, "Page.enable", "{}")
	strings.write_string(&p, `{"source":`)
	core.json_quote(&p, ANNOT_JS)
	fmt.sbprintf(&p, `,"worldName":"%s"}}`, ANNOT_WORLD)
	cdp(a, b, "Page.addScriptToEvaluateOnNewDocument", strings.to_string(p))
	// agents' password tracker (browser_act.js init): from each document's start, a field ever
	// seen as a password one stays sensitive
	q := strings.builder_make(context.temp_allocator)
	strings.write_string(&q, `{"source":`)
	core.json_quote(&q, ACT_INIT_JS)
	fmt.sbprintf(&q, `,"worldName":"%s"}}`, ANNOT_WORLD)
	cdp(a, b, "Page.addScriptToEvaluateOnNewDocument", strings.to_string(q))
	cdp(a, b, "Page.getFrameTree", "{}", .Frame_Tree)
}

// Our world on frame_id's document (Page.createIsolatedWorld gives the one the new-document script
// runs in, or makes it): its context comes back as the result (.World).
@(private = "file")
attach_world :: proc(a: ^Annot, b: ^Browser, frame_id: string) {
	if frame_id == "" do return
	p := strings.builder_make(context.temp_allocator)
	strings.write_string(&p, `{"frameId":`)
	core.json_quote(&p, frame_id)
	fmt.sbprintf(&p, `,"worldName":"%s"}}`, ANNOT_WORLD)
	cdp(a, b, "Page.createIsolatedWorld", strings.to_string(p), .World)
}

@(private = "file")
num :: proc(v: json.Value) -> (f32, bool) {
	#partial switch n in v {
	case json.Integer: return f32(n), true
	case json.Float:   return f32(n), true
	}
	return 0, false
}

// An integer (ids, seq): a JSON integer, or a float with no fraction.
@(private = "file")
int_of :: proc(v: json.Value) -> (i64, bool) {
	#partial switch n in v {
	case json.Integer: return n, true
	case json.Float:   if n == f64(i64(n)) do return i64(n), true
	}
	return 0, false
}

@(private = "file")
rect_of :: proc(v: json.Value) -> (r: [4]f32, ok: bool) {
	arr, is := v.(json.Array)
	if !is || len(arr) < 4 do return
	for i in 0 ..< 4 {
		r[i] = num(arr[i]) or_return
	}
	return r, true
}

@(private = "file")
str :: proc(o: json.Object, k: string) -> string {
	s, _ := o[k].(json.String)
	return s
}

// A CDP message (the shim's observer, on the main thread).
@(private = "file")
on_cef_devtools :: proc "c" (id: c.int, msg_id: c.int, ok: c.int, method: cstring, data: [^]u8, n: c.size_t) {
	context = core.app_context
	if browser_agent_devtools(id, msg_id, ok, method, data, n) do return // an agent's call (browser_agent.odin)
	b: ^Browser
	for _, x in browsers do if x.cef == id do b = x
	if b == nil do return
	a := annots[b.tab_id]
	if a == nil || a.cef != id do return
	if msg_id > 0 {
		call, had := a.pending[msg_id]
		if !had do return
		delete_key(&a.pending, msg_id)
		if ok == 0 do return
		v, err := jg.parse(data[:n], .JSON, true, context.temp_allocator)
		if err != nil do return
		o, _ := v.(json.Object)
		#partial switch call {
		case .Frame_Tree:
			tree, _ := o["frameTree"].(json.Object)
			frame, _ := tree["frame"].(json.Object)
			attach_world(a, b, str(frame, "id"))
		case .World:
			// our world's context on the top document: the binding goes into it (with the
			// Runtime domain off, Runtime.addBinding reaches only contexts that exist when it is
			// called), then the overlay runs there (or, already running from the document's
			// start, says hello again: the binding is there now)
			ctx, is := int_of(o["executionContextId"])
			if !is do return
			p := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&p, `{{"name":"%s","executionContextName":"%s"}}`, ANNOT_BINDING, ANNOT_WORLD)
			cdp(a, b, "Runtime.addBinding", strings.to_string(p))
			run(a, b, ANNOT_JS, ctx)
			run(a, b, ACT_INIT_JS, ctx)
		}
		return
	}
	if string(method) != "Runtime.bindingCalled" && string(method) != "Page.frameNavigated" do return
	v, err := jg.parse(data[:n], .JSON, true, context.temp_allocator)
	if err != nil do return
	o, is_o := v.(json.Object)
	if !is_o do return
	if string(method) == "Page.frameNavigated" {
		// the top frame has a new document: its markers wait for its overlay's hello (the old
		// context is still asked meanwhile: its answers fail or are dropped, seq)
		frame, _ := o["frame"].(json.Object)
		if _, sub := frame["parentId"]; sub do return
		a.hover_seq, a.pick_seq, a.has_hover = 0, 0, false
		for _, &mk in annot_markers do if mk.tab_id == a.tab_id do mk.found = false
		if u, ok := frame["url"].(json.String); ok do set_str(&a.url, u)
		delete(a.tracked)
		a.tracked = "" // the list goes again
		attach_world(a, b, str(frame, "id"))
		app.redraw = true
		return
	}
	if str(o, "name") != ANNOT_BINDING do return
	ctx, ok := int_of(o["executionContextId"])
	if !ok do return
	m, perr := jg.parse_string(str(o, "payload"), .JSON, true, context.temp_allocator)
	if perr != nil do return
	mo, is := m.(json.Object)
	if !is do return
	annot_message(a, b, ctx, mo)
}

// The document went (a navigation, a crash): nothing is asked of it any more.
@(private = "file")
annot_doc_gone :: proc(a: ^Annot) {
	a.ctx = 0
	a.hover_seq, a.pick_seq, a.has_hover = 0, 0, false
	for _, &m in annot_markers do if m.tab_id == a.tab_id do m.found = false
	app.redraw = true
}

@(private = "file")
set_str :: proc(dst: ^string, s: string) {
	if dst^ == s do return
	delete(dst^)
	dst^ = strings.clone(s)
}

// One overlay message (Runtime.bindingCalled from context ctx).
@(private = "file")
annot_message :: proc(a: ^Annot, b: ^Browser, ctx: i64, m: json.Object) {
	t := str(m, "t")
	if t == "hello" {
		// the latest document's overlay: the one we talk to from now on
		a.ctx = ctx
		a.hover_seq, a.pick_seq = 0, 0
		delete(a.tracked)
		a.tracked = "" // its marker list goes again
		for _, &mk in annot_markers do if mk.tab_id == a.tab_id do mk.found = false
	} else if ctx != a.ctx do return // an older document's
	if v, ok := num(m["sx"]); ok do a.scroll.x = v
	if v, ok := num(m["sy"]); ok do a.scroll.y = v
	if v, ok := num(m["vw"]); ok do a.view.x = v
	if v, ok := num(m["vh"]); ok do a.view.y = v
	if u, ok := m["url"].(json.String); ok do set_str(&a.url, u)
	if u, ok := m["title"].(json.String); ok do set_str(&a.title, u)
	app.redraw = true
	seq64, _ := int_of(m["seq"])
	seq := int(seq64)
	switch t {
	case "hello":
		annot_areas_found(a)
	case "hover":
		if seq != a.hover_seq do return
		a.hover_seq = 0
		r, ok := rect_of(m["r"])
		a.has_hover = ok && a.on && a.ptr_in
		a.hover = r
		set_str(&a.hover_label, core.cut_utf8(core.one_line(str(m, "label"), context.temp_allocator), 120))
		if a.hover_again do ask_hover(a, b)
	case "pick", "area":
		if seq == 0 || seq != a.pick_seq do return
		a.pick_seq = 0
		r, ok := rect_of(m["r"])
		if !ok do return
		// a comment being typed on this tab is kept: the new pick is dropped (Cancel it first)
		if d := comments_ui.draft; d.tab_id == a.tab_id && strings.trim_space(tf_text(&comment_new_field)) != "" do return
		a.has_hover = false // the pick's own outline shows while its comment is written
		p := new(Annot_Pick)
		p.kind = t == "pick" ? .Element : .Area
		p.seq = seq
		p.box = r
		p.scroll = a.scroll
		p.url = strings.clone(a.url)
		p.title = strings.clone(a.title)
		p.tag = strings.clone(core.cut_utf8(str(m, "tag"), 40))
		p.role = strings.clone(core.cut_utf8(str(m, "role"), 80))
		p.itype = strings.clone(core.cut_utf8(str(m, "type"), 40))
		p.name = strings.clone(core.cut_utf8(str(m, "name"), 400))
		p.selector = strings.clone(core.cut_utf8(str(m, "sel"), 1000))
		p.text = strings.clone(core.cut_utf8(str(m, "text"), 2000))
		if els, is := m["els"].(json.Array); is do for e in els {
			if len(p.els) >= 5 do break
			if s, is_s := e.(json.String); is_s do append(&p.els, strings.clone(core.cut_utf8(s, 400)))
		}
		// the crop now (§3.3: all context when the marker is made), from the frame on screen
		box := [4]int{int(math.floor(r.x * a.zoom)), int(math.floor(r.y * a.zoom)), int(math.ceil(r[2] * a.zoom)), int(math.ceil(r[3] * a.zoom))}
		comments_draft_pick(a.tab_id, p, browser_box_crop(a.tab_id, box))
	case "layout":
		a.layouts += 1
		list, _ := m["m"].(json.Array)
		for x in list {
			e, is := x.(json.Array)
			if !is || len(e) < 1 do continue
			cid, cid_ok := int_of(e[0])
			if !cid_ok do continue
			mk, has := &annot_markers[u64(cid)]
			if !has || mk.tab_id != a.tab_id do continue
			mk.found = false
			if len(e) >= 5 {
				r: [4]f32
				for i in 0 ..< 4 do r[i], _ = num(e[i + 1])
				mk.doc, mk.found = r, true
			}
		}
		annot_areas_found(a)
	}
}

// Area markers show on the document they were made on (same address).
@(private = "file")
annot_areas_found :: proc(a: ^Annot) {
	key := annot_url_key(a.url)
	for _, &mk in annot_markers do if mk.tab_id == a.tab_id && mk.kind == .Area do mk.found = a.ctx != 0 && mk.url == key
}

@(private = "file")
ask_hover :: proc(a: ^Annot, b: ^Browser) {
	a.hover_again = false
	if a.ctx == 0 do return
	a.seq += 1
	a.hover_seq = a.seq
	a.hover_at = time.tick_now()
	run(a, b, fmt.tprintf(`__pd.probe("hover",%.1f,%.1f,%d)`, a.ptr.x, a.ptr.y, a.seq), a.ctx)
}

// The element markers the overlay should follow in its document (those made at its address).
@(private = "file")
track_list :: proc(a: ^Annot) -> string {
	key := annot_url_key(a.url)
	s := strings.builder_make(context.temp_allocator)
	strings.write_byte(&s, '[')
	n := 0
	for cid, mk in annot_markers {
		if mk.tab_id != a.tab_id || mk.kind != .Element || mk.url != key do continue
		if n > 0 do strings.write_byte(&s, ',')
		fmt.sbprintf(&s, `{{"id":%d,"k":"e","seq":%d,"sel":`, cid, mk.seq)
		core.json_quote(&s, mk.selector)
		strings.write_byte(&s, '}')
		n += 1
	}
	strings.write_byte(&s, ']')
	return strings.to_string(s)
}

// ---- every frame (main.odin, after browser_tick) ----

annot_tick :: proc() {
	if len(browsers) == 0 && len(annots) == 0 && len(annot_markers) == 0 do return
	gone := make([dynamic]u64, context.temp_allocator)
	for id in annots do if browsers[id] == nil do append(&gone, id)
	for id in gone {
		a := annots[id]
		annot_free(a)
		delete_key(&annots, id)
	}
	// a comment sent, deleted or cleared takes its marker
	clear(&gone)
	for cid in annot_markers {
		if _, pc, _ := core.comment_find(cid); pc == nil do append(&gone, cid)
	}
	for cid in gone {
		marker_free(annot_markers[cid])
		delete_key(&annot_markers, cid)
		app.redraw = true
	}
	for id, b in browsers {
		a := annots[id]
		if a == nil {
			a = new(Annot)
			a.tab_id = id
			a.zoom = 1
			annots[id] = a
		}
		if b.cef != a.cef {
			if b.cef != 0 do install(a, b)
			else {
				a.cef = 0
				annot_doc_gone(a)
			}
		}
		if a.ctx == 0 || b.cef == 0 do continue
		// a hover question the page never answered (its document went meanwhile)
		if a.hover_seq != 0 && time.tick_since(a.hover_at) > ANNOT_HOVER_RETRY do a.hover_seq = 0
		// the markers to follow, and whether comment mode is on (the page reports scroll then too)
		if l := fmt.tprintf("%s,%v", track_list(a), a.on); l != a.tracked {
			delete(a.tracked)
			a.tracked = strings.clone(l)
			run(a, b, fmt.tprintf("__pd.track(JSON.parse(%s),%v)", quoted(track_list(a)), a.on), a.ctx)
		}
	}
}

@(private = "file")
quoted :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	core.json_quote(&b, s)
	return strings.to_string(b)
}

@(private = "file")
annot_free :: proc(a: ^Annot) {
	delete(a.pending)
	for k in a.sent do delete(k)
	delete(a.sent)
	delete(a.url)
	delete(a.title)
	delete(a.hover_label)
	delete(a.tracked)
	free(a)
}

// Comment mode on or off for the browser on screen.
annot_set :: proc(b: ^Browser, on: bool) {
	a := annots[b.tab_id]
	if a == nil || a.on == on do return
	a.on = on
	a.has_hover, a.press, a.dragging, a.hover_seq = false, false, false, 0
	a.pick_seq = 0 // a pick's answer still on its way opens nothing now
	// the page's own hover ends: the pointer is Deckhand's while commenting
	if on && b.cef != 0 do dh_cef_mouse_move(b.cef, b.last_x, b.last_y, 0, 1)
	app.redraw = true
}

// ---- input (main.odin: before browser_event) ----

@(private = "file")
in_pane :: proc(p: [4]f32, x, y: f32) -> bool {
	return p.z > 0 && x >= p.x && y >= p.y && x < p.x + p.z && y < p.y + p.w
}

// The Annotate button, ⌘⇧., badge clicks, and in comment mode the mouse over the page and the
// keys (the page gets neither). True if it took the event.
annot_event :: proc(p: ^core.Pane, e: ^sapp.Event) -> bool {
	b := pane_browser(p)
	if b == nil do return false
	r := pane_rect(p)
	a := annots[b.tab_id]
	if a == nil do return false
	mods := e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT)
	if e.type == .KEY_DOWN && e.key_code == .PERIOD && mods == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT {
		annot_set(b, !a.on)
		app.key_taken = true
		return true
	}
	overlay := palette_is_open() || menu.open || settings_open() || shortcuts_open() || setup_open() || job_sheet_open()
	covered := overlay || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y))
	if e.type == .MOUSE_DOWN && e.mouse_button == .LEFT && !covered {
		if cinside("annot_toggle", e.mouse_x, e.mouse_y) {
			annot_set(b, !a.on)
			return true
		}
		// a badge (either mode): its comment, to edit in the list
		if in_pane(r, e.mouse_x, e.mouse_y) do #reverse for h in badges {
			r := h.rect
			if e.mouse_x >= r.x && e.mouse_y >= r.y && e.mouse_x < r.x + r[2] && e.mouse_y < r.y + r[3] {
				comments_edit_open(h.comment_id)
				return true
			}
		}
	}
	if !a.on || b.cef == 0 do return false
	if b.buttons != 0 do return false // a press made in the page before: its moves and release go there
	#partial switch e.type {
	case .KEY_DOWN:
		if state.focus_widget != "" || e.modifiers & sapp.MODIFIER_SUPER != 0 do return false
		if e.key_code == .ESCAPE do annot_set(b, false)
		return true // the page gets no keys while commenting
	case .CHAR:
		if state.focus_widget != "" || e.modifiers & sapp.MODIFIER_SUPER != 0 do return false
		return true
	case .KEY_UP:
		return false // a key held in the page before gets its release (browser_event)
	}
	if covered && !a.press do return false
	pt := annot_fb_to_css({e.mouse_x, e.mouse_y}, a.zoom, app.dpi, {r.x, r.y})
	inside_page := in_pane(r, e.mouse_x, e.mouse_y)
	#partial switch e.type {
	case .MOUSE_MOVE:
		a.ptr, a.ptr_in = pt, inside_page
		if a.press {
			d := (pt - a.press_at) * a.zoom
			if !a.dragging && d.x * d.x + d.y * d.y >= ANNOT_DRAG_MIN * ANNOT_DRAG_MIN do a.dragging = true
			app.redraw = true
			return true
		}
		if !inside_page {
			if a.has_hover do app.redraw = true
			a.has_hover = false
			return false
		}
		if a.hover_seq == 0 do ask_hover(a, b)
		else do a.hover_again = true
		return true
	case .MOUSE_DOWN:
		if !inside_page do return false
		if state.home_open && !state.layout.drawer_pinned do ui_do(core.Set_Home{open = false})
		if e.mouse_button == .LEFT {
			a.press, a.press_at, a.dragging = true, pt, false
			a.ptr = pt
		}
		return true // the page gets no clicks while commenting
	case .MOUSE_UP:
		if e.mouse_button != .LEFT || !a.press do return inside_page
		a.press = false
		if a.ctx == 0 {
			a.dragging = false
			return true
		}
		a.seq += 1
		a.pick_seq = a.seq
		if a.dragging {
			a.dragging = false
			x0, y0 := min(a.press_at.x, pt.x), min(a.press_at.y, pt.y)
			x1, y1 := max(a.press_at.x, pt.x), max(a.press_at.y, pt.y)
			x0, y0 = max(x0, 0), max(y0, 0)
			if a.view.x > 0 do x1 = min(x1, a.view.x)
			if a.view.y > 0 do y1 = min(y1, a.view.y)
			run(a, b, fmt.tprintf(`__pd.area(%.0f,%.0f,%.0f,%.0f,%d)`, x0, y0, max(x1 - x0, 1), max(y1 - y0, 1), a.seq), a.ctx)
		} else do run(a, b, fmt.tprintf(`__pd.probe("pick",%.1f,%.1f,%d)`, pt.x, pt.y, a.seq), a.ctx)
		app.redraw = true
		return true
	case .MOUSE_LEAVE:
		a.ptr_in, a.has_hover = false, false
		app.redraw = true
		return false
	}
	return false
}

// ---- drawing (browser_draw, inside its sgl quads) ----

@(private = "file")
outline :: proc(r: [4]f32, t: f32, col: core.Rgba) {
	draw_rect(r.x, r.y, r[2], t, col)
	draw_rect(r.x, r.y + r[3] - t, r[2], t, col)
	draw_rect(r.x, r.y, t, r[3], col)
	draw_rect(r.x + r[2] - t, r.y, t, r[3], col)
}

// r clipped to the pane x,y,w,h; ok=false if nothing is left.
@(private = "file")
clip_rect :: proc(r: [4]f32, x, y, w, h: f32) -> (out: [4]f32, ok: bool) {
	x0, y0 := max(r.x, x), max(r.y, y)
	x1, y1 := min(r.x + r[2], x + w), min(r.y + r[3], y + h)
	if x1 <= x0 || y1 <= y0 do return {}, false
	return {x0, y0, x1 - x0, y1 - y0}, true
}

// The overlay over the page: markers (outline, numbered badge or edge arrow), the picked
// element while its comment is being written, the hover outline and its label, a drag's area.
// Each drawn frame starts with no badges (main.odin): every pane's page adds its own (their rects
// are in its pane, so a click finds the one under it).
annot_frame_begin :: proc() {clear(&badges)}

annot_draw :: proc(tab_id: u64, x, y, w, h: f32) {
	a := annots[tab_id]
	if a == nil do return
	th := theme()
	t := max(1, math.round(app.dpi))
	origin := [2]f32{x, y}
	// the pick being commented on
	if d := comments_ui.draft; d.tab_id == tab_id && d.pick != nil && annot_url_key(d.pick.url) == annot_url_key(a.url) {
		p := d.pick
		doc := [4]f32{p.box.x + p.scroll.x, p.box.y + p.scroll.y, p.box[2], p.box[3]}
		if r, ok := clip_rect(annot_doc_to_fb(doc, a.scroll, a.zoom, app.dpi, origin), x, y, w, h); ok {
			draw_rect(r.x, r.y, r[2], r[3], with_alpha(th.accent, 0.18))
			outline(r, 2 * t, th.accent)
		}
	}
	// markers, numbered as the session's list
	if s, _, _ := core.find_tab(tab_id); s != nil {
		lh := text_line_height(.UI)
		pad := px(SP_1)
		for cm, i in s.comments {
			mk, has := annot_markers[cm.id]
			if !has || mk.tab_id != tab_id || !mk.found do continue
			at_, badge := annot_place(mk.doc, a.scroll, a.view)
			label := fmt.tprintf("%d", i + 1)
			switch at_ {
			case .Above:          label = fmt.tprintf("↑ %d", i + 1)
			case .Below:          label = fmt.tprintf("↓ %d", i + 1)
			case .Left:           label = fmt.tprintf("← %d", i + 1)
			case .Right:          label = fmt.tprintf("→ %d", i + 1)
			case .On, .Not_Found, .Other_Page:
			}
			if at_ == .On {
				if r, ok := clip_rect(annot_doc_to_fb(mk.doc, a.scroll, a.zoom, app.dpi, origin), x, y, w, h); ok do outline(r, t, with_alpha(th.accent, 0.7))
			}
			bw := max(text_width(label, .UI, bold = true) + 2 * pad, lh + pad)
			bh := lh + pad
			bx := clamp(x + badge.x * a.zoom * app.dpi, x, x + w - bw)
			by := clamp(y + badge.y * a.zoom * app.dpi, y, y + h - bh)
			draw_rect(bx, by, bw, bh, th.accent)
			draw_text(bx + (bw - text_width(label, .UI, bold = true)) / 2, by + pad / 2, label, th.text_on_accent, .UI, bold = true)
			append(&badges, Badge_Hit{cm.id, {bx, by, bw, bh}})
		}
	}
	if !a.on do return
	if a.press && a.dragging {
		x0, y0 := min(a.press_at.x, a.ptr.x), min(a.press_at.y, a.ptr.y)
		x1, y1 := max(a.press_at.x, a.ptr.x), max(a.press_at.y, a.ptr.y)
		if r, ok := clip_rect(annot_doc_to_fb({x0, y0, x1 - x0, y1 - y0}, {}, a.zoom, app.dpi, origin), x, y, w, h); ok {
			draw_rect(r.x, r.y, r[2], r[3], with_alpha(th.accent, 0.15))
			outline(r, t, th.accent)
		}
		return
	}
	if !a.has_hover || a.press do return
	r, ok := clip_rect(annot_doc_to_fb(a.hover, {}, a.zoom, app.dpi, origin), x, y, w, h)
	if !ok do return
	draw_rect(r.x, r.y, r[2], r[3], with_alpha(th.accent, 0.12))
	outline(r, t, th.accent)
	if a.hover_label == "" do return
	lh := text_line_height(.UI)
	pad := px(SP_1)
	tw := min(text_width(a.hover_label, .UI), w - 2 * pad)
	shown := text_clip(a.hover_label, tw, .UI)
	cw, ch := tw + 2 * pad, lh + pad
	cx := clamp(r.x, x, x + w - cw)
	cy := r.y - ch - t
	if cy < y do cy = r.y + t
	draw_rect(cx, cy, cw, ch, th.bg_elevated)
	draw_rect(cx, cy, cw, t, th.border)
	draw_text(cx + pad, cy + pad / 2, shown, th.text)
}

// ---- Annotate on the browser toolbar (browser_nav.odin's browser_bar_layout) ----

// Comment mode's hint, in place of the address field while on (true: drawn). The toolbar
// keeps its height, so the page is not resized when the mode changes.
annot_hint_layout :: proc(b: ^Browser) -> bool {
	a := annots[b.tab_id]
	if a == nil || !a.on do return false
	th := theme()
	if clay.UI(cid("annot_hint"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BUTTON_H))}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
		dot(th.accent)
		msg := a.ctx != 0 ? "Click an element or drag over an area to comment · Esc leaves" : "Waiting for the page…"
		room := px(200)
		if d := clay.GetElementData(cid("annot_hint")); d.found do room = max(d.boundingBox.width - px(DOT + SP_2), px(80))
		clay.TextDynamic(clip(msg, room), txt(th.text))
	}
	return true
}

// Whether the tab is in comment mode (the toolbar has no address field then).
annot_on :: proc(b: ^Browser) -> bool {
	a := annots[b.tab_id]
	return a != nil && a.on
}

// The toolbar's Annotate button (its click: annot_event).
annot_button_layout :: proc(b: ^Browser) {
	if b.message != "" do return
	a := annots[b.tab_id]
	button(cid("annot_toggle"), "Annotate ⌘⇧.", a != nil && a.on, clay.PointerOver(cid("annot_toggle")))
}

// ---- the state snapshot (json_write.odin, inside a browser tab's object) ----

// `,"mode":…,"annot_ready":…,"doc_url":…,"markers":[…]`: comment mode, whether the overlay
// answers, the document on screen, and the tab's markers in the session's order: the comment,
// its number, kind, selector, document box (CSS px), where it is (annot_place, or not_found /
// other_page) and its badge's place (logical px from the page's top-left).
annot_tab_facts :: proc(f: ^core.Browser_Facts, tab_id: u64) {
	a := annots[tab_id]
	if a == nil do return
	f.annot, f.comment_mode, f.annot_ready, f.doc_url = true, a.on, a.ctx != 0, a.url
	s, _, _ := core.find_tab(tab_id)
	markers := make([dynamic]core.Browser_Marker_Fact, context.temp_allocator)
	if s != nil do for cm, i in s.comments {
		mk, has := annot_markers[cm.id]
		if !has || mk.tab_id != tab_id do continue
		at_, badge := annot_place(mk.doc, a.scroll, a.view)
		if !mk.found do at_ = mk.url == annot_url_key(a.url) && a.ctx != 0 ? .Not_Found : .Other_Page
		append(&markers, core.Browser_Marker_Fact {
			comment_id = cm.id,
			n = i + 1,
			area = mk.kind == .Area,
			selector = mk.selector,
			url = mk.url,
			box = fmt.tprintf("%d,%d %dx%d", int(math.round(mk.doc.x)), int(math.round(mk.doc.y)), int(math.round(mk.doc[2])), int(math.round(mk.doc[3]))),
			where_ = ANNOT_WHERE_NAMES[at_],
			badge = fmt.tprintf("%d,%d", int(math.round(badge.x * a.zoom)), int(math.round(badge.y * a.zoom))),
		})
	}
	f.markers = markers[:]
}

// ---- test mode (autotest.odin) ----
//
//   annot_move X Y             the pointer to page X,Y (logical px) through Deckhand's event path
//   annot_drag X1 Y1 X2 Y2     a left drag in the page (press, two moves, release)
//   annot_key cmd_shift_period | escape   ⌘⇧. or Esc through the event path
//   annot_assert crop N W H    comment N's crop (1-based, the session on screen) is a PNG of
//                              W×H logical px at this DPI (±2 px; scaled down past COMMENT_CROP_SIDE)
//   annot_assert hover yes|no  whether the hover outline shows
//   annot_assert label TEXT    the hover label is TEXT
//   annot_assert bar TEXT      the new-comment bar's head contains TEXT (- = no bar)
//   annot_assert what N TEXT   comment N's label (1-based, the session on screen) contains TEXT;
//                              what_not: does not
//   annot_assert layouts N     marker reports the tab's overlay sent so far
//   annot_assert sent METHOD N CDP calls of METHOD sent to the tab's browser so far

annot_script :: proc(cmd: string, args: []string, rest: string) -> (msg: string, ok: bool) {
	b := tab_browser()
	if b == nil do return fmt.tprintf("%s: no browser tab on screen", cmd), false
	f :: proc(s: string) -> f32 {
		v, _ := strconv.parse_f64(s)
		return f32(v)
	}
	org := tab_rect(b.tab_id) // the page's pane (panes.odin)
	at :: proc(o: [4]f32, x, y: f32) -> (f32, f32) {return o.x + x * app.dpi, o.y + y * app.dpi}
	switch cmd {
	case "annot_move":
		if len(args) < 2 do return "annot_move X Y", false
		mx, my := at(org, f(args[0]), f(args[1]))
		e := sapp.Event{type = .MOUSE_MOVE, mouse_x = mx, mouse_y = my}
		event(&e)
		return "", true
	case "annot_drag":
		if len(args) < 4 do return "annot_drag X1 Y1 X2 Y2", false
		x1, y1 := at(org, f(args[0]), f(args[1]))
		x2, y2 := at(org, f(args[2]), f(args[3]))
		app.clicks = 1
		e := sapp.Event{type = .MOUSE_MOVE, mouse_x = x1, mouse_y = y1}
		event(&e)
		e = {type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x1, mouse_y = y1}
		event(&e)
		e = {type = .MOUSE_MOVE, mouse_x = (x1 + x2) / 2, mouse_y = (y1 + y2) / 2}
		event(&e)
		e = {type = .MOUSE_MOVE, mouse_x = x2, mouse_y = y2}
		event(&e)
		e = {type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x2, mouse_y = y2}
		event(&e)
		return "", true
	case "annot_key":
		if len(args) < 1 do return "annot_key cmd_shift_period|escape", false
		e: sapp.Event
		switch args[0] {
		case "cmd_shift_period": e = {type = .KEY_DOWN, key_code = .PERIOD, modifiers = sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT}
		case "escape":           e = {type = .KEY_DOWN, key_code = .ESCAPE}
		case: return "annot_key cmd_shift_period|escape", false
		}
		event(&e)
		return "", true
	case "annot_assert":
		if len(args) < 2 do return "annot_assert crop|hover|label|bar …", false
		a := annots[b.tab_id]
		want := strings.trim_space(rest[len(args[0]):])
		got: string
		switch args[0] {
		case "crop":
			if len(args) < 4 do return "annot_assert crop N W H", false
			s := core.cur()
			n := int(f(args[1]))
			if s == nil || n < 1 || n > len(s.comments) do return fmt.tprintf("ASSERT FAILED annot_assert crop: no comment %d", n), false
			path := s.comments[n - 1].crop
			pw, ph, pok := png_size(path)
			if !pok do return fmt.tprintf("ASSERT FAILED annot_assert crop: %q is not a PNG", path), false
			ew, eh := f(args[2]) * app.dpi, f(args[3]) * app.dpi
			if k := f32(core.COMMENT_CROP_SIDE) / max(ew, eh); k < 1 do ew, eh = ew * k, eh * k
			if abs(f32(pw) - ew) > 2 || abs(f32(ph) - eh) > 2 do return fmt.tprintf("ASSERT FAILED annot_assert crop: %dx%d px, want %.0fx%.0f", pw, ph, ew, eh), false
			fmt.printfln("[annot] assert ok: crop %d is %dx%d px", n, pw, ph)
			return "", true
		case "what", "what_not":
			if len(args) < 3 do return "annot_assert what|what_not N TEXT", false
			s := core.cur()
			n := int(f(args[1]))
			if s == nil || n < 1 || n > len(s.comments) do return fmt.tprintf("ASSERT FAILED annot_assert %s: no comment %d", args[0], n), false
			text := strings.trim_space(want[len(args[1]):])
			has := strings.contains(s.comments[n - 1].what, text)
			if has != (args[0] == "what") do return fmt.tprintf("ASSERT FAILED annot_assert %s %d %q: the label is %q", args[0], n, text, s.comments[n - 1].what), false
			fmt.printfln("[annot] assert ok: %s %d %q", args[0], n, text)
			return "", true
		case "layouts": got = a != nil ? fmt.tprint(a.layouts) : "-"
		case "sent":
			// annot_assert sent METHOD N: CDP calls of METHOD so far
			if len(args) < 3 do return "annot_assert sent METHOD N", false
			got = fmt.tprintf("%s %d", args[1], a != nil ? a.sent[args[1]] : 0)
		case "hover": got = a != nil && a.has_hover ? "yes" : "no"
		case "label": got = a != nil ? a.hover_label : ""
		case "bar":
			d := comments_ui.draft
			got = d.pick != nil ? annot_pick_head(d.pick) : "-"
			if strings.contains(got, want) do got = want
		case: return fmt.tprintf("annot_assert: unknown %s", args[0]), false
		}
		if got != want do return fmt.tprintf("ASSERT FAILED annot_assert %s: got %q, want %q", args[0], got, want), false
		fmt.printfln("[annot] assert ok: %s = %s", args[0], got)
		return "", true
	}
	return fmt.tprintf("unknown command %s", cmd), false
}

// A PNG file's size from its header.
@(private = "file")
png_size :: proc(path: string) -> (w, h: int, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < 24 || string(data[:8]) != "\x89PNG\r\n\x1a\n" do return
	be :: proc(p: []u8) -> int {return int(p[0]) << 24 | int(p[1]) << 16 | int(p[2]) << 8 | int(p[3])}
	return be(data[16:20]), be(data[20:24]), true
}
