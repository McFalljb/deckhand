package holder

import "core:time"

// Placeholders the PR B workers replace (holder.odin). Until W1's holder lands, `hold --ready
// PATH` does the launcher's handshake (detach.odin) and then idles 30 s: a stand-in that the
// launch tests (src/launchd_test.odin) can find running, detached.
hold_main :: proc(args: []string) -> int {
	for i in 0 ..< len(args) - 1 {
		if args[i] != "--ready" do continue
		if _, ok := ready_handshake(args[i + 1]); !ok do return 1
		time.sleep(30 * time.Second)
		return 0
	}
	return 2
}
