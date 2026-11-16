package core

// The web client's files, embedded in the core at build time: web/dist/ as the web client's own
// build makes it (`cd web && npm ci && npm run build`; flat: index.html, app.js, app.css). GET / is
// index.html, GET /assets/<name> web/dist/<name> (names starting with a dot are not served).
// web/dist is not committed: a build without it (no Node) embeds WEB_PLACEHOLDER, a page that says
// so, and no assets.

import "base:runtime"
import "core:strings"

WEB_PLACEHOLDER :: `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Deckhand</title></head>
<body><p>Deckhand's web client is not in this build of its core (it was built without web/dist: cd web &amp;&amp; npm ci &amp;&amp; npm run build, then build Deckhand again).</p></body></html>
`

when #exists("../../web/dist/index.html") {
	@(private = "file")
	WEB_FILES := #load_directory("../../web/dist")
	WEB_CLIENT_BUILT :: true
} else {
	@(private = "file")
	WEB_FILES: []runtime.Load_Directory_File
	WEB_CLIENT_BUILT :: false
}

// A file's media type by its extension.
web_content_type :: proc(name: string) -> string {
	ext := name
	if d := strings.last_index_byte(name, '.'); d >= 0 do ext = name[d:]
	switch ext {
	case ".html": return "text/html; charset=utf-8"
	case ".js", ".mjs": return "text/javascript; charset=utf-8"
	case ".css": return "text/css; charset=utf-8"
	case ".json", ".map": return "application/json"
	case ".svg": return "image/svg+xml"
	case ".png": return "image/png"
	case ".ico": return "image/x-icon"
	case ".woff2": return "font/woff2"
	case ".woff": return "font/woff"
	case ".txt": return "text/plain; charset=utf-8"
	case ".webmanifest": return "application/manifest+json"
	}
	return "application/octet-stream"
}

@(private = "file")
web_file :: proc(name: string) -> ([]u8, bool) {
	for f in WEB_FILES do if f.name == name do return f.data, true
	return nil, false
}

// The asset at a request path: its bytes and type. ok false: none.
web_asset :: proc(path: string) -> (data: []u8, ctype: string, ok: bool) {
	if path == "/" || path == "/index.html" {
		if d, found := web_file("index.html"); found do return d, "text/html; charset=utf-8", true
		return transmute([]u8)string(WEB_PLACEHOLDER), "text/html; charset=utf-8", true
	}
	if !strings.has_prefix(path, "/assets/") do return nil, "", false
	name := path[len("/assets/"):]
	if name == "" || name[0] == '.' || len(name) > 128 do return nil, "", false
	for ch in transmute([]u8)name {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
		case: return nil, "", false
		}
	}
	d, found := web_file(name)
	if !found do return nil, "", false
	return d, web_content_type(name), true
}

// Sends the asset at path (a GET). False: none (the caller answers 404).
web_asset_send :: proc(fd: Sock_Fd, path, host: string) -> bool {
	data, ctype, ok := web_asset(path)
	if !ok do return false
	web_send(fd, 200, ctype, string(data), host = host, api = false)
	return true
}
