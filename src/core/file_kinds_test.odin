package core

// What icon a Files row draws (file_kinds.odin): by exact name first, then .env*, then the
// extension (any case), else a plain file.

import "core:strings"
import "core:testing"

@(test)
file_kind_mapping :: proc(t: ^testing.T) {
	Case :: struct {
		name: string,
		dir:  bool,
		want: File_Kind,
	}
	cases := [?]Case {
		{"src", true, .Folder},
		{"main.c", true, .Folder}, // a folder is a folder, whatever its name
		{"notes", false, .File},
		{"weird.unknownext", false, .File},
		{"", false, .File},
		{"main.odin", false, .Code},
		{"App.TSX", false, .Code},
		{"Makefile", false, .Code},
		{"Dockerfile", false, .Code},
		{"README.md", false, .Doc},
		{"notes.txt", false, .Doc},
		{"LICENSE", false, .Doc},
		{"tsconfig.json", false, .Config},
		{"ci.yml", false, .Config},
		{".editorconfig", false, .Config},
		{"logo.PNG", false, .Image},
		{"icon.svg", false, .Image},
		{"build.sh", false, .Shell},
		{".zshrc", false, .Shell},
		{"package.json", false, .Package}, // the name wins over .json
		{"Cargo.toml", false, .Package}, // over .toml
		{"Cargo.lock", false, .Package},
		{"some.lock", false, .Package},
		{"go.sum", false, .Package},
		{".gitignore", false, .Git},
		{".gitattributes", false, .Git},
		{".env", false, .Env},
		{".env.local", false, .Env},
		{".env.example", false, .Env},
		{".envrc", false, .Shell}, // direnv's: a script, not an .env file
		{"archive.tar.gz", false, .Binary},
		{"a.zip", false, .Binary},
		{"lib.dylib", false, .Binary},
		{"AGENTS.md", false, .Agent}, // over .md
		{"CLAUDE.md", false, .Agent},
		{"claude.md", false, .Agent}, // any case
		{"CLAUDE.local.md", false, .Agent},
		{".hidden", false, .File}, // a dotfile has no extension
		{"trailing.", false, .File},
	}
	for c in cases {
		got := file_kind(c.name, c.dir)
		testing.expectf(t, got == c.want, "%q (dir %v): got %v, want %v", c.name, c.dir, got, c.want)
	}
	// every kind has an icon, and folders draw open or closed
	for k in File_Kind do testing.expectf(t, file_kind_icon(k, false) != .None, "%v has no icon", k)
	testing.expect(t, file_kind_icon(.Folder, true) == .Folder_Open && file_kind_icon(.Folder, false) == .Folder)
	// the tables hold lowercase keys only (the lookup lowers the name), each once
	seen := make(map[string]bool, context.temp_allocator)
	for e in FILE_KIND_NAMES {
		testing.expectf(t, e.key == strings.to_lower(e.key, context.temp_allocator), "name %q is not lowercase", e.key)
		testing.expectf(t, !(e.key in seen), "name %q twice", e.key)
		seen[e.key] = true
	}
	clear(&seen)
	for e in FILE_KIND_EXTS {
		testing.expectf(t, e.key == strings.to_lower(e.key, context.temp_allocator) && e.key != "" && e.key[0] != '.', "ext %q: lowercase, no dot", e.key)
		testing.expectf(t, !(e.key in seen), "ext %q twice", e.key)
		seen[e.key] = true
	}
}
