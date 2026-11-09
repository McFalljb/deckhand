/**
 * Bridge to Deckhand (the native app that runs pi in a terminal tab): the pi tab's control plane,
 * per Deckhand's docs/PROTOCOL.md §4. Inert unless DECKHAND_SOCKET and DECKHAND_TOKEN are set and pi
 * runs in the interactive TUI.
 *
 * - Connects to the socket, sends `hello`, reconnects with backoff if Deckhand goes away. The env
 *   token is single-use: Deckhand revokes it on the first hello and returns a reconnect token, kept
 *   in memory (see deskToken) for every later hello, also after a reload or session switch.
 * - Reports `pi.session` (id, file, cwd) after each handshake; a session switch or reload starts a
 *   new extension runtime, which connects again and reports the new session.
 * - Reports `pi.status {agent, waiting, question, blockers}` when it changes (see status() in protocol.ts).
 * - Tells other extensions its tab id (`deckhand:tab`, after each handshake).
 * - If the hello result's `capabilities` include `panels`, publishes the panels producers hand it
 *   on `kit:desk:panels` (extensions/panels, pi-kit's sidebar or any other; merged by panel name)
 *   as `panel.set`, or `panel.remove` once a panel empties, at most once a second and only when
 *   they changed. `kit:desk:mode` tells producers whether Deckhand draws panels (after each
 *   handshake; false while the bridge has never connected), and again once every extension's
 *   session_start has run (`resources_discover`) and on `kit:desk:mode?`: a sidebar that only
 *   listens once its own session_start ran (pi-kit's, loaded after us) missed the first one when an
 *   extension in between awaited I/O. session_start waits for the first handshake (at most
 *   MODE_WAIT_MS), so the mode is known before later extensions start, and such a sidebar is hidden
 *   by the time every session_start has run (it may still draw one frame if a later extension yields).
 * - Answers `pi.prompt` (a user message, with `images` if given; follow-up while a run is going),
 *   `pi.wait_idle` (when pi is idle with nothing queued and no blockers, or a timeout) and
 *   `pi.reload` (refused unless that same idle holds: a reload kills the kit's background shells;
 *   the result comes after it).
 * - Holds Deckhand's pending comments (`pi.attach` replaces them, `pi.attach_clear` drops them, and
 *   so does a dropped connection) and adds them to the next message the user types in pi (the
 *   `input` hook: text after the user's, images after theirs; not a `/` command), then tells
 *   Deckhand `pi.attached {attachment_id}` so it clears them: at once for a message queued while pi
 *   works, once it starts (`message_start`) for one sent while idle.
 *   Deckhand sends them again (or clears them) after every handshake, so a reload loses nothing.
 * - Sends Deckhand commands for other extensions over this connection (caller `panel`: the pi
 *   tab's own session's browser tabs; extensions/browser; only its command types,
 *   browserRefusal): `deckhand:command`
 *   {requestId, command, timeoutMs?} on pi.events, answered on `deckhand:command:reply:<requestId>`
 *   with {result} (a long command's `finished` result) or {error}; `deckhand:command:cancel`
 *   {requestId} stops waiting and sends Deckhand a `cancel` line for a long command's request id
 *   (once that id is known), as does a call's timeout; its late `finished` is dropped. Not connected: an error at once.
 *
 * Never throws into pi: socket and protocol errors end the connection, which is retried.
 */

import { randomUUID } from "node:crypto";
import net from "node:net";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type Panel, type Run, type ShellRow, SUBAGENT_EVENTS } from "../../lib/rows.ts";
import { Attacher, backoff, browserRefusal, busyReasons, cancelLine, COMMAND_EVENT, CommandCalls, type CommandOutcome, adoptEnv, deskSocket, deskToken, HelloFlow, line, mergePanels, MODE_EVENT, MODE_QUERY, PANELS_EVENT, parse, parseAttach, promptContent, promptRefusal, RELOAD_COMMAND, reply, runOutcome, SHELL_ROWS_EVENT, shellRows, status, TAB_EVENT, wireImages } from "../../lib/protocol.ts";

export { inDesk } from "../../lib/protocol.ts";

const HELLO_TIMEOUT_MS = 5000;
const IDLE_SETTLE_MS = 250; // wait_idle needs idle to hold this long (a shell's exit notice starts a run just after its rows clear)
const PANEL_EVERY_MS = 1000; // panel updates are coalesced to one per this
const COMMAND_TIMEOUT_MS = 60_000; // a deckhand:command without timeoutMs
const MODE_WAIT_MS = 1000; // session_start waits this long at most for the first handshake (the mode)
const arr = (v: unknown) => (Array.isArray(v) ? v : []);

export default function (pi: ExtensionAPI) {
	adoptEnv(); // DECKHAND_* out of process.env: no child process inherits them (lib/protocol.ts)
	let ctx: ExtensionContext | undefined; // set while active
	let sock: net.Socket | undefined;
	let ready = false; // handshake done on the current connection
	let panelsOn = false; // the current connection's Deckhand draws panels
	let connected = false; // a handshake has succeeded in this runtime
	let mode: boolean | undefined; // the last MODE_EVENT said, said again to producers that got ready later
	let modeKnown: (() => void) | undefined; // ends session_start's wait for the first handshake
	let closed = false;
	let attempt = 0;
	let retry: NodeJS.Timeout | undefined;
	let seq = 0;
	let sent = ""; // the last pi.status sent on this connection
	let shells: ShellRow[] = [];
	let runs: Run[] = [];
	let dialogs = 0; // open pi dialogs (they can overlap)
	let compacting = false; // a manual /compact is running
	let error = false;
	let question = false;
	let subTimer: NodeJS.Timeout | undefined;
	let reloadId: unknown; // a pi.reload waiting for its result
	const panels = new Map<string, Panel>(); // the latest of each panel, from any producer (PANELS_EVENT)
	const panelSent = new Map<string, string>(); // panel -> the last panel.set/remove sent on this connection
	let panelTimer: NodeJS.Timeout | undefined;
	let idleTimer: NodeJS.Timeout | undefined;
	const waiters = new Map<unknown, NodeJS.Timeout | undefined>(); // pi.wait_idle id -> its timeout
	const attach = new Attacher(); // Deckhand's pending comments (pi.attach), for the next typed message
	const acks: (string | number)[] = []; // pi.attached not sent yet (no connection when the message started)
	// deckhand:command calls in flight on this connection; a cancelled one is stopped in Deckhand too
	const calls = new CommandCalls((rid) => {
		if (sock && ready && !sock.destroyed && !closed) sock.write(cancelLine(`b${++seq}`, rid));
	});
	const callIds = new Map<string, string>(); // requestId -> our line id

	const send = (msg: Record<string, unknown>) => {
		if (sock && ready && !sock.destroyed) sock.write(line({ id: `b${++seq}`, ...msg }));
	};
	const sayMode = (on: boolean) => {
		mode = on;
		modeKnown?.();
		pi.events.emit(MODE_EVENT, on);
	};
	const answer = (id: unknown, result: { ok: boolean; error?: string }) => {
		if (sock && !sock.destroyed) sock.write(reply(id, result));
	};

	function current() {
		return status({ idle: ctx!.isIdle(), error, dialogs, question, shells, runs });
	}
	const notIdle = () => busyReasons(current(), ctx!.hasPendingMessages());

	/** Send pi.status if it changed; answer wait_idle requests once pi is idle. */
	function update() {
		if (!ctx || closed) return;
		try {
			const s = JSON.stringify(current());
			if (ready && s !== sent) {
				sent = s;
				send({ type: "pi.status", ...JSON.parse(s) });
			}
			if (waiters.size && !notIdle().length) idleTimer ??= setTimeout(answerIdle, IDLE_SETTLE_MS);
		} catch {}
	}
	function answerIdle() {
		idleTimer = undefined;
		try {
			if (!ctx || closed || notIdle().length) return; // the next update() checks again
			for (const [id, t] of waiters) clearTimeout(t), answer(id, { ok: true });
			waiters.clear();
		} catch {}
	}

	function flushPanels() {
		panelTimer = undefined;
		if (!ready || closed || !panelsOn) return;
		for (const p of panels.values()) {
			const msg = p.rows.length ? { type: "panel.set", panel: p.panel, title: p.title, rows: p.rows } : { type: "panel.remove", panel: p.panel };
			const key = JSON.stringify(msg);
			if (panelSent.get(p.panel) === key) continue;
			panelSent.set(p.panel, key);
			send(msg);
		}
	}
	const panelsChanged = () => void (ready && panelsOn && !closed && (panelTimer ??= setTimeout(flushPanels, PANEL_EVERY_MS)));

	function flushAcks() {
		while (acks.length && ready && sock && !sock.destroyed) send({ type: "pi.attached", attachment_id: acks.shift() });
	}

	function sendSession() {
		const sm = ctx!.sessionManager;
		send({ type: "pi.session", pi_session_id: sm.getSessionId(), session_file: sm.getSessionFile() ?? "", cwd: ctx!.cwd });
	}

	function handle(m: Record<string, any>) {
		if (m.type === "result") return void calls.onResult(m); // our commands' (the rest: pi.session, pi.status…)
		if (m.type === "event" && m.event === "finished") return void calls.onFinished(m);
		if (m.id === undefined) return; // other events: none expected
		if (m.type === "pi.prompt") {
			if (typeof m.text !== "string" || !m.text.trim()) return answer(m.id, { ok: false, error: "text is required" });
			const images = wireImages(m.images);
			if (typeof images === "string") return answer(m.id, { ok: false, error: images });
			const refused = promptRefusal({ dialogs, compacting });
			if (refused) return answer(m.id, { ok: false, error: refused });
			pi.sendUserMessage(promptContent(m.text, images ?? []), ctx!.isIdle() ? undefined : { deliverAs: "followUp" });
			return answer(m.id, { ok: true });
		}
		if (m.type === "pi.attach") {
			const a = parseAttach(m);
			if (typeof a === "string") return answer(m.id, { ok: false, error: a });
			attach.set(a);
			return answer(m.id, { ok: true });
		}
		if (m.type === "pi.attach_clear") {
			attach.clear();
			return answer(m.id, { ok: true });
		}
		if (m.type === "pi.wait_idle") {
			const ms = Number(m.timeout_ms);
			const t = ms > 0 ? setTimeout(() => waiters.delete(m.id) && answer(m.id, { ok: false, error: "timeout" }), ms) : undefined;
			waiters.set(m.id, t);
			return update();
		}
		if (m.type === "pi.reload") {
			const why = notIdle();
			if (why.length) return answer(m.id, { ok: false, error: `not idle: ${why.join("; ")}` });
			if (reloadId !== undefined) return answer(m.id, { ok: false, error: "a reload is already running" });
			reloadId = m.id;
			// Reload is a command-context operation: run it through our command.
			pi.sendUserMessage(`/${RELOAD_COMMAND}`, { expandPromptTemplates: true });
			return;
		}
		answer(m.id, { ok: false, error: `unknown type ${String(m.type)}` });
	}

	function connect() {
		retry = undefined;
		if (closed) return;
		const s = net.createConnection(deskSocket()!);
		sock = s;
		const hello = new HelloFlow("DECKHAND_TOKEN", `b${++seq}`, deskToken()!);
		let buf = "";
		const helloTimer = setTimeout(() => s.destroy(), HELLO_TIMEOUT_MS);
		s.setEncoding("utf8");
		s.on("connect", () => s.write(hello.first));
		s.on("data", (chunk: string) => {
			buf += chunk;
			let nl: number;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const m = parse(buf.slice(0, nl));
				buf = buf.slice(nl + 1);
				if (!m) continue;
				// Deckhand revoked the env token on this hello: the flow keeps its reconnect token even if
				// this runtime closed meanwhile (reload, session switch), or the next runtime cannot connect.
				const step = ready ? undefined : hello.onLine(m);
				if (sock !== s || closed) continue;
				try {
					if (!ready) {
						if (!step) continue;
						if ("send" in step) {
							s.write(step.send); // the challenge hello's proof: Deckhand proved the token first
							continue;
						}
						clearTimeout(helloTimer);
						if ("fail" in step) return void s.destroy(); // wrong token or version, or not our Deckhand: retried with backoff
						const data = step.ok.data;
						panelsOn = Array.isArray(data?.capabilities) && data.capabilities.includes("panels");
						sayMode(panelsOn);
						pi.events.emit(TAB_EVENT, data?.tab_id); // Home's desk extension never targets its own tab
						ready = connected = true;
						attempt = 0;
						sent = "";
						panelSent.clear();
						flushAcks(); // before pi.session: Deckhand clears those comments before it sends the rest again
						sendSession();
						update();
						flushPanels();
					} else handle(m);
				} catch {}
			}
		});
		s.on("error", () => {}); // "close" follows
		s.on("close", () => {
			clearTimeout(helloTimer);
			if (sock !== s) return;
			sock = undefined;
			ready = false;
			for (const t of waiters.values()) clearTimeout(t); // their connection is gone
			waiters.clear();
			calls.failAll("the Deckhand connection closed before the result");
			reloadId = undefined; // a reload still running answers nobody
			// Deckhand may clear or change the comments while we are away and cannot say so: after the
			// handshake it sends them again, or pi.attach_clear
			attach.clear();
			if (!connected && !closed) sayMode(false); // no Deckhand: a sidebar draws as usual
			if (!closed) retry = setTimeout(connect, backoff(attempt++));
		});
	}

	function readSubagents() {
		subTimer = undefined;
		const requestId = randomUUID();
		const finish = (r?: any) => {
			off();
			clearTimeout(timeout);
			if (r?.success) runs = arr(r.data?.asyncSnapshot?.runs);
			update();
		};
		const off = pi.events.on(`subagents:rpc:v1:reply:${requestId}`, finish);
		const timeout = setTimeout(finish, 5000); // no pi-subagents, or it did not answer
		pi.events.emit("subagents:rpc:v1:request", { version: 1, requestId, method: "status" });
	}
	const subagentsChanged = () => void (ctx && !closed && (subTimer ??= setTimeout(readSubagents, 250)));
	for (const name of SUBAGENT_EVENTS) pi.events.on(name, subagentsChanged);
	pi.events.on(PANELS_EVENT, (p) => {
		mergePanels(panels, p);
		panelsChanged();
	});
	const shellSeen = { ours: false }; // pi-kit's shell's empty rows next to ours do not clear the blockers
	pi.events.on(SHELL_ROWS_EVENT, (v) => {
		const rows = shellRows(shellSeen, v);
		if (!rows) return;
		shells = rows;
		update();
	});

	// Other extensions' Deckhand commands (desk-browser), over this connection.
	pi.events.on(COMMAND_EVENT, (req: any) => {
		const requestId = String(req?.requestId ?? "");
		const answer = (o: CommandOutcome) => pi.events.emit(`${COMMAND_EVENT}:reply:${requestId}`, o);
		if (!requestId) return answer({ error: "a requestId is required" });
		const why = browserRefusal(req?.command);
		if (why) return answer({ error: why });
		if (!sock || !ready || sock.destroyed || closed) return answer({ error: "Not connected to Deckhand (it reconnects on its own; try again shortly)." });
		const id = `b${++seq}`;
		const ms = Number(req.timeoutMs) > 0 ? Number(req.timeoutMs) : COMMAND_TIMEOUT_MS;
		const timer = setTimeout(() => calls.cancel(id, { error: `Deckhand did not answer within ${Math.round(ms / 1000)}s` }), ms);
		callIds.set(requestId, id);
		calls.start(id, (o) => {
			clearTimeout(timer);
			callIds.delete(requestId);
			answer(o);
		});
		sock.write(line({ id, type: "command", command: req.command }));
	});
	pi.events.on(`${COMMAND_EVENT}:cancel`, (req: any) => {
		const id = callIds.get(String(req?.requestId ?? ""));
		if (id) calls.cancel(id);
	});

	pi.registerCommand(RELOAD_COMMAND, {
		description: "Reload pi for Deckhand (Deckhand's pi.reload uses it)",
		handler: async (_args, c) => {
			const id = reloadId;
			let result = { ok: true } as { ok: boolean; error?: string };
			try {
				await c.reload();
			} catch (e) {
				result = { ok: false, error: `reload failed: ${(e as Error)?.message ?? e}` };
			}
			// This runtime is gone now; only its socket is left, kept open for this result.
			if (id !== undefined) answer(id, result);
			reloadId = undefined;
			if (closed) sock?.end();
		},
	});

	pi.on("session_start", async (_e, c) => {
		if (c.mode !== "tui" || !deskSocket() || !deskToken(true)) return;
		ctx = c;
		// The extensions after us start once the first handshake says the mode (or it fails, or
		// MODE_WAIT_MS): the repeat on resources_discover then reaches a sidebar among them.
		const known = new Promise<void>((r) => (modeKnown = r));
		const wait = setTimeout(() => modeKnown?.(), MODE_WAIT_MS);
		connect();
		subagentsChanged();
		await known;
		clearTimeout(wait);
		modeKnown = undefined;
	});
	// Every session_start handler has run now (pi emits this after them, on every session start):
	// say the mode again for producers that only listen once their own session_start ran.
	// The event bus is synchronous: a listener that asks again from its MODE_EVENT handler is not
	// answered (one answer per outer query, no recursion).
	let answering = false;
	const sayModeAgain = () => {
		if (answering || !ctx || closed || mode === undefined) return;
		answering = true;
		try {
			pi.events.emit(MODE_EVENT, mode);
		} finally {
			answering = false;
		}
	};
	pi.on("resources_discover", () => sayModeAgain());
	pi.events.on(MODE_QUERY, sayModeAgain);
	// The user's next typed message takes Deckhand's pending comments; pi.attached tells Deckhand to
	// clear them (Attacher: at once if queued, else when the message starts).
	pi.on("input", (e) => {
		const out = attach.input(e);
		if (!out) return { action: "continue" };
		const { ack, ...transform } = out;
		if (ack !== undefined) acks.push(ack), flushAcks(); // queued: pi has it
		return { action: "transform", ...transform };
	});
	pi.on("message_start", (e) => {
		const ids = attach.started(e.message as { role?: string; content?: unknown });
		if (!ids.length) return;
		acks.push(...ids);
		flushAcks();
	});
	pi.on("ui_prompt_start", () => {
		dialogs++;
		update();
	});
	pi.on("ui_prompt_end", () => {
		dialogs = Math.max(0, dialogs - 1);
		update();
	});
	pi.on("agent_start", () => {
		error = question = false;
		update();
	});
	pi.on("agent_end", (e) => {
		({ error, question } = runOutcome(e.messages));
		update();
	});
	pi.on("agent_settled", () => update());
	// Compaction outside a run (/compact) also makes pi busy; isIdle() flips around these events.
	const compaction = (start: boolean) => (e: { reason: string }) => {
		if (e.reason === "manual") compacting = start; // automatic compaction runs inside a run: prompts queue
		setTimeout(update, 0);
	};
	pi.on("session_before_compact", compaction(true));
	pi.on("session_compact", compaction(false));
	pi.on("session_compact_failed", compaction(false));

	pi.on("session_shutdown", () => {
		if (closed || !ctx) return;
		closed = true;
		modeKnown?.();
		clearTimeout(retry);
		clearTimeout(subTimer);
		clearTimeout(panelTimer);
		clearTimeout(idleTimer);
		for (const t of waiters.values()) clearTimeout(t);
		waiters.clear();
		if (reloadId === undefined) sock?.end(); // else the reload command answers, then closes it
		ctx = undefined;
	});
}
