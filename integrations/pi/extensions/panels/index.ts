/**
 * Deckhand's panel producer for pi tabs: background subagents (pi-subagents), todos (rpiv-todo) and
 * background shells and timers (the optional `shell`, or pi-kit's) as Deckhand panels (docs/PROTOCOL.md §5), from the data pi-kit's sidebar reads (its
 * extensions/sidebar/index.ts, without the terminal column: Deckhand draws the panels). Inert
 * outside a Deckhand pi tab (DECKHAND_SOCKET and the tab's token) and outside the interactive TUI.
 *
 * - Publishes on PANELS_EVENT (`kit:desk:panels`, pi-kit's contract) once the bridge says
 *   Deckhand draws panels (MODE_EVENT true), and again whenever the data changes; the bridge
 *   coalesces what it sends Deckhand to once a second and only on change.
 * - Steps back per panel (lib/claims.ts): an extension that answers the session_start
 *   CAPS_QUERY, or later sends CAPS_CLAIM, with `panels:todos`, `panels:subagents` or `panels:shells` takes that
 *   panel over: what we published of it is cleared first (one empty panel: the bridge keeps one
 *   copy per panel name, the last one any producer published, and the claimant may publish
 *   nothing). So does any other
 *   producer that publishes the panel with rows on PANELS_EVENT (pi-kit's sidebar does, once
 *   MODE_EVENT says Deckhand draws panels); its copy has replaced ours already. An empty one
 *   (rows: []) takes nothing over, so a single empty message cannot hide a panel for good.
 * - Data: pi-subagents' event-bus status RPC, re-read when its job events fire; the task line of
 *   this session's own `subagent` calls; rpiv-todo's state on the session branch and `todo` tool
 *   results (completed todos fold into one "✓ N done" row from the next run on, and at once after a
 *   relaunch, /tree or compaction); the rows
 *   on SHELL_ROWS_EVENT (`kit:shell:rows`), as pi-kit's sidebar reads them.
 *
 * Never throws into pi.
 */

import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { CAPS_CLAIM, CAPS_QUERY, PANEL_CAPS, parseClaim } from "../../lib/claims.ts";
import { adoptEnv, inDesk, MODE_EVENT, PANELS_EVENT, SHELL_ROWS_EVENT, shellRows } from "../../lib/protocol.ts";
import { type Data, deskPanels, hideCompleted, nextHide, type Panel, resumeTodos, type Run, SUBAGENT_EVENTS, subagentTask, type TodoState, todosFromBranch, todoView, trackFinished, trackTodos } from "../../lib/rows.ts";

const OURS = new Set(Object.values(PANEL_CAPS)); // the panels this producer publishes
const arr = (v: unknown) => (Array.isArray(v) ? v : []);

export default function (pi: ExtensionAPI) {
	adoptEnv(); // DECKHAND_* out of process.env: no child process inherits them (lib/protocol.ts)
	const tasks = new Map<string, string[]>(); // run id -> task line per step, from this session's own subagent calls
	const taskAt = new Map<string, number>();
	const finishedAt = new Map<string, number>(); // run id -> when first seen finished, for runs without endedAt
	const data: Data = { runs: [], todos: [], shells: [], tasks, finishedAt };
	let view = todoView();
	let active = false; // session_start in a Deckhand pi tab, until session_shutdown
	let desk = false; // the bridge says Deckhand draws panels
	const yielded = new Set<string>(); // our panels another extension took over (a claim, or its own PANELS_EVENT with rows)
	let own: unknown; // the list we last emitted (to tell it from another producer's)
	let subTimer: NodeJS.Timeout | undefined;
	let stopRead: (() => void) | undefined;
	let again = false;
	let expiry: NodeJS.Timeout | undefined;

	function publish() {
		if (!active || !desk) return;
		try {
			scheduleExpiry();
			const list: Panel[] = deskPanels(data, Date.now()).filter((p) => OURS.has(p.panel) && !yielded.has(p.panel));
			if (!list.length) return;
			own = list;
			pi.events.emit(PANELS_EVENT, list);
		} catch {}
	}

	/** Publish again when the next finished run is due to leave its panel. */
	function scheduleExpiry() {
		clearTimeout(expiry);
		const at = nextHide(data, Date.now());
		expiry = at === undefined ? undefined : setTimeout(() => ((expiry = undefined), publish()), Math.min(at - Date.now(), 15 * 60_000) + 100);
	}

	pi.events.on(CAPS_CLAIM, (c) => {
		const claim = parseClaim(c);
		const panel = claim && PANEL_CAPS[claim.capability];
		if (!panel || yielded.has(panel)) return;
		// clear what we published of it (the bridge keeps it until replaced), then leave it
		if (active && desk) {
			try {
				const title = deskPanels(data, Date.now()).find((p) => p.panel === panel)?.title ?? panel;
				own = [{ panel, title, rows: [] }];
				pi.events.emit(PANELS_EVENT, own);
			} catch {}
		}
		yielded.add(panel);
	});
	pi.events.on(PANELS_EVENT, (list) => {
		if (list === own) return;
		for (const p of arr(list)) if (OURS.has(p?.panel) && Array.isArray(p.rows) && p.rows.length) yielded.add(p.panel);
	});
	pi.events.on(MODE_EVENT, (on) => {
		desk = on === true;
		publish();
	});
	const shellSeen = { ours: false };
	pi.events.on(SHELL_ROWS_EVENT, (v) => {
		const rows = shellRows(shellSeen, v);
		if (!rows) return;
		data.shells = rows;
		publish();
	});

	function readSubagents() {
		subTimer = undefined;
		if (stopRead) return void (again = true);
		const requestId = randomUUID();
		const finish = (reply?: unknown) => {
			off();
			clearTimeout(timeout);
			stopRead = undefined;
			const r = reply as { success?: boolean; data?: { asyncSnapshot?: { runs?: unknown } } } | undefined;
			if (r?.success) {
				data.runs = arr(r.data?.asyncSnapshot?.runs);
				trackFinished(finishedAt, data.runs, Date.now());
				// Forget tasks of runs gone from the snapshot (a minute's grace: a read may predate a launch).
				const live = new Set(data.runs.map((run: Run) => run?.id));
				for (const [id, at] of taskAt) if (!live.has(id) && Date.now() - at > 60_000) tasks.delete(id), taskAt.delete(id);
			}
			publish();
			if (again && active) {
				again = false;
				subagentsChanged();
			}
		};
		const off = pi.events.on(`subagents:rpc:v1:reply:${requestId}`, finish);
		const timeout = setTimeout(finish, 5000); // no pi-subagents, or it did not answer
		stopRead = finish;
		pi.events.emit("subagents:rpc:v1:request", { version: 1, requestId, method: "status" });
	}
	// Events come in bursts: one status read per 250 ms.
	const subagentsChanged = () => void (active && (subTimer ??= setTimeout(readSubagents, 250)));
	for (const name of SUBAGENT_EVENTS) pi.events.on(name, subagentsChanged);

	/**
	 * New todos. A `reset` (new session, /tree) starts a fresh view: todos already completed count as
	 * done in earlier runs and fold into one row; a "compact" reset keeps this run's ticks listed.
	 */
	function setTodos(s: TodoState, reset?: "start" | "compact") {
		if (reset) view = resumeTodos(s.tasks, s.nextId, reset === "compact" ? view.pending : undefined);
		else trackTodos(view, s.tasks, s.nextId);
		data.todos = s.tasks;
		data.hiddenTodos = view.hidden;
	}

	pi.on("session_start", (_e, ctx) => {
		if (ctx.mode !== "tui" || !inDesk()) return;
		active = true;
		try {
			setTodos(todosFromBranch(ctx.sessionManager.getBranch()), "start");
		} catch {}
		pi.events.emit(CAPS_QUERY, { from: "deckhand", capabilities: Object.keys(PANEL_CAPS) });
		subagentsChanged();
	});
	const replayTodos = (reset?: "start" | "compact") => (_e: unknown, ctx: ExtensionContext) => {
		if (!active) return;
		try {
			setTodos(todosFromBranch(ctx.sessionManager.getBranch()), reset);
		} catch {}
		publish();
	};
	pi.on("session_tree", replayTodos("start"));
	pi.on("session_compact", replayTodos("compact"));
	pi.on("turn_end", replayTodos()); // todo changes made through another tool (codemode) leave no todo tool_result
	pi.on("agent_start", () => {
		if (!active) return;
		hideCompleted(view); // todos completed in earlier runs stop being listed
		publish();
	});
	pi.on("tool_result", (e) => {
		if (!active) return;
		const t = e.toolName === "subagent" && !e.isError ? subagentTask(e.input, e.details) : undefined;
		if (t) {
			tasks.set(t[0], t[1]);
			taskAt.set(t[0], Date.now());
			subagentsChanged();
		}
		const d = e.details as { tasks?: unknown; nextId?: unknown } | undefined;
		if (e.toolName !== "todo" || e.isError || !Array.isArray(d?.tasks)) return;
		setTodos({ tasks: d.tasks, nextId: typeof d.nextId === "number" ? d.nextId : undefined });
		publish();
	});

	pi.on("session_shutdown", () => {
		if (!active) return;
		active = false;
		clearTimeout(subTimer);
		clearTimeout(expiry);
		stopRead?.();
	});
}
