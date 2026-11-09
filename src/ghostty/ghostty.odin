// Hand-written Odin bindings for the subset of libghostty-vt (Ghostty v1.4.0,
// include/ghostty/vt/*.h) that Deckhand uses. The C ABI is not stable yet:
// when bumping the Ghostty tag, re-check every struct here against the
// headers. `./build.sh test` compares struct sizes with the C compiler's.
package ghostty

import "core:c"

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib "../../vendor/libghostty-vt/aarch64-macos/lib/libghostty-vt.a"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import lib "../../vendor/libghostty-vt/x86_64-macos/lib/libghostty-vt.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib "../../vendor/libghostty-vt/x86_64-linux-gnu/lib/libghostty-vt.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import lib "../../vendor/libghostty-vt/aarch64-linux-gnu/lib/libghostty-vt.a"
} else when ODIN_OS == .Windows {
	foreign import lib "../../vendor/libghostty-vt/x86_64-windows-gnu/lib/ghostty-vt-static.lib"
}

// ---- common (types.h, allocator.h) ----

Result :: enum c.int {
	Success        = 0,
	Out_Of_Memory  = -1,
	Invalid_Value  = -2,
	Out_Of_Space   = -3,
	No_Value       = -4,
	IO_Error       = -5,
	Limit_Exceeded = -6,
	Rejected       = -7,
}

Terminal :: distinct rawptr
Render_State :: distinct rawptr
Tracked_Grid_Ref :: distinct rawptr // follows its cell through scrolling and scrollback trims
Row_Iterator :: distinct rawptr
Row_Cells :: distinct rawptr
Key_Encoder :: distinct rawptr
Key_Event :: distinct rawptr
Mouse_Encoder :: distinct rawptr
Mouse_Event :: distinct rawptr
Formatter :: distinct rawptr
Snapshot_Decoder :: distinct rawptr
Allocator :: struct {} // only ever passed as nil (default allocator)

// ---- io.h ----

// Called synchronously; data is borrowed for the call. Return false to fail the operation.
Writer_Fn :: #type proc "c" (userdata: rawptr, data: [^]u8, len: c.size_t) -> bool
Writer :: struct {
	write:    Writer_Fn,
	userdata: rawptr,
}
// Fill buf (up to cap) and set out_len; a successful zero-byte read is end of file.
Reader_Fn :: #type proc "c" (userdata: rawptr, buf: [^]u8, cap: c.size_t, out_len: ^c.size_t) -> bool
Reader :: struct {
	read:     Reader_Fn,
	userdata: rawptr,
}

Formatter_Format :: enum c.int {
	Plain = 0,
	VT    = 1,
	HTML  = 2,
}

Buffer :: struct {
	ptr: [^]u8,
	cap: c.size_t,
	len: c.size_t,
}

// ---- color.h, style.h ----

Color_Rgb :: struct {
	r, g, b: u8,
}

Style_Color_Tag :: enum c.int {
	None    = 0,
	Palette = 1,
	Rgb     = 2,
}

Style_Color :: struct {
	tag:   Style_Color_Tag,
	value: struct #raw_union {
		palette:  u8,
		rgb:      Color_Rgb,
		_padding: u64,
	},
}

Style :: struct {
	size:            c.size_t,
	fg_color:        Style_Color,
	bg_color:        Style_Color,
	underline_color: Style_Color,
	bold:            bool,
	italic:          bool,
	faint:           bool,
	blink:           bool,
	inverse:         bool,
	invisible:       bool,
	strikethrough:   bool,
	overline:        bool,
	underline:       c.int,
}

// ---- point.h, grid_ref.h, selection.h ----

Point_Tag :: enum c.int {
	Active   = 0,
	Viewport = 1,
	Screen   = 2,
	History  = 3,
}

Point_Coordinate :: struct {
	x: u16,
	y: u32,
}

Point :: struct {
	tag:   Point_Tag,
	value: struct #raw_union {
		coordinate: Point_Coordinate,
		_padding:   [2]u64,
	},
}

Grid_Ref :: struct {
	size: c.size_t,
	node: rawptr,
	x:    u16,
	y:    u16,
}

Selection :: struct {
	size:      c.size_t,
	start:     Grid_Ref,
	end:       Grid_Ref,
	rectangle: bool,
}

Selection_Format_Options :: struct {
	size:      c.size_t,
	emit:      Formatter_Format,
	unwrap:    bool,
	trim:      bool,
	selection: ^Selection,
}

// ---- screen.h (cells) ----

Cell :: u64

Cell_Data :: enum c.int {
	Invalid          = 0,
	Codepoint        = 1,
	Wide             = 3,
	Has_Text         = 4, // bool
	Style_Id         = 6, // u16
	Has_Hyperlink    = 7, // bool: an OSC 8 hyperlink (its URI: grid_ref_hyperlink_uri)
	Protected        = 8, // bool: DECSCA
	Semantic_Content = 9, // Cell_Semantic_Content (OSC 133)
}

Cell_Semantic_Content :: enum c.int {
	Output = 0,
	Input  = 1,
	Prompt = 2,
}

// A row of the grid (ghostty_grid_ref_row), opaque: read with row_get.
Grid_Row :: u64

Grid_Row_Data :: enum c.int {
	Wrap              = 1, // bool: the row soft-wraps into the next
	Wrap_Continuation = 2, // bool: the row continues the one above
	Hyperlink         = 5, // bool: some cell has a hyperlink (may be a false positive)
	Semantic_Prompt   = 6, // c.int (GhosttyRowSemanticPrompt): OSC 133 marks
}

Cell_Wide :: enum c.int {
	Narrow      = 0,
	Wide        = 1,
	Spacer_Tail = 2,
	Spacer_Head = 3,
}

// ---- terminal.h ----

Terminal_Option :: enum c.int {
	Userdata             = 0,
	Write_Pty            = 1,
	Title_Changed        = 5,
	Color_Scheme         = 7, // Color_Scheme_Fn: answers CSI ? 996 n
	Color_Foreground     = 11, // ^Color_Rgb, nil clears
	Color_Background     = 12,
	Color_Cursor         = 13,
	Color_Palette        = 14, // ^[256]Color_Rgb, nil resets to the built-in palette
	Selection            = 21,
	Scrollback_Max_Bytes = 27,
	Scrollback_Max_Lines = 28,
	// ^c.size_t: the unfinished escape or UTF-8 suffix kept for snapshots; 0 disables.
	// Must be set before the input it covers (snapshot.odin, term.odin)
	Continuation_Max_Bytes = 31,
	Kitty_Image_Storage_Limit = 15, // ^u64: 0 disables Kitty graphics and deletes every image
	Mode                 = 34, // Mode_Config*
	Semantic_Prompt      = 42, // Semantic_Prompt_Fn: OSC 133 steps (a new prompt clears program status)
	Program_Status       = 46, // Program_Status_Fn: OSC 7501 reports; while set, `OSC 7501 ; ?` is answered through Write_Pty
}

Terminal_Data :: enum c.int {
	Cols            = 1,
	Rows            = 2,
	Cursor_X        = 3, // u16, active area
	Cursor_Y        = 4, // u16
	Cursor_Pending_Wrap = 5, // bool
	Active_Screen   = 6,
	Cursor_Visible  = 7, // bool
	Cursor_Style    = 10, // Style: the pen for newly printed characters
	Pwd             = 13, // String, borrowed until the next mutating call
	Total_Rows      = 14, // c.size_t: scrollback plus the active area
	Scrollback_Rows = 15, // c.size_t
	Width_Px        = 16, // u32: cols * the cell width given to terminal_resize
	Height_Px       = 17, // u32
	Color_Foreground = 18, // Color_Rgb; No_Value when unset
	Color_Background = 19,
	Color_Cursor     = 20,
	Color_Palette    = 21, // [256]Color_Rgb
	Scrollback_Max_Bytes   = 34, // c.size_t
	Continuation_Max_Bytes = 36, // c.size_t; 0 = tracking off
	Vt_Ground              = 38, // bool: the parser is between sequences
	Kitty_Keyboard_Flags = 8, // u8
	Mouse_Tracking  = 11,
	Title           = 12,
	Scrollbar       = 9,
	Selection       = 31,
	Viewport_Active = 32,
	Mode            = 37,
	Color_Foreground_Default = 22,
	Color_Background_Default = 23,
	Color_Cursor_Default     = 24,
	Color_Palette_Default    = 25,
}

Terminal_Screen :: enum c.int {
	Primary   = 0,
	Alternate = 1,
}

Scroll_Viewport_Tag :: enum c.int {
	Top    = 0,
	Bottom = 1,
	Delta  = 2,
	Row    = 3,
}

Scroll_Viewport :: struct {
	tag:   Scroll_Viewport_Tag,
	value: struct #raw_union {
		delta:    int,
		row:      uint,
		_padding: [2]u64,
	},
}

Scrollbar :: struct {
	total:  u64,
	offset: u64,
	len:    u64,
}

Mode :: u16 // bit 15 = ANSI mode, low 15 bits = mode number

mode_dec :: proc "contextless" (n: u16) -> Mode {return n & 0x7FFF}

Mode_Config :: struct {
	mode:  Mode,
	value: bool,
}

String :: struct {
	ptr: [^]u8,
	len: c.size_t,
}

Write_Pty_Fn :: #type proc "c" (t: Terminal, userdata: rawptr, data: [^]u8, len: c.size_t)
Title_Changed_Fn :: #type proc "c" (t: Terminal, userdata: rawptr)
Color_Scheme_Fn :: #type proc "c" (t: Terminal, userdata: rawptr, out_scheme: ^Color_Scheme) -> bool

// OSC 7501, the program status protocol (terminal.h: GhosttyTerminalProgramStatus;
// https://www.superlogical.com/rex/docs/build/program-status). Only reports that
// pass the spec's checks reach the callback; msg and title arrive decoded with no
// control characters. Strings are valid during the call only.
Program_Status_State :: enum c.int {
	Idle    = 0,
	Working = 1,
	Done    = 2,
	Blocked = 3,
	Error   = 4,
	Clear   = 5, // not a state: remove the record `id` and those under it ("" = all)
}
Program_Status_Kind :: enum c.int {
	None       = 0,
	Permission = 1,
	Question   = 2,
	Auth       = 3,
}
Program_Status :: struct {
	size:     c.size_t,
	state:    Program_Status_State,
	kind:     Program_Status_Kind,
	progress: i8, // 0-100, -1 = none
	id:       String, // "" = the root record; "a/b" is a child of "a"
	app:      String, // a stable name ("claude-code"), not a label
	title:    String,
	message:  String,
}
Program_Status_Fn :: #type proc "c" (t: Terminal, userdata: rawptr, report: ^Program_Status)

// OSC 133 shell integration (terminal.h: GhosttyTerminalSemanticPrompt).
Semantic_Prompt_Kind :: enum c.int {
	Invalid      = 0,
	Prompt_Start = 1,
	Input_Start  = 2,
	Output_Start = 3,
	Command_End  = 4,
}
Semantic_Prompt_Prompt_Kind :: enum c.int {
	Primary      = 0,
	Right        = 1,
	Continuation = 2,
	Secondary    = 3,
}
Semantic_Prompt :: struct {
	size:          c.size_t,
	kind:          Semantic_Prompt_Kind,
	prompt_kind:   Semantic_Prompt_Prompt_Kind,
	has_exit_code: bool,
	exit_code:     i32,
	command:       String,
	error:         String,
}
Semantic_Prompt_Fn :: #type proc "c" (t: Terminal, userdata: rawptr, event: ^Semantic_Prompt)

// device.h: the light/dark report of mode 2031 and CSI ? 996 n
Color_Scheme :: enum c.int {
	Light = 0,
	Dark  = 1,
}

// ---- formatter.h ----

Formatter_Screen_Extra :: struct {
	size:           c.size_t,
	cursor:         bool,
	style:          bool,
	hyperlink:      bool,
	protection:     bool,
	kitty_keyboard: bool,
	charsets:       bool,
}

Formatter_Terminal_Extra :: struct {
	size:             c.size_t,
	palette:          bool,
	modes:            bool,
	scrolling_region: bool,
	tabstops:         bool,
	pwd:              bool,
	keyboard:         bool,
	screen:           Formatter_Screen_Extra,
}

Formatter_Terminal_Options :: struct {
	size:      c.size_t,
	emit:      Formatter_Format,
	unwrap:    bool,
	trim:      bool,
	extra:     Formatter_Terminal_Extra,
	selection: ^Selection, // nil: the whole active screen and its scrollback
}

// ---- snapshot.h (GHOSTSNP) ----

Snapshot_Decoder_Option :: enum c.int {
	Max_Continuation_Bytes     = 0, // ^c.size_t
	Retain_Continuation        = 1, // ^bool: keep tracking on the decoded terminal
	Compress_History           = 2, // ^bool
	Kitty_Image_Storage_Limit  = 3, // ^u64
}

Snapshot_Decoder_Data :: enum c.int {
	Invalid                = 0,
	Max_Continuation_Bytes = 1,
	Source_Offset          = 2, // c.size_t: bytes consumed
	History_Rows_Primary   = 3, // u64
	History_Rows_Alternate = 4,
}

// ---- render.h ----

Render_Dirty :: enum c.int {
	False   = 0,
	Partial = 1,
	Full    = 2,
}

Render_Data :: enum c.int {
	Cols         = 1,
	Rows         = 2,
	Dirty        = 3,
	Row_Iterator = 4,
	Cursor       = 18,
	Colors       = 19,
}

Render_Option :: enum c.int {
	Dirty = 0,
}

Row_Data :: enum c.int {
	Dirty     = 1,
	Cells     = 3,
	Selection = 4,
}

Row_Option :: enum c.int {
	Dirty = 0,
}

Cells_Data :: enum c.int {
	Raw           = 1,
	Style         = 2,
	Graphemes_Len = 3,
	Graphemes_Buf = 4,
	Bg_Color      = 5,
	Fg_Color      = 6,
	Selected      = 7,
}

Cursor_Visual_Style :: enum c.int {
	Bar          = 0,
	Block        = 1,
	Underline    = 2,
	Block_Hollow = 3,
}

Render_Cursor :: struct {
	size:               c.size_t,
	viewport_has_value: bool,
	viewport_x:         u16,
	viewport_y:         u16,
	wide_tail:          bool,
	visible:            bool,
	blinking:           bool,
	password_input:     bool,
	visual_style:       Cursor_Visual_Style,
}

Render_Colors :: struct {
	size:             c.size_t,
	background:       Color_Rgb,
	foreground:       Color_Rgb,
	cursor:           Color_Rgb,
	cursor_has_value: bool,
	palette:          [256]Color_Rgb,
}

Row_Selection :: struct {
	size:    c.size_t,
	start_x: u16,
	end_x:   u16,
}

// ---- key/event.h, key/encoder.h ----

Key_Action :: enum c.int {
	Release = 0,
	Press   = 1,
	Repeat  = 2,
}

Mods :: u16
MOD_SHIFT :: Mods(1 << 0)
MOD_CTRL :: Mods(1 << 1)
MOD_ALT :: Mods(1 << 2)
MOD_SUPER :: Mods(1 << 3)

// Order must match GhosttyKey in key/event.h exactly (implicit C values).
Key :: enum c.int {
	Unidentified = 0,
	Backquote, Backslash, Bracket_Left, Bracket_Right, Comma,
	Digit_0, Digit_1, Digit_2, Digit_3, Digit_4, Digit_5, Digit_6, Digit_7, Digit_8, Digit_9,
	Equal, Intl_Backslash, Intl_Ro, Intl_Yen,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Minus, Period, Quote, Semicolon, Slash,
	Alt_Left, Alt_Right, Backspace, Caps_Lock, Context_Menu, Control_Left, Control_Right,
	Enter, Meta_Left, Meta_Right, Shift_Left, Shift_Right, Space, Tab,
	Convert, Kana_Mode, Non_Convert,
	Delete, End, Help, Home, Insert, Page_Down, Page_Up,
	Arrow_Down, Arrow_Left, Arrow_Right, Arrow_Up,
	Num_Lock, Numpad_0, Numpad_1, Numpad_2, Numpad_3, Numpad_4, Numpad_5, Numpad_6, Numpad_7, Numpad_8, Numpad_9,
	Numpad_Add, Numpad_Backspace, Numpad_Clear, Numpad_Clear_Entry, Numpad_Comma, Numpad_Decimal,
	Numpad_Divide, Numpad_Enter, Numpad_Equal, Numpad_Memory_Add, Numpad_Memory_Clear,
	Numpad_Memory_Recall, Numpad_Memory_Store, Numpad_Memory_Subtract, Numpad_Multiply,
	Numpad_Paren_Left, Numpad_Paren_Right, Numpad_Subtract, Numpad_Separator,
	Numpad_Up, Numpad_Down, Numpad_Right, Numpad_Left, Numpad_Begin, Numpad_Home, Numpad_End,
	Numpad_Insert, Numpad_Delete, Numpad_Page_Up, Numpad_Page_Down,
	Escape,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15, F16, F17, F18, F19, F20,
	F21, F22, F23, F24, F25,
}

Key_Encoder_Option :: enum c.int {
	Cursor_Key_Application = 0,
	Alt_Esc_Prefix         = 3,
	Kitty_Flags            = 5,
	Macos_Option_As_Alt    = 6,
}

Option_As_Alt :: enum c.int {
	False = 0,
	True  = 1,
	Left  = 2,
	Right = 3,
}

// ---- mouse/event.h, mouse/encoder.h ----

Mouse_Action :: enum c.int {
	Press   = 0,
	Release = 1,
	Motion  = 2,
}

Mouse_Button :: enum c.int {
	Unknown = 0,
	Left    = 1,
	Right   = 2,
	Middle  = 3,
	Four    = 4, // wheel up
	Five    = 5, // wheel down
	Six     = 6,
	Seven   = 7,
}

Mouse_Position :: struct {
	x, y: f32,
}

Mouse_Tracking :: enum c.int {
	None   = 0,
	X10    = 1,
	Normal = 2,
	Button = 3,
	Any    = 4,
}

Mouse_Encoder_Size :: struct {
	size:           c.size_t,
	screen_width:   u32,
	screen_height:  u32,
	cell_width:     u32,
	cell_height:    u32,
	padding_top:    u32,
	padding_bottom: u32,
	padding_right:  u32,
	padding_left:   u32,
}

Mouse_Encoder_Option :: enum c.int {
	Event              = 0,
	Format             = 1,
	Size               = 2,
	Any_Button_Pressed = 3,
	Track_Last_Cell    = 4,
}

// ---- focus.h ----

Focus_Event :: enum c.int {
	Gained = 0,
	Lost   = 1,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	free :: proc(allocator: ^Allocator, ptr: [^]u8, len: c.size_t) ---

	terminal_new :: proc(allocator: ^Allocator, terminal: ^Terminal, cols, rows: u16) -> Result ---
	terminal_free :: proc(terminal: Terminal) ---
	terminal_resize :: proc(terminal: Terminal, cols, rows: u16, cell_width_px, cell_height_px: u32) -> Result ---
	terminal_set :: proc(terminal: Terminal, option: Terminal_Option, value: rawptr) -> Result ---
	terminal_get :: proc(terminal: Terminal, data: Terminal_Data, out: rawptr) -> Result ---
	terminal_vt_write :: proc(terminal: Terminal, data: [^]u8, len: c.size_t) ---
	terminal_scroll_viewport :: proc(terminal: Terminal, behavior: Scroll_Viewport) ---
	terminal_grid_ref :: proc(terminal: Terminal, point: Point, out_ref: ^Grid_Ref) -> Result ---
	terminal_point_from_grid_ref :: proc(terminal: Terminal, ref: ^Grid_Ref, tag: Point_Tag, out: ^Point_Coordinate) -> Result ---
	terminal_grid_ref_track :: proc(terminal: Terminal, point: Point, out_ref: ^Tracked_Grid_Ref) -> Result ---
	tracked_grid_ref_free :: proc(ref: Tracked_Grid_Ref) ---
	tracked_grid_ref_point :: proc(ref: Tracked_Grid_Ref, tag: Point_Tag, out: ^Point_Coordinate) -> Result ---
	terminal_selection_format_alloc :: proc(terminal: Terminal, allocator: ^Allocator, options: Selection_Format_Options, out_ptr: ^[^]u8, out_len: ^c.size_t) -> Result ---
	// the exact unfinished-sequence suffix (tracking must be on: Continuation_Max_Bytes)
	terminal_continuation_alloc :: proc(terminal: Terminal, allocator: ^Allocator, out_ptr: ^[^]u8, out_len: ^c.size_t) -> Result ---

	formatter_terminal_new :: proc(allocator: ^Allocator, formatter: ^Formatter, terminal: Terminal, options: Formatter_Terminal_Options) -> Result ---
	formatter_format_alloc :: proc(formatter: Formatter, allocator: ^Allocator, out_ptr: ^[^]u8, out_len: ^c.size_t) -> Result ---
	formatter_free :: proc(formatter: Formatter) ---

	// GHOSTSNP: Invalid_Value when the parser is mid-sequence and the suffix isn't available
	snapshot_encode :: proc(terminal: Terminal, writer: Writer) -> Result ---
	snapshot_encode_alloc :: proc(terminal: Terminal, allocator: ^Allocator, out_ptr: ^[^]u8, out_len: ^c.size_t) -> Result ---
	snapshot_decoder_new :: proc(allocator: ^Allocator, decoder: ^Snapshot_Decoder, reader: Reader) -> Result ---
	snapshot_decoder_new_buf :: proc(allocator: ^Allocator, decoder: ^Snapshot_Decoder, ptr: [^]u8, len: c.size_t) -> Result ---
	snapshot_decoder_set :: proc(decoder: Snapshot_Decoder, option: Snapshot_Decoder_Option, value: rawptr) -> Result ---
	snapshot_decoder_ready :: proc(decoder: Snapshot_Decoder, terminal: ^Terminal) -> Result ---
	snapshot_decoder_next :: proc(decoder: Snapshot_Decoder) -> Result --- // No_Value at FINISH
	snapshot_decoder_decode :: proc(decoder: Snapshot_Decoder, terminal: ^Terminal) -> Result ---
	snapshot_decoder_get :: proc(decoder: Snapshot_Decoder, data: Snapshot_Decoder_Data, out: rawptr) -> Result ---
	snapshot_decoder_free :: proc(decoder: Snapshot_Decoder) ---

	render_state_new :: proc(allocator: ^Allocator, state: ^Render_State) -> Result ---
	render_state_free :: proc(state: Render_State) ---
	render_state_update :: proc(state: Render_State, terminal: Terminal) -> Result ---
	render_state_get :: proc(state: Render_State, data: Render_Data, out: rawptr) -> Result ---
	render_state_set :: proc(state: Render_State, option: Render_Option, value: rawptr) -> Result ---
	render_state_row_iterator_new :: proc(allocator: ^Allocator, out: ^Row_Iterator) -> Result ---
	render_state_row_iterator_free :: proc(it: Row_Iterator) ---
	render_state_row_iterator_next :: proc(it: Row_Iterator) -> bool ---
	render_state_row_get :: proc(it: Row_Iterator, data: Row_Data, out: rawptr) -> Result ---
	render_state_row_set :: proc(it: Row_Iterator, option: Row_Option, value: rawptr) -> Result ---
	render_state_row_cells_new :: proc(allocator: ^Allocator, out: ^Row_Cells) -> Result ---
	render_state_row_cells_free :: proc(cells: Row_Cells) ---
	render_state_row_cells_next :: proc(cells: Row_Cells) -> bool ---
	render_state_row_cells_get :: proc(cells: Row_Cells, data: Cells_Data, out: rawptr) -> Result ---

	cell_get :: proc(cell: Cell, data: Cell_Data, out: rawptr) -> Result ---
	row_get :: proc(row: Grid_Row, data: Grid_Row_Data, out: rawptr) -> Result ---
	// grid_ref.h: an untracked ref is valid until the terminal next changes
	grid_ref_cell :: proc(ref: ^Grid_Ref, out_cell: ^Cell) -> Result ---
	grid_ref_row :: proc(ref: ^Grid_Ref, out_row: ^Grid_Row) -> Result ---
	grid_ref_graphemes :: proc(ref: ^Grid_Ref, buf: [^]u32, buf_len: c.size_t, out_len: ^c.size_t) -> Result ---
	grid_ref_hyperlink_uri :: proc(ref: ^Grid_Ref, buf: [^]u8, buf_len: c.size_t, out_len: ^c.size_t) -> Result ---
	grid_ref_style :: proc(ref: ^Grid_Ref, out: ^Style) -> Result ---

	key_encoder_new :: proc(allocator: ^Allocator, encoder: ^Key_Encoder) -> Result ---
	key_encoder_free :: proc(encoder: Key_Encoder) ---
	key_encoder_setopt :: proc(encoder: Key_Encoder, option: Key_Encoder_Option, value: rawptr) ---
	key_encoder_setopt_from_terminal :: proc(encoder: Key_Encoder, terminal: Terminal) ---
	key_encoder_encode :: proc(encoder: Key_Encoder, event: Key_Event, out_buf: [^]u8, out_buf_size: c.size_t, out_len: ^c.size_t) -> Result ---
	key_event_new :: proc(allocator: ^Allocator, event: ^Key_Event) -> Result ---
	key_event_free :: proc(event: Key_Event) ---
	key_event_set_action :: proc(event: Key_Event, action: Key_Action) ---
	key_event_set_key :: proc(event: Key_Event, key: Key) ---
	key_event_set_mods :: proc(event: Key_Event, mods: Mods) ---
	key_event_set_consumed_mods :: proc(event: Key_Event, mods: Mods) ---
	key_event_set_utf8 :: proc(event: Key_Event, utf8: [^]u8, len: c.size_t) ---
	key_event_set_unshifted_codepoint :: proc(event: Key_Event, codepoint: u32) ---

	mouse_encoder_new :: proc(allocator: ^Allocator, encoder: ^Mouse_Encoder) -> Result ---
	mouse_encoder_free :: proc(encoder: Mouse_Encoder) ---
	mouse_encoder_setopt :: proc(encoder: Mouse_Encoder, option: Mouse_Encoder_Option, value: rawptr) ---
	mouse_encoder_setopt_from_terminal :: proc(encoder: Mouse_Encoder, terminal: Terminal) ---
	mouse_encoder_encode :: proc(encoder: Mouse_Encoder, event: Mouse_Event, out_buf: [^]u8, out_buf_size: c.size_t, out_len: ^c.size_t) -> Result ---
	mouse_event_new :: proc(allocator: ^Allocator, event: ^Mouse_Event) -> Result ---
	mouse_event_free :: proc(event: Mouse_Event) ---
	mouse_event_set_action :: proc(event: Mouse_Event, action: Mouse_Action) ---
	mouse_event_set_button :: proc(event: Mouse_Event, button: Mouse_Button) ---
	mouse_event_clear_button :: proc(event: Mouse_Event) ---
	mouse_event_set_mods :: proc(event: Mouse_Event, mods: Mods) ---
	mouse_event_set_position :: proc(event: Mouse_Event, position: Mouse_Position) ---

	paste_encode :: proc(data: [^]u8, data_len: c.size_t, bracketed: bool, buf: [^]u8, buf_len: c.size_t, out_written: ^c.size_t) -> Result ---
	focus_encode :: proc(event: Focus_Event, buf: [^]u8, buf_len: c.size_t, out_written: ^c.size_t) -> Result ---
	color_scheme_report_encode :: proc(scheme: Color_Scheme, buf: [^]u8, buf_len: c.size_t, out_written: ^c.size_t) -> Result ---
}
