package core

// The web client's files, embedded in the core at build time: web/dist/ as the web client's own
// build makes it (`cd web && npm ci && npm run build`; flat: index.html, app.<hash>.js,
// app.<hash>.css, icon.<hash>.svg and their .gz copies). GET / is index.html, GET /assets/<name>
// web/dist/<name> (names starting with a dot, and .gz names, are not served: web_asset_reply).
// web/dist is not committed: a build without it (no Node) embeds WEB_PLACEHOLDER, a page that says
// so, and no assets.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:strings"

WEB_PLACEHOLDER :: `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Deckhand</title></head>
<body><p>Deckhand's web client is not in this build of its core (it was built without web/dist: cd web &amp;&amp; npm ci &amp;&amp; npm run build, then build Deckhand again).</p></body></html>
`

// Release builds (-define:DECKHAND_WEB_REQUIRED=true: build.sh with DECKHAND_RELEASE=1,
// scripts/pack-linux.sh) never ship the placeholder.
WEB_REQUIRED :: #config(DECKHAND_WEB_REQUIRED, false)

when WEB_REQUIRED && !#exists("../../web/dist/index.html") {
	#panic("web/dist/index.html is missing: a release build embeds the web client (scripts/build-web.sh needs Node 22.18 or later)")
}

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

// What a GET of an asset answers: 200 with its bytes, or 304 (index.html's ETag matched). A name
// with its content's hash (base.<hash>.ext: web/build.mjs) is cached for good; index.html and an
// unhashed name are revalidated each time (no-cache), index.html by its ETag. A .gz copy goes to a
// browser that takes gzip (Vary: Accept-Encoding); .gz names themselves are not served.
Web_Asset :: struct {
	status:   int, // 200 or 304
	data:     []u8,
	ctype:    string,
	encoding: string, // "" or "gzip"
	cache:    string, // Cache-Control
	etag:     string, // "" = none
	vary:     bool, // Vary: Accept-Encoding (it has a .gz copy)
}

WEB_CACHE_IMMUTABLE :: "public, max-age=31536000, immutable"

// The reply for a GET of path (accept: Accept-Encoding; if_none_match: If-None-Match). ok false: none.
web_asset_reply :: proc(path, accept, if_none_match: string) -> (a: Web_Asset, ok: bool) {
	if path == "/" || path == "/index.html" {
		a = {status = 200, ctype = "text/html; charset=utf-8", cache = "no-cache"}
		d, found := web_file("index.html")
		if !found {
			a.data = transmute([]u8)string(WEB_PLACEHOLDER)
			return a, true
		}
		a.data = d
		a.etag = fmt.tprintf(`"%016x"`, hash.fnv64a(d))
		if http_etag_match(if_none_match, a.etag) do a.status, a.data = 304, nil
		return a, true
	}
	if !strings.has_prefix(path, "/assets/") do return {}, false
	name := path[len("/assets/"):]
	if name == "" || name[0] == '.' || len(name) > 128 || strings.has_suffix(name, ".gz") do return {}, false
	for ch in transmute([]u8)name {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
		case: return {}, false
		}
	}
	d, found := web_file(name)
	if !found do return {}, false
	a = {status = 200, data = d, ctype = web_content_type(name), cache = web_asset_hashed(name) ? WEB_CACHE_IMMUTABLE : "no-cache"}
	if gz, has := web_file(strings.concatenate({name, ".gz"}, context.temp_allocator)); has {
		a.vary = true
		if http_accepts_gzip(accept) do a.data, a.encoding = gz, "gzip"
	}
	return a, true
}

// A name with its content's hash: base.<10 or more hex>.ext.
web_asset_hashed :: proc(name: string) -> bool {
	parts := strings.split(name, ".", context.temp_allocator)
	if len(parts) < 3 do return false
	h := parts[len(parts) - 2]
	if len(h) < 10 do return false
	for ch in transmute([]u8)h do if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') do return false
	return true
}

// Whether Accept-Encoding takes gzip: a gzip entry (not q=0) or, with none, a * entry (not q=0).
http_accepts_gzip :: proc(header: string) -> bool {
	// gzip by name decides; else the wildcard does; else no (RFC 9110 §12.5.3)
	named, wild := -1, -1 // -1 not listed, 0 refused (q=0), 1 taken
	rest := header
	for part in strings.split_iterator(&rest, ",") {
		p := strings.trim_space(part)
		coding, params := p, ""
		if i := strings.index_byte(p, ';'); i >= 0 do coding, params = strings.trim_space(p[:i]), p[i + 1:]
		ok := 1
		q := strings.trim_space(params)
		if strings.has_prefix(q, "q=") || strings.has_prefix(q, "Q=") {
			v := strings.trim_space(q[2:])
			if v == "0" || v == "0." || v == "0.0" || v == "0.00" || v == "0.000" do ok = 0
		}
		if strings.equal_fold(coding, "gzip") do named = ok
		else if coding == "*" do wild = ok
	}
	return named == 1 || (named < 0 && wild == 1)
}

// Whether If-None-Match names etag (a list, weak or strong, or *).
http_etag_match :: proc(header, etag: string) -> bool {
	if header == "" || etag == "" do return false
	rest := header
	for part in strings.split_iterator(&rest, ",") {
		p := strings.trim_space(part)
		if p == "*" do return true
		if strings.has_prefix(p, "W/") do p = p[2:]
		if p == etag do return true
	}
	return false
}

// Sends the asset at path (a GET). False: none (the caller answers 404).
web_asset_send :: proc(fd: Sock_Fd, path: string, req: Http_Request) -> bool {
	a, ok := web_asset_reply(path, req.accept_encoding, req.if_none_match)
	if !ok do return false
	web_send_asset(fd, a, req.host)
	return true
}
