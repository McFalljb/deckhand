package core

// A browser's Changes tab (#148). The window draws its Changes tab from the core's Changes_View
// (changes.odin): the list, the selection and the selected file's diff, read on a worker with
// the same guards (credential and binary files never read, CHANGES_DIFF_BYTES_MAX, no external
// diff or textconv programs). With a browser attached the core keeps that view itself (as for a
// window in its own process) and sends it as state sections, to the browser's link only:
//
//   webchg:<tab>   {list (changes_list's data: paths and counts), sel {path, scope, status},
//                  busy, notice, notice_err}
//   webdiff:<tab>  {path, text (the first `shown` lines, as the window's), lines, shown,
//                  loading, msg (why there is no diff: "Credentials file: listed, never shown")}
//
// Actions are the existing commands (changes_stage, changes_unstage, changes_discard (confirmed),
// changes_commit, pi_prompt / claude_prompt for "Ask pi to review"); changes_select is view state.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:strings"

WEB_DIFF_BYTES_MAX :: 4 << 20 // a diff shown in a browser: at most this much of it (then "Show more" stops)

// changes_select (a browser's): select, show more, read again.
changes_select_apply :: proc(c: Changes_Select) -> Result {
	v := changes_view(c.tab_id)
	if v == nil do return fail("no such changes tab")
	r := changes_repo(v.root)
	if c.refresh do changes_refresh(r)
	if c.path != "" {
		scope: Change_Scope
		switch c.scope {
		case "", "uncommitted": scope = .Uncommitted
		case "committed":       scope = .Committed
		case:                   return fail("scope: uncommitted or committed")
		}
		st := change_status_of_wire(c.status)
		if c.status != "" && st == 0 do return fail("status: M, A, D, R, U or untracked")
		if r == nil || !r.loaded do return fail("the changes are being read: try again")
		f := changes_find(r, c.path, scope, st)
		if f == nil do return fail("not a listed file of this checkout")
		changes_select(v, f.path, f.scope, f.status)
	}
	if c.more && v.diff_lines > v.shown {
		v.shown += CHANGES_LINES_STEP
		window_state_changed()
	}
	return {ok = true}
}

// While a browser is attached (web_view_tick): a Changes tab with nothing selected selects as
// the window's does once its list is read (a list read before the browser came has no
// selection yet).
changes_web_tick :: proc() {
	for _, v in changes_views {
		if v.sel_path != "" || v.diff_loading do continue
		r := changes_repo(v.root)
		if r == nil || !r.loaded || r.loading || len(r.files) == 0 do continue
		f := r.files[0]
		changes_select(v, f.path, f.scope, f.status)
	}
}

// The sections, for every Changes tab of an open session (state_sections; a browser's link only).
@(private)
web_diff_cache: map[u64]struct {
	key:  u64,
	json: string,
}

web_changes_sections :: proc(out: ^[dynamic][2]string) {
	for &s in state.open_sessions do for &t in s.tabs {
		if _, is := t.kind.(Changes_Tab); !is do continue
		v := changes_view(t.id)
		if v == nil do continue
		r := changes_repo(v.root)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"list":`)
		if r != nil do strings.write_string(&b, changes_json(r))
		else do strings.write_string(&b, "null")
		strings.write_string(&b, `,"sel":{"path":`)
		json_quote(&b, v.sel_path)
		fmt.sbprintf(&b, `,"scope":"%s","status":`, v.sel_scope == .Committed ? "committed" : "uncommitted")
		json_quote(&b, change_status_wire(v.sel_status))
		busy, notice, nerr := changes_status(v)
		strings.write_string(&b, `},"busy":`)
		json_quote(&b, busy)
		strings.write_string(&b, `,"notice":`)
		json_quote(&b, notice)
		fmt.sbprintf(&b, `,"notice_err":%v}}`, nerr)
		append(out, [2]string{fmt.tprintf("webchg:%d", t.id), strings.to_string(b)})
		append(out, [2]string{fmt.tprintf("webdiff:%d", t.id), web_diff_json(v)})
	}
}

// A tab's diff section, built again only when the diff, what is shown of it or its message changed.
@(private = "file")
web_diff_json :: proc(v: ^Changes_View) -> string {
	k := hash.fnv64a(transmute([]u8)v.diff)
	k = hash.fnv64a(transmute([]u8)v.msg, k)
	k = hash.fnv64a(transmute([]u8)v.sel_path, k)
	stamp := [3]int{v.shown, v.diff_loading ? 1 : 0, int(v.diff_gen)}
	k = hash.fnv64a(mem.ptr_to_bytes(&stamp), k)
	if c, ok := web_diff_cache[v.tab_id]; ok && c.key == k do return c.json
	context.allocator = runtime.heap_allocator() // the cache's (its map and strings)
	text := v.diff
	if v.diff_lines > v.shown {
		end := 0
		for _ in 0 ..< v.shown {
			i := strings.index_byte(text[end:], '\n')
			if i < 0 do break
			end += i + 1
		}
		text = text[:end]
	}
	cut := len(text) > WEB_DIFF_BYTES_MAX
	if cut {
		end := strings.last_index_byte(text[:WEB_DIFF_BYTES_MAX], '\n')
		text = text[:max(end + 1, 0)]
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"path":`)
	json_quote(&b, v.sel_path)
	strings.write_string(&b, `,"text":`)
	json_quote(&b, text)
	fmt.sbprintf(&b, `,"lines":%d,"shown":%d,"cut":%v,"loading":%v,"msg":`, v.diff_lines, cut ? strings.count(text, "\n") : v.shown, cut, v.diff_loading)
	json_quote(&b, v.msg)
	strings.write_byte(&b, '}')
	if old, ok := web_diff_cache[v.tab_id]; ok do delete(old.json)
	web_diff_cache[v.tab_id] = {k, strings.clone(strings.to_string(b))}
	return web_diff_cache[v.tab_id].json
}

// A Changes tab closed: its cached section goes (changes_drop).
web_changes_drop :: proc(tab_id: u64) {
	if c, ok := web_diff_cache[tab_id]; ok {
		delete(c.json)
		delete_key(&web_diff_cache, tab_id)
	}
}
