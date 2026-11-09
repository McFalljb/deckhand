package core

// The window's messages (window_hooks.odin, window_link.odin; design §10.3, M3-F2): every
// window.request op round-trips to a fake window and back; with no window each answers as if none,
// at once; a parked confirmation reaches the window; the window's facts are what the core reads;
// a window message over its decode budget is refused; a burst of window commands runs over
// several pumps; a zero Caller is refused by every rule.

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:testing"
import cw "../corewire"

// A fake window on the link: it keeps the requests it got and answers those that want a reply.
Fake_Window :: struct {
	end:    cw.Mem_End,
	ops:    [dynamic]Window_Op, // temp
	last:   Window_Request, // temp
	parked: int,
	holds_quit: bool, // what it answers job_sheet_holds_quit
	flood: int, // commands it sends before a reply (past the per-pump cap)
}

fw: Fake_Window

fw_attach :: proc() -> bool {
	fw = {ops = make([dynamic]Window_Op, context.temp_allocator)}
	end, ok := core_attach_window(fw_on_frames)
	fw.end = end
	return ok
}

@(private = "file")
fw_on_frames :: proc() {
	for {
		f, err := cw.mem_recv(fw.end, context.temp_allocator)
		if err != .None do return
		if f.channel != cw.JSON_CHANNEL do continue
		text := string(f.payload)
		m, _ := window_msg_parse(text)
		#partial switch m.kind {
		case .Confirmation_Parked:
			fw.parked += 1
		case .Window_Request:
			id, r, perr := window_request_parse(text)
			if perr != "" do panic(perr)
			append(&fw.ops, r.op)
			fw.last = r
			if id == "" do continue
			for i in 0 ..< fw.flood do fw_send(window_msg_command(Set_Files_Filter{text = fmt.tprintf("f%d", i)}, ""))
			rep := Window_Reply{ok = r.op != .Job_Sheet_Holds_Quit || fw.holds_quit, count = 41, cols = 100, rows = 30, cell = {8, 16}, changed = true, result = {ok = true, data = `{"sheet":"open"}`}}
			fw_send(window_msg_reply(id, &rep))
		}
	}
}

fw_send :: proc(text: string) {
	assert(cw.mem_send(fw.end, cw.JSON_CHANNEL, .Data, transmute([]u8)text) == .None)
}

// The window reports its facts (the core reads them at the pump).
fw_facts :: proc(f: Window_Facts) {
	x := f
	fw_send(window_msg_facts(&x))
	window_link_pump()
}

@(test)
window_request_round_trips :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state = State{}
	if !testing.expect(t, fw_attach()) do return
	defer core_detach_window()

	window_clipboard_set("copied")
	testing.expect_value(t, fw.last.op, Window_Op.Clipboard_Set)
	testing.expect_value(t, fw.last.text, "copied")
	count, marked := window_clipboard_secret("export X=1")
	testing.expect(t, marked && count == 41, "the secret's change count comes back")
	window_clipboard_clear_if(41)
	testing.expect_value(t, fw.last.count, 41)
	testing.expect(t, window_open_url("https://example.invalid/"), "opened")
	testing.expect_value(t, fw.last.text, "https://example.invalid/")
	window_reveal("/tmp/x")
	testing.expect_value(t, fw.last.path, "/tmp/x")
	window_set_appearance(.Dark)
	testing.expect_value(t, fw.last.mode, Appearance.Dark)
	testing.expect(t, window_copy_selection(5), "a selection")
	term: Term
	term_init(&term, 80, 24)
	defer term_free(&term)
	window_term_fit(&term, 5)
	testing.expect(t, term.cols == 100 && term.rows == 30, "the pane's grid")
	window_view_open(6, Editor_Tab{path = "/tmp/a.txt"}, 3, "")
	et, is := fw.last.kind.(Editor_Tab)
	testing.expect(t, is && et.path == "/tmp/a.txt" && fw.last.line == 3, "the record's kind goes with it")
	window_view_drop(6)
	window_view_moved(6, "/tmp/b.txt")
	window_files_deleted("/tmp")
	window_changes_diff(6, "/r/a", "diff", "")
	testing.expect_value(t, fw.last.text, "diff")
	window_changes_rewind(6)
	window_commit_message_clear()
	window_watch_folder("/r")
	window_watch_sync()
	window_setup_sheet(.Failed, "why")
	testing.expect(t, fw.last.setup == .Failed && fw.last.text == "why")
	r, changed := window_job_sheet({open = true, job = "j1"}, {kind = .UI})
	testing.expect(t, r.ok && changed && r.data == `{"sheet":"open"}`, "the sheet's result")
	testing.expect(t, fw.last.job_sheet.job == "j1" && fw.last.caller.kind == .UI)
	testing.expect(t, window_job_sheet_saved("/j/a.md", ""), "the sheet closed")
	fw.holds_quit = true
	testing.expect(t, window_job_sheet_holds_quit())
	want := []Window_Op{.Clipboard_Set, .Clipboard_Secret, .Clipboard_Clear_If, .Open_Url, .Reveal, .Appearance, .Copy_Selection, .Term_Fit, .View_Open, .View_Drop, .View_Moved, .Files_Deleted, .Changes_Diff, .Changes_Rewind, .Commit_Message_Clear, .Watch_Folder, .Watch_Sync, .Setup_Sheet, .Job_Sheet, .Job_Sheet_Saved, .Job_Sheet_Holds_Quit}
	testing.expectf(t, slice_eq(fw.ops[:], want), "%v", fw.ops)
	// every op but None and View_Goto (it needs a tab record: show_file's tests) is covered
	testing.expect_value(t, len(want), len(Window_Op) - 2)

	// facts: what the window reported is what the core reads
	_, known := window_unsaved_files()
	testing.expect(t, !known, "nothing reported yet: not known")
	fw_facts({active = false, dpi = 2, unsaved = []string{"/r/a.txt", "", "/s/b.txt"}, job_sheet_open = true})
	n, k := window_unsaved_files()
	testing.expect(t, k && n == 3, "all unsaved buffers")
	n, _ = window_unsaved_files("/r")
	testing.expect_value(t, n, 1)
	testing.expect(t, !window_is_active() && window_dpi() == 2 && window_job_sheet_open())
	tf := Tab_Facts{dirty = true}
	fw_send(window_msg_tab_facts(9, &tf))
	window_link_pump()
	dirty, dk := window_tab_dirty(9)
	testing.expect(t, dirty && dk, "a dirty buffer, reported")
}

@(private = "file")
slice_eq :: proc(a, b: []Window_Op) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

// F's missing test: with no window every request answers as if none, at once.
@(test)
window_request_no_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, !window_attached())
	window_clipboard_set("x")
	_, marked := window_clipboard_secret("x")
	testing.expect(t, !marked, "nothing to clear")
	testing.expect(t, !window_open_url("https://example.invalid/"))
	testing.expect(t, !window_copy_selection(1))
	r, changed := window_job_sheet({open = true}, {kind = .UI})
	testing.expect(t, !r.ok && !changed)
	testing.expect(t, !window_job_sheet_saved("/x", ""))
	testing.expect(t, !window_job_sheet_holds_quit())
	term: Term
	term_init(&term, 80, 24)
	defer term_free(&term)
	window_term_fit(&term, 1)
	testing.expect(t, term.cols == 80 && term.rows == 24, "keeps its own grid")
	_, known := window_unsaved_files()
	testing.expect(t, !known)
	_, known = window_tab_dirty(1)
	testing.expect(t, !known)
	testing.expect(t, window_is_active(), "no window: as before (M4-D decides)")
	// a ⌘-click with no window: no_window, nothing opened
	state = State{}
	s := Open_Session{id = new_id()}
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, status = .Running})
	append(&state.open_sessions, s)
	defer state = State{}
	lr := run_command(Terminal_Link{tab_id = s.tabs[0].id, url = "https://example.invalid/"}, {kind = .UI})
	testing.expect_value(t, json_path(lr.data, "code"), "no_window")
}

@(test)
confirmation_parked_reaches_the_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state = State{}
	defer {
		for &p in state.pending_confirmations {
			delete(p.token)
			delete(p.summary)
			command_free(p.command, context.allocator)
		}
		delete(state.pending_confirmations)
		state = State{}
	}
	if !testing.expect(t, fw_attach()) do return
	defer core_detach_window()
	// a window that has not said what is unsaved: the quit asks (window_unsaved_test.odin)
	r := run_command(Quit{}, {kind = .UI})
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect_value(t, fw.parked, 1)
}

// A window message whose decoded size passes its budget (8x, not state's 64x) is refused.
@(test)
window_message_over_budget_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state = State{}
	if !testing.expect(t, fw_attach()) do return
	defer core_detach_window()
	// 20k empty markers: ~60 KB of JSON, each a whole Browser_Marker_Fact once decoded (~1.5 MB)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"v":1,"type":"window.tab_facts","tab_id":4,"facts":{"browser":{"markers":[`)
	for i in 0 ..< 20_000 {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{}")
	}
	strings.write_string(&b, `]}}}`)
	fw_send(strings.to_string(b))
	window_link_pump()
	testing.expect(t, window_tab_facts(4) == nil, "refused")
	// a state message's budget would have taken it
	testing.expect(t, READ_BUDGET_PER_BYTE * len(strings.to_string(b)) > 20_000 * size_of(Browser_Marker_Fact), "state's budget is far larger")
}

// A burst of 10k window commands runs over several pumps (WINDOW_COMMANDS_PER_PUMP each), not one.
@(test)
window_commands_capped_per_pump :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state = State{}
	defer state = State{}
	if !testing.expect(t, fw_attach()) do return
	defer core_detach_window()
	N :: 10_000
	for i in 0 ..< N do fw_send(window_msg_command(Set_Files_Filter{text = fmt.tprintf("f%d", i)}, ""))
	inbox_drain()
	testing.expectf(t, state.files.filter != fmt.tprintf("f%d", N - 1), "not all in one drain")
	drains := 1
	for state.files.filter != fmt.tprintf("f%d", N - 1) && drains < 100 {
		inbox_drain()
		drains += 1
	}
	testing.expect_value(t, state.files.filter, fmt.tprintf("f%d", N - 1))
	testing.expectf(t, drains >= N / WINDOW_COMMANDS_PER_PUMP, "%d drains", drains)
}

// The zero Caller (Caller_Kind.None) is nobody's: every command refuses it.
@(test)
zero_caller_refused :: proc(t: ^testing.T) {
	ti := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	for v in ti.variants {
		cmd: Command
		reflect.set_union_variant_typeid(any{&cmd, typeid_of(Command)}, v.id)
		testing.expectf(t, !caller_may({}, cmd), "%v: a zero caller may", v.id)
	}
	testing.expect_value(t, confirm_mode({}, .Tab_Close), Confirm_Mode.Ask)
	testing.expect(t, !owns_tab({}, 1))
	r := run_command(Set_Confirm_Policy{caller = .None, class = .Tab_Close, mode = .Auto}, {kind = .UI})
	testing.expect(t, !r.ok, "no policy for nobody")
}

// #50 review: a reply behind more than a pump's cap of commands still reaches its request.
@(test)
window_reply_behind_the_cap :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state = State{}
	defer state = State{}
	if !testing.expect(t, fw_attach()) do return
	defer core_detach_window()
	fw.flood = 2 * WINDOW_COMMANDS_PER_PUMP
	count, marked := window_clipboard_secret("export X=1")
	testing.expect(t, marked && count == 41, "the reply came")
}
