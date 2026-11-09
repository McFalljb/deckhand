package corewire

// The framed wire's part of the released API (schema/released-v1.json "frame", design §7.5):
// the header, the payload limit and the kind numbers are frozen, so the file and this
// package must agree exactly. A new kind (additive, allowed any time) goes into the file in
// the same change, by hand: the core's test (src/core/api_schema_test.odin), which writes
// the rest of the file, carries this part over as it is.
// Run from the repo root, as wire_test.odin.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

RELEASED_V1 :: "schema/released-v1.json"

// The header as the released file describes it (never changes: wire.odin).
FRAME_HEADER :: "channel u32 LE, kind u8, len u32 LE; len <= 16777216"

@(test)
released_frame :: proc(t: ^testing.T) {
	text, err := os.read_entire_file(RELEASED_V1, context.temp_allocator)
	if !testing.expectf(t, err == nil, "%s: %v (run from the repo root)", RELEASED_V1, err) do return
	v, jerr := json.parse(text, .JSON, true, context.temp_allocator) // the repo's own file (corewire imports no other package)
	if !testing.expectf(t, jerr == nil, "%s: %v", RELEASED_V1, jerr) do return
	frame := (v.(json.Object) or_else nil)["frame"].(json.Object) or_else nil
	if !testing.expect(t, frame != nil, "the released file has a frame part") do return
	testing.expect_value(t, frame["header"].(json.String) or_else "", FRAME_HEADER)
	testing.expect_value(t, frame["max_payload"].(json.Integer) or_else 0, MAX_PAYLOAD)
	testing.expect_value(t, HEADER_SIZE, 9)
	kinds := frame["kinds"].(json.Array) or_else nil
	// every released kind is in the code with its number (none renumbered, none removed)
	for k in kinds {
		o := k.(json.Object) or_else nil
		name := o["name"].(json.String) or_else ""
		num := o["kind"].(json.Integer) or_else -1
		found := false
		for x in Kind do if strings.equal_fold(fmt.tprint(x), name) {
			found = true
			testing.expectf(t, i64(x) == num, "kind %s: released as %d, the code says %d (frozen)", name, num, int(x))
		}
		testing.expectf(t, found, "kind %s (%d): released, gone from the code (frozen)", name, num)
		testing.expectf(t, num != 0, "kind 0 is reserved")
	}
	// every kind of the code is in the file (a new one: add it there too)
	for x in Kind {
		name, _ := reflect.enum_name_from_value(x)
		found := false
		for k in kinds do if strings.equal_fold((k.(json.Object) or_else nil)["name"].(json.String) or_else "", name) do found = true
		testing.expectf(t, found, "kind %s (%d) is not in %s yet", name, int(x), RELEASED_V1)
	}
}
