package core

// What a Files row is, for its icon (ui_files.odin draws file_kind_icon; src/icons.odin the
// shapes). The one table: the web client's tree mirrors FILE_KIND_NAMES and FILE_KIND_EXTS as
// they are (web/src/app), so change both together. A name is looked up as written (any case):
// first the whole name (FILE_KIND_NAMES), then `.env` and `.env.*`, then the part after the last
// dot (FILE_KIND_EXTS; a dotfile's leading dot does not start one), else a plain file.

import "core:strings"

File_Kind :: enum u8 {
	File, // anything else
	Folder,
	Code, // source files, build scripts
	Doc, // Markdown and other prose
	Config, // JSON, YAML, TOML, INI...
	Image,
	Shell, // shell scripts and rc files
	Package, // package manifests and lock files
	Git, // .gitignore and friends
	Env, // .env, .env.*
	Binary, // archives, executables, libraries, fonts, media
	Agent, // agent instructions: AGENTS.md, CLAUDE.md
}

File_Kind_Entry :: struct {
	key:  string, // lowercase; an extension without its dot
	kind: File_Kind,
}

// Whole names (lowercase), before the extension: package.json is a manifest, not config.
FILE_KIND_NAMES := [?]File_Kind_Entry {
	// agent instructions
	{"agents.md", .Agent},
	{"agent.md", .Agent},
	{"claude.md", .Agent},
	{"claude.local.md", .Agent},
	{"gemini.md", .Agent},
	// git
	{".gitignore", .Git},
	{".gitattributes", .Git},
	{".gitmodules", .Git},
	{".gitkeep", .Git},
	{".git-blame-ignore-revs", .Git},
	{".mailmap", .Git},
	// package manifests and lock files
	{"package.json", .Package},
	{"package-lock.json", .Package},
	{"npm-shrinkwrap.json", .Package},
	{"yarn.lock", .Package},
	{"pnpm-lock.yaml", .Package},
	{"pnpm-workspace.yaml", .Package},
	{"bun.lockb", .Package},
	{"deno.json", .Package},
	{"cargo.toml", .Package},
	{"go.mod", .Package},
	{"go.sum", .Package},
	{"go.work", .Package},
	{"gemfile", .Package},
	{"pipfile", .Package},
	{"pyproject.toml", .Package},
	{"requirements.txt", .Package},
	{"composer.json", .Package},
	{"podfile", .Package},
	{"package.swift", .Package},
	{"package.resolved", .Package},
	{"mix.exs", .Package},
	{"build.zig.zon", .Package},
	// build files: code
	{"makefile", .Code},
	{"gnumakefile", .Code},
	{"dockerfile", .Code},
	{"containerfile", .Code},
	{"justfile", .Code},
	{"cmakelists.txt", .Code},
	{"rakefile", .Code},
	// prose without an extension
	{"readme", .Doc},
	{"license", .Doc},
	{"licence", .Doc},
	{"copying", .Doc},
	{"changelog", .Doc},
	{"authors", .Doc},
	{"notice", .Doc},
	// config dotfiles
	{".editorconfig", .Config},
	{".prettierrc", .Config},
	{".eslintrc", .Config},
	{".npmrc", .Config},
	{".nvmrc", .Config},
	{".tool-versions", .Config},
	{".dockerignore", .Config},
	// shell rc files
	{".bashrc", .Shell},
	{".bash_profile", .Shell},
	{".zshrc", .Shell},
	{".zprofile", .Shell},
	{".zshenv", .Shell},
	{".profile", .Shell},
	{".envrc", .Shell},
}

// Extensions (lowercase, no dot).
FILE_KIND_EXTS := [?]File_Kind_Entry {
	// code
	{"odin", .Code}, {"c", .Code}, {"h", .Code}, {"cc", .Code}, {"cpp", .Code}, {"cxx", .Code},
	{"hpp", .Code}, {"hh", .Code}, {"m", .Code}, {"mm", .Code}, {"swift", .Code}, {"go", .Code},
	{"rs", .Code}, {"zig", .Code}, {"py", .Code}, {"rb", .Code}, {"js", .Code}, {"mjs", .Code},
	{"cjs", .Code}, {"jsx", .Code}, {"ts", .Code}, {"tsx", .Code}, {"mts", .Code}, {"cts", .Code},
	{"java", .Code}, {"kt", .Code}, {"kts", .Code}, {"scala", .Code}, {"cs", .Code}, {"fs", .Code},
	{"lua", .Code}, {"php", .Code}, {"pl", .Code}, {"r", .Code}, {"dart", .Code}, {"ex", .Code},
	{"exs", .Code}, {"erl", .Code}, {"hs", .Code}, {"ml", .Code}, {"clj", .Code}, {"vue", .Code},
	{"svelte", .Code}, {"css", .Code}, {"scss", .Code}, {"sass", .Code}, {"less", .Code},
	{"html", .Code}, {"htm", .Code}, {"sql", .Code}, {"glsl", .Code}, {"hlsl", .Code},
	{"metal", .Code}, {"wgsl", .Code}, {"vim", .Code}, {"el", .Code}, {"nim", .Code}, {"jl", .Code},
	{"asm", .Code}, {"s", .Code}, {"mk", .Code}, {"cmake", .Code}, {"gradle", .Code},
	// prose
	{"md", .Doc}, {"markdown", .Doc}, {"mdx", .Doc}, {"txt", .Doc}, {"rst", .Doc}, {"adoc", .Doc},
	{"org", .Doc}, {"tex", .Doc}, {"rtf", .Doc}, {"pdf", .Doc},
	// config
	{"json", .Config}, {"jsonc", .Config}, {"json5", .Config}, {"yaml", .Config}, {"yml", .Config},
	{"toml", .Config}, {"ini", .Config}, {"cfg", .Config}, {"conf", .Config}, {"xml", .Config},
	{"plist", .Config}, {"properties", .Config},
	// images
	{"png", .Image}, {"jpg", .Image}, {"jpeg", .Image}, {"gif", .Image}, {"webp", .Image},
	{"svg", .Image}, {"ico", .Image}, {"icns", .Image}, {"bmp", .Image}, {"tif", .Image},
	{"tiff", .Image}, {"heic", .Image}, {"avif", .Image}, {"psd", .Image},
	// shell
	{"sh", .Shell}, {"bash", .Shell}, {"zsh", .Shell}, {"fish", .Shell}, {"ps1", .Shell},
	{"bat", .Shell}, {"cmd", .Shell}, {"command", .Shell},
	// lock files
	{"lock", .Package},
	// archives, binaries, fonts, media
	{"zip", .Binary}, {"tar", .Binary}, {"gz", .Binary}, {"tgz", .Binary}, {"bz2", .Binary},
	{"xz", .Binary}, {"zst", .Binary}, {"7z", .Binary}, {"rar", .Binary}, {"dmg", .Binary},
	{"pkg", .Binary}, {"iso", .Binary}, {"jar", .Binary}, {"whl", .Binary}, {"exe", .Binary},
	{"dll", .Binary}, {"so", .Binary}, {"dylib", .Binary}, {"a", .Binary}, {"o", .Binary},
	{"bin", .Binary}, {"wasm", .Binary}, {"class", .Binary}, {"pyc", .Binary}, {"deb", .Binary},
	{"rpm", .Binary}, {"ttf", .Binary}, {"otf", .Binary}, {"woff", .Binary}, {"woff2", .Binary},
	{"mp3", .Binary}, {"wav", .Binary}, {"mp4", .Binary}, {"mov", .Binary}, {"sqlite", .Binary},
	{"db", .Binary},
}

// What the row of a file or folder named name is (a folder is always .Folder).
file_kind :: proc(name: string, is_dir: bool) -> File_Kind {
	if is_dir do return .Folder
	if name == "" do return .File
	lower := strings.to_lower(name, context.temp_allocator)
	for e in FILE_KIND_NAMES do if e.key == lower do return e.kind
	if lower == ".env" || strings.has_prefix(lower, ".env.") do return .Env
	dot := strings.last_index_byte(lower, '.')
	if dot <= 0 || dot == len(lower) - 1 do return .File // none, a dotfile's own dot, or a trailing one
	ext := lower[dot + 1:]
	for e in FILE_KIND_EXTS do if e.key == ext do return e.kind
	return .File
}

// The icon a kind draws (a folder: open or closed).
file_kind_icon :: proc(k: File_Kind, open: bool) -> Icon {
	switch k {
	case .Folder:  return open ? .Folder_Open : .Folder
	case .File:    return .File
	case .Code:    return .File_Code
	case .Doc:     return .File_Doc
	case .Config:  return .File_Config
	case .Image:   return .File_Image
	case .Shell:   return .File_Shell
	case .Package: return .File_Package
	case .Git:     return .Branch
	case .Env:     return .File_Env
	case .Binary:  return .File_Binary
	case .Agent:   return .File_Agent
	}
	return .File
}
