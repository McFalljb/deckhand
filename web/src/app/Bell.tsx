// The bell (src/ui_bell.odin): a popover with what happened, newest first, from
// notifications_list; a click goes there. The count comes from state (notifications.unread).

import { useEffect, useState } from "preact/hooks";
import { useApp } from "./ctx.ts";
import { Icon, StatusMark } from "./icons.tsx";
import { focusSession } from "./Sidebar.tsx";
import type { Mark } from "../status.ts";

interface Entry {
  id: number;
  time: string;
  kind: string; // finished, waiting, error, exited, job
  read: boolean;
  title: string;
  machine?: string;
  job_id?: string;
  status?: string;
  summary?: string;
  project?: string;
  session_id?: number;
  tab_id?: number;
}

const KIND_MARK: Record<string, Mark> = { finished: "done", waiting: "waiting", error: "error", exited: "exited", job: "done" };
const KIND_WORDS: Record<string, string> = { finished: "Finished", waiting: "Waiting for you", error: "Stopped with an error", exited: "Exited" };

function when(iso: string): string {
  const t = Date.parse(iso);
  if (!t) return "";
  const s = Math.max(0, (Date.now() - t) / 1000);
  if (s < 60) return "now";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  return Math.floor(s / 86400) + "d";
}

export function unreadCount(app: ReturnType<typeof useApp>): number {
  const n = app.store.sections.get("notifications");
  return Number(n?.notices?.unread ?? n?.unread ?? 0) || countUnread(n);
}

function countUnread(n: any): number {
  const items = n?.notices?.items;
  return Array.isArray(items) ? items.filter((x: any) => !x.read).length : 0;
}

export function Bell() {
  const app = useApp();
  const [items, setItems] = useState<Entry[] | null>(null);
  const version = app.store.sections.get("notifications");
  useEffect(() => {
    let live = true;
    app.link.run({ type: "notifications_list", limit: 40 }).then((r) => {
      if (live && r.ok) setItems((r.data?.notifications ?? []) as Entry[]);
    });
    return () => {
      live = false;
    };
  }, [version]);
  const close = () => app.setOverlay({ bell: false });
  return (
    <div class="scrim clear" onMouseDown={close}>
      <div class={"popover bell-pop" + (app.phone ? " phone" : "")} role="dialog" aria-label="Notifications" onMouseDown={(e) => e.stopPropagation()}>
        <div class="pop-head">
          <span class="pop-title">Notifications</span>
          <span class="spacer" />
          <button type="button" class="link-btn" onClick={() => app.run({ type: "notifications_mark_read", all: true })}>
            Mark all read
          </button>
          <button type="button" class="link-btn" onClick={() => app.run({ type: "notifications_clear" })}>
            Clear
          </button>
        </div>
        <div class="bell-list">
          {items === null ? <p class="empty">Loading…</p> : items.length === 0 ? <p class="empty">Nothing yet. Finished, waiting and failed work shows here.</p> : null}
          {items?.map((x) => (
            <button
              type="button"
              class={"bell-row" + (x.read ? "" : " unread")}
              onClick={() => {
                close();
                app.run({ type: "notifications_mark_read", id: x.id });
                if (x.session_id && app.store.session(x.session_id)) focusSession(app, x.session_id, x.tab_id || undefined);
                else if (x.job_id) app.run({ type: "set_left_tab", tab: "jobs" }).then(() => app.go({ screen: "home" }));
              }}
            >
              <span class="bell-mark">{x.job_id ? <Icon name="clock" size={14} /> : <StatusMark mark={KIND_MARK[x.kind] ?? "idle"} />}</span>
              <span class="bell-text">
                <span class="bell-title">{x.title}</span>
                <span class="bell-sub">
                  {x.job_id ? (x.status === "needs_you" ? "Job needs you" : x.status === "failed" ? "Job failed" : "Job finished") : KIND_WORDS[x.kind] ?? x.kind}
                  {x.project ? " · " + x.project : ""}
                  {x.machine ? " · " + x.machine : ""}
                  {x.summary ? " · " + x.summary : ""}
                </span>
              </span>
              <span class="when">{when(x.time)}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
