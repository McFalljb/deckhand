package pi_desk_cli

// The command line → one pi-desk command. Checked the way pi-kit's desk-browser and desk app
// tools check their parameters, so a bad call gets a clear message without a round trip;
// pi-desk enforces every rule again (who may act on which tab, sensitive fields, uploads…).

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

Kind :: enum {
	Tabs,
	Open,
	Nav,
	Read,
	Shot,
	Wait,
	Console,
	Network,
	Comments,
	Act,
	App_Call,
	App_Shot,
	App_Input,
	App_Events,
	App_Open,
	App_Tab_Op, // app close, app restart
	App_Declared,
	State,
	Show,
}

Req :: struct {
	name:       string, // as the user typed it: "read", "app call"
	type:       string, // pi-desk's command type
	kind:       Kind,
	cmd:        string, // the command object (JSON, one line)
	tab:        i64,
	timeout_ms: int, // how long we wait for its result
	act:        bool, // a browser action (its own hints)
	app:        bool, // an app tab command (app hints, DATA_NOTE)
	// for the output
	wait_for:   string,
	wait_value: string,
	method:     string,
	topic:      string,
	typed:      string, // never echoed
	button:     string,
	double:     bool,
	clear:      bool,
	modifiers:  []string,
	n_events:   int,
}

ACT_TIMEOUT_MS :: 40_000 // pi-desk gives an action 30 s
UPLOAD_TIMEOUT_MS :: 130_000 // pi-desk waits 120 s for the user's Allow
DEFAULT_TIMEOUT_MS :: 30_000
MAX_WAIT_S :: 120.0

Flags :: struct {
	pos:   [dynamic]string,
	vals:  map[string]string,
	bools: map[string]bool,
}

// Splits args into positionals and flags (`--name value`, `--name=value`, boolean `--name`);
// `--` ends the flags; a lone `-` is a positional.
parse_flags :: proc(args: []string, value_flags, bool_flags: []string) -> (f: Flags, err: string) {
	is_in :: proc(list: []string, s: string) -> bool {
		for x in list do if x == s do return true
		return false
	}
	i := 0
	for i < len(args) {
		a := args[i]
		i += 1
		if a == "--" {
			for i < len(args) {
				append(&f.pos, args[i])
				i += 1
			}
			break
		}
		if !strings.has_prefix(a, "--") || len(a) == 2 {
			append(&f.pos, a)
			continue
		}
		name := a[2:]
		val: string
		has_val := false
		if eq := strings.index_byte(name, '='); eq >= 0 {
			name, val, has_val = name[:eq], name[eq + 1:], true
		}
		switch {
		case is_in(value_flags, name):
			if !has_val {
				if i >= len(args) do return f, fmt.aprintf("--%s needs a value", name)
				val = args[i]
				i += 1
			}
			f.vals[name] = val
		case is_in(bool_flags, name):
			if has_val do return f, fmt.aprintf("--%s takes no value", name)
			f.bools[name] = true
		case:
			return f, fmt.aprintf("unknown option --%s", name)
		}
	}
	return f, ""
}

parse_number :: proc(s: string) -> (f64, bool) {
	v, ok := strconv.parse_f64(strings.trim_space(s))
	if !ok || math.is_nan(v) || math.is_inf(v) do return 0, false
	return v, true
}

parse_tab :: proc(s: string, what := "TAB") -> (i64, string) {
	v, ok := strconv.parse_i64_of_base(s, 10)
	if !ok || v <= 0 do return 0, fmt.aprintf("%s must be a tab id (a positive whole number, from `deckhand tabs` or `deckhand state`)", what)
	return v, ""
}

parse_rect :: proc(s: string, what: string) -> (string, string) {
	parts := strings.split(s, ",")
	if len(parts) != 4 do return "", fmt.aprintf("--rect is X,Y,W,H (%s), with a width and a height", what)
	v: [4]f64
	for p, i in parts {
		n, ok := parse_number(p)
		if !ok do return "", fmt.aprintf("--rect is X,Y,W,H (%s), with a width and a height", what)
		v[i] = n
	}
	if v[2] <= 0 || v[3] <= 0 do return "", fmt.aprintf("--rect is X,Y,W,H (%s), with a width and a height", what)
	return fmt.aprintf(`{{"x":%s,"y":%s,"w":%s,"h":%s}}`, num_text(v[0]), num_text(v[1]), num_text(v[2]), num_text(v[3])), ""
}

// A JSON argument made one line: a raw CR or LF in valid JSON can only be whitespace outside a
// string, so it becomes a space (pi-desk's protocol is one message per line).
one_line_json :: proc(s: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(s) {
		c := s[i]
		strings.write_byte(&b, c == '\n' || c == '\r' ? ' ' : c)
	}
	return strings.to_string(b)
}

USAGE :: `usage: deckhand COMMAND [ARGS]   (run inside a Deckhand Claude tab; deckhand --skill for the manual)
  tabs | open URL | navigate TAB URL | back|forward|reload|stop TAB
  read TAB [--mode text|outline|html] [--selector S] [--max N]
  screenshot TAB [--rect X,Y,W,H]
  wait TAB load|selector|text [VALUE] [--timeout SECONDS]
  click TAB [SELECTOR] [--x X --y Y] [--button left|right|middle] [--double] [--modifiers shift,control,alt,meta]
  type TAB TEXT|- [--selector S] [--clear] [--submit]
  press TAB KEYS [--selector S]
  scroll TAB [SELECTOR | --x X --y Y] [--dx N] [--dy N]
  select TAB SELECTOR (--label L | --value V)
  hover TAB (SELECTOR | --x X --y Y)
  upload TAB SELECTOR PATH...
  console TAB [--since N] [--limit N] | network TAB [--since N] [--limit N]
  comments [TAB]
  app call TAB METHOD [PARAMS_JSON] [--timeout SECONDS]
  app screenshot TAB [--rect X,Y,W,H]
  app input TAB EVENTS_JSON
  app events TAB TOPIC [--since N] [--limit N]
  app open NAME [--title T] | app close TAB [--comments send|drop] | app restart TAB | app list-declared
  show PATH [--line N | --anchor HEADING]
  state`

// A selector, or x and y (CSS px from the viewport's top-left); need: one is required.
target :: proc(w: ^JW, selector: string, has_sel: bool, f: ^Flags, need: bool) -> string {
	xs, hx := f.vals["x"]
	ys, hy := f.vals["y"]
	has_xy := hx || hy
	if (has_sel && has_xy) || (need && !has_sel && !has_xy) || (has_xy && !(hx && hy)) {
		return fmt.aprintf("name the target with a SELECTOR or --x and --y (not both): %s; or the page's CSS px from the viewport's top-left", SELECTOR_HELP)
	}
	if has_xy {
		x, okx := parse_number(xs)
		y, oky := parse_number(ys)
		if !okx || !oky || x < 0 || y < 0 do return "--x and --y are the page's CSS px from the viewport's top-left (numbers, 0 or more)"
		jw_num(w, "x", x)
		jw_num(w, "y", y)
		return ""
	}
	if has_sel {
		if strings.trim_space(selector) == "" do return fmt.aprintf("SELECTOR is required: %s", SELECTOR_HELP)
		jw_str(w, "selector", selector)
	}
	return ""
}

opt_since_limit :: proc(w: ^JW, f: ^Flags) -> string {
	if s, has := f.vals["since"]; has {
		n, ok := parse_number(s)
		if !ok || n < 0 do return "--since is a number (the last call's next)"
		if n > 0 do jw_num(w, "since", math.floor(n))
	}
	if s, has := f.vals["limit"]; has {
		n, ok := parse_number(s)
		if !ok || n <= 0 do return "--limit is a positive number"
		jw_num(w, "limit", math.floor(n))
	}
	return ""
}

// Builds the request for args (without the program name). read_stdin: `type TAB -`'s text.
// err: a usage error (exit 2).
parse_cli :: proc(args: []string, read_stdin: proc() -> string = nil) -> (req: Req, err: string) {
	if len(args) == 0 do return req, USAGE
	name := args[0]
	rest := args[1:]
	if name == "app" {
		if len(rest) == 0 do return req, "app needs a subcommand: call, screenshot, input, events, open, close, restart or list-declared"
		name = fmt.aprintf("app %s", rest[0])
		rest = rest[1:]
		req.app = true
	}
	req.name = name
	req.timeout_ms = DEFAULT_TIMEOUT_MS
	w := jw_begin()
	tab_arg :: proc(req: ^Req, w: ^JW, f: ^Flags, at: int) -> string {
		if len(f.pos) <= at do return "TAB (a tab id) is required"
		t, e := parse_tab(f.pos[at])
		if e != "" do return e
		req.tab = t
		jw_int(w, "tab_id", t)
		return ""
	}
	no_more :: proc(f: ^Flags, n: int) -> string {
		if len(f.pos) > n do return fmt.aprintf("unexpected argument %q", f.pos[n])
		return ""
	}
	f: Flags
	e: string
	switch name {
	case "tabs":
		f, e = parse_flags(rest, nil, nil)
		if e == "" do e = no_more(&f, 0)
		req.type, req.kind = "browser_tabs", .Tabs
	case "open":
		f, e = parse_flags(rest, nil, nil)
		req.type, req.kind = "browser_open", .Open
		if e == "" && (len(f.pos) < 1 || strings.trim_space(f.pos[0]) == "") do e = "URL is required (http, https, or a bare host such as example.com; localhost gets http://)"
		if e == "" do e = no_more(&f, 1)
		if e == "" do jw_str(&w, "url", f.pos[0])
	case "navigate":
		f, e = parse_flags(rest, nil, nil)
		req.type, req.kind = "browser_navigate", .Nav
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" && (len(f.pos) < 2 || strings.trim_space(f.pos[1]) == "") do e = "URL is required"
		if e == "" do e = no_more(&f, 2)
		if e == "" do jw_str(&w, "url", f.pos[1])
	case "back", "forward", "reload", "stop":
		f, e = parse_flags(rest, nil, nil)
		req.type, req.kind = fmt.aprintf("browser_%s", name), .Nav
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 1)
	case "read":
		f, e = parse_flags(rest, {"mode", "selector", "max"}, nil)
		req.type, req.kind = "browser_read", .Read
		req.timeout_ms = 60_000
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 1)
		if e == "" {
			if m, has := f.vals["mode"]; has {
				if m != "text" && m != "outline" && m != "html" do e = "--mode is one of text, outline, html"
				else do jw_str(&w, "mode", m)
			}
		}
		if e == "" {
			if s, has := f.vals["selector"]; has {
				if strings.trim_space(s) == "" do e = fmt.aprintf("--selector must be %s", SELECTOR_HELP)
				else do jw_str(&w, "selector", s)
			}
		}
		if e == "" {
			if s, has := f.vals["max"]; has {
				n, ok := parse_number(s)
				if !ok || n <= 0 do e = "--max must be a positive number of characters"
				else do jw_num(&w, "max", min(math.floor(n), TEXT_MAX))
			}
		}
	case "screenshot", "app screenshot":
		f, e = parse_flags(rest, {"rect"}, nil)
		req.kind = name == "screenshot" ? .Shot : .App_Shot
		req.type = name == "screenshot" ? "browser_screenshot" : "app_screenshot"
		req.timeout_ms = 40_000
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 1)
		if e == "" {
			if s, has := f.vals["rect"]; has {
				r, re := parse_rect(s, name == "screenshot" ? "the page's CSS px" : "the tab's logical px")
				if re != "" do e = re
				else do jw_raw(&w, "rect", r)
			}
		}
	case "wait":
		f, e = parse_flags(rest, {"timeout"}, nil)
		req.type, req.kind = "browser_wait", .Wait
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" {
			if len(f.pos) < 2 || (f.pos[1] != "load" && f.pos[1] != "selector" && f.pos[1] != "text") do e = "wait TAB load|selector|text [VALUE]"
		}
		if e == "" {
			req.wait_for = f.pos[1]
			jw_str(&w, "for", req.wait_for)
			if req.wait_for != "load" {
				if len(f.pos) < 3 || f.pos[2] == "" {
					e = fmt.aprintf("VALUE is required for %q (%s)", req.wait_for, req.wait_for == "selector" ? fmt.aprintf("the selector to wait for: %s", SELECTOR_HELP) : "the text to wait for")
				} else {
					req.wait_value = f.pos[2]
					jw_str(&w, "value", req.wait_value)
					e = no_more(&f, 3)
				}
			} else {
				e = no_more(&f, 2)
			}
		}
		if e == "" {
			secs := 10.0
			if s, has := f.vals["timeout"]; has {
				n, ok := parse_number(s)
				if !ok do e = "--timeout is seconds (a number)"
				else do secs = clamp(n, 0.1, MAX_WAIT_S)
			}
			ms := int(math.round(secs * 1000))
			jw_int(&w, "timeout_ms", i64(ms))
			req.timeout_ms = ms + 5000
		}
	case "console", "network":
		f, e = parse_flags(rest, {"since", "limit"}, nil)
		req.type = fmt.aprintf("browser_%s", name)
		req.kind = name == "console" ? .Console : .Network
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 1)
		if e == "" do e = opt_since_limit(&w, &f)
	case "comments":
		f, e = parse_flags(rest, nil, nil)
		req.type, req.kind = "browser_comments", .Comments
		if e == "" && len(f.pos) > 0 do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 1)
	case "click":
		f, e = parse_flags(rest, {"x", "y", "button", "modifiers"}, {"double"})
		req.type, req.kind, req.act, req.timeout_ms = "browser_click", .Act, true, ACT_TIMEOUT_MS
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 2)
		if e == "" do e = target(&w, len(f.pos) > 1 ? f.pos[1] : "", len(f.pos) > 1, &f, true)
		if e == "" {
			if b, has := f.vals["button"]; has {
				if b != "left" && b != "right" && b != "middle" do e = "--button is one of left, right, middle"
				else {
					req.button = b
					jw_str(&w, "button", b)
				}
			}
		}
		if e == "" && f.bools["double"] {
			req.double = true
			jw_bool(&w, "double", true)
		}
		if e == "" {
			if m, has := f.vals["modifiers"]; has {
				mods := make([dynamic]string)
				for x in strings.split(m, ",") {
					s := strings.trim_space(x)
					if s == "" do continue
					if s != "shift" && s != "control" && s != "alt" && s != "meta" {
						e = "--modifiers are shift, control, alt, meta (comma-separated)"
						break
					}
					append(&mods, s)
				}
				if e == "" && len(mods) > 0 {
					req.modifiers = mods[:]
					jw_strs(&w, "modifiers", mods[:])
				}
			}
		}
	case "type":
		f, e = parse_flags(rest, {"selector"}, {"clear", "submit"})
		req.type, req.kind, req.act, req.timeout_ms = "browser_type", .Act, true, ACT_TIMEOUT_MS
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 2)
		if e == "" {
			text := len(f.pos) > 1 ? f.pos[1] : ""
			if text == "-" {
				text = read_stdin != nil ? read_stdin() : ""
				text = strings.trim_suffix(text, "\n")
				text = strings.trim_suffix(text, "\r")
			}
			if text == "" && !f.bools["clear"] do e = "TEXT is required (empty only with --clear, to empty the field; - reads it from stdin)"
			else {
				req.typed = text
				jw_str(&w, "text", text)
			}
		}
		if e == "" {
			if s, has := f.vals["selector"]; has {
				if strings.trim_space(s) == "" do e = fmt.aprintf("--selector must be %s", SELECTOR_HELP)
				else do jw_str(&w, "selector", s)
			}
		}
		if e == "" && f.bools["clear"] {
			req.clear = true
			jw_bool(&w, "clear", true)
		}
		if e == "" && f.bools["submit"] do jw_bool(&w, "submit", true)
	case "press":
		f, e = parse_flags(rest, {"selector"}, nil)
		req.type, req.kind, req.act, req.timeout_ms = "browser_press", .Act, true, ACT_TIMEOUT_MS
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 2)
		if e == "" {
			keys := make([dynamic]string)
			if len(f.pos) > 1 do for k in strings.fields(f.pos[1]) do append(&keys, k)
			if len(keys) == 0 do e = `KEYS is required: space-separated keys or chords, e.g. "Tab", "Shift+Tab", "ArrowDown ArrowDown Enter"`
			for k in keys {
				if k == "+" do continue
				for part in strings.split(k, "+") do if part == "" {
					e = fmt.aprintf("KEYS: %q has an empty key in a chord (e.g. \"Shift+Tab\")", f.pos[1])
				}
			}
			if e == "" do jw_str(&w, "keys", strings.join(keys[:], " "))
		}
		if e == "" {
			if s, has := f.vals["selector"]; has {
				if strings.trim_space(s) == "" do e = fmt.aprintf("--selector must be %s", SELECTOR_HELP)
				else do jw_str(&w, "selector", s)
			}
		}
	case "scroll":
		f, e = parse_flags(rest, {"x", "y", "dx", "dy"}, nil)
		req.type, req.kind, req.act, req.timeout_ms = "browser_scroll", .Act, true, ACT_TIMEOUT_MS
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 2)
		if e == "" do e = target(&w, len(f.pos) > 1 ? f.pos[1] : "", len(f.pos) > 1, &f, false)
		_, hdx := f.vals["dx"]
		_, hdy := f.vals["dy"]
		for k in ([]string{"dx", "dy"}) {
			if e != "" do break
			if s, has := f.vals[k]; has {
				n, ok := parse_number(s)
				if !ok do e = "--dx and --dy are CSS px (numbers)"
				else do jw_num(&w, k, n)
			}
		}
		if e == "" && len(f.pos) < 2 && !("x" in f.vals) && !hdx && !hdy do e = "give --dx or --dy (CSS px) to scroll by, and/or a target (SELECTOR, or --x and --y) to scroll into view or to scroll in"
	case "select":
		f, e = parse_flags(rest, {"label", "value"}, nil)
		req.type, req.kind, req.act, req.timeout_ms = "browser_select", .Act, true, ACT_TIMEOUT_MS
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 2)
		if e == "" && (len(f.pos) < 2 || strings.trim_space(f.pos[1]) == "") do e = fmt.aprintf("SELECTOR is required (the <select>): %s", SELECTOR_HELP)
		if e == "" do jw_str(&w, "selector", f.pos[1])
		if e == "" {
			l, hl := f.vals["label"]
			v, hv := f.vals["value"]
			if hl == hv || (hl && l == "") do e = "give exactly one of --label or --value (label: the option's text)"
			else if hl do jw_str(&w, "label", l)
			else do jw_str(&w, "value", v)
		}
	case "hover":
		f, e = parse_flags(rest, {"x", "y"}, nil)
		req.type, req.kind, req.act, req.timeout_ms = "browser_hover", .Act, true, ACT_TIMEOUT_MS
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 2)
		if e == "" do e = target(&w, len(f.pos) > 1 ? f.pos[1] : "", len(f.pos) > 1, &f, true)
	case "upload":
		f, e = parse_flags(rest, nil, nil)
		req.type, req.kind, req.act, req.timeout_ms = "browser_upload", .Act, true, UPLOAD_TIMEOUT_MS
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" && (len(f.pos) < 2 || strings.trim_space(f.pos[1]) == "") do e = fmt.aprintf("SELECTOR is required (the file input): %s", SELECTOR_HELP)
		if e == "" && len(f.pos) < 3 do e = "PATH is required: absolute paths of regular files"
		if e == "" {
			jw_str(&w, "selector", f.pos[1])
			for p in f.pos[2:] do if !strings.has_prefix(p, "/") do e = "each PATH must be an absolute path (e.g. /Users/me/report.pdf)"
			if e == "" do jw_strs(&w, "paths", f.pos[2:])
		}
	case "app call":
		f, e = parse_flags(rest, {"timeout"}, nil)
		req.type, req.kind = "app_call", .App_Call
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" && (len(f.pos) < 2 || strings.trim_space(f.pos[1]) == "") do e = `METHOD is required: the app's own method name; call "tab.describe" first to list them`
		if e == "" {
			req.method = f.pos[1]
			jw_str(&w, "method", req.method)
			e = no_more(&f, 3)
		}
		if e == "" && len(f.pos) > 2 {
			if o, ok := parse_obj(f.pos[2]); !ok || o == nil do e = "PARAMS_JSON must be a JSON object"
			else do jw_raw(&w, "params", one_line_json(f.pos[2]))
		}
		req.timeout_ms = 10_000 + 5000
		if e == "" {
			if s, has := f.vals["timeout"]; has {
				n, ok := parse_number(s)
				if !ok do e = "--timeout is seconds (a number)"
				else {
					ms := i64(clamp(n, 1, 600)) * 1000
					jw_int(&w, "timeout_ms", ms)
					req.timeout_ms = int(ms) + 5000
				}
			}
		}
	case "app input":
		f, e = parse_flags(rest, nil, nil)
		req.type, req.kind = "app_input", .App_Input
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 2)
		if e == "" {
			bad := `EVENTS_JSON must be a non-empty list of input objects, e.g. [{"event":"key","action":"down","key":"w"}]`
			if len(f.pos) < 2 do e = bad
			else {
				v, perr := json.parse_string(f.pos[1], .JSON, true)
				arr, is_arr := v.(json.Array)
				if perr != nil || !is_arr || len(arr) == 0 do e = bad
				for ev in arr {
					if e != "" do break
					o, is_o := ev.(json.Object)
					if !is_o do e = `each event must be an object with "event" (key, char, mouse, move, scroll, focus)`
					else if _, s := o["event"].(json.String); !s do e = `each event must be an object with "event" (key, char, mouse, move, scroll, focus)`
					else do for k in ([]string{"type", "v", "id", "source"}) do if k in o do e = fmt.aprintf("an event cannot set %q (Deckhand's envelope)", k)
				}
				if e == "" {
					req.n_events = len(arr)
					jw_raw(&w, "events", one_line_json(f.pos[1]))
				}
			}
		}
	case "app events":
		f, e = parse_flags(rest, {"since", "limit"}, nil)
		req.type, req.kind = "app_events", .App_Events
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" && (len(f.pos) < 2 || f.pos[1] == "") do e = `TOPIC is required, e.g. "log" (tab.log)`
		if e == "" {
			req.topic = f.pos[1]
			jw_str(&w, "topic", req.topic)
			e = no_more(&f, 2)
		}
		if e == "" do e = opt_since_limit(&w, &f)
	case "app open":
		f, e = parse_flags(rest, {"title"}, nil)
		req.type, req.kind = "new_app_tab", .App_Open
		if e == "" && (len(f.pos) < 1 || strings.trim_space(f.pos[0]) == "") do e = "NAME is required: an app your project declares in .pi-desk/apps.json (`deckhand app list-declared`)"
		if e == "" do e = no_more(&f, 1)
		if e == "" {
			jw_str(&w, "name", f.pos[0])
			if s, has := f.vals["title"]; has do jw_str(&w, "title", s)
		}
	case "app close", "app restart":
		f, e = parse_flags(rest, name == "app close" ? {"comments"} : nil, nil)
		req.type, req.kind = name == "app close" ? "app_close" : "app_restart", .App_Tab_Op
		if e == "" do e = tab_arg(&req, &w, &f, 0)
		if e == "" do e = no_more(&f, 1)
		if e == "" {
			if s, has := f.vals["comments"]; has {
				if s != "send" && s != "drop" do e = "--comments is send or drop"
				else do jw_str(&w, "comments", s)
			}
		}
	case "app list-declared":
		f, e = parse_flags(rest, nil, nil)
		if e == "" do e = no_more(&f, 0)
		req.type, req.kind = "app_declared", .App_Declared
	case "show":
		f, e = parse_flags(rest, {"line", "anchor"}, nil)
		req.type, req.kind = "show_file", .Show
		if e == "" && (len(f.pos) < 1 || strings.trim_space(f.pos[0]) == "") do e = "PATH is required: the file to show the user (absolute, or relative to your session's folder)"
		if e == "" do e = no_more(&f, 1)
		if e == "" do jw_str(&w, "path", f.pos[0])
		if e == "" {
			if s, has := f.vals["line"]; has {
				n, ok := strconv.parse_i64_of_base(strings.trim_space(s), 10)
				if !ok || n < 1 || n > 1 << 30 do e = "--line is a line number (1 or more)"
				else do jw_int(&w, "line", n)
			}
		}
		if e == "" {
			if s, has := f.vals["anchor"]; has {
				if "line" in f.vals do e = "give --line or --anchor, not both (--anchor: a Markdown heading id)"
				else if strings.trim_space(strings.trim_prefix(s, "#")) == "" do e = "--anchor is a Markdown heading id (e.g. setup for ## Setup)"
				else do jw_str(&w, "anchor", s)
			}
		}
	case "state":
		f, e = parse_flags(rest, nil, nil)
		if e == "" do e = no_more(&f, 0)
		req.type, req.kind = "get_state", .State
	case:
		if req.app do return req, "app subcommands: call, screenshot, input, events, open, close, restart, list-declared"
		return req, fmt.aprintf("unknown command %q\n%s", name, USAGE)
	}
	if e != "" do return req, e
	body := strings.to_string(w.b)
	// the type first, then the fields written above
	cmd := strings.builder_make()
	fmt.sbprintf(&cmd, `{{"type":%s`, quoted(req.type))
	if len(body) > 1 {
		strings.write_byte(&cmd, ',')
		strings.write_string(&cmd, body[1:])
	}
	strings.write_byte(&cmd, '}')
	req.cmd = strings.to_string(cmd)
	return req, ""
}
