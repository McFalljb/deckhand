package main

// Engine bridge step 2, the parts that need no GPU or second process:
// app_call's passthrough envelope (any method of the app's own, Deckhand's
// reserved ones refused, params kept), the app's replies kept as sent,
// app_screenshot's crop and the app's inspect boxes. The live side is the
// app-tab scene (tests/scripts/app-tab.sh).

import "base:runtime"
import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
app_call_parses_method_and_params :: proc(t: ^testing.T) {
	c, err := parse_command(`{"type":"app_call","tab_id":4,"method":"game.get","params":{"path":"square"},"timeout_ms":500}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	ac := c.(App_Call)
	testing.expect_value(t, ac.method, "game.get")
	testing.expect_value(t, ac.params, `{"path":"square"}`)
	testing.expect_value(t, ac.timeout_ms, 500)
	c, err = parse_command(`{"type":"app_call","tab_id":4,"method":"tab.describe"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(App_Call).params, "")
	_, err = parse_command(`{"type":"app_call","tab_id":4,"method":"game.get","params":[1]}`, context.temp_allocator)
	testing.expect(t, err != "", "params must be an object")
	_, err = parse_command(`{"type":"app_call","tab_id":4,"method":7}`, context.temp_allocator)
	testing.expect(t, err != "", "method must be a string")
}

// Only the envelope is checked: any method name of the app's own goes
// through; Deckhand's own (lifecycle, visibility) and the envelope's message
// types are refused, as are params that would set envelope fields.
@(test)
app_call_checks_only_the_envelope :: proc(t: ^testing.T) {
	ok :: proc(t: ^testing.T, method, params: string) {
		e, _ := app_call_check(method, params)
		testing.expectf(t, e == "", "%s %s: %s", method, params, e)
	}
	bad :: proc(t: ^testing.T, method, params, want_code: string) {
		e, code := app_call_check(method, params)
		testing.expectf(t, e != "" && code == want_code, "%s %s: refused with %s (got %q %q)", method, params, want_code, e, code)
	}
	ok(t, "tab.describe", "")
	ok(t, "game.get", `{"path":"square"}`)
	ok(t, "tab.ping", "") // harmless: Deckhand's own pings use their own wire ids
	ok(t, "editor:spawn_entity", `{}`)
	ok(t, "a", "")
	bad(t, "", "", "bad_args")
	bad(t, strings.repeat("m", APP_METHOD_MAX + 1, context.temp_allocator), "", "bad_args")
	bad(t, "game get", "", "bad_args")
	bad(t, "game.get\n", "", "bad_args")
	bad(t, `game"get`, "", "bad_args")
	bad(t, "ünïcode", "", "bad_args")
	bad(t, ".get", "", "bad_args") // starts with a letter
	for m in ([]string{"tab.quit", "tab.visible", "tab.display", "hello", "result", "event", "input"}) do bad(t, m, "", "reserved")
	for k in ([]string{"id", "v", "type"}) do bad(t, "game.get", strings.concatenate({`{"`, k, `":1}`}, context.temp_allocator), "bad_args")
	big := strings.concatenate({`{"s":"`, strings.repeat("x", APP_PARAMS_MAX, context.temp_allocator), `"}`}, context.temp_allocator)
	bad(t, "game.set", big, "bad_args")
}

// The line to the app: our id and the envelope's version, the method as
// `type`, then the params' fields as given.
@(test)
app_call_line_keeps_the_params :: proc(t: ^testing.T) {
	testing.expect_value(t, app_call_line("a5", "game.get", `{"path":"square","depth":2}`), `{"id":"a5","v":1,"type":"game.get","path":"square","depth":2}`)
	testing.expect_value(t, app_call_line("a6", "tab.describe", ""), `{"id":"a6","v":1,"type":"tab.describe"}`)
	testing.expect_value(t, app_call_line("a7", "tab.describe", "{}"), `{"id":"a7","v":1,"type":"tab.describe"}`)
	testing.expect_value(t, app_call_line("a8", "x", ` { } `), `{"id":"a8","v":1,"type":"x"}`)
	_, err := json.parse_string(app_call_line("a9", "game.set", `{"value":{"x":1.5,"y":[1,2]}}`), .JSON, true, context.temp_allocator)
	testing.expect(t, err == nil, "one JSON object")
}

// The app's reply is passed back as sent: its data verbatim (no re-marshal:
// tiny floats, integers past i64, escaped keys survive); an error keeps its
// code and the app's other fields (traceback, path, …) in data.
@(test)
app_results_are_kept_as_sent :: proc(t: ^testing.T) {
	r, valid := app_result_of(`{"id":"a3","v":1,"type":"result","result":{"ok":true,"data":{"f":1e-20,"n":12345678901234567890,"k\u0001":true}}}`)
	testing.expect(t, valid, "a result line")
	testing.expect_value(t, r.id, "a3")
	testing.expect(t, r.ok, "ok")
	testing.expect_value(t, r.data, `{"f":1e-20,"n":12345678901234567890,"k\u0001":true}`)
	r, valid = app_result_of(`{"id":"a4","v":1,"type":"result","result":{"ok":false,"error":"no field 'hpp'","code":"no_path","path":"entities[e:1:1].hpp","at":"hpp"}}`)
	testing.expect(t, valid && !r.ok, "an error")
	testing.expect_value(t, r.error, "no field 'hpp'")
	testing.expect_value(t, r.code, "no_path")
	testing.expect_value(t, r.data, `{"code":"no_path","path":"entities[e:1:1].hpp","at":"hpp"}`)
	r, valid = app_result_of(`{"id":"a5","type":"result","result":{"ok":true}}`)
	testing.expect(t, valid && r.ok && r.data == "{}", "no data: {}")
	// not one JSON object: refused
	_, valid = app_result_of(`{"id":"a6","type":"result","result":{"ok":true,"data":1}} {"x":1}`)
	testing.expect(t, !valid, "trailing tokens refused")
	_, valid = app_result_of(`{"id":"a6","type":"result","result":[1]}`)
	testing.expect(t, !valid, "result must be an object")
	// whatever the data, the finished result is one JSON value
	r, valid = app_result_of(`{"id":"a7","type":"result","result":{"ok":true,"data":[1,{"a":"}]"}]}}`)
	testing.expect(t, valid, "array data")
	_, err := json.parse_string(r.data, .JSON, true, context.temp_allocator)
	testing.expect(t, err == nil, r.data)
}

// The crop is in the tab's logical px: times the ring's scale, clamped to
// the surface; nothing left is refused. No rect: the whole frame.
@(test)
app_screenshot_rect_is_clamped :: proc(t: ^testing.T) {
	x, y, w, h, ok := app_shot_rect({}, false, 2, 800, 600)
	testing.expect(t, ok && x == 0 && y == 0 && w == 800 && h == 600, "the whole frame")
	x, y, w, h, ok = app_shot_rect({x = 10, y = 20, w = 30, h = 40}, true, 2, 800, 600)
	testing.expect(t, ok && x == 20 && y == 40 && w == 60 && h == 80, "logical px times the scale")
	x, y, w, h, ok = app_shot_rect({x = -10, y = 290, w = 100, h = 100}, true, 2, 800, 600)
	testing.expect(t, ok && x == 0 && y == 580 && w == 180 && h == 20, "clamped to the surface")
	_, _, _, _, ok = app_shot_rect({x = 500, y = 10, w = 10, h = 10}, true, 2, 800, 600)
	testing.expect(t, !ok, "outside the frame")
	_, _, _, _, ok = app_shot_rect({x = 1, y = 1, w = 0, h = 10}, true, 1, 800, 600)
	testing.expect(t, !ok, "empty")
	c, err := parse_command(`{"type":"app_screenshot","tab_id":4,"rect":{"x":1,"y":2,"w":3,"h":4.5}}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	sc := c.(App_Screenshot)
	testing.expect(t, sc.tab_id == 4 && sc.has_rect && sc.rect.w == 3 && sc.rect.h == 4.5, "rect parsed")
	c, err = parse_command(`{"type":"app_screenshot","tab_id":4}`, context.temp_allocator)
	testing.expect(t, err == "" && !c.(App_Screenshot).has_rect, "no rect: the whole frame")
	_, err = parse_command(`{"type":"app_screenshot","tab_id":4,"rect":{"x":1}}`, context.temp_allocator)
	testing.expect(t, err != "", "a rect needs x, y, w, h")
	testing.expect(t, caller_may({kind = .Control}, App_Screenshot{}), "control may take screenshots")
	testing.expect(t, !caller_may({kind = .App, tab_id = 4}, App_Screenshot{}), "an app may not")
}

// tab.boxes: the app's list of {id, label, rect} in tab px replaces the last
// one; bad entries are skipped, the count and the strings capped.
@(test)
app_boxes_are_parsed_and_capped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	boxes, ok := app_boxes_parse(`{"type":"event","event":"tab.boxes","boxes":[{"id":"e:1:1","label":"square","rect":{"x":20,"y":40,"w":40,"h":40}},{"id":"e:2:1","rect":{"x":20,"y":120,"w":200,"h":20}},{"label":"no id","rect":{"x":0,"y":0,"w":1,"h":1}},{"id":"e:9:1","label":"no rect"},{"id":"e:3:1","label":"coin","rect":{"x":300,"y":200,"w":16.5,"h":16}}]}`)
	defer app_boxes_free(boxes)
	testing.expect(t, ok, "parsed")
	testing.expect_value(t, len(boxes), 3)
	testing.expect(t, boxes[0].id == "e:1:1" && boxes[0].label == "square" && boxes[0].rect == App_Rect{20, 40, 40, 40}, "the square")
	testing.expect(t, boxes[1].label == "e:2:1", "no label: the id")
	testing.expect_value(t, boxes[2].rect.w, f32(16.5))
	// hit: the last box listed that holds the point (drawn on top)
	testing.expect_value(t, app_box_at(boxes, 30, 50), 0)
	testing.expect_value(t, app_box_at(boxes, 305, 205), 2)
	testing.expect_value(t, app_box_at(boxes, 5, 5), -1)
	over := []App_Box{{id = "a", rect = {0, 0, 100, 100}}, {id = "b", rect = {10, 10, 10, 10}}}
	testing.expect_value(t, app_box_at(over, 15, 15), 1)
	// capped
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"event":"tab.boxes","boxes":[`)
	for i in 0 ..< APP_BOXES_MAX + 20 {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"id":"x","label":"`)
		strings.write_string(&b, strings.repeat("L", APP_BOX_LABEL_MAX + 50, context.temp_allocator))
		strings.write_string(&b, `","rect":{"x":0,"y":0,"w":1,"h":1}}`)
	}
	strings.write_string(&b, `]}`)
	many, mok := app_boxes_parse(strings.to_string(b))
	defer app_boxes_free(many)
	testing.expect(t, mok && len(many) == APP_BOXES_MAX, "at most APP_BOXES_MAX")
	testing.expect(t, len(many[0].label) <= APP_BOX_LABEL_MAX + len("…"), "labels capped")
	_, bad := app_boxes_parse(`{"event":"tab.boxes","boxes":{"e:1:1":{"x":1}}}`)
	testing.expect(t, !bad, "boxes must be a list")
	empty, eok := app_boxes_parse(`{"event":"tab.boxes","boxes":[]}`)
	testing.expect(t, eok && len(empty) == 0, "an empty list clears them")
}

@(test)
app_inspect_parses :: proc(t: ^testing.T) {
	c, err := parse_command(`{"type":"app_inspect","tab_id":4,"on":true}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, c.(App_Inspect).on && c.(App_Inspect).tab_id == 4, "on")
	testing.expect(t, caller_may({kind = .Control}, App_Inspect{}), "control may toggle it")
}

// An app's own method may be called "app_screenshot": when the app exits, a
// call of it fails at once like any other (only Deckhand's own screenshots,
// whose frame is copied already, go on).
@(test)
app_exit_fails_calls_whatever_their_method :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // global maps outlive the test
	pending[strings.clone("a901")] = {tab_id = 9, request_id = 0, type = strings.clone("app_screenshot"), deadline = time.tick_add(time.tick_now(), time.Second)}
	pending[strings.clone("s902")] = {tab_id = 9, request_id = 0, type = strings.clone(APP_SHOT_TYPE), deadline = time.tick_add(time.tick_now(), time.Second)}
	defer app_fail_pending(9, "", "")
	app_fail_pending(9, "the app exited", "tab_gone", shots = false)
	testing.expect(t, !("a901" in pending), "the app's own method named app_screenshot: failed")
	testing.expect(t, "s902" in pending, "Deckhand's screenshot: goes on")
}

// Review round 1, finding 1: an app's result can never finish Deckhand's own
// screenshot (an "s…" wire), and a worker's never an app call.
@(test)
app_results_cannot_forge_screenshots :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pending[strings.clone("s950")] = {tab_id = 7, type = strings.clone(APP_SHOT_TYPE), deadline = time.tick_add(time.tick_now(), time.Second)}
	pending[strings.clone("a951")] = {tab_id = 7, type = strings.clone("game.get"), deadline = time.tick_add(time.tick_now(), time.Second)}
	defer app_fail_pending(7, "", "")
	app_apply(App_Call_Done{tab_id = 7, wire = "s950", ok = true, data = `{"path":"/etc/passwd"}`}, {kind = .Internal}, 0)
	testing.expect(t, "s950" in pending, "the app's forged reply to a screenshot is ignored")
	app_apply(App_Call_Done{tab_id = 7, wire = "a951", ok = true, data = "{}", from_worker = true}, {kind = .Internal}, 0)
	testing.expect(t, "a951" in pending, "a worker cannot finish an app call")
	app_apply(App_Call_Done{tab_id = 7, wire = "s950", ok = true, data = "{}", from_worker = true}, {kind = .Internal}, 0)
	testing.expect(t, !("s950" in pending), "the worker finishes its screenshot")
}

// Finding 2 and 5: lines from apps are strict RFC 8259 JSON, nested at most
// JSON_MAX_DEPTH; core:encoding/json's .JSON mode accepts more.
@(test)
app_json_is_strict :: proc(t: ^testing.T) {
	for bad in ([]string{`{"a":"a\'b"}`, `{"a":"\uzzzz"}`, `[1,2,]`, `{"a":1,}`, `01`, "{\v\"a\":1}", `{"a":1} {"b":2}`, `{'a':1}`, `{a:1}`, `[1 2]`, `{"a" 1}`, `"x`, "\"a\tb\"", `-`, `1.`, `.5`, `1e`, `+1`, `NaN`, `[true,tru]`, `nul`, `{"a":1`, ``, `  `, "\"\xff\""}) {
		testing.expectf(t, !json_valid(bad), "refused: %q", bad)
	}
	for good in ([]string{`{"a":1}`, ` {"a" : [1, -2.5e-3, 0, 1E+9, true, false, null, "x\"\\\/\b\f\n\r\té"]} `, `{"f":1e400,"n":12345678901234567890}`, `[]`, `{}`, `"é"`, `0`, `[[[]]]`}) {
		testing.expectf(t, json_valid(good), "accepted: %q", good)
	}
	deep := strings.concatenate({strings.repeat("[", JSON_MAX_DEPTH + 1, context.temp_allocator), strings.repeat("]", JSON_MAX_DEPTH + 1, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, !json_valid(deep), "too deep")
	ok := strings.concatenate({strings.repeat("[", JSON_MAX_DEPTH, context.temp_allocator), strings.repeat("]", JSON_MAX_DEPTH, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, json_valid(ok), "deep enough")
	// replies and events with invalid JSON are refused, not passed on
	_, valid := app_result_of(`{"id":"a1","type":"result","result":{"ok":true,"data":{"a":"a\'b"}}}`)
	testing.expect(t, !valid, "an invalid reply is refused")
	_, valid = app_result_of(`{"id":"a1","type":"result","result":{"ok":true,"data":[1,2,]}}`)
	testing.expect(t, !valid, "a trailing comma is refused")
	context.allocator = runtime.heap_allocator()
	tab: u64 = 994
	defer app_events_forget(tab)
	app_event_in(tab, "tab.log", `{"type":"event","event":"tab.log","text":"\uzzzz"}`)
	app_event_in(tab, "tab.log", `{"type":"event","event":"tab.log","n":01}`)
	testing.expect(t, strings.count(app_events_json(tab, "log", 0, 10), `"seq":`) == 0, "invalid events are refused")
}

// Finding 4: params go to the app as the caller wrote them (no re-marshal:
// big integers, 1e400 and the key order survive), and must be strict JSON.
@(test)
app_call_params_are_kept_raw :: proc(t: ^testing.T) {
	c, err := parse_command(`{"type":"app_call","tab_id":4,"method":"m","params":{"z":1,"a":12345678901234567890,"f":1e400}}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(App_Call).params, `{"z":1,"a":12345678901234567890,"f":1e400}`)
	m, merr := parse_request(`{"id":"h1","v":1,"type":"command","command":{"type":"app_call","tab_id":4,"method":"m","params":{"z":[1,2],"a":-0.0}}}`, context.temp_allocator)
	testing.expect_value(t, merr, "")
	testing.expect_value(t, m.command.(App_Call).params, `{"z":[1,2],"a":-0.0}`)
	_, err = parse_command(`{"type":"app_call","tab_id":4,"method":"m","params":{"a":1,}}`, context.temp_allocator)
	testing.expect(t, err != "", "params must be strict JSON")
	// reserved names in any case
	e, code := app_call_check("TAB.Quit", "")
	testing.expect(t, e != "" && code == "reserved", "reserved in any case")
	e, code = app_call_check("Input", "")
	testing.expect(t, e != "" && code == "reserved", "Input reserved")
}

// Review round 2: a raw CR or LF (JSON whitespace outside strings) would be a
// line end to Node's readline or Python's text mode, so a caller could
// smuggle a second line ({"type":"tab.quit"}, an input) to the app.
@(test)
app_call_refuses_raw_line_breaks :: proc(t: ^testing.T) {
	for p in ([]string{"{\"a\":\r1}", "{\"a\":1\n}", "{\"a\":1}\r", "\n{\"a\":1}"}) {
		e, code := app_call_check("m", p)
		testing.expectf(t, e != "" && code == "bad_args", "params %q: %s", p, e)
	}
	_, err := parse_command("{\"type\":\"app_call\",\"tab_id\":4,\"method\":\"m\",\"params\":{\"a\":1\r,\"b\":{\"type\":\"tab.quit\"}}}", context.temp_allocator)
	testing.expect(t, err != "", "a CR in the params")
	_, err = parse_command("{\"type\":\"app_call\",\"tab_id\":4,\r\"method\":\"m\",\"params\":{\"a\":1}}", context.temp_allocator)
	testing.expect(t, err != "", "a CR elsewhere in the request line")
	_, merr := parse_request("{\"id\":\"h1\",\"v\":1,\"type\":\"command\",\"command\":{\"type\":\"app_call\",\"tab_id\":4,\"method\":\"m\",\"params\":{\"a\":\r1}}}", context.temp_allocator)
	testing.expect(t, merr != "", "a CR through the socket's command request")
	// the raw params slice is the only "params": the parser refuses duplicate keys
	_, err = parse_command(`{"type":"app_call","tab_id":4,"method":"m","params":{"a":1},"params":{"type":"tab.quit"}}`, context.temp_allocator)
	testing.expect(t, err != "", "two params")
	// escaped ones inside strings are fine
	e, _ := app_call_check("m", `{"a":"x\r\ny"}`)
	testing.expect_value(t, e, "")
	// the backstop on every line Deckhand sends an app
	testing.expect(t, app_line_ok(`{"v":1,"type":"m","a":1}`), "a plain line")
	testing.expect(t, !app_line_ok("{\"v\":1,\"type\":\"m\",\"a\":1}\r{\"type\":\"tab.quit\"}"), "CR")
	testing.expect(t, !app_line_ok("{\"v\":1,\"type\":\"m\"\n}"), "LF")
}

// "type\u0000" is not "type" to Deckhand but is to a C-string parser.
@(test)
app_keys_cannot_hold_nul :: proc(t: ^testing.T) {
	e, code := app_call_check("m", `{"type\u0000":"tab.quit"}`)
	testing.expect(t, e != "" && code == "bad_args", "params key with NUL")
	testing.expect(t, app_input_event_check(`{"event":"key","type\u0000":"tab.quit"}`) != "", "an input event key with NUL")
	testing.expect_value(t, app_input_event_check(`{"event":"key","key":"w"}`), "")
	testing.expect(t, app_input_event_check(`{"event":"key","source":"user"}`) != "", "the envelope's keys, as before")
}

// The display an app paces from (ENGINE-BRIDGE §2.1): the hello's `display` and tab.display's
// fields, valid JSON numbers whatever the scale.
@(test)
app_display_json_fields :: proc(t: ^testing.T) {
	testing.expect_value(t, app_display_json(240, 1), `{"fps":240,"scale":1}`)
	testing.expect_value(t, app_display_json(120, 2), `{"fps":120,"scale":2}`)
	testing.expect_value(t, app_display_json(60, 1.5), `{"fps":60,"scale":1.5}`)
	v, err := json.parse_string(app_display_json(144, 2), .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, v.(json.Object)["fps"].(json.Integer), 144)
}

// A frame draws 1:1: at whole pixels, never wider than the frame, so no texel is stretched,
// shifted by half a pixel or filtered, also in a split pane whose edges are fractional. The
// ring is sized from the same snapped span (app_snap), so a settled ring is drawn whole: no
// column of it cropped, no column of the pane left undrawn.
@(test)
app_frame_quad_is_whole_pixels :: proc(t: ^testing.T) {
	// the pane at whole pixels, the frame its size: as is
	q := app_frame_quad(100, 50, 640, 480, 640, 480)
	testing.expect_value(t, q, App_Quad{100, 50, 640, 480, 1, 1})
	// fractional split-pane edges (panes_tab_rect): the ring the pane gets is drawn exactly
	for r in ([][4]f32{{600.5, 78, 499.5, 572}, {600.4, 78.6, 499.4, 571.3}, {0.5, 0.5, 10.5, 10.5}, {10.25, 10.75, 320.5, 240}}) {
		sn := app_snap(r)
		testing.expect_value(t, sn.x, math.round(r.x))
		testing.expect_value(t, sn.y, math.round(r.y))
		rw, rh := int(sn.z), int(sn.w) // the ring's size (app_frames_tick)
		q = app_frame_quad(r.x, r.y, r.z, r.w, rw, rh)
		testing.expectf(t, q.w == f32(rw) && q.h == f32(rh) && q.u == 1 && q.v == 1, "%v: ring %dx%d, drawn %v", r, rw, rh, q)
		testing.expect_value(t, q.x, sn.x)
		testing.expect_value(t, q.y, sn.y)
		// the pane's right and bottom edges, snapped, are where the frame ends
		testing.expect_value(t, q.x + q.w, math.round(r.x + r.z))
		testing.expect_value(t, q.y + q.h, math.round(r.y + r.w))
	}
	testing.expect_value(t, app_snap({600.5, 78, 499.5, 572}).z, 499)
	testing.expect_value(t, app_snap({600.4, 78, 499.4, 572}).z, 500)
	// a pane larger than the frame (a resize on its way): the frame's size, never stretched
	q = app_frame_quad(10, 10, 800, 600, 640, 480)
	testing.expect_value(t, q, App_Quad{10, 10, 640, 480, 1, 1})
	// smaller (a drag shrinks the pane): clipped, still 1:1
	q = app_frame_quad(10.25, 10.75, 320.5, 240, 640, 480)
	testing.expect_value(t, q.w, 321)
	testing.expect_value(t, q.u * 640, 321)
	// no frame size: nothing
	q = app_frame_quad(0, 0, 100, 100, 0, 0)
	testing.expect_value(t, q.w, 0)
	testing.expect_value(t, q.u, 0)
}

// The display link's rate (power): the screen's maximum only while a visible app or browser
// tab is live (an app connected, or a frame in the last DISPLAY_FAST_HOLD); otherwise at most
// DISPLAY_IDLE_FPS, as on a 120 Hz MacBook before. What apps are told stays the real maximum.
@(test)
display_link_follows_live_frames :: proc(t: ^testing.T) {
	testing.expect_value(t, display_link_cap(true), 0) // no cap: the screen's maximum
	testing.expect_value(t, display_link_cap(false), DISPLAY_IDLE_FPS)
	testing.expect_value(t, DISPLAY_IDLE_FPS, 120)
	now := time.tick_now()
	r: Frame_Ring
	testing.expect(t, !ring_framed_recently(&r, now), "never framed")
	r.last_frame = now
	testing.expect(t, ring_framed_recently(&r, time.tick_add(now, DISPLAY_FAST_HOLD)), "framed within the hold")
	testing.expect(t, !ring_framed_recently(&r, time.tick_add(now, DISPLAY_FAST_HOLD + time.Millisecond)), "quiet past the hold")
	// a visible tab counts; a hidden one never does
	testing.expect(t, display_tab_live(visible = true, connected = true, framed = false), "a connected app on screen")
	testing.expect(t, display_tab_live(visible = true, connected = false, framed = true), "a page painting on screen")
	testing.expect(t, !display_tab_live(visible = true, connected = false, framed = false), "idle on screen")
	testing.expect(t, !display_tab_live(visible = false, connected = true, framed = true), "hidden")
}
