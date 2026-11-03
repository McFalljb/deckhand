package main

// Design tokens: every size, colour and timing the chrome uses lives here.
// ui.odin reads only these (no raw numbers or colours there). Sizes are
// logical px on a 4/8 grid; ui.odin multiplies by app.dpi.
//
// A look (Theme_Id) is a preset of the colour tokens plus the terminal's
// default colours, so pi's TUI blends with the chrome. It is switched live
// with the set_theme command and stored in State.settings.theme. Each look
// has a dark (THEMES) and a light (THEMES_LIGHT) variant; set_appearance
// picks one (system, light, dark), State.settings.appearance.

import gh "ghostty"
import "core:math"
import "core:time"

// ---- spacing (4/8 grid) ----
SP_1 :: 4
SP_2 :: 8
SP_3 :: 12
SP_4 :: 16
SP_6 :: 24

// Spacing roles: which step of the grid each kind of gap uses, so the same
// relation reads the same everywhere (rows, bars, menus).
GAP_INLINE :: SP_2 // between a row's parts: icon, text, time, buttons
GAP_BUTTONS :: SP_1 // between adjacent buttons of one group
GAP_GROUP :: SP_3 // between button groups (a separator sits in it)
GAP_SECTION :: SP_3 // between the left column's sections
PAD_ROW :: SP_2 // a row's inner left and right padding
PAD_OVERLAY :: SP_1 // inside menus, the settings popover and the sheet
SEPARATOR_H :: 16 // a vertical separator between button groups

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
TEXT_SIZE_NAMES := [Text_Size]string {
	.Default = "default",
	.Small   = "small",
	.Medium  = "medium",
	.Large   = "large",
}
// Smallest to largest, as the gear shows them.
TEXT_SIZE_ORDER :: [4]Text_Size{.Small, .Medium, .Default, .Large}
// UI body and secondary (small) text per size, logical px.
TYPE_UI_PX := [Text_Size][2]f32 {
	.Small   = {12, 11},
	.Medium  = {13, 11},
	.Default = {14, 12},
	.Large   = {15, 13},
}
// Weights: OR'ed into Clay's fontId (font kind | FONT_BOLD), real bold faces.
WEIGHT_REGULAR :: 0
WEIGHT_BOLD :: FONT_BOLD
WEIGHT_HEADER :: FONT_SEMIBOLD // section headers (sidebar sections, panels, Settings groups, the bell's days)

// ---- shape ----
RADIUS_SM :: 4
RADIUS_MD :: 6
BORDER_W :: 1 // dividers
FOCUS_RING_W :: 1 // text field outline in the accent colour
CARET_W :: 1.5

// ---- sizes ----
ROW_H :: 30 // project and session rows (28–32)
HEADER_H :: 28 // section headers
TAB_STRIP_H :: 40
TAB_H :: 28
TAB_MIN_W :: 72 // a tab's width without its close button's room
TAB_MAX_W :: 200 // longer titles are cut with an ellipsis
BAR_H :: 44 // confirmation bar (its smallest height: a long summary wraps)
CONFIRM_LINES :: 4 // the most lines a confirmation's summary takes; the last is cut with an ellipsis
BUTTON_H :: 28
DOT :: 6 // status dot
PANEL_ROW_H :: 24 // panel rows in the right column (denser than session rows)
// Icons (icons.odin): vector shapes on a 16-unit grid, one stroke width.
ICON_SIZE :: 16
ICON_SIZE_SM :: 14 // on rows and tabs
ICON_STROKE :: 1.25 // logical px (rounded to whole device px)
// Top bar toolbar (ui_toolbar.odin): icon buttons and the search pill.
TOOL_BUTTON :: TAB_H // square icon buttons
SEARCH_W :: 280 // the "Search or run a command" pill, when the bar has room
SEARCH_MIN_ROOM :: 160 // the bar's free width (beyond the pill) it keeps before the pill becomes an icon
NEW_MENU_W :: 16 // the chevron beside the tab strip's "+"
// Settings popover (the stopgap until the Settings tab) and the shortcuts sheet.
POPOVER_W :: 300
POPOVER_ROW_H :: 30
SEGMENT_H :: 24 // appearance segmented control
SEGMENT_PAD :: SP_1 + 2 // a segment's left and right padding where four share a row (text size)
SWATCH :: 20 // look swatches
SWITCH_W :: 28 // on/off switches
SWITCH_H :: 16
CHIP_SMALL_H :: 22 // the gear's "Notify me about" toggles
BELL_POP_W :: 380 // the bell's popover (ui_bell.odin)
BELL_ROW_H :: 44 // an entry: what happened, then where
BELL_GROUP_H :: 24 // "Today", "Earlier"
TOP_BAR_COMPACT_W :: 640 // a narrower top bar shows the agent's initial without its name
SHEET_W :: 520
SHEET_TOP :: 72
SHEET_ROW_H :: 26
KEYCAP_PAD :: 6 // shortcut keycaps
DISABLED_ALPHA :: 0.45 // a button whose action does not apply now
// Tooltips: after the pointer rests on a control; label and shortcut.
TIP_DELAY :: 500 * time.Millisecond
TIP_H :: 24
TIP_OFFSET :: 18 // below the pointer
// Left column (ui_sidebar.odin): the Open, Projects (a tree: a project's
// sessions under it) and Chats sections in one scrolling list.
PINNED_GAP :: SP_3 // between a list's pinned rows and the rest (a thin line in it)
CHIP_H :: 24 // quick filter chips
CHIP_PAD :: SP_3 // a chip's left and right padding
TREE_CHEVRON :: SP_3 // the fold chevron's box on a project row
TREE_INDENT :: TREE_CHEVRON + GAP_INLINE // a project's sessions line up with its icon
TREE_SHOW :: 8 // sessions shown under a project before "Show more"
KIND_ICON :: ICON_SIZE_SM // folder (project) or bubble (chat) on rows and tabs
FIELD_H :: 28 // the filter field
ROW_BUTTON :: ROW_H - SP_3 // pin, new chat and close buttons on a hovered row
// The left column's tabs (Sessions | Files) and the Files tab (ui_files.odin).
LEFT_TABS_H :: SEGMENT_H + 4 // the segmented switch under the title bar
FILES_ROW_H :: 24 // tree rows (denser than session rows)
FILES_INDENT :: 12 // per folder level
FILES_TOOL :: ROW_BUTTON // header icon buttons
FILES_DRAG_START :: 4 // px the pointer moves before a press on a row becomes a drag
FILES_SCROLL_THUMB :: 3 // the list's scroll indicator
// Context and sort menus.
MENU_W :: 220
MENU_W_MAX :: 360 // a menu grows to its longest row up to this; longer labels are cut
SHADOW_Y :: 2 // a floating box's shadow: offset down
SHADOW_SPREAD :: 3 // and how far it reaches past each edge (two layers: this and twice this)
MENU_ROW_H :: 26
MENU_SEP_H :: SP_2
// Column dividers (drag to resize; double-click resets).
DIVIDER_HIT :: 6 // grab width across the 1 px line
LEFT_MIN :: 200
LEFT_MAX :: 480
RIGHT_MIN :: 240
RIGHT_MAX :: 560
CENTRE_MIN :: 360 // the terminal never gets narrower; small windows shrink the columns first
WINDOW_MIN_W :: LEFT_MIN + CENTRE_MIN + RIGHT_MIN // the window's smallest size (its layout is audited down to it)
WINDOW_MIN_H :: 480
RESIZE_THROTTLE :: 120 * time.Millisecond // terminal grid (and PTY) resizes while a divider is dragged
TERM_PAD :: SP_3 // between the terminal pane edge and its cell grid
// Title bar (macOS): the top bar (tab strip and the sidebar's top) is the
// title bar; the traffic lights sit centred in it, over the left column.
LIGHTS_X :: SP_4 + SP_1 // first traffic light's left edge
LIGHTS_W :: 3 * SP_6 // the three lights and their gaps (drawn by the OS; keep clear)
// Command palette (⌘K): a floating box near the top of the window.
PALETTE_W :: 600
PALETTE_TOP :: 72 // from the window top
PALETTE_ROWS :: 9 // visible result rows; the list scrolls past them
PALETTE_RESULTS_MAX :: 300 // only PALETTE_ROWS are drawn; the cap keeps sorting cheap
PALETTE_RECENT_MAX :: 8
PALETTE_KIND_W :: 64 // right-hand column: kind or shortcut
// The agent's chat drawer (⌘J): slides over the right side of the body,
// under the top bar and the confirmation bar; pinned, it is a column.
// Width in State.layout.drawer_width (DRAWER_WIDTH_* in state.odin).
DRAWER_MAX_FRACTION :: 0.7 // of the space right of the left column
DRAWER_PAD :: SP_4 // around the chat column
AVATAR :: 22 // the agent's initial in a circle
BUBBLE_MAX_FRACTION :: 0.85 // user messages: of the chat column
CHAT_GAP :: SP_3 // between chat items
CHAT_FIELD_LINES :: 8 // message field lines shown before it scrolls with the caret
CODE_PAD :: SP_2 // inside code blocks
BADGE_H :: 16 // unread count on the top bar button

// ---- motion ----
DUR_HOVER :: 120 * time.Millisecond // hover fades, ease-out
DUR_SWITCH :: 160 * time.Millisecond // selection/tab switch, ease-out
DUR_SLIDE :: 180 * time.Millisecond // the agent's drawer in and out, ease-out
PULSE_FPS :: 10 // "running" dot redraw rate; no redraws without a running dot
PULSE_PERIOD :: 1600 * time.Millisecond
PULSE_MIN :: 0.4 // dimmest point of the running dot (alpha)
// Tints towards the text colour (0..1): secondary button at rest and on
// hover, primary button on hover; an exited session's dot alpha.
TINT_BUTTON :: 0.06
TINT_BUTTON_HOVER :: 0.12
TINT_PRIMARY_HOVER :: 0.15
TINT_SEGMENT :: 0.16 // the chosen segment of a segmented control
EXITED_ALPHA :: 0.5
QUESTION_ALPHA :: 0.55 // pi asked something (softer than "waiting for you")
// Shell tabs (no bridge) count as running while their terminal printed
// something within this window. pi tabs use the bridge's pi.status.
ACTIVITY_WINDOW :: 1500 * time.Millisecond
SCROLL_STEP :: 10 // px per wheel unit in the chrome's lists

// ---- colours ----

Theme_Id :: enum {
	Graphite,
	Warm,
	Ghostty,
}

THEME_NAMES := [Theme_Id]string {
	.Graphite = "graphite",
	.Warm     = "warm",
	.Ghostty  = "ghostty",
}

Theme :: struct {
	font_family:    string, // wanted terminal/UI family; the text layer picks the face
	// surfaces
	bg_app:         Rgba, // centre column; equals the terminal background
	bg_sidebar:     Rgba,
	bg_panel:       Rgba, // right column
	bg_elevated:    Rgba, // bars, buttons
	bg_field:       Rgba, // text fields
	hover:          Rgba, // overlay on any surface (alpha)
	selected:       Rgba, // overlay on any surface (alpha)
	// text
	text:           Rgba,
	text_secondary: Rgba,
	text_muted:     Rgba,
	text_on_accent: Rgba,
	border:         Rgba,
	// one accent: focus and the primary action
	accent:         Rgba,
	selection:      Rgba, // text selection in fields (alpha)
	scrim:          Rgba, // behind the command palette (alpha)
	shadow:         Rgba, // under menus and popovers (alpha; overlay_shadow)
	// status
	running:        Rgba,
	waiting:        Rgba, // waiting for you
	done:           Rgba,
	error:          Rgba,
	// terminal defaults (libghostty-vt default fg/bg/cursor/palette)
	term_fg:        Rgba,
	term_bg:        Rgba,
	term_cursor:    Rgba,
	term_selection: Rgba, // selected cells' background (text keeps its colour)
	ansi:           [16]Rgba, // 16..255 follow xterm's cube and grey ramp
}

THEMES := [Theme_Id]Theme {
	// Neutral dark: zinc greys, a calm blue accent.
	.Graphite = {
		font_family    = "Menlo",
		bg_app         = {0x17, 0x17, 0x1a, 255},
		bg_sidebar     = {0x1e, 0x1e, 0x22, 255},
		bg_panel       = {0x1e, 0x1e, 0x22, 255},
		bg_elevated    = {0x27, 0x27, 0x2c, 255},
		bg_field       = {0x12, 0x12, 0x14, 255},
		hover          = {255, 255, 255, 10},
		selected       = {255, 255, 255, 20},
		text           = {0xe4, 0xe4, 0xe7, 255},
		text_secondary = {0xa1, 0xa1, 0xaa, 255},
		text_muted     = {0x74, 0x74, 0x7e, 255}, // 3:1 on bg_elevated
		text_on_accent = {0x0b, 0x10, 0x20, 255},
		border         = {0x2a, 0x2a, 0x30, 255},
		accent         = {0x7a, 0xa2, 0xf7, 255},
		selection      = {0x7a, 0xa2, 0xf7, 90},
		scrim          = {0, 0, 0, 110},
		shadow         = {0, 0, 0, 70},
		running        = {0x56, 0xb6, 0xc2, 255},
		waiting        = {0xe5, 0xb9, 0x5c, 255},
		done           = {0x7e, 0xc4, 0x88, 255},
		error          = {0xef, 0x6f, 0x6c, 255},
		term_fg        = {0xd4, 0xd4, 0xd8, 255},
		term_bg        = {0x17, 0x17, 0x1a, 255},
		term_cursor    = {0xe4, 0xe4, 0xe7, 255},
		term_selection = {0x34, 0x44, 0x6a, 255}, // accent over term_bg
		ansi           = {
			{0x27, 0x27, 0x2a, 255}, {0xe5, 0x73, 0x7a, 255}, {0x8f, 0xc4, 0x8a, 255}, {0xe3, 0xc0, 0x7b, 255},
			{0x7a, 0xa2, 0xf7, 255}, {0xc2, 0x9b, 0xe0, 255}, {0x6f, 0xc2, 0xc8, 255}, {0xc8, 0xc8, 0xce, 255},
			{0x5a, 0x5a, 0x63, 255}, {0xf0, 0x8a, 0x90, 255}, {0xa6, 0xd6, 0xa0, 255}, {0xee, 0xd4, 0x9a, 255},
			{0x96, 0xb6, 0xf8, 255}, {0xd3, 0xb3, 0xec, 255}, {0x8d, 0xd3, 0xd8, 255}, {0xed, 0xed, 0xf0, 255},
		},
	},
	// Warm dark: brown-greys, a terracotta accent.
	.Warm = {
		font_family    = "Menlo",
		bg_app         = {0x1b, 0x18, 0x15, 255},
		bg_sidebar     = {0x22, 0x1e, 0x1a, 255},
		bg_panel       = {0x22, 0x1e, 0x1a, 255},
		bg_elevated    = {0x2e, 0x29, 0x24, 255},
		bg_field       = {0x14, 0x12, 0x10, 255},
		hover          = {255, 240, 220, 10},
		selected       = {255, 240, 220, 20},
		text           = {0xed, 0xe4, 0xd8, 255},
		text_secondary = {0xb5, 0xa8, 0x98, 255},
		text_muted     = {0x7d, 0x71, 0x65, 255},
		text_on_accent = {0x1b, 0x12, 0x06, 255},
		border         = {0x32, 0x2c, 0x26, 255},
		accent         = {0xe0, 0x89, 0x5f, 255},
		selection      = {0xe0, 0x89, 0x5f, 90},
		scrim          = {0, 0, 0, 110},
		shadow         = {0, 0, 0, 70},
		running        = {0x7f, 0xb0, 0xc8, 255},
		waiting        = {0xe8, 0xc2, 0x5a, 255},
		done           = {0xa6, 0xbe, 0x6e, 255},
		error          = {0xe0, 0x67, 0x5a, 255},
		term_fg        = {0xe0, 0xd6, 0xc8, 255},
		term_bg        = {0x1b, 0x18, 0x15, 255},
		term_cursor    = {0xed, 0xe4, 0xd8, 255},
		term_selection = {0x52, 0x37, 0x2a, 255}, // accent over term_bg
		ansi           = {
			{0x2a, 0x25, 0x20, 255}, {0xd9, 0x70, 0x5f, 255}, {0xa3, 0xb8, 0x6c, 255}, {0xe3, 0xb3, 0x41, 255},
			{0x7f, 0xa7, 0xc9, 255}, {0xc6, 0x91, 0x9f, 255}, {0x86, 0xb8, 0xa6, 255}, {0xd9, 0xcf, 0xc2, 255},
			{0x6b, 0x60, 0x56, 255}, {0xea, 0x8a, 0x78, 255}, {0xb8, 0xcc, 0x83, 255}, {0xf0, 0xc7, 0x66, 255},
			{0x9b, 0xbc, 0xd8, 255}, {0xd7, 0xa9, 0xb5, 255}, {0xa0, 0xcb, 0xbb, 255}, {0xf2, 0xea, 0xdf, 255},
		},
	},
	// Ghostty's defaults with no user config (Ghostty v1.4.0, vendor/ghostty):
	// background #282C34 and foreground #FFFFFF (src/config/Config.zig,
	// `background`/`foreground`), cursor = foreground (`cursor-color` null),
	// palette 0–15 from src/terminal/color.zig `Name.default`, font
	// JetBrains Mono (src/font/embedded.zig), 13 pt on macOS (`font-size`).
	// Chrome colours are derived from those; status colours are palette entries.
	.Ghostty = {
		font_family    = "JetBrains Mono",
		bg_app         = {0x28, 0x2c, 0x34, 255},
		bg_sidebar     = {0x21, 0x25, 0x2b, 255},
		bg_panel       = {0x21, 0x25, 0x2b, 255},
		bg_elevated    = {0x31, 0x36, 0x40, 255},
		bg_field       = {0x1b, 0x1e, 0x23, 255},
		hover          = {255, 255, 255, 10},
		selected       = {255, 255, 255, 20},
		text           = {0xe6, 0xe6, 0xe6, 255},
		text_secondary = {0xab, 0xb2, 0xbf, 255},
		text_muted     = {0x7f, 0x84, 0x8e, 255},
		text_on_accent = {0x1d, 0x1f, 0x21, 255},
		border         = {0x34, 0x39, 0x42, 255},
		accent         = {0x7a, 0xa6, 0xda, 255}, // bright blue
		selection      = {0x7a, 0xa6, 0xda, 90},
		scrim          = {0, 0, 0, 110},
		shadow         = {0, 0, 0, 70},
		running        = {0x8a, 0xbe, 0xb7, 255}, // cyan
		waiting        = {0xf0, 0xc6, 0x74, 255}, // yellow
		done           = {0xb5, 0xbd, 0x68, 255}, // green
		error          = {0xcc, 0x66, 0x66, 255}, // red
		term_fg        = {0xff, 0xff, 0xff, 255},
		term_bg        = {0x28, 0x2c, 0x34, 255},
		term_cursor    = {0xff, 0xff, 0xff, 255},
		term_selection = {0x3e, 0x4f, 0x6b, 255}, // accent over term_bg
		ansi           = {
			{0x1d, 0x1f, 0x21, 255}, {0xcc, 0x66, 0x66, 255}, {0xb5, 0xbd, 0x68, 255}, {0xf0, 0xc6, 0x74, 255},
			{0x81, 0xa2, 0xbe, 255}, {0xb2, 0x94, 0xbb, 255}, {0x8a, 0xbe, 0xb7, 255}, {0xc5, 0xc8, 0xc6, 255},
			{0x66, 0x66, 0x66, 255}, {0xd5, 0x4e, 0x53, 255}, {0xb9, 0xca, 0x4a, 255}, {0xe7, 0xc5, 0x47, 255},
			{0x7a, 0xa6, 0xda, 255}, {0xc3, 0x97, 0xd8, 255}, {0x70, 0xc0, 0xb1, 255}, {0xea, 0xea, 0xea, 255},
		},
	},
}

// The light variant of each look (same font). Body text keeps at least
// 4.5:1 on every surface, muted text and the accent at least 3:1, status
// colours (also used as text) 4.5:1; theme_test.odin checks every look in
// both appearances. Terminal colours 1-6 reach 4.5:1 on the background,
// their bright variants 3:1; 7 and 15 are light greys (backgrounds).
THEMES_LIGHT := [Theme_Id]Theme {
	// Neutral light: zinc greys on near-white, a deeper blue accent (blue-600)
	// so the focus ring and "+" read on light surfaces.
	.Graphite = {
		font_family    = "Menlo",
		bg_app         = {0xfa, 0xfa, 0xfa, 255},
		bg_sidebar     = {0xf4, 0xf4, 0xf5, 255},
		bg_panel       = {0xf4, 0xf4, 0xf5, 255},
		bg_elevated    = {0xff, 0xff, 0xff, 255},
		bg_field       = {0xff, 0xff, 0xff, 255},
		hover          = {0, 0, 0, 10},
		selected       = {0, 0, 0, 20},
		text           = {0x18, 0x18, 0x1b, 255},
		text_secondary = {0x52, 0x52, 0x5b, 255},
		text_muted     = {0x71, 0x71, 0x7a, 255},
		text_on_accent = {0xff, 0xff, 0xff, 255},
		border         = {0xe4, 0xe4, 0xe7, 255},
		accent         = {0x25, 0x63, 0xeb, 255},
		selection      = {0x25, 0x63, 0xeb, 60},
		scrim          = {0, 0, 0, 60},
		shadow         = {0, 0, 0, 26},
		running        = {0x0e, 0x74, 0x90, 255},
		waiting        = {0xa3, 0x5a, 0x00, 255},
		done           = {0x15, 0x80, 0x3d, 255},
		error          = {0xc4, 0x2b, 0x2b, 255},
		term_fg        = {0x27, 0x27, 0x2a, 255},
		term_bg        = {0xfa, 0xfa, 0xfa, 255},
		term_cursor    = {0x18, 0x18, 0x1b, 255},
		term_selection = {0xd6, 0xe2, 0xfb, 255},
		ansi           = {
			{0x27, 0x27, 0x2a, 255}, {0xc4, 0x2b, 0x2b, 255}, {0x2d, 0x7a, 0x2f, 255}, {0x8f, 0x64, 0x00, 255},
			{0x25, 0x63, 0xeb, 255}, {0x90, 0x35, 0xc0, 255}, {0x0e, 0x74, 0x90, 255}, {0xd4, 0xd4, 0xd8, 255},
			{0x71, 0x71, 0x7a, 255}, {0xdc, 0x3c, 0x3c, 255}, {0x3a, 0x8f, 0x3d, 255}, {0xa8, 0x77, 0x00, 255},
			{0x3b, 0x7c, 0xf0, 255}, {0xa2, 0x4f, 0xd6, 255}, {0x0b, 0x8a, 0xa8, 255}, {0xf4, 0xf4, 0xf5, 255},
		},
	},
	// Warm light: cream paper, brown-grey ink, terracotta darkened for light.
	.Warm = {
		font_family    = "Menlo",
		bg_app         = {0xfb, 0xf8, 0xf3, 255},
		bg_sidebar     = {0xf3, 0xed, 0xe4, 255},
		bg_panel       = {0xf3, 0xed, 0xe4, 255},
		bg_elevated    = {0xff, 0xfd, 0xf9, 255},
		bg_field       = {0xff, 0xfd, 0xf9, 255},
		hover          = {60, 30, 0, 12},
		selected       = {60, 30, 0, 22},
		text           = {0x2a, 0x22, 0x1b, 255},
		text_secondary = {0x5e, 0x53, 0x48, 255},
		text_muted     = {0x85, 0x78, 0x69, 255},
		text_on_accent = {0xff, 0xff, 0xff, 255},
		border         = {0xe3, 0xd9, 0xcb, 255},
		accent         = {0xa9, 0x4c, 0x27, 255},
		selection      = {0xa9, 0x4c, 0x27, 60},
		scrim          = {0, 0, 0, 60},
		shadow         = {0, 0, 0, 26},
		running        = {0x2f, 0x6a, 0x85, 255},
		waiting        = {0x95, 0x60, 0x00, 255},
		done           = {0x4c, 0x75, 0x20, 255},
		error          = {0xb3, 0x37, 0x2a, 255},
		term_fg        = {0x3a, 0x30, 0x28, 255},
		term_bg        = {0xfb, 0xf8, 0xf3, 255},
		term_cursor    = {0x2a, 0x22, 0x1b, 255},
		term_selection = {0xf0, 0xd8, 0xc8, 255},
		ansi           = {
			{0x3a, 0x30, 0x28, 255}, {0xb3, 0x37, 0x2a, 255}, {0x4c, 0x75, 0x20, 255}, {0x8a, 0x5f, 0x00, 255},
			{0x2f, 0x6a, 0x85, 255}, {0x94, 0x49, 0x6a, 255}, {0x2d, 0x75, 0x65, 255}, {0xdd, 0xd3, 0xc6, 255},
			{0x85, 0x78, 0x69, 255}, {0xc8, 0x50, 0x3f, 255}, {0x5d, 0x8a, 0x2c, 255}, {0xa3, 0x72, 0x00, 255},
			{0x3f, 0x7f, 0xa0, 255}, {0xab, 0x5d, 0x80, 255}, {0x3a, 0x8b, 0x78, 255}, {0xf3, 0xed, 0xe4, 255},
		},
	},
	// Ghostty has no built-in light defaults (its light/dark switching needs
	// `theme = light:X,dark:Y` with external themes; src/config/Config.zig).
	// Its default palette is Tomorrow Night (Chris Kempson's Tomorrow theme,
	// github.com/chriskempson/tomorrow-theme), so the light variant is
	// Tomorrow: background #FFFFFF, foreground #4D4D4C, selection #D6D6D6,
	// red #C82829, blue #4271AE, purple #8959A8, comment #8E908C. Tomorrow's
	// green #718C00, yellow #EAB700 and aqua #3E999F are too light for text on
	// white (3.9, 1.9, 3.4:1): ANSI 2/3/6 are darker shades of them, the
	// originals (yellow: Solarized's #B58900) are the bright variants.
	.Ghostty = {
		font_family    = "JetBrains Mono",
		bg_app         = {0xff, 0xff, 0xff, 255},
		bg_sidebar     = {0xf4, 0xf5, 0xf7, 255},
		bg_panel       = {0xf4, 0xf5, 0xf7, 255},
		bg_elevated    = {0xff, 0xff, 0xff, 255},
		bg_field       = {0xff, 0xff, 0xff, 255},
		hover          = {0, 0, 0, 10},
		selected       = {0, 0, 0, 20},
		text           = {0x1d, 0x1f, 0x21, 255},
		text_secondary = {0x4d, 0x4d, 0x4c, 255},
		text_muted     = {0x76, 0x78, 0x76, 255},
		text_on_accent = {0xff, 0xff, 0xff, 255},
		border         = {0xe3, 0xe5, 0xe8, 255},
		accent         = {0x42, 0x71, 0xae, 255},
		selection      = {0x42, 0x71, 0xae, 60},
		scrim          = {0, 0, 0, 60},
		shadow         = {0, 0, 0, 26},
		running        = {0x28, 0x72, 0x7a, 255},
		waiting        = {0x8c, 0x60, 0x00, 255},
		done           = {0x5a, 0x70, 0x00, 255},
		error          = {0xc8, 0x28, 0x29, 255},
		term_fg        = {0x4d, 0x4d, 0x4c, 255},
		term_bg        = {0xff, 0xff, 0xff, 255},
		term_cursor    = {0x4d, 0x4d, 0x4c, 255},
		term_selection = {0xd6, 0xd6, 0xd6, 255},
		ansi           = {
			{0x1d, 0x1f, 0x21, 255}, {0xc8, 0x28, 0x29, 255}, {0x5a, 0x70, 0x00, 255}, {0x8c, 0x60, 0x00, 255},
			{0x42, 0x71, 0xae, 255}, {0x89, 0x59, 0xa8, 255}, {0x28, 0x72, 0x7a, 255}, {0xd6, 0xd6, 0xd6, 255},
			{0x8e, 0x90, 0x8c, 255}, {0xd5, 0x4e, 0x53, 255}, {0x71, 0x8c, 0x00, 255}, {0xb5, 0x89, 0x00, 255},
			{0x5a, 0x8c, 0xcc, 255}, {0xa2, 0x74, 0xc0, 255}, {0x3e, 0x99, 0x9f, 255}, {0xef, 0xef, 0xef, 255},
		},
	},
}

// Light or dark, independent of the look: `system` follows the OS
// appearance (State.system_light, reported by the platform layer).
Appearance :: enum {
	System,
	Light,
	Dark,
}

APPEARANCE_NAMES := [Appearance]string {
	.System = "system",
	.Light  = "light",
	.Dark   = "dark",
}

// Whether the chrome and the terminals are light now.
theme_is_light :: proc() -> bool {
	switch state.settings.appearance {
	case .Light:  return true
	case .Dark:   return false
	case .System: return state.system_light
	}
	return false
}

// The active look in the active appearance.
theme :: proc() -> ^Theme {return theme_is_light() ? &THEMES_LIGHT[state.settings.theme] : &THEMES[state.settings.theme]}

// Fonts for a look: its terminal family first, then the default chain
// (JetBrains Mono, SF Mono, Menlo); UI text in the system font at the
// chosen text size.
theme_font_config :: proc(th: ^Theme) -> Font_Config {
	@(static) families: [8]string
	n := 0
	families[n] = th.font_family
	n += 1
	for f in DEFAULT_MONO_FAMILIES do if f != th.font_family && n < len(families) {
		families[n] = f
		n += 1
	}
	cfg := font_config
	cfg.mono_families = families[:n]
	cfg.mono_pt = term_text_pt()
	cfg.ui_family = DEFAULT_UI_FAMILY
	cfg.ui_pt = TYPE_UI_PX[state.settings.text_size][0]
	cfg.ui_small_pt = TYPE_UI_PX[state.settings.text_size][1]
	return cfg
}

// The full 256-colour palette of a look: its 16 colours, then the 6x6x6
// cube and the grey ramp. Dark variants: exactly as Ghostty builds its
// default (src/terminal/color.zig `default`). Light variants: derived from
// the look's own colours as Ghostty's `palette-generate` does
// (color.zig `generate256Color`, harmonious = false; after
// gist.github.com/jake-stewart/0a8ea46159a7da2c808e5be2177e1783): the cube
// still runs dark (16) to light (231) and the ramp dark (232) to light
// (255), but its corners are the look's foreground, background and colours
// 1-6, so a program's "pure green" (46) is the look's readable green, not
// #00FF00 on a white page.
theme_palette :: proc(th: ^Theme) -> (p: [256]gh.Color_Rgb) {
	for c, i in th.ansi do p[i] = {c.r, c.g, c.b}
	if lab_of(th.term_fg).l < lab_of(th.term_bg).l {
		// corners: dark end (the foreground), colours 1-6, light end
		base: [8]Lab = {lab_of(th.term_fg), {}, {}, {}, {}, {}, {}, lab_of(th.term_bg)}
		for k in 1 ..= 6 do base[k] = lab_of(th.ansi[k])
		i := 16
		for r in 0 ..< 6 do for g in 0 ..< 6 do for b in 0 ..< 6 {
			tr, tg, tb := f32(r) / 5, f32(g) / 5, f32(b) / 5
			c0, c1 := lab_lerp(tr, base[0], base[1]), lab_lerp(tr, base[2], base[3])
			c2, c3 := lab_lerp(tr, base[4], base[5]), lab_lerp(tr, base[6], base[7])
			p[i] = lab_to_rgb(lab_lerp(tb, lab_lerp(tg, c0, c1), lab_lerp(tg, c2, c3)))
			i += 1
		}
		for k in 0 ..< 24 do p[232 + k] = lab_to_rgb(lab_lerp(f32(k + 1) / 25, base[0], base[7]))
		return
	}
	i := 16
	for r in 0 ..< 6 do for g in 0 ..< 6 do for b in 0 ..< 6 {
		lv :: proc(v: int) -> u8 {return v == 0 ? 0 : u8(v * 40 + 55)}
		p[i] = {lv(r), lv(g), lv(b)}
		i += 1
	}
	for ; i < 256; i += 1 {
		v := u8((i - 232) * 10 + 8)
		p[i] = {v, v, v}
	}
	return
}

// CIELAB (D65), as Ghostty's color.zig LAB.
Lab :: struct {
	l, a, b: f32,
}

@(private = "file")
srgb_to_linear :: proc(v: u8) -> f32 {
	c := f32(v) / 255
	return c > 0.04045 ? math.pow((c + 0.055) / 1.055, 2.4) : c / 12.92
}

lab_of :: proc(c: Rgba) -> Lab {
	r, g, b := srgb_to_linear(c.r), srgb_to_linear(c.g), srgb_to_linear(c.b)
	f :: proc(t: f32) -> f32 {return t > 0.008856 ? math.cbrt(t) : 7.787 * t + 16.0 / 116.0}
	x := f((r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047)
	y := f(r * 0.2126729 + g * 0.7151522 + b * 0.0721750)
	z := f((r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883)
	return {116 * y - 16, 500 * (x - y), 200 * (y - z)}
}

lab_to_rgb :: proc(c: Lab) -> gh.Color_Rgb {
	y := (c.l + 16) / 116
	x := c.a / 500 + y
	z := y - c.b / 200
	inv :: proc(t: f32) -> f32 {return t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116.0) / 7.787}
	xf, yf, zf := inv(x) * 0.95047, inv(y), inv(z) * 1.08883
	out :: proc(v: f32) -> u8 {
		v := v > 0.0031308 ? 1.055 * math.pow(v, 1 / 2.4) - 0.055 : 12.92 * v
		return u8(clamp(v, 0, 1) * 255 + 0.5)
	}
	return {
		out(xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314),
		out(-xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560),
		out(xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252),
	}
}

lab_lerp :: proc(t: f32, a, b: Lab) -> Lab {return {a.l + t * (b.l - a.l), a.a + t * (b.a - a.a), a.b + t * (b.b - a.b)}}

// WCAG 2 contrast ratio of two opaque colours (1..21).
contrast_ratio :: proc(a, b: Rgba) -> f32 {
	lum :: proc(c: Rgba) -> f32 {return 0.2126 * srgb_to_linear(c.r) + 0.7152 * srgb_to_linear(c.g) + 0.0722 * srgb_to_linear(c.b)}
	la, lb := lum(a), lum(b)
	return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// ---- editor (src/editor*.odin) ----
// Kept in one block: the editor's sizes, and its colours per look. Chrome
// colours the editor shares with the rest (text, accent, selection, status)
// come from Theme above; only syntax and diff colours are its own.

EDITOR_LINE_PAD :: 2 // logical px added to the mono line height
EDITOR_GUTTER_PAD :: SP_3 // left of the line numbers and between them and the text
EDITOR_DIFF_W :: 3 // git change bar in the gutter
EDITOR_TAB_WIDTH :: 4 // columns per tab stop when showing tabs
EDITOR_BAR_H :: 36 // find / replace / go-to bar and the changed-on-disk banner
EDITOR_TOOLBAR_H :: 34 // the editor's own buttons (Save, Undo, Find…) above its text
EDITOR_FIELD_W :: 280 // find and replace fields
EDITOR_SCROLL_MARGIN :: 3 // lines kept visible above/below the cursor
EDITOR_UNDO_BURST :: 1000 * time.Millisecond // typing within this joins one undo step
EDITOR_DIFF_DELAY :: 250 * time.Millisecond // git gutter recomputed after typing pauses

// ---- Markdown tab (src/markdown_view.odin) ----
// Logical px unless noted. Colours come from Theme (text, accent, border,
// bg_elevated) and the editor's syntax colours for code blocks.
MD_MAX_W :: 860 // the text column's widest
MD_PAD_X :: 32 // either side of the column (narrower windows: SP_4)
MD_PAD_Y :: 24 // above the first block and below the last
MD_BODY_SCALE :: 1.08 // body text against the chrome's UI size
MD_LINE :: 1.45 // line box against the font's own line height
MD_GAP :: 12 // between blocks
MD_GAP_TIGHT :: 4 // between the items of a tight list
MD_HEADING_GAP :: 22 // above a heading (not the first block)
MD_HEADING_SCALE := [7]f32{1, 1.75, 1.4, 1.18, 1.05, 1, 0.92} // h1–h6 against body text
MD_INDENT :: 24 // a list's content
MD_QUOTE_INDENT :: 16 // a block quote's content
MD_QUOTE_BAR :: 3 // its bar
MD_CODE_PAD :: 12 // inside code blocks
MD_CODE_INLINE_PAD :: 3 // around code spans
MD_CELL_PAD :: 8 // inside table cells
MD_CHECK :: 13 // task item boxes
MD_SCROLL_LINE :: 40 // arrow keys and one wheel step

Syntax_Token :: enum u8 {
	Plain,
	Comment,
	Keyword,
	String,
	Escape,
	Number,
	Constant,
	Function,
	Type,
	Property,
	Attribute,
	Tag,
	Operator,
	Punctuation,
	Heading,
	Link,
}

Editor_Colors :: struct {
	syntax:        [Syntax_Token]Rgba, // Plain = the text colour
	line_number:   Rgba,
	current_line:  Rgba, // background of the cursor's line (alpha)
	find_match:    Rgba, // other matches (alpha)
	diff_added:    Rgba,
	diff_modified: Rgba,
	diff_removed:  Rgba,
}

EDITOR_COLORS := [Theme_Id]Editor_Colors {
	.Graphite = {
		syntax = {
			.Plain = {0xd4, 0xd4, 0xd8, 255}, .Comment = {0x6e, 0x6e, 0x78, 255}, .Keyword = {0xc2, 0x9b, 0xe0, 255},
			.String = {0x8f, 0xc4, 0x8a, 255}, .Escape = {0x6f, 0xc2, 0xc8, 255}, .Number = {0xe3, 0xa0, 0x6b, 255},
			.Constant = {0xe3, 0xa0, 0x6b, 255}, .Function = {0x7a, 0xa2, 0xf7, 255}, .Type = {0xe3, 0xc0, 0x7b, 255},
			.Property = {0x96, 0xb6, 0xf8, 255}, .Attribute = {0xe3, 0xc0, 0x7b, 255}, .Tag = {0xe5, 0x73, 0x7a, 255},
			.Operator = {0xa1, 0xa1, 0xaa, 255}, .Punctuation = {0x8a, 0x8a, 0x94, 255}, .Heading = {0x7a, 0xa2, 0xf7, 255},
			.Link = {0x6f, 0xc2, 0xc8, 255},
		},
		line_number = {0x5a, 0x5a, 0x63, 255}, current_line = {255, 255, 255, 8}, find_match = {0xe5, 0xb9, 0x5c, 60},
		diff_added = {0x7e, 0xc4, 0x88, 255}, diff_modified = {0x7a, 0xa2, 0xf7, 255}, diff_removed = {0xef, 0x6f, 0x6c, 255},
	},
	.Warm = {
		syntax = {
			.Plain = {0xe0, 0xd6, 0xc8, 255}, .Comment = {0x7d, 0x71, 0x65, 255}, .Keyword = {0xc6, 0x91, 0x9f, 255},
			.String = {0xa3, 0xb8, 0x6c, 255}, .Escape = {0x86, 0xb8, 0xa6, 255}, .Number = {0xe0, 0x89, 0x5f, 255},
			.Constant = {0xe0, 0x89, 0x5f, 255}, .Function = {0x7f, 0xa7, 0xc9, 255}, .Type = {0xe3, 0xb3, 0x41, 255},
			.Property = {0x9b, 0xbc, 0xd8, 255}, .Attribute = {0xe3, 0xb3, 0x41, 255}, .Tag = {0xd9, 0x70, 0x5f, 255},
			.Operator = {0xb5, 0xa8, 0x98, 255}, .Punctuation = {0x96, 0x8a, 0x7c, 255}, .Heading = {0xe0, 0x89, 0x5f, 255},
			.Link = {0x86, 0xb8, 0xa6, 255},
		},
		line_number = {0x6b, 0x60, 0x56, 255}, current_line = {255, 240, 220, 8}, find_match = {0xe8, 0xc2, 0x5a, 60},
		diff_added = {0xa6, 0xbe, 0x6e, 255}, diff_modified = {0x7f, 0xb0, 0xc8, 255}, diff_removed = {0xe0, 0x67, 0x5a, 255},
	},
	.Ghostty = {
		syntax = {
			.Plain = {0xff, 0xff, 0xff, 255}, .Comment = {0x7f, 0x84, 0x8e, 255}, .Keyword = {0xb2, 0x94, 0xbb, 255},
			.String = {0xb5, 0xbd, 0x68, 255}, .Escape = {0x8a, 0xbe, 0xb7, 255}, .Number = {0xde, 0x93, 0x5f, 255},
			.Constant = {0xde, 0x93, 0x5f, 255}, .Function = {0x81, 0xa2, 0xbe, 255}, .Type = {0xf0, 0xc6, 0x74, 255},
			.Property = {0x7a, 0xa6, 0xda, 255}, .Attribute = {0xf0, 0xc6, 0x74, 255}, .Tag = {0xcc, 0x66, 0x66, 255},
			.Operator = {0xc5, 0xc8, 0xc6, 255}, .Punctuation = {0xab, 0xb2, 0xbf, 255}, .Heading = {0x81, 0xa2, 0xbe, 255},
			.Link = {0x8a, 0xbe, 0xb7, 255},
		},
		line_number = {0x66, 0x6b, 0x75, 255}, current_line = {255, 255, 255, 8}, find_match = {0xf0, 0xc6, 0x74, 60},
		diff_added = {0xb5, 0xbd, 0x68, 255}, diff_modified = {0x81, 0xa2, 0xbe, 255}, diff_removed = {0xcc, 0x66, 0x66, 255},
	},
}

// The light variant of each look's editor colours (contrast at least 4.5:1
// against the light background for code, like the light terminal palettes).
EDITOR_COLORS_LIGHT := [Theme_Id]Editor_Colors {
	.Graphite = {
		syntax = {
			.Plain = {0x27, 0x27, 0x2a, 255}, .Comment = {0x6e, 0x6e, 0x78, 255}, .Keyword = {0x7c, 0x3a, 0xb5, 255},
			.String = {0x2f, 0x7a, 0x2c, 255}, .Escape = {0x0e, 0x74, 0x7c, 255}, .Number = {0xb4, 0x53, 0x09, 255},
			.Constant = {0xb4, 0x53, 0x09, 255}, .Function = {0x25, 0x63, 0xeb, 255}, .Type = {0x92, 0x5d, 0x00, 255},
			.Property = {0x1d, 0x4e, 0xd8, 255}, .Attribute = {0x92, 0x5d, 0x00, 255}, .Tag = {0xb9, 0x1c, 0x1c, 255},
			.Operator = {0x52, 0x52, 0x5b, 255}, .Punctuation = {0x60, 0x60, 0x6a, 255}, .Heading = {0x25, 0x63, 0xeb, 255},
			.Link = {0x0e, 0x74, 0x7c, 255},
		},
		line_number = {0xa1, 0xa1, 0xaa, 255}, current_line = {0, 0, 0, 10}, find_match = {0xe5, 0xa0, 0x1c, 70},
		diff_added = {0x2f, 0x9e, 0x44, 255}, diff_modified = {0x25, 0x63, 0xeb, 255}, diff_removed = {0xdc, 0x26, 0x26, 255},
	},
	.Warm = {
		syntax = {
			.Plain = {0x3b, 0x32, 0x2a, 255}, .Comment = {0x85, 0x78, 0x6a, 255}, .Keyword = {0x8e, 0x3b, 0x5c, 255},
			.String = {0x4f, 0x6b, 0x1f, 255}, .Escape = {0x2f, 0x6e, 0x5c, 255}, .Number = {0xa8, 0x4a, 0x22, 255},
			.Constant = {0xa8, 0x4a, 0x22, 255}, .Function = {0x2e, 0x5e, 0x8a, 255}, .Type = {0x8a, 0x5a, 0x00, 255},
			.Property = {0x2e, 0x5e, 0x8a, 255}, .Attribute = {0x8a, 0x5a, 0x00, 255}, .Tag = {0xa8, 0x3a, 0x2c, 255},
			.Operator = {0x5c, 0x50, 0x45, 255}, .Punctuation = {0x6b, 0x5e, 0x52, 255}, .Heading = {0xa8, 0x4a, 0x22, 255},
			.Link = {0x2f, 0x6e, 0x5c, 255},
		},
		line_number = {0xa8, 0x9c, 0x8e, 255}, current_line = {60, 40, 20, 10}, find_match = {0xd9, 0x9a, 0x1e, 70},
		diff_added = {0x5a, 0x8a, 0x2a, 255}, diff_modified = {0x3a, 0x74, 0xa8, 255}, diff_removed = {0xc0, 0x45, 0x38, 255},
	},
	.Ghostty = {
		syntax = {
			.Plain = {0x4d, 0x4d, 0x4c, 255}, .Comment = {0x8e, 0x90, 0x8c, 255}, .Keyword = {0x89, 0x59, 0xa8, 255},
			.String = {0x5b, 0x72, 0x00, 255}, .Escape = {0x2c, 0x75, 0x7a, 255}, .Number = {0xb8, 0x5c, 0x00, 255},
			.Constant = {0xb8, 0x5c, 0x00, 255}, .Function = {0x42, 0x71, 0xae, 255}, .Type = {0x8a, 0x6a, 0x00, 255},
			.Property = {0x42, 0x71, 0xae, 255}, .Attribute = {0x8a, 0x6a, 0x00, 255}, .Tag = {0xc8, 0x28, 0x29, 255},
			.Operator = {0x5c, 0x5c, 0x5b, 255}, .Punctuation = {0x6a, 0x6a, 0x69, 255}, .Heading = {0x42, 0x71, 0xae, 255},
			.Link = {0x2c, 0x75, 0x7a, 255},
		},
		line_number = {0xa0, 0xa1, 0x9f, 255}, current_line = {0, 0, 0, 10}, find_match = {0xea, 0xb7, 0x00, 70},
		diff_added = {0x5b, 0x8a, 0x00, 255}, diff_modified = {0x42, 0x71, 0xae, 255}, diff_removed = {0xc8, 0x28, 0x29, 255},
	},
}

editor_colors :: proc() -> ^Editor_Colors {
	return theme_is_light() ? &EDITOR_COLORS_LIGHT[state.settings.theme] : &EDITOR_COLORS[state.settings.theme]
}
