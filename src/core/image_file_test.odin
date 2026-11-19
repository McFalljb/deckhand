package core

// Images in file tabs (image_file.odin): what is an image (extension and first bytes), a
// browser's file_read image (base64 under file_read's rules), and show_file letting an agent show
// one (its bytes never come back).

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

TEST_PNG :: "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f\x8a\x00\x00\x00\x0e\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\x00\x42\x0d\x00\x0f\x7a\x03\x7e\x77\xe9\x7f\x97\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"

@(test)
image_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, image_ext("/a/b.PNG"), Image_Format.PNG)
	testing.expect_value(t, image_ext("x.jpeg"), Image_Format.JPEG)
	testing.expect_value(t, image_ext("x.webp"), Image_Format.WebP)
	testing.expect_value(t, image_ext("x.svg"), Image_Format.None) // text: the editor
	testing.expect_value(t, image_ext("png"), Image_Format.None)
	testing.expect_value(t, image_sniff(transmute([]u8)string(TEST_PNG)), Image_Format.PNG)
	testing.expect_value(t, image_sniff(transmute([]u8)string("\xff\xd8\xff\xe0")), Image_Format.JPEG)
	testing.expect_value(t, image_sniff(transmute([]u8)string("GIF89a....")), Image_Format.GIF)
	testing.expect_value(t, image_sniff(transmute([]u8)string("RIFF\x00\x00\x00\x00WEBPVP8 ")), Image_Format.WebP)
	testing.expect_value(t, image_sniff(transmute([]u8)string("BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00")), Image_Format.BMP)
	testing.expect_value(t, image_sniff(transmute([]u8)string("\x89PN")), Image_Format.None) // cut short
	testing.expect_value(t, image_sniff(transmute([]u8)string("let a = 1\n")), Image_Format.None)
}

@(test)
image_file_read_and_show :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	tmpl := strings.clone_to_cstring(fmt.tprintf("%s/img-XXXXXX", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")), context.temp_allocator)
	proj := fs_real(string(posix.mkdtemp(([^]u8)(tmpl))))
	put :: proc(path, text: string) {_ = os.write_entire_file(path, transmute([]u8)text)}
	png := fmt.tprintf("%s/a.png", proj)
	put(png, TEST_PNG)
	put(fmt.tprintf("%s/fake.png", proj), "not an image\n")
	put(fmt.tprintf("%s/b.bin", proj), "a\x00b\x00c")
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(proj)})
	web := Caller{kind = .UI, web = true}

	// a browser's image read: the bytes as base64 with the type their first bytes say
	r := run_command(File_Read{path = png, image = true}, web)
	testing.expect(t, r.ok, r.error)
	v, _ := json.parse_string(r.data, allocator = context.temp_allocator)
	o, _ := v.(json.Object)
	testing.expect(t, o != nil && o["image"].(json.String) == "image/png" && o["text"] == nil, r.data)
	if o == nil do return
	raw, _ := base64.decode(o["base64"].(json.String), allocator = context.temp_allocator)
	testing.expect_value(t, string(raw), TEST_PNG)
	h := strings.clone(o["hash"].(json.String), context.temp_allocator)
	same := run_command(File_Read{path = png, image = true, since = h}, web)
	testing.expect(t, same.ok && strings.contains(same.data, `"same":true`) && !strings.contains(same.data, "base64"), same.data)
	// as text it stays refused; an image read of a non-image is refused; file_read's rules hold
	testing.expect(t, !run_command(File_Read{path = png}, web).ok, "an image is not text")
	fake := run_command(File_Read{path = fmt.tprintf("%s/fake.png", proj), image = true}, web)
	testing.expect(t, !fake.ok && strings.contains(fake.error, "not an image"), fake.error)
	testing.expect(t, !run_command(File_Read{path = png, image = true}, Caller{kind = .UI}).ok, "a browser's only")
	big := strings.concatenate({TEST_PNG, strings.repeat("x", WEB_IMAGE_MAX, context.temp_allocator)}, context.temp_allocator)
	put(fmt.tprintf("%s/big.png", proj), big)
	tb := run_command(File_Read{path = fmt.tprintf("%s/big.png", proj), image = true}, web)
	testing.expect(t, !tb.ok && strings.contains(tb.error, "too large"), tb.error)

	// show_file's check: an image passes (a tab shows it), a .png that is text is text, binary is not
	testing.expect_value(t, show_file_peek(png), "")
	testing.expect_value(t, show_file_peek(fmt.tprintf("%s/fake.png", proj)), "")
	testing.expect(t, strings.has_prefix(show_file_peek(fmt.tprintf("%s/b.bin", proj)), "Binary"), "binary")
	testing.expect(t, image_file(png) && !image_file(fmt.tprintf("%s/fake.png", proj)), "image_file")
}
