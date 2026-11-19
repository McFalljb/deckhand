package main

// Image tabs: an editor tab whose file is a PNG, JPEG, GIF (its first frame) or BMP shows the
// picture instead of text (core/image_file.odin decides what is an image). It stays an ordinary
// editor tab for the core and the agents, read-only and "refused" as text (no buffer, no save,
// find or diff: e.refused names the image), so nothing of the bytes reaches an agent. Opening reads
// 16 bytes; the file is read and decoded at the tab's first draw (image_ensure: a tab an agent
// showed behind the view holds no pixels), and again at the next draw after it changes. The file is
// read as the editor reads text (disk_read: credentials, regular files, non-blocking) up to
// core.IMAGE_FILE_MAX; its size is checked (core.IMAGE_PIXELS_MAX) before anything is decoded,
// with stb_image. Drawn centred, fitted to the pane and never past 100% (one image pixel a
// point), over a checkerboard, with its size under it; no zoom. It follows the file on disk as
// text tabs do (editor_check_disk). WebP (and anything stb_image cannot decode) says it cannot be
// shown here (a browser shows WebP). The texture goes when the tab closes or the file reloads,
// destroyed after the frame's commit (images_frame_done).

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import sg "../vendor/sokol-odin/sokol/gfx"
import sgl "../vendor/sokol-odin/sokol/gl"
import stbi "vendor:stb/image"
import "core"

IMAGE_TEX_MAX :: 8192 // a texture's side at most: larger images are scaled down to fit (the view fits them anyway)

Image_View :: struct {
	format:     core.Image_Format,
	w, h:       int, // the image's pixels
	tw, th:     int, // the texture's (scaled down past IMAGE_TEX_MAX)
	pixels:     []u8, // RGBA, tw x th, until uploaded at the first draw (heap)
	image:      sg.Image,
	view:       sg.View,
	size:       i64, // bytes on disk
}

image_textures: int // alive (tests: every one is destroyed)

@(private = "file")
image_retired: [dynamic]Image_View // textures to destroy after this frame's commit

@(private = "file")
image_sampler, checker_sampler: sg.Sampler
@(private = "file")
checker: struct {
	image: sg.Image,
	view:  sg.View,
}

// Opens e's file as an image tab when its extension names an image format and its first bytes
// are one (core.image_file: a stat and 16 bytes); false: the caller reads it as text. Nothing is
// decoded here: a tab never drawn (one an agent showed behind the user's view) holds no pixels;
// image_ensure decodes at its first draw.
image_load :: proc(e: ^Editor) -> bool {
	if core.image_ext(e.path) == .None || core.settings_credential(e.path) || !core.image_file(e.path) do return false
	e.image_tab, e.img_stale, e.readonly = true, true, true
	e.disk, _ = disk_stamp(e.path)
	tb_init(&e.buf, nil)
	e.refused = fmt.aprintf("%s image (not text)", core.IMAGE_NAME[core.image_ext(e.path)])
	return true
}

// An image tab about to be drawn: its file read and decoded, unless done since it last changed.
// The bytes are read as the editor reads text (disk_read: credentials, regular files), up to
// core.IMAGE_FILE_MAX; no longer an image by its first bytes: a text tab from now on.
image_ensure :: proc(e: ^Editor) {
	if !e.image_tab || !e.img_stale do return
	e.img_stale = false
	image_free(e)
	data, st, refused := disk_read(e.path, limit = core.IMAGE_FILE_MAX, binary_ok = true)
	if refused != "" {
		delete(e.refused)
		e.refused = strings.clone(refused)
		return
	}
	e.disk = st
	defer delete(data)
	f := core.image_sniff(data[:min(len(data), 16)])
	if f == .None {
		path := strings.clone(e.path, context.temp_allocator)
		tb_destroy(&e.buf)
		delete(e.refused)
		delete(e.path)
		e.refused, e.path = "", ""
		e.image_tab, e.readonly = false, false
		editor_load(e, path)
		return
	}
	v, why := image_decode(data, f)
	delete(e.refused)
	if why != "" {
		e.refused = strings.clone(why)
		return
	}
	v.size = i64(len(data))
	e.img = new_clone(v)
	e.refused = fmt.aprintf("%s image, %d × %d px (not text)", core.IMAGE_NAME[f], v.w, v.h)
}

// Decodes an image's bytes into RGBA pixels of their own (not yet a texture; stb_image's buffer
// freed before it returns), or why it cannot be shown. Pure: no GPU (tests).
image_decode :: proc(data: []u8, f: core.Image_Format) -> (v: Image_View, why: string) {
	v.format = f
	if f == .WebP do return v, "Can't display this image here: WebP images show in a browser, not in the window"
	w, h, n: c.int
	if len(data) > int(max(c.int)) || stbi.info_from_memory(raw_data(data), c.int(len(data)), &w, &h, &n) == 0 || w <= 0 || h <= 0 {
		return v, "Can't display this image: it could not be read"
	}
	if i64(w) * i64(h) > core.IMAGE_PIXELS_MAX {
		return v, fmt.tprintf("Can't display this image: %d × %d px is more than %d megapixels", w, h, core.IMAGE_PIXELS_MAX / 1_000_000)
	}
	px := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &n, 4)
	if px == nil do return v, "Can't display this image: it could not be decoded"
	defer stbi.image_free(px)
	v.w, v.h = int(w), int(h)
	// one in every `step` pixels each way, so the texture fits IMAGE_TEX_MAX (it is shown smaller
	// anyway); never 0 wide or high (8193 x 1)
	step := max((v.w + IMAGE_TEX_MAX - 1) / IMAGE_TEX_MAX, (v.h + IMAGE_TEX_MAX - 1) / IMAGE_TEX_MAX, 1)
	v.tw, v.th = max(v.w / step, 1), max(v.h / step, 1)
	src := px[:v.w * v.h * 4]
	v.pixels = make([]u8, v.tw * v.th * 4)
	if step == 1 do copy(v.pixels, src)
	else do for y in 0 ..< v.th do for x in 0 ..< v.tw {
		s := ((y * step) * v.w + x * step) * 4
		copy(v.pixels[(y * v.tw + x) * 4:][:4], src[s:s + 4])
	}
	return v, ""
}

// The tab's image goes (its tab closed, or the file changed): its pixels now, its texture after
// this frame's commit.
image_free :: proc(e: ^Editor) {
	if e.img == nil do return
	delete(e.img.pixels)
	if e.img.image.id != 0 do append(&image_retired, e.img^)
	free(e.img)
	e.img = nil
}

// After sg.commit (main.odin): the textures of images that went this frame.
images_frame_done :: proc() {
	for v in image_retired {
		sg.destroy_view(v.view)
		sg.destroy_image(v.image)
		image_textures -= 1
	}
	clear(&image_retired)
}

// An image tab looks at its file: changed on disk (or back), its picture goes and the file is read
// again at its next draw (image_ensure), not now: a hidden tab decodes nothing.
image_check_disk :: proc(e: ^Editor) {
	st, ok := disk_stamp(e.path)
	if !ok || st == e.disk do return
	e.disk = st
	image_free(e)
	e.img_stale = true
	app.redraw = true
}

// The image centred in the pane, fitted and never past 100% (one image pixel a point), over a
// checkerboard; its type, size and file size under it.
image_draw :: proc(e: ^Editor, x, y, w, h: f32) {
	v := e.img
	th := theme()
	cap_h := px(28)
	draw_rect(x, y, w, h, th.bg_app)
	if v.image.id == 0 && v.pixels != nil {
		v.image = sg.make_image({width = c.int(v.tw), height = c.int(v.th), pixel_format = .RGBA8, data = {ptr = raw_data(v.pixels), size = c.size_t(len(v.pixels))}})
		delete(v.pixels)
		v.pixels = nil
		if sg.query_image_state(v.image) != .VALID {
			// the GPU did not take it: the tab says so (no texture to keep or count)
			sg.destroy_image(v.image)
			v.image = {}
			image_free(e)
			delete(e.refused)
			e.refused = strings.clone("Can't display this image: it could not be made a texture")
			return
		}
		v.view = sg.make_view({texture = {image = v.image}})
		image_textures += 1
	}
	pad := px(16)
	aw, ah := max(w - 2 * pad, 1), max(h - 2 * pad - cap_h, 1)
	scale := min(aw / f32(v.w), ah / f32(v.h), app.dpi)
	iw, ih := math.round(f32(v.w) * scale), math.round(f32(v.h) * scale)
	ix, iy := math.round(x + (w - iw) / 2), math.round(y + pad + (ah - ih) / 2)
	if image_sampler.id == 0 do image_sampler = sg.make_sampler({min_filter = .LINEAR, mag_filter = .LINEAR, wrap_u = .CLAMP_TO_EDGE, wrap_v = .CLAMP_TO_EDGE})
	if checker.image.id == 0 {
		// 2 x 2 squares, repeated: the transparent parts show it
		k := [16]u8{255, 255, 255, 255, 204, 204, 204, 255, 204, 204, 204, 255, 255, 255, 255, 255}
		checker.image = sg.make_image({width = 2, height = 2, pixel_format = .RGBA8, data = {ptr = &k[0], size = len(k)}})
		checker.view = sg.make_view({texture = {image = checker.image}})
		checker_sampler = sg.make_sampler({min_filter = .NEAREST, mag_filter = .NEAREST, wrap_u = .REPEAT, wrap_v = .REPEAT})
	}
	cell := px(8)
	dark := int(th.bg_app.r) + int(th.bg_app.g) + int(th.bg_app.b) < 3 * 128
	t: u8 = dark ? 80 : 255 // a dark theme's checkerboard is darker
	sgl.end()
	sgl.texture(checker.view, checker_sampler)
	sgl.begin_quads()
	quad(ix, iy, iw, ih, iw / (2 * cell), ih / (2 * cell), t)
	sgl.end()
	sgl.texture(v.view, image_sampler)
	sgl.begin_quads()
	quad(ix, iy, iw, ih, 1, 1, 255)
	sgl.end()
	sgl.texture(font.view, font.sampler)
	sgl.begin_quads()
	caption := fmt.tprintf("%s · %d × %d px · %s%s", core.IMAGE_NAME[v.format], v.w, v.h, image_size_text(v.size), scale < app.dpi ? fmt.tprintf(" · %d%%", int(math.round(scale / app.dpi * 100))) : "")
	cw := text_width(caption, .UI_Small)
	draw_text(x + (w - cw) / 2, iy + ih + px(8), caption, th.text_muted, .UI_Small)

	quad :: proc(x, y, w, h, u, v: f32, k: u8) {
		sgl.v2f_t2f_c4b(x, y, 0, 0, k, k, k, 255)
		sgl.v2f_t2f_c4b(x + w, y, u, 0, k, k, k, 255)
		sgl.v2f_t2f_c4b(x + w, y + h, u, v, k, k, k, 255)
		sgl.v2f_t2f_c4b(x, y + h, 0, v, k, k, k, 255)
	}
}

// A file's size for people: 512 B, 3.4 KB, 12.0 MB.
image_size_text :: proc(n: i64) -> string {
	switch {
	case n < 1024:      return fmt.tprintf("%d B", n)
	case n < 1 << 20:   return fmt.tprintf("%.1f KB", f64(n) / 1024)
	}
	return fmt.tprintf("%.1f MB", f64(n) / (1 << 20))
}
