package main

// The terminal's default colours (term_palette.odin), the core's since M2-A: a few pinned values
// per look (the tables moved out of theme.odin unchanged), the 256-colour palette's fixed parts,
// and a terminal taking the active look's colours.

import "core:testing"
import gh "ghostty"

@(test)
term_palette_per_look :: proc(t: ^testing.T) {
	// as they were in theme.odin's THEMES / THEMES_LIGHT
	testing.expect_value(t, term_colors_of(.Graphite, false).fg, Rgba{0xd4, 0xd4, 0xd8, 255})
	testing.expect_value(t, term_colors_of(.Warm, false).bg, Rgba{0x1b, 0x18, 0x15, 255})
	testing.expect_value(t, term_colors_of(.Ghostty, false).bg, Rgba{0x28, 0x2c, 0x34, 255})
	testing.expect_value(t, term_colors_of(.Graphite, true).cursor, Rgba{0x18, 0x18, 0x1b, 255})
	testing.expect_value(t, term_colors_of(.Ghostty, true).bg, Rgba{0xff, 0xff, 0xff, 255})
	testing.expect_value(t, term_colors_of(.Graphite, false).ansi[4], Rgba{0x7a, 0xa2, 0xf7, 255})
	for look in Theme_Id do for light in ([]bool{false, true}) {
		tc := term_colors_of(look, light)
		th := light ? &THEMES_LIGHT[look] : &THEMES[look]
		testing.expectf(t, th.bg_app == tc.bg, "%v light=%v: bg_app != terminal bg", look, light)
		p := term_palette(tc)
		for c, i in tc.ansi do testing.expect_value(t, p[i], gh.Color_Rgb{c.r, c.g, c.b})
		if !light {
			// dark: xterm's cube and ramp, as Ghostty's default
			testing.expect_value(t, p[16], gh.Color_Rgb{0, 0, 0})
			testing.expect_value(t, p[231], gh.Color_Rgb{255, 255, 255})
			testing.expect_value(t, p[232], gh.Color_Rgb{8, 8, 8})
		} else {
			// light: the cube's dark corner is the foreground, its light corner the background
			testing.expect_value(t, p[16], gh.Color_Rgb{tc.fg.r, tc.fg.g, tc.fg.b})
			testing.expect_value(t, p[231], gh.Color_Rgb{tc.bg.r, tc.bg.g, tc.bg.b})
		}
	}
	// the active look, in the active appearance
	saved := state.settings
	defer state.settings = saved
	state.settings.theme, state.settings.appearance = .Warm, .Light
	testing.expect(t, term_colors() == term_colors_of(.Warm, true))
	state.settings.appearance = .Dark
	testing.expect(t, term_colors() == term_colors_of(.Warm, false))
}
