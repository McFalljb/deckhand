// Name conflicts with the user's own pi extensions (pi-kit's or anyone's), in a model of pi's own
// rules (test/pi-rules.ts, from pi's source): two extensions that register one tool or flag name
// while loading stop pi from starting at all, so no bundled extension may register one then.
// The optional shell steps back for another extension that has its tool names; guardrails leaves
// /guardrails to another copy; the required desk and browser register at session_start and win by
// load order (`-e` first).
// node --test test/conflicts.test.ts (Node 22.18+ strips the types; never runs pi).
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { loadedCommands, loadedTools } from "../lib/claims.ts";
import { piRules } from "./pi-rules.ts";

// every temp folder of this run in one, removed at exit
const TMP_ROOT = mkdtempSync(path.join(os.tmpdir(), "deckhand-test-"));
process.on("exit", () => rmSync(TMP_ROOT, { recursive: true, force: true }));

const stubs: Record<string, string> = {
	typebox: "export const Type = new Proxy({}, { get: () => (...a) => ({}) });",
	"@earendil-works/pi-tui": "export const truncateToWidth = (s) => s;",
};
registerHooks({ resolve: (spec, ctx, next) => (spec in stubs ? { url: `data:text/javascript,${encodeURIComponent(stubs[spec])}`, shortCircuit: true } : next(spec, ctx)) });

const ROOT = path.join(path.dirname(new URL(import.meta.url).pathname), "..");
const KIT = process.env.PI_KIT_DIR ? path.join(process.env.PI_KIT_DIR, "extensions") : "";
const noKit = !KIT || !existsSync(path.join(KIT, "shell/index.ts")) ? "PI_KIT_DIR (a pi-kit checkout) not set" : false;
const SHELL_TOOLS = ["bash_bg", "monitor", "wake_later", "shell_stop", "shell_list"];
const ENV = ["DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CONTROL_TOKEN", "DECKHAND_SHOTS_DIR", "PI_KIT_READONLY", "PI_CODING_AGENT_DIR", "PI_SUBAGENT_CHILD"];

/** Runs `f` with exactly `env` set among ENV (and Deckhand's in-memory copies cleared), then puts everything back. */
async function withEnv<T>(env: Record<string, string>, f: () => T | Promise<T>): Promise<T> {
	const saved = Object.fromEntries(ENV.map((k) => [k, process.env[k]]));
	const g = globalThis as any;
	const syms = Object.getOwnPropertySymbols(g).filter((s) => String(s.description).startsWith("deckhand."));
	const savedSyms = syms.map((s) => g[s]);
	for (const k of ENV) delete process.env[k];
	for (const s of syms) g[s] = undefined;
	process.env.PI_CODING_AGENT_DIR = mkdtempSync(path.join(TMP_ROOT, "deckhand-conflicts-"));
	Object.assign(process.env, env);
	try {
		return await f();
	} finally {
		for (const k of ENV) saved[k] === undefined ? delete process.env[k] : (process.env[k] = saved[k]);
		syms.forEach((s, i) => (g[s] = savedSyms[i]));
	}
}
const ours = async (name: string) => (await import(`../extensions/${name}/index.ts?${Math.random()}`)).default;
const ourPath = (name: string) => path.join(ROOT, "extensions", name);

/** A stand-in for pi-kit's shell, as the user's settings load it: its tools and /shells, registered while loading. */
const standInShell = (names = SHELL_TOOLS) => (pi: any) => {
	for (const name of names) pi.registerTool({ name, parameters: {}, execute: async () => ({ content: [] }) });
	pi.registerCommand("shells", { handler: async () => {} });
};

test("pi's rule: two extensions that register one tool name while loading stop pi (the model, from pi's source)", async () => {
	const pi = piRules();
	await pi.load("/a/index.ts", standInShell());
	await pi.load("/b/index.ts", standInShell(["monitor"]));
	const r = await pi.start();
	assert.equal(r.exitCode, 1);
	assert.deepEqual(r.errors, ['Failed to load extension "/b/index.ts": Tool "monitor" conflicts with /a/index.ts']);
	const late = piRules();
	await late.load("/a/index.ts", (p: any) => p.on("session_start", () => p.registerTool({ name: "monitor", parameters: {} })));
	await late.load("/b/index.ts", standInShell(["monitor"]));
	assert.equal((await late.start()).exitCode, 0, "a tool registered at session_start is never checked");
	assert.deepEqual(late.tools().map((t) => [t.name, t.owner]), [["monitor", "/a/index.ts"]], "the first extension in load order wins");
});

test("no bundled extension registers a tool or flag while loading (pi would refuse to start next to an extension with the same name)", async () => {
	for (const env of [{ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, { DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t", DECKHAND_CONTROL_TOKEN: "c" }, {}])
		for (const name of ["bridge", "desk", "browser", "panels", "guardrails", "shell", "notes"])
			await withEnv(env, async () => {
				const pi = piRules();
				await pi.load(ourPath(name), await ours(name));
				const [x] = pi.extensions;
				assert.deepEqual([...x.tools.keys(), ...x.flags.keys()], [], `${name} with ${Object.keys(env).join(", ") || "no Deckhand variables"}`);
			});
});

test("shell: next to a stand-in pi-kit shell from the user's settings, pi starts with one copy of each tool (theirs) and one /shells; ours says so", async () => {
	await withEnv({}, async () => {
		const pi = piRules();
		await pi.load(ourPath("shell"), await ours("shell")); // -e: first
		await pi.load("/home/u/pi-kit/extensions/shell/index.ts", standInShell());
		const r = await pi.start();
		assert.deepEqual(r, { exitCode: 0, errors: [] });
		assert.deepEqual(pi.tools().map((t) => [t.name, t.owner]), SHELL_TOOLS.map((n) => [n, "/home/u/pi-kit/extensions/shell/index.ts"]));
		assert.deepEqual(pi.commands().map((c) => c.name), ["shells"], "not /shells:1 and /shells:2");
		assert.equal(pi.notices.filter((n) => /Deckhand's shell stepped back.*\/home\/u\/pi-kit\/extensions\/shell\/index\.ts/.test(n)).length, 1, pi.notices.join("\n"));
		assert.equal(pi.emitted.filter(([e]) => e === "kit:shell:rows").length, 0, "publishes no rows: the Shells panel is the other shell's");
		await pi.fire("session_shutdown");
	});
});

test("shell: one of its names elsewhere is enough to step back whole (its tools share their tasks)", async () => {
	await withEnv({}, async () => {
		const pi = piRules();
		await pi.load(ourPath("shell"), await ours("shell"));
		await pi.load("/x/monitor.ts", standInShell(["monitor"]));
		assert.equal((await pi.start()).exitCode, 0);
		assert.deepEqual(pi.tools().map((t) => t.name), ["monitor"]);
		assert.deepEqual(pi.commands().map((c) => c.owner), ["/x/monitor.ts"]);
	});
});

test("shell: alone, it registers its tools and /shells at session start", async () => {
	await withEnv({}, async () => {
		const pi = piRules();
		await pi.load(ourPath("shell"), await ours("shell"));
		assert.equal((await pi.start()).exitCode, 0);
		assert.deepEqual(pi.tools().map((t) => [t.name, t.owner]), SHELL_TOOLS.map((n) => [n, ourPath("shell")]));
		assert.deepEqual(pi.commands().map((c) => c.name), ["shells"]);
		assert.equal(pi.notices.length, 0);
		await pi.fire("session_shutdown");
	});
});

test("guardrails: next to pi-kit's, one /guardrails (pi-kit's); alone, ours", async () => {
	const dir = path.join(mkdtempSync(path.join(TMP_ROOT, "deckhand-kitlike-")), "extensions/guardrails");
	mkdirSync(dir, { recursive: true });
	for (const f of ["index.ts", "core.ts"]) writeFileSync(path.join(dir, f), "export default () => {};\n");
	await withEnv({}, async () => {
		const pi = piRules();
		await pi.load(ourPath("guardrails"), await ours("guardrails"));
		await pi.load(path.join(dir, "index.ts"), (p: any) => p.registerCommand("guardrails", { handler: async () => {} }));
		assert.equal((await pi.start()).exitCode, 0);
		assert.deepEqual(pi.commands().map((c) => [c.name, c.owner]), [["guardrails", path.join(dir, "index.ts")]]);
		const alone = piRules();
		await alone.load(ourPath("guardrails"), await ours("guardrails"));
		await alone.start();
		assert.deepEqual(alone.commands().map((c) => [c.name, c.owner]), [["guardrails", ourPath("guardrails")]]);
	});
});

test("browser (required): next to an extension with one of its tool names, pi starts and ours is the one copy (load order)", async () => {
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, async () => {
		const pi = piRules();
		await pi.load(ourPath("browser"), await ours("browser"));
		await pi.load("/x/tabs.ts", standInShell(["browser_tabs"]));
		assert.equal((await pi.start()).exitCode, 0);
		const tabs = pi.tools().filter((t) => t.name === "browser_tabs");
		assert.deepEqual(tabs.map((t) => t.owner), [ourPath("browser")]);
		await pi.fire("session_shutdown");
	});
});

test("loadedTools, loadedCommands: who else provides a name; nothing when pi cannot say", () => {
	const pi = {
		getAllTools: () => [
			{ name: "bash_bg", sourceInfo: { path: "/kit/shell/index.ts" } },
			{ name: "read", sourceInfo: { path: "builtin:read" } },
			{ name: "x", sourceInfo: {} },
		],
		getCommands: () => [
			{ name: "shells:1", source: "extension", sourceInfo: { path: "/a.ts" } },
			{ name: "shells:2", source: "extension", sourceInfo: { path: "/b.ts" } },
			{ name: "guardrails", source: "prompt", sourceInfo: { path: "/p.md" } },
		],
	};
	assert.deepEqual([...loadedTools(pi, ["bash_bg", "monitor", "x"])], [["bash_bg", "/kit/shell/index.ts"], ["x", ""]]);
	assert.deepEqual([...loadedCommands(pi, ["shells", "guardrails", "sidebar"])], [["shells", "/a.ts"], ["guardrails", "/p.md"]]);
	const loading = { getAllTools: () => { throw new Error("not initialized"); }, getCommands: () => { throw new Error("not initialized"); } };
	assert.equal(loadedTools(loading, ["bash_bg"]).size, 0);
	assert.equal(loadedCommands(loading, ["shells"]).size, 0);
	assert.equal(loadedTools({}, ["bash_bg"]).size, 0, "an older pi without getAllTools");
});

test("overlap: ours next to pi-kit's own extensions (shell, guardrails, notes, desk, desk-browser, desk-bridge), pi starts", { skip: noKit }, async () => {
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, async () => {
		const pi = piRules();
		for (const name of ["bridge", "desk", "browser", "panels", "guardrails", "shell", "notes"]) await pi.load(ourPath(name), await ours(name));
		// (pi-kit's sidebar registers only /sidebar, a name Deckhand does not use; it needs more of pi-tui than the stub)
		for (const name of ["shell", "guardrails", "notes", "desk", "desk-browser", "desk-bridge"]) {
			const file = path.join(KIT, name, "index.ts");
			if (existsSync(file)) await pi.load(file, (await import(file)).default);
		}
		const r = await pi.start();
		assert.deepEqual(r, { exitCode: 0, errors: [] });
		for (const n of SHELL_TOOLS) assert.equal(pi.tools().filter((t) => t.name === n)[0]?.owner, path.join(KIT, "shell/index.ts"), n);
		for (const n of ["shells", "guardrails"]) assert.equal(pi.commands().filter((c) => c.name.split(":")[0] === n).length, 1, n);
		await pi.fire("session_shutdown");
	});
});

test("desk_show: registered at session_start, never while loading, so an extension of the user's with a desk_show tool does not stop pi; ours (-e, first) has the name", async () => {
	await withEnv({ DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t" }, async () => {
		const pi = piRules();
		await pi.load(ourPath("browser"), await ours("browser"));
		assert.deepEqual([...pi.extensions[0].tools.keys()], [], "nothing while loading");
		await pi.load("/user/ext/index.ts", (p: any) => p.registerTool({ name: "desk_show", parameters: {}, execute: async () => ({ content: [] }) }));
		const r = await pi.start();
		assert.equal(r.exitCode, 0, r.errors.join("; "));
		const t = pi.tools().find((x) => x.name === "desk_show");
		assert.equal(t?.owner, ourPath("browser"), "ours wins by load order");
	});
});
