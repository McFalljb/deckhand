package deckhand_cli

// Small JSON helpers: a writer for the objects this tool prints and sends, a compact
// serializer for values Deckhand returned (app replies, events), and readers that never fail.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import jg "../../src/jsonguard"

// A JSON string literal: quotes, backslashes and control characters escaped; invalid
// UTF-8 becomes U+FFFD, so the output is always valid JSON on one line.
json_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); {
		c := s[i]
		if c < 0x80 {
			switch c {
			case '"':  strings.write_string(b, `\"`)
			case '\\': strings.write_string(b, `\\`)
			case '\n': strings.write_string(b, `\n`)
			case '\r': strings.write_string(b, `\r`)
			case '\t': strings.write_string(b, `\t`)
			case:
				if c < 0x20 || c == 0x7f do fmt.sbprintf(b, `\u%04x`, c)
				else do strings.write_byte(b, c)
			}
			i += 1
			continue
		}
		r, w := utf8.decode_rune(s[i:])
		if r == utf8.RUNE_ERROR && w <= 1 {
			strings.write_string(b, "\\ufffd")
			i += 1
			continue
		}
		if r == 0x2028 || r == 0x2029 do fmt.sbprintf(b, `\u%04x`, r)
		else do strings.write_string(b, s[i:i + w])
		i += w
	}
	strings.write_byte(b, '"')
}

quoted :: proc(s: string) -> string {
	b := strings.builder_make()
	json_quote(&b, s)
	return strings.to_string(b)
}

// A number as JS prints it: integers without a fraction, others shortest.
num_text :: proc(f: f64) -> string {
	if math.is_nan(f) || math.is_inf(f) do return "null"
	if f == math.trunc(f) && abs(f) < 1e15 do return fmt.aprintf("%d", i64(f))
	buf: [64]u8
	return strings.clone(strings.trim_prefix(strconv.write_float(buf[:], f, 'g', -1, 64), "+"))
}

// ---- an object writer ----

JW :: struct {
	b:     strings.Builder,
	first: bool,
}

jw_begin :: proc() -> JW {
	w := JW{b = strings.builder_make(), first = true}
	strings.write_byte(&w.b, '{')
	return w
}
jw_key :: proc(w: ^JW, k: string) {
	if !w.first do strings.write_byte(&w.b, ',')
	w.first = false
	json_quote(&w.b, k)
	strings.write_byte(&w.b, ':')
}
jw_str :: proc(w: ^JW, k, v: string) {jw_key(w, k); json_quote(&w.b, v)}
jw_int :: proc(w: ^JW, k: string, v: i64) {jw_key(w, k); fmt.sbprintf(&w.b, "%d", v)}
jw_num :: proc(w: ^JW, k: string, v: f64) {jw_key(w, k); strings.write_string(&w.b, num_text(v))}
jw_bool :: proc(w: ^JW, k: string, v: bool) {jw_key(w, k); strings.write_string(&w.b, v ? "true" : "false")}
jw_raw :: proc(w: ^JW, k, raw: string) {jw_key(w, k); strings.write_string(&w.b, raw)}
jw_strs :: proc(w: ^JW, k: string, list: []string) {
	jw_key(w, k)
	strings.write_byte(&w.b, '[')
	for s, i in list {
		if i > 0 do strings.write_byte(&w.b, ',')
		json_quote(&w.b, s)
	}
	strings.write_byte(&w.b, ']')
}
jw_end :: proc(w: ^JW) -> string {
	strings.write_byte(&w.b, '}')
	return strings.to_string(w.b)
}

// ---- values Deckhand returned ----

// Compact JSON of a parsed value (object key order is not kept).
json_text :: proc(v: json.Value) -> string {
	b := strings.builder_make()
	json_write_value(&b, v)
	return strings.to_string(b)
}

json_write_value :: proc(b: ^strings.Builder, v: json.Value) {
	switch x in v {
	case json.Null:    strings.write_string(b, "null")
	case json.Integer: fmt.sbprintf(b, "%d", x)
	case json.Float:   strings.write_string(b, num_text(f64(x)))
	case json.Boolean: strings.write_string(b, x ? "true" : "false")
	case json.String:  json_quote(b, string(x))
	case json.Array:
		strings.write_byte(b, '[')
		for e, i in x {
			if i > 0 do strings.write_byte(b, ',')
			json_write_value(b, e)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		i := 0
		for k, e in x {
			if i > 0 do strings.write_byte(b, ',')
			i += 1
			json_quote(b, k)
			strings.write_byte(b, ':')
			json_write_value(b, e)
		}
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

// What JS's String(v ?? "") gives for a scalar ("" for null, missing, arrays and objects).
val_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String:  return string(x)
	case json.Integer: return fmt.aprintf("%d", x)
	case json.Float:   return num_text(f64(x))
	case json.Boolean: return x ? "true" : "false"
	}
	return ""
}

get_obj :: proc(o: json.Object, k: string) -> json.Object {
	if o == nil do return nil
	x, _ := o[k].(json.Object)
	return x
}
get_arr :: proc(o: json.Object, k: string) -> json.Array {
	if o == nil do return nil
	x, _ := o[k].(json.Array)
	return x
}
get_text :: proc(o: json.Object, k: string) -> string {
	if o == nil do return ""
	return val_text(o[k])
}
get_str :: proc(o: json.Object, k: string) -> (string, bool) {
	if o == nil do return "", false
	x, ok := o[k].(json.String)
	return string(x), ok
}
get_num :: proc(o: json.Object, k: string) -> (f64, bool) {
	if o == nil do return 0, false
	#partial switch x in o[k] {
	case json.Integer: return f64(x), true
	case json.Float:   return f64(x), true
	}
	return 0, false
}
get_int :: proc(o: json.Object, k: string) -> (i64, bool) {
	f, ok := get_num(o, k)
	if !ok || f != math.trunc(f) do return 0, false
	return i64(f), true
}
get_bool :: proc(o: json.Object, k: string) -> (val: bool, has: bool) {
	if o == nil do return false, false
	x, ok := o[k].(json.Boolean)
	return bool(x), ok
}
is_true :: proc(o: json.Object, k: string) -> bool {
	v, has := get_bool(o, k)
	return has && v
}
is_false :: proc(o: json.Object, k: string) -> bool {
	v, has := get_bool(o, k)
	return has && !v
}

// Through jg (src/jsonguard, core only): Claude Code's hook input carries what an agent wrote,
// and core:encoding/json crashes on deep nesting and invalid UTF-8.
parse_obj :: proc(s: string) -> (json.Object, bool) {
	v, err := jg.parse_string(s, .JSON, true)
	if err != nil do return nil, false
	o, ok := v.(json.Object)
	return o, ok
}
