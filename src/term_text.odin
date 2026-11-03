package main

// The terminal and editor text size (Set_Terminal_Text_Size; theme.odin's
// theme_font_config): points, 0 in the settings = the look's.
TERM_TEXT_MIN :: 9
TERM_TEXT_MAX :: 28

term_text_pt :: proc() -> f32 {
	return state.settings.term_text_pt > 0 ? f32(state.settings.term_text_pt) : TYPE_CODE_PX
}
