// A guard in front of core:encoding/json for JSON that Deckhand does not fully
// control (sockets, apps, pages, other programs' files, the network). Pure:
// imports only core, so the app, holderwire and the holder can all use it.
//
// Why: core:encoding/json
// - recurses per nesting level with no limit (parse_value -> parse_array /
//   parse_object, and marshal on the way back out): 100 KB of "[" overflows
//   the stack;
// - writes 3 bytes per invalid UTF-8 byte into an unquote buffer sized for
//   the input plus 8: a string of 5+ bad bytes is a bounds trap;
// - ends a string at a raw newline (String_Not_Terminated) and its parser
//   carries on, so a naive bracket count drifts out of step with it;
// - unmarshal into a struct grows the stack per key of one object (100,000
//   keys overflow a 512 KiB thread).
// check refuses all of those, in one pass, before anything parses.
//
// Stack measured (dev-2026-09, arm64, a 512 KiB thread: the smallest any
// Deckhand thread gets; Odin threads take RLIMIT_STACK, normally 8 MiB):
// per level, parse 0.74 KB (arrays) / 1.3 KB (objects) at -o:speed, 1.2 /
// 1.8 KB in unoptimised test builds, 5.5 KB with a marshal after it. So 64
// levels cost at most ~350 KB and 128 levels ~230 KB parse-only: both fit.
package jsonguard

import "core:encoding/json"
import "core:unicode/utf8"

// The default depth: Deckhand's own protocols (the control socket, app tabs,
// browser messages), settings and state files. Real ones nest under 20.
MAX_DEPTH :: 64
// pi session lines and pi's JSON events (tool results inside messages): seen
// nesting 72 deep in real sessions.
MAX_DEPTH_TRANSCRIPT :: 128
// The most any caller may ask for (the per-level key counts live on the stack).
DEPTH_CAP :: 256
// Keys per object for unmarshal into a struct (its stack cost grows per key).
// Plain parse has no per-key stack cost: unlimited by default.
MAX_KEYS_UNMARSHAL :: 4096
NO_KEY_LIMIT :: max(int)

Refusal :: enum u8 {
	None,
	Not_Utf8, // JSON forbids it; unquote overruns on it
	Control_In_String, // a raw byte < 0x20 in a string (JSON forbids it; the tokenizer ends the string at \n)
	Too_Deep,
	Too_Many_Keys, // in one object
	Unbalanced, // more closers than openers
}

// Why b must not reach the parser (.None: it may). Says nothing else about
// validity; json.parse decides that after. spec matters for JSON5 (and
// SJSON/MJSON): single-quoted strings and comments, scanned exactly as the
// tokenizer scans them, so the count cannot be fooled by a bracket in either.
check :: proc(s: string, max_depth := MAX_DEPTH, max_keys := NO_KEY_LIMIT, spec := json.DEFAULT_SPECIFICATION) -> Refusal {
	if !utf8.valid_string(s) do return .Not_Utf8
	limit := min(max_depth, DEPTH_CAP)
	keys: [DEPTH_CAP + 1]int
	depth := 0
	quote: u8 = 0 // the open string's quote, 0 outside strings
	esc := false
	json5 := spec != .JSON
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if quote != 0 {
			if c < 0x20 do return .Control_In_String
			if esc do esc = false
			else if c == '\\' do esc = true
			else if c == quote do quote = 0
			continue
		}
		switch c {
		case '"': quote = c
		case '\'': if json5 do quote = c
		case '/':
			// comments (not JSON's): as the tokenizer skips them
			if !json5 || i + 1 >= len(s) do break
			if s[i + 1] == '/' {
				i += 2
				for i < len(s) && s[i] != '\n' do i += 1
			} else if s[i + 1] == '*' {
				// the tokenizer reads pairs: a '*' then the next byte; "*/" closes only as such a pair
				i += 2
				closed := false
				for i < len(s) {
					a := s[i]
					i += 1
					if a == '*' && i < len(s) {
						b := s[i]
						i += 1
						if b == '/' {closed = true; break}
					}
				}
				i -= 1 // the loop's i += 1
				if !closed do return .None // the tokenizer stops at EOF in the comment: nothing more parses
			}
		case '{', '[':
			depth += 1
			if depth > limit do return .Too_Deep
			keys[depth] = 0
		case '}', ']':
			depth -= 1
			if depth < 0 do return .Unbalanced
		case ':':
			keys[depth] += 1
			if keys[depth] > max_keys do return .Too_Many_Keys
		}
	}
	return .None
}

shape_ok_string :: proc(s: string, max_depth := MAX_DEPTH, max_keys := NO_KEY_LIMIT, spec := json.DEFAULT_SPECIFICATION) -> bool {
	return check(s, max_depth, max_keys, spec) == .None
}
shape_ok_bytes :: proc(b: []u8, max_depth := MAX_DEPTH, max_keys := NO_KEY_LIMIT, spec := json.DEFAULT_SPECIFICATION) -> bool {
	return check(string(b), max_depth, max_keys, spec) == .None
}
shape_ok :: proc {
	shape_ok_string,
	shape_ok_bytes,
}

// The json.Error a refusal reads as at a call site (any non-None error is
// "bad JSON" there).
refusal_error :: proc(r: Refusal) -> json.Error {
	switch r {
	case .None: return .None
	case .Not_Utf8: return .Invalid_Rune
	case .Control_In_String: return .String_Not_Terminated
	case .Too_Deep, .Too_Many_Keys, .Unbalanced: return .Unexpected_Token
	}
	return .Unexpected_Token
}

// json.parse with the guard in front: same arguments and defaults, plus the
// limits. A refused input returns (nil, a non-None error), like bad JSON.
// fix_utf8: replace invalid UTF-8 with U+FFFD (a copy, in allocator) instead
// of refusing it, for text that is worth reading lossily (a session title).
parse_string :: proc(data: string, spec := json.DEFAULT_SPECIFICATION, parse_integers := false, allocator := context.allocator, max_depth := MAX_DEPTH, max_keys := NO_KEY_LIMIT, fix_utf8 := false, loc := #caller_location) -> (json.Value, json.Error) {
	data := data
	if fix_utf8 && !utf8.valid_string(data) do data = replace_invalid_utf8(data, allocator)
	if r := check(data, max_depth, max_keys, spec); r != .None do return nil, refusal_error(r)
	return json.parse_string(data, spec, parse_integers, allocator, loc)
}
parse_bytes :: proc(data: []u8, spec := json.DEFAULT_SPECIFICATION, parse_integers := false, allocator := context.allocator, max_depth := MAX_DEPTH, max_keys := NO_KEY_LIMIT, fix_utf8 := false, loc := #caller_location) -> (json.Value, json.Error) {
	return parse_string(string(data), spec, parse_integers, allocator, max_depth, max_keys, fix_utf8, loc)
}

// s with each invalid UTF-8 byte replaced by U+FFFD (allocated).
replace_invalid_utf8 :: proc(s: string, allocator := context.allocator) -> string {
	out := make([dynamic]u8, 0, len(s) + 16, allocator)
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && w <= 1 {
			append(&out, "\xef\xbf\xbd") // U+FFFD
			i += max(w, 1)
			continue
		}
		append(&out, s[i:i + w])
		i += w
	}
	return string(out[:])
}
parse :: proc {
	parse_bytes,
	parse_string,
}

// json.unmarshal with the guard in front (keys limited by default: see MAX_KEYS_UNMARSHAL).
unmarshal :: proc(data: []u8, ptr: ^$T, spec := json.DEFAULT_SPECIFICATION, allocator := context.allocator, max_depth := MAX_DEPTH, max_keys := MAX_KEYS_UNMARSHAL) -> json.Unmarshal_Error {
	if r := check(string(data), max_depth, max_keys, spec); r != .None do return refusal_error(r)
	return json.unmarshal(data, ptr, spec, allocator)
}
unmarshal_string :: proc(data: string, ptr: ^$T, spec := json.DEFAULT_SPECIFICATION, allocator := context.allocator, max_depth := MAX_DEPTH, max_keys := MAX_KEYS_UNMARSHAL) -> json.Unmarshal_Error {
	return unmarshal(transmute([]u8)data, ptr, spec, allocator, max_depth, max_keys)
}
