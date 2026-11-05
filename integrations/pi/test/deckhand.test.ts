// What the bundled copy adds to pi-kit's desk extensions: the DECKHAND_* namespace (so an installed
// pi-kit's desk extensions stay inert in Deckhand), event names of its own for its internal routes,
// panels merged by name from several producers, the capability claims, and its variables kept out of
// every child process's environment.
// node --test test/*.test.ts (Node 22.18+ strips the types).
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import * as claims from "../lib/claims.ts";
import { CAPS_CLAIM, CAPS_QUERY, PANEL_CAPS, parseClaim } from "../lib/claims.ts";
import { COMMAND_EVENT, CONTROL_EVENT, CONTROL_READY, deckhandEnv, deskSocket, deskToken, envToken, inDesk, mergePanels, MODE_EVENT, PANELS_EVENT, RELOAD_COMMAND, TAB_EVENT } from "../lib/protocol.ts";

const ENV = ["DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CONTROL_TOKEN", "DECKHAND_SHOTS_DIR", "PI_DESK_SOCKET", "PI_DESK_TOKEN", "PI_DESK_CONTROL_TOKEN", "PI_KIT_READONLY"] as const;

/** Runs `f` with exactly `env` set among ENV (the rest unset), then puts everything back. */
async function withEnv<T>(env: Partial<Record<(typeof ENV)[number], string>>, f: () => T | Promise<T>): Promise<T> {
	const saved = Object.fromEntries(ENV.map((k) => [k, process.env[k]]));
	const g = globalThis as any;
	const syms = [Symbol.for("deckhand.bridge.token"), Symbol.for("deckhand.token.DECKHAND_CONTROL_TOKEN"), Symbol.for("deckhand.env.DECKHAND_SOCKET"), Symbol.for("deckhand.env.DECKHAND_SHOTS_DIR")];
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

/** A fake pi: what an extension registers, its hooks and the event bus (synchronous, as pi's). */
function fakePi(others: { name: string; path: string }[] = []) {
	const mod = import("node:module").then((m: any) => {
		if (!(globalThis as any).__kitTypeboxStub) {
			(globalThis as any).__kitTypeboxStub = true;
			const stub = "data:text/javascript," + encodeURIComponent("export const Type = new Proxy({}, { get: () => (...a) => ({}) });");
			m.registerHooks({ resolve: (spec: string, ctx: any, next: any) => (spec === "typebox" ? { url: stub, shortCircuit: true } : next(spec, ctx)) });
		}
	});
	const tools = new Map<string, any>();
	const commands = new Map<string, any>();
	const handlers = new Map<string, any[]>();
	const listeners = new Map<string, ((x: any) => void)[]>();
	const emitted: [string, any][] = [];
	const pi: any = {
		registerTool: (t: any) => tools.set(t.name, t),
		registerCommand: (n: string, c: any) => commands.set(n, c),
		getAllTools: () => [...others.map((o) => ({ name: o.name, sourceInfo: { path: o.path } })), ...[...tools.keys()].map((name) => ({ name, sourceInfo: { path: "/deckhand/pi" } }))],
		on: (e: string, f: any) => handlers.set(e, [...(handlers.get(e) ?? []), f]),
		sendUserMessage: () => {},
		events: {
			on: (e: string, f: any) => (listeners.set(e, [...(listeners.get(e) ?? []), f]), () => listeners.set(e, (listeners.get(e) ?? []).filter((g) => g !== f))),
			emit: (e: string, x: any) => {
				emitted.push([e, x]);
				for (const f of listeners.get(e) ?? []) f(x);
			},
		},
	};
	const ctx = (over: Record<string, any> = {}) => ({ mode: "tui", cwd: "/w", isIdle: () => true, hasPendingMessages: () => false, sessionManager: { getBranch: () => [], getSessionId: () => "s", getSessionFile: () => "" }, ...over });
	const fire = async (e: string, ev: any = {}, c: any = ctx()) => {
		for (const f of handlers.get(e) ?? []) await f(ev, c);
	};
	return { pi, tools, commands, handlers, listeners, emitted, fire, ctx, ready: mod };
}

test("namespace: the bundled copy reads DECKHAND_* only; pi-kit's PI_DESK_* bridge variables and token symbol mean nothing to it", async () => {
	await withEnv({ PI_DESK_SOCKET: "/tmp/x.sock", PI_DESK_TOKEN: "old" }, () => {
		assert.equal(inDesk(), false, "PI_DESK_* alone: not in Deckhand");
		assert.equal(deskToken(), undefined);
		(globalThis as any)[Symbol.for("pi-kit.desk-bridge.token")] = "pi-kit's reconnect token";
		assert.equal(deskToken(), undefined, "pi-kit's in-memory token is not ours");
		(globalThis as any)[Symbol.for("pi-kit.desk-bridge.token")] = undefined;
	});
	await withEnv({ DECKHAND_SOCKET: "/tmp/x.sock", DECKHAND_TOKEN: "new" }, () => {
		assert.equal(inDesk(), true);
		assert.equal(deskToken(true), "new");
		assert.equal(process.env.DECKHAND_TOKEN, undefined, "taken out of the environment");
		assert.equal((globalThis as any)[Symbol.for("deckhand.bridge.token")], "new", "kept under Deckhand's own symbol");
	});
});

test("namespace: internal routes have Deckhand's own event names (an inert pi-kit bridge would answer kit:desk:command); the panel contract keeps pi-kit's", () => {
	assert.equal(COMMAND_EVENT, "deckhand:command");
	assert.equal(CONTROL_EVENT, "deckhand:control:command");
	assert.equal(CONTROL_READY, "deckhand:control");
	assert.equal(TAB_EVENT, "deckhand:tab");
	assert.equal(RELOAD_COMMAND, "deckhand-reload", "pi-kit's desk-bridge registers /desk-reload whether or not it is active");
	assert.equal(PANELS_EVENT, "kit:desk:panels", "pi-kit's sidebar (and any producer) hands panels over with this");
	assert.equal(MODE_EVENT, "kit:desk:mode", "pi-kit's sidebar stops drawing its column on this");
});

test("namespace: with only PI_DESK_* set, the bundled extensions register no tools and never connect", async () => {
	for (const ext of ["browser", "desk", "bridge", "panels"]) {
		const f = fakePi();
		await f.ready;
		await withEnv({ PI_DESK_SOCKET: "/nonexistent/x.sock", PI_DESK_TOKEN: "t", PI_DESK_CONTROL_TOKEN: "c" }, async () => {
			const { default: load } = await import(`../extensions/${ext}/index.ts`);
			load(f.pi);
			await f.fire("session_start");
			assert.equal(f.tools.size, 0, `${ext}: no tools`);
			assert.deepEqual(f.emitted.filter(([e]) => e !== COMMAND_EVENT), [], `${ext}: no events`);
			await f.fire("session_shutdown");
		});
	}
});

test("namespace: with DECKHAND_* set, a pi tab gets the browser and app tools, Home the desk tools", async () => {
	const tab = fakePi();
	await tab.ready;
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, async () => {
		const { default: browser } = await import("../extensions/browser/index.ts");
		browser(tab.pi);
		await tab.fire("session_start");
	});
	for (const name of ["browser_tabs", "browser_click", "app_tabs", "app_open", "app_call"]) assert.ok(tab.tools.has(name), name);
	const home = fakePi();
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t", DECKHAND_CONTROL_TOKEN: "c" }, async () => {
		const { default: desk } = await import("../extensions/desk/index.ts");
		desk(home.pi);
		await home.fire("session_start");
		assert.equal(process.env.DECKHAND_CONTROL_TOKEN, undefined, "the control token leaves the environment");
		await home.fire("session_shutdown");
	});
	for (const name of ["desk_state", "desk_run", "desk_prompt", "desk_wait", "desk_watch", "desk_events", "app_call"]) assert.ok(home.tools.has(name), name);
});

test("bridge: panels from several producers merge by name; an empty one is kept (it removes the panel)", () => {
	const m = new Map();
	mergePanels(m, [{ panel: "subagents", title: "Subagents", rows: [{ text: "a" }] }, { panel: "todos", title: "Todos", rows: [] }]);
	mergePanels(m, [{ panel: "shells", title: "Shells", rows: [{ text: "s" }] }]);
	assert.deepEqual([...m.keys()], ["subagents", "todos", "shells"]);
	mergePanels(m, [{ panel: "todos", title: "Todos", rows: [{ text: "t" }] }, null, { panel: "", rows: [] }, { panel: "x", rows: "no" }]);
	assert.deepEqual(m.get("todos").rows, [{ text: "t" }]);
	assert.equal(m.size, 3, "bad entries are skipped");
});

test("claims: a claim names a capability and an owner other than Deckhand", () => {
	assert.equal(CAPS_QUERY, "deckhand:capabilities?");
	assert.equal(CAPS_CLAIM, "deckhand:capabilities");
	assert.deepEqual(PANEL_CAPS, { "panels:todos": "todos", "panels:subagents": "subagents", "panels:shells": "shells" });
	assert.deepEqual(parseClaim({ capability: "panels:todos", owner: "my-todo", version: "1.2.0" }), { capability: "panels:todos", owner: "my-todo", version: "1.2.0" });
	assert.deepEqual(parseClaim({ capability: "panels:subagents", owner: "x" }), { capability: "panels:subagents", owner: "x", version: "" });
	for (const bad of [undefined, null, "panels:todos", {}, { capability: "panels:todos" }, { capability: "", owner: "x" }, { capability: "panels:todos", owner: "deckhand" }, { capability: 3, owner: "x" }])
		assert.equal(parseClaim(bad), undefined, JSON.stringify(bad));
});

test("tool names (required extensions): browser registers every tool of its own at session_start (pi never checks those; at run time the first extension in load order, -e: ours, has the name)", async () => {
	assert.equal((claims as Record<string, unknown>).toolRegistrar, undefined, "no per-name fallback");
	const f = fakePi([{ name: "browser_read", path: "/other/ext.ts" }]);
	await f.ready;
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, async () => {
		const { default: browser } = await import("../extensions/browser/index.ts");
		browser(f.pi);
		await f.fire("session_start");
	});
	assert.ok(f.tools.has("browser_read"), "registered: ours wins by load order (test/conflicts.test.ts)");
	assert.ok(f.tools.has("browser_tabs") && f.tools.has("app_call"));
});

test("environment: loading the integration takes every DECKHAND_* variable out of process.env, so a child process (pi's bash tool, ! commands) inherits none; a reload still finds them", async () => {
	const f = fakePi();
	await f.ready;
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t", DECKHAND_CONTROL_TOKEN: "c", DECKHAND_SHOTS_DIR: "/shots" }, async () => {
		const loadAll = async () => {
			for (const ext of ["bridge", "desk", "browser", "panels"]) (await import(`../extensions/${ext}/index.ts`)).default(f.pi);
		};
		await loadAll(); // the factories only: before any session_start
		const child = spawnSync(process.execPath, ["-e", "process.stdout.write(JSON.stringify(Object.keys(process.env).filter((k) => k.startsWith('DECKHAND_'))))"], { encoding: "utf8" });
		assert.equal(child.stdout, "[]", "a spawned child sees no DECKHAND_* variable");
		assert.deepEqual(Object.keys(process.env).filter((k) => k.startsWith("DECKHAND_")), []);
		// kept in memory for the extensions, which run again on /reload, /deckhand-reload and a session switch
		await loadAll();
		assert.equal(deskSocket(), "/nonexistent/x.sock");
		assert.equal(deskToken(), "t");
		assert.equal(envToken("DECKHAND_CONTROL_TOKEN"), "c");
		assert.equal(deckhandEnv("DECKHAND_SHOTS_DIR"), "/shots");
		assert.equal(inDesk(), true);
		// the initial environment again (a reloaded runtime): the token in memory (a reconnect token) wins
		process.env.DECKHAND_TOKEN = "stale";
		assert.equal(deskToken(), "t");
		assert.equal(process.env.DECKHAND_TOKEN, undefined);
	});
});

/** The panels producer in a Deckhand pi tab; `mode` is what the bridge says after its handshake. */
async function panelsIn(setup: (f: ReturnType<typeof fakePi>) => void = () => {}) {
	const f = fakePi();
	setup(f);
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, async () => {
		const { default: panels } = await import("../extensions/panels/index.ts");
		panels(f.pi);
		await f.fire("session_start");
	});
	const todo = { toolName: "todo", isError: false, details: { tasks: [{ id: 1, subject: "Write tests", status: "pending" }], nextId: 2 } };
	const published = () => f.emitted.filter(([e]) => e === PANELS_EVENT).map(([, p]) => p);
	return { f, todo, published };
}

test("panels: the producer asks for claims at session start, then publishes todos, subagents and shells once Deckhand draws panels", async () => {
	const { f, todo, published } = await panelsIn();
	assert.deepEqual(f.emitted.find(([e]) => e === CAPS_QUERY)?.[1], { from: "deckhand", capabilities: ["panels:todos", "panels:subagents", "panels:shells"] });
	await f.fire("tool_result", todo);
	assert.equal(published().length, 0, "nothing before the bridge's handshake");
	f.pi.events.emit(MODE_EVENT, true);
	const last = published().at(-1);
	assert.deepEqual(last.map((p: any) => p.panel), ["subagents", "shells", "todos"]);
	assert.deepEqual(last[2].rows.map((r: any) => r.text), ["Todos 0/1", "○ Write tests"]);
	f.pi.events.emit(MODE_EVENT, false);
	await f.fire("tool_result", todo);
	assert.equal(published().length, 1, "no panels while Deckhand draws none");
	await f.fire("session_shutdown");
});

test("panels: todos completed before a relaunch collapse into one row; one completed in this run stays listed until the next run", async () => {
	const tasks = (done: number[]) => [1, 2, 3, 4].map((id) => ({ id, subject: `t${id}`, status: done.includes(id) ? "completed" : "pending" }));
	const branch = (done: number[]) => [{ type: "custom", customType: "rpiv-todo-state", data: { tasks: tasks(done), nextId: 5 } }];
	const f = fakePi();
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, async () => {
		const { default: panels } = await import("../extensions/panels/index.ts");
		panels(f.pi);
		await f.fire("session_start", {}, f.ctx({ sessionManager: { getBranch: () => branch([1, 2]) } }));
	});
	const rows = () => f.emitted.filter(([e]) => e === PANELS_EVENT).at(-1)?.[1][2].rows.map((r: any) => r.text);
	f.pi.events.emit(MODE_EVENT, true);
	assert.deepEqual(rows(), ["Todos 2/4", "○ t3", "○ t4", "✓ 2 done"]);
	await f.fire("agent_start");
	await f.fire("tool_result", { toolName: "todo", isError: false, details: { tasks: tasks([1, 2, 3]), nextId: 5 } });
	assert.deepEqual(rows(), ["Todos 3/4", "✓ t3", "○ t4", "✓ 2 done"]);
	await f.fire("session_compact", {}, f.ctx({ sessionManager: { getBranch: () => branch([1, 2, 3]) } }));
	assert.deepEqual(rows(), ["Todos 3/4", "✓ t3", "○ t4", "✓ 2 done"], "compaction mid-run keeps this run's ticks");
	await f.fire("session_tree", {}, f.ctx({ sessionManager: { getBranch: () => branch([1, 2, 3]) } }));
	assert.deepEqual(rows(), ["Todos 3/4", "○ t4", "✓ 3 done"]);
	await f.fire("session_shutdown");
});

test("panels: an extension that claims todos takes them over (asked at session start, or later)", async () => {
	const { f, todo, published } = await panelsIn((x) => x.pi.events.on(CAPS_QUERY, () => x.pi.events.emit(CAPS_CLAIM, { capability: "panels:todos", owner: "my-todos", version: "1" })));
	f.pi.events.emit(MODE_EVENT, true);
	await f.fire("tool_result", todo);
	assert.deepEqual(published().at(-1).map((p: any) => p.panel), ["subagents", "shells"]);
	f.pi.events.emit(CAPS_CLAIM, { capability: "panels:subagents", owner: "my-agents" });
	await f.fire("tool_result", todo);
	assert.deepEqual(published().at(-1).map((p: any) => p.panel), ["shells"], "both claimed: only the shells of ours are published");
	f.pi.events.emit(CAPS_CLAIM, { capability: "panels:todos", owner: "deckhand" });
	await f.fire("session_shutdown");
});

test("panels: another producer's kit:desk:panels with rows (pi-kit's sidebar) takes over the panels it publishes", async () => {
	const { f, todo, published } = await panelsIn();
	f.pi.events.emit(MODE_EVENT, true);
	await f.fire("tool_result", todo);
	const ours = published().length;
	f.pi.events.emit(PANELS_EVENT, [{ panel: "subagents", title: "Subagents", rows: [{ text: "a run" }] }, { panel: "shells", title: "Shells", rows: [{ text: "Shells" }] }, { panel: "todos", title: "Todos", rows: [{ text: "Todos 0/1" }] }]);
	await f.fire("tool_result", todo);
	assert.equal(published().length, ours + 1, "its emission only: nothing of ours is left to publish");
	await f.fire("session_shutdown");
});

test("panels: an empty kit:desk:panels does not take a panel over (one rows: [] message must not hide it for good)", async () => {
	const { f, todo, published } = await panelsIn();
	f.pi.events.emit(MODE_EVENT, true);
	f.pi.events.emit(PANELS_EVENT, [{ panel: "subagents", title: "Subagents", rows: [] }, { panel: "shells", title: "Shells", rows: [] }, { panel: "todos", title: "Todos", rows: [] }]);
	await f.fire("tool_result", todo);
	assert.deepEqual(published().at(-1).map((p: any) => p.panel), ["subagents", "shells", "todos"], "still ours");
	assert.deepEqual(published().at(-1)[2].rows.map((r: any) => r.text), ["Todos 0/1", "○ Write tests"]);
	await f.fire("session_shutdown");
});

test("panels: a late claim clears what we published for that panel (one empty panel, marked ours), then we publish it no more", async () => {
	const { f, todo, published } = await panelsIn();
	f.pi.events.emit(MODE_EVENT, true);
	await f.fire("tool_result", todo);
	const before = published().length;
	f.pi.events.emit(CAPS_CLAIM, { capability: "panels:todos", owner: "my-todos", version: "1" });
	assert.deepEqual(published().slice(before), [[{ panel: "todos", title: "Todos", rows: [] }]], "one empty todos panel: the bridge's stale entry goes");
	const bridge = new Map();
	for (const p of published()) mergePanels(bridge, p);
	assert.deepEqual(bridge.get("todos").rows, [], "the bridge's copy is empty now");
	await f.fire("tool_result", todo);
	assert.deepEqual(published().at(-1).map((p: any) => p.panel), ["subagents", "shells"], "no longer ours; our own empty panel did not count as another producer's");
	const n = published().length;
	f.pi.events.emit(CAPS_CLAIM, { capability: "panels:todos", owner: "my-todos" });
	assert.equal(published().length, n, "claimed again: nothing more");
	await f.fire("session_shutdown");
});
