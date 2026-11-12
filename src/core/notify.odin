package core

// The notification centre: the bell in the top bar (ui_bell.odin) and its
// entries. What happened in a session the user was not looking at (pi
// finished, waits for them, stopped with an error, exited) and what jobs
// report (job.finished: the jobs code calls notify_job_finished) is kept
// here as a short, bounded list in State, newest last. Nothing goes to the
// agent: the user reads the bell, and an agent may ask for the list
// (notifications_list, titles and ids only).
//
//   - A session's entries are only made while that session is not on screen
//     (not the current one, or the window is in the background).
//   - Flapping is coalesced: a new entry from the same session (or job)
//     within NOTICE_COALESCE replaces its last one (the latest wins).
//   - Focusing a session while the window is active marks its entries read
//     (focus_session, and the window coming to the front).
//   - Per group (Bell_Group: needs you, finished, errors, jobs) three
//     channels (notice_channels): the bell (Settings.bell_off), a macOS
//     notification never, only while Deckhand is in the background, or
//     always (Settings.bell_os), and a sound (Settings.bell_sound) that
//     plays while Deckhand is in the background, or also in front when the
//     group's macOS says always. Defaults (BELL_OS_DEFAULT,
//     BELL_SOUND_DEFAULT): macOS in the background for needs you, errors and
//     jobs, never for finished; a sound (Tink) for needs you only. A job's
//     finished run is the job's own `notify` setting's (jobs.odin): the bell
//     only. The sound is the window's (window_sound: one window.request per
//     notice, never one for what a window finds in the bell when it attaches),
//     paced with the macOS notifications and never more than one a second.
//   - Not saved: entries are gone after a restart (their session ids would
//     not survive it either).

import "core:fmt"
import "core:strings"
import "core:time"

Notice_Kind :: enum {
	Finished, // pi went idle after working
	Waiting, // a pi dialog opened, or its answer ended with a question
	Error, // pi reported an error
	Exited, // pi's process exited
	Job_Finished,
	Job_Needs_You,
	Job_Failed,
}
NOTICE_KIND_NAMES := [Notice_Kind]string {
	.Finished      = "finished",
	.Waiting       = "waiting",
	.Error         = "error",
	.Exited        = "exited",
	.Job_Finished  = "job_finished",
	.Job_Needs_You = "job_needs_you",
	.Job_Failed    = "job_failed",
}

// What the user turns on and off (the gear: "Notify me about").
Bell_Group :: enum {
	Finished,
	Waiting,
	Errors, // errors and exits
	Jobs,
}
BELL_GROUP_NAMES := [Bell_Group]string{.Finished = "finished", .Waiting = "waiting", .Errors = "errors", .Jobs = "jobs"}

notice_group :: proc(k: Notice_Kind) -> Bell_Group {
	switch k {
	case .Finished:                                    return .Finished
	case .Waiting:                                     return .Waiting
	case .Error, .Exited:                              return .Errors
	case .Job_Finished, .Job_Needs_You, .Job_Failed:   return .Jobs
	}
	return .Finished
}

// The kinds that need the user (a burst's summary counts them).
NOTICE_OS_KINDS :: bit_set[Notice_Kind]{.Waiting, .Error, .Exited, .Job_Needs_You, .Job_Failed}

// When a group's entries also raise a macOS notification ("background": Deckhand is not in
// front). Default: the group's BELL_OS_DEFAULT (saved settings keep only what differs).
Os_When :: enum u8 {
	Default,
	Never,
	Background,
	Always,
}
OS_WHEN_NAMES := [Os_When]string{.Default = "", .Never = "never", .Background = "background", .Always = "always"}

// A group's sound: one of macOS's system sounds (/System/Library/Sounds, all there since
// macOS 12), played by name. Default: the group's BELL_SOUND_DEFAULT.
Bell_Sound :: enum u8 {
	Default,
	None,
	Tink,
	Glass,
	Pop,
	Ping,
	Purr,
	Hero,
	Bottle,
	Basso,
}
BELL_SOUND_NAMES := [Bell_Sound]string{.Default = "", .None = "none", .Tink = "tink", .Glass = "glass", .Pop = "pop", .Ping = "ping", .Purr = "purr", .Hero = "hero", .Bottle = "bottle", .Basso = "basso"}
// As macOS names the sound (NSSound soundNamed:) and the gear shows it.
BELL_SOUND_LABELS := [Bell_Sound]string{.Default = "", .None = "none", .Tink = "Tink", .Glass = "Glass", .Pop = "Pop", .Ping = "Ping", .Purr = "Purr", .Hero = "Hero", .Bottle = "Bottle", .Basso = "Basso"}

// Today's behaviour (before per-group settings: waiting, errors, exits and jobs that need you
// or failed notified in the background, finished runs never) and one sound, for needs you.
BELL_OS_DEFAULT := [Bell_Group]Os_When{.Finished = .Never, .Waiting = .Background, .Errors = .Background, .Jobs = .Background}
BELL_SOUND_DEFAULT := [Bell_Group]Bell_Sound{.Finished = .None, .Waiting = .Tink, .Errors = .None, .Jobs = .None}

// Sounds never stack: at most one this often (a burst's first one plays).
SOUND_FLOOR :: time.Second

bell_os_when :: proc(st: Settings, g: Bell_Group) -> Os_When {
	if st.bell_os_off do return .Never // an older core's (Settings.bell_os_off)
	v := st.bell_os[g]
	return v == .Default ? BELL_OS_DEFAULT[g] : v
}

// Every group's macOS is never: what older builds call "os": false (saved, and on the wire).
bell_os_all_never :: proc(st: Settings) -> bool {
	for g in Bell_Group do if bell_os_when(st, g) != .Never do return false
	return true
}

bell_sound_of :: proc(st: Settings, g: Bell_Group) -> Bell_Sound {
	v := st.bell_sound[g]
	return v == .Default ? BELL_SOUND_DEFAULT[g] : v
}

// The choice after this one, as the gear's buttons step through them (never Default).
os_when_next :: proc(v: Os_When) -> Os_When {return v == .Always ? .Never : Os_When(int(v) + 1)}
bell_sound_next :: proc(v: Bell_Sound) -> Bell_Sound {return v == max(Bell_Sound) ? .None : Bell_Sound(int(v) + 1)}

// Where an entry of this kind goes, given the settings and whether Deckhand is in front:
//   - bell: its group is on (bell_off);
//   - os: the group's macOS is always, or background while Deckhand is not in front;
//   - sound (.None = none): the group's sound, while Deckhand is not in front, or in front
//     too when its macOS is always.
// A job's finished run raises neither (the job's own notify setting does: jobs.odin). Pacing
// (notify_os) and the sound floor come after.
Notice_Channels :: struct {
	bell:  bool,
	os:    bool,
	front: bool, // the macOS notification is an "always" one: shown also while Deckhand is in front
	sound: Bell_Sound,
}

notice_channels :: proc(st: Settings, kind: Notice_Kind, active: bool) -> (c: Notice_Channels) {
	g := notice_group(kind)
	c.bell = g not_in st.bell_off
	c.sound = .None
	if kind == .Job_Finished do return
	w := bell_os_when(st, g)
	c.os = w == .Always || (w == .Background && !active)
	c.front = w == .Always
	if s := bell_sound_of(st, g); s != .None && (w == .Always || !active) do c.sound = s
	return
}

Notice :: struct {
	id:            u64,
	at:            time.Time,
	kind:          Notice_Kind,
	project_id:    u64, // sessions: its project (or Chats)
	session:       u64, // sessions: the open session id (0 = a job)
	tab_id:        u64, // sessions: its pi tab
	pi_session_id: string, // sessions: reopens it once it was closed
	title:         string, // the session's title, or the job's
	place:         string, // the project's name ("Chat" for a chat; "" for a job)
	summary:       string, // jobs: one line (shown in the bell, not listed to agents)
	job_id:        string,
	run_dir:       string, // jobs: where the run's output is
	read:          bool,
	claude:        bool, // .Exited: a Claude tab's, not pi's
	machine:       u64, // another machine's (machine_mirror.odin's mirror_alerts: its strings cleaned there; 0 = this Mac's)
}

Notices :: struct {
	items:   [dynamic]Notice, // oldest first; at most NOTICES_MAX
	os_sent: int, // OS notifications raised for entries (tests)
	// OS notification pacing (not in the snapshot): when each session or job
	// last raised one (dropped after NOTICE_COALESCE), and the current burst
	os_recent:   [dynamic]Os_Recent,
	burst_start: time.Time,
	burst_n:     int, // notifications wanted in the burst so far
	burst_need:  int, // of them, kinds that need the user (NOTICE_OS_KINDS): the summary's words
	sounds:      int, // sounds asked of the window (tests)
	sound_at:    time.Time, // the last one (SOUND_FLOOR)
}
Os_Recent :: struct {
	session: u64,
	job_id:  string,
	at:      time.Time,
}

NOTICES_MAX :: 200
NOTICE_COALESCE :: 10 * time.Second
NOTICE_TEXT_MAX :: 200 // bytes of a title, place or summary
NOTICE_BURST :: 5 * time.Second // OS notifications wanted within it: the first two, then one summary
NOTICE_BURST_SINGLE :: 2

// ---- jobs: the event the jobs code posts ----

Job_Status :: enum {
	Finished,
	Needs_You,
	Failed,
}
JOB_STATUS_NAMES := [Job_Status]string{.Finished = "finished", .Needs_You = "needs_you", .Failed = "failed"}

// job.finished: what a job run reports to the bell.
Job_Finished :: struct {
	job_id:  string,
	title:   string,
	status:  Job_Status,
	summary: string, // one line
	run_dir: string,
}

// Any thread: posts a job's result to the bell (through the inbox, as
// Deckhand itself).
notify_job_finished :: proc(ev: Job_Finished) {
	inbox_submit(Notify_Post{job = ev}, {kind = .Internal})
}

// ---- commands ----

Notifications_List :: struct { 	// query: the entries, newest first (titles and ids)
	limit: int, // 0 = NOTICES_LIST_DEFAULT
}
// Marks entries read: one (id), a session's (session) or all (all).
Notifications_Mark_Read :: struct {
	id:      u64,
	session: u64,
	all:     bool,
}
Notifications_Clear :: struct {} // removes every entry
Notify_Post :: struct { 	// internal: a job's result (notify_job_finished)
	job: Job_Finished,
}
// The bell's settings (this Mac's user only: never an agent, never another machine); unset
// fields keep their value.
Set_Bell :: struct {
	finished: Maybe(bool),
	waiting:  Maybe(bool),
	errors:   Maybe(bool),
	jobs:     Maybe(bool),
	// every group's macOS at once (the setting before per-group ones, and saved files from
	// then): false = never, true = the defaults (BELL_OS_DEFAULT); before macos
	os:       Maybe(bool),
	macos:    [Bell_Group]Maybe(Os_When), // per group (Default: its default)
	sound:    [Bell_Group]Maybe(Bell_Sound), // per group (Default: its default)
	dock:     Maybe(bool), // the Dock icon's badge: the sessions waiting for you
}

notify_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	items := &state.notices.items
	#partial switch c in cmd {
	case Notifications_List:
		return {ok = true, data = notices_json(c.limit, caller)}, false
	case Notifications_Mark_Read:
		n := 0
		switch {
		case c.id != 0:
			for &x in items^ do if x.id == c.id {
				if !x.read do n += 1
				x.read = true
				return {ok = true}, n > 0
			}
			return fail("no such notification"), false
		case c.session != 0:
			n = notify_mark_session(c.session)
		case c.all:
			for &x in items^ do if !x.read {
				x.read = true
				n += 1
			}
		case:
			return fail("give id, session or all"), false
		}
		return {ok = true}, n > 0
	case Notifications_Clear:
		if len(items) == 0 do return {ok = true}, false
		for &x in items^ do notice_free(&x)
		clear(items)
		return {ok = true}, true
	case Notify_Post:
		j := c.job
		if j.job_id == "" && j.title == "" do return fail("a job needs job_id or title"), false
		kind := Notice_Kind.Job_Finished
		if j.status == .Needs_You do kind = .Job_Needs_You
		if j.status == .Failed do kind = .Job_Failed
		title := j.title != "" ? j.title : j.job_id
		// its owner first (its project, Atlas, Chats), as another machine's say theirs (machine_mirror.odin)
		for r in state.jobs do if r.id == j.job_id do if owner := job_owner_title(r); owner != "" do title = fmt.tprintf("%s · %s", owner, title)
		n := Notice {
			kind    = kind,
			title   = notice_text(title),
			summary = notice_text(j.summary),
			job_id  = strings.clone(cut_utf8(j.job_id, NOTICE_TEXT_MAX)),
			run_dir = strings.clone(j.run_dir),
		}
		return {ok = true}, notice_post(n)
	case Set_Bell:
		st := &state.settings
		was_off, was_os, was_sound, was_dock, was_os_off := st.bell_off, st.bell_os, st.bell_sound, st.bell_dock_off, st.bell_os_off
		vals := [Bell_Group]Maybe(bool){.Finished = c.finished, .Waiting = c.waiting, .Errors = c.errors, .Jobs = c.jobs}
		for v, g in vals {
			on, set := v.?
			if !set do continue
			if on do st.bell_off -= {g}
			else do st.bell_off += {g}
		}
		if st.bell_os_off { 	// an older core's one switch: as per group
			st.bell_os_off = false
			for g in Bell_Group do st.bell_os[g] = .Never
		}
		if on, set := c.os.?; set do for g in Bell_Group do st.bell_os[g] = on ? .Default : .Never
		// kept as Default when it is the default (saved files keep only what differs)
		for v, g in c.macos do if w, set := v.?; set do st.bell_os[g] = w == BELL_OS_DEFAULT[g] ? .Default : w
		for v, g in c.sound do if s, set := v.?; set do st.bell_sound[g] = s == BELL_SOUND_DEFAULT[g] ? .Default : s
		if on, set := c.dock.?; set do st.bell_dock_off = !on
		st.bell_os_off = bell_os_all_never(st^)
		return {ok = true}, st.bell_off != was_off || st.bell_os != was_os || st.bell_sound != was_sound || st.bell_dock_off != was_dock || was_os_off
	}
	return fail("unknown command"), false
}

// ---- entries from other machines (machine_mirror.odin) ----

// Another machine's entry (n.machine set, its strings already cleaned and owned): posted as this
// Mac's are, its OS notification paced the same way.
notify_remote :: proc(n: Notice) -> bool {
	if n.machine == 0 do return false
	return notice_post(n)
}

// Machine no is gone (removed, Machines over SSH off): its entries leave the bell.
notify_drop_machine :: proc(no: u64) {
	items := &state.notices.items
	n := len(items)
	for i := len(items) - 1; i >= 0; i -= 1 do if items[i].machine == no {
		notice_free(&items[i])
		ordered_remove(items, i)
	}
	if len(items) != n do window_state_changed()
}

// ---- entries from sessions ----

// A pi tab's bridge status is about to change (Pi_Status_Update, before the
// tab takes it): a dialog that opens, an error, or a run that ended makes
// an entry.
notify_pi_status :: proc(s: ^Open_Session, tab: ^Tab, agent: Agent_State, waiting, question: bool) {
	if s == nil || tab == nil || s.home || agent == .Unknown do return
	// unknown: no bridge yet, or it reconnects; its first report restates
	// where pi is, it is not a change
	if tab.agent == .Unknown do return
	switch {
	case waiting && !tab.waiting:                  notify_session(s, tab, .Waiting)
	case agent == .Error && tab.agent != .Error:   notify_session(s, tab, .Error)
	case agent == .Idle && tab.agent == .Working:  notify_session(s, tab, question ? .Waiting : .Finished)
	}
}

// A tab's process exited (Tab_Exited): pi's makes an entry.
notify_tab_exited :: proc(s: ^Open_Session, tab: ^Tab, exit: Exit_Info = {}) {
	if s == nil || tab == nil || s.home do return
	// a Claude tab's error exit; not the user's own /exit (0) nor "not installed" (127: no restart loop)
	if _, is_claude := tab.kind.(Claude_Tab); is_claude {
		if exit.known && exit.signal == 0 && exit.code != 0 && exit.code != 127 do notify_session(s, tab, .Exited, claude = true)
		return
	}
	if _, is_pi := tab.kind.(Pi_Tab); !is_pi do return
	notify_session(s, tab, .Exited)
}

// An entry for a session, unless the user is looking at it (its pi tab, or
// with tab_shown the reporting tab itself: OSC 7501, agent_status.odin).
notify_session :: proc(s: ^Open_Session, tab: ^Tab, kind: Notice_Kind, tab_shown := false, claude := false) -> bool {
	if claude ? status_on_screen(s, tab.id) : (tab_shown ? status_on_screen(s, tab.id) : notify_on_screen(s.id)) do return false
	_, place := session_place(s)
	n := Notice {
		kind          = kind,
		project_id    = s.project_id,
		session       = s.id,
		tab_id        = tab.id,
		pi_session_id = strings.clone(s.pi_session_id),
		title         = notice_text(open_session_title(s)),
		place         = notice_text(place),
		claude        = claude,
	}
	return notice_post(n)
}

// An entry for something Deckhand could not do for the user (no session,
// no job): what, and why. In the bell whatever the groups: it answers the
// user's own action (Send to Atlas: the only word of where the text went);
// its banner and sound as the Errors row says.
notify_failed :: proc(what, why: string) {
	notice_post(Notice{kind = .Error, place = notice_text(what), title = notice_text(why)}, any_group = true)
}

// The session is on screen: current, its pi tab shown, the window in front.
notify_on_screen :: proc(session: u64) -> bool {
	return session != 0 && state.current_session == session && notify_pi_shown(session) && notify_window_active()
}

// The session's pi tab is shown (in any of its panes: panes.odin).
@(private = "file")
notify_pi_shown :: proc(session: u64) -> bool {
	s := find_session(session)
	if s != nil && s.agent == .Claude && len(s.tabs) > 0 do return session_tab_shown(s, s.tabs[0].id) // a Claude-only session's main tab
	pt := session_pi_tab(s)
	return pt != nil && session_tab_shown(s, pt.id)
}

// A page changed the user's clipboard during an agent's action (browser_act.odin): an entry in
// the bell, tied to the tab's session, whatever the groups.
notify_page_clipboard :: proc(tab_id: u64, what: string) {
	n := Notice{kind = .Error, title = notice_text(what), place = notice_text("Browser")}
	if s, _, _ := find_tab(tab_id); s != nil {
		n.session, n.project_id = s.id, s.project_id
		n.pi_session_id = strings.clone(s.pi_session_id)
		if pt := session_pi_tab(s); pt != nil do n.tab_id = pt.id
	}
	notice_post(n, any_group = true)
}

// The session on screen has unread entries (main.odin: the window coming to
// the front reads them; nothing is queued otherwise).
notify_wants_seen :: proc(session: u64) -> bool {
	if session == 0 || !notify_pi_shown(session) do return false
	s := find_session(session)
	for x in state.notices.items do if !x.read && (x.session == session || (x.pi_session_id != "" && x.pi_session_id == s.pi_session_id)) do return true
	return false
}

notify_window_active :: proc() -> bool {
	return window_is_active()
}

// The user sees this session now (focus_session): its entries are read,
// when its pi tab shows and the window is in front.
notify_seen :: proc(session: u64) {
	if notify_window_active() && notify_pi_shown(session) do notify_mark_session(session)
}

// Marks a session's entries read, also those from before it was closed and
// opened again (the same pi session).
notify_mark_session :: proc(session: u64) -> (n: int) {
	if session == 0 do return 0
	s := find_session(session)
	pid := s != nil ? s.pi_session_id : ""
	for &x in state.notices.items do if !x.read && (x.session == session || (pid != "" && x.pi_session_id == pid)) {
		x.read = true
		n += 1
	}
	return
}

notices_unread :: proc() -> (n: int) {
	for x in state.notices.items do if !x.read do n += 1
	return
}

// The test clock (0 = the real one).
notice_test_now: time.Time

notice_now :: proc() -> time.Time {
	return notice_test_now._nsec != 0 ? notice_test_now : time.now()
}

// Adds an entry (owning its strings): dropped when its group is off (unless
// any_group);
// replaces the last entry of the same session or job when that is younger
// than NOTICE_COALESCE; the oldest goes past NOTICES_MAX. Then the OS
// notification, unless the replaced entry was the same kind (no repeats
// while it flaps). Returns whether State changed.
@(private = "file")
notice_post :: proc(n: Notice, any_group := false) -> bool {
	n := n
	// quitting: pi processes ending are not news
	ch := notice_channels(state.settings, n.kind, notify_window_active())
	if app_quitting {
		notice_free(&n)
		return false
	}
	// not collected: its banner and sound still go as its row says (the columns are independent)
	if !any_group && !ch.bell {
		n.at = notice_now()
		notify_os(n, ch)
		notice_free(&n)
		return false
	}
	items := &state.notices.items
	n.id = new_id()
	n.at = notice_now()
	repeat := false
	#reverse for x, i in items^ {
		same := (n.session != 0 && x.session == n.session) || (n.job_id != "" && x.job_id == n.job_id)
		if !same do continue
		if time.diff(x.at, n.at) < NOTICE_COALESCE {
			repeat = x.kind == n.kind
			notice_free(&items[i])
			ordered_remove(items, i)
		}
		break
	}
	append(items, n)
	for len(items) > NOTICES_MAX {
		notice_free(&items[0])
		ordered_remove(items, 0)
	}
	if !repeat do notify_os(n, ch)
	return true
}

// The entry's macOS notification and sound (notice_channels). At most one
// per session (or job) per NOTICE_COALESCE, whatever the kind; of a burst
// (NOTICE_BURST_SINGLE + 1 or more wanted within NOTICE_BURST) the first
// ones go out, then one summary for the rest, then nothing until the burst
// is over. A sound plays with each that goes out, at most one per
// SOUND_FLOOR.
@(private = "file")
notify_os :: proc(n: Notice, ch: Notice_Channels) {
	os := ch.os && platform.notify != nil
	sound := ch.sound != .None && sound_reaches_window()
	if !os && !sound do return
	ns := &state.notices
	#reverse for r, i in ns.os_recent do if time.diff(r.at, n.at) >= NOTICE_COALESCE {
		delete(r.job_id)
		ordered_remove(&ns.os_recent, i)
	}
	for r in ns.os_recent do if (n.session != 0 && r.session == n.session) || (n.job_id != "" && r.job_id == n.job_id) do return
	append(&ns.os_recent, Os_Recent{session = n.session, job_id = strings.clone(n.job_id), at = n.at})
	if ns.burst_n == 0 || time.diff(ns.burst_start, n.at) >= NOTICE_BURST {
		ns.burst_start, ns.burst_n, ns.burst_need = n.at, 0, 0
	}
	ns.burst_n += 1
	if n.kind in NOTICE_OS_KINDS do ns.burst_need += 1
	notify := ch.front && platform.notify_front != nil ? platform.notify_front : platform.notify
	switch {
	case ns.burst_n <= NOTICE_BURST_SINGLE:
		title := n.place != "" ? fmt.tprintf("%s · %s", n.place, n.title) : n.title
		if os do notify(title, notice_label(n))
	case ns.burst_n == NOTICE_BURST_SINGLE + 1:
		// the rest of the burst in one, in words for what it holds; the bell lists them
		fin := ns.burst_n - ns.burst_need
		text: string
		switch {
		case fin == 0: text = fmt.tprintf("%d sessions need you", ns.burst_need)
		case ns.burst_need == 0: text = fmt.tprintf("%d sessions finished", fin)
		case: text = fmt.tprintf("%d sessions need you, %d finished", ns.burst_need, fin)
		}
		if os do notify("Deckhand", text)
	case:
		return
	}
	if sound && sound_floor_ok(ns.sound_at, n.at) {
		ns.sound_at = n.at
		ns.sounds += 1
		window_sound(BELL_SOUND_LABELS[ch.sound])
	}
	if os do ns.os_sent += 1
	window_state_changed() // State.notices: not always inside a command that says it changed
}

// A sound may play at `now`: none played within SOUND_FLOOR before it (last: the last one's
// time, zero = none yet).
sound_floor_ok :: proc(last, now: time.Time) -> bool {
	return last._nsec == 0 || time.diff(last, now) >= SOUND_FLOOR || time.diff(last, now) < 0
}

// A sound reaches this Mac's window: one is attached, and it is not another machine's core
// viewing this one (a hub: that machine rings for this one's bell itself, machine_mirror.odin).
@(private = "file")
sound_reaches_window :: proc() -> bool {
	return window_attached() && !window_link_hub()
}

// What happened, in words: "Finished", "Waiting for you", …
notice_label :: proc(n: Notice) -> string {
	switch n.kind {
	case .Finished:      return "Finished"
	case .Waiting:       return "Waiting for you"
	case .Error:         return n.session == 0 && n.job_id == "" ? "Did not work" : "Stopped with an error" // notify_failed's
	case .Exited:        return n.claude ? "Claude exited" : "pi exited"
	case .Job_Finished:  return "Job finished"
	case .Job_Needs_You: return "Job needs you"
	case .Job_Failed:    return "Job failed"
	}
	return ""
}

@(private = "file")
notice_text :: proc(s: string) -> string {
	return strings.clone(cut_utf8(one_line(s, context.temp_allocator), NOTICE_TEXT_MAX))
}

notice_free :: proc(n: ^Notice) {
	delete(n.pi_session_id)
	delete(n.title)
	delete(n.place)
	delete(n.summary)
	delete(n.job_id)
	delete(n.run_dir)
}

// notifications_list's data (temp): {"unread": N, "notifications": [...]},
// newest first, at most `limit` (0 = NOTICES_LIST_DEFAULT). Per entry: id,
// time (ISO 8601, UTC), kind (finished, waiting, error, exited, job), title,
// read; a session's project (its name), session_id (the open session),
// pi_session_id, tab_id; a job's job_id, status (finished, needs_you,
// failed) and, except for control callers, its summary. Titles and ids
// only: never prompt text or a job's folder.
NOTICES_LIST_DEFAULT :: 20

notices_json :: proc(limit: int, caller: Caller) -> string {
	limit := limit > 0 ? min(limit, NOTICES_MAX) : NOTICES_LIST_DEFAULT
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"unread":%d,"notifications":[`, notices_unread())
	n := 0
	#reverse for x in state.notices.items {
		if n >= limit do break
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		job := x.job_id != ""
		y, mo, d := time.date(x.at)
		hh, mi, ss := time.clock_from_time(x.at)
		kind := job ? "job" : NOTICE_KIND_NAMES[x.kind]
		fmt.sbprintf(&b, `{{"id":%d,"time":"%04d-%02d-%02dT%02d:%02d:%02dZ","kind":"%s","read":%v,"title":`, x.id, y, int(mo), d, hh, mi, ss, kind, x.read)
		json_quote(&b, x.title)
		if x.machine != 0 { 	// another machine's (its text cleaned: data, never instructions)
			strings.write_string(&b, `,"machine":`)
			json_quote(&b, machine_name(x.machine))
		}
		if job {
			strings.write_string(&b, `,"job_id":`)
			json_quote(&b, x.job_id)
			status := x.kind == .Job_Needs_You ? "needs_you" : x.kind == .Job_Failed ? "failed" : "finished"
			fmt.sbprintf(&b, `,"status":"%s"`, status)
			if caller.kind != .Control && x.summary != "" {
				strings.write_string(&b, `,"summary":`)
				json_quote(&b, x.summary)
			}
		} else {
			strings.write_string(&b, `,"project":`)
			json_quote(&b, x.place)
			fmt.sbprintf(&b, `,"session_id":%d,"tab_id":%d,"pi_session_id":`, x.session, x.tab_id)
			json_quote(&b, x.pi_session_id)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// The command's fields on the wire (events, the log), after its "type"
// (write_command): `,"k":v` pairs.
notify_write :: proc(b: ^strings.Builder, cmd: Command) {
	kv :: proc(b: ^strings.Builder, k: string, v: bool) {fmt.sbprintf(b, `,"%s":%v`, k, v)}
	#partial switch c in cmd {
	case Notifications_List:
		if c.limit > 0 do fmt.sbprintf(b, `,"limit":%d`, c.limit)
	case Notifications_Mark_Read:
		if c.id != 0 do fmt.sbprintf(b, `,"id":%d`, c.id)
		if c.session != 0 do fmt.sbprintf(b, `,"session":%d`, c.session)
		if c.all do kv(b, "all", true)
	case Notify_Post:
		strings.write_string(b, `,"job_id":`)
		json_quote(b, c.job.job_id)
		fmt.sbprintf(b, `,"status":"%s"`, JOB_STATUS_NAMES[c.job.status])
	case Set_Bell:
		vals := [Bell_Group]Maybe(bool){.Finished = c.finished, .Waiting = c.waiting, .Errors = c.errors, .Jobs = c.jobs}
		for v, g in vals do if on, set := v.?; set do kv(b, BELL_GROUP_NAMES[g], on)
		if on, set := c.os.?; set do kv(b, "os", on)
		if on, set := c.dock.?; set do kv(b, "dock", on)
		// {"macos":{"waiting":"always"},"sound":{"waiting":"tink"}}: the groups set
		obj :: proc(b: ^strings.Builder, k: string, vals: [Bell_Group]Maybe($E), names: [E]string) {
			n := 0
			for v, g in vals do if x, set := v.?; set {
				if n == 0 do fmt.sbprintf(b, `,"%s":{{`, k)
				else do strings.write_byte(b, ',')
				fmt.sbprintf(b, `"%s":"%s"`, BELL_GROUP_NAMES[g], names[x] != "" ? names[x] : "default")
				n += 1
			}
			if n > 0 do strings.write_byte(b, '}')
		}
		obj(b, "macos", c.macos, OS_WHEN_NAMES)
		obj(b, "sound", c.sound, BELL_SOUND_NAMES)
	}
}
