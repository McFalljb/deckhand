// pi's rules for several extensions in one process, written from pi's own source (1.4.0 and 1.5.0
// agree on all of these; paths are in @earendil-works/pi-coding-agent/dist):
//
// - Load order: `-e` paths first, then the settings' and packages' (core/resource-loader.js
//   `mergePaths(cliEnabledExtensions, enabledExtensions)`). Each factory runs to completion in turn.
// - While loading, getAllTools and getCommands throw (core/extensions/loader.js: "Action methods
//   cannot be called during extension loading").
// - After every factory ran, a tool or flag name registered by two extensions is an error
//   (core/resource-loader.js detectExtensionConflicts: "Tool \"x\" conflicts with <path>"), and any
//   error makes pi exit 1 before the session starts (main.js: hasRuntimeErrors → process.exit(1)).
//   Commands are not checked: every copy is kept, named `name:1`, `name:2`, … when there are
//   several (core/extensions/runner.js resolveRegisteredCommands).
// - Then session_start runs every extension's handlers in load order, each awaited
//   (runner.js emit). registerTool still works then (docs/extensions.md "Dynamic Tool Loading"),
//   and is never checked for conflicts: at run time the first extension in load order that has a
//   name wins (runner.js getAllRegisteredTools: "first registration per name wins").
// - Once every session_start handler has run, resources_discover runs (same order, awaited), on
//   every session start: startup, reload, new, resume, fork (agent-session.js bindExtensions:
//   `await emit(sessionStartEvent)`, then `extendResourcesFromExtensions`; docs/extensions.md
//   "SessionStart --> resources_discover").
//
// node --test never runs pi; this is what the tests load our extensions into.
import os from "node:os";

type Ext = { path: string; tools: Map<string, any>; commands: Map<string, any>; flags: Map<string, any>; handlers: Map<string, any[]> };

export function piRules() {
	const exts: Ext[] = [];
	let loading = true;
	const listeners = new Map<string, ((x: any) => void)[]>();
	const emitted: [string, any][] = [];
	const events = {
		on: (e: string, f: any) => (listeners.set(e, [...(listeners.get(e) ?? []), f]), () => listeners.set(e, (listeners.get(e) ?? []).filter((g) => g !== f))),
		emit: (e: string, x: any) => {
			emitted.push([e, x]);
			for (const f of listeners.get(e) ?? []) f(x);
		},
	};
	const notInitialized = () => {
		throw new Error("Extension runtime not initialized. Action methods cannot be called during extension loading.");
	};
	/** The run-time tools: the first extension in load order that has a name wins. */
	const allTools = () => {
		const out = new Map<string, { name: string; owner: string; tool: any; sourceInfo: { path: string } }>();
		for (const x of exts) for (const [name, tool] of x.tools) if (!out.has(name)) out.set(name, { name, owner: x.path, tool, sourceInfo: { path: x.path } });
		return [...out.values()];
	};
	const allCommands = () => {
		const list = exts.flatMap((x) => [...x.commands.values()].map((c) => ({ ...c, owner: x.path })));
		const count = (n: string) => list.filter((c) => c.name === n).length;
		const seen = new Map<string, number>();
		return list.map((c) => {
			const k = (seen.get(c.name) ?? 0) + 1;
			seen.set(c.name, k);
			return { ...c, name: count(c.name) > 1 ? `${c.name}:${k}` : c.name, source: "extension", sourceInfo: { path: c.owner } };
		});
	};
	const notices: string[] = [];
	const widgets = new Map<string, unknown>();
	const ui = {
		notify: (m: string) => void notices.push(m),
		confirm: async () => true,
		select: async () => undefined,
		setWidget: (k: string, w: unknown) => void widgets.set(k, w),
		setStatus: () => {},
	};
	const ctx: any = { mode: "tui", cwd: os.tmpdir(), hasUI: true, ui, isIdle: () => true, hasPendingMessages: () => false, getContextUsage: () => undefined, sessionManager: { getBranch: () => [] } };

	/** Runs one extension's factory, as pi loads `path`. */
	async function load(path: string, factory: (pi: any) => unknown) {
		const x: Ext = { path, tools: new Map(), commands: new Map(), flags: new Map(), handlers: new Map() };
		exts.push(x);
		const api = {
			registerTool: (t: any) => void x.tools.set(t.name, t),
			registerCommand: (name: string, c: any) => void x.commands.set(name, { name, ...c }),
			registerFlag: (name: string, f: any) => void x.flags.set(name, f),
			registerShortcut: () => {},
			on: (e: string, f: any) => void x.handlers.set(e, [...(x.handlers.get(e) ?? []), f]),
			events,
			getAllTools: () => (loading ? notInitialized() : allTools().map(({ name, sourceInfo }) => ({ name, sourceInfo }))),
			getCommands: () => (loading ? notInitialized() : allCommands()),
			sendMessage: () => {},
			sendUserMessage: () => {},
		};
		await factory(api);
	}
	/** pi's start: the conflict check (errors: pi exits 1), then session_start. */
	async function start(reason = "startup"): Promise<{ exitCode: number; errors: string[] }> {
		loading = false;
		const errors: string[] = [];
		for (const kind of ["tools", "flags"] as const) {
			const owners = new Map<string, string>();
			for (const x of exts)
				for (const name of x[kind].keys()) {
					const o = owners.get(name);
					if (o && o !== x.path) errors.push(`Failed to load extension "${x.path}": ${kind === "tools" ? `Tool "${name}"` : `Flag "--${name}"`} conflicts with ${o}`);
					else owners.set(name, x.path);
				}
		}
		if (errors.length) return { exitCode: 1, errors };
		await fire("session_start", { type: "session_start", reason });
		await fire("resources_discover", { type: "resources_discover", cwd: ctx.cwd, reason: reason === "reload" ? "reload" : "startup" });
		return { exitCode: 0, errors };
	}
	async function fire(e: string, ev: any = {}) {
		const out: any[] = [];
		for (const x of exts) for (const f of x.handlers.get(e) ?? []) out.push(await f(ev, ctx));
		return out;
	}
	return { load, start, fire, ctx, notices, widgets, emitted, events, tools: allTools, commands: allCommands, extensions: exts };
}
