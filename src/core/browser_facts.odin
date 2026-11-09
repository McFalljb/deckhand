package core

// What only the window knows of a browser tab's page, for its object in get_state (design §10.2,
// an M3 must-do): comment mode and markers, zoom, the page's bars and downloads, the agent strip,
// an upload's ask. It was a hook that wrote raw JSON members into the core's output; now the
// window sends it typed (Tab_Facts.browser in window.tab_facts, window_link.odin) and the core
// writes it (browser_facts_write), so nothing the window says becomes JSON the core did not shape.

import "core:fmt"
import "core:math"
import "core:strings"

Browser_Marker_Fact :: struct {
	comment_id: u64,
	n:          int, // its number in the session's comments (1-based)
	area:       bool, // an area, else an element
	selector:   string,
	url:        string,
	box:        string, // "x,y wxh" (document px)
	where_:     string, // where it is on the page (ANNOT_WHERE_NAMES)
	badge:      string, // "x,y" (the badge's place)
}

Browser_Dialog_Fact :: struct {
	kind, message, origin: string,
}

Browser_Permission_Fact :: struct {
	what, origin: string,
}

Browser_Ask_Fact :: struct {
	id:   u64,
	name: string,
}

Browser_Find_Fact :: struct {
	text:    string,
	matches: int,
	active:  int,
}

Browser_Download_Fact :: struct {
	id:          u64,
	name, path:  string,
	state:       string, // DOWNLOAD_STATE_NAMES
	received:    i64,
	total:       i64,
	dismissed:   bool,
	quarantined: bool,
}

Browser_Agent_Fact :: struct {
	who:       string,
	doing:     string, // AGENT_DOING_NAMES
	busy:      bool,
	recording: string,
	target:    string, // "" = none
	acting:    bool,
	user:      bool, // the user took over (control: user)
}

Browser_Upload_Fact :: struct {
	files: []string, // base names
	who:   string,
}

Browser_Facts :: struct {
	annot:          bool, // the annotation layer exists: mode, annot_ready, doc_url, markers
	comment_mode:   bool,
	annot_ready:    bool,
	doc_url:        string,
	markers:        []Browser_Marker_Fact,
	zoom:           f64, // the zoom factor (1 = 100%; 0 = not set, 100%)
	crashed:        bool,
	devtools:       bool,
	extras:         bool, // the page's bars exist: what follows
	dialog:         Maybe(Browser_Dialog_Fact),
	permission:     Maybe(Browser_Permission_Fact),
	download_ask:   Maybe(Browser_Ask_Fact),
	popups_blocked: int,
	find:           Maybe(Browser_Find_Fact),
	downloads:      []Browser_Download_Fact,
	agent:          Maybe(Browser_Agent_Fact),
	upload_ask:     Maybe(Browser_Upload_Fact),
}

// The members of a browser tab's object in get_state, as `,"key":value` (the order the window's
// hook wrote them in).
browser_facts_write :: proc(b: ^strings.Builder, f: ^Browser_Facts) {
	q :: json_quote
	if f.annot {
		fmt.sbprintf(b, `,"mode":"%s","annot_ready":%v,"doc_url":`, f.comment_mode ? "comment" : "browse", f.annot_ready)
		q(b, f.doc_url)
		strings.write_string(b, `,"markers":[`)
		for m, i in f.markers {
			if i > 0 do strings.write_byte(b, ',')
			fmt.sbprintf(b, `{{"comment_id":%d,"n":%d,"kind":"%s","selector":`, m.comment_id, m.n, m.area ? "area" : "element")
			q(b, m.selector)
			strings.write_string(b, `,"url":`)
			q(b, m.url)
			strings.write_string(b, `,"box":`)
			q(b, m.box)
			strings.write_string(b, `,"where":`)
			q(b, m.where_)
			strings.write_string(b, `,"badge":`)
			q(b, m.badge)
			strings.write_byte(b, '}')
		}
		strings.write_byte(b, ']')
	}
	fmt.sbprintf(b, `,"zoom":%s,"crashed":%v,"devtools":%v`, browser_zoom_json(f.zoom), f.crashed, f.devtools)
	if f.extras {
		if d, ok := f.dialog.?; ok {
			strings.write_string(b, `,"dialog":{"kind":`)
			q(b, d.kind)
			strings.write_string(b, `,"message":`)
			q(b, d.message)
			strings.write_string(b, `,"origin":`)
			q(b, d.origin)
			strings.write_byte(b, '}')
		}
		if p, ok := f.permission.?; ok {
			strings.write_string(b, `,"permission":{"what":`)
			q(b, p.what)
			strings.write_string(b, `,"origin":`)
			q(b, p.origin)
			strings.write_byte(b, '}')
		}
		if a, ok := f.download_ask.?; ok {
			fmt.sbprintf(b, `,"download_ask":{{"id":%d,"name":`, a.id)
			q(b, a.name)
			strings.write_byte(b, '}')
		}
		if f.popups_blocked > 0 do fmt.sbprintf(b, `,"popups_blocked":%d`, f.popups_blocked)
		if fd, ok := f.find.?; ok {
			strings.write_string(b, `,"find":{"text":`)
			q(b, fd.text)
			fmt.sbprintf(b, `,"matches":%d,"active":%d}}`, fd.matches, fd.active)
		}
		for d, i in f.downloads {
			strings.write_string(b, i == 0 ? `,"downloads":[` : ",")
			fmt.sbprintf(b, `{{"id":%d,"name":`, d.id)
			q(b, d.name)
			strings.write_string(b, `,"path":`)
			q(b, d.path)
			strings.write_string(b, `,"state":`)
			q(b, d.state)
			fmt.sbprintf(b, `,"received":%d,"total":%d,"dismissed":%v,"quarantined":%v}}`, d.received, d.total, d.dismissed, d.quarantined)
		}
		if len(f.downloads) > 0 do strings.write_byte(b, ']')
	}
	if a, ok := f.agent.?; ok {
		strings.write_string(b, `,"agent":{"who":`)
		q(b, a.who)
		strings.write_string(b, `,"doing":`)
		q(b, a.doing)
		fmt.sbprintf(b, `,"busy":%v,"recording":`, a.busy)
		q(b, a.recording)
		if a.target != "" {
			strings.write_string(b, `,"target":`)
			q(b, a.target)
		}
		if a.acting do strings.write_string(b, `,"acting":true`)
		if a.user do strings.write_string(b, `,"control":"user"`)
		strings.write_byte(b, '}')
	}
	if u, ok := f.upload_ask.?; ok {
		strings.write_string(b, `,"upload_ask":{"files":[`)
		for x, i in u.files {
			if i > 0 do strings.write_byte(b, ',')
			q(b, x)
		}
		strings.write_string(b, `],"who":`)
		q(b, u.who)
		strings.write_byte(b, '}')
	}
}

// A zoom factor as get_state writes it: two decimals, trailing zeros off ("1.2", "1", "0.83").
browser_zoom_json :: proc(factor: f64) -> string {
	f := factor
	if math.is_nan(f) || math.is_inf(f) || f <= 0 do f = 1 // 0: not set (100%)
	s := fmt.tprintf("%.2f", f)
	s = strings.trim_right(s, "0")
	return strings.trim_right(s, ".")
}
