// A tab's status strip (bars.ts): the native window's bars over a Claude, Codex or pi tab, as text
// with the actions a browser may take. Text goes in as text nodes (JSX children), never as HTML.
import { tabKind, type Tab } from "../state.ts";
import { useApp } from "./ctx.ts";
import { barsFor } from "./bars.ts";

export function TabBars({ tab }: { tab: Tab }) {
  const app = useApp();
  const bars = barsFor(app.store, tab);
  if (!bars.length || !tabKind(tab)) return null;
  return (
    <div class="tab-bars" role="status">
      {bars.map((b, i) => (
        <div class={"tab-bar " + (b.tone === "error" ? "error" : b.tone === "info" ? "info" : "waiting")} key={b.kind + ":" + b.tab + ":" + i}>
          <span class="dot" aria-hidden="true" />
          <span class="tab-bar-text">{b.text}</span>
          {b.actions.map((a, k) => (
            <button
              type="button"
              class={"btn small" + (k === b.actions.length - 1 && a.command ? " primary" : "")}
              key={a.label}
              onClick={() => {
                if (a.command) void app.run(a.command);
                else if (a.copy !== undefined) app.setOverlay({ copy: a.copy });
                else if (a.settings) app.go({ screen: "settings" });
              }}
            >
              {a.label}
            </button>
          ))}
        </div>
      ))}
    </div>
  );
}
