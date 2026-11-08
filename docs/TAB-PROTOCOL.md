# Deckhand tab protocol (draft)

What a program does to be built into Deckhand as a tab: show itself inside the window, take input
from Deckhand, and expose its own commands, state and events to Deckhand and its agents. Terminals,
the markdown viewer, game engines and browsers all meet the same contract in different ways.
Programs that do not implement it still run, in a native view or their own window, with less
integration.

Status: app tabs ([ENGINE-BRIDGE.md](ENGINE-BRIDGE.md)) and browser tabs ([BROWSER.md](BROWSER.md))
implement the texture path and the control pass-through; the native-view and own-window modes are
not built.

## 1. Display

Preferred: **shared GPU texture.** Deckhand creates (or imports) a texture the program renders
into, and draws it with Clay as an image, so Deckhand's overlays (palette, confirmation bar,
annotation boxes, focus rings) and shortcuts keep working on top.

| OS | Shared surface | Into sokol_gfx |
|---|---|---|
| macOS | IOSurface → `MTLTexture` | `sg_image_desc.mtl_textures` |
| Windows | D3D11 shared handle (`IDXGISharedResource` / NT handle) | `sg_image_desc.d3d11_texture` |
| Linux | dmabuf fd → EGL image → GL texture | `sg_image_desc.gl_textures` |

sokol_gfx supports wrapping native textures ("ADVANCED TOPIC: Injecting native 3D-API textures"
in `vendor/sokol-odin/sokol/c/sokol_gfx.h`). Frame handshake: the program signals "frame ready"
(control channel event or a shared fence); Deckhand redraws on it, so idle tabs cost nothing. The
size follows the tab's pane (its own pane when the session is split): Deckhand sends `resize{w, h, scale}`; the program reallocates or Deckhand
hands it a new surface.

Fallback: **native child view.** The program's own view is attached to the window's native
handle (`sapp_macos_get_window`, `sapp_win32_get_hwnd`, `sapp_x11_get_window`) and positioned
over the tab's pane. It sits above GL content, so Deckhand disables overlays over that pane (the
palette and confirmation bar move outside it or temporarily hide the view), and the view keeps the
keyboard while focused (Deckhand's shortcuts work only when focus leaves it).

Last resort: **own window.** The program keeps its own window; the tab shows its status and the
control channel still works.

Deckhand-drawn tabs (terminals, markdown) are a fourth case: Deckhand renders them itself
(`Tab_Display.Drawn`).

## 2. Input

Deckhand owns input. Keyboard, text (including IME, through `NSTextInputClient` on macOS),
mouse and scroll go to the focused tab only, after Deckhand took its own shortcuts.
Texture tabs receive events over the control channel in tab coordinates (logical px + scale):

```json
{"type": "input", "event": "key", "action": "down", "key": "a", "text": "a", "mods": ["shift"]}
{"type": "input", "event": "mouse", "action": "down", "button": "left", "x": 120, "y": 44}
{"type": "input", "event": "scroll", "dx": 0, "dy": -3, "x": 120, "y": 44}
{"type": "input", "event": "focus", "focused": true}
```

Native views get native events directly (degraded mode).

## 3. Control

The program exposes commands, state and events over the envelope in [PROTOCOL.md](PROTOCOL.md)
(NDJSON, `{id, type, v, …}`, `hello` with version and token). Deckhand starts the program with
`DECKHAND_SOCKET` and a per-tab `DECKHAND_TOKEN`, or connects to an address the program announces.
The program speaks first (`hello`); Deckhand's hello reply is the first line it gets, and nothing
(requests, `input`) is sent before that reply.
Which requests a program answers is its own business: Deckhand passes any method through
(`app_call {method, params}`, PROTOCOL.md) and keeps only `tab.quit`, `tab.visible` and `tab.display` for itself.
Agents ask the program with `tab.describe` first. Suggested common requests:

| type | reply |
|---|---|
| `tab.describe` | name, version, display mode, the commands it supports |
| `tab.hit_test` `{x, y}` | what is at that point (element, entity, cell…), with an id usable in other commands |
| `tab.capture` `{x, y, w, h}` | PNG (base64) of a region; for texture tabs Deckhand takes it itself from the frame it shows (`app_screenshot`) |
| `tab.inspect` `{id}` | the state of one thing (DOM node, entity, file section) |
| `tab.act` `{action, …}` | do something (click, type, set a value, step a frame) |
| `tab.state` / `subscribe` | the program's own state and events |

Deckhand's agents reach these through Deckhand (caller capabilities and confirmation apply), and pi
extensions expose them as general tools (`app_call`, `app_screenshot`, `app_input`,
`app_events`), not one tool per request. A program may send `tab.boxes` (`[{id, label, rect}]`
in logical px) for Deckhand's Inspect overlay.

## 4. How each tab kind fits

| Tab | Display | Input | Control |
|---|---|---|---|
| terminal (pi, shell, Claude) | drawn by Deckhand from libghostty-vt in process | encoded by libghostty-vt to the PTY | pi tabs: the bridge (PROTOCOL.md §4); Claude tabs: the plugin's hooks and `deckhand` CLI (CLAUDE.md) |
| markdown | drawn by Deckhand (own parser, `src/markdown.odin`) | Deckhand | Deckhand commands (open, scroll, find) |
| game engine | texture, via a small Odin package linked into the engine | forwarded input events | the package implements `tab.*`: this **is** the engine bridge ([ENGINE-BRIDGE.md](ENGINE-BRIDGE.md)): inspect/set state, pause/step, capture, inject input, hit test |
| browser | CEF off-screen rendering into the texture | forwarded to CEF | Chrome DevTools Protocol behind an adapter that answers `tab.*` (hit test, capture, act) |
| any other app | native view or own window | native | none, or whatever it implements |

## 5. In code

`src/tabhost.odin` has the in-process interface as types: `Tab_Display` and `Tab_View` (draw,
texture, input, capture, control), and `tab_view(kind)` picks the host for each tab kind. The
frame draws each pane's shown tab (one per pane when the session is split) through `tab_view(kind).draw`. Terminal, editor, Changes and Markdown
tabs are `.Drawn`; browser tabs (`src/browser.odin`) and app tabs (`src/app_tab.odin`, frames
over IOSurface) are `.Texture` and draw their texture themselves. Input is routed per tab kind in
`main.odin`, and an app's control requests go through `app_call` on the socket (PROTOCOL.md), not
through `Tab_View.control`. Clay `.Image` render commands are not used (`ui_draw`).

## Open questions

- Who allocates the shared surface (Deckhand, so it controls size and format, is the default) and
  how a crashed program's surface is released.
- Linux: dmabuf import needs EGL; sokol's Linux backend uses GLX by default.
- Whether a separate window process (the planned process split, [ROADMAP.md](ROADMAP.md))
  renders the same tab protocol textures from the core, or each window imports them directly.
