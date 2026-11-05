// `kit:desk:mode` reaches a sidebar however late it gets ready. pi runs session_start handlers in
// load order, each awaited (test/pi-rules.ts); the bridge loads first (`-e`) and a terminal sidebar
// (pi-kit's) loads with the user's packages, and only listens once its own session_start has run.
// An extension in between that awaits I/O in its session_start (pi-computer-use does) let the
// bridge's handshake land first, and the sidebar missed the mode and drew its column next to
// Deckhand's panels. These load the bridge and a stand-in sidebar into the model of pi, against a
// fake Deckhand on a unix socket.
// node --test test/mode.test.ts (Node 22.18+ strips the types; never runs pi).
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { registerHooks } from "node:module";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { afterEach, test } from "node:test";
import * as protocol from "../lib/protocol.ts";
import { MODE_EVENT, PANELS_EVENT } from "../lib/protocol.ts";
import { piRules } from "./pi-rules.ts";

const TMP_ROOT = mkdtempSync(path.join(os.tmpdir(), "deckhand-test-"));
process.on("exit", () => rmSync(TMP_ROOT, { recursive: true, force: true }));

// pi-kit's sidebar (PI_KIT_DIR) imports pi-tui; nothing here draws, so names are enough
const stubs: Record<string, string> = {
	"@earendil-works/pi-tui":
		"export const truncateToWidth = (s) => s; export const visibleWidth = (s) => String(s).length; export const isViewportTUI = () => false;" +
		"export class HStack { constructor(c) { this.c = c; } } export class ScrollView { constructor(c) { this.c = c; } render() { return []; } invalidate() {} }",
};
registerHooks({ resolve: (spec, ctx, next) => (spec in stubs ? { url: `data:text/javascript,${encodeURIComponent(stubs[spec])}`, shortCircuit: true } : next(spec, ctx)) });

const KIT = process.env.PI_KIT_DIR ? path.join(process.env.PI_KIT_DIR, "extensions") : "";
const noKit = !KIT || !existsSync(path.join(KIT, "sidebar/index.ts")) ? "PI_KIT_DIR (a pi-kit checkout) not set" : false;
const MODE_QUERY = "kit:desk:mode?";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Runs `f` with only these DECKHAND_* variables set and Deckhand's in-memory copies cleared, then puts everything back. */
async function withEnv<T>(env: Record<string, string>, f: () => T | Promise<T>): Promise<T> {
	const ENV = ["DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CONTROL_TOKEN", "DECKHAND_SHOTS_DIR", "PI_DESK_SOCKET", "PI_DESK_TOKEN"];
	const saved = Object.fromEntries(ENV.map((k) => [k, process.env[k]]));
	const g = globalThis as any;
	const syms = [Symbol.for("deckhand.bridge.token"), Symbol.for("deckhand.env.DECKHAND_SOCKET"), Symbol.for("deckhand.env.DECKHAND_SHOTS_DIR"), Symbol.for("deckhand.token.DECKHAND_CONTROL_TOKEN")];
	const savedSyms = syms.map((s) => g[s]);
	for (const k of ENV) delete process.env[k];
	for (const s of syms) g[s] = undefined;
	Object.assign(process.env, env);
	try {
		return await f();
	} finally {
		for (const k of ENV) saved[k] === undefined ? delete process.env[k] : (process.env[k] = saved[k]);
		syms.forEach((s, i) => (g[s] = savedSyms[i]));
	}
}

/** A fake Deckhand: answers a pi tab's hello after `delay` ms (never, if `silent`) with the panels capability, and every other request ok. */
async function fakeDeckhand(opts: { delay?: number; silent?: boolean } = {}) {
	const dir = mkdtempSync(path.join(TMP_ROOT, "m-"));
	const sock = path.join(dir, "s");
	const hellos: string[] = [];
	const conns = new Set<net.Socket>();
	const server = net.createServer((c) => {
		conns.add(c);
		c.on("close", () => conns.delete(c));
		c.on("error", () => {});
		let buf = "";
		c.setEncoding("utf8");
		c.on("data", (d: string) => {
			buf += d;
			let nl: number;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const m = JSON.parse(buf.slice(0, nl));
				buf = buf.slice(nl + 1);
				const reply = (o: any) => !c.destroyed && c.write(JSON.stringify({ v: 1, type: "result", id: m.id, ...o }) + "\n");
				if (m.type === "hello") {
					hellos.push(m.token);
					if (!opts.silent) setTimeout(() => reply({ result: { ok: true, data: { tab_id: 4, reconnect_token: `r${hellos.length}`, capabilities: ["pi_tab", "panels", "state", "events"] } } }), opts.delay ?? 0);
				} else reply({ result: { ok: true } });
			}
		});
	});
	await new Promise<void>((r) => server.listen(sock, r));
	const close = () => {
		for (const c of conns) c.destroy();
		server.close();
	};
	return { sock, hellos, close };
}

/**
 * A terminal sidebar that gets ready the way pi-kit's does (extensions/sidebar/index.ts): it listens
 * for MODE_EVENT from load, ignores it until its own session_start has set its ui, and at
 * session_start draws its column unless the mode said panels. `order` records whether it heard a
 * mode before it was ready. (Whether pi-tui draws a frame between its session_start and the
 * bridge's repeat depends on later extensions, so nothing here asserts on frames.)
 */
function standInSidebar() {
	const s = { column: false, order: [] as string[] };
	let ui: unknown;
	let desk = false;
	const factory = (pi: any) => {
		pi.events.on(MODE_EVENT, (on: unknown) => {
			s.order.push(`mode:${on}`);
			if (!ui) return;
			desk = on === true;
			s.column = !desk;
		});
		pi.on("session_start", (_e: unknown, ctx: any) => {
			if (ctx.mode !== "tui") return;
			s.order.push("ready");
			ui = ctx.ui;
			s.column = !desk;
		});
		pi.on("session_shutdown", () => void (ui = undefined));
	};
	return { s, factory };
}

/** An extension whose session_start awaits I/O (pi-computer-use's setup does): the event loop runs meanwhile. */
const slowStart = (ms: number) => (pi: any) => pi.on("session_start", () => sleep(ms));

const live: ReturnType<typeof piRules>[] = []; // shut down after each test, also when it failed
afterEach(async () => {
	for (const pi of live.splice(0)) await pi.fire("session_shutdown");
});

/** One pi runtime: the bridge (-e, first), then `others` (the user's packages), then session_start and resources_discover. */
async function runtime(others: [string, (pi: any) => unknown][], reason = "startup") {
	const pi = piRules();
	live.push(pi);
	Object.assign(pi.ctx.sessionManager, { getSessionId: () => "s1", getSessionFile: () => "" });
	await pi.load("/deckhand/pi/extensions/bridge", (await import(`../extensions/bridge/index.ts?${Math.random()}`)).default);
	for (const [p, f] of others) await pi.load(p, f);
	const t0 = Date.now();
	const r = await pi.start(reason);
	assert.deepEqual(r, { exitCode: 0, errors: [] });
	return { pi, startMs: Date.now() - t0 };
}

test("mode: MODE_QUERY is the query event a late producer asks with", () => {
	assert.equal((protocol as Record<string, unknown>).MODE_QUERY, MODE_QUERY);
});

test("mode: a sidebar loaded after an extension that awaits I/O in session_start still hears that Deckhand draws panels (hidden once every session_start has run)", async () => {
	const dh = await fakeDeckhand();
	try {
		await withEnv({ DECKHAND_SOCKET: dh.sock, DECKHAND_TOKEN: "t" }, async () => {
			const side = standInSidebar();
			await runtime([["/user/computer-use", slowStart(150)], ["/user/pi-kit/sidebar", side.factory]]);
			assert.equal(side.s.column, false, "the column is hidden: Deckhand draws the panels");
		});
	} finally {
		dh.close();
	}
});

test("mode: with nothing slow in between and a Deckhand that answers a little later, the sidebar is hidden once every session_start has run", async () => {
	const dh = await fakeDeckhand({ delay: 40 }); // Deckhand answers on its next frame or so
	try {
		await withEnv({ DECKHAND_SOCKET: dh.sock, DECKHAND_TOKEN: "t" }, async () => {
			const side = standInSidebar();
			await runtime([["/user/pi-kit/sidebar", side.factory]]);
			assert.equal(side.s.column, false);
		});
	} finally {
		dh.close();
	}
});

test("mode: after a reload or session switch (a new runtime, the reconnect token), the new sidebar hears the mode too", async () => {
	const dh = await fakeDeckhand();
	try {
		await withEnv({ DECKHAND_SOCKET: dh.sock, DECKHAND_TOKEN: "t" }, async () => {
			const first = await runtime([["/user/computer-use", slowStart(80)], ["/user/pi-kit/sidebar", standInSidebar().factory]]);
			await first.pi.fire("session_shutdown");
			for (const reason of ["reload", "new"]) {
				const side = standInSidebar();
				const next = await runtime([["/user/computer-use", slowStart(80)], ["/user/pi-kit/sidebar", side.factory]], reason);
				assert.equal(side.s.column, false, reason);
				await next.pi.fire("session_shutdown");
			}
			assert.equal(dh.hellos[0], "t");
			assert.deepEqual(dh.hellos.slice(1), ["r1", "r2"], "each later runtime said hello with the reconnect token");
		});
	} finally {
		dh.close();
	}
});

test("mode: a producer that gets ready later asks with MODE_QUERY and hears the current mode", async () => {
	const dh = await fakeDeckhand();
	try {
		await withEnv({ DECKHAND_SOCKET: dh.sock, DECKHAND_TOKEN: "t" }, async () => {
			const { pi } = await runtime([]);
			const heard: unknown[] = [];
			pi.events.on(MODE_EVENT, (on: unknown) => heard.push(on));
			pi.events.emit(MODE_QUERY, undefined);
			assert.deepEqual(heard, [true]);
			await pi.fire("session_shutdown");
			pi.events.emit(MODE_QUERY, undefined);
			assert.deepEqual(heard, [true], "a closed bridge answers nothing");
		});
	} finally {
		dh.close();
	}
});

test("mode: a listener that asks again from inside its MODE_EVENT handler gets one answer per outer query, not a recursion", async () => {
	const dh = await fakeDeckhand();
	try {
		await withEnv({ DECKHAND_SOCKET: dh.sock, DECKHAND_TOKEN: "t" }, async () => {
			const { pi } = await runtime([]);
			let heard = 0;
			pi.events.on(MODE_EVENT, () => {
				heard++;
				if (heard < 10_000) pi.events.emit(MODE_QUERY, undefined); // a naive producer: asks whenever it hears
			});
			pi.events.emit(MODE_QUERY, undefined);
			assert.equal(heard, 1, "the nested query is not answered");
			pi.events.emit(MODE_QUERY, undefined);
			assert.equal(heard, 2, "a later query is answered again");
		});
	} finally {
		dh.close();
	}
});

test("mode: a Deckhand that never answers the hello holds pi's start back only up to the bridge's cap; with no Deckhand at all, the mode is false before later extensions start", async () => {
	const dh = await fakeDeckhand({ silent: true });
	try {
		await withEnv({ DECKHAND_SOCKET: dh.sock, DECKHAND_TOKEN: "t" }, async () => {
			const side = standInSidebar();
			const { startMs } = await runtime([["/user/pi-kit/sidebar", side.factory]]);
			assert.ok(startMs < 4500, `start took ${startMs} ms (the cap is 1 s, well under the 5 s hello timeout)`);
			assert.equal(side.s.column, true, "no answer yet: the sidebar draws (the bridge's later handshake or close says otherwise)");
		});
	} finally {
		dh.close();
	}
	await withEnv({ DECKHAND_SOCKET: path.join(TMP_ROOT, "none.sock"), DECKHAND_TOKEN: "t" }, async () => {
		const side = standInSidebar();
		await runtime([["/user/pi-kit/sidebar", side.factory]]);
		assert.deepEqual(side.s.order.slice(0, 2), ["mode:false", "ready"], "the failed connection said false before the sidebar started (no wait for the cap)");
		assert.equal(side.s.column, true, "no Deckhand: the sidebar draws as usual");
	});
});

test("mode: outside Deckhand the bridge says nothing", async () => {
	await withEnv({}, async () => {
		const side = standInSidebar();
		const { pi } = await runtime([["/user/pi-kit/sidebar", side.factory]]);
		assert.deepEqual(pi.emitted.filter(([e]) => e === MODE_EVENT), []);
		pi.events.emit(MODE_QUERY, undefined);
		assert.deepEqual(pi.emitted.filter(([e]) => e === MODE_EVENT), [], "nothing to answer");
		assert.deepEqual(side.s.order, ["ready"]);
		assert.equal(side.s.column, true);
	});
});

test("mode (PI_KIT_DIR): pi-kit's own sidebar, after a slow session_start, hands its sections to Deckhand as panels instead of drawing", { skip: noKit }, async () => {
	const dh = await fakeDeckhand();
	try {
		await withEnv({ DECKHAND_SOCKET: dh.sock, DECKHAND_TOKEN: "t" }, async () => {
			const file = path.join(KIT, "sidebar/index.ts");
			const sidebar = (await import(file)).default;
			const { pi } = await runtime([["/user/computer-use", slowStart(150)], [file, sidebar]]);
			const panels = pi.emitted.filter(([e]) => e === PANELS_EVENT);
			assert.ok(panels.length > 0, "pi-kit's sidebar is in desk mode: it publishes kit:desk:panels");
			assert.deepEqual(panels.at(-1)![1].map((p: any) => p.panel), ["subagents", "shells", "todos"]);
		});
	} finally {
		dh.close();
	}
});
