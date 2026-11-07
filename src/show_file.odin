package main

// show_file (a row in command_table.odin; docs/PROTOCOL.md): an agent shows the user a file in a
// tab of its own session. A Markdown file opens in a Markdown tab (rendered, following the file on
// disk; anchor scrolls to a heading, line to a source line), any other text file in an editor tab
// (line). It is the agent's way to answer "open it in a tab"; open_file and markdown_open stay
// the user's, scripts' and Atlas's (they focus the tab, and a pi or Claude tab may not send them).
//
// Rules:
// - Where: a pi or Claude tab (caller panel) shows files only in its own session (naming another
//   is refused), the new tab right after the agent's own tab and behind the user's view (the
//   session on screen and its active tab stay, as browser_open and new_app_tab). The user and
//   scripts: the session on screen (or named), in front. A control caller (Atlas): the session it
//   names, behind.
// - Which files: display only, so any file the user could open, outside the project too (the
//   agent can read it with its own tools anyway; nothing of the file comes back to it), never a
//   credentials file (settings_credential, as open_file). fs_check's project boundary is for
//   listing and changing files, which this does not do.
// - What it shows: what the editor can (disk_read): binary files, files over 20 MB, folders,
//   pipes and missing files are refused with a hint, and no tab opens.
// - Read-only: a read-only chat may show files too. The tab is an ordinary editor tab for the
//   user; no agent has a command that edits it (save_file, reload_file… are not for panel callers).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

Show_File :: struct {
	path:    string, // absolute, ~/, or relative to the session's folder
	line:    int, // 1-based; 0 = none
	anchor:  string, // a Markdown heading id, "#" optional ("" = none)
	session: u64, // a pi or Claude tab: 0 or its own; the user, scripts: 0 = the one on screen
}

// The session a caller's show_file goes to, or why not.
@(private = "file")
show_session :: proc(caller: Caller, session: u64) -> (^Open_Session, string) {
	s: ^Open_Session
	switch caller.kind {
	case .Panel:
		own := caller_session(caller)
		if own == nil do return nil, "the calling tab has no session"
		if session != 0 && session != own.id do return nil, "a pi or Claude tab shows files in its own session only"
		s = own
	case .UI, .Script:
		s = session != 0 ? find_session(session) : cur()
		if s == nil do return nil, session != 0 ? "no such session" : "no session on screen"
	case .Control, .Internal:
		if session != 0 do s = find_session(session)
		else if caller.tab_id != 0 do s = caller_session(caller)
		if s == nil do return nil, session != 0 ? "no such session" : "session is needed (which session's tab shows the file)"
	case .App:
		return nil, "not allowed for this caller"
	}
	if s.home do return nil, "Home has only its pi tab: name a session (session) to show the file in"
	return s, ""
}

// A refusal: error says what, data {code, hint} what to do instead (the CLI and the pi tool show both).
@(private = "file")
refuse :: proc(code, msg, hint: string) -> Result {
	b := strings.builder_make(context.temp_allocator)
	json_quote(&b, hint)
	return {error = msg, data = fmt.tprintf(`{{"code":%q,"hint":%s}}`, code, strings.to_string(b))}
}

show_file_apply :: proc(c: Show_File, caller: Caller) -> (r: Result, changed: bool) {
	s, serr := show_session(caller, c.session)
	if s == nil {
		if caller.kind == .Panel && c.session != 0 do return refuse("other_session", serr, "leave session out: the file opens next to your own tab"), false
		return fail(serr), false
	}
	if strings.trim_space(c.path) == "" do return refuse("bad_path", "path is empty", "give the file's path: absolute, or relative to the session's folder"), false
	if c.line < 0 do return fail("line starts at 1"), false
	agent := caller.kind == .Panel || caller.kind == .Control
	p := c.path
	if strings.has_prefix(p, "~/") do p = strings.concatenate({os.get_env("HOME", context.temp_allocator), p[1:]}, context.temp_allocator)
	if !filepath.is_abs(p) do p, _ = filepath.join({s.cwd, p}, context.temp_allocator)
	p, _ = filepath.clean(p, context.temp_allocator)
	// before anything touches the file system: devices, and for agents the volumes that can hang
	if show_device(p) do return refuse("device", "a device (/dev)", "only regular text files are shown"), false
	if agent && show_slow_path(p) do return refuse("slow_path", "on a network or removable volume (/net, /Volumes)", SLOW_HINT), false
	rp := fs_real(p)
	if show_device(rp) do return refuse("device", "a device (/dev)", "only regular text files are shown"), false
	if agent && show_slow_path(rp) do return refuse("slow_path", "on a network or removable volume (/net, /Volumes)", SLOW_HINT), false
	CRED_HINT :: "sign-ins and .env files are never shown: tell the user which file to open themselves"
	if settings_credential(p) || settings_credential(rp) do return refuse("credentials", CREDENTIAL_REFUSED, CRED_HINT), false
	if agent && (show_secret(p) || show_secret(rp)) do return refuse("secret", "it looks like a secret (keys, tokens, sign-ins)", "an agent never shows keys, tokens or sign-ins: tell the user the file's path if they want to open it themselves"), false
	switch path_kind(p) {
	case .Missing: return refuse("no_such_file", fmt.tprintf("no such file: %s", p), fmt.tprintf("a relative path is from the session's folder, %s; check the path, or give an absolute one", s.cwd)), false
	case .Dir:     return refuse("folder", "that is a folder", "show a file in it"), false
	case .Other:   return refuse("not_a_file", "not a regular file (a pipe, device or socket)", "only regular text files are shown"), false
	case .File:
	}
	// an iCloud file not downloaded: reading it would wait for the download, on the main thread
	if agent && show_file_flags(p) & SF_DATALESS != 0 do return refuse("not_downloaded", "an iCloud file that is not downloaded", "ask the user to download it (Finder: Download Now), or tell them its path"), false
	md := md_is_markdown_path(p)
	anchor := strings.trim_prefix(c.anchor, "#")
	if anchor != "" && !md do return refuse("anchor_not_markdown", "anchor is for Markdown files (a heading id)", "use line for other files"), false
	// what the editor would refuse (stat and one chunk): refused here, with no tab that only says why
	if refused := show_file_peek(p); refused != "" {
		switch {
		case refused == CREDENTIALS_NOT_OPENED:      return refuse("credentials", CREDENTIAL_REFUSED, CRED_HINT), false
		case strings.has_prefix(refused, "Binary"):    return refuse("binary", refused, "only text files are shown (an image, PDF or other binary file is not): tell the user the file's path instead"), false
		case strings.has_prefix(refused, "Too large"): return refuse("too_large", refused, "tell the user the file's path, or show a smaller excerpt saved as its own text file"), false
		}
		return refuse("unreadable", refused, "only readable text files are shown"), false
	}
	kind := md ? "markdown" : "editor"
	data :: proc(kind, path: string, session: u64, again: bool) -> string {
		b := strings.builder_make(context.temp_allocator)
		json_quote(&b, path)
		return fmt.aprintf(`{{"kind":%q,"path":%s,"session":%d,"already_open":%v}}`, kind, strings.to_string(b), session, again)
	}
	front :: proc(s: ^Open_Session, id: u64, caller: Caller) {
		session_show_tab(s, id)
		focus_session(s.id, caller)
	}
	// already open (the same kind of tab): not opened twice; scrolled to what was asked
	for &tab in s.tabs {
		open_path := ""
		#partial switch k in tab.kind {
		case Markdown_Tab: if md do open_path = k.path
		case Editor_Tab:   if !md && k.view == .File do open_path = k.path
		}
		if open_path == "" || fs_real(open_path) != rp do continue
		// an agent moves only a tab it opened itself, and never the one the user looks at
		moves := !agent || (show_agent_tabs[tab.id] == caller.tab_id && tab.id in show_agent_tabs && !(s.id == state.current_session && tab_on_screen(tab.id)))
		if !moves {
			return {ok = true, created_id = tab.id, data = data(kind, open_path, s.id, true)}, false
		}
		if md {
			if v := md_view_of(tab.id); v != nil {
				if anchor != "" {
					delete(v.want)
					v.want = strings.clone(anchor)
				} else if c.line > 0 {
					v.want_line = c.line
				}
			}
		} else if e := editor_of(tab.id); e != nil && c.line > 0 {
			ed_goto(e, c.line, 1)
		}
		if !agent do front(s, tab.id, caller)
		app.redraw = true
		return {ok = true, created_id = tab.id, data = data(kind, open_path, s.id, true)}, true
	}
	// at most SHOW_FILE_MAX_TABS tabs agents opened in a session
	if agent {
		n := 0
		for t in s.tabs do if t.id in show_agent_tabs do n += 1
		if n >= SHOW_FILE_MAX_TABS do return refuse("too_many_tabs", fmt.tprintf("%d tabs agents opened are open in this session", n), "ask the user to close some of the tabs you showed; a file already open answers without a new tab"), false
	}
	tab := Tab{id = new_id(), title = strings.clone(filepath.base(p)), status = .Running}
	if md {
		tab.kind = Markdown_Tab{path = strings.clone(p)}
		v := md_view_new(tab.id, p)
		if anchor != "" do v.want = strings.clone(anchor)
		else if c.line > 0 do v.want_line = c.line
	} else {
		tab.kind = Editor_Tab{path = strings.clone(p)}
		e := editor_new(tab.id, p)
		if c.line > 0 do ed_goto(e, c.line, 1)
	}
	// a pi or Claude tab's: right after its own tab, in its pane (else at the end of the focused pane)
	after: u64
	if caller.kind == .Panel do for t in s.tabs do if t.id == caller.tab_id do after = t.id
	pane_add_tab(s, tab, after = after)
	if agent {
		// forget the tabs that closed since (ids are never reused), then remember this one
		for id in show_agent_tabs do if _, t, _ := find_tab(id); t == nil do delete_key(&show_agent_tabs, id)
		show_agent_tabs[tab.id] = caller.tab_id
	}
	if !agent do front(s, tab.id, caller)
	app.redraw = true
	return {ok = true, created_id = tab.id, data = data(kind, p, s.id, false)}, true
}


// The tabs agents opened with show_file, and which caller tab opened each (Panel: the pi or
// Claude tab; Control: Atlas's tab, or 0). An agent moves only its own; the cap counts them.
show_agent_tabs: map[u64]u64

SHOW_FILE_MAX_TABS :: 20
SLOW_HINT :: "network and removable volumes can stall Deckhand while they answer: tell the user the file's path instead"

// macOS's flag on an iCloud (File Provider) file whose content is not on disk.
SF_DATALESS :: u32(0x40000000)

// The file's st_flags (stat, links followed; 0 when it cannot be read). Tests swap it.
show_file_flags: proc(path: string) -> u32 = proc(path: string) -> u32 {
	sb: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &sb) != .OK do return 0
	return u32(sb.st_flags)
}

@(private = "file")
show_device :: proc(p: string) -> bool {return p == "/dev" || strings.has_prefix(p, "/dev/")}

// Network (autofs /net) and removable or mounted volumes (/Volumes): a stat can hang.
@(private = "file")
show_slow_path :: proc(p: string) -> bool {
	for pre in ([]string{"/net", "/Volumes", "/System/Volumes/Data/net"}) {
		if p == pre || strings.has_prefix(p, strings.concatenate({pre, "/"}, context.temp_allocator)) do return true
	}
	return false
}

// What an agent never shows (users opening files themselves are unaffected): keys, tokens and
// sign-ins by name (as worktree_cleanup's wt_secret_name, without its "secret"/"credential"
// substrings, which docs share) and the folders that hold them in the home folder.
show_secret :: proc(p: string) -> bool {
	base := strings.to_lower(filepath.base(p), context.temp_allocator)
	switch base {
	case ".envrc", ".netrc", ".npmrc", ".pypirc", ".htpasswd", ".git-credentials", ".pgpass":
		return true
	}
	for pre in ([]string{"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"}) do if strings.has_prefix(base, pre) do return true
	for ext in ([]string{".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".keychain", ".keychain-db"}) do if strings.has_suffix(base, ext) do return true
	if strings.contains(p, "/Library/Keychains/") do return true
	for home in ([]string{os.get_env("HOME", context.temp_allocator), fs_real(os.get_env("HOME", context.temp_allocator))}) {
		h := strings.trim_right(home, "/")
		if h == "" do continue
		for d in ([]string{".ssh", ".aws", ".gnupg", ".kube", ".docker/config.json", ".config/gh/hosts.yml"}) {
			x := strings.concatenate({h, "/", d}, context.temp_allocator)
			if p == x || strings.has_prefix(p, strings.concatenate({x, "/"}, context.temp_allocator)) do return true
		}
	}
	return false
}

// What disk_read would refuse, from a stat and one chunk ("" = fine): not a regular file, over
// EDITOR_MAX_BYTES, binary in its first 8 KB. Opened non-blocking (a FIFO swapped in never blocks).
show_file_peek :: proc(path: string) -> string {
	kind, st := path_stat(path)
	switch kind {
	case .Missing: return "Cannot open: no such file"
	case .Dir:     return "This is a folder"
	case .Other:   return "Not a regular file (a pipe, device or socket): not opened"
	case .File:
	}
	too_large :: proc(size: i64) -> string {return fmt.tprintf("Too large to open (%.1f MB; the editor opens files up to %d MB)", f64(size) / (1 << 20), EDITOR_MAX_BYTES >> 20)}
	if st.size > EDITOR_MAX_BYTES do return too_large(st.size)
	f, oerr := os.open(path, {.Read, .Non_Blocking})
	if oerr != nil do return fmt.tprintf("Cannot read: %v", oerr)
	defer os.close(f)
	sb: posix.stat_t
	if posix.fstat(posix.FD(os.fd(f)), &sb) != .OK || !posix.S_ISREG(sb.st_mode) do return "Not a regular file (a pipe, device or socket): not opened"
	if credential_inode(u64(sb.st_dev), u64(sb.st_ino)) do return CREDENTIALS_NOT_OPENED
	if i64(sb.st_size) > EDITOR_MAX_BYTES do return too_large(i64(sb.st_size))
	buf: [8192 + 8]u8 // a little past looks_binary's window: a cut sequence at its end is fine
	n, rerr := disk_read_chunk(f, buf[:])
	if rerr != nil && rerr != .EOF do return fmt.tprintf("Cannot read: %v", rerr)
	if looks_binary(buf[:max(n, 0)]) do return "Binary file: not shown"
	return ""
}
