package core

// Hand-written JSON encoding for the wire schema in docs/PROTOCOL.md:
// commands and results with an explicit "type" tag, events, the state
// snapshot and reply envelopes. Odin's default marshalling is not used for
// any of these (it does not tag union variants).

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"

PROTOCOL_VERSION :: 1

// ---- writer helpers ----

Jw :: struct {
	b:     ^strings.Builder,
	first: bool,
}

json_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case 0 ..< 0x20, 0x7f, 0x2028, 0x2029:
			fmt.sbprintf(b, `\u%04x`, int(r))
		case:
			strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}

@(private = "file")
obj_begin :: proc(b: ^strings.Builder) -> Jw {
	strings.write_byte(b, '{')
	return {b = b, first = true}
}
@(private = "file")
obj_end :: proc(w: ^Jw) {strings.write_byte(w.b, '}')}
@(private = "file")
key :: proc(w: ^Jw, k: string) {
	if !w.first do strings.write_byte(w.b, ',')
	w.first = false
	json_quote(w.b, k)
	strings.write_byte(w.b, ':')
}
@(private = "file")
kv_str :: proc(w: ^Jw, k, v: string) {key(w, k); json_quote(w.b, v)}
@(private = "file")
kv_u64 :: proc(w: ^Jw, k: string, v: u64) {key(w, k); strings.write_u64(w.b, v)}
@(private = "file")
kv_bool :: proc(w: ^Jw, k: string, v: bool) {key(w, k); strings.write_string(w.b, v ? "true" : "false")}
@(private = "file")
kv_f32 :: proc(w: ^Jw, k: string, v: f32) {
	key(w, k)
	buf: [32]u8
	strings.write_string(w.b, strings.trim_prefix(strconv.write_float(buf[:], f64(v), 'g', -1, 32), "+"))
}

// ---- enum names on the wire ----

CALLER_NAMES := [Caller_Kind]string {
	.None     = "none",
	.Internal = "internal",
	.UI       = "ui",
	.Script   = "script",
	.Control  = "control",
	.Panel    = "panel",
	.App      = "app",
	.Tab_Host = "tab_host",
}
CLASS_NAMES := [Command_Class]string {
	.Tab_Close       = "tab_close",
	.Session_Restart = "session_restart",
	.Settings_Write  = "settings_write",
	.App_Quit        = "app_quit",
	.Delete          = "delete",
	.Fs_Write        = "fs_write",
	.Open_Link       = "open_link",
}
MODE_NAMES := [Confirm_Mode]string {
	.Ask     = "ask",
	.Trusted = "trusted",
	.Auto    = "auto",
}
CLOSE_NAMES := [Close_Confirm]string {
	.Auto   = "auto",
	.Always = "always",
	.Never  = "never",
}
AGENT_NAMES := [Agent_State]string {
	.Unknown = "unknown",
	.Idle    = "idle",
	.Working = "working",
	.Error   = "error",
}
TONE_NAMES := [Panel_Tone]string {
	.Normal  = "",
	.Accent  = "accent",
	.Muted   = "muted",
	.Dim     = "dim",
	.Warning = "warning",
	.Success = "success",
	.Error   = "error",
}
TAB_STATUS_NAMES := [Tab_Status]string {
	.Running     = "running",
	.Exited      = "exited",
	.Not_Started = "not_started",
}
TAB_KIND_NAMES := [Tab_Kind_Id]string {
	.Pi     = "pi",
	.Shell  = "shell",
	.Editor = "editor",
	.Changes = "changes",
	.Markdown = "markdown",
	.Browser = "browser",
	.App = "app",
	.Claude = "claude",
}
SORT_SECTION_NAMES := [Sort_Section]string {
	.Projects = "projects",
	.Sessions = "sessions",
	.Chats    = "chats",
}
SORT_BY_NAMES := [Sort_By]string {
	.Recent  = "recent",
	.Name    = "name",
	.Created = "created",
	.Attention = "attention",
}
SIDEBAR_VIEW_NAMES := [Sidebar_View]string {
	.Projects  = "projects",
	.Attention = "attention",
}
FOLD_NAMES := [Sidebar_Fold]string {
	.Open     = "open",
	.Projects = "projects",
	.Chats    = "chats",
	.This_Mac = "this_mac",
	.Usage    = "usage",
}

// ---- commands ----

command_type :: proc(cmd: Command) -> string {
	info := command_info(cmd)
	return info == nil ? "" : info.name
}

// A pi tab's blocker as events and the log show it: "shell sh1" and "timer wk2" (the bridge's
// "<kind> <id>: <text>"), "subagent", else "<redacted>" (temp-allocated).
blocker_redacted :: proc(b: string) -> string {
	head, sep, _ := strings.partition(b, ": ")
	kind, _, id := strings.partition(head, " ")
	if sep != "" && (kind == "shell" || kind == "timer") && id != "" && !strings.contains_any(id, " :") do return strings.concatenate({kind, " ", id}, context.temp_allocator)
	if strings.has_prefix(b, "subagent ") || b == "subagent" do return "subagent"
	return "<redacted>"
}

// Which of a command's encodings (command_codec.odin): the log's (and the events'), the same
// redacted, the window's to its core.
Cmd_Mode :: enum u8 {
	Log,
	Red,
	Wire,
}

// redact: for events and logs. Pasted text becomes its length, tokens vanish.
write_command :: proc(b: ^strings.Builder, cmd: Command, redact := false) {
	cmd_write(b, cmd, redact ? .Red : .Log)
}

@(private = "file")
cmd_write :: proc(b: ^strings.Builder, cmd: Command, mode: Cmd_Mode) {
	w := obj_begin(b)
	info := command_info(cmd)
	kv_str(&w, "type", info == nil ? "" : info.name)
	if info != nil && !write_command_hook(&w, cmd, mode) {
		c := cmd
		// `last` fields after the rest; on the wire, what the log leaves out after those
		for pass in 0 ..< 3 do for &f in info.fields {
			p := mode == .Wire && f.log.tx == .Drop ? 2 : (f.last ? 1 : 0)
			if p == pass do cmd_write_field(&w, info, &f, &c, mode)
		}
	}
	obj_end(&w)
}

// One field as its tag says (command_codec.odin).
@(private = "file")
cmd_write_field :: proc(w: ^Jw, info: ^Cmd_Info, f: ^Cmd_Field, cmd: ^Command, mode: Cmd_Mode) {
	if f.skip || (f.ui && mode != .Wire) do return // ui: only on the wire, whatever red= says
	data := rawptr(uintptr(cmd) + f.offset)
	t: Cmd_Transform
	if mode != .Wire || !f.full {
		t = f.log
		if mode == .Red && f.red.tx != .None do t = f.red
	}
	if t.tx == .Drop do return
	if f.omit && cmd_is_zero(data, f.ti) do return
	ti := f.ti
	if u, is := runtime.type_info_base(ti).variant.(runtime.Type_Info_Union); is && len(u.variants) == 1 && !u.no_nil { // Maybe(T): unset is left out
		if reflect.get_union_variant_raw_tag(any{data, ti.id}) == 0 do return
		ti = u.variants[0]
	}
	if f.nonneg && wire_int(data, ti.size) < 0 do return
	if t.tx == .None && f.codec != "" && cmd_write_codec(w, info, f, data, cmd, mode) do return
	switch t.tx {
	case .None, .Drop:
		key(w, f.key)
		cmd_write_value(w.b, f, data, ti)
	case .Bytes: kv_str(w, f.key, fmt.tprintf("<redacted %d bytes>", cmd_len(data, ti)))
	case .Len:   kv_u64(w, t.arg != "" ? t.arg : f.key, u64(cmd_len(data, ti)))
	case .Token: kv_str(w, f.key, "<redacted>")
	case .Url:   kv_str(w, f.key, browser_url_redacted((^string)(data)^))
	case .Path:  kv_str(w, f.key, "<path>")
	case .Items: kv_str(w, f.key, fmt.tprintf("<redacted %d %s>", cmd_len(data, ti), t.arg))
	case .Cut:   kv_str(w, f.key, cut_utf8((^string)(data)^, t.n))
	case .F3:
		key(w, f.key)
		fmt.sbprintf(w.b, "%.3f", (^f32)(data)^)
	case .Blockers:
		list := (^[]string)(data)^
		masked := make([]string, len(list), context.temp_allocator)
		for x, i in list do masked[i] = blocker_redacted(x)
		key(w, f.key)
		write_strings(w.b, masked)
	}
}

// A string's bytes, a list's items.
@(private = "file")
cmd_len :: proc(data: rawptr, ti: ^runtime.Type_Info) -> int {
	#partial switch _ in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_String:        return len((^string)(data)^)
	case runtime.Type_Info_Slice:         return (^runtime.Raw_Slice)(data).len
	case runtime.Type_Info_Dynamic_Array: return (^runtime.Raw_Dynamic_Array)(data).len
	}
	return 0
}

@(private = "file")
cmd_write_value :: proc(b: ^strings.Builder, f: ^Cmd_Field, data: rawptr, ti: ^runtime.Type_Info) {
	#partial switch t in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		if !t.signed do strings.write_u64(b, wire_uint(data, ti.size))
		else if f.pos do strings.write_i64(b, max(wire_int(data, ti.size), 0))
		else if f.signed do strings.write_i64(b, wire_int(data, ti.size))
		else do strings.write_u64(b, u64(wire_int(data, ti.size)))
	case runtime.Type_Info_Float:
		buf: [32]u8
		x := ti.size == 4 ? f64((^f32)(data)^) : (^f64)(data)^
		strings.write_string(b, strings.trim_prefix(strconv.write_float(buf[:], x, 'g', -1, ti.size * 8), "+"))
	case runtime.Type_Info_Boolean:
		strings.write_string(b, wire_uint(data, ti.size) != 0 ? "true" : "false")
	case runtime.Type_Info_String:
		json_quote(b, (^string)(data)^)
	case runtime.Type_Info_Enum:
		x := wire_int(data, ti.size)
		if f.names != nil {
			i := x - f.names_min
			json_quote(b, i >= 0 && i < i64(len(f.names)) ? f.names[i] : "")
			return
		}
		wire_write(b, data, ti)
	case runtime.Type_Info_Slice:
		if t.elem.id == typeid_of(string) {
			write_strings(b, (^[]string)(data)^)
			return
		}
		wire_write(b, data, ti)
	case:
		wire_write(b, data, ti)
	}
}

command_json :: proc(cmd: Command, redact := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_command(&b, cmd, redact)
	return strings.to_string(b)
}

// A command as the window sends it to its core (window_link.odin; design §10.2, M3-F): what
// parse_command_ui reads back into the same command. command_json is the log's and the events'
// encoding, which writes counts for lists, leaves out tokens and limits and never writes the
// UI-only fields; this one writes every field (the `full` and `ui` ones of command_codec.odin).
// Temp allocator. Never logged or sent to an agent.
command_wire_json :: proc(cmd: Command) -> string {
	b := strings.builder_make(context.temp_allocator)
	cmd_write(&b, cmd, .Wire)
	return strings.to_string(b)
}

// A field written by hand (its tag's codec=); false: as any other.
@(private = "file")
cmd_write_codec :: proc(w: ^Jw, info: ^Cmd_Info, f: ^Cmd_Field, data: rawptr, cmd: ^Command, mode: Cmd_Mode) -> bool {
	sib :: proc(info: ^Cmd_Info, cmd: ^Command, name: string, $T: typeid) -> T {return (^T)(cmd_sibling(info, cmd, name))^}
	switch f.codec {
	case "inverse": kv_bool(w, f.key, !(^bool)(data)^) // no_focus as focus
	case "harness_ct": // a Claude command's harness: "codex" or nothing (Claude's wire is unchanged)
		if harness_is_codex((^Harness)(data)^) do kv_str(w, f.key, "codex")
	case "images": write_prompt_images(w.b, (^[]Prompt_Image)(data)^)
	case "rows":
		key(w, f.key)
		write_rows(w.b, (^[]Panel_Row)(data)^)
	case "raw_list": // each a JSON object (get_raw_list)
		key(w, f.key)
		strings.write_byte(w.b, '[')
		for e, i in (^[]string)(data)^ {
			if i > 0 do strings.write_byte(w.b, ',')
			strings.write_string(w.b, e)
		}
		strings.write_byte(w.b, ']')
	case "raw": // app_call's params: a JSON object as the caller wrote it
		x := (^string)(data)^
		if mode == .Red do kv_u64(w, "params_bytes", u64(len(x)))
		else if x != "" {
			key(w, f.key)
			strings.write_string(w.b, x)
		}
	case "rect":
		if !sib(info, cmd, "has_rect", bool) do return true
		r := (^App_Rect)(data)^
		key(w, f.key)
		fmt.sbprintf(w.b, `{{"x":%v,"y":%v,"w":%v,"h":%v}}`, r.x, r.y, r.w, r.h)
	case "act_target": // its fields beside the command's
		tg := (^Act_Target)(data)^
		if tg.selector != "" do kv_str(w, "selector", tg.selector)
		if tg.has_xy {
			key(w, "x")
			fmt.sbprintf(w.b, "%v", tg.x)
			key(w, "y")
			fmt.sbprintf(w.b, "%v", tg.y)
		}
	case "mods": // the log: CDP's bits; the wire: their names
		m := (^int)(data)^
		if mode != .Wire {
			key(w, f.key)
			fmt.sbprintf(w.b, "%d", m)
			return true
		}
		names := make([dynamic]string, context.temp_allocator)
		for n, i in ACT_MOD_NAMES do if m & (1 << uint(i)) != 0 do append(&names, n)
		key(w, f.key)
		write_strings(w.b, names[:])
	case "xy": // devtools' point: both or neither
		x, y := sib(info, cmd, "x", i32), sib(info, cmd, "y", i32)
		if f.name == "x" && x >= 0 && y >= 0 {
			kv_u64(w, "x", u64(x))
			kv_u64(w, "y", u64(y))
		}
	case "has": // browser_select's label and value: when given
		if sib(info, cmd, strings.concatenate({"has_", f.name}, context.temp_allocator), bool) do kv_str(w, f.key, (^string)(data)^)
	case "exit": // a crash or a hangup (dead_tab.odin)
		if how := exit_text((^Exit_Info)(data)^); how != "" do kv_str(w, f.key, how)
	case "job_finished":
		j := (^Job_Finished)(data)^
		kv_str(w, "job_id", j.job_id)
		kv_str(w, "status", JOB_STATUS_NAMES[j.status])
	case "exit_code": if sib(info, cmd, "status", App_Status) == .Exited do kv_u64(w, f.key, u64(max((^int)(data)^, 0)))
	case "ok_if_empty": kv_bool(w, f.key, (^string)(data)^ == "")
	case "wait_value": // a waited-for text may be what the user typed into the page: its length only
		if mode == .Red && sib(info, cmd, "what", string) == "text" do kv_u64(w, "value_bytes", u64(len((^string)(data)^)))
		else do kv_str(w, f.key, (^string)(data)^)
	case "app_argv": // the log: how many words (the command line is one), never which
		argv := (^[]string)(data)^
		if mode == .Red do kv_u64(w, "argc", u64(len(argv) + (sib(info, cmd, "command", string) != "" ? 1 : 0)))
		else {
			key(w, f.key)
			write_strings(w.b, argv)
		}
	case "delete_path": // path, unless only paths are given
		if (^string)(data)^ != "" || len(sib(info, cmd, "paths", []string)) == 0 do kv_str(w, f.key, (^string)(data)^)
	case "files": // how many files changed (the list is capped: more)
		key(w, f.key)
		strings.write_int(w.b, len((^[]string)(data)^) + sib(info, cmd, "more", int))
	case "prog_summary": // what the program said, not its title or message (untrusted text; the snapshot has them)
		p := (^Prog_Summary)(data)^
		kv_str(w, "state", PROG_STATE_NAMES[p.state])
		if p.kind != .None do kv_str(w, "kind", PROG_KIND_NAMES[p.kind])
		if p.app != "" do kv_str(w, "app", p.app)
		kv_u64(w, "records", u64(p.records))
	case "bell_macos": bell_write(w, f.key, (^[Bell_Group]Maybe(Os_When))(data)^, OS_WHEN_NAMES)
	case "bell_sound": bell_write(w, f.key, (^[Bell_Group]Maybe(Bell_Sound))(data)^, BELL_SOUND_NAMES)
	case: return false
	}
	return true
}

// {"macos":{"waiting":"always"},"sound":{"waiting":"tink"}}: the groups set
@(private = "file")
bell_write :: proc(w: ^Jw, k: string, vals: [Bell_Group]Maybe($E), names: [E]string) {
	n := 0
	for v, g in vals do if x, set := v.?; set {
		if n == 0 do fmt.sbprintf(w.b, `,"%s":{{`, k)
		else do strings.write_byte(w.b, ',')
		fmt.sbprintf(w.b, `"%s":"%s"`, BELL_GROUP_NAMES[g], names[x] != "" ? names[x] : "default")
		n += 1
	}
	if n > 0 do strings.write_byte(w.b, '}')
}

// The commands whose JSON no tag can say: written here (true), after "type".
@(private = "file")
write_command_hook :: proc(w: ^Jw, cmd: Command, mode: Cmd_Mode) -> bool {
	#partial switch c in cmd {
	case New_Claude_Session: // the log's order is not the wire's
		if mode == .Wire do return false
		kv_u64(w, "project_id", c.project_id)
		if harness_is_codex(c.harness) do kv_str(w, "harness", "codex")
		if c.account != "" do kv_str(w, "account", c.account)
		if c.cwd != "" do kv_str(w, "cwd", c.cwd)
		if len(c.args) > 0 do kv_u64(w, "argc", u64(len(c.args)))
	case Browser_Update: // what changed (what)
		kv_u64(w, "tab_id", c.tab_id)
		if .Url in c.what do kv_str(w, "url", mode == .Red ? browser_url_redacted(c.url) : c.url)
		if .Title in c.what do kv_str(w, "title", c.title)
		if .Nav in c.what {
			kv_bool(w, "loading", c.loading)
			kv_bool(w, "can_back", c.can_back)
			kv_bool(w, "can_forward", c.can_forward)
		}
		if .Blocked in c.what do kv_str(w, "blocked_popup", mode == .Red ? browser_url_redacted(c.blocked) : c.blocked)
	case Restore_Session:
		kv_u64(w, "project_id", c.project_id)
		kv_str(w, "pi_session_id", c.pi_session_id)
		kv_str(w, "session_dir", c.session_dir)
		if c.cwd != "" do kv_str(w, "cwd", c.cwd)
		if c.agent == .Claude do kv_str(w, "agent", "claude")
		key(w, "tabs")
		strings.write_byte(w.b, '[')
		for t, i in c.tabs {
			if i > 0 do strings.write_byte(w.b, ',')
			o := obj_begin(w.b)
			kv_str(&o, "kind", TAB_KIND_NAMES[t.kind])
			kv_str(&o, "title", t.title)
			kv_str(&o, "cwd", mode == .Red && t.kind == .Browser ? browser_url_redacted(t.cwd) : t.cwd) // a browser tab's: its URL
			if t.active do kv_bool(&o, "active", true)
			if len(c.layout.nodes) > 0 {
				if pn, ok := t.pane.?; ok { // its saved pane (left out: not known)
					key(&o, "pane")
					strings.write_int(w.b, pn)
				}
				if t.pane_active do kv_bool(&o, "pane_active", true)
			}
			obj_end(&o)
		}
		strings.write_byte(w.b, ']')
		if len(c.layout.nodes) > 0 {
			// the saved panes (persist.odin panes_parse): the tree in pre-order, the pi tab's pane (left out: not known)
			if pn, ok := c.pi_pane.?; ok && c.agent != .Claude {
				key(w, "pi_pane")
				strings.write_int(w.b, pn)
			}
			key(w, "panes")
			lo := obj_begin(w.b)
			kv_u64(&lo, "count", u64(c.layout.panes))
			kv_u64(&lo, "focused", u64(c.layout.focused))
			key(&lo, "tree")
			strings.write_byte(w.b, '[')
			for n, i in c.layout.nodes {
				if i > 0 do strings.write_byte(w.b, ',')
				if n.leaf do fmt.sbprintf(w.b, `{{"pane":%d}}`, n.pane)
				else do fmt.sbprintf(w.b, `{{"split":"%s","ratio":%.3f,"a":%d,"b":%d}}`, n.dir == .Right ? "right" : "down", n.ratio, n.a, n.b)
			}
			strings.write_byte(w.b, ']')
			obj_end(&lo)
		}
		if c.home do kv_bool(w, "home", true)
	case:
		return false
	}
	return true
}

// get_state's pending_confirmations: each one's question, who asked, its class and its command
// (redacted: no token).
write_pending_confirmations :: proc(b: ^strings.Builder, list: []Pending_Confirmation) {
	strings.write_byte(b, '[')
	for p, i in list {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_str(&o, "summary", p.summary)
		kv_str(&o, "caller", caller_kind_name(p.caller.kind))
		kv_str(&o, "class", CLASS_NAMES[p.class])
		kv_u64(&o, "id", p.id)
		key(&o, "command")
		write_command(b, p.command, redact = true)
		obj_end(&o)
	}
	strings.write_byte(b, ']')
}

// ---- results and events ----

write_result :: proc(b: ^strings.Builder, r: Result, redact := false) {
	w := obj_begin(b)
	kv_bool(&w, "ok", r.ok)
	if r.error != "" do kv_str(&w, "error", r.error)
	if r.created_id != 0 do kv_u64(&w, "created_id", r.created_id)
	if r.pending do kv_bool(&w, "pending", true)
	if r.confirm_summary != "" {
		key(&w, "needs_confirmation")
		c := obj_begin(b)
		if !redact && r.confirm_token != "" do kv_str(&c, "token", r.confirm_token)
		kv_str(&c, "summary", r.confirm_summary)
		kv_str(&c, "by", r.confirm_by_user ? "user" : "caller")
		if r.confirm_id != 0 do kv_u64(&c, "id", r.confirm_id)
		obj_end(&c)
	}
	if r.data != "" {
		key(&w, "data")
		strings.write_string(b, r.data) // already JSON
	}
	if r.remote != 0 do kv_str(&w, "machine", machine_name(r.remote)) // another machine answered (route_result)
	obj_end(&w)
}

result_json :: proc(r: Result) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_result(&b, r)
	return strings.to_string(b)
}

caller_kind_name :: proc(k: Caller_Kind) -> string {return CALLER_NAMES[k]}

// One event as an envelope line (redacted). full: a private finished event's data too (its requester's copy).
event_json :: proc(ev: Event, full := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := obj_begin(&b)
	kv_u64(&w, "v", PROTOCOL_VERSION)
	kv_str(&w, "type", "event")
	switch e in ev {
	case Command_Event:
		kv_str(&w, "event", "command")
		kv_u64(&w, "request_id", e.request_id)
		kv_str(&w, "caller", caller_kind_name(e.caller.kind))
		if e.caller.tab_id != 0 do kv_u64(&w, "caller_tab_id", e.caller.tab_id)
		kv_u64(&w, "version", e.version)
		kv_bool(&w, "changed", e.changed)
		key(&w, "command")
		write_command(&b, e.command, redact = true)
		if e.confirmation != 0 do kv_u64(&w, "confirmation", e.confirmation) // the user's confirmed run of that pending confirmation
		key(&w, "result")
		write_result(&b, e.result, redact = true)
	case Finished_Event:
		kv_str(&w, "event", "finished")
		kv_u64(&w, "request_id", e.request_id)
		key(&w, "result")
		r := e.result
		if e.private && !full && r.data != "" do r.data = fmt.tprintf(`{{"private_bytes":%d}}`, len(r.data))
		write_result(&b, r, redact = true)
	case Job_Event:
		return job_event_json(e)
	}
	obj_end(&w)
	return strings.to_string(b)
}

// Panel rows as pi-kit's Line: {text, tone?, head?}.
write_rows :: proc(b: ^strings.Builder, rows: []Panel_Row) {
	strings.write_byte(b, '[')
	for r, i in rows {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_str(&o, "text", r.text)
		if r.tone != .Normal do kv_str(&o, "tone", TONE_NAMES[r.tone])
		if r.head do kv_bool(&o, "head", true)
		obj_end(&o)
	}
	strings.write_byte(b, ']')
}

// A terminal tab's status in the snapshot (agent_status.odin): the dot, its
// source (bridge, osc7501, none), when it last reported, unseen, and OSC
// 7501's record (app, kind, title, message: untrusted one-line text).
status_tab_json :: proc(b: ^strings.Builder, t: Tab) {
	v := tab_status_view(t)
	w := obj_begin(b)
	kv_str(&w, "dot", ROW_STATUS_NAMES[v.dot])
	kv_str(&w, "source", STATUS_SOURCE_NAMES[v.source])
	kv_bool(&w, "unseen", t.unseen)
	if v.at != {} do kv_str(&w, "at", iso_utc(v.at))
	if t.prog.state != .None {
		key(&w, "osc7501")
		p := obj_begin(b)
		kv_str(&p, "state", PROG_STATE_NAMES[t.prog.state])
		if t.prog.kind != .None do kv_str(&p, "kind", PROG_KIND_NAMES[t.prog.kind])
		if t.prog.progress >= 0 && (t.prog.state == .Working || t.prog.state == .Blocked) do kv_u64(&p, "progress", u64(t.prog.progress))
		if t.prog.app != "" do kv_str(&p, "app", t.prog.app)
		if t.prog.id != "" do kv_str(&p, "id", t.prog.id)
		if t.prog.title != "" do kv_str(&p, "title", t.prog.title)
		if t.prog.msg != "" do kv_str(&p, "message", t.prog.msg)
		kv_u64(&p, "records", u64(t.prog.records))
		kv_str(&p, "at", iso_utc(t.prog.at))
		obj_end(&p)
	}
	obj_end(&w)
}

// "2026-11-03T10:20:30Z" (temp).
iso_utc :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, sec := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, sec)
}

write_strings :: proc(b: ^strings.Builder, list: []string) {
	strings.write_byte(b, '[')
	for x, i in list {
		if i > 0 do strings.write_byte(b, ',')
		json_quote(b, x)
	}
	strings.write_byte(b, ']')
}

// Reply envelope to a request with client id `id`. request_id (commands
// over the socket) is Deckhand's id for the request: a `pending` result's
// `finished` event carries the same one.
reply_json :: proc(id: string, r: Result, request_id: u64 = 0) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := obj_begin(&b)
	kv_str(&w, "id", id)
	kv_u64(&w, "v", PROTOCOL_VERSION)
	kv_str(&w, "type", "result")
	if request_id != 0 do kv_u64(&w, "request_id", request_id)
	key(&w, "result")
	write_result(&b, r)
	obj_end(&w)
	return strings.to_string(b)
}

// ---- state snapshot ----

tab_kind_name :: proc(k: Tab_Kind) -> string {
	switch _ in k {
	case Pi_Tab:     return "pi"
	case Shell_Tab:  return "shell"
	case Editor_Tab: return "editor"
	case Changes_Tab: return "changes"
	case Markdown_Tab: return "markdown"
	case Browser_Tab: return "browser"
	case App_Tab: return "app"
	case Claude_Tab: return "claude"
	}
	return ""
}

// The state as JSON (temp allocator). Confirmation tokens are left out: only
// the caller that triggered a confirmation (or the user, via the UI) gets one.
state_json :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	write_state(&b, state)
	return strings.to_string(b)
}

// The snapshot as one pi tab may see it: only the open session holding
// `tab_id` and its project; no other sessions, listed sessions or pending
// confirmations. Same shape as state_json.
session_state_json :: proc(tab_id: u64) -> string {
	v := State {
		version  = state.version,
		next_id  = state.next_id,
		layout   = state.layout,
		settings = state.settings,
	}
	v.projects = make([dynamic]Project, context.temp_allocator)
	v.open_sessions = make([dynamic]Open_Session, context.temp_allocator)
	if s, _, _ := find_tab(tab_id); s != nil {
		append(&v.open_sessions, s^)
		if p := find_project(s.project_id); p != nil do append(&v.projects, p^)
		if state.current_session == s.id do v.current_session = s.id
	}
	b := strings.builder_make(context.temp_allocator)
	writing_tab_view = true
	write_state(&b, v)
	writing_tab_view = false
	return strings.to_string(b)
}

// A pi or Claude tab's own view is being written (session_state_json): no account folders.
@(private = "file")
writing_tab_view: bool

write_state :: proc(b: ^strings.Builder, s: State) {
	w := obj_begin(b)
	kv_u64(&w, "version", s.version)
	kv_u64(&w, "next_id", s.next_id)
	key(&w, "projects")
	strings.write_byte(b, '[')
	for p, i in s.projects {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_u64(&o, "id", p.id)
		if p.machine != 0 do kv_str(&o, "machine", machine_name(p.machine)) // another machine's (machine_mirror.odin)
		kv_str(&o, "cwd", p.cwd)
		kv_str(&o, "label", p.label)
		kv_str(&o, "name", p.name)
		kv_str(&o, "dir", p.dir)
		if p.missing do kv_bool(&o, "missing", true)
		// the tidy list (project_tidy.odin): why it is hidden (user, temp, missing), the row it shows in
		if p.group == .Projects {
			if r := project_hide_reason(p); r != .None do kv_str(&o, "hidden_reason", HIDE_REASON_NAMES[r])
			if p.repo do kv_bool(&o, "repo", true)
			if p.temp do kv_bool(&o, "temp", true)
			if p.parent != 0 do kv_u64(&o, "parent", p.parent) // nested under that project's row
			if p.group_dir != "" do kv_str(&o, "group_dir", p.group_dir) // in that folder's group row
			if p.group_in != 0 do kv_u64(&o, "group_in", p.group_in) // that group row is nested under this project
			if p.group_up != "" do kv_str(&o, "group_up", p.group_up) // that group row is inside this one
		}
		if p.group == .Chats do kv_str(&o, "group", "chats")
		obj_end(&o)
	}
	strings.write_byte(b, ']')
	kv_u64(&w, "selected_project", s.selected_project)
	write_sessions :: proc(w: ^Jw, b: ^strings.Builder, name: string, list: []Session) {
		key(w, name)
		strings.write_byte(b, '[')
		for x, i in list {
			if i > 0 do strings.write_byte(b, ',')
			o := obj_begin(b)
			kv_str(&o, "id", x.id)
			kv_str(&o, "path", x.path)
			kv_str(&o, "when", x.when_)
			kv_str(&o, "title", x.title)
			obj_end(&o)
		}
		strings.write_byte(b, ']')
	}
	write_sessions(&w, b, "sessions", s.sessions[:])
	write_sessions(&w, b, "chats", s.chats[:])
	key(&w, "sidebar")
	{
		sb := s.sidebar
		o := obj_begin(b)
		key(&o, "pinned_projects")
		write_strings(b, sb.pinned_projects[:])
		key(&o, "pinned_sessions")
		write_strings(b, sb.pinned_sessions[:])
		key(&o, "hidden_projects")
		write_strings(b, sb.hidden_projects[:])
		key(&o, "hidden_sessions")
		write_strings(b, sb.hidden_sessions[:])
		key(&o, "sort")
		so := obj_begin(b)
		for sec in Sort_Section do kv_str(&so, SORT_SECTION_NAMES[sec], SORT_BY_NAMES[sb.sort[sec]])
		obj_end(&so)
		key(&o, "folded")
		fo := obj_begin(b)
		for f in Sidebar_Fold do kv_bool(&fo, FOLD_NAMES[f], sb.folded[f])
		obj_end(&fo)
		kv_str(&o, "view", SIDEBAR_VIEW_NAMES[sb.view])
		kv_bool(&o, "show_hidden", sb.show_hidden)
		key(&o, "expanded")
		write_strings(b, sb.expanded[:])
		key(&o, "filter")
		fl := obj_begin(b)
		kv_str(&fl, "text", sb.filter)
		kv_bool(&fl, "running", sb.only_running)
		kv_bool(&fl, "waiting", sb.only_waiting)
		kv_bool(&fl, "pinned", sb.only_pinned)
		obj_end(&fl)
		obj_end(&o)
	}
	key(&w, "open_sessions")
	strings.write_byte(b, '[')
	for os, i in s.open_sessions {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_u64(&o, "id", os.id)
		if os.machine != 0 do kv_str(&o, "machine", machine_name(os.machine)) // another machine's (machine_mirror.odin)
		// a Claude-only session (claude.odin): its main tab is a Claude tab, and its id (here and as
		// claude_session_id) is that tab's Claude session id
		kv_str(&o, "agent", os.agent == .Claude ? "claude" : os.agent == .Files ? "files" : "pi")
		if os.agent == .Claude do kv_str(&o, "claude_session_id", os.pi_session_id)
		kv_str(&o, "pi_session_id", os.pi_session_id)
		kv_str(&o, "session_dir", os.session_dir)
		kv_str(&o, "session_file", os.session_file)
		kv_u64(&o, "project_id", os.project_id)
		kv_str(&o, "cwd", os.cwd)
		kv_u64(&o, "active_tab", os.active_tab)
		panes_json(b, &o, os) // its panes and their layout (panes.odin)
		if os.missing do kv_bool(&o, "missing", true)
		if os.home do kv_bool(&o, "home", true)
		// pending comments for its pi (comments.odin), and why they wait ("" = they go with the next message)
		key(&o, "comments")
		strings.write_byte(b, '[')
		for c, k in os.comments {
			if k > 0 do strings.write_byte(b, ',')
			co := obj_begin(b)
			kv_u64(&co, "id", c.id)
			kv_str(&co, "source", COMMENT_SOURCE_NAMES[c.source])
			kv_u64(&co, "tab_id", c.tab_id)
			kv_str(&co, "what", c.what)
			kv_str(&co, "text", c.text)
			kv_str(&co, "crop", c.crop)
			y, mo, d := time.date(c.created)
			h, mi, sec := time.clock(c.created)
			kv_str(&co, "created", fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, sec))
			obj_end(&co)
		}
		strings.write_byte(b, ']')
		if len(os.comments) > 0 {
			sos := os
			_, why := comments_ready(&sos)
			kv_str(&o, "comments_wait", why)
			kv_bool(&o, "comments_sending", os.attach.sending != 0)
		}
		{
			sos := os
			st, _ := session_row_status(&sos)
			kv_str(&o, "agent_status", ROW_STATUS_NAMES[st]) // the row's dot: the strongest of its tabs
		}
		key(&o, "tabs")
		strings.write_byte(b, '[')
		for t, j in os.tabs {
			if j > 0 do strings.write_byte(b, ',')
			to := obj_begin(b)
			kv_u64(&to, "id", t.id)
			if t.machine != 0 do kv_str(&to, "machine", machine_name(t.machine))
			kv_str(&to, "kind", tab_kind_name(t.kind))
			kv_str(&to, "title", t.title)
			kv_str(&to, "status", TAB_STATUS_NAMES[t.status])
			{
				sos := os
				pn := session_pane(&sos, t.pane)
				kv_u64(&to, "pane", pn != nil ? pn.id : 0)
				kv_bool(&to, "on_screen", os.id == s.current_session && session_tab_shown(&sos, t.id))
			}
			if t.status == .Exited do if how := exit_text(t.exit); how != "" do kv_str(&to, "exit", how)
			if x := term_of(t.id); x != nil {
				// keep_sessions (holder_client.odin): its process runs in the session holder's terminal `held`
				if x.pty.held != 0 {
					kv_u64(&to, "held", u64(x.pty.held))
					if x.pty.pid > 0 do kv_u64(&to, "pid", u64(x.pty.pid))
				}
				if x.inexact do kv_bool(&to, "inexact", true) // adopted, not rebuilt byte-exactly
				if x.holder_lost do kv_bool(&to, "holder_lost", true) // the session holder stopped
				if x.pty.held != 0 && holder_term_degraded(x.pty.held) do kv_bool(&to, "holder_degraded", true) // an upgrade's keeper serves it (§7.3)
			} else if replica_process { // a separate core's window: the same, from the tab's live facts
				l := t.live
				if l.held_term != 0 {
					kv_u64(&to, "held", u64(l.held_term))
					if l.pid > 0 do kv_u64(&to, "pid", u64(l.pid))
				}
				if l.inexact do kv_bool(&to, "inexact", true)
				if l.holder_lost do kv_bool(&to, "holder_lost", true)
				if l.holder_degraded do kv_bool(&to, "holder_degraded", true)
			}
			if t.cwd != "" do kv_str(&to, "cwd", t.cwd)
			if et, is_ed := t.kind.(Editor_Tab); is_ed {
				kv_str(&to, "path", et.path)
				if et.view != .File do kv_str(&to, "view", EDITOR_VIEW_NAMES[et.view])
				if et.preview do kv_bool(&to, "preview", true)
				if dirty, known := window_tab_dirty(t.id); known do kv_bool(&to, "dirty", dirty) // no window: not said
			}
			if ct, is_ch := t.kind.(Changes_Tab); is_ch do kv_str(&to, "root", ct.root)
			// the window's: comment mode and markers, zoom, bars, downloads, the agent strip, an upload's ask
			if _, is_br := t.kind.(Browser_Tab); is_br do window_browser_json(b, t.id)
			if bt, is_web := t.kind.(Browser_Tab); is_web {
				// browser_nav.odin: what the page reported
				kv_str(&to, "url", bt.url)
				kv_bool(&to, "loading", bt.loading)
				kv_bool(&to, "can_back", bt.can_back)
				kv_bool(&to, "can_forward", bt.can_forward)
				if bt.blocked_popup != "" do kv_str(&to, "blocked_popup", browser_url_public(bt.blocked_popup)) // State keeps it as asked (Browser_Popup opens it)
				// its page: open | waiting (no slot free) | unloaded (opens when shown) | closed (see the tab)
				if page := window_browser_page(t.id); page != "" do kv_str(&to, "page", page)
			}
			if at, is_app := t.kind.(App_Tab); is_app {
				kv_str(&to, "app_status", APP_STATUS_NAMES[at.app_status])
				if at.exit_code >= 0 do kv_u64(&to, "exit_code", u64(at.exit_code))
				if a, has := window_app_view(t.id); has { // its process (the window's)
					kv_u64(&to, "frames", a.frames)
					kv_bool(&to, "inspect", a.inspect)
					kv_u64(&to, "boxes", u64(app_box_count(t.id)))
					if a.has_ring {
						kv_u64(&to, "ring_gen", u64(a.ring_gen))
						kv_u64(&to, "ring_w", u64(a.ring_w))
						kv_u64(&to, "ring_h", u64(a.ring_h))
					}
				}
			}
			if _, is_cl := t.kind.(Claude_Tab); is_cl do claude_tab_json(b, t) // claude.odin
			if mt, is_md := t.kind.(Markdown_Tab); is_md {
				kv_str(&to, "path", mt.path)
				kv_bool(&to, "source", mt.source)
				if line, links, headings, matches, laid := window_md_view(t.id); laid { // its preview (the window's)
					kv_u64(&to, "line", u64(line))
					kv_u64(&to, "links", u64(links))
					kv_u64(&to, "headings", u64(headings))
					if matches >= 0 do kv_u64(&to, "matches", u64(matches))
				}
			}
			if tab_is_terminal(t) {
				key(&to, "agent_status") // the dot and where it came from (agent_status.odin)
				status_tab_json(b, t)
			}
			if _, is_pi := t.kind.(Pi_Tab); is_pi {
				kv_str(&to, "agent", AGENT_NAMES[t.agent])
				kv_bool(&to, "waiting", t.waiting)
				kv_bool(&to, "question", t.question)
				if pt := t.kind.(Pi_Tab); pt.model != "" do kv_str(&to, "model", pt.model)
				if pt := t.kind.(Pi_Tab); pt.thinking != "" do kv_str(&to, "thinking", pt.thinking)
				key(&to, "blockers")
				write_strings(b, t.blockers[:])
				key(&to, "reload") // hot reload (reload.odin)
				write_tab_reload(b, t.reload)
				key(&to, "panels")
				write_panels(b, t.panels[:])
			}
			if _, is_cl := t.kind.(Claude_Tab); is_cl {
				key(&to, "reload") // hot reload and version (claude_reload.odin)
				write_tab_reload(b, t.reload)
				key(&to, "panels") // Claude's todos and subagents (claude_panels.odin)
				write_panels(b, t.panels[:])
			}
			obj_end(&to)
		}
		strings.write_byte(b, ']')
		obj_end(&o)
	}
	strings.write_byte(b, ']')
	kv_u64(&w, "current_session", s.current_session)
	kv_u64(&w, "shown_before", s.shown_before)
	fmt.sbprintf(b, `,"pi_installed":%v`, pi_installed()) // pi found (harness.odin): stat, else the login shell's answer
	fmt.sbprintf(b, `,"claude_installed":%v`, claude_installed()) // Claude Code found (claude.odin): new_claude_session would start
	fmt.sbprintf(b, `,"codex_installed":%v`, codex_installed()) // Codex found (codex.odin): new_claude_session harness codex would start
	if !writing_tab_view do claude_accounts_json(b) // the Claude Code accounts (claude_accounts.odin): labels and folders; the full snapshot only
	if !writing_tab_view do agy_accounts_json(b) // the Antigravity accounts (agy_accounts.odin): names, labels, folders, how each signs in
	if !writing_tab_view { // other machines over SSH (machines.odin): never their ssh target; [] for none
		strings.write_string(b, `,"machines":[`)
		for m, i in s.machines {
			if i > 0 do strings.write_byte(b, ',')
			fmt.sbprintf(b, `{{"no":%d,"name":`, m.no)
			json_quote(b, m.name)
			fmt.sbprintf(b, `,"status":"%s","version":`, MACHINE_STATUS_NAMES[m.status])
			json_quote(b, m.version)
			strings.write_string(b, `,"os":`)
			json_quote(b, m.os)
			strings.write_string(b, `,"arch":`)
			json_quote(b, m.arch)
			strings.write_string(b, `,"error":`)
			json_quote(b, m.error)
			// its install or update, Update's offer, linger, its coding agents (machine_install.odin)
			fmt.sbprintf(b, `,"job":"%s","job_note":`, strings.to_lower(fmt.tprint(m.job), context.temp_allocator))
			json_quote(b, m.job_note)
			fmt.sbprintf(b, `,"update":"%s","linger":"%s","codex":%v,"checklist":[`, strings.to_lower(fmt.tprint(m.update), context.temp_allocator), strings.to_lower(fmt.tprint(m.linger), context.temp_allocator), m.codex) // codex: Codex tabs may start there (its hello's codex_tabs)
			for c, k in m.checklist {
				if k > 0 do strings.write_byte(b, ',')
				strings.write_string(b, `{"id":`)
				json_quote(b, c.id)
				fmt.sbprintf(b, `,"state":"%s","version":`, HARNESS_STATE_NAMES[c.state])
				json_quote(b, c.version)
				strings.write_string(b, `,"command":`)
				json_quote(b, c.command)
				strings.write_byte(b, '}')
			}
			strings.write_string(b, "]}")
		}
		strings.write_byte(b, ']')
	}
	if !writing_tab_view do usage_snapshot_json(b, s.usage) // quota and usage per account (usage.odin): numbers and labels, never the account's id
	claude_history_json(b, s.claude_history[:], s.claude_disk[:], s.claude_disk_chats[:]) // Claude sessions Deckhand ran (claude.odin); not in a pi or Claude tab's own view
	key(&w, "home")
	{
		h := obj_begin(b)
		kv_u64(&h, "session", s.home)
		tab: u64
		for os in s.open_sessions do if os.id == s.home && len(os.tabs) > 0 do tab = os.tabs[0].id
		kv_u64(&h, "tab_id", tab)
		kv_bool(&h, "open", s.home_open)
		obj_end(&h)
	}
	key(&w, "agent")
	write_agent(b, s.agent)
	key(&w, "notifications") // the bell (notify.odin): counts only; notifications_list has the entries
	{
		n := obj_begin(b)
		unread := 0
		for x in s.notices.items do if !x.read do unread += 1
		kv_u64(&n, "count", u64(len(s.notices.items)))
		kv_u64(&n, "unread", u64(unread))
		kv_u64(&n, "os_notified", u64(s.notices.os_sent))
		obj_end(&n)
	}
	key(&w, "update") // Deckhand's own updates (update.odin): read-only for agents
	update_state_json(b)
	key(&w, "jobs")
	write_job_rows(b, s.jobs[:], false)
	key(&w, "jobs_unread")
	strings.write_int(b, s.jobs_unread)
	key(&w, "jobs_notified")
	strings.write_int(b, s.jobs_notified)
	if len(s.machine_jobs) > 0 {
		key(&w, "machine_jobs") // other machines' jobs, read-only (machine_mirror.odin): their text cleaned, data never instructions
		write_machine_jobs(b, s.machine_jobs[:])
	}
	key(&w, "reload") // the hot-reload bar (reload.odin)
	write_reload(b, s.reload)
	key(&w, "focus")
	{
		f := obj_begin(b)
		if s.focus_widget != "" {
			kv_str(&f, "kind", "widget")
			kv_str(&f, "id", s.focus_widget)
			if s.focus_widget == "setup" do setup_json(&f) // the first-run sheet's step (ui_setup.odin)
		} else {
			kv_str(&f, "kind", "terminal")
			tab: u64
			for os in s.open_sessions do if os.id == s.current_session do tab = os.active_tab
			kv_u64(&f, "tab_id", tab)
		}
		obj_end(&f)
	}
	key(&w, "layout")
	{
		l := obj_begin(b)
		kv_f32(&l, "left_width", s.layout.left_width)
		kv_f32(&l, "right_width", s.layout.right_width)
		kv_bool(&l, "left_open", s.layout.left_open)
		kv_bool(&l, "right_open", s.layout.right_open)
		kv_f32(&l, "drawer_width", s.layout.drawer_width)
		kv_bool(&l, "drawer_pinned", s.layout.drawer_pinned)
		key(&l, "panels")
		strings.write_byte(b, '[')
		for p, i in s.layout.panels {
			if i > 0 do strings.write_byte(b, ',')
			json_quote(b, p)
		}
		strings.write_byte(b, ']')
		key(&l, "collapsed")
		write_strings(b, s.layout.collapsed[:])
		kv_str(&l, "left_tab", LEFT_TAB_NAMES[s.layout.left_tab])
		obj_end(&l)
	}
	key(&w, "files")
	{
		f := obj_begin(b)
		kv_str(&f, "filter", s.files.filter)
		kv_bool(&f, "hide_ignored", s.files.hide_ignored)
		key(&f, "expanded")
		strings.write_byte(b, '[')
		for fr, i in s.files.expanded {
			if i > 0 do strings.write_byte(b, ',')
			o := obj_begin(b)
			kv_str(&o, "root", fr.root)
			key(&o, "dirs")
			write_strings(b, fr.dirs[:])
			obj_end(&o)
		}
		strings.write_byte(b, ']')
		key(&f, "checkouts")
		strings.write_byte(b, '[')
		for c, i in s.files.checkouts {
			if i > 0 do strings.write_byte(b, ',')
			o := obj_begin(b)
			kv_str(&o, "base", c.base)
			kv_str(&o, "path", c.path)
			obj_end(&o)
		}
		strings.write_byte(b, ']')
		obj_end(&f)
	}
	key(&w, "pending_confirmations")
	write_pending_confirmations(b, s.pending_confirmations[:])
	// the close prompt (comments.odin): a tab, or a session (tab_id 0), closed with comments not sent
	if s.comments_ask != {} {
		key(&w, "comments_ask")
		o := obj_begin(b)
		kv_u64(&o, "session", s.comments_ask.session)
		kv_u64(&o, "tab_id", s.comments_ask.tab_id)
		obj_end(&o)
	}
	key(&w, "settings")
	{
		st := obj_begin(b)
		key(&st, "confirm")
		cf := obj_begin(b)
		for k in Caller_Kind {
			if k == .None || k == .UI || k == .Internal || k == .Tab_Host do continue // fixed policies
			key(&cf, CALLER_NAMES[k])
			ko := obj_begin(b)
			for cl in Command_Class do kv_str(&ko, CLASS_NAMES[cl], MODE_NAMES[s.settings.confirm[k][cl]])
			obj_end(&ko)
		}
		obj_end(&cf)
		key(&st, "confirm_close")
		cc := obj_begin(b)
		for k in Tab_Kind_Id do kv_str(&cc, TAB_KIND_NAMES[k], CLOSE_NAMES[s.settings.confirm_close[k]])
		obj_end(&cc)
		kv_str(&st, "theme", THEME_NAMES[s.settings.theme])
		kv_bool(&st, "reduce_motion", s.settings.reduce_motion)
		kv_bool(&st, "dim_panes", !s.settings.dim_panes_off)
		kv_u64(&st, "terminal_text_size", u64(s.settings.term_text_pt))
		kv_str(&st, "appearance", APPEARANCE_NAMES[s.settings.appearance])
		kv_bool(&st, "light", s.settings.appearance == .System ? s.system_light : s.settings.appearance == .Light) // what shows now
		kv_str(&st, "text_size", TEXT_SIZE_NAMES[s.settings.text_size])
		kv_bool(&st, "claude_skip_permissions", s.settings.claude_skip_permissions)
		kv_bool(&st, "codex_full_access", s.settings.codex_full_access)
		// the pi integration's optional extensions, on or off for the pi tabs started from now on
		key(&st, "pi_extensions")
		pe := obj_begin(b)
		for e in pi_integration_optional() do kv_bool(&pe, e.name, e.on)
		obj_end(&pe)
		kv_str(&st, "agent_model", s.settings.agent_model)
		kv_str(&st, "agent_name", s.settings.agent_name)
		kv_bool(&st, "notify", !s.settings.notify_off)
		kv_bool(&st, "tidy_projects", !s.settings.tidy_off)
		kv_bool(&st, "keep_sessions", s.settings.keep_sessions)
		kv_bool(&st, "remote_machines", s.settings.remote_machines)
		kv_bool(&st, "machines_reachable", s.settings.machines_reachable)
		kv_bool(&st, "web_access", s.settings.web_access)
		kv_str(&st, "web_listen", web_listen_address())
		key(&st, "bell")
		bo := obj_begin(b)
		for g in Bell_Group do kv_bool(&bo, BELL_GROUP_NAMES[g], g not_in s.settings.bell_off)
		// per group, what applies (the defaults filled in: notify.odin); os: any group's macOS is not never
		any_os := false
		for g in Bell_Group do if bell_os_when(s.settings, g) != .Never do any_os = true
		kv_bool(&bo, "os", any_os)
		key(&bo, "macos")
		mo := obj_begin(b)
		for g in Bell_Group do kv_str(&mo, BELL_GROUP_NAMES[g], OS_WHEN_NAMES[bell_os_when(s.settings, g)])
		obj_end(&mo)
		key(&bo, "sound")
		so := obj_begin(b)
		for g in Bell_Group do kv_str(&so, BELL_GROUP_NAMES[g], BELL_SOUND_NAMES[bell_sound_of(s.settings, g)])
		obj_end(&so)
		kv_bool(&bo, "dock", !s.settings.bell_dock_off)
		obj_end(&bo)
		// the main folder and the effective subfolders (folders.odin)
		kv_str(&st, "home_dir", s.settings.home_dir)
		kv_bool(&st, "setup_seen", s.settings.setup_seen)
		key(&st, "folders")
		fo := obj_begin(b)
		for f in Folder_Kind {
			key(&fo, FOLDER_NAMES[f])
			fe := obj_begin(b)
			kv_str(&fe, "path", folder_path(s.settings, f))
			kv_bool(&fe, "custom", s.settings.folders[f] != "")
			obj_end(&fe)
		}
		obj_end(&fo)
		// what pi tabs and jobs get as PI_KIT_NOTES_DIR; yours: the user's own environment sets it (it wins)
		key(&st, "notes_env")
		ne := obj_begin(b)
		yours := notes_env_user()
		ours := ""
		if sp := folder_path(s.settings, .Sessions); sp != "" && filepath.base(sp) == "sessions" do ours = filepath.dir(sp)
		kv_str(&ne, "value", yours != "" ? yours : ours)
		kv_bool(&ne, "yours", yours != "")
		obj_end(&ne)
		kv_str(&st, "pi_path", s.settings.pi_path)
		kv_bool(&st, "jobs_paused", s.settings.jobs_paused)
		l := s.settings.job_limits
		key(&st, "job_limits")
		fmt.sbprintf(st.b, `{{"max_cost":%v,"timeout":%d,"max_turns":%d,"day":%v,"week":%v,"month":%v,"concurrency":%d,"loop_calls":%d,"stall":%d,"fail_pause":%d}}`, l.max_cost, l.timeout, l.max_turns, l.day, l.week, l.month, l.concurrency, limit_loop(), limit_stall(), limit_fail())
		obj_end(&st)
	}
	obj_end(&w)
}

// `list_commands`' data: {"commands": [{type, args?, does, confirm_class?,
// long_running?}]}, the commands `caller` may send (temp allocator).
list_commands_json :: proc(caller: Caller) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"commands":[`)
	n := 0
	for s in COMMAND_SPECS {
		if s.who == .Internal || !who_allows(caller.kind, s.who) do continue
		// a pi tab's bridge and a Claude tab (both panel) report different things (caller_may)
		if caller.kind == .Panel && (s.who == .Claude) != caller.claude && (s.who == .Claude || s.who == .Report || s.who == .Bridge) do continue
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		w := obj_begin(&b)
		kv_str(&w, "type", s.type)
		if s.args != "" do kv_str(&w, "args", s.args)
		kv_str(&w, "does", s.does)
		if c, ok := s.confirm.?; ok do kv_str(&w, "confirm_class", CLASS_NAMES[c])
		if s.long_running do kv_bool(&w, "long_running", true)
		obj_end(&w)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}


// The agent in the state snapshot: unread runs, whether it waits for the
// user, the model it runs as far as Deckhand can tell (agent_model).
write_agent :: proc(b: ^strings.Builder, a: Agent_Info) {
	w := obj_begin(b)
	kv_u64(&w, "unread", u64(a.unread))
	kv_bool(&w, "needs_user", agent_needs_user())
	kv_str(&w, "model", agent_model())
	kv_u64(&w, "notified", u64(a.notified))
	obj_end(&w)
}

// A tab's panels: [{panel, title, rows}].
@(private = "file")
write_panels :: proc(b: ^strings.Builder, panels: []Panel) {
	strings.write_byte(b, '[')
	for p, k in panels {
		if k > 0 do strings.write_byte(b, ',')
		po := obj_begin(b)
		kv_str(&po, "panel", p.id)
		kv_str(&po, "title", p.title)
		key(&po, "rows")
		write_rows(b, p.rows[:])
		obj_end(&po)
	}
	strings.write_byte(b, ']')
}

// The harness checklist (harness_manifest.odin) as the sheet shows it: each item's state, what it
// found, its action and command; the run.
@(private = "file")
harness_json :: proc(f: ^Jw) {
	key(f, "agents")
	strings.write_byte(f.b, '[')
	for it, i in harness_items {
		if i > 0 do strings.write_byte(f.b, ',')
		r := HARNESS_MANIFEST[it.row]
		o := obj_begin(f.b)
		kv_str(&o, "id", r.id)
		kv_str(&o, "harness", HARNESS_KEYS[r.harness])
		kv_str(&o, "kind", r.kind == .Harness ? "harness" : r.kind == .Built_In ? "built_in" : "third_party")
		kv_str(&o, "need", r.need == .Required ? "required" : "recommended")
		kv_str(&o, "state", HARNESS_STATE_NAMES[it.state])
		if it.version != "" do kv_str(&o, "version", it.version)
		if r.kind == .Harness && it.where_ != "" do kv_str(&o, "layout", INSTALL_LAYOUT_NAMES[it.layout])
		kv_str(&o, "action", it.action == .Install ? "install" : it.action == .Update ? "update" : "none")
		if it.command != "" do kv_str(&o, "command", it.command)
		if it.action != .None do kv_bool(&o, "runnable", it.runnable)
		obj_end(&o)
	}
	strings.write_byte(f.b, ']')
	if harness_run.status == .None do return
	key(f, "run")
	o := obj_begin(f.b)
	kv_str(&o, "item", harness_run.item)
	names := [Harness_Run_Status]string{.None = "none", .Running = "running", .Done = "done", .Failed = "failed"}
	kv_str(&o, "status", names[harness_run.status])
	if harness_run.exit.known do kv_u64(&o, "code", u64(harness_run.exit.code))
	obj_end(&o)
}

// The sheet in the snapshot's focus: its step, how many, and the accounts step's list (labels
// and folders the user sees; nothing written yet). The sheet is the window's (window.setup_state).
@(private = "file")
setup_json :: proc(f: ^Jw) {
	u, ok := window_setup_state()
	names := [Setup_Step]string{.Agents = "agents", .Main = "main", .Chats = "chats", .Accounts = "accounts", .Agy_Accounts = "agy_accounts", .Folders = "folders"}
	if ok {
		kv_str(f, "step", names[u.step])
		kv_u64(f, "steps", u64(u.steps))
		if u.err != "" do kv_str(f, "error", u.err)
	}
	harness_json(f)
	if !ok do return
	list :: proc(f: ^Jw, name: string, accts: []Setup_Account, def: int) {
		key(f, name)
		strings.write_byte(f.b, '[')
		for a, i in accts {
			if i > 0 do strings.write_byte(f.b, ',')
			o := obj_begin(f.b)
			kv_str(&o, "label", a.label)
			kv_str(&o, "dir", a.dir)
			if a.name != "" do kv_str(&o, "name", a.name)
			kv_bool(&o, "keep", a.keep)
			kv_bool(&o, "marked", a.marked)
			if i == def && a.keep do kv_bool(&o, "default", true)
			if a.hand do kv_bool(&o, "added", true)
			obj_end(&o)
		}
		strings.write_byte(f.b, ']')
	}
	if u.acct_show do list(f, "accounts", u.accounts, u.acct_default)
	if u.agy_show do list(f, "agy_accounts", u.agy_accounts, u.agy_default) // Antigravity's (agy_accounts.odin)
	if (u.acct_show || u.agy_show) && u.acct_msg != "" do kv_str(f, "message", u.acct_msg)
}

// An open session's panes (panes.odin): "focused_pane", "panes" (in leaf order: id, slot, the
// tab it shows, its tabs in strip order, its content rect in logical px once laid out) and
// "layout", the tree: {"pane": id} or {"split": id, "dir": "right"|"down", "ratio", "a", "b"}.
// A session with no panes yet (one read back from a snapshot): its implicit one, id 0.
@(private = "file")
panes_json :: proc(b: ^strings.Builder, o: ^Jw, os: Open_Session) {
	s := os
	fp := session_focused_pane(&s)
	kv_u64(o, "focused_pane", fp != nil ? fp.id : 0)
	if z := session_zoomed(&s); z != 0 do kv_u64(o, "zoomed_pane", z) // zoom_pane: the others are hidden
	key(o, "panes")
	strings.write_byte(b, '[')
	if len(s.panes) == 0 && fp != nil {
		po := obj_begin(b)
		kv_u64(&po, "id", 0)
		kv_u64(&po, "slot", 0)
		kv_u64(&po, "active_tab", fp.active)
		key(&po, "tabs")
		write_ids(b, pane_strip(&s, fp))
		obj_end(&po)
	}
	for &p, i in s.panes {
		if i > 0 do strings.write_byte(b, ',')
		po := obj_begin(b)
		kv_u64(&po, "id", p.id)
		kv_u64(&po, "slot", u64(p.slot))
		kv_u64(&po, "active_tab", p.active)
		key(&po, "tabs")
		write_ids(b, pane_strip(&s, &p))
		if dpi := window_dpi(); p.rect.z > 0 && dpi > 0 {
			key(&po, "rect")
			r := p.rect / dpi
			fmt.sbprintf(b, `{{"x":%d,"y":%d,"w":%d,"h":%d}}`, int(r.x), int(r.y), int(r.z), int(r.w))
		}
		obj_end(&po)
	}
	strings.write_byte(b, ']')
	if len(s.nodes) == 0 do return
	key(o, "layout")
	node :: proc(b: ^strings.Builder, s: ^Open_Session, n: int) {
		x := s.nodes[n]
		if x.leaf {
			fmt.sbprintf(b, `{{"pane":%d}}`, x.pane)
			return
		}
		fmt.sbprintf(b, `{{"split":%d,"dir":"%s","ratio":%.3f,"a":`, x.id, x.dir == .Right ? "right" : "down", x.ratio)
		node(b, s, x.a)
		strings.write_string(b, `,"b":`)
		node(b, s, x.b)
		strings.write_byte(b, '}')
	}
	node(b, &s, s.root)
}

@(private = "file")
write_ids :: proc(b: ^strings.Builder, ids: []u64) {
	strings.write_byte(b, '[')
	for id, i in ids {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_u64(b, id)
	}
	strings.write_byte(b, ']')
}

// get_state's machine_jobs: other machines' jobs as the agents see them (read-only; no paths).
write_machine_jobs :: proc(b: ^strings.Builder, rows: []Job_Row) {
	strings.write_byte(b, '[')
	for r, i in rows {
		if i > 0 do strings.write_byte(b, ',')
		w := obj_begin(b)
		kv_str(&w, "id", r.id)
		kv_str(&w, "machine", machine_name(r.machine))
		kv_str(&w, "name", r.name)
		kv_str(&w, "owner", r.owner_name != "" ? JOB_OWNER_NAMES[r.owner] : "") // as that machine groups it ("" = an older core)
		kv_str(&w, "owner_name", r.owner_name) // display text, cleaned
		kv_str(&w, "schedule", r.schedule)
		kv_bool(&w, "enabled", r.enabled)
		kv_bool(&w, "paused", r.paused)
		kv_bool(&w, "running", r.running)
		kv_u64(&w, "next_due", u64(max(r.next_due, 0)))
		kv_u64(&w, "last_at", u64(max(r.last_at, 0)))
		kv_str(&w, "last_status", r.last_status)
		kv_str(&w, "last_headline", r.last_headline)
		kv_u64(&w, "unread", u64(max(r.unread, 0)))
		key(&w, "needs_you")
		strings.write_byte(b, '[')
		for x, k in r.needs_you {
			if k > 0 do strings.write_byte(b, ',')
			json_quote(b, x)
		}
		strings.write_byte(b, ']')
		obj_end(&w)
	}
	strings.write_byte(b, ']')
}
