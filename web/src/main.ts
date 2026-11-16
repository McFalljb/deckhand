// Deckhand in the browser (issue #148): the native window's layout and features over the core's
// own framed wire on a WebSocket. The page is one Preact tree (app/App.tsx).

import "@xterm/xterm/css/xterm.css";
import "./theme.gen.css";
import "./app.css";

import { start } from "./app/App.tsx";

start(document.getElementById("app")!);
