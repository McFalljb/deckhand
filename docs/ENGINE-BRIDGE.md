# Engine bridge: a game engine in a Deckhand tab

A game engine (the first target: an Odin engine with sokol_gfx on Metal, Lua scripting, physics
and an ImGui editor) runs as its own process and shows in a Deckhand **app tab**. Agents can see
it, call any method it offers, and play it with injected input. The user can comment on what it
shows. Contract: [TAB-PROTOCOL.md](TAB-PROTOCOL.md). Envelope: [PROTOCOL.md](PROTOCOL.md). How to
use app tabs: [GUIDE.md](GUIDE.md#tabs).

**Status.** Built: frames, app tabs, input, the method pass-through (`app_call`),
`app_screenshot`, `app_input`, `app_events`, and Inspect boxes with comments. Not built: comment
mode on a game tab with hit testing (§6), record and replay in the toolbar, the direct mode
without Deckhand (§5).

**Decision: the game's agent API belongs in the engine, not in Deckhand.** Deckhand is the pipe,
plus what only the host can do (the frame it shows, its overlays). Agents discover an app's
features by asking it (`tab.describe`); a new engine method works with no Deckhand change. The
`tab.*` tables below are a suggested vocabulary, not a list Deckhand checks.

## Summary

1. **App tab.** The window starts the engine's windowless *desk host* as a child, with
   `DECKHAND_SOCKET` and a single-use `DECKHAND_TOKEN` (caller kind `app`). Control is NDJSON on
   Deckhand's socket; the engine is a client, like a pi tab's bridge.
2. **Frames over a Mach channel** to the window, not XPC (§2.2). Surfaces travel as
   `IOSurfaceCreateMachPort` port descriptors.
3. **Deckhand owns a ring of 3 IOSurfaces.** The engine renders into a free slot and says
   `FRAME` only after its GPU work completes. Deckhand never blocks, and hands a slot back
   (`RELEASE`) only once its own GPU frame that sampled it has completed. No `MTLSharedEvent`:
   publicly its handle crosses processes only over XPC.
4. **One frame-ring module** serves both app tabs and CEF (§2.4).
5. **The app's own methods, passed through.** `app_call {method, params}` forwards any method name
   and returns the reply as sent. Deckhand keeps `tab.quit`, `tab.visible` and `tab.display` for
   itself, and answers `app_screenshot` from the slot it shows.
6. **Agents get a few general tools** (`app_call`, `app_screenshot`, `app_input`, `app_events`),
   not one per feature: they call `tab.describe` first.
7. **A fake app** (`tests/fake-app/`) tests all of it in quiet test mode (§7).

## 1. Process model and launch

**Where it runs.** The app tab's **program** and its **frames** belong to the window process:
the window spawns the program, serves the Mach channel and draws the ring. Its **control
connection** goes to the core: `DECKHAND_SOCKET` is the core's `core.sock`, the core mints the
token, and the core relays the lines between agents and the program (`app_socket`,
`src/core/app_tab_core.odin`). With no window attached, app commands answer `no_window`. **App
tabs end when the window closes** (or updates): the window stops their programs on its way out.
See [How Deckhand runs](GUIDE.md#how-deckhand-runs).

**Tab kind.** `App_Tab {argv, cwd, app_status, exit_code}` in a session, like a shell tab
(`src/app_tab.odin`, the window's part; `src/core/app_tab_core.odin`, the core's). App tabs are
not saved in the workspace.

**Starting one.**
- `new_app_tab {session, name? | argv? | command?, cwd?, title?}` → tab id. `name` names an entry
  in the project's `.deckhand/apps.json` (`app_declared` lists them):
  `{"apps":[{"name":"sandbox","argv":["build/engine-desk","build/sandbox.dylib"],"cwd":"."}]}`.
  The **+** menu and the palette list those entries. The cwd must be inside the project.
- A session's own agents (a pi tab, a Claude tab) open **by name only**, in their own session,
  behind the user's view. `app_restart` and `app_close` let them manage the ones in their
  session. Read-only chats open, restart and close none.
- **apps.json's trust model.** Any agent that can write the project can write apps.json, so an
  entry runs with **the agent's own authority**: it could already run that program from its own
  shell, and Deckhand adds no question of its own. A Claude tab's `deckhand app open`, `restart`
  and `close` are left to Claude Code's permission mode (the plugin's skill does not pre-approve
  them). What Deckhand still holds: by name only, own session, behind the view; at most 8 running
  per session; titles one line of at most 80 characters; apps.json read only as a regular file,
  not through a link, at most 256 KB.
- `posix_spawn` with no PTY, in its own process group. stdout and stderr go to a 2000-line ring
  and `<data dir>/apps/<tab_id>.log` (the tab's **Log** button).
- Env: the parent's minus Deckhand's own variables (`src/core/env_names.odin`) and `PI_KIT_*`,
  plus `DECKHAND_SOCKET`, `DECKHAND_TOKEN` (fresh, single-use, bound to this tab) and
  `DECKHAND_APP=1`. For three releases after 0.2.0 each is also set under its pre-rename name (`PI_DESK_SOCKET`,
  `PI_DESK_TOKEN`, `PI_DESK_APP`); read the `DECKHAND_` names first.
- **Owner:** the session that holds the tab. Its agent may drive this tab (the same exception to
  the self-reference rule as browser tabs, BROWSER §4.1). Atlas reaches any app tab.

**Hello** (engine → Deckhand, first line):

```json
{"id":"1","v":1,"type":"hello","token":"<DECKHAND_TOKEN>","app":"my-engine","pid":4321}
{"id":"1","v":1,"type":"result","result":{"ok":true,"data":{"v":1,"app":"deckhand","caller":"app","tab_id":9,
 "capabilities":["app","frames","input"],"reconnect_token":"<64 hex>",
 "frames":{"service":"dev.deckhand.frames.812","key":"<64 hex>","device":4294969123},
 "display":{"fps":240,"scale":1}}}}
```

- `device` is the window's `MTLDevice.registryID`. The engine must render on that GPU, so
  surfaces never cross GPUs on a dual-GPU Mac.
- `display` is the screen the tab is on (§2.1, "Display rate").
- **Order:** the hello reply is the first line Deckhand sends. Nothing (`tab.visible`, an agent's
  `app_call`, `input`) comes before it.
- **Direction:** after the hello, Deckhand sends requests (`tab.*`, with ids) and the engine
  replies, in any order. The engine sends events (`tab.log`, …) without ids.

**Exit, crash and restart.**
- Socket EOF, a dead-name notification on the Mach channel, or `SIGCHLD` means the engine is
  gone. The tab keeps the **last frame, dimmed**, with a bar: "sandbox exited (code 139) ·
  **Restart** · **Log**".
- **Restart:** the same argv, a new token and a new ring.
- **Exit code 75** ("restart me", e.g. after a rebuild) restarts it by itself, at most 3 times in
  30 s.
- **Close tab:** `tab.quit`, then `SIGTERM` to the group after 2 s, `SIGKILL` after 5 s.
- **Hot reload stays inside the engine** (a dylib swap, a Lua reload), so the connection and the
  ring survive. The engine reports each as a `tab.reload` event.
- **Deckhand goes away** (the window closes, or the core's connection ends): the engine sees EOF
  or a dead name and, by its flag (`--on-desk-exit=window|exit`), opens its own window or exits.
  It never draws into the old surfaces.

## 2. Frames

### 2.1 The ring

- **3 IOSurfaces** per app tab, created and freed by Deckhand.
  - `'BGRA'`, 4 bytes per element, bytes per row aligned with `IOSurfaceAlignProperty`, not
    global.
  - **Size:** the tab's pane in framebuffer px, edges rounded to whole pixels:
    `round(x + w) − round(x)` by `round(y + h) − round(y)`.
  - **Contents:** display-encoded values, as sokol's BGRA8 swapchain.
- One slot is on screen, one waits for Deckhand's GPU to finish sampling it, one is free for the
  engine. Neither side waits on the other (measured up to 240 Hz).
- The engine wraps each surface once (`newTextureWithDescriptor:iosurface:plane:0`, usage
  RenderTarget|ShaderRead, then `sg_make_image{mtl_textures}`); depth and MSAA are its own.
- **Resize:** while the pane is dragged, Deckhand draws the old frame clipped. About 100 ms after
  the size settles, or on a DPI change, it sends a new ring with `gen+1`. The engine switches at
  its next frame and replies `RING_DONE {old gen}`; then Deckhand frees the old ring. The RING
  message *is* the resize for texture tabs (TAB-PROTOCOL's `resize` is not sent to them).
- **Display rate.** The engine has no window and no display link, so Deckhand tells it the
  screen it is on: the hello's `display {fps, scale}`, then the request `tab.display {fps,
  scale}` soon after the hello and whenever they change (another screen, a refresh-rate change,
  screens added or removed, a scale change). Any reply or none is fine.
  - `fps`: the window's screen's `NSScreen.maximumFramesPerSecond` (the screen holding most of
    the window). `scale`: its backing scale; render at the RING's `scale`.
  - The engine paces to `fps`, or its own lower cap. Deckhand's loop runs at the screen's
    maximum while a live app or browser tab is on screen; nothing caps app frames at 60 Hz.
  - Frames are drawn 1:1 at the rounded origin with a nearest sampler; input is measured from the
    same origin.
- **Visibility:** `tab.visible {visible}`. Visible = shown in any pane of the session on screen.
  A hidden tab draws nothing but may keep simulating. A tab that opens hidden (an agent's) is told
  it shows until its first frame; an `app_screenshot` of a hidden tab does the same until a newer
  frame arrives (at most 3 s).

### 2.2 The Mach channel (transport choice)

- **Why Mach, not XPC:** XPC between unrelated processes needs a launchd-registered service; an
  anonymous listener's endpoint can only travel over an existing XPC connection.
  `bootstrap_check_in` of a per-process name works in the user's GUI domain (Chromium's
  MachPortRendezvous does the same). Global IOSurface IDs were rejected: any process could read
  the frames.
- **Code:** `src/native/frames_macos.m`, plain C with ObjC only for Metal. The *serve* half is
  the window's; the *connect* half (about 150 lines) is what the fake app links and an engine can
  copy.
- **Bootstrap:** at its first app tab, the window checks in `dev.deckhand.frames.<pid>` and keeps
  the receive right until it exits; later tabs share it. Its queue limit is raised from 5 to 1024
  (`MACH_PORT_LIMITS_INFO`). The engine raises its reply port's to 64 and looks the name up.
- **Checks:** the key must match the tab's (constant-time). The sender's audit-token pid must be
  in the tab's process group or session, so wrappers such as `sh -c "make run"` work. The key is
  never logged and never in State.
- **Death:** each side asks for a dead-name notification on the other's send right.

**Messages:** fixed little-endian structs after the Mach header; `msgh_id` picks the type. `gen`
is the ring generation, `slot` 0–2, `seq` the engine's rising frame counter.

| msgh_id | Dir | Body | Ports |
|---|---|---|---|
| 1 `HELLO` | E→D | `key[32]`, `tab_id u64` | reply port (Deckhand gets a send right) |
| 2 `RING` | D→E | `gen u32, count u32, w u32, h u32, scale f32, pixel_format u32` | `count` × IOSurface (`MOVE_SEND`) |
| 3 `RING_DONE` | E→D | `gen u32` | — |
| 4 `FRAME` | E→D | `gen u32, slot u32, seq u64, tick u64` | — |
| 5 `RELEASE` | D→E | `gen u32, slot u32` | — |

**Rules.**
- After `RING`, every slot is the engine's. Once `FRAME` is sent, the slot is Deckhand's until
  `RELEASE`. The engine renders only into slots it holds; with none, it skips rendering (the sim
  still ticks).
- Messages with a stale `gen` are dropped by both sides.
- `seq` rises, and `FRAME`s are sent in `seq` order. Within a ring, Deckhand drops a `FRAME` whose
  `seq` is not newer than one it already took and releases its slot at once; a new ring starts
  over.
- **Only `FRAME` may be dropped:** it is sent with timeout 0, and on failure the engine takes the
  slot back.
- `HELLO` and `RING_DONE` are sent with no timeout. `RING` and `RELEASE` go from Deckhand's Mach
  queue with a 250 ms timeout; a timeout means the engine is hung (the stall path, §2.3). Deckhand
  never retries into a hung engine.

### 2.3 The handshake: GPU-complete, with no blocking

**Engine**, each frame:
1. Render into a held slot's `sg_image`; `sg_commit()`.
2. Commit an empty command buffer on `sg_mtl_command_queue()` whose completed handler sends
   `FRAME`. It fires after the frame's buffers on the same queue: **observed, not documented**
   (20 of 20 runs, +0.11 ms). A small sokol patch exposing the frame's own command buffer would
   make it documented; the messages would not change.

**Deckhand** (the frame loop never waits):
1. The Mach queue stores `latest` atomically (an older one never shown is released at once) and
   sets the wake flag the CEF paint path uses.
2. The frame makes `latest` the shown slot and retires the old one.
3. After `sg_commit`, an empty command buffer's completed handler sends `RELEASE` for the retired
   slots.

**Stalls:** no `FRAME` for 2 s while visible and not paused → `tab.ping` (1 s). An answer shows
"No frames for Ns"; none shows "sandbox is not responding · **Restart** · **Wait**". The last good
frame stays on screen. A paused engine is not stalled.

**Teardown:** when the engine dies, Deckhand keeps the shown slot's surface for the dimmed frame
and frees the rest. Restart makes a fresh ring.

### 2.4 Shared code with the CEF texture path

`src/frames.odin` and `src/native/frames_macos.m` hold one `Frame_Ring` (slots of wrapped
`sg_image`s, `latest`/`shown`, retirement through the completion buffer, drawing and capture),
with two producers:
- **remote:** the Mach channel above;
- **local:** CEF's paint blits into a free slot (a *local channel*, no Mach peer). It differs in
  two ways: the ring follows the size CEF paints at, with headroom, and a paint with no free slot
  is dropped and repainted a frame later. Details: [BROWSER §1.1](BROWSER.md#11-rendering-off-screen-into-the-tab-texture).

## 3. Input

- **Routing** follows the browser's rules: Deckhand's shortcuts first (⌘T/W/1–9, ⌘K, ⌘J, ⌃Tab,
  ⌘⇧.); keys go to the tab only while no widget has focus; the mouse never goes to it under the
  palette, a menu, a sheet or Atlas's drawer; a click in the pane takes the keyboard back.
- **Capture:** a press keeps sending moves and the release until the button goes up.
- **Focus loss:** `focus {focused:false}` and synthesised key-ups and button-ups for everything
  held.
- **Messages:** TAB-PROTOCOL §2's `input`. `key` is the sokol `Keycode` name in lower case
  (`a`, `space`, `left_shift`), so an engine on sokol needs no mapping. `x`/`y` are logical px;
  multiply by the ring's `scale`.

```json
{"v":1,"type":"input","event":"key","action":"down","key":"w","repeat":false,"mods":["shift"]}
{"v":1,"type":"input","event":"char","text":"é"}
{"v":1,"type":"input","event":"mouse","action":"down","button":"left","x":120,"y":44,"clicks":1,"mods":[]}
{"v":1,"type":"input","event":"move","x":121,"y":45,"dx":1,"dy":1}
{"v":1,"type":"input","event":"scroll","dx":0,"dy":-3,"x":120,"y":44}
{"v":1,"type":"input","event":"focus","focused":true}
```

- **Agent input** (`app_input`) uses the same messages with `"source":"agent"`, which the engine
  must not treat differently. For exact play-tests, agents pause, inject, then step time.
- **Later:** IME composition, gamepads, cursor lock.

## 4. Protocol additions to TAB-PROTOCOL

**Envelope.** PROTOCOL.md's, `v:1`. No other version number anywhere. Additions are new types or
optional fields only. Deckhand forwards every method except its own (`tab.quit`, `tab.visible`,
`tab.display`) and the envelope's types (`hello`, `result`, `event`, `input`). An app answers a
method it lacks with code `not_supported`, never silence.

**Errors:** `{"ok":false,"error":"<human text>","code":"<code>", …}`. Codes: `bad_args`,
`unknown_command`, `no_path`, `gone`, `read_only`, `script_error`, `not_supported`, `busy`,
`timeout`, `tab_gone`.

```json
{"ok":false,"error":"entity gone","code":"gone","id":"e:12:3"}
{"ok":false,"error":"no field 'hpp' on Entity","code":"no_path","path":"entities[e:12:3].hpp","at":"hpp"}
```

**Ids and paths.** Entity ids are `e:<index>:<gen>`; a stale generation always gives `gone`.
Paths: `root(.field | [int] | [e:i:g] | ["key"])*`, e.g. `entities[e:12:3].hp`. Values are JSON;
vectors are arrays, enums names, quaternions `[x,y,z,w]`.

**Suggested requests (Deckhand → app).**

| type | args | reply `data` |
|---|---|---|
| `tab.describe` | — | `{name, title, version, supports, commands:[{name, doc, args, edits, writes_files, long}], roots, eval, topics}`; `args` a JSON Schema subset |
| `tab.act` | `command`, `args?` | `{result?, undo_id?}`; `undo_id` (`u:<n>`) only when the level was edited. `long` commands reply when done |
| `tab.get` | `path`, `depth?` (2, max 8), `max_bytes?` (64 KB) | `{path, type, value, truncated?}` |
| `tab.set` | `path`, `value` | `{value, undo_id?}`: the value as stored |
| `tab.eval` | `lang`, `code`, `timeout_ms?` (2000) | `{value, output}` |
| `tab.hit_test` | `x`, `y` (logical px) | `{hit:{id, kind, name, box, world?}}` or `{hit:null}` |
| `tab.track` | `ids` (replaces the set) | `{}`, then `tab.boxes` events |
| `tab.time` | `paused?`, `step?`, `scale?` | `{paused, tick, scale, mode}`; a `step` replies after N ticks |
| `tab.record` / `tab.replay` | `action`, `path?` / `path`, `until_tick?` | `{recording}`, `{path, ticks}` / `{started}`, then `tab.replay_done` |
| `tab.subscribe` | `topics` | `{}` |
| `tab.visible` / `tab.display` / `tab.ping` / `tab.quit` | `visible` / `fps, scale` / — / — | `{}` |

**Events (app → Deckhand).**

```json
{"v":1,"type":"event","event":"tab.log","level":"warn","text":"…","tick":1834}
{"v":1,"type":"event","event":"tab.reload","kind":"code|script|restart","ok":true,"error":null}
{"v":1,"type":"event","event":"tab.boxes","seq":902,"boxes":[{"id":"e:12:3","label":"bee","rect":{"x":40,"y":60,"w":32,"h":32}}]}
{"v":1,"type":"event","event":"tab.time","paused":true,"tick":1834,"scale":1,"mode":"play"}
```

- **`tab.boxes`** (built): the full list of `{id, label?, rect}` in logical px, replacing the last
  (`[]` clears), at most once per frame. Deckhand keeps at most 256, draws them while the tab's
  **Inspect** is on and shows the label under the pointer. A click on a box opens the comment bar;
  the comment (label, id, rect, text, a crop of the shown frame) goes to the session's agent with
  the next message (BROWSER §3.6–3.7). Boxes are state, so they stay out of `app_events`.
- Profiler events at most 4 per second.

**What Deckhand answers itself.** `app_screenshot {tab_id, rect?}` copies the shown slot's
IOSurface (safe: Deckhand holds the slot until a newer frame replaces it) and writes a PNG to
`<data dir>/apps/shots/`. It works while the app is stalled or hidden, and on the dimmed last
frame. The reply has `path`, `w`, `h`, `bytes`, `seq`, `tick`.

**Deckhand commands (for agents).** `new_app_tab`, `app_restart`, `app_close`, `app_declared`,
`app_call {tab_id, method, params?, timeout_ms?}` (default 10 s, up to 10 min; `tab_gone` if the
app exits mid-call), `app_screenshot`, `app_inspect {tab_id, on}`, `app_input {tab_id, events}`,
`app_events {tab_id, topic, since?, limit?}` (the last 500 per topic, read on demand, never
pushed into a turn). Every call is logged without values or code text. Fields: [PROTOCOL.md
§3](PROTOCOL.md).

## 5. Agent tools

- A **pi tab**: the pi integration's tools (`integrations/pi`, [HARNESSES.md](HARNESSES.md)):
  `app_call`, `app_screenshot`, `app_input`, `app_events`, and `app_open`, `app_restart`,
  `app_close` for its own session's declared apps. Their descriptions send agents to
  `tab.describe` first.
- A **Claude tab**: the `deckhand app …` verbs ([CLAUDE.md](CLAUDE.md)).
- **Atlas**: the same commands over `control` (any app tab), and `new_app_tab` through `desk_run`.
- Another pi extension can reach the commands through pi's event bus: emit `deckhand:command`
  `{requestId, command}` (browser and app commands only) and listen on
  `deckhand:command:reply:<requestId>`. The integration replies `{result}` when connected,
  `{error}` when not; no reply means pi is not in Deckhand. (`DECKHAND_*` variables are taken out
  of pi's environment when the integration loads, so they can't tell.)
- **Direct mode** (not built): the engine's normal windowed host, with `--agent` in development
  builds, listens on `$TMPDIR/pi-app-<uid>/<name>-<pid>.sock` (0700 folder, a 0600 token file
  beside it), and a tool talks to it with the same `tab.*` requests, the engine answering
  `tab.capture` itself.

## 6. Annotation on a game tab

Built: Inspect boxes and comments on them (§4, `tab.boxes`). Planned, not built: a full comment
mode as in the browser. Annotate pauses the game (`tab.time`), hover uses `tab.hit_test` (at most
30 a second), and a click captures the entity's id, a state snapshot (`tab.get`, at most 8 KB), a
crop and the tick. Markers stay pinned through `tab.track`, a gone entity is labelled "gone", and
a running recording's tick goes with the comment, so an agent can replay to it.

## 7. The fake test app (`tests/fake-app/`)

- Odin, linking the *connect* half of `src/native/frames_macos.m`. `./build.sh fake-app` →
  `build/fake-app`. No window and no sokol; Metal through the C file. All of it runs in quiet
  test mode.
- **Startup:** hello with `DECKHAND_TOKEN`, the Mach `HELLO`, then wait for `RING`.
- **Loop** at 60 Hz, `--fps N`, or `--fps display` (the rate Deckhand reports). A stats line once
  a second in the tab's log. Render if a slot is held.
- **Render, no shaders:** a clear to `#202830`, then a blit per entity box: square `#FF4040`, wall
  `#40A040`, coin `#F0D020`. `--cpu` writes through `IOSurfaceLock` instead.
- **World** in logical px: `e:1:1` "square" 40×40 at `x = 20 + (tick*speed) mod (w-60)`, `y = 40`,
  `speed = 2` (with `game.square.mode = "keys"`, the arrows move it 4 px per tick); `e:2:1` "wall"
  at 20,120, 200×20; `e:3:1` "coin" at 300,200, 16×16.
- **`tab.describe`:** commands `spawn`, `delete`, `undo`, `set_color` (these edit), `save`
  (writes files), `play`/`stop`; roots `game`, `entities`; eval `["lua"]`; topics `log`,
  `script_error`, `reload`.
- **`tab.get`/`tab.set`** on `game.tick` (read-only), `game.paused`, `game.scale`,
  `game.square.*` and `entities[e:i:g].*`; a deleted slot bumps `gen` (`gone`); a bad field gives
  `no_path`.
- **`tab.hit_test`**, `tab.track`/`tab.boxes`, `tab.time`, `tab.record`/`tab.replay` (per-tick
  input in a JSON file), and a fake `tab.eval` (`return <path>`, or `script_error` on `error(`).
- **Fault flags:** `--slow-ms N`, `--hang-after N`, `--crash-after N`, `--exit N`,
  `--no-frames`, `--flash` (alternating whole-frame colours: the tearing test), `--bad-key`.
- Logs `tab.log` once a second, and `tab.reload {kind:"script"}` on `SIGUSR1`.

**Test-mode commands:** `app_open NAME|ARGV…`, `app_waitframe [SEQ] [MS]`,
`assert_app_pixel X Y RRGGBB`, `app_call JSON WANT_SUBSTRING`,
`assert_app_status running|exited|stalled`, `app_kill`. The usual `click`, `type`, `key` and
`scroll` reach the tab through the real routing.

## 8. What's next

1. A joint spike with the real engine: its desk host renders into the ring, `hit_test` and `get`
   return an entity, `act step 10` advances exactly 10 ticks.
2. Comment mode on a game tab (§6).
3. Record and replay in the toolbar, with a marker's recording link.
4. Direct mode (§5).

## 9. Risks and open questions

- **Dynamic bootstrap names locked down by Apple.** Unlikely soon (Chromium depends on them).
  Fallback: an `SMAppService` broker with `NSXPCListener`; only the transport file changes.
- **The empty buffer's ordering is undocumented.** If it breaks, use the sokol patch (§2.3).
- **Dual-GPU Macs:** the engine must render on the hello's `device`, or say it can't.
- **Large replies vs the 1 MiB line limit:** `get` has depth and size caps; screenshots never go
  through the app's NDJSON.
- **App tabs and the window.** App programs are the window's, so they stop when it closes; a
  later version could move them to the core (the design keeps them in the window for v1:
  [background-core.md](plans/background-core.md), decision 3).
- Open: cursor lock for mouse-look (`tab.cursor`); attaching to an engine started outside
  Deckhand (a single-use token minted for a manual start); a per-class ask for `writes_files`
  commands (none by default).

## Engine side: what an engine implements

1. A **desk host** with no window: read `DECKHAND_SOCKET` and `DECKHAND_TOKEN`, send `hello` (§1),
   keep the `reconnect_token`, and drain NDJSON on a background thread into a per-frame mailbox.
2. **Metal:** pick the `MTLDevice` whose `registryID` matches `frames.device`; `sg_setup` with no
   swapchain.
3. **The Mach connect side** (§2.2): `bootstrap_look_up(frames.service)` (never check in a name
   yourself), `HELLO {key, tab_id}` with a reply port whose limit is 64, sent from a process in
   the tab's process group or session. Wrap each `RING` surface as a render target; reply
   `RING_DONE` when switching rings. Copying the connect half of `frames_macos.m` is fine.
4. **The frame rule:** render only into held slots; after `sg_commit`, an empty command buffer's
   completed handler sends `FRAME {gen, slot, seq, tick}` with timeout 0 (take the slot back if
   it fails). Completed handlers can run at once on different threads: send under a lock, and
   drop a frame older than one already sent instead of sending it (the connect half does). Send
   `HELLO` and `RING_DONE` with no timeout. Drain `RING` and `RELEASE` promptly: Deckhand gives up
   after 250 ms. With no free slot, skip rendering and keep ticking.
5. **Pace** to `display.fps`, then each `tab.display`, or a lower cap of your own. Render nothing
   while `tab.visible` is false.
6. **Death:** a dead name or socket EOF means `--on-desk-exit=window|exit`. Never touch the old
   surfaces again. Exit code 75 means "restart me".
7. **`input` messages** (sokol keycode names, logical px × scale, `focus`, `char`) applied at the
   tick boundary. `source:"agent"` changes nothing.
8. **Requests:** whatever the game offers, listed in `tab.describe`; the §4 vocabulary is a
   suggestion. Answer `tab.visible`, `tab.display`, `tab.ping` and `tab.quit`.
9. **Errors** in the §4 shape with `code`. A stale generation is always `gone`.
10. **Events:** `tab.reload` for code, script and state-size reloads; `tab.time` when the pause
    state or mode changes.
11. **No version numbers** but the envelope's `v:1`.

## Sources

- macOS SDK headers: `MTLEvent.h` (`MTLSharedEventHandle` "may be passed between processes via
  XPC connections"), `IOSurfaceRef.h` (`IOSurfaceCreateMachPort`), `servers/bootstrap.h`.
- Chromium [mach_port_rendezvous_mac.cc](https://chromium.googlesource.com/chromium/src.git/+/main/base/apple/mach_port_rendezvous_mac.cc).
- Probe programs on macOS 26.6.2 (not kept in the repository).
