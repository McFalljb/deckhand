package core

// The launch's scan of pi's store (scan_projects, sessions.odin): one header line read per
// project, its first 4 KB (more only when the line goes on), and the folders' listings not kept
// in the scan's arena.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
scan_projects_reads_little :: proc(t: ^testing.T) {
	when TEST_HOOKS {
		context.allocator = runtime.heap_allocator()
		base := fmt.tprintf("%s/pd-scan-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
		old := os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator)
		os.set_env("PI_CODING_AGENT_DIR", base)
		defer {
			if old == "" do os.unset_env("PI_CODING_AGENT_DIR")
			else do os.set_env("PI_CODING_AGENT_DIR", old)
			os.remove_all(base)
		}
		PROJECTS :: 20
		FILES :: 10
		noise := strings.repeat(`{"type":"message","id":"a","message":{"role":"toolResult","content":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}` + "\n", 1000, context.temp_allocator) // ~100 KB
		for p in 0 ..< PROJECTS {
			cwd := fmt.tprintf("/nowhere/project-%02d", p)
			// project 0's header line is longer than the first read (a long cwd)
			if p == 0 do cwd = fmt.tprintf("/nowhere/%s", strings.repeat("long", 2000, context.temp_allocator))
			d := fmt.tprintf("%s/sessions/--nowhere-project-%02d--", base, p)
			os.make_directory_all(d)
			for f in 0 ..< FILES {
				header := fmt.tprintf(`{{"type":"session","version":3,"id":"s%d","cwd":"%s"}}`+"\n", f, cwd)
				_ = os.write_entire_file(fmt.tprintf("%s/2026-11-%02dT10-00-00-000Z_s%d.jsonl", d, f + 1, f), transmute([]u8)strings.concatenate({header, noise}, context.temp_allocator))
			}
		}
		claude_scan_clear()
		header_read_bytes = 0
		scan := new(Scan_Result)
		scan_projects(scan)
		defer {
			virtual.arena_destroy(&scan.arena)
			free(scan)
		}
		fmt.printfln("PERF scan: %d projects of %d files: %d header bytes read, scan arena %d bytes used", PROJECTS, FILES, header_read_bytes, scan.arena.total_used)
		testing.expect_value(t, len(scan.projects), PROJECTS)
		long_ok := false
		for p in scan.projects {
			if strings.has_prefix(p.cwd, "/nowhere/longlong") && len(p.cwd) == len("/nowhere/") + 8000 do long_ok = true
			else do testing.expectf(t, strings.has_prefix(p.cwd, "/nowhere/project-"), "cwd %q", p.cwd[:min(len(p.cwd), 40)])
		}
		testing.expect(t, long_ok, "the long header line read whole")
		// 4 KB a project; the long one up to SCAN_CHUNK more
		testing.expectf(t, header_read_bytes <= (PROJECTS - 1) * 4096 + 4096 + SCAN_CHUNK, "read %d header bytes", header_read_bytes)
		// the arena holds the projects, not the folders' listings (200 files' infos)
		testing.expectf(t, scan.arena.total_used < 24 * 1024, "the scan's arena %d bytes", scan.arena.total_used)
	}
}
