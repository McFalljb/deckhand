package core

// The terminal's default colours per look and appearance: what libghostty-vt
// answers OSC 4/10/11 and CSI ? 996 n with, so they are the core's, not the
// window's (design §4: the core owns every terminal). The chrome's colours are
// in theme.odin; each look's bg_app equals its terminal background here.

import "core:math"
import gh "../ghostty"

Term_Colors :: struct {
	fg:     Rgba,
	bg:     Rgba,
	cursor: Rgba,
	ansi:   [16]Rgba, // 16..255 follow xterm's cube and grey ramp (term_palette)
}

TERM_COLORS := [Theme_Id]Term_Colors {
	.Graphite = {
		fg     = {0xd4, 0xd4, 0xd8, 255},
		bg     = {0x17, 0x17, 0x1a, 255},
		cursor = {0xe4, 0xe4, 0xe7, 255},
		ansi   = {
			{0x27, 0x27, 0x2a, 255}, {0xe5, 0x73, 0x7a, 255}, {0x8f, 0xc4, 0x8a, 255}, {0xe3, 0xc0, 0x7b, 255},
			{0x7a, 0xa2, 0xf7, 255}, {0xc2, 0x9b, 0xe0, 255}, {0x6f, 0xc2, 0xc8, 255}, {0xc8, 0xc8, 0xce, 255},
			{0x5a, 0x5a, 0x63, 255}, {0xf0, 0x8a, 0x90, 255}, {0xa6, 0xd6, 0xa0, 255}, {0xee, 0xd4, 0x9a, 255},
			{0x96, 0xb6, 0xf8, 255}, {0xd3, 0xb3, 0xec, 255}, {0x8d, 0xd3, 0xd8, 255}, {0xed, 0xed, 0xf0, 255},
		},
	},
	.Warm = {
		fg     = {0xe0, 0xd6, 0xc8, 255},
		bg     = {0x1b, 0x18, 0x15, 255},
		cursor = {0xed, 0xe4, 0xd8, 255},
		ansi   = {
			{0x2a, 0x25, 0x20, 255}, {0xd9, 0x70, 0x5f, 255}, {0xa3, 0xb8, 0x6c, 255}, {0xe3, 0xb3, 0x41, 255},
			{0x7f, 0xa7, 0xc9, 255}, {0xc6, 0x91, 0x9f, 255}, {0x86, 0xb8, 0xa6, 255}, {0xd9, 0xcf, 0xc2, 255},
			{0x6b, 0x60, 0x56, 255}, {0xea, 0x8a, 0x78, 255}, {0xb8, 0xcc, 0x83, 255}, {0xf0, 0xc7, 0x66, 255},
			{0x9b, 0xbc, 0xd8, 255}, {0xd7, 0xa9, 0xb5, 255}, {0xa0, 0xcb, 0xbb, 255}, {0xf2, 0xea, 0xdf, 255},
		},
	},
	.Ghostty = {
		fg     = {0xff, 0xff, 0xff, 255},
		bg     = {0x28, 0x2c, 0x34, 255},
		cursor = {0xff, 0xff, 0xff, 255},
		ansi   = {
			{0x1d, 0x1f, 0x21, 255}, {0xcc, 0x66, 0x66, 255}, {0xb5, 0xbd, 0x68, 255}, {0xf0, 0xc6, 0x74, 255},
			{0x81, 0xa2, 0xbe, 255}, {0xb2, 0x94, 0xbb, 255}, {0x8a, 0xbe, 0xb7, 255}, {0xc5, 0xc8, 0xc6, 255},
			{0x66, 0x66, 0x66, 255}, {0xd5, 0x4e, 0x53, 255}, {0xb9, 0xca, 0x4a, 255}, {0xe7, 0xc5, 0x47, 255},
			{0x7a, 0xa6, 0xda, 255}, {0xc3, 0x97, 0xd8, 255}, {0x70, 0xc0, 0xb1, 255}, {0xea, 0xea, 0xea, 255},
		},
	},
}

TERM_COLORS_LIGHT := [Theme_Id]Term_Colors {
	.Graphite = {
		fg     = {0x27, 0x27, 0x2a, 255},
		bg     = {0xfa, 0xfa, 0xfa, 255},
		cursor = {0x18, 0x18, 0x1b, 255},
		ansi   = {
			{0x27, 0x27, 0x2a, 255}, {0xc4, 0x2b, 0x2b, 255}, {0x2d, 0x7a, 0x2f, 255}, {0x8f, 0x64, 0x00, 255},
			{0x25, 0x63, 0xeb, 255}, {0x90, 0x35, 0xc0, 255}, {0x0e, 0x74, 0x90, 255}, {0xd4, 0xd4, 0xd8, 255},
			{0x71, 0x71, 0x7a, 255}, {0xdc, 0x3c, 0x3c, 255}, {0x3a, 0x8f, 0x3d, 255}, {0xa8, 0x77, 0x00, 255},
			{0x3b, 0x7c, 0xf0, 255}, {0xa2, 0x4f, 0xd6, 255}, {0x0b, 0x8a, 0xa8, 255}, {0xf4, 0xf4, 0xf5, 255},
		},
	},
	.Warm = {
		fg     = {0x3a, 0x30, 0x28, 255},
		bg     = {0xfb, 0xf8, 0xf3, 255},
		cursor = {0x2a, 0x22, 0x1b, 255},
		ansi   = {
			{0x3a, 0x30, 0x28, 255}, {0xb3, 0x37, 0x2a, 255}, {0x4c, 0x75, 0x20, 255}, {0x8a, 0x5f, 0x00, 255},
			{0x2f, 0x6a, 0x85, 255}, {0x94, 0x49, 0x6a, 255}, {0x2d, 0x75, 0x65, 255}, {0xdd, 0xd3, 0xc6, 255},
			{0x85, 0x78, 0x69, 255}, {0xc8, 0x50, 0x3f, 255}, {0x5d, 0x8a, 0x2c, 255}, {0xa3, 0x72, 0x00, 255},
			{0x3f, 0x7f, 0xa0, 255}, {0xab, 0x5d, 0x80, 255}, {0x3a, 0x8b, 0x78, 255}, {0xf3, 0xed, 0xe4, 255},
		},
	},
	.Ghostty = {
		fg     = {0x4d, 0x4d, 0x4c, 255},
		bg     = {0xff, 0xff, 0xff, 255},
		cursor = {0x4d, 0x4d, 0x4c, 255},
		ansi   = {
			{0x1d, 0x1f, 0x21, 255}, {0xc8, 0x28, 0x29, 255}, {0x5a, 0x70, 0x00, 255}, {0x8c, 0x60, 0x00, 255},
			{0x42, 0x71, 0xae, 255}, {0x89, 0x59, 0xa8, 255}, {0x28, 0x72, 0x7a, 255}, {0xd6, 0xd6, 0xd6, 255},
			{0x8e, 0x90, 0x8c, 255}, {0xd5, 0x4e, 0x53, 255}, {0x71, 0x8c, 0x00, 255}, {0xb5, 0x89, 0x00, 255},
			{0x5a, 0x8c, 0xcc, 255}, {0xa2, 0x74, 0xc0, 255}, {0x3e, 0x99, 0x9f, 255}, {0xef, 0xef, 0xef, 255},
		},
	},
}


// A look's terminal colours in one appearance.
term_colors_of :: proc(look: Theme_Id, light: bool) -> ^Term_Colors {
	return light ? &TERM_COLORS_LIGHT[look] : &TERM_COLORS[look]
}

// The active look's terminal colours in the active appearance.
term_colors :: proc() -> ^Term_Colors {return term_colors_of(state.settings.theme, theme_is_light())}

// Whether the chrome and the terminals are light now.
theme_is_light :: proc() -> bool {
	switch state.settings.appearance {
	case .Light:  return true
	case .Dark:   return false
	case .System: return state.system_light
	}
	return false
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
term_palette :: proc(th: ^Term_Colors) -> (p: [256]gh.Color_Rgb) {
	for c, i in th.ansi do p[i] = {c.r, c.g, c.b}
	if lab_of(th.fg).l < lab_of(th.bg).l {
		// corners: dark end (the foreground), colours 1-6, light end
		base: [8]Lab = {lab_of(th.fg), {}, {}, {}, {}, {}, {}, lab_of(th.bg)}
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

