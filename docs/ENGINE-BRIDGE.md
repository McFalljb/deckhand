# Engine bridge: a game engine in a Deckhand tab (design, draft 2026-11-01)

A game engine (the first target: an Odin engine with sokol_gfx on Metal, Lua scripting, physics
and an ImGui editor) runs as its own process and shows in a Deckhand **app tab**. Agents can see it,
read and set any state, run any editor command, eval Lua, pause, step, record and replay, and play
it with injected input. The user annotates it like a page: click → entity → comment → pi. An extension could give the same tools
without Deckhand, with the game in its own window (the direct mode, §5, not built). Agents may do anything: no permission tiers.
Goal G6; ROADMAP Phase 4. Contract: [TAB-PROTOCOL.md](TAB-PROTOCOL.md). Envelope:
[PROTOCOL.md](PROTOCOL.md).

Status: step 1 (frames, app tabs, input) is built; step 2's pipe is built: `app_call` passes
any method through, `app_screenshot`, the Inspect boxes. **Decision: the
game's agent API (describe, get/set, eval, hit-test, act/undo, record/replay, subscribe, time…)
belongs in the engine, not in Deckhand.** Deckhand is the pipe plus what only the host can do (the
frame it shows, its overlays). Agents discover an app's features by asking it (`tab.describe`); a
new engine method works with no Deckhand change. The `tab.*` tables below are the engine's
suggested vocabulary, not a list Deckhand checks.

## Summary (recommendations)

1. **App tab.** Deckhand starts the engine's windowless *desk host* as a child of a session, with
   `PI_DESK_SOCKET` and a single-use `PI_DESK_TOKEN` (new caller kind `app`). Control stays NDJSON
   on Deckhand's socket; the engine is a client, like a pi tab's bridge. (pi tabs moved to
   `DECKHAND_SOCKET`/`DECKHAND_TOKEN` with Deckhand's bundled pi integration; an app keeps
   `PI_DESK_SOCKET`/`PI_DESK_TOKEN`, a stable interface.)
2. **Frames over a Mach channel, not XPC.** Deckhand checks in a per-process bootstrap name
   (`bootstrap_check_in`, as Chromium's MachPortRendezvous does) and hands the
   engine its name and a 32-byte key in the hello reply. Surfaces travel as
   `IOSurfaceCreateMachPort` port descriptors. XPC needs a launchd-registered service between
   unrelated processes; plain Mach does not.
3. **Deckhand owns a ring of 3 IOSurfaces** (BGRA8, pane px × scale). The engine renders into a
   free slot. It says "frame ready" only after the GPU finished: after `sg_commit` it commits one
   empty command buffer on sokol's queue, and its completed handler sends `FRAME`. Deckhand never
   blocks: a Mach receive on a dispatch queue sets an atomic "latest", and the frame loop picks it
   up. Deckhand hands a slot back (`RELEASE`) only once its own GPU frame that last sampled the slot
   has completed (the same empty-command-buffer trick on Deckhand's sokol queue).
   **Change from the note:** no `MTLSharedEvent`. Publicly its handle crosses processes only
   through `NSXPCCoder` (`MTLEvent.h:69`; `NSKeyedArchiver` throws), which item 2 rules out. A
   private Mach-port route works (`-[MTLSharedEventHandle eventPort]` /
   `-[MTLDevice newSharedEventWithMachPort:]`, probe `evx.m`), but we use no private
   SPI. The completed handler costs about 0.01–0.1 ms more (probe `order.m`: mean +0.11 ms). An
   `SMAppService` broker would allow the public route later (risk R1); the messages stay the same.
4. **One frame-ring module serves both the engine and CEF.** It also fixes the browser's tearing
   race: CEF currently blits into one texture that in-flight frames may be sampling.
5. **The app's own methods, passed through.** `app_call {method, params}` forwards any method
   name to the app unchanged and returns its reply as sent; Deckhand checks only the envelope and
   keeps `tab.quit` and `tab.visible` for itself. The engine's vocabulary (`tab.describe`,
   `tab.act` with `undo_id`, `tab.get`/`tab.set` on paths, `tab.eval {lang}`, `tab.subscribe`,
   `tab.hit_test` → `e:<index>:<gen>`, `tab.time`, `tab.record`/`tab.replay`, or anything else)
   is the engine's to define and list in `tab.describe`. Deckhand answers `app_screenshot` itself
   from the slot it shows.
6. **Agents get a few general tools** from Deckhand's pi integration (`integrations/pi`: the
   `desk` extension for Atlas, `browser` for a pi tab; [HARNESSES.md](HARNESSES.md)) and the
   `deckhand app` verbs of Claude tabs: `app_call`, `app_screenshot`,
   `app_input`, `app_events` (plus `new_app_tab`/`app_restart` through `desk_run`; a pi tab's
   `app_open`, `app_restart` and `app_close` in its own session, by `apps.json` name). No
   per-feature tools: they call `tab.describe` first. Without Deckhand (later) the same calls go
   straight to the engine's desktop host.
7. **A fake app** (`tests/fake-app/`, Odin plus the shared Mach/Metal C file) lets Deckhand build
   and test everything in quiet test mode before a real engine is ready.

## 1. Process model and launch

**Tab kind.** A new `App_Tab {argv, cwd, title, status, exit_code}` in a session, like a shell
tab. `Tab_Display.Texture` and `tab_host(App_Tab)` → `app_host` (`src/app_tab.odin`).

**Starting one.**
- Command `new_app_tab {session, name? | argv?, cwd?, title?}` → tab id. `name` names an entry in
  the project's `.pi-desk/apps.json` (`app_declared` lists them), for example
  `{"apps":[{"name":"sandbox","argv":["build/engine-desk","build/sandbox.dylib"],"cwd":"."}]}`.
  The tab bar's `+` menu and the palette list those entries ("New app tab › sandbox").
  `argv` runs anything (Home's agent can already run shells). The cwd must be inside the project.
  A session's own agents (a pi tab, a Claude tab) open **by name only**, in their own session,
  behind the user's view, and the user sees and stops the tab like any other (its close button;
  `app_close` and `app_restart` let the agent manage the ones in its session). Read-only chats
  open, restart and close none (a read-only pi chat has no app tools at all: pi's `--tools` allowlist).
- **apps.json's trust model.** `.pi-desk/apps.json` is a file in the project, so any agent that
  can write the project can write it: a name limits nothing by itself. An entry runs with **the
  agent's own authority**: an agent that can write apps.json can already run that program from
  its own shell, so Deckhand adds no question of its own. A pi tab opens a declared entry at once.
  A Claude tab's `deckhand app open`, `app restart` and `app close` are not pre-approved by the
  plugin's skill (its `allowed-tools` lists every other `deckhand` verb), so Claude Code's own permission mode
  decides: it asks in its default mode, runs in bypass mode. What Deckhand still holds: by name
  only, in the agent's own session, behind the user's view; never from a read-only Claude tab or
  a pi tab started read-only (Chats: read-only); at most 8 running per session (restarts of an
  exited one counted); an agent's title cleaned to one line of at most 80 characters; apps.json
  read only as a regular file, not through a symbolic link and without blocking (a FIFO), at most
  256 KB, names over 80 characters skipped. The user's own opens (the palette's **New app tab…**)
  and Home's come to the front.
- `posix_spawn` with no PTY, in its own process group. stdout and stderr go to a 2000-line ring
  and to `<data dir>/apps/<tab_id>.log`, which the tab's **Log** button opens.
- Env: the parent's env minus the `PI_DESK_*` and `PI_KIT_*` variables, plus `PI_DESK_SOCKET`,
  `PI_DESK_TOKEN` (fresh, single-use, caller `app`, bound to this tab) and `PI_DESK_APP=1`.
- **Owner:** the session that holds the tab. Its pi tab may drive this tab. That is the same
  exception to the self-reference rule as browser tabs (BROWSER §4.1). Atlas reaches it through
  `control`.
- Saved in the workspace. After a relaunch the tab comes back stopped. It starts when it is first
  shown, or on `app_start`.

**Hello** (engine → Deckhand, first line):

```json
{"id":"1","v":1,"type":"hello","token":"<PI_DESK_TOKEN>","app":"my-engine","pid":4321}
{"id":"1","v":1,"type":"result","result":{"ok":true,"data":{"v":1,"app":"pi-desk","caller":"app","tab_id":9,
 "capabilities":["app","frames","input"],"reconnect_token":"<64 hex>",
 "frames":{"service":"dev.pi-desk.frames.812","key":"<64 hex>","device":4294969123}}}}
```

`device` is Deckhand's `MTLDevice.registryID`. The engine must render on that same GPU (pick it
from `MTLCopyAllDevices`), so the surfaces never cross GPUs on a dual-GPU Mac.

**Order.** The hello reply is the first line Deckhand sends the engine. Nothing (`tab.visible`,
an agent's `app_call`, `input`) comes before it, even when the tab is on screen or an agent calls
the moment the engine connects (PROTOCOL.md §2). The engine reads one line after its hello and
takes it as the reply.

**Direction.** After the hello, Deckhand sends the requests (`tab.*`, with ids) and the engine
replies. The engine sends events (`tab.log`, …) without ids. This is the same shape as `pi.prompt`
to the bridge. The engine handles requests in its per-frame mailbox. Requests are queued, so it
never has to reply in order (unlike PROTOCOL §1 for clients).

**Exit, crash and restart.**
- **Socket EOF, a dead-name notification on the Mach channel, or `SIGCHLD`:** any of these means
  the engine is gone. The tab keeps the **last frame, dimmed** (Deckhand owns the surface, so it
  stays valid) and shows a bar: "sandbox exited (code 139) · **Restart** · **Log**".
- **Restart:** the same argv, a new token and a new ring.
- **Exit code 75** ("restart me", e.g. after the host binary was rebuilt) restarts the engine by
  itself. Three restarts within 30 s stop that and show the bar instead.
- **Close tab:** Deckhand sends `tab.quit`, then `SIGTERM` to the process group after 2 s and
  `SIGKILL` after 5 s.
- **Hot reload stays inside the engine.** A dylib swap, a Lua reload, or a `state_size` restart
  of the game all happen in the same process, so the connection and the ring survive. The engine
  reports each one as a `tab.reload` event (§4), which Deckhand shows briefly in the tab's status
  line.
- **Deckhand dies:** the engine sees EOF or a dead name and, depending on its flag
  (`--on-desk-exit=window|exit`), opens its own window or exits. It never draws into the old
  surfaces.

## 2. Frames

### 2.1 The ring

- **3 IOSurfaces** per app tab, created by Deckhand.
  - `kIOSurfacePixelFormat 'BGRA'`, 4 bytes per element, bytes per row aligned with
    `IOSurfaceAlignProperty`, not global.
  - **Size:** `round(pane_w × scale) × round(pane_h × scale)`.
  - **Contents:** values already display-encoded, the same as sokol's BGRA8 window swapchain.
- With 3 slots, one is on screen, one waits for Deckhand's GPU to finish sampling it, and one is
  free for the engine. Neither side waits on the other at 60 Hz.
- **Ownership:** Deckhand creates and frees the surfaces.
  - The engine wraps each surface once, with `newTextureWithDescriptor:iosurface:plane:0`
    (usage RenderTarget|ShaderRead) and then `sg_make_image{mtl_textures}`. Depth and MSAA
    targets are its own.
  - Deckhand wraps each slot once as an `sg_image` (ShaderRead).
- **Resize.**
  - While the pane is being dragged, Deckhand draws the old frame clipped, as the browser does.
  - About 100 ms after the size settles, or on a DPI change, Deckhand sends a new ring with
    `gen+1`.
  - The engine switches at its next frame boundary and replies `RING_DONE {old gen}`. Deckhand
    then frees the old ring. If the engine dies first, Deckhand frees it then.
  - The RING message *is* the resize for texture tabs. TAB-PROTOCOL's `resize` message is dropped
    for them.
- **Visibility:** `tab.visible {visible}` (NDJSON). A hidden tab gets no frames. The engine keeps
  simulating unless it is paused and only skips rendering. Free slots are never needed while the
  tab is hidden. **On demand:** a tab that opens hidden (an agent's, behind the view) is told it
  shows until its first frame arrives, and an `app_screenshot` of a hidden tab tells it so again
  until a frame newer than the ask arrives (at most 3 s); then `tab.visible {visible: false}`
  follows. The engine needs nothing new: it draws while told it shows.

### 2.2 The Mach channel (transport choice)

| Option | Between unrelated processes | Carries IOSurface | Carries MTLSharedEvent |
|---|---|---|---|
| XPC (`xpc_connection_create_mach_service`, `NSXPCListener`) | only with a launchd-registered service (LaunchAgent / `SMAppService`); an anonymous listener's endpoint can only travel over an existing XPC connection | `IOSurfaceCreateXPCObject` | yes (`MTLSharedEventHandle`, NSXPC only) |
| **Mach + bootstrap check-in (chosen)** | yes: `bootstrap_check_in` of a dynamic name, `bootstrap_look_up` by the peer (Chromium's MachPortRendezvous) | `IOSurfaceCreateMachPort` → port descriptor | no public way |
| The NDJSON Unix socket | yes | no (it carries fds, not Mach ports) | no |

**Evidence** (small probe programs run on macOS 26.6.2):
- XPC is impossible here without launchd. A listener on a dynamically checked-in name fails
  (probe `xpcl.m`), and moving an `xpc_endpoint` over raw Mach is private SPI.
- `bootstrap_check_in` of an undeclared name works in the user's GUI domain (`gui/501`, probe
  `boot.c`). Chrome 156 imports `bootstrap_check_in`/`bootstrap_look_up` for its
  MachPortRendezvous server. `bootstrap_register` is deprecated; don't use it.

**Alternatives, ranked:**
1. **Bootstrap check-in** of a per-process name: chosen.
2. `posix_spawnattr_setexceptionports_np` on an unused exception mask: works with no global name,
   but misuses exception ports and is not inherited by grandchildren (wrappers such as `sh -c`).
3. `mach_ports_register`: legacy, limited to 3 ports, same inheritance problem.
4. fileport: private, and it goes the wrong way (fd → port).
5. Global IOSurface IDs (`kIOSurfaceIsGlobal`, `IOSurfaceLookup`): any process can read the
   frames. Rejected.

**Chosen: plain Mach messages.**
- An `SMAppService` agent would add login-item approval UI, need a signed bundle in every dev
  build, and add a launchd job, all to move three ports.
- Neither side is sandboxed: Deckhand is not, and the engine is a dev build. A sandboxed producer
  would need a `mach-lookup` temporary-exception entitlement for `dev.pi-desk.frames.*`; noted,
  not needed.
- Code: `src/native/frames_macos.m`, plain C with ObjC only for Metal.
  - The *serve* half is Deckhand's.
  - The *connect* half is about 150 lines that the fake app links and the engine can copy or port
    to Odin. It needs `vendor:darwin/Metal` plus a few `mach_msg` declarations.

**Bootstrap.**
- **Check in once per process.** At its first app tab, Deckhand calls
  `bootstrap_check_in(bootstrap_port, "dev.pi-desk.frames.<pid>", &recv)` and keeps the receive
  right until it quits. A second check-in of the same name fails with 1103
  (`BOOTSTRAP_SERVICE_ACTIVE`), so later tabs reuse the port. A dispatch source on it runs on a
  serial background queue.
- **Queue limit.** A receive port holds `MACH_PORT_QLIMIT_BASIC` (5) messages by default, and this
  one port is shared by every app tab. Deckhand raises it to 1024 with `mach_port_set_attributes(…,
  MACH_PORT_LIMITS_INFO, …)` right after the check-in. (One port per tab would also work. We pick
  the shared port with a high limit because it needs no extra handshake message.) The engine
  raises its reply port to 64 the same way.
- The engine calls `bootstrap_look_up` on the name from the hello reply and sends `HELLO`.
- **Checks:** the key must match the tab's (constant-time compare), always. The sender's
  audit-token pid (from the message trailer) must belong to the tab's process group or session
  (`getpgid`/`getsid` equal to the child's). That is not the child's exact pid, so wrappers such
  as `sh -c "make run"` work. A program that leaves both with `setsid` must not be the
  sender.
  - A same-user process could look the name up, but without the key it gets nothing.
  - The key is never logged and never in State (PROTOCOL §2's threat model).
- **Death:** each side asks for a dead-name notification on the other's send right
  (`mach_port_request_notification`, `MACH_NOTIFY_DEAD_NAME`).

**Messages.**
- Fixed little-endian structs after the Mach header; `msgh_id` picks the type.
- `gen` is the ring generation, `slot` is 0–2, and `seq` is the engine's frame counter (u64, rising).

| msgh_id | Dir | Body | Ports |
|---|---|---|---|
| 1 `HELLO` | E→D | `key[32]`, `tab_id u64` | reply port (receive right stays with the engine; Deckhand gets a send right) |
| 2 `RING` | D→E | `gen u32, count u32, w u32, h u32, scale f32, pixel_format u32` | `count` × IOSurface (`MOVE_SEND`) |
| 3 `RING_DONE` | E→D | `gen u32` | — |
| 4 `FRAME` | E→D | `gen u32, slot u32, seq u64, tick u64` | — |
| 5 `RELEASE` | D→E | `gen u32, slot u32` | — |

**Rules.**
- After `RING`, every slot belongs to the engine.
- Once `FRAME` is sent, the slot is Deckhand's until `RELEASE`.
- The engine renders only into slots it holds. If it holds none, it skips rendering that frame
  (the sim still ticks).
- Messages with a stale `gen` are dropped by both sides. Deckhand does not answer them, and old
  slots come back with `RING_DONE`.
- **Only `FRAME` may be dropped.** It is sent with `MACH_SEND_TIMEOUT` and timeout 0. If the send
  fails, the engine takes the slot back at once; the next frame replaces it.
- **The others must arrive:**
  - `HELLO` and `RING_DONE` (engine → Deckhand) are sent with no timeout. Deckhand always drains
    its port on a dedicated queue, and the limit is 1024.
  - `RING` and `RELEASE` (Deckhand → engine) are sent from Deckhand's Mach serial queue, never
    from the frame loop or a Metal callback, with `MACH_SEND_TIMEOUT` of 250 ms. A timeout
    means the engine is hung. Deckhand marks the tab stalled and goes through the stall path
    (§2.3: `tab.ping`, then **Restart**). It never retries into a hung engine.

### 2.3 The handshake: GPU-complete, with no blocking

**Engine** (each rendered frame, about 20 lines):
1. Pick a held slot and render into its wrapped `sg_image`. Call `sg_commit()`.
2. `cb := [sg_mtl_command_queue() commandBuffer]` with
   `addCompletedHandler { send FRAME{gen, slot, seq, tick} }`, then `commit`. The empty buffer's
   completed handler fires after the frame's buffers on the same queue. That is **empirically
   ordered, not documented**: probe `order.m` saw it 20 out of 20 times, mean +0.11 ms.
3. The handler runs on a Metal thread. It sends `FRAME` with a 0 timeout (§2.2's drop rule). If
   the send fails, the engine takes the slot back.
4. **Optional, stronger (documented):** a tiny sokol patch that exposes the frame's own
   `MTLCommandBuffer` (e.g. `sg_mtl_frame_command_buffer()`, valid before `sg_commit`). Then
   `addCompletedHandler` goes on the frame buffer itself, which Metal documents as firing after
   that buffer's work. This is an engine-side improvement; the messages don't change.

**Deckhand** (frame loop never waits):
1. The Mach receive queue gets `FRAME` and stores `latest = {gen, slot, seq}` atomically (an older
   `latest` that was never shown is released right away). It then sets the atomic `wake` flag that
   `frame()` checks before its `if !app.redraw do return`. That is the same wake path the CEF paint
   callback uses.
2. `frame()`: if `latest` is newer than `shown`, it makes it the shown slot and records
   `retired += old shown @ this frame number`, then draws the slot's `sg_image` like the browser's
   `browser_draw`.
3. After `sg_commit`, if anything retired this frame, Deckhand commits an empty command buffer on
   `sg.mtl_command_queue()`. Its completed handler posts the retired slots to the Mach serial
   queue, which sends `RELEASE` (§2.2). The same empirical ordering applies; vendoring the same
   sokol patch in Deckhand would make it documented.

**Stalls.**
- **No `FRAME` for 2 s** while the tab is visible and not paused: Deckhand sends `tab.ping`
  (1 s timeout).
  - If it answers: the badge says "No frames for Ns", and the engine is busy or the GPU is stuck.
  - If not: "sandbox is not responding · **Restart** · **Wait**".
- **The last good frame stays on screen.**
- **Paused engines** keep sending frames when something changes (editor UI). Deckhand does not
  call silence while paused a stall: `tab.time` tells it the engine is paused.

**Teardown and recovery.**
- **When the engine dies:** Deckhand drops its send rights, keeps the shown slot's IOSurface for
  the dimmed last frame, and frees the others. The Mach ports the engine held die with it; the
  kernel releases its IOSurface use counts.
- **Restart:** a fresh ring.
- **Close tab:** all surfaces are freed after `RING_DONE` or the exit.

### 2.4 Shared code with the CEF texture path (and its fix)

`src/frames.odin` + `src/native/frames_macos.m` hold one `Frame_Ring`:
- slots of wrapped `sg_image`s;
- `latest`/`shown`, and retirement through the completion buffer;
- `ring_draw(ring, x, y, w, h)`, which clips like `browser_draw`;
- `ring_capture(ring, box) -> RGBA`.

There are two producers:
- **remote:** the Mach channel above;
- **local:** CEF's `on_accelerated_paint` blits into a *free* slot of a 3-texture ring that
  Deckhand owns, keeps its `waitUntilCompleted` (CEF takes the surface back when the callback
  returns), then publishes `latest`.

This fixes a race in the first browser build (BROWSER.md, "Open items"). Before the ring, the blit wrote
the single `slots[i].texture` while sokol could still have up to two frames in flight sampling it.
With the ring, a slot is never written while a frame that sampled it is still in flight. The same
change trims padded IOSurface edges: `w`/`h` come from the view rect, not the surface. The CPU
`OnPaint` path writes into a free slot the same way. **Do the CEF fix in step 1**: it is the first
user of the ring and its tests already exist.

**Done (branch `cef-ring`, after step 1).** The local producer is a *local channel* in
`frames_macos.m`: the same ring stores, poll, `pd_frames_retire`/`pd_frames_committed` and
`ring_freeable` as an app tab, with no Mach peer. `pd_frames_local_acquire` gives CEF a free slot
(or the slot of a frame not yet polled, which was never drawn), `pd_frames_local_frame` is FRAME
in process, and RELEASE marks the slot free at the moments it would be sent to an app. Hidden
tabs give frames back at once, never the shown slot. Two differences from an app: the ring
follows the size CEF paints at, with headroom (rounded up to 256 px; each frame carries its
content size; a paint that outgrows the ring asks `browser.odin` for a larger one, at most one
per `RING_SETTLE`, and the old one is done at once, as if `RING_DONE` came), and a paint with no
slot free is dropped and the view invalidated a frame later. Edge trimming was not done: the ring is the surface's size, and
drawing clips to the pane as before. Details: BROWSER §1.1.

## 3. Input

- **Routing:** the browser's rules (`browser_event`).
  - Deckhand's shortcuts come first (⌘T/W/1–9, ⌘K, ⌘J, ⌃Tab, ⌘⇧.).
  - Keys go to the tab only while no widget has focus (`state.focus_widget == ""`).
  - The mouse never goes to the tab under the palette, a menu, a popover, a sheet or Atlas's
    drawer.
  - A click in the pane takes the keyboard back.
- **Capture:** a press in the pane keeps sending moves and the release to the tab, even outside
  the pane, until the button goes up.
- **Focus loss** (another widget, a hidden tab, the window losing focus): Deckhand sends
  `focus {focused:false}` and synthesises key-ups and button-ups for everything still held, as
  `release_input` does.
- **Messages:** TAB-PROTOCOL §2's `input`, with exact fields.
  - `key`: the sokol `Keycode` name in lower case (`a`, `space`, `left_shift`, `f6`, `left`).
    An engine on sokol can fill its key state indexed by `sapp.Keycode`, so this needs no mapping table.
  - `x`/`y`: logical px in the tab; the engine multiplies by the ring's `scale`.

```json
{"v":1,"type":"input","event":"key","action":"down","key":"w","repeat":false,"mods":["shift"]}
{"v":1,"type":"input","event":"char","text":"é"}
{"v":1,"type":"input","event":"mouse","action":"down","button":"left","x":120,"y":44,"clicks":1,"mods":[]}
{"v":1,"type":"input","event":"move","x":121,"y":45,"dx":1,"dy":1}
{"v":1,"type":"input","event":"scroll","dx":0,"dy":-3,"x":120,"y":44}
{"v":1,"type":"input","event":"focus","focused":true}
```

- **Agent injection** uses the same messages: Deckhand sends what `app_input` gives it through the
  same writer, with `"source":"agent"`, which the engine may log but must not treat differently.
  While agent input runs, the tab shows the browser's activity strip (**Stop**, **Take over**). A
  key or click from the user pauses the agent for 30 s.
- **Timing:** for exact play-tests, agents pause, inject, then `tab.time {step:N}`. Input lands at
  the next tick boundary.
- **Later:** IME composition (the `char` events above cover committed text), a gamepad `event`
  (reserved), and cursor lock or hide (`tab.cursor` from the engine; open question Q4).

## 4. Protocol additions to TAB-PROTOCOL

**Envelope.**
- Everything goes in PROTOCOL.md's envelope, `v:1`. There is no other version number: not in
  `tab.*` and not on the engine's own host/game seam.
- **Additions** are new types or optional fields only. A breaking change bumps the envelope's `v`
  for all of Deckhand.
- **Feature detection:** the app's `tab.describe` lists the methods it answers (its own shape;
  for example `supports`, `commands` with arg schemas). Deckhand forwards every method but its own
  (`tab.quit`, `tab.visible`) and the envelope's types (`hello`, `result`, `event`, `input`);
  an app answers a method it lacks with code `not_supported`, never silence.

**Errors.**
- `{"ok":false,"error":"<human text>","code":"<code>", …}`. `code` is a new optional result field
  for all of PROTOCOL.
- Codes: `bad_args`, `unknown_command`, `no_path`, `gone`, `read_only`, `script_error`,
  `not_supported`, `busy`, `timeout`, `tab_gone`.

```json
{"ok":false,"error":"entity gone","code":"gone","id":"e:12:3"}
{"ok":false,"error":"no field 'hpp' on Entity","code":"no_path","path":"entities[e:12:3].hpp","at":"hpp"}
{"ok":false,"error":"attempt to index a nil value","code":"script_error","traceback":"[string]:1: …"}
```

**Ids and paths.**
- **Entity id:** `e:<index>:<gen>`. A stale generation always gives `gone`, never another entity.
  Other kinds may use their own prefix (`ui:<panel>`, `a:<asset>`).
- **Path grammar:** `root(.field | [int] | [e:i:g] | ["key"])*`. Examples: `game.player.speed`,
  `entities[e:12:3].hp`, `lua.creatures["bee"].mood`.
- **Values:** JSON. Vectors are arrays, enums are names, handles are ids, and quaternions are
  `[x,y,z,w]`.

**Requests (Deckhand → app).**

| type | args | reply `data` |
|---|---|---|
| `tab.describe` | — | `{name, title, version, display:"texture", supports:[types], commands:[{name, doc, args, edits, writes_files, long}], roots:[paths], eval:["lua"], topics:["log","script_error","profiler","reload"]}`. `args` is a JSON Schema subset (`type`, `properties`, `required`, `enum`, `minimum`, `maximum`, `items`, `description`) reflected from the command's Odin arg struct |
| `tab.act` | `command`, `args?` | `{result?, undo_id?}`; `undo_id` is present only when the command edited the level (`u:<n>`). Undo: `tab.act {command:"undo", args:{undo_id}}`. `long` commands reply when done |
| `tab.get` | `path`, `depth?` (default 2, max 8), `max_bytes?` (default 64 KB) | `{path, type, value, truncated?}`; `type` is the Odin type name |
| `tab.set` | `path`, `value` | `{value, undo_id?}`: the value as stored after clamping. Edit-mode changes to authored data go through the undo log |
| `tab.eval` | `lang` ("lua"), `code`, `timeout_ms?` (default 2000) | `{value, output}` (`print` captured, capped at 64 KB) |
| `tab.hit_test` | `x`, `y` (logical px) | `{hit:{id, kind, name, box:{x,y,w,h}, world?:[x,y,z]}}` or `{hit:null, world?}`. `box` is in logical tab px for the frame `seq` it was computed on; `kind` is `entity` or `ui` |
| `tab.track` | `ids:[…]` (replaces the set; `[]` stops) | `{}`, then `tab.boxes` events |
| `tab.time` | `paused?`, `step?` (N ticks, implies paused), `scale?` (0.05–8) | `{paused, tick, scale, mode:"edit"\|"play"}`. A `step` replies after the N ticks have run |
| `tab.record` | `action`: `start`\|`stop`, `path?` | start: `{recording}`; stop: `{path, ticks, from:"play"}`. Starting Play first is the engine's job |
| `tab.replay` | `path`, `until_tick?`, `speed?`, `paused_at_end?` (default true) | `{started:true}`, then a `tab.replay_done {tick, path}` event |
| `tab.subscribe` | `topics:[…]` | `{}` (`tab.unsubscribe` likewise) |
| `tab.visible` / `tab.ping` / `tab.quit` | `visible` / — / — | `{}` |

**Events (app → Deckhand).**

```json
{"v":1,"type":"event","event":"tab.log","level":"warn","text":"…","tick":1834}
{"v":1,"type":"event","event":"tab.script_error","file":"scripts/bee.lua","line":12,"text":"…","traceback":"…"}
{"v":1,"type":"event","event":"tab.profiler","seq":901,"ms":4.1,"blocks":[["physics",1.2],["lua",0.8]]}
{"v":1,"type":"event","event":"tab.reload","kind":"code|script|restart","ok":true,"error":null}
{"v":1,"type":"event","event":"tab.boxes","seq":902,"boxes":[{"id":"e:12:3","label":"bee","rect":{"x":40,"y":60,"w":32,"h":32}}]}
{"v":1,"type":"event","event":"tab.time","paused":true,"tick":1834,"scale":1,"mode":"play"}
{"v":1,"type":"event","event":"tab.replay_done","tick":2400,"path":"…"}
```

- **`tab.boxes`** (built, step 2): the full list of `{id, label?, rect}` in logical tab px; each
  event replaces the last (`[]` clears). At most once per frame and only with changes. Deckhand
  keeps at most 256 (labels 200 bytes, ids 64), draws them while the tab's **Inspect** is on,
  shows the label under the pointer, and keeps them out of `app_events` (state, not history).
  A left click on a box while inspecting opens the new-comment bar for it; the comment (source
  `app`: the box's label, id and rect, the user's text, a crop of the shown frame taken at the
  click through `app_screenshot`'s frame read) goes to the tab's session's pi with the user's next message
  (`src/comments.odin`, BROWSER.md §3.6–3.7). Not yet: matching `seq` to the shown `FRAME`.
- **Profiler** events are sent at most 4 per second.

**What Deckhand answers itself.**
- **`app_screenshot {tab_id, rect?}`** (built, step 2; was `tab.capture`) copies the shown slot's
  IOSurface on the main thread (`IOSurfaceLock` read-only, a memcpy; safe because Deckhand holds
  the slot until a newer frame replaces it, so never past its `RELEASE`), and a worker writes a
  PNG to `<data dir>/apps/shots/`. It works while the app is stalled or hidden, and on the dimmed
  last frame. `rect` crops in logical tab px. The reply has `path`, `w`, `h`, `bytes`, `seq`,
  `tick`. Not yet: JPEG or downscaling for large frames (the pi integration's `app_screenshot` describes rather than attaches images over 4 MB).
- **`input`** is routed as in §3.

**Deckhand commands (for agents).**
- `new_app_tab`, `app_start {tab_id}`, `app_restart {tab_id}`.
- `app_call {tab_id, method, params?, timeout_ms?}` (default 10 s, up to 10 min) → the app's
  reply verbatim (data as sent; an error's code and fields in `data`). A `tab_gone` error comes if
  the app exits mid-call. The app gets `{"id","v":1,"type":<method>, …params}`.
- `app_screenshot {tab_id, rect?}`, `app_inspect {tab_id, on}` (the tab's Inspect button).
- `app_input {tab_id, events:[…]}`.
- `app_events {tab_id, topic, since?, limit?}`: Deckhand keeps a ring of the last 500 events per
  topic, subscribed on the app's first connect. Agents read it on demand; nothing is pushed into
  a turn, matching desk's "no automatic notices" rule.
- Every call is logged to the command log without values or code text.

## 5. Agent tools (originally planned as pi-kit `extensions/desk-app`)

**Superseded for the Deckhand route (2026-11-02):** the pi integration's desk extension
(`integrations/pi/extensions/desk`, from pi-kit since 2026-11-04) has four general
tools instead, `app_call {tab, method, params}`, `app_screenshot {tab, rect?}`, `app_input`,
`app_events` (new tabs and restarts through `desk_run`), and their descriptions send agents to
`tab.describe` first. The table below is the earlier per-feature plan, kept for the direct
(no Deckhand) mode still to come.

Loaded in every pi; inert when no app is reachable.

| Tool | Args | Maps to |
|---|---|---|
| `app_tabs` | — | Deckhand: `get_state` filtered to app tabs (id, title, status, paused, tick). Direct: the sockets found |
| `app_describe` | `tab` | `tab.describe` (cached per connection; the tool text lists commands with their arg schemas) |
| `app_act` | `tab, command, args?` | `tab.act` → result + `undo_id` |
| `app_get` / `app_set` | `tab, path, depth?` / `tab, path, value` | `tab.get` / `tab.set` |
| `app_eval` | `tab, code, lang?="lua"` | `tab.eval` |
| `app_screenshot` | `tab, box?, hit?:{x,y}` | `tab.capture` (image content) + optional `tab.hit_test` |
| `app_input` | `tab, events` (compact: `"key w down"`, `"click 120 44"`, `"type hello"`, `"wait 3"` = step 3 ticks) | `app_input` / `input`, `tab.time` |
| `app_time` | `tab, paused?, step?, scale?` | `tab.time` |
| `app_events` | `tab, topic, since?` | Deckhand `app_events`; direct: the extension's own ring |
| `app_record` | `tab, action: start\|stop\|replay, path?, until_tick?` | `tab.record` / `tab.replay` |

**With Deckhand.**
- A pi tab sends `app_call` and the other commands over its bridge's connection (caller
  `panel`, its own session's app tabs only); it opens its project's declared apps there
  (`new_app_tab` by `name`) and restarts and closes them (`app_restart`, `app_close`).
- Atlas sends them over `control` (any app tab).
- `tab` is the Deckhand tab id.

**Without Deckhand** (the game in its own window):
- The engine's normal desktop host, started with `--agent` (DEV builds), listens on
  `$TMPDIR/pi-app-<uid>/<name>-<pid>.sock`. The directory is 0700, and Deckhand's checks apply:
  it must be owned by the user and be a real directory.
- It writes a 0600 `<name>-<pid>.token` beside the socket, and the extension sends that token in
  `hello`.
- The extension is the client. The same `tab.*` requests and `input` messages go to the engine,
  which also answers `tab.capture` itself (readback of its game view, the same reply shape).
- `tab` is `<name>-<pid>`.
- The extension uses Deckhand in a Deckhand pi tab whose tab is a Deckhand app tab, and direct mode
  otherwise. It cannot tell by `DECKHAND_SOCKET`: Deckhand's pi integration takes every
  `DECKHAND_*` variable out of the environment when it loads (before other extensions' tools run).
  It goes through the integration instead: its tools (`app_call`, `app_screenshot`, …, which the
  agent sees), or pi's event bus: emit `deckhand:command` `{requestId, command}` (the browser and
  app commands only) and listen on `deckhand:command:reply:<requestId>`. Only a pi Deckhand started
  has the integration loaded; its bridge replies `{result}` when connected to Deckhand, or
  `{error}` ("Not connected to Deckhand…") when not. No reply means pi is not in Deckhand: direct
  mode.

## 6. Annotation on a game tab

- **Mode.** Annotate (tab toolbar) or ⌘⇧. toggles comment mode. Input stops going to the game.
  Entering pauses the game (`tab.time {paused:true}`); leaving resumes it if it was running. A
  setting, on by default, so moving things can be clicked.
- **Hover.** `tab.hit_test` at most 30 times a second, only after the pointer moves. Deckhand draws
  the outline from `hit.box`; the engine draws nothing. ImGui panels hit as `kind:"ui"`.
- **Click → marker.** All captured at click time (BROWSER §3.3's rule):
  - the entity `id`, `name`, `kind`, `box`, `tick` and `seq`;
  - a **state snapshot**: `tab.get {path:"entities[<id>]", depth:2}`, capped at 8 KB;
  - a **crop** from the shown slot (box + 24 px, at most 1024 px);
  - the paused state.
  - A click on nothing makes a `point` marker with pixel coordinates and `world` if given. A drag
    makes an `area` marker.
- **Pinned to the entity.** Deckhand keeps `tab.track` set to every pending marker's id. Badges sit
  at `tab.boxes` for the shown `seq`. An off-screen entity gets an edge arrow. A `gone` entity
  gets a "gone" label in the list, and the marker stays pending with its snapshot and crop.
- **Pending comments** reuse the browser's chip, list and pi-tab strip (BROWSER §3.6) and its send
  path (`pi.attach`, §3.7). The block:

```
<game-comments count="1" tab="sandbox">
1. Entity e:12:3 "bee" (kind entity) at tick 1834, paused · box 412,220 40×40 · image 1
   State: {"pos":[1.0,0.0,3.2],"hp":3,"mood":"angry",…}
   Comment: It clips through the fence here.
</game-comments>
```

- **Recording link.** If a recording is running when the comment is made, the marker carries
  `{recording, tick}` and the block says "recording <path>, tick 1834", so an agent can replay to
  that tick.

## 7. The fake test app (`tests/fake-app/`)

- **Language:** Odin for the logic and JSON (`core:encoding/json`), linking the *connect* half of
  `src/native/frames_macos.m`, the same file Deckhand serves with.
- **Build:** `build.sh fake-app` → `build/fake-app`. No window and no sokol. Metal only, through
  the C file.
- **About 600 lines.** All of it runs in quiet test mode, because nothing is shown outside
  Deckhand.

**Behaviour.**
- **Startup:** hello with `PI_DESK_TOKEN`, then the Mach `HELLO`, then wait for `RING`.
- **Loop at 60 Hz** (a `mach_wait_until` timer). When not paused: `tick += round(scale)` (scale
  < 1 ticks every 1/scale frames). Then render if a slot is held.
- **Render, with no shaders:**
  - a render pass with a Clear load action: background `#202830`;
  - a blit `copyFromBuffer:toTexture:` from a 1×1-pixel-colour `MTLBuffer` for each entity box:
    square `#FF4040`, wall `#40A040`, coin `#F0D020`;
  - then the empty completion buffer and `FRAME`.
  - `--cpu` writes pixels through `IOSurfaceLock` instead, for debugging.
- **Deterministic world** in logical px of the tab:
  - `e:1:1` "square", 40×40. Position: `x = 20 + (tick*speed) mod (w-60)`, `y = 40`, `speed = 2`.
    With `game.square.mode = "keys"`, the arrow keys move it 4 px per tick instead.
  - `e:2:1` "wall": fixed at 20,120, 200×20.
  - `e:3:1` "coin": fixed at 300,200, 16×16.
- **`tab.describe`**: commands `spawn {name, x, y}` (edits), `delete {id}` (edits),
  `undo {undo_id}`, `set_color {id, rgb}` (edits), `save {path}` (writes_files), and
  `play`/`stop` (stop restores the snapshot taken at play); roots `game`, `entities`; eval
  `["lua"]`; topics `log`, `script_error`, `reload`.
- **`tab.get`/`tab.set`:**
  - on `game.tick`, `game.paused`, `game.scale`, `game.square.{speed,mode,color}` and
    `entities[e:i:g].{name,x,y,w,h,color}`;
  - a deleted slot bumps `gen`, so the old id gives `gone`;
  - a bad field gives `no_path`; `game.tick` is `read_only`.
- **`tab.hit_test`:** the topmost box, or `hit:null`. `tab.track`/`tab.boxes` as specified.
- **`tab.eval`:** `lang:"lua"` with code `return <path>` returns that path's value; code
  containing `error(` returns `script_error` with a fake traceback; anything else echoes
  `{"value":null,"output":"<code>"}`.
- **`tab.time`, `tab.record`, `tab.replay`:**
  - record: per-tick input events written to a JSON file;
  - replay: restore the play snapshot and feed the events back (in `keys` mode the square's path
    must match);
  - `step` replies after N ticks.
- **Fault flags:**
  - `--slow-ms N` delays each commit;
  - `--hang-after N` stops reading everything after N frames;
  - `--crash-after N` calls `abort()`;
  - `--exit N` exits with code N after the hello;
  - `--no-frames` never connects the Mach channel;
  - `--flash` fills whole frames in two alternating colours (the tearing test);
  - `--bad-key` sends a wrong `HELLO` key;
  - `--listen` (direct mode, for the agent tools' tests) serves the NDJSON socket itself, with
    CPU-readback capture.
- **Logs** `tab.log` once a second, and `tab.reload {kind:"script"}` on `SIGUSR1`.

**New autotest commands:**
- `app_open NAME|ARGV…` (from a fixture `.pi-desk/apps.json`);
- `app_waitframe [SEQ] [MS]`;
- `assert_app_pixel X Y RRGGBB` (reads the shown IOSurface);
- `app_call JSON WANT_SUBSTRING`;
- `assert_app_status running|exited|stalled`;
- `app_kill`.

The existing `click`, `type`, `key` and `scroll` commands reach the tab through the real routing.

## 8. Build plan (Deckhand side)

Every step: a branch, unit tests for the pure parts, and a quiet-mode script in `tests/scripts/`.
Step 1 carries the most risk: it is native IPC and process-lifetime code.

| # | Step | Scope | Tests (fake app, quiet mode) |
|---|---|---|---|
| 1 | **Frames + app tab + input** | `App_Tab`, `new_app_tab`, `apps.json`, spawn, logs, exit, restart, exit 75; `frames_macos.m` serve + connect, `Frame_Ring`; resize; stall badge; **CEF moved onto the ring (tearing fix, edge trim)**; input routing, capture, release on focus loss; the `app` caller and hello `frames`; fake app frames + input | square pixel moves between `app_waitframe`s; a resize sends a new ring (`RING_DONE` seen, old surfaces freed); `--crash-after` → dimmed last frame + bar → Restart works; `--hang-after` → not responding; `--bad-key` refused; a key reaches the fake (`keys` mode moves the square); the browser scripts still pass; a 200-frame run never shows a torn pixel (`--flash`: the fake fills each frame with one of two colours, alternating; every sampled pixel is one of the two) |
| 2 | **Protocol** | the `tab.*` forwarding, `app_call`, `app_input`, `app_events`, error `code`, `tab.capture` in Deckhand, `tab.time`; TAB-PROTOCOL.md and PROTOCOL.md updated (incl. dropping `resize` for texture tabs) | describe lists `spawn` with its schema; `spawn` → `undo_id`, `undo` removes it; `delete` then `get` → `gone`; `set game.tick` → `read_only`; `step 10` → tick+10 exactly; `hit_test` on the square → `e:1:1`; capture PNG pixel = square colour; eval error → `script_error` |
| J | **Joint spike with a real engine** (its own 4 steps) | the engine's desk host renders the sandbox into the ring; keys and mouse; `hit_test` + `get` return one entity; `act step 10` advances exactly 10 ticks | the same scripts with `apps.json` pointing at the engine; needs steps 1–2 here and the engine's editor |
| 3 | **Agent tools** | the agent tools (§5: built for the Deckhand route as four general tools; the direct mode not yet); `app_*` in `list_commands`; activity strip, Stop, Take over | unit tests against the fake in `--listen` mode; via Deckhand with a fake caller; a user click pauses agent input |
| 4 | **Annotation** | comment mode with auto-pause, hover outlines, markers, `tab.track` badges, snapshot + crop, pending strip, `pi.attach` send | click the square → marker JSON has `e:1:1`, snapshot, crop size; the badge follows the square across frames; delete it → "gone"; the fake bridge receives the block |
| 5 | **Record and replay** | toolbar Record/Stop/Replay, recordings list per tab, the marker's recording link, `app_record` | record in `keys` mode, replay, the square's positions match tick by tick; replay `until_tick` stops there |

## 9. Risks and open questions (recommended answers)

- **R1 Dynamic bootstrap names get locked down by Apple.** Chromium's MachPortRendezvous depends
  on them, so this is unlikely soon. Fallback: an `SMAppService` LaunchAgent broker with `NSXPCListener`. That route
  also enables `MTLSharedEvent`. The ring and the messages stay; only the transport file changes.
- **R2 The empty buffer's ordering is undocumented.** Probes saw it hold every time, at about
  0.1 ms. If it ever breaks, use the sokol patch (§2.3, step 4).
  **Latency:** expect 0.01–0.1 ms. Step 1 measures FRAME
  latency (commit → Deckhand receipt). Above 4 ms p95, revisit R1's route.
- **R3 Dual-GPU Macs.** The `device` registryID in the hello. If the engine cannot get that
  device, it says so in the hello and Deckhand shows an error, rather than copying across GPUs.
- **R4 Large replies vs the 1 MiB line limit.** `get` has depth and size caps with `truncated`;
  capture never goes through the app's NDJSON with Deckhand.
- **R5 An engine that blocks its frame on a long request** (reimport, a long step). Replies may
  come out of order and `long` commands reply when done; Deckhand times out per call.
- **Q1 Does the ImGui editor render into the texture?** Yes, the whole editor (the engine
  side's recommendation). Deckhand overlays still draw on top, and `hit_test` reports `ui`.
- **Q2 Keep simulating while the tab is hidden?** Yes, and stop rendering. A per-tab "pause when
  hidden" setting, off by default.
- **Q3 Pause on entering comment mode?** Yes, on by default (§6).
- **Q4 Cursor lock for mouse-look?** Later. The engine sends `tab.cursor {hidden, locked}`;
  Deckhand applies it only while the tab has focus, and Esc always frees it.
- **Q5 Attach to an engine started outside Deckhand** (e.g. under lldb)? Later: `app_attach_token
  {session}` mints a single-use `app` token for a manual start. Until then, attach lldb to the
  pid Deckhand started.
- **Q6 Where do recordings live?** The engine decides, under the game's gitignored `build/`.
  Deckhand passes paths through and never reads the files.
- **Q7 Confirmation for `writes_files` commands?** None by default (the rule: agents may
  do anything). The flag lets the user turn on `ask` for one class later (`app_write`).

## Engine side: what an engine implements

1. A **desk host** (beside the engine's normal windowed host): no sokol_app window. It reads `PI_DESK_SOCKET` and
   `PI_DESK_TOKEN`, sends `hello` (§1), swaps in the `reconnect_token`, and drains NDJSON on a
   background thread into the per-frame mailbox.
2. **Metal setup:** pick the `MTLDevice` whose `registryID` matches the hello's `frames.device`,
   then `sg_setup` with it and no swapchain.
3. **The Mach connect side** (§2.2): `bootstrap_look_up(frames.service)` (never check in a name
   yourself: Deckhand checks in once per process), `HELLO {key, tab_id}` with a reply port whose
   queue limit is raised to 64, sent from a process in the tab's process group or session.
   Receive `RING`, wrap each IOSurface as an `MTLTexture` → `sg_image` (render target), and reply `RING_DONE` when switching rings. Copying the connect half of
   `src/native/frames_macos.m` is fine.
4. **The frame rule:** render only into slots it holds. After `sg_commit`, commit an empty command
   buffer on `sg_mtl_command_queue()`; its completed handler sends `FRAME {gen, slot, seq, tick}`.
   That ordering is empirical, not documented (probe: 20/20, +0.11 ms). Take slots back on
   `RELEASE`. With no free slot, skip rendering and keep ticking.
   - **Optional, stronger:** a tiny sokol patch exposing the frame's own `MTLCommandBuffer`, so
     `addCompletedHandler` goes on the frame buffer itself (documented ordering).
   - **Only `FRAME` may be dropped:** send it with `MACH_SEND_TIMEOUT`, timeout 0, and take the
     slot back if the send fails. Send `HELLO` and `RING_DONE` with no timeout. Drain `RING`
     and `RELEASE` promptly on a dedicated queue: Deckhand gives up after 250 ms and treats the
     engine as hung.
5. **Pace itself to 60 Hz** (no display link). Render nothing while `tab.visible` is false.
6. **Death handling:** a dead-name notification or socket EOF means `--on-desk-exit=window|exit`.
   Never touch the old surfaces again. Exit code 75 means "restart me".
7. **`input` messages → `Game_Input`** (sokol keycode names, logical px × scale, `focus`, `char`),
   applied at the tick boundary. `source:"agent"` changes nothing.
8. **Requests**, answered by the game:
   - `tab.describe` from the command registry with JSON-Schema-subset args reflected from each
     arg struct, plus `edits`/`writes_files`/`long` flags;
   - `tab.act` with `undo_id` (`u:<n>`) when the undo log recorded an edit, and an `undo` command
     that takes one;
   - `tab.get`/`tab.set` on the §4 path grammar through `core:reflect` and Lua tables;
   - `tab.eval {lang:"lua"}` returning `{value, output}`;
   - `tab.hit_test` from the picking pass, with `box` in logical px and `seq`;
   - `tab.track` → `tab.boxes`;
   - `tab.time` (pause, step N replying after N ticks, scale);
   - `tab.record`/`tab.replay` (Play snapshot + per-tick input);
   - `tab.subscribe` (log, script_error, profiler ≤ 4/s, reload);
   - `tab.visible`, `tab.ping`, `tab.quit`.
9. **Errors** in the §4 shape with `code`. A stale generation is always `gone`.
10. **Events:** `tab.reload` for dylib, Lua and state-size restarts; `tab.time` when the pause
    state or mode changes.
11. **Direct mode** in the desktop host (`--agent`, DEV only): listen on
    `$TMPDIR/pi-app-<uid>/<name>-<pid>.sock` with a 0600 token file, serve the same requests, and
    answer `tab.capture` by reading back the game view.
12. **No version numbers** anywhere but the envelope's `v:1`.

## Sources

- macOS SDK 26.1 headers: `Metal.framework/Headers/MTLEvent.h` (`MTLSharedEventHandle` "may be
  passed between processes via XPC connections"), `IOSurface.framework/Headers/IOSurfaceRef.h`
  (`IOSurfaceCreateMachPort`, `IOSurfaceLookupFromMachPort`), `IOSurfaceAPI.h`
  (`IOSurfaceCreateXPCObject`), `xpc/connection.h`, `servers/bootstrap.h`.
- Chromium [mach_port_rendezvous_mac.cc](https://chromium.googlesource.com/chromium/src.git/+/main/base/apple/mach_port_rendezvous_mac.cc)
  (`bootstrap_check_in` of `<bundle id>.MachPortRendezvousServer.<pid>`).
- Probes on macOS 26.6.2 (`evx.m`, `xpcl.m`, `boot.c`, `order.m`), not kept in the repository.
- Deckhand `browser-spike` (`src/native/cef_macos.m` `on_accelerated_paint`, `src/browser.odin`).
