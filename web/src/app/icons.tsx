// The native window's icon set (src/core/icons_core.odin, drawn in src/icons.odin): simple shapes on
// a 16-unit grid with one stroke width, in the caller's colour (currentColor). The harness logos are
// the pixel grids of src/logos.odin. SVG elements only: no inline styles.

import type { ComponentChildren } from "preact";
import type { Dot, Mark } from "../status.ts";

export type IconName =
  | "search" | "compose" | "plus" | "chevron-down" | "chevron-right" | "sidebar-left" | "sidebar-right"
  | "sliders" | "close" | "more" | "check" | "folder" | "chat" | "sort" | "bell" | "alert" | "clock"
  | "play" | "pause" | "stop" | "info" | "eye" | "deck" | "split-right" | "split-down" | "refresh"
  | "file" | "branch" | "pi" | "claude" | "codex" | "terminal" | "pin" | "keyboard" | "back" | "send" | "atlas" | "arrow-up" | "arrow-down";

function paths(name: IconName): ComponentChildren {
  switch (name) {
    case "search":
      return <><circle cx="7" cy="7" r="4.25" /><path d="M10.2 10.2 13.5 13.5" /></>;
    case "compose":
      return <><path d="M13 8.5V13a.5.5 0 0 1-.5.5h-9A.5.5 0 0 1 3 13V4a.5.5 0 0 1 .5-.5H8" /><path d="M7 9.5 7.4 7.6 12.6 2.4l1.5 1.5L8.9 9.1Z" /></>;
    case "plus":
      return <path d="M8 3.25v9.5M3.25 8h9.5" />;
    case "chevron-down":
      return <path d="m4.5 6.25 3.5 3.5 3.5-3.5" />;
    case "chevron-right":
      return <path d="m6.25 4.5 3.5 3.5-3.5 3.5" />;
    case "arrow-up":
      return <path d="m4.5 9.75 3.5-3.5 3.5 3.5" />;
    case "arrow-down":
      return <path d="m4.5 6.25 3.5 3.5 3.5-3.5" />;
    case "back":
      return <path d="m9.75 3.5-4.5 4.5 4.5 4.5" />;
    case "sidebar-left":
      return <><rect x="2.25" y="3" width="11.5" height="10" rx="1.5" /><path d="M6.25 3v10" /></>;
    case "sidebar-right":
      return <><rect x="2.25" y="3" width="11.5" height="10" rx="1.5" /><path d="M9.75 3v10" /></>;
    case "sliders":
      return <><path d="M2.5 5h11M2.5 11h11" /><circle cx="10" cy="5" r="1.6" class="fill" /><circle cx="6" cy="11" r="1.6" class="fill" /></>;
    case "close":
      return <path d="m4.5 4.5 7 7m0-7-7 7" />;
    case "more":
      return <><circle cx="3.5" cy="8" r="1" class="fill" /><circle cx="8" cy="8" r="1" class="fill" /><circle cx="12.5" cy="8" r="1" class="fill" /></>;
    case "check":
      return <path d="m3.5 8.5 3 3 6-7" />;
    case "folder":
      return <path d="M2.25 4.5A1 1 0 0 1 3.25 3.5h3l1.5 1.5h5a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-9.5a1 1 0 0 1-1-1Z" />;
    case "chat":
      return <path d="M3 3.5h10a.75.75 0 0 1 .75.75v6.5a.75.75 0 0 1-.75.75H7.5L4.5 13.75V11.5H3a.75.75 0 0 1-.75-.75v-6.5A.75.75 0 0 1 3 3.5Z" />;
    case "sort":
      return <path d="M5 13V3M2.75 5.25 5 3l2.25 2.25M11 3v10m-2.25-2.25L11 13l2.25-2.25" />;
    case "bell":
      return <><path d="M4 11.25V7.5a4 4 0 0 1 8 0v3.75l1 1H3Z" /><path d="M6.75 13.5a1.4 1.4 0 0 0 2.5 0" /></>;
    case "alert":
      return <><path d="M8 2.75 14 13.25H2Z" /><path d="M8 6.5v3.25M8 11.4v.1" /></>;
    case "clock":
      return <><circle cx="8" cy="8" r="5.5" /><path d="M8 5v3.25l2.25 1.5" /></>;
    case "play":
      return <path d="M5 3.5v9l7.5-4.5Z" class="fill" />;
    case "pause":
      return <path d="M5.5 3.5v9M10.5 3.5v9" />;
    case "stop":
      return <rect x="4" y="4" width="8" height="8" rx="1" class="fill" />;
    case "info":
      return <><circle cx="8" cy="8" r="5.5" /><path d="M8 7.25v3.5M8 5.1v.1" /></>;
    case "eye":
      return <><path d="M1.75 8S4 3.75 8 3.75 14.25 8 14.25 8 12 12.25 8 12.25 1.75 8 1.75 8Z" /><circle cx="8" cy="8" r="1.9" /></>;
    case "deck":
      return <><rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1" /><rect x="9" y="2.5" width="4.5" height="4.5" rx="1" /><rect x="2.5" y="9" width="4.5" height="4.5" rx="1" /><rect x="9" y="9" width="4.5" height="4.5" rx="1" /></>;
    case "split-right":
      return <><rect x="2.25" y="3" width="11.5" height="10" rx="1.5" /><path d="M8 3v10" /></>;
    case "split-down":
      return <><rect x="2.25" y="3" width="11.5" height="10" rx="1.5" /><path d="M2.25 8h11.5" /></>;
    case "refresh":
      return <><path d="M13 8a5 5 0 1 1-1.5-3.55" /><path d="M11.75 2v2.75H9" /></>;
    case "file":
      return <path d="M4 2.5h5l3 3V13a.5.5 0 0 1-.5.5h-7.5A.5.5 0 0 1 3.5 13V3a.5.5 0 0 1 .5-.5ZM9 2.5V5.5h3" />;
    case "branch":
      return <><circle cx="5" cy="3.75" r="1.5" /><circle cx="5" cy="12.25" r="1.5" /><circle cx="11" cy="6" r="1.5" /><path d="M5 5.25v5.5M11 7.5c0 2.5-6 1.5-6 3.25" /></>;
    case "pi":
      return <path d="M3 4.5h10M6 4.5v8M10.25 4.5v6.5c0 1 .75 1.5 1.75 1.25" />;
    case "claude":
      return <path d="M8 2.5v11M3.25 5.25l9.5 5.5M12.75 5.25l-9.5 5.5" />;
    case "codex":
      return <path d="m3.5 4.5 3.5 3.5-3.5 3.5M8.5 12h4" />;
    case "terminal":
      return <><rect x="2" y="3" width="12" height="10" rx="1.5" /><path d="m4.75 6.25 2 1.75-2 1.75M8.25 10h3" /></>;
    case "pin":
      return <path d="M6 2.5h4M7 2.5v4l-2.5 2.5h7L9 6.5v-4M8 9v4.5" />;
    case "keyboard":
      return <><rect x="1.75" y="4" width="12.5" height="8" rx="1.25" /><path d="M4.5 6.5h.1M7 6.5h.1M9.5 6.5h.1M12 6.5h-.4M5 9.5h6" /></>;
    case "send":
      return <path d="M8 13V3.5M4 7.25 8 3.25l4 4" />;
    case "atlas":
      return <><circle cx="8" cy="8" r="5.5" /><path d="M2.5 8h11M8 2.5c-2.5 3-2.5 8 0 11M8 2.5c2.5 3 2.5 8 0 11" /></>;
  }
}

export function Icon({ name, size = 16, class: cls }: { name: IconName; size?: number; class?: string }) {
  if (name === "pi" || name === "claude") return <Logo name={name} size={size} class={cls} />;
  return (
    <svg class={"icon " + (cls ?? "")} width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
      {paths(name)}
    </svg>
  );
}

// ---- logos (src/logos.odin): pixel grids in their own colours ----

const LOGOS: Record<"pi" | "claude", { rows: string[]; inks: Record<string, string> }> = {
  pi: { rows: ["PPP.", "B.P.", "BB.G", "B..G"], inks: { P: "#f09082", B: "#4d9abf", G: "#f1be58" } },
  claude: {
    rows: [
      "..#############..",
      "..#############..",
      "..##e#######e##..",
      "..##e#######e##..",
      "#################",
      "#################",
      "..#############..",
      "..#############..",
      "..#.#.......#.#..",
      "..#.#.......#.#..",
    ],
    inks: { "#": "#d77757", e: "#000000" },
  },
};

export function Logo({ name, size = 14, class: cls }: { name: "pi" | "claude"; size?: number; class?: string }) {
  const art = LOGOS[name];
  const w = art.rows[0].length, h = art.rows.length, side = Math.max(w, h);
  const rects = [];
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const k = art.rows[y][x];
      if (k !== ".") rects.push(<rect x={x + (side - w) / 2} y={y + (side - h) / 2} width="1.02" height="1.02" fill={art.inks[k]} />);
    }
  return (
    <svg class={"logo " + (cls ?? "")} width={size} height={size} viewBox={`0 0 ${side} ${side}`} shape-rendering="crispEdges" aria-hidden="true">
      {rects}
    </svg>
  );
}

export function HarnessIcon({ harness, size = 14 }: { harness: "pi" | "claude" | "codex" | "shell"; size?: number }) {
  if (harness === "pi") return <Logo name="pi" size={size} />;
  if (harness === "claude") return <Logo name="claude" size={size} />;
  if (harness === "codex") return <Icon name="codex" size={size} />;
  return <Icon name="terminal" size={size} />;
}

// ---- status marks (src/icons.odin Mark_*): one shape per status, never colour alone ----

const MARK_LABEL: Record<Mark, string> = {
  idle: "idle",
  exited: "exited",
  working: "working",
  progress: "working",
  waiting: "waiting for you",
  permission: "wants permission",
  question: "asked you something",
  auth: "wants a login",
  done: "finished",
  error: "stopped with an error",
};

export function StatusMark({ mark, progress = -1 }: { mark: Mark; progress?: number }) {
  let body: ComponentChildren;
  switch (mark) {
    case "idle":
      body = <circle cx="8" cy="8" r="2.5" class="fill" />;
      break;
    case "exited":
      body = <circle cx="8" cy="8" r="2.5" />;
      break;
    case "working":
      body = <><circle cx="8" cy="8" r="5" class="track" /><path d="M8 3a5 5 0 0 1 5 5" /></>;
      break;
    case "progress": {
      const a = Math.max(0, Math.min(1, progress)) * 2 * Math.PI;
      const x = 8 + 3.5 * Math.sin(a), y = 8 - 3.5 * Math.cos(a);
      body = <><circle cx="8" cy="8" r="5.5" /><path d={`M8 8V4.5A3.5 3.5 0 ${a > Math.PI ? 1 : 0} 1 ${x.toFixed(2)} ${y.toFixed(2)}Z`} class="fill" /></>;
      break;
    }
    case "waiting":
      body = <circle cx="8" cy="8" r="5" class="fill" />;
      break;
    case "permission":
      body = <path d="M8 2.5 13 4.5v3.25c0 3-2.25 5-5 5.75-2.75-.75-5-2.75-5-5.75V4.5Z" class="fill" />;
      break;
    case "question":
      body = <path d="M5.75 6a2.25 2.25 0 1 1 3.4 1.95C8.4 8.4 8 8.9 8 9.75M8 12.1v.15" />;
      break;
    case "auth":
      body = <><rect x="3.5" y="7.25" width="9" height="6.25" rx="1" class="fill" /><path d="M5.5 7.25V5.5a2.5 2.5 0 0 1 5 0v1.75" /></>;
      break;
    case "done":
      body = <path d="m3.5 8.5 3 3 6-7" />;
      break;
    case "error":
      body = <path d="M8 3v6.25M8 12.25v.25" />;
      break;
  }
  return (
    <svg class={"mark mark-" + mark} width="12" height="12" viewBox="0 0 16 16" role="img" aria-label={MARK_LABEL[mark]}>
      <title>{MARK_LABEL[mark]}</title>
      {body}
    </svg>
  );
}

export function dotMark(d: Dot): Mark {
  switch (d) {
    case "working":
      return "working";
    case "waiting":
      return "waiting";
    case "question":
      return "question";
    case "unseen":
      return "done";
    case "error":
      return "error";
    case "exited":
      return "exited";
  }
  return "idle";
}
