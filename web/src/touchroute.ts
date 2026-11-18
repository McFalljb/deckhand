// Where a touch scroll's lines go in a terminal (pure; term.ts applies it), as the wheel's do:
// - "scrollback": the normal screen and the program does not take the wheel: the page's own copy
//   scrolls, nothing is sent;
// - "reports": the program takes the wheel (mouse mode vt200, drag or any): wheel mouse reports;
// - "arrows": the alternate screen without wheel reports: xterm.js sends arrow keys;
// - "none": reports or arrows would be sent, but this pane is not the one typed into.
// Only scrollback and wheel reports coast after a flick: arrows are keystrokes, and a coast of them
// would move a selection (an agent's permission choice) the user never moved.

export type TouchRoute = "scrollback" | "reports" | "arrows" | "none";

export function touchRoute(mouseMode: string, buffer: "normal" | "alternate", reports: boolean): TouchRoute {
  const wheel = mouseMode === "vt200" || mouseMode === "drag" || mouseMode === "any";
  if (!wheel && buffer === "normal") return "scrollback";
  if (!reports) return "none";
  return wheel ? "reports" : "arrows";
}

export const routeCoasts = (r: TouchRoute): boolean => r === "scrollback" || r === "reports";

// The window in which xterm.js handles a touch scroll's wheel events: its stdin on (it drops what
// it would send otherwise) and what it sends marked as the scroll's (not typing), both only for
// the dispatch, restored even if it throws.
export class WheelWindow {
  active = false;
  run(stdin: { disabled(): boolean; setDisabled(v: boolean): void }, dispatch: () => void): void {
    const was = stdin.disabled();
    stdin.setDisabled(false);
    this.active = true;
    try {
      dispatch();
    } finally {
      this.active = false;
      stdin.setDisabled(was);
    }
  }
}
