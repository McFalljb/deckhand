package core

// A browser tab's facts (browser_facts.odin): the window's typed message round-trips, and the
// core writes them as the window's hook wrote get_state's members before.

import "base:runtime"
import "core:testing"
import "core:strings"
import cw "../corewire"

@(test)
browser_facts_round_trip_and_form :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Browser_Facts {
		annot = true, comment_mode = true, annot_ready = true, doc_url = "https://x.test/a",
		markers = []Browser_Marker_Fact{{comment_id = 4, n = 1, area = true, selector = "#a", url = "https://x.test/a", box = "1,2 3x4", where_ = "here", badge = "5,6"}},
		zoom = 1.2, extras = true,
		dialog = Browser_Dialog_Fact{kind = "confirm", message = "sure?", origin = "https://x.test"},
		permission = Browser_Permission_Fact{what = "camera,microphone", origin = "https://x.test"},
		download_ask = Browser_Ask_Fact{id = 9, name = "f.zip"},
		popups_blocked = 2,
		find = Browser_Find_Fact{text = "q", matches = 3, active = 1},
		downloads = []Browser_Download_Fact{{id = 1, name = "a", path = "/d/a", state = "done", received = 10, total = 10}},
		agent = Browser_Agent_Fact{who = "pi", doing = "reading", busy = true, recording = "", target = "#b", acting = true, user = true},
		upload_ask = Browser_Upload_Fact{files = []string{"r.pdf"}, who = "pi"},
	}
	b := strings.builder_make(context.temp_allocator)
	browser_facts_write(&b, &f)
	want := `,"mode":"comment","annot_ready":true,"doc_url":"https://x.test/a","markers":[{"comment_id":4,"n":1,"kind":"area","selector":"#a","url":"https://x.test/a","box":"1,2 3x4","where":"here","badge":"5,6"}],"zoom":1.2,"crashed":false,"devtools":false,"dialog":{"kind":"confirm","message":"sure?","origin":"https://x.test"},"permission":{"what":"camera,microphone","origin":"https://x.test"},"download_ask":{"id":9,"name":"f.zip"},"popups_blocked":2,"find":{"text":"q","matches":3,"active":1},"downloads":[{"id":1,"name":"a","path":"/d/a","state":"done","received":10,"total":10,"dismissed":false,"quarantined":false}],"agent":{"who":"pi","doing":"reading","busy":true,"recording":"","target":"#b","acting":true,"control":"user"},"upload_ask":{"files":["r.pdf"],"who":"pi"}`
	testing.expect_value(t, strings.to_string(b), want)
	empty: Browser_Facts
	b2 := strings.builder_make(context.temp_allocator)
	browser_facts_write(&b2, &empty)
	testing.expect_value(t, strings.to_string(b2), `,"zoom":1,"crashed":false,"devtools":false`)

	// over the link: what the core keeps writes the same
	state = State{}
	end, _ := core_attach_window(proc() {})
	defer core_detach_window()
	tf := Tab_Facts{browser = f, page = "open"}
	_ = cw.mem_send(end, cw.JSON_CHANNEL, .Data, transmute([]u8)window_msg_tab_facts(7, &tf))
	window_link_pump()
	b3 := strings.builder_make(context.temp_allocator)
	window_browser_json(&b3, 7)
	testing.expect_value(t, strings.to_string(b3), want)
	testing.expect_value(t, window_browser_page(7), "open")
	_ = cw.mem_send(end, cw.JSON_CHANNEL, .Data, transmute([]u8)window_msg_tab_facts(7, nil))
	window_link_pump()
	testing.expect(t, window_tab_facts(7) == nil, "gone")
}
