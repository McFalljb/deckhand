// deckhand-core-serve (in Deckhand Core.app beside deckhand-core, the session holder;
// docs/plans/background-core.md §7.1, §10.3 M4-C): the core, headless.
//
//   deckhand-core-serve serve --run DIR --data DIR [--ready PATH]   the core (serve.odin)
//   deckhand-core-serve __detach serve ...                          launchd job entry for serve
//
// The plan has one binary (deckhand-core gaining `serve`). Linking the core package and the
// holder's `hold` into one executable crashes Odin's LLVM backend at -o:speed (an assertion in
// llvm_backend_utility.cpp, `llvm_sz == llvm_dz` i32 i16; dev-2026-09), so serve is its own
// executable, signed with the same identifier; the holder binary is unchanged. One binary again
// once the compiler takes it. Only ready_handshake is used from src/holder.
// Obj-C shims are allowed here (core_macos.m), never in src/core.
package main

import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) >= 2 && os.args[1] == "serve" do os.exit(serve_main(os.args[2:]))
	if len(os.args) >= 3 && os.args[1] == "__detach" && os.args[2] == "serve" do os.exit(detach_serve(os.args[3:]))
	fmt.eprintln(SERVE_USAGE)
	os.exit(2)
}
