package deckhand_cli

import "core:encoding/json"
import "core:strings"
import "core:testing"

// The handshake: initialize (the instructions), a notification unanswered, tools/list (read-only
// only where nothing changes), errors for unknown methods and bad JSON.
@(test)
mcp_handshake :: proc(t: ^testing.T) {
	f: Fake
	c := test_ctx(&f)
	r, _ := parse_obj(mcp_handle(&c, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`))
	res := get_obj(r, "result")
	testing.expect_value(t, get_text(res, "protocolVersion"), "2025-03-26")
	testing.expect(t, "tools" in get_obj(res, "capabilities"))
	testing.expect(t, strings.contains(get_text(res, "instructions"), "untrusted data"))
	testing.expect_value(t, mcp_handle(&c, `{"jsonrpc":"2.0","method":"notifications/initialized"}`), "")
	r, _ = parse_obj(mcp_handle(&c, `{"jsonrpc":"2.0","id":"l","method":"tools/list"}`))
	testing.expect_value(t, get_text(r, "id"), "l")
	ro := map[string]bool{}
	for tv in get_arr(get_obj(r, "result"), "tools") {
		tool := tv.(json.Object)
		ro[get_text(tool, "name")] = is_true(get_obj(tool, "annotations"), "readOnlyHint")
		testing.expect(t, get_obj(tool, "inputSchema") != nil)
	}
	testing.expect_value(t, len(ro), len(MCP_TOOLS))
	for name in ([]string{"state", "browser_tabs", "browser_read", "browser_screenshot", "app_screenshot", "comments"}) do testing.expectf(t, ro[name], "%s read-only", name)
	for name in ([]string{"show_file", "browser_click", "browser_type", "browser_open", "app_call", "app_open", "app_close", "app_input", "browser_upload"}) do testing.expectf(t, !ro[name], "%s not read-only", name)
	r, _ = parse_obj(mcp_handle(&c, `{"jsonrpc":"2.0","id":2,"method":"resources/list"}`))
	n, _ := get_int(get_obj(r, "error"), "code")
	testing.expect_value(t, n, -32601)
	r, _ = parse_obj(mcp_handle(&c, `not json`))
	n, _ = get_int(get_obj(r, "error"), "code")
	testing.expect_value(t, n, -32700)
	testing.expect_value(t, len(f.sent), 0)
}

// A tool call is the CLI's command: its arguments as argv (flags, then positionals after --, so a
// text starting with -- stays text), the command's JSON line as the tool's text.
@(test)
mcp_tool_round_trip :: proc(t: ^testing.T) {
	f: Fake
	f.replies = make(map[string]string)
	f.replies["browser_type"] = `{"ok":true,"data":{}}`
	c := test_ctx(&f)
	r, _ := parse_obj(mcp_handle(&c, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_type","arguments":{"tab":7,"text":"--hi","selector":"#q","submit":true,"clear":false}}}`))
	res := get_obj(r, "result")
	testing.expect(t, is_false(res, "isError"))
	testing.expect_value(t, len(f.sent), 1)
	testing.expect_value(t, f.sent[0], `{"type":"browser_type","tab_id":7,"text":"--hi","selector":"#q","submit":true}`)
	out, _ := parse_obj(get_text(get_arr(res, "content")[0].(json.Object), "text"))
	testing.expect(t, is_true(out, "ok"))
	// params as an object, and an upload's list of paths
	mcp_handle(&c, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"app_call","arguments":{"tab":9,"method":"game.pause","params":{"on":true}}}}`)
	testing.expect_value(t, f.sent[1], `{"type":"app_call","tab_id":9,"method":"game.pause","params":{"on":true}}`)
	mcp_handle(&c, `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"browser_upload","arguments":{"tab":7,"selector":"ref=e1","paths":["/a.pdf","/b.txt"]}}}`)
	testing.expect_value(t, f.sent[2], `{"type":"browser_upload","tab_id":7,"selector":"ref=e1","paths":["/a.pdf","/b.txt"]}`)
	// refused before Deckhand: an argument the tool does not take, a missing one
	r, _ = parse_obj(mcp_handle(&c, `{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"state","arguments":{"tab_id":1}}}`))
	testing.expect(t, is_true(get_obj(r, "result"), "isError"))
	r, _ = parse_obj(mcp_handle(&c, `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"browser_read","arguments":{}}}`))
	testing.expect(t, is_true(get_obj(r, "result"), "isError"))
	testing.expect_value(t, len(f.sent), 3)
}

// Without the tab's token (Codex passed no env_vars) every tool fails closed, saying why.
@(test)
mcp_no_token :: proc(t: ^testing.T) {
	env := make(map[string]string)
	env["DECKHAND_SOCKET"] = "/nonexistent.sock"
	c := test_ctx(nil, env = env)
	c.tr = nil
	r, _ := parse_obj(mcp_handle(&c, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_tabs"}}`))
	res := get_obj(r, "result")
	testing.expect(t, is_true(res, "isError"))
	testing.expect(t, strings.contains(get_text(get_arr(res, "content")[0].(json.Object), "text"), "DECKHAND_CLAUDE_TOKEN is not set"))
}
