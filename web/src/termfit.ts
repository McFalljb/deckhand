// Who sizes a terminal several clients show (this page, the Mac window, another page): the one
// the user is using. Each asks the core for the grid its own pane fits (term.resize; the core
// applies the last ask); a client the user comes back to asks again, so a TUI another client made
// wider no longer runs off this pane's right edge. The window has the same rule
// (src/term_view_stream.odin, term_fits_reclaim).
//
// Never because another client resized (no back and forth: the other one keeps its size while
// nobody uses this page), never on a scroll alone (reading back on the phone must not reflow the
// Mac's screen under the user there), never from a page that may not type into it (a peek, a
// terminal kept hidden, one under a menu or sheet), and never a second time while this page's
// own ask is on its way.

export type Interaction = "key" | "tap" | "focus" | "visible" | "scroll";

export interface Grid {
  cols: number;
  rows: number;
}

// How long after this page asked a grid that still differs is taken as its answer on the way.
export const RECLAIM_IN_FLIGHT = 1000; // ms

// Whether this page asks for its own grid again. fits: what its pane fits now; pty: the grid the
// terminal has now (the core's last RESIZE); asked/askedAt: what this page asked last and when
// (ms; null: nothing yet, or forgotten); mayType: the user can type into it here.
export function shouldReclaim(
  fits: Grid | null,
  pty: Grid | null,
  kind: Interaction,
  mayType: boolean,
  asked: Grid | null = null,
  askedAt = 0,
  now = 0,
): boolean {
  if (!mayType || kind === "scroll" || !fits || !pty) return false;
  if (fits.cols === pty.cols && fits.rows === pty.rows) return false; // it has this page's grid
  if (asked && asked.cols === fits.cols && asked.rows === fits.rows && now - askedAt < RECLAIM_IN_FLIGHT) return false;
  return true;
}
