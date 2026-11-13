// Deckhand's optional pi extensions (guardrails, shell, notes; extensions.json `required: false`) and
// Atlas's desk skill: what each does in a fake pi, and how each steps back next to pi-kit's copy.
// With PI_KIT_DIR set to a pi-kit checkout, the overlap tests load pi-kit's own (unmodified)
// extensions next to ours; without it they are skipped.
// node --test test/optional.test.ts (Node 22.18+ strips the types; never runs pi).
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { CAPS_CLAIM, CAPS_QUERY, commandPaths, GUARDRAILS_CAP, NOTES_CAP } from "../lib/claims.ts";
import { isKitGuardrails } from "../lib/guardrails.ts";
import { blockers, MODE_EVENT, PANELS_EVENT, SHELL_ROWS_EVENT, shellRows } from "../lib/protocol.ts";

// every temp folder this file makes goes in one of its own, removed when its tests end (they were
// left in $TMPDIR)
const TMP_ROOT = mkdtempSync(path.join(os.tmpdir(), "deckhand-test-"));
process.on("exit", () => rmSync(TMP_ROOT, { recursive: true, force: true }));

// pi supplies these packages to extensions; here, stubs (only what the shell's code touches)
const stubs: Record<string, string> = {
	typebox: "export const Type = new Proxy({}, { get: () => (...a) => ({}) });",
	"@earendil-works/pi-tui": "export const truncateToWidth = (s) => s;",
};
registerHooks({ resolve: (spec, ctx, next) => (spec in stubs ? { url: `data:text/javascript,${encodeURIComponent(stubs[spec])}`, shortCircuit: true } : next(spec, ctx)) });

const HERE = path.dirname(new URL(import.meta.url).pathname);
const ROOT = path.join(HERE, "..");
const KIT = process.env.PI_KIT_DIR ? path.join(process.env.PI_KIT_DIR, "extensions") : "";
const noKit = !KIT || !existsSync(path.join(KIT, "guardrails/index.ts")) ? "PI_KIT_DIR (a pi-kit checkout) not set" : false;

/**
 * A fake pi that keeps pi's run-time rules for several extensions in one process: the first
 * extension that registers a tool name has it (getAllTools); every copy of a command is kept and
 * named `name:1`, `name:2` when there are several (getCommands, as pi's resolveRegisteredCommands);
 * every handler of every extension runs. pi's start-up check (two extensions that register one tool
 * name while loading stop pi) is test/pi-rules.ts's, in test/conflicts.test.ts.
 */
function fakePi() {
	const tools = new Map<string, { owner: string; tool: any; file: string }>();
	const commands: { name: string; owner: string; cmd: any; file: string }[] = [];
	const handlers = new Map<string, any[]>();
	const listeners = new Map<string, ((x: any) => void)[]>();
	const emitted: [string, any][] = [];
	const sent: any[] = [];
	const asked: string[] = [];
	const widgets = new Map<string, unknown>();
	const statuses = new Map<string, unknown>();
	const branch: any[] = [];
	const events = {
		on: (e: string, f: any) => (listeners.set(e, [...(listeners.get(e) ?? []), f]), () => listeners.set(e, (listeners.get(e) ?? []).filter((g) => g !== f))),
		emit: (e: string, x: any) => {
			emitted.push([e, x]);
			for (const f of listeners.get(e) ?? []) f(x);
		},
	};
	const notices: string[] = [];
	const api = (owner: string, file = `/${owner}/extension.ts`): any => ({
		registerTool: (t: any) => void (tools.has(t.name) || tools.set(t.name, { owner, tool: t, file })),
		getAllTools: () => [...tools].map(([name, t]) => ({ name, sourceInfo: { path: t.file } })),
		registerCommand: (name: string, cmd: any) => commands.push({ name, owner, cmd, file }),
		getCommands: () => {
			const n = (name: string) => commands.filter((c) => c.name === name).length;
			const seen = new Map<string, number>();
			return commands.map((c) => {
				const k = (seen.get(c.name) ?? 0) + 1;
				seen.set(c.name, k);
				return { name: n(c.name) > 1 ? `${c.name}:${k}` : c.name, source: "extension", owner: c.owner, sourceInfo: { path: c.file } };
			});
		},
		on: (e: string, f: any) => handlers.set(e, [...(handlers.get(e) ?? []), f]),
		events,
		sendMessage: (m: any, o: any) => void (sent.push({ ...m, options: o }), branch.push({ type: "custom_message", customType: m.customType })),
		sendUserMessage: () => {},
	});
	let percent = 0;
	const ui = {
		confirm: async (_t: string, m: string) => (asked.push(m), true),
		notify: (m: string) => void notices.push(m),
		setWidget: (k: string, w: unknown) => void widgets.set(k, w),
		setStatus: (k: string, v: unknown) => void statuses.set(k, v),
		select: async () => undefined,
	};
	const ctx: any = { mode: "tui", cwd: os.tmpdir(), hasUI: true, ui, isIdle: () => true, hasPendingMessages: () => false, getContextUsage: () => ({ percent }), sessionManager: { getBranch: () => branch } };
	const fire = async (e: string, ev: any = {}) => {
		const out: any[] = [];
		for (const f of handlers.get(e) ?? []) out.push(await f(ev, ctx));
		return out;
	};
	return { api, notices, tools, commands, emitted, sent, asked, widgets, statuses, branch, events, fire, ctx, setPercent: (p: number) => void (percent = p) };
}

/** Runs `f` with these environment variables set (undefined: unset), then puts them back. */
async function withEnv<T>(env: Record<string, string | undefined>, f: () => T | Promise<T>): Promise<T> {
	const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
	for (const [k, v] of Object.entries(env)) v === undefined ? delete process.env[k] : (process.env[k] = v);
	try {
		return await f();
	} finally {
		for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : (process.env[k] = v);
	}
}

/** A pi agent dir whose guardrails config asks before a force push (both copies read this file). */
function askConfig(): string {
	const dir = mkdtempSync(path.join(TMP_ROOT, "deckhand-optional-"));
	mkdirSync(path.join(dir, "extensions/guardrails"), { recursive: true });
	writeFileSync(path.join(dir, "extensions/guardrails/config.json"), '{"enable": {"force-push": "ask"}}');
	return dir;
}
const forcePush = { toolName: "bash", input: { command: "git push --force origin x" } };

// ---- the manifest and the skill ----

test("manifest: guardrails, shell and notes are optional, with their defaults (on, on, off) and a one-line description; each folder exists", () => {
	const m = JSON.parse(readFileSync(path.join(ROOT, "extensions.json"), "utf8"));
	const opt = m.extensions.filter((e: any) => !e.required);
	assert.deepEqual(opt.map((e: any) => [e.name, e.default]), [["guardrails", true], ["shell", true], ["notes", false]]);
	for (const e of m.extensions) assert.ok(existsSync(path.join(ROOT, "extensions", e.name, "index.ts")), e.name);
	for (const e of opt) assert.ok(typeof e.does === "string" && e.does && !e.does.includes("\n") && e.does.length <= 120, `${e.name}: one line for Settings`);
});

test("Atlas's skill: deckhand-desk (pi keeps the first skill of a name and --skill paths come last, so it cannot share pi-kit's `desk`); Deckhand's names, no env variable names", () => {
	assert.ok(!existsSync(path.join(ROOT, "skills/desk")), "no skill named like pi-kit's");
	const text = readFileSync(path.join(ROOT, "skills/deckhand-desk/SKILL.md"), "utf8");
	assert.match(text, /^---\nname: deckhand-desk\ndescription: How Deckhand works/);
	assert.doesNotMatch(text, /pi-desk|PI_DESK|DECKHAND_[A-Z]/);
	assert.doesNotMatch(text, /\bHome agent\b/);
});

// ---- guardrails ----

async function guardrailsIn(f: ReturnType<typeof fakePi>, owner = "deckhand") {
	const { default: load } = await import(`../extensions/guardrails/index.ts?${Math.random()}`);
	load(f.api(owner, path.join(ROOT, "extensions/guardrails/index.ts")));
}

/** A folder laid out like pi-kit's guardrails (index.ts next to core.ts); its index.ts path. */
function kitLike(): string {
	const dir = path.join(mkdtempSync(path.join(TMP_ROOT, "deckhand-kitlike-")), "extensions/guardrails");
	mkdirSync(dir, { recursive: true });
	for (const f of ["index.ts", "core.ts", "readonly.ts"]) writeFileSync(path.join(dir, f), "export default () => {};\n");
	return path.join(dir, "index.ts");
}

test("guardrails: PI_KIT_READONLY=1 (Deckhand's read-only jobs) blocks edits, writes and mutating bash; without it they run", async () => {
	for (const [ro, blocked] of [["1", true], [undefined, false]] as const) {
		const f = fakePi();
		await withEnv({ PI_KIT_READONLY: ro, PI_CODING_AGENT_DIR: askConfig() }, async () => {
			await guardrailsIn(f);
			await f.fire("session_start");
			for (const ev of [{ toolName: "edit", input: {} }, { toolName: "write", input: {} }, { toolName: "bash", input: { command: "rm -rf x" } }]) {
				const [r] = await f.fire("tool_call", ev);
				assert.equal(!!r?.block, blocked, `${ro} ${ev.toolName}`);
			}
		});
	}
});

test("guardrails: alone it asks once for a rule's command and redacts secrets in tool output", async () => {
	const f = fakePi();
	await withEnv({ PI_KIT_READONLY: undefined, PI_CODING_AGENT_DIR: askConfig() }, async () => {
		await guardrailsIn(f);
		await f.fire("session_start");
		assert.deepEqual(f.emitted.find(([e]) => e === CAPS_QUERY)?.[1], { from: "deckhand", capabilities: [GUARDRAILS_CAP] });
		await f.fire("tool_call", forcePush);
		assert.equal(f.asked.length, 1);
		const [r] = await f.fire("tool_result", { toolName: "bash", input: {}, content: [{ type: "text", text: "token=abcdefghijklmnop1234" }] });
		assert.equal(r.content[0].text, "token=[REDACTED]");
	});
});

test("guardrails: steps back for an extension that claims guardrails, and for another /guardrails (pi-kit's makes no claim)", async () => {
	await withEnv({ PI_KIT_READONLY: "1", PI_CODING_AGENT_DIR: askConfig() }, async () => {
		// a claim, answering the query
		const a = fakePi();
		a.events.on(CAPS_QUERY, (q: any) => q.capabilities.includes(GUARDRAILS_CAP) && a.events.emit(CAPS_CLAIM, { capability: GUARDRAILS_CAP, owner: "other", version: "1" }));
		await guardrailsIn(a);
		await a.fire("session_start");
		assert.deepEqual(await a.fire("tool_call", forcePush), [undefined]);
		assert.deepEqual(await a.fire("tool_call", { toolName: "edit", input: {} }), [undefined], "its read-only blocking is the other's too");
		assert.deepEqual(await a.fire("tool_result", { toolName: "bash", input: {}, content: [{ type: "text", text: "token=abcdefghijklmnop1234" }] }), [undefined]);
		assert.equal(a.asked.length, 0);
		// pi-kit's /guardrails (its entry file, next to its core.ts): ours steps back, and says so once
		const b = fakePi();
		await guardrailsIn(b);
		b.api("pi-kit", kitLike()).registerCommand("guardrails", { handler: async () => {} });
		await b.fire("session_start");
		assert.deepEqual(await b.fire("tool_call", forcePush), [undefined]);
		assert.equal(b.asked.length, 0);
		assert.equal(b.notices.filter((n) => /Deckhand's guardrails stepped back/.test(n)).length, 1, b.notices.join("\n"));
		await b.fire("session_start");
		assert.equal(b.notices.filter((n) => /stepped back/.test(n)).length, 1, "once");
	});
});

test("guardrails: another extension's /guardrails (not pi-kit's entry files) does not turn ours off", async () => {
	await withEnv({ PI_KIT_READONLY: undefined, PI_CODING_AGENT_DIR: askConfig() }, async () => {
		for (const file of ["/somewhere/else/guardrails/index.ts", "/x/my-rails.ts", path.join(ROOT, "extensions/guardrails/index.ts")]) {
			const f = fakePi();
			await guardrailsIn(f);
			f.api("other", file).registerCommand("guardrails", { handler: async () => {} });
			await f.fire("session_start");
			await f.fire("tool_call", forcePush);
			assert.equal(f.asked.length, 1, `still on next to ${file}`);
			assert.equal(f.notices.filter((n) => /stepped back/.test(n)).length, 0);
		}
	});
});

test("guardrails: a write or edit that would put this session's [REDACTED] marker into a file is blocked (the real value would be lost)", async () => {
	await withEnv({ PI_KIT_READONLY: undefined, PI_CODING_AGENT_DIR: askConfig() }, async () => {
		const f = fakePi();
		await guardrailsIn(f);
		await f.fire("session_start");
		const write = { toolName: "write", input: { path: "/w/.env.local", content: "A=1\nKEY=sk-[REDACTED]\n" } };
		const edit = { toolName: "edit", input: { path: "/w/cfg.ts", edits: [{ oldText: "x", newText: "const k = '[REDACTED]'" }] } };
		assert.deepEqual(await f.fire("tool_call", write), [undefined], "nothing redacted yet: a literal [REDACTED] is the model's own");
		const [r] = await f.fire("tool_result", { toolName: "read", input: { path: "/w/cfg.ts" }, content: [{ type: "text", text: "const k = 'sk-ant-abcdefghijklmnopqrstuvwxyz'" }] });
		assert.match(r.content[0].text, /\[REDACTED\]/);
		for (const ev of [write, edit]) {
			const [b] = await f.fire("tool_call", ev);
			assert.equal(b?.block, true, ev.toolName);
			assert.match(b.reason, /\[REDACTED\].*real value/s);
		}
		assert.deepEqual(await f.fire("tool_call", { toolName: "write", input: { path: "/w/a.txt", content: "plain" } }), [undefined]);
	});
});

test("isKitGuardrails: pi-kit's guardrails entry files only (index.ts or readonly.ts next to its core.ts)", () => {
	const kit = kitLike();
	assert.equal(isKitGuardrails(kit), true);
	assert.equal(isKitGuardrails(path.join(path.dirname(kit), "readonly.ts")), true);
	assert.equal(isKitGuardrails(path.join(ROOT, "extensions/guardrails/index.ts")), false, "ours");
	assert.equal(isKitGuardrails("/nope/extensions/guardrails/index.ts"), false, "no core.ts beside it");
	assert.equal(isKitGuardrails(undefined), false);
});

test("commandPaths: the source file of each copy of a command (pi's name, name:1, name:2), not a prefix", () => {
	const pi = (names: string[]) => ({ getCommands: () => names.map((name, i) => ({ name, source: "extension", sourceInfo: { path: `/e${i}.ts` } })) });
	assert.deepEqual(commandPaths(pi(["guardrails"]), "guardrails"), ["/e0.ts"]);
	assert.deepEqual(commandPaths(pi(["guardrails:1", "guardrails:2"]), "guardrails"), ["/e0.ts", "/e1.ts"]);
	assert.deepEqual(commandPaths(pi(["guardrails-plus", "guardrails:x"]), "guardrails"), []);
	assert.deepEqual(commandPaths({ getCommands: () => { throw new Error("not initialized"); } }, "guardrails"), []);
	assert.deepEqual(commandPaths({}, "guardrails"), []);
});

// ---- shell ----

async function shellIn(f: ReturnType<typeof fakePi>, owner = "deckhand") {
	const { default: load } = await import(`../extensions/shell/index.ts?${Math.random()}`);
	load(f.api(owner));
}

test("shell: rows on kit:shell:rows become the Shells panel and the bridge's blockers; its widget steps aside while Deckhand draws panels", async () => {
	const f = fakePi();
	await withEnv({ PI_KIT_READONLY: undefined, DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t", PI_CODING_AGENT_DIR: askConfig() }, async () => {
		(await import("../extensions/panels/index.ts")).default(f.api("deckhand"));
		await shellIn(f);
		await f.fire("session_start");
		const exec = f.tools.get("bash_bg")!.tool.execute;
		await exec("1", { command: "sleep 5" }, undefined, undefined, f.ctx);
		const rows = f.emitted.filter(([e]) => e === SHELL_ROWS_EVENT).at(-1)![1];
		assert.equal(rows[0].id, "sh1");
		assert.deepEqual(blockers(rows, []), ["shell sh1: sleep 5"], "what the bridge reports, and Deckhand's reload waits for");
		assert.ok(f.widgets.get("deckhand-shell"), "its widget, before Deckhand draws panels");
		f.events.emit(MODE_EVENT, true);
		assert.equal(f.widgets.get("deckhand-shell"), undefined, "Deckhand's Shells panel instead");
		assert.equal(f.statuses.get("deckhand-shell"), undefined);
		const shells = f.emitted.filter(([e]) => e === PANELS_EVENT).at(-1)![1].find((p: any) => p.panel === "shells");
		assert.equal(shells.rows[0].text, "Shells");
		assert.match(shells.rows[1].text, /^sh1 /);
		await f.fire("session_shutdown");
	});
});

test("shell: not registered in read-only sessions", async () => {
	const f = fakePi();
	await withEnv({ PI_KIT_READONLY: "1" }, async () => {
		await shellIn(f);
		assert.equal(f.tools.size, 0);
	});
});

// ---- notes ----

async function notesIn(f: ReturnType<typeof fakePi>, env: Record<string, string | undefined> = {}) {
	await withEnv({ PI_SUBAGENT_CHILD: undefined, PI_KIT_NOTES_REMIND_PERCENT: undefined, ...env }, async () => {
		const { default: load } = await import(`../extensions/notes/index.ts?${Math.random()}`);
		load(f.api("deckhand"));
	});
	await f.fire("session_start");
}
const toolTurn = { toolResults: [{}] };

test("notes: past 75% on a turn that ran tools, one reminder at the next turn start, never a turn of its own; again after a compaction", async () => {
	const f = fakePi();
	await notesIn(f);
	assert.deepEqual(f.emitted.find(([e]) => e === CAPS_QUERY)?.[1], { from: "deckhand", capabilities: [NOTES_CAP] });
	f.setPercent(80);
	await f.fire("turn_end", { toolResults: [] });
	await f.fire("turn_start");
	assert.equal(f.sent.length, 0, "a turn without tools (a final answer): nothing");
	await f.fire("turn_end", toolTurn);
	assert.equal(f.sent.length, 0, "not from turn_end");
	await f.fire("turn_start");
	assert.equal(f.sent.length, 1);
	assert.deepEqual(f.sent[0].options, { triggerTurn: false });
	assert.equal(f.sent[0].customType, "deckhand-notes");
	await f.fire("turn_end", toolTurn);
	await f.fire("agent_end");
	assert.equal(f.sent.length, 1, "once until compaction");
	await f.fire("session_compact");
	await f.fire("turn_end", toolTurn);
	await f.fire("agent_end");
	assert.equal(f.sent.length, 2, "re-armed; sent at the run's end if no turn follows");
});

test("notes: names the notes folder only from PI_KIT_NOTES_DIR (no path of its own); PI_KIT_NOTES_REMIND_PERCENT moves or turns off the threshold", async () => {
	const src = readFileSync(path.join(ROOT, "extensions/notes/index.ts"), "utf8");
	assert.doesNotMatch(src, /\/Users\/|~\/|workspace|Notes\//, "no user-specific path");
	for (const [dir, want] of [["/n/notes", /session note \(in \/n\/notes\), rewrite/], [undefined, /session note, rewrite/]] as const) {
		const f = fakePi();
		await notesIn(f);
		f.setPercent(76);
		await f.fire("turn_end", toolTurn);
		await withEnv({ PI_KIT_NOTES_DIR: dir }, () => f.fire("turn_start"));
		assert.match(f.sent[0].content, want);
	}
	const g = fakePi();
	await notesIn(g, { PI_KIT_NOTES_REMIND_PERCENT: "90" });
	g.setPercent(80);
	await g.fire("turn_end", toolTurn);
	await g.fire("turn_start");
	assert.equal(g.sent.length, 0);
	const off = fakePi();
	await notesIn(off, { PI_KIT_NOTES_REMIND_PERCENT: "0" });
	off.setPercent(99);
	await off.fire("turn_end", toolTurn);
	await off.fire("turn_start");
	assert.equal(off.sent.length, 0);
});

test("notes: steps back for pi-kit's reminder (on the branch since it became due) for good, and for a claim", async () => {
	const f = fakePi();
	await notesIn(f);
	f.setPercent(80);
	await f.fire("turn_end", toolTurn);
	f.branch.push({ type: "custom_message", customType: "pi-kit-notes" }); // pi appends what turn_end handlers queued
	await f.fire("turn_start");
	assert.equal(f.sent.length, 0);
	await f.fire("session_compact");
	await f.fire("turn_end", toolTurn);
	await f.fire("turn_start");
	assert.equal(f.sent.length, 0, "quiet for good");
	const g = fakePi();
	await notesIn(g);
	g.events.emit(CAPS_CLAIM, { capability: NOTES_CAP, owner: "other" });
	g.setPercent(80);
	await g.fire("turn_end", toolTurn);
	await g.fire("turn_start");
	assert.equal(g.sent.length, 0);
});

// ---- next to pi-kit's own copies (PI_KIT_DIR) ----

test("overlap: ours and pi-kit's guardrails in one pi ask once for one command (ours steps back)", { skip: noKit }, async () => {
	await withEnv({ PI_KIT_READONLY: undefined, PI_CODING_AGENT_DIR: askConfig() }, async () => {
		const f = fakePi();
		await guardrailsIn(f); // -e: first
		(await import(path.join(KIT, "guardrails/index.ts"))).default(f.api("pi-kit", path.join(KIT, "guardrails/index.ts")));
		await f.fire("session_start");
		await f.fire("tool_call", forcePush);
		assert.equal(f.asked.length, 1, "asked once: by pi-kit's copy");
		// the control: ours alone asks once too, and so would two that did not step back (twice)
		const g = fakePi();
		await guardrailsIn(g);
		await g.fire("session_start");
		await g.fire("tool_call", forcePush);
		assert.equal(g.asked.length, 1);
	});
	await withEnv({ PI_KIT_READONLY: "1", PI_CODING_AGENT_DIR: askConfig() }, async () => {
		const f = fakePi();
		await guardrailsIn(f);
		(await import(`${path.join(KIT, "guardrails/index.ts")}?ro`)).default(f.api("pi-kit", path.join(KIT, "guardrails/index.ts")));
		await f.fire("session_start");
		const out = await f.fire("tool_call", { toolName: "edit", input: {} });
		assert.equal(out.filter((r) => r?.block).length, 1, "read-only still enforced, by pi-kit's copy");
	});
});

test("overlap: ours and pi-kit's notes send one reminder (pi-kit's)", { skip: noKit }, async () => {
	const f = fakePi();
	await notesIn(f);
	await withEnv({ PI_SUBAGENT_CHILD: undefined, PI_KIT_NOTES_REMIND_PERCENT: undefined }, async () => (await import(path.join(KIT, "notes/index.ts"))).default(f.api("pi-kit")));
	f.setPercent(80);
	await f.fire("turn_end", toolTurn); // ours first (-e), then pi-kit's, which sends
	await f.fire("turn_start");
	await f.fire("agent_end");
	assert.deepEqual(f.sent.map((m) => m.customType), ["pi-kit-notes"]);
});

test("overlap: ours and pi-kit's shell in one pi: ours steps back; pi-kit's tools, one /shells, and pi-kit's rows are the Shells panel", { skip: noKit }, async () => {
	await withEnv({ PI_KIT_READONLY: undefined, DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t", PI_CODING_AGENT_DIR: askConfig() }, async () => {
		const f = fakePi();
		(await import(`../extensions/panels/index.ts?${Math.random()}`)).default(f.api("deckhand"));
		await shellIn(f); // -e: first
		const kitShell = path.join(KIT, "shell/index.ts");
		(await import(kitShell)).default(f.api("pi-kit", kitShell));
		await f.fire("session_start");
		for (const name of ["bash_bg", "monitor", "wake_later", "shell_stop", "shell_list"]) assert.equal(f.tools.get(name)?.owner, "pi-kit", name);
		assert.deepEqual(f.commands.filter((c) => c.name === "shells").map((c) => c.owner), ["pi-kit"], "one /shells");
		assert.equal(f.notices.filter((n) => /Deckhand's shell stepped back/.test(n)).length, 1);
		f.events.emit(MODE_EVENT, true);
		await f.tools.get("bash_bg")!.tool.execute("1", { command: "sleep 5" }, undefined, undefined, f.ctx);
		f.events.emit("kit:sidebar", false); // pi-kit's shell refreshes on this
		const shells = f.emitted.filter(([e]) => e === PANELS_EVENT).at(-1)![1].find((p: any) => p.panel === "shells");
		assert.match(shells.rows[1]?.text ?? "", /^sh1 /, "pi-kit's task in the Shells panel");
		assert.equal(f.widgets.get("deckhand-shell"), undefined, "ours draws nothing");
		await f.fire("session_shutdown");
	});
});

// pi's own skill loader (PI_PACKAGE_DIR: an installed @earendil-works/pi-coding-agent; its library
// function only, never the pi program), in pi 1.5.0's order: package skills, then --skill paths.
const PI_PKG = process.env.PI_PACKAGE_DIR;
test("precedence: next to a package skill named desk (pi-kit's), pi loads deckhand-desk from --skill, with no collision", { skip: !PI_PKG || !existsSync(path.join(PI_PKG, "dist/core/skills.js")) ? "PI_PACKAGE_DIR not set" : false }, async () => {
	const { loadSkills } = await import(path.join(PI_PKG!, "dist/core/skills.js"));
	const tmp = mkdtempSync(path.join(TMP_ROOT, "deckhand-skills-"));
	const pkg = path.join(tmp, "pkg/skills/desk");
	mkdirSync(pkg, { recursive: true });
	writeFileSync(path.join(pkg, "SKILL.md"), "---\nname: desk\ndescription: pi-kit's desk skill (pi-desk)\n---\n# pi-desk\n");
	const ours = path.join(ROOT, "skills/deckhand-desk");
	const r = loadSkills({ cwd: tmp, agentDir: path.join(tmp, "agent"), includeDefaults: false, skillPaths: [path.join(tmp, "pkg/skills"), ours] });
	const byName = new Map(r.skills.map((x: any) => [x.name, x.filePath]));
	assert.equal(byName.get("deckhand-desk"), path.join(ours, "SKILL.md"), "ours loads");
	assert.equal(byName.get("desk"), path.join(pkg, "SKILL.md"), "the package's desk stays (a same-named --skill would lose to it)");
	assert.deepEqual(r.diagnostics.filter((d: any) => d.type === "collision"), []);
	// the rule this relies on: a same-named --skill (last) loses
	const same = path.join(tmp, "same/desk");
	mkdirSync(same, { recursive: true });
	writeFileSync(path.join(same, "SKILL.md"), "---\nname: desk\ndescription: x\n---\n");
	const r2 = loadSkills({ cwd: tmp, agentDir: path.join(tmp, "agent"), includeDefaults: false, skillPaths: [path.join(tmp, "pkg/skills"), path.join(tmp, "same")] });
	assert.equal(r2.skills.find((x: any) => x.name === "desk").filePath, path.join(pkg, "SKILL.md"));
});

// ---- shell rows: only ours, once ours are seen ----

test("shellRows: rows tagged as ours always count; untagged ones (pi-kit's shell) only until ours were seen", () => {
	const seen = { ours: false };
	const ours = (rows: object[]) => Object.assign(rows, { [Symbol.for("deckhand.shell.rows")]: true });
	assert.deepEqual(shellRows(seen, [{ id: "sh9" }]), [{ id: "sh9" }], "pi-kit's shell alone: its rows");
	assert.deepEqual([...shellRows(seen, ours([{ id: "sh1" }]))!], [{ id: "sh1" }]);
	assert.equal(shellRows(seen, []), undefined, "pi-kit's empty rows next to ours: ignored");
	assert.deepEqual([...shellRows(seen, ours([]))!], []);
	assert.deepEqual(shellRows(seen, "junk"), undefined);
});

test("shell: pi-kit's empty kit:shell:rows does not empty our Shells panel", async () => {
	const f = fakePi();
	await withEnv({ PI_KIT_READONLY: undefined, DECKHAND_SOCKET: "/nonexistent/x.sock", DECKHAND_TOKEN: "t", PI_CODING_AGENT_DIR: askConfig() }, async () => {
		(await import(`../extensions/panels/index.ts?${Math.random()}`)).default(f.api("deckhand"));
		await shellIn(f);
		await f.fire("session_start");
		f.events.emit(MODE_EVENT, true);
		await f.tools.get("bash_bg")!.tool.execute("1", { command: "sleep 5" }, undefined, undefined, f.ctx);
		f.events.emit(SHELL_ROWS_EVENT, []); // pi-kit's shell, refreshing on kit:sidebar
		const shells = f.emitted.filter(([e]) => e === PANELS_EVENT).at(-1)![1].find((p: any) => p.panel === "shells");
		assert.match(shells.rows[1]?.text ?? "", /^sh1 /);
		await f.fire("session_shutdown");
	});
});
