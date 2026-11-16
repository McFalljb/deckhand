package main

// The bar over the centre while the session holder is lost (core holder_recover.odin, #108): what
// it means, and its one action. The holder gone: Restart session holder starts a new one. Still
// running but not answering: Restart session holder attaches to it again (its sessions come back
// to their tabs); when that found it still not answering, the button stops it, saying how many
// sessions that ends.

import "core:fmt"
import "core"
import clay "../build/clay-odin"

Hit_Holder_Bar :: struct {}

// What the bar says, and its button's label.
holder_bar_text :: proc(v: core.Holder_Lost_Live) -> (msg, button: string) {
	after :: "new tabs won't keep running when Deckhand's core restarts or quits"
	if !v.alive do return fmt.tprintf("The session holder stopped: the sessions it kept have ended, and %s.", after), "Restart session holder"
	msg = fmt.tprintf("The session holder isn't answering: the sessions it keeps can't be reached here, and %s.", after)
	if !v.stop do return msg, "Restart session holder"
	n := v.sessions
	what := n > 0 ? fmt.tprintf("ends its %d session%s", n, n == 1 ? "" : "s") : "ends its sessions"
	return msg, fmt.tprintf("Stop it (%s) and start a new one", what)
}

// At the top of the centre (ui.odin), under the update bar.
holder_bar :: proc() {
	v := core.holder_lost_view()
	if !v.lost do return
	th := theme()
	msg, label := holder_bar_text(v)
	used := px(2 * TERM_PAD + DOT + 2 * SP_2) + text_w(label, WEIGHT_BOLD) + px(2 * SP_3 + SP_2)
	if clay.UI(clay.ID("holder_bar"))({
		clip = {horizontal = true},
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		dot(th.error)
		clay.TextDynamic(clip(msg, max(centre_width() - used, px(80))), txt(th.text))
		spacer()
		button(clay.ID("holder_bar_go"), label, true, ui_hover == Hit(Hit_Holder_Bar{}))
	}
}

holder_bar_hit :: proc() -> Hit {
	if !core.holder_lost_view().lost || !clay.PointerOver(clay.ID("holder_bar_go")) do return nil
	return Hit_Holder_Bar{}
}

holder_bar_tip :: proc() -> (label, keys: string) {
	v := core.holder_lost_view()
	if v.stop do return "Stop the session holder that isn't answering (its sessions end), then start a new one: new tabs keep running again", ""
	if v.alive do return "Attach to the session holder again: its sessions come back to their tabs, and new tabs keep running again", ""
	return "Start a new session holder: new tabs keep running again. Tabs that ended can be restarted as usual", ""
}

holder_bar_click :: proc() {
	v := core.holder_lost_view()
	if !v.lost do return
	ui_do(core.Holder_Recover{stop = v.stop})
	app.redraw = true
}
