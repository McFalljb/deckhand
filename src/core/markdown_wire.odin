package core

// The Markdown commands' wire layer (design §4): their copy and free for the inbox (inbox.odin).
// The commands are declared in markdown_view.odin, which the window's tab host runs.

import "base:runtime"
import "core:strings"

md_command_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	s :: proc(x: string, a: runtime.Allocator) -> string {return strings.clone(x, a)}
	#partial switch c in cmd {
	case Markdown_Open:   return Markdown_Open{path = s(c.path, allocator), session = c.session, anchor = s(c.anchor, allocator)}
	case Markdown_Scroll: return Markdown_Scroll{tab_id = c.tab_id, anchor = s(c.anchor, allocator), line = c.line}
	case Markdown_Follow: return Markdown_Follow{tab_id = c.tab_id, url = s(c.url, allocator), confirm = s(c.confirm, allocator)}
	}
	return cmd
}

md_command_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	#partial switch c in cmd {
	case Markdown_Open:
		delete(c.path, allocator)
		delete(c.anchor, allocator)
	case Markdown_Scroll: delete(c.anchor, allocator)
	case Markdown_Follow:
		delete(c.url, allocator)
		delete(c.confirm, allocator)
	}
}
