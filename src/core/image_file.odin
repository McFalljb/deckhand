package core

// Images in file tabs: a file tab of a PNG, JPEG, GIF, BMP or WebP shows the picture, read-only
// (the window: image_view.odin; a browser: web/src/app/ImageView.tsx through file_read's image).
// A file is shown as an image when its extension says so (image_ext) and its first bytes agree
// (image_sniff); anything else stays a text file (an SVG is text: the editor, and a browser's
// preview of its text). The bytes are read under each reader's usual rules (the window's
// disk_read, a browser's file_read); these caps only bound what is decoded.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

IMAGE_FILE_MAX :: 64 << 20 // an image file the window shows: at most this many bytes on disk
IMAGE_PIXELS_MAX :: 100_000_000 // and at most this many pixels (width x height), checked before decoding
WEB_IMAGE_MAX :: 8 << 20 // an image a browser shows (file_read image): its base64 fits one 16 MB frame

Image_Format :: enum u8 {
	None,
	PNG,
	JPEG,
	GIF,
	BMP,
	WebP,
}

IMAGE_MIME := [Image_Format]string {
	.None = "",
	.PNG  = "image/png",
	.JPEG = "image/jpeg",
	.GIF  = "image/gif",
	.BMP  = "image/bmp",
	.WebP = "image/webp",
}

IMAGE_NAME := [Image_Format]string {
	.None = "",
	.PNG  = "PNG",
	.JPEG = "JPEG",
	.GIF  = "GIF",
	.BMP  = "BMP",
	.WebP = "WebP",
}

// The image format a file's extension names (any case), .None for any other file.
image_ext :: proc(path: string) -> Image_Format {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".png":           return .PNG
	case ".jpg", ".jpeg":  return .JPEG
	case ".gif":           return .GIF
	case ".bmp":           return .BMP
	case ".webp":          return .WebP
	}
	return .None
}

// The format the first bytes are (magic numbers), .None when they are none of these.
image_sniff :: proc(head: []u8) -> Image_Format {
	has :: proc(b: []u8, at: int, s: string) -> bool {return len(b) >= at + len(s) && string(b[at:at + len(s)]) == s}
	switch {
	case has(head, 0, "\x89PNG\r\n\x1a\n"):                 return .PNG
	case has(head, 0, "\xff\xd8\xff"):                      return .JPEG
	case has(head, 0, "GIF87a") || has(head, 0, "GIF89a"): return .GIF
	case has(head, 0, "BM") && len(head) >= 14:             return .BMP
	case has(head, 0, "RIFF") && has(head, 8, "WEBP"):      return .WebP
	}
	return .None
}

// Whether a file is an image a file tab shows: its extension names a format and its first bytes
// are an image (any of them: a .jpg that is really a PNG still shows). Reads 16 bytes, opened
// non-blocking (a FIFO named .png never blocks).
image_file :: proc(path: string) -> bool {
	if image_ext(path) == .None do return false
	f, err := os.open(path, {.Read, .Non_Blocking})
	if err != nil do return false
	defer os.close(f)
	sb: posix.stat_t
	if posix.fstat(posix.FD(os.fd(f)), &sb) != .OK || !posix.S_ISREG(sb.st_mode) do return false
	head: [16]u8
	n, _ := disk_read_chunk(f, head[:])
	return image_sniff(head[:max(n, 0)]) != .None
}
