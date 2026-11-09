package core

// From src/theme.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

// ---- type ----
// UI text (system font, two sizes) and code (the look's terminal family),
// in logical px; the text layer scales by the display (font.odin). The UI
// sizes follow Settings.text_size (the gear's "Text size"); code stays put.
TYPE_CODE_PX :: 14

// The chrome's text size. Default first: the zero value, not saved.
Text_Size :: enum {
	Default,
	Small,
	Medium,
	Large,
}

BORDER_W :: 1 // dividers

LEFT_MIN :: 200

LEFT_MAX :: 480

RIGHT_MIN :: 240

RIGHT_MAX :: 560

PANE_MIN_W :: 240 // a pane's content, at least (logical px; ~28 columns); split_pane refuses less

PANE_MIN_H :: 140 // (~6 rows)

Theme_Id :: enum {
	Graphite,
	Warm,
	Ghostty,
}

// Light or dark, independent of the look: `system` follows the OS
// appearance (State.system_light, reported by the platform layer).
Appearance :: enum {
	System,
	Light,
	Dark,
}
