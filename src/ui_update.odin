package main

// The update bar over the centre (update.odin has the model): "pi-desk 0.1.1 is
// available" with Release notes, Skip this version, Later and Update; then
// "Downloading…", "ready: Restart to update", or why it was not installed. Every step is
// a visible button; nothing installs without a click.

import "core:fmt"
import clay "../build/clay-odin"

Update_Part :: enum u8 {
	Notes,
	Skip,
	Later,
	Update,
	Install,
}

Hit_Update :: struct {
	part: Update_Part,
}

UPDATE_IDS := [Update_Part]string {
	.Notes   = "update_notes",
	.Skip    = "update_skip",
	.Later   = "update_later",
	.Update  = "update_go",
	.Install = "update_install",
}

update_bar_shows :: proc() -> bool {
	if upd.phase == .Downloading || upd.phase == .Installed do return true
	return upd.offered && !upd.dismissed
}

// The bar's text and its buttons, left to right.
update_bar_parts :: proc() -> (msg: string, parts: [dynamic]Update_Part) {
	parts = make([dynamic]Update_Part, context.temp_allocator)
	v := upd.release.version
	switch upd.phase {
	case .Downloading:
		msg = fmt.tprintf("Downloading Deckhand %s and checking its signature…", v)
		append(&parts, Update_Part.Notes)
	case .Ready:
		msg = fmt.tprintf("Deckhand %s is ready", v)
		if any_running() || jobs_any_running() do msg = fmt.tprintf("%s — restarting stops running sessions, shells and jobs", msg)
		append(&parts, Update_Part.Later, Update_Part.Install)
	case .Failed:
		msg = fmt.tprintf("Deckhand %s not installed: %s", v, upd.message)
		append(&parts, Update_Part.Notes, Update_Part.Skip, Update_Part.Later)
		if update_cannot_install() == "" do append(&parts, Update_Part.Update)
	case .Installed:
		msg = fmt.tprintf("Deckhand %s is installed: restarting…", v)
	case .None, .Checking:
		msg = fmt.tprintf("Deckhand %s is available", v)
		append(&parts, Update_Part.Notes, Update_Part.Skip, Update_Part.Later)
		if why := update_cannot_install(); why != "" do msg = fmt.tprintf("%s — %s", msg, why)
		else do append(&parts, Update_Part.Update)
	}
	return
}

update_part_label :: proc(p: Update_Part) -> string {
	switch p {
	case .Notes:   return "Release notes"
	case .Skip:    return "Skip this version"
	case .Later:   return "Later"
	case .Update:  return upd.phase == .Failed ? "Try again" : "Update"
	case .Install: return "Restart to update"
	}
	return ""
}

// At the top of the centre (ui.odin), above the hot-reload bars.
update_bar :: proc() {
	if !update_bar_shows() do return
	th := theme()
	msg, parts := update_bar_parts()
	used := px(2 * TERM_PAD + DOT + 2 * SP_2)
	for p in parts {
		primary := p == .Update || p == .Install
		used += text_w(update_part_label(p), primary ? WEIGHT_BOLD : WEIGHT_REGULAR) + px(2 * SP_3 + SP_2)
	}
	if clay.UI(clay.ID("update_bar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		dot(upd.phase == .Failed ? th.error : th.accent)
		clay.TextDynamic(clip(msg, max(centre_width() - used, px(80))), txt(upd.phase == .Failed ? th.error : th.text))
		spacer()
		for p in parts {
			primary := p == .Update || p == .Install
			button(clay.ID(UPDATE_IDS[p]), update_part_label(p), primary, ui_hover == Hit(Hit_Update{p}))
		}
	}
}

update_hit :: proc() -> Hit {
	if !update_bar_shows() do return nil
	for id, part in UPDATE_IDS do if clay.PointerOver(clay.ID(id)) do return Hit_Update{part}
	return nil
}

update_tip :: proc(h: Hit_Update) -> (label, keys: string) {
	switch h.part {
	case .Notes:   return "Open the release's page on GitHub in your browser", ""
	case .Skip:    return "Do not offer this version again (Check for Updates… offers it again)", ""
	case .Later:   return "Hide this until the next check finds a release", ""
	case .Update:  return "Download it and check its signature; nothing is replaced until you restart", ""
	case .Install: return "Replace Deckhand with the checked update and restart it (asks first while anything runs)", ""
	}
	return "", ""
}

// A click on the bar's button (main.odin).
update_click :: proc(h: Hit_Update) {
	switch h.part {
	case .Notes:
		url := upd.release.notes_url != "" ? upd.release.notes_url : UPDATE_RELEASES_URL
		if platform.open_url != nil do _ = platform.open_url(url)
	case .Skip:    ui_do(Update_Skip{})
	case .Later:   ui_do(Update_Later{})
	case .Update:  ui_do(Update_Download{})
	case .Install: ui_do(Update_Install{})
	}
	app.redraw = true
}
