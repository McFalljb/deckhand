import type { Link, Result } from "../link.ts";
import type { Store } from "../state.ts";

// What the screens get from the app.
export interface Ctx {
  link: Link;
  store: Store;
  // runs a command as the user; a failure is a toast (needs_confirmation is the bar's)
  run(command: object): Promise<Result>;
  showHome(): void;
  showProject(projectId: number): void;
  showSession(sessionId: number, tabId?: number): void;
  unpair(): void;
}
