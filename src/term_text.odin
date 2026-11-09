package main

import "core"


term_text_pt :: proc() -> f32 {
	return state.settings.term_text_pt > 0 ? f32(state.settings.term_text_pt) : core.TYPE_CODE_PX
}
