// A one-finger vertical drag as wheel lines (pure: no DOM; term.ts feeds it touches and frames).
//
// Lines are signed as the wheel's: positive is down, toward the newest output (finger moving up),
// negative is back into history (finger moving down). A drag only counts once it has gone SCROLL_SLOP
// px, mostly up or down (a tap, or a sideways swipe, stays what it was), and the slop itself is not
// distance. The distance is cells of the terminal's height with the remainder kept between moves.
// After the finger lifts at speed it coasts: the speed of its last moments, decaying each frame,
// until it is slow; a new touch stops it.

export const SCROLL_SLOP = 8; // px before a drag scrolls
const SAMPLE_MS = 100; // the finger's speed is measured over its last moments
const STILL_MS = 60; // lifted after holding still this long: no coast
const MIN_COAST = 0.3; // px/ms to start coasting
const STOP_COAST = 0.03; // px/ms: stopped
const MAX_COAST = 6; // px/ms
const DECAY = 0.95; // speed kept each 16 ms frame

export type MoveState = "pending" | "scroll" | "ignored";

export class TouchScroll {
  private x0 = 0;
  private y0 = 0;
  private state: MoveState | "idle" = "idle";
  private lastY = 0;
  private rest = 0; // px not yet a whole line (wheel sign)
  private samples: { t: number; y: number }[] = [];
  private v = 0; // coast speed, px/ms in the finger's direction (down is +)
  private tCoast = 0;

  get scrolling(): boolean {
    return this.state === "scroll";
  }
  get coasting(): boolean {
    return this.v !== 0;
  }

  // A finger lands. True when it stopped a coast (its tap is not a tap).
  start(x: number, y: number, t: number): boolean {
    const was = this.coasting;
    this.v = 0;
    this.x0 = x;
    this.y0 = y;
    this.lastY = y;
    this.rest = 0;
    this.state = "pending";
    this.samples = [{ t, y }];
    return was;
  }

  move(x: number, y: number, t: number, cellH: number): { state: MoveState; lines: number } {
    if (this.state === "idle" || this.state === "ignored") return { state: "ignored", lines: 0 };
    if (this.state === "pending") {
      const dx = Math.abs(x - this.x0);
      const dy = Math.abs(y - this.y0);
      if (Math.max(dx, dy) < SCROLL_SLOP) return { state: "pending", lines: 0 };
      if (dx > dy) {
        this.state = "ignored";
        return { state: "ignored", lines: 0 };
      }
      this.state = "scroll";
      this.lastY = y;
      this.samples = [{ t, y }];
      return { state: "scroll", lines: 0 };
    }
    const dy = y - this.lastY;
    this.lastY = y;
    this.samples.push({ t, y });
    while (this.samples.length > 2 && t - this.samples[0].t > SAMPLE_MS) this.samples.shift();
    return { state: "scroll", lines: this.take(-dy, cellH) };
  }

  // The finger lifts. True when it coasts on (call step each frame while coasting).
  end(t: number): boolean {
    const was = this.state;
    this.state = "idle";
    this.v = 0;
    if (was !== "scroll" || this.samples.length < 2) return false;
    const a = this.samples[0];
    const b = this.samples[this.samples.length - 1];
    if (t - b.t > STILL_MS || b.t <= a.t) return false;
    const v = (b.y - a.y) / (b.t - a.t);
    if (!isFinite(v) || Math.abs(v) < MIN_COAST) return false;
    this.v = Math.max(-MAX_COAST, Math.min(MAX_COAST, v));
    this.tCoast = t;
    return true;
  }

  // One frame of a coast: the lines it moves now (0 once stopped).
  step(t: number, cellH: number): number {
    if (!this.v) return 0;
    const dt = Math.max(0, Math.min(t - this.tCoast, 100));
    this.tCoast = t;
    const px = this.v * dt;
    this.v *= Math.pow(DECAY, dt / 16);
    if (Math.abs(this.v) < STOP_COAST) this.v = 0;
    return this.take(-px, cellH);
  }

  stop(): void {
    this.v = 0;
    this.state = "idle";
  }

  private take(px: number, cellH: number): number {
    if (!(cellH > 0) || !isFinite(cellH)) return 0;
    this.rest += px;
    const lines = Math.trunc(this.rest / cellH);
    this.rest -= lines * cellH;
    return lines;
  }
}
