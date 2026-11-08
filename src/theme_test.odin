package main

// Contrast of every look in both appearances (WCAG 2 ratios): body and
// secondary text 4.5:1 on every surface text sits on, muted text, the accent
// and status colours 3:1 (status colours also mark text: 4.5:1 in the light
// variants), text on the accent 4.5:1, terminal text 4.5:1 and its colours
// 1-6 and 9-14 3:1 on the terminal background.

import "core:fmt"
import "core:testing"

@(test)
theme_contrast :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, what: string, fg, bg: Rgba, min: f32) {
		r := contrast_ratio(fg, bg)
		testing.expectf(t, r >= min, "%s: %.2f:1, want >= %.1f", what, r, min)
	}
	for look in Theme_Id do for light in ([]bool{false, true}) {
		th := light ? &THEMES_LIGHT[look] : &THEMES[look]
		tc := term_colors_of(look, light)
		name := fmt.tprintf("%s %s", THEME_NAMES[look], light ? "light" : "dark")
		surfaces := [?]struct {
			n: string,
			c: Rgba,
		}{{"bg_app", th.bg_app}, {"bg_sidebar", th.bg_sidebar}, {"bg_panel", th.bg_panel}, {"bg_elevated", th.bg_elevated}, {"bg_field", th.bg_field}}
		for s in surfaces {
			check(t, fmt.tprintf("%s text on %s", name, s.n), th.text, s.c, 4.5)
			check(t, fmt.tprintf("%s text_secondary on %s", name, s.n), th.text_secondary, s.c, 4.5)
			check(t, fmt.tprintf("%s text_muted on %s", name, s.n), th.text_muted, s.c, 3)
			check(t, fmt.tprintf("%s accent on %s", name, s.n), th.accent, s.c, 3)
			status := light ? f32(4.5) : 3
			check(t, fmt.tprintf("%s running on %s", name, s.n), th.running, s.c, status)
			check(t, fmt.tprintf("%s waiting on %s", name, s.n), th.waiting, s.c, status)
			check(t, fmt.tprintf("%s done on %s", name, s.n), th.done, s.c, status)
			check(t, fmt.tprintf("%s error on %s", name, s.n), th.error, s.c, status)
		}
		check(t, fmt.tprintf("%s text_on_accent", name), th.text_on_accent, th.accent, 4.5)
		check(t, fmt.tprintf("%s term_fg", name), tc.fg, tc.bg, 4.5)
		check(t, fmt.tprintf("%s term_fg on term_selection", name), tc.fg, th.term_selection, 4.5)
		check(t, fmt.tprintf("%s term_cursor", name), tc.cursor, tc.bg, 3)
		for i in ([]int{1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14}) {
			// light variants: the normal colours carry text, 4.5:1
			want := light && i < 8 ? f32(4.5) : 3
			check(t, fmt.tprintf("%s ansi %d", name, i), tc.ansi[i], tc.bg, want)
		}
		// the chrome's centre column is the terminal's background
		testing.expectf(t, th.bg_app == tc.bg, "%s: bg_app != term_bg", name)
		testing.expectf(t, (contrast_ratio(tc.fg, tc.bg) > 1) && (light == (lab_of(tc.fg).l < lab_of(tc.bg).l)), "%s: variant is the wrong way round", name)
	}
}
