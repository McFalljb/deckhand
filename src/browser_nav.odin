package main

// Browser tabs, step 2 (docs/BROWSER.md §6): navigation. The commands
// (browser_open, browser_navigate, browser_back, browser_forward,
// browser_reload, browser_stop) and the tab's State (url, title, loading,
// can_back, can_forward, blocked_popup), the toolbar above the page (Back,
// Forward, Reload / Stop, the URL field), the URL field's normalising, and
// saving browser tabs in the workspace (persist.odin; restored tabs load once
// their session is first focused: start_restored_tabs).
//
// Sessions (docs/BROWSER.md §2.1): browser_open opens in the caller's own
// session: a pi tab's (its tab's session; it may not name another), the
// session on screen for the user and scripts, the named one for a control
// caller (Atlas, bound to Home, has no browser tabs of its own: it names the
// session). Never "whatever is focused" for an agent. A pi tab drives only its
// own session's browser tabs (an explicit exception to PROTOCOL.md §2's
// self-reference rule; closing them is still close_tab, which it may not send).
//
// What CEF reports (browser.odin's callbacks) comes back as Browser_Update
// (internal, through the inbox), so State and events follow the page.

import "core:slice"
import "core:strings"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"



// ---- URL normalising (the URL field and browser_open/browser_navigate) ----

// Which session browser_open opens in, which browser tabs a caller may drive, file: addresses and
// the tab's title: the core's (tabhost_route.odin), which checks them before the window's part.

// ---- commands ----

// The window's part of the navigation commands: CEF goes there (the core checked the caller, the
// tab and the URL, and changes the tab's record from the answer: tabhost_route.odin). tab_id: the
// tab browser_open makes.
browser_nav_apply :: proc(cmd: core.Command, caller: core.Caller, tab_id: u64 = 0) -> (r: core.Result, changed: bool) {
	#partial switch c in cmd {
	case core.Browser_Open:
		if tab_id == 0 do return core.fail("no tab for the page"), false
		blank := c.url == ""
		url := core.BROWSER_BLANK
		if !blank {
			err: string
			url, err = core.browser_url_normalize(c.url)
			if err != "" do return core.fail(err), false
		}
		browser_attach(tab_id, url)
		if blank && !core.harness_run_holds_sheet() {
			// the user's New browser tab: the keyboard goes to its URL field
			tf_set(&browser_url_field, "")
			browser_url_tab = tab_id
			delete(browser_url_error)
			browser_url_error = ""
			client_call(core.Focus_Take{widget = "browser_url"}, .Internal)
		}
		return {ok = true, created_id = tab_id}, true
	case core.Browser_Navigate:
		url, uerr := core.browser_url_normalize(c.url)
		if uerr != "" do return core.fail(uerr), false
		browser_go(c.tab_id, url)
		return {ok = true}, true
	case core.Browser_Back:
		return browser_step(c.tab_id, true), false // the page reports where it went (Browser_Update)
	case core.Browser_Forward:
		return browser_step(c.tab_id, false), false
	case core.Browser_Reload:
		b := browser_of(c.tab_id)
		if b == nil do return core.fail("the page is not loaded"), false
		if b.cef == 0 {
			// the page closed itself (or could not open): open it again, at its address
			url := ""
			if _, tab, _ := find_tab(c.tab_id); tab != nil do if bt, is := tab.kind.(core.Browser_Tab); is do url = bt.url
			if !browser_reopen(b, url) do return core.fail("the page is not loaded"), false
			return {ok = true}, true
		}
		dh_cef_history(b.cef, CEF_RELOAD)
		return {ok = true}, false
	case core.Browser_Stop:
		b := browser_of(c.tab_id)
		if b == nil || b.cef == 0 do return core.fail("the page is not loaded"), false
		dh_cef_history(b.cef, CEF_STOP)
		return {ok = true}, false
	}
	return core.fail("unknown command"), false
}

@(private = "file")
browser_step :: proc(tab_id: u64, back: bool) -> core.Result {
	b := browser_of(tab_id)
	if b == nil || b.cef == 0 do return core.fail("the page is not loaded")
	dh_cef_history(b.cef, back ? CEF_BACK : CEF_FORWARD)
	return {ok = true}
}

// Restored tabs (start_restored_tabs): the tab gets its runtime; CEF opens
// the page once the pane has a size (browser_tick).
browser_restore :: proc(tab_id: u64, url: string) {
	if browser_of(tab_id) != nil do return
	b := browser_attach(tab_id, url != "" ? url : core.BROWSER_BLANK)
	b.lazy = true // its page opens when the tab is first shown
}

// The command plumbing (type names, copies, events' fields, browser_url_redacted): browser_wire.odin.

// What CEF reported, into the tab's record (from browser.odin's callbacks): a tab_host.event the
// core runs with the tab_host caller, after the pump, never inside CEF's own call. The page's
// title goes with every address change (the core makes the tab's title from both).
browser_report :: proc(u: core.Browser_Update) {
	v := u
	if .Url in v.what || .Title in v.what {
		if b := browser_of(v.tab_id); b != nil {
			if .Url in v.what do set_str(&b.url, v.url) // a reopened page loads this
			if .Title not_in v.what do v.title = b.title
		}
	}
	tab_host_report(v) // tabhost_link.odin
}

@(private = "file")
set_str :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	old := dst^
	dst^ = strings.clone(v)
	delete(old)
}

// ---- the toolbar (ui.odin's centre, above the page) ----
//
// [‹] [›] [↻ / ✕] [ URL field ……………… ]
// Every action has a button (BROWSER.md §5); the URL field takes the
// keyboard on a click (⌘L too), Enter goes, Esc gives the page its keys back.

browser_url_field: Text_Field
browser_url_error: string // why the typed text was not opened ("" = none)
browser_url_tab: u64 // the tab the field was opened on: another one on screen drops it (browser_url_check)

@(private = "file")
nav_button :: proc(id: clay.ElementId, label: string, enabled: bool) {
	th := theme()
	hovered := enabled && clay.PointerOver(id)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(px(BUTTON_H)), clay.SizingFixed(px(BUTTON_H))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = cc(mix(th.bg_elevated, th.text, hovered ? TINT_BUTTON_HOVER : TINT_BUTTON)),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		clay.TextDynamic(label, txt(enabled ? th.text : th.text_muted, WEIGHT_BOLD))
	}
}

browser_bar_layout :: proc(p: ^core.Pane) {
	b := pane_browser(p)
	if b == nil do return
	_, tab, _ := find_tab(b.tab_id)
	if tab == nil do return
	bt, _ := tab.kind.(core.Browser_Tab)
	th := theme()
	focused := state.focus_widget == "browser_url" && core.pane_keys(p) // the field is the focused pane's
	// the agent strip on a row of its own when the toolbar has no room for it beside the least
	// address (a narrow pane): its buttons always whole (browser_agent.odin)
	own_row := browser_agent_strip_w(b) > 0 && toolbar_parts_w(b, bt) + px(URL_LEAST + STRIP_TEXT_LEAST) + browser_agent_strip_buttons_w(b) > pane_width()
	if clay.UI(cid("browser_bar"))({
		clip = {horizontal = true}, // its pane's width at most (bar_w)
		layout = {sizing = {bar_w(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		nav_button(cid("br_back"), "‹", bt.can_back)
		nav_button(cid("br_forward"), "›", bt.can_forward)
		if bt.loading do nav_button(cid("br_stop"), "✕", true)
		else do nav_button(cid("br_reload"), "↻", true)
		// comment mode: its hint takes the address field's place (browser_annotate.odin)
		if annot_hint_layout(b) {} else if clay.UI(cid("br_url_box"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			border = {color = cc(focused ? th.accent : th.border), width = {pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), 0}},
		}) {
			if clay.UI(cid("br_url_text"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
				if focused {
					shown, _, _ := tf_display(&browser_url_field, ime.marked)
					if shown == "" do clay.Text("Type a web address", txt(th.text_muted))
					else do clay.TextDynamic(shown, txt(th.text))
				} else {
					u := bt.url == core.BROWSER_BLANK ? "" : bt.url
					room := px(400) // the box's width last frame, inside its padding (px)
					if d := clay.GetElementData(cid("br_url_box")); d.found do room = max(d.boundingBox.width - px(2 * SP_2), px(40))
					// and no more than the bar leaves it beside its other parts (last frame): the
					// address gives way to the agent strip and its buttons (browser_agent.odin)
					// (a part's box is last frame's; the strip's width is computed: it comes and goes)
					if bar := clay.GetElementData(cid("browser_bar")); bar.found {
						others := px(2 * SP_2) + toolbar_parts_w(b, bt) + (own_row ? 0 : browser_agent_strip_w(b))
						// the bar's own width, at most its pane's (a long address must not widen the pane)
						room = max(min(room, min(bar.boundingBox.width, pane_width()) - others), px(40))
					}
					if u == "" do clay.Text("Type a web address", txt(th.text_muted))
					else do clay.TextDynamic(clip(u, room), txt(th.text_secondary))
				}
			}
		}
		if focused && browser_url_error != "" do clay.TextDynamic(browser_url_error, txt(th.error))
		if focused do nav_button(cid("br_go"), "Go", true)
		if !own_row do browser_agent_strip_layout(b, false) // an agent uses this page · Stop (browser_agent.odin)
		annot_button_layout(b) // comment mode's switch (browser_annotate.odin)
		browser_polish_toolbar_layout(b) // the zoom chip and ⋯ (browser_polish.odin)
	}
	if own_row do browser_agent_strip_layout(b, true) // under the toolbar, its own bar
	browser_polish_bars_layout(b) // crash, dialog, permission, popup, download and find bars (browser_polish.odin)
}

// The toolbar beside its address field and the agent strip may give way to: the least address
// (logical px) and the least of the strip's text, before the strip takes a row of its own.
URL_LEAST :: 80
STRIP_TEXT_LEAST :: 60

// What the toolbar's other parts take (last frame's boxes): its padding, Back, Forward, Reload
// or Stop, Annotate, the zoom chip, ⋯ (px).
@(private = "file")
toolbar_parts_w :: proc(b: ^Browser, bt: core.Browser_Tab) -> f32 {
	w := px(2 * TERM_PAD)
	for part in ([]string{"br_back", "br_forward", bt.loading ? "br_stop" : "br_reload", "annot_toggle", "pg_more", browser_zoomed(b) ? "pg_zoom" : ""}) {
		if part == "" do continue
		if d := clay.GetElementData(cid(part)); d.found do w += d.boundingBox.width + px(SP_1)
	}
	return w
}

// The URL field takes the keyboard with the tab's address selected.
browser_url_focus :: proc() {
	b := tab_browser()
	if b == nil || annot_on(b) do return // comment mode: no field on screen
	_, tab, _ := find_tab(b.tab_id)
	if tab == nil do return
	bt, _ := tab.kind.(core.Browser_Tab)
	tf_set(&browser_url_field, bt.url == core.BROWSER_BLANK ? "" : bt.url)
	tf_select_all(&browser_url_field)
	browser_url_tab = b.tab_id
	delete(browser_url_error)
	browser_url_error = ""
	ui_do(core.Set_Focus{"browser_url"})
}

// Enter (and Go): open what the field has; a text that is not an address
// stays with its reason.
@(private = "file")
browser_url_go :: proc() {
	b := tab_browser()
	if b == nil || b.tab_id != browser_url_tab do return
	_, err := core.browser_url_normalize(tf_text(&browser_url_field))
	delete(browser_url_error)
	browser_url_error = strings.clone(err)
	if err != "" {
		app.redraw = true
		return
	}
	ui_do(core.Browser_Navigate{tab_id = browser_url_tab, url = tf_text(&browser_url_field)})
	ui_do(core.Set_Focus{""}) // the page has the keyboard again
}

// A click on the toolbar (browser_event, before the page). True if it took it.
browser_bar_click :: proc(p: ^core.Pane, e: ^sapp.Event) -> bool {
	if e.type != .MOUSE_DOWN || e.mouse_button != .LEFT do return false
	b := pane_browser(p)
	if b == nil || (!cinside("browser_bar", e.mouse_x, e.mouse_y) && !cinside("br_agent_bar", e.mouse_x, e.mouse_y)) do return false // the toolbar, or the strip on its own row
	if cinside("annot_toggle", e.mouse_x, e.mouse_y) do return false // annot_event's
	hit :: proc(name: string, e: ^sapp.Event) -> bool {return cinside(name, e.mouse_x, e.mouse_y)}
	switch {
	case hit("br_back", e):    if browser_can(b.tab_id, .Back) do ui_do(core.Browser_Back{b.tab_id})
	case hit("br_forward", e): if browser_can(b.tab_id, .Forward) do ui_do(core.Browser_Forward{b.tab_id})
	case hit("br_reload", e):  ui_do(core.Browser_Reload{b.tab_id})
	case hit("br_stop", e):    ui_do(core.Browser_Stop{b.tab_id})
	case hit("br_go", e):      browser_url_go()
	case hit("br_agent_stop", e): ui_do(core.Browser_Agent_Stop{b.tab_id})
	// Take over and Hand back sit in one place: a click right after the last toggle (a double
	// click) is ignored for BARS_GUARD, so it never hands back what it just took
	case hit("br_agent_takeover", e): if browser_agent_toggle_ok(b.tab_id) do ui_do(core.Browser_Agent_Take_Over{tab_id = b.tab_id, on = true}) // browser_act.odin
	case hit("br_agent_handback", e): if browser_agent_toggle_ok(b.tab_id) do ui_do(core.Browser_Agent_Take_Over{tab_id = b.tab_id, on = false})
	case hit("br_url_box", e): if state.focus_widget != "browser_url" do browser_url_focus()
	}
	app.redraw = true
	return true
}

Browser_Can :: enum {
	Back,
	Forward,
}
@(private = "file")
browser_can :: proc(tab_id: u64, what: Browser_Can) -> bool {
	_, tab, _ := find_tab(tab_id)
	if tab == nil do return false
	bt, is := tab.kind.(core.Browser_Tab)
	if !is do return false
	return what == .Back ? bt.can_back : bt.can_forward
}

// The URL field's Enter and Esc (main.odin, before the generic text field).
// True if consumed.
browser_url_key :: proc(p: ^core.Pane, e: ^sapp.Event) -> bool {
	if state.focus_widget != "browser_url" do return false
	if browser_url_check() do return false
	if e.type != .KEY_DOWN do return false
	#partial switch e.key_code {
	case .ENTER, .KP_ENTER:
		app.key_taken = true // its CHAR must not reach the page
		browser_url_go()
		return true
	case .ESCAPE:
		delete(browser_url_error)
		browser_url_error = ""
		ui_do(core.Set_Focus{""})
		return true
	case .PERIOD:
		// ⌘⇧. (Annotate): the field lets go, comment mode toggles (browser_annotate.odin)
		mods := e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT)
		if mods == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT {
			ui_do(core.Set_Focus{""})
			return annot_event(p, e)
		}
	}
	return false
}

// The browser tab on screen and its id (actions.odin), or nil.
browser_shown :: proc() -> (^core.Browser_Tab, u64) {
	tab := core.active_tab()
	if tab == nil do return nil, 0
	bt, is := &tab.kind.(core.Browser_Tab)
	if !is do return nil, 0
	return bt, tab.id
}

// ---- which pages have a browser (CEF has 8 slots; browser_tick runs the plan) ----
//
// Every browser tab with a runtime may want a page; CEF holds at most 8.
// Rules (browser_page_plan, pure; docs/BROWSER.md "Pages"):
//  - only the user unloads a page: the tabs on screen (one per pane showing a
//    page; only the user puts one there, an agent's browser_open never does)
//    get a page first, and when no slot is free the least recently shown hidden
//    page goes for each, its own session's first, then any session's, never one
//    twice nor an on-screen one (its URL stays; it loads when shown);
//  - every other tab that wants a page (an agent's, a background popup's)
//    loads while slots are free, the first to ask first; otherwise it waits
//    ("too many open pages") and loads when one frees. It never unloads one;
//  - a popup whose browser CEF is still making (pinned) is never unloaded.
// Restored tabs and unloaded ones load only when shown (Browser.lazy).

Page_Info :: struct {
	session: u64,
	live:    bool, // has a CEF browser (or one on its way)
	wants:   bool, // needs a page and has none
	visible: bool, // on screen (the user's doing)
	pinned:  bool, // never unloaded (a popup whose browser is on its way)
	shown:   i64, // when last on screen (or opened)
}
Page_Plan :: struct {
	load:   [dynamic]int, // open its page
	unload: [dynamic]int, // close its page (keeps its URL; loads again when shown)
	wait:   [dynamic]int, // no slot: retried when one frees
}

browser_page_plan :: proc(pages: []Page_Info, free_slots: int, allocator := context.temp_allocator) -> (p: Page_Plan) {
	p.load = make([dynamic]int, allocator)
	p.unload = make([dynamic]int, allocator)
	p.wait = make([dynamic]int, allocator)
	slots := free_slots
	taken := make([dynamic]int, context.temp_allocator) // victims already chosen
	// 1. the tabs on screen (one per pane showing a page)
	for x, i in pages {
		if !x.visible || !x.wants do continue
		if slots > 0 {
			append(&p.load, i)
			slots -= 1
			continue
		}
		// the least recently shown hidden page: its own session's, else anyone's
		victim := -1
		for y, k in pages {
			if !y.live || y.visible || y.pinned do continue
			if slice.contains(taken[:], k) do continue
			if victim < 0 {victim = k; continue}
			v := pages[victim]
			own, vown := y.session == x.session, v.session == x.session
			if own != vown {
				if own do victim = k
			} else if y.shown < v.shown do victim = k
		}
		if victim < 0 {
			append(&p.wait, i)
			continue
		}
		append(&taken, victim)
		append(&p.unload, victim)
		append(&p.load, i)
	}
	// 2. the others, the first to ask first: a free slot, or wait
	rest := make([dynamic]int, context.temp_allocator)
	for x, i in pages do if x.wants && !x.visible do append(&rest, i)
	for a in 1 ..< len(rest) {
		for b := a; b > 0 && pages[rest[b]].shown < pages[rest[b - 1]].shown; b -= 1 do rest[b], rest[b - 1] = rest[b - 1], rest[b]
	}
	for i in rest {
		if slots > 0 {
			append(&p.load, i)
			slots -= 1
		} else do append(&p.wait, i)
	}
	return
}

// Every frame (browser_tick) and before a key: the URL field belongs to the tab
// it was opened on; another tab on screen (or none) drops it, so Enter never
// loads its text into the wrong tab. True: dropped.
browser_url_check :: proc() -> bool {
	if state.focus_widget != "browser_url" do return false
	// the field's own tab, while it has the keyboard (panes.odin); comment mode's hint has the
	// field's place (browser_annotate.odin)
	if b := browsers[browser_url_tab]; b != nil && core.tab_focused(browser_url_tab) && !annot_on(b) do return false
	ui_do(core.Set_Focus{""})
	return true
}
