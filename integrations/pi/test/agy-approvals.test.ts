// Approvals for Antigravity (lib/agy-approvals.ts) in tabs (lib/antigravity.ts) and in the
// antigravity tool (lib/agy-delegate.ts), against the stand-in agy (test/fake-agy.mjs): never a real
// agy, pi or model. node --test test/agy-approvals.test.ts
import { assertTempData } from "./temp-home.ts"; // first: HOME and XDG_DATA_HOME in a temp folder
import "./typebox-stub.ts";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { agyEnv } from "../lib/acp.ts";
import { credentialPath, credentialsInCommand, decide, insideFolder, pathsOf, ToolCallTracker } from "../lib/agy-approvals.ts";
import { approvalsOf, dataRoot, updateAccounts } from "../lib/agy-accounts.ts";
import { createAntigravity } from "../lib/antigravity.ts";
import { piRules } from "./pi-rules.ts";

const TMP_ROOT = realpathSync(mkdtempSync(path.join(os.tmpdir(), "deckhand-agy-appr-")));
process.on("exit", () => rmSync(TMP_ROOT, { recursive: true, force: true }));
const FAKE = path.join(path.dirname(new URL(import.meta.url).pathname), "fake-agy.mjs");
chmodSync(FAKE, 0o755);
const HOME = process.env.HOME!;

let n = 0;
/** A project folder (with an optional project guardrails file), the stand-in's log and env. */
function project(guardrails?: unknown) {
	const cwd = mkdtempSync(path.join(TMP_ROOT, "proj-"));
	if (guardrails) {
		mkdirSync(path.join(cwd, ".pi"));
		writeFileSync(path.join(cwd, ".pi", "guardrails.json"), JSON.stringify(guardrails));
	}
	const log = path.join(TMP_ROOT, `log-${n++}.jsonl`);
	const read = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
	return { cwd, log, env: { ...agyEnv(), FAKE_AGY_LOG: log }, read };
}

/** A UI that records its dialogs and answers them from `answers` (confirm: true unless told). */
function fakeUi(answers: { confirm?: boolean[]; select?: (string | undefined)[]; input?: (string | undefined)[] } = {}) {
	const asked: { kind: string; title: string; body?: string; options?: string[] }[] = [];
	const ui = {
		confirm: async (title: string, body: string) => (asked.push({ kind: "confirm", title, body }), answers.confirm?.length ? answers.confirm.shift()! : true),
		select: async (title: string, options: string[]) => (asked.push({ kind: "select", title, options }), answers.select?.shift()),
		input: async (title: string) => (asked.push({ kind: "input", title }), answers.input?.shift()),
		notify: () => {},
	};
	return { ui, asked };
}

const SYS = { role: "system", content: "You are pi." };
let clock = 1_000;
const user = (text: string) => ({ role: "user", content: [{ type: "text", text }], timestamp: clock++ });
const MODEL = { id: "default", provider: "antigravity", api: "antigravity-acp" };
async function drive(stream: any) {
	for await (const _ of stream);
	return stream.result();
}
const textOf = (m: any) => m.content.filter((b: any) => b.type === "text").map((b: any) => b.text).join("");
const thinkingOf = (m: any) => m.content.filter((b: any) => b.type === "thinking").map((b: any) => b.thinking).join("");
/** The approval lines of the thinking (not agy's tool calls `→` or their failures). */
const notes = (m: any) => thinkingOf(m).split("\n").filter((l: string) => /^[✓✗?] /.test(l) && !/ failed$/.test(l));
/** agy's answers echoed by the stand-in, by shape: `run` → the outcome. */
const outcomes = (m: any) => textOf(m).split("\n").map((l) => /^(\w+):(.*)$/.exec(l)!).map(([, k, v]) => [k, JSON.parse(v)?.outcome]);

/** A tab's provider in `p.cwd` with the given approvals context; one turn per call. */
function tab(p: ReturnType<typeof project>, ctx: { hasUI?: boolean; ui?: any; readonly?: boolean; mode?: "allow" | "ask" } = {}) {
	const ag = createAntigravity({
		agyPath: FAKE,
		cwd: () => p.cwd,
		env: p.env,
		approvals: () => ({ cwd: p.cwd, hasUI: ctx.hasUI ?? !!ctx.ui, ui: ctx.ui, readonly: ctx.readonly ?? false, mode: ctx.mode ?? "allow" }),
	});
	let k = 0;
	const turn = (text: string, signal?: AbortSignal) => drive(ag.provider.streamSimple(MODEL, { messages: [SYS, user(text)] }, { sessionId: `s${k++}`, signal }));
	return { ag, turn };
}

after(() => assertTempData());

test("default: each request answered with agy's allow_once, never allow_always; what ran is shown in the thinking", async () => {
	const p = project();
	const { ag, turn } = tab(p);
	try {
		const msg = await turn(`run: npm test\nedit: ${p.cwd}/src/a.ts\nwrite: notes.md\nread: ${p.cwd}/README.md\nmcp:`);
		assert.deepEqual(outcomes(msg), [
			["run", { outcome: "selected", optionId: "once" }],
			["edit", { outcome: "selected", optionId: "once" }],
			["write", { outcome: "selected", optionId: "once" }],
			["read", { outcome: "selected", optionId: "once" }],
			["mcp", { outcome: "selected", optionId: "once" }],
		]);
		const th = thinkingOf(msg);
		assert.match(th, /✓ ran: npm test\n/);
		assert.match(th, /✓ allowed: edit a\.ts\n/);
		assert.match(th, /✓ allowed: edit notes\.md\n/, "a relative path is the tab's folder");
		assert.match(th, /✓ allowed: Run view_file\?\n/);
		const answers = p.read().filter((m) => m.method === undefined && m.id >= 1000);
		assert.equal(answers.length, 5);
		assert.ok(answers.every((a) => !JSON.stringify(a).includes('"always"')), "never the standing grant");
	} finally {
		await ag.closeAll();
	}
});

test("a request offering no allow_once is rejected (never allow_always); agy asking to leave default mode is rejected", async () => {
	const p = project();
	const { ag, turn } = tab(p);
	try {
		const msg = await turn("alwaysonly: ls\nswitchmode:");
		assert.deepEqual(outcomes(msg), [
			["alwaysonly", { outcome: "selected", optionId: "deny" }],
			["switchmode", { outcome: "selected", optionId: "deny" }],
		]);
		assert.match(thinkingOf(msg), /✗ refused \(agy offered no one-time approval\): run_command\n/);
		assert.match(thinkingOf(msg), /✗ refused \(Deckhand keeps Antigravity in its default mode\): Switch to auto mode\?\n/);
	} finally {
		await ag.closeAll();
	}
});

test("guardrails: a block rule rejects the command; an ask rule confirms it (yes runs, no rejects) and rejects without a UI", async () => {
	const p = project({ rules: [{ name: "nuke", pattern: "rm -rf", action: "block" }, { name: "pub", pattern: "npm publish", action: "ask", reason: "publishes a package" }] });
	const { ui, asked } = fakeUi({ confirm: [true, false] });
	const withUi = tab(p, { ui });
	const headless = tab(p, { hasUI: false });
	try {
		const msg = await withUi.turn("run: rm -rf build\nrun: npm publish\nrun: npm publish --tag x\nrun: ls");
		assert.deepEqual(outcomes(msg).map(([, o]) => o.optionId), ["deny", "once", "deny", "once"]);
		assert.deepEqual(asked.map((a) => [a.kind, a.title]), [["confirm", "Allow this Antigravity command?"], ["confirm", "Allow this Antigravity command?"]], "one confirm per ask-rule command, none for the others");
		assert.match(asked[0].body!, /npm publish\n\nReason: publishes a package/);
		const th = thinkingOf(msg);
		assert.match(th, /✗ blocked by guardrails: rm -rf build\n/);
		assert.match(th, /✓ you allowed: npm publish\n/);
		assert.match(th, /✗ you declined: npm publish --tag x\n/);
		assert.match(th, /✓ ran: ls\n/);
		const h = await headless.turn("run: npm publish\nrun: ls");
		assert.deepEqual(outcomes(h).map(([, o]) => o.optionId), ["deny", "once"]);
		assert.match(thinkingOf(h), /✗ refused \(guardrails asks, and no UI\): npm publish\n/);
	} finally {
		await withUi.ag.closeAll();
		await headless.ag.closeAll();
	}
});

test("a command named by id only is judged by its tool call (agy's tool_call update)", async () => {
	const p = project({ rules: [{ name: "nuke", pattern: "rm -rf", action: "block" }] });
	const { ag, turn } = tab(p);
	try {
		const msg = await turn("idonly: rm -rf build\nidonly: ls");
		assert.deepEqual(outcomes(msg).map(([, o]) => o.optionId), ["deny", "once"]);
		assert.deepEqual(notes(msg), ["✗ blocked by guardrails: rm -rf build", "✓ ran: ls"]);
	} finally {
		await ag.closeAll();
	}
});

test("read-only sessions: edits, mutating commands and other tools rejected; reads and plain commands allowed", async () => {
	const p = project();
	const { ag, turn } = tab(p, { readonly: true, ui: fakeUi().ui });
	try {
		const msg = await turn(`edit: ${p.cwd}/a.ts\nwrite: b.md\nrun: rm build.log\nrun: echo hi > out.txt\nmcp:\nrun: git status\nread: ${p.cwd}/README.md`);
		assert.deepEqual(outcomes(msg).map(([, o]) => o.optionId), ["deny", "deny", "deny", "deny", "deny", "once", "once"]);
		assert.equal((thinkingOf(msg).match(/✗ refused \(read-only session\)/g) ?? []).length, 5);
	} finally {
		await ag.closeAll();
	}
});

test("edits outside the tab's folder are confirmed with a UI (the folder named), rejected without one; a symlink out of the folder counts as outside", async () => {
	const p = project();
	const elsewhere = mkdtempSync(path.join(TMP_ROOT, "elsewhere-"));
	symlinkSync(elsewhere, path.join(p.cwd, "link"));
	const { ui, asked } = fakeUi({ confirm: [true, false] });
	const withUi = tab(p, { ui });
	const headless = tab(p);
	try {
		const msg = await withUi.turn(`edit: ${elsewhere}/x.ts\nedit: ${p.cwd}/link/y.ts\nedit: ${p.cwd}/inside.ts`);
		assert.deepEqual(outcomes(msg).map(([, o]) => o.optionId), ["once", "deny", "once"]);
		assert.equal(asked.length, 2, "the edit inside is not asked");
		assert.match(asked[0].title, /outside the tab's folder/);
		assert.ok(asked[0].body!.includes(`The tab's folder: ${p.cwd}`));
		assert.deepEqual(notes(msg), ["✓ you allowed: edit x.ts (outside the tab's folder)", "✗ you declined: edit y.ts (outside the tab's folder)", "✓ allowed: edit inside.ts"]);
		const h = await headless.turn(`edit: ${elsewhere}/x.ts\nwrite: ../up.md`);
		assert.deepEqual(outcomes(h).map(([, o]) => o.optionId), ["deny", "deny"]);
		assert.match(thinkingOf(h), /✗ refused \(outside the tab's folder, and no UI to ask\)/);
	} finally {
		await withUi.ag.closeAll();
		await headless.ag.closeAll();
	}
});

test("credential files: a read, an edit or a command naming one is rejected, even in ask mode with a yes", async () => {
	const p = project();
	const agent = path.join(HOME, ".pi", "agent");
	mkdirSync(agent, { recursive: true });
	writeFileSync(path.join(agent, "auth.json"), "{}", { mode: 0o600 });
	const profile = path.join(dataRoot(), "profiles", "default", "antigravity-acp");
	const { ui, asked } = fakeUi();
	const { ag, turn } = tab(p, { ui, mode: "ask" });
	try {
		const msg = await turn(
			[`read: ${agent}/auth.json`, `read: ${profile}/acp_token.json`, `edit: ${HOME}/.claude/.credentials.json`, "run: cat ~/.pi/agent/auth.json", `run: cp $HOME/.codex/auth.json /tmp/x`, `read: ${agent}/settings.json`].join("\n"),
		);
		assert.deepEqual(outcomes(msg).map(([, o]) => o.optionId), ["deny", "deny", "deny", "deny", "deny", "once"]);
		assert.equal(asked.length, 1, "only the settings read is asked (ask mode); credentials are never offered");
		const th = thinkingOf(msg);
		assert.equal((th.match(/✗ refused \(a protected credential file\)/g) ?? []).length, 3);
		assert.equal((th.match(/✗ refused \(the command names a protected credential file\)/g) ?? []).length, 2);
	} finally {
		await ag.closeAll();
	}
});

test("credentialPath mirrors the core's names (pi's sign-ins and private files, Claude's, Codex's) plus agy's tokens; ordinary files pass", () => {
	const env = { HOME: "/Users/u", PI_CODING_AGENT_DIR: undefined } as any;
	for (const p of ["/Users/u/.pi/agent/auth.json", "/Users/u/.pi/agent/AUTH.JSON", "/Users/u/.pi/agent/models-store.json", "/Users/u/.pi/agent/cursor-sdk-x.json", "/Users/u/.pi/agent/intercom/a", "/x/.credentials.json", "/x/.claude.json", "/x/.claude.json.backup", "/Users/u/.codex/auth.json", "/p/antigravity-acp/acp_token.json", "/Users/u/.gemini/oauth_creds.json"])
		assert.equal(credentialPath(p, env), true, p);
	for (const p of ["/Users/u/.pi/agent/settings.json", "/Users/u/project/auth.json", "/Users/u/project/README.md", "/Users/u/.claude/CLAUDE.md"]) assert.equal(credentialPath(p, env), false, p);
	assert.equal(credentialPath("/h/codex/auth.json", { ...env, CODEX_HOME: "/h/codex" }), true, "CODEX_HOME's sign-in");
	assert.deepEqual(credentialsInCommand("cat ~/.pi/agent/auth.json | head", "/w", env), ["~/.pi/agent/auth.json"]);
	assert.deepEqual(credentialsInCommand('jq . "$HOME/.claude.json"', "/w", env), ["/Users/u/.claude.json"]);
	assert.deepEqual(credentialsInCommand("npm test -- --grep auth", "/w", env), []);
});

test("credentialPath guards every agy profile as the core does: Deckhand's profiles whole, a folder used in place, agy's default ~/.gemini and any marked folder, all but GEMINI.md, AGENTS.md and skills", () => {
	const home = mkdtempSync(path.join(TMP_ROOT, "home-"));
	const env = { HOME: home } as any;
	const root = dataRoot(env);
	const own = mkdtempSync(path.join(TMP_ROOT, "own-profile-"));
	mkdirSync(root, { recursive: true });
	writeFileSync(path.join(root, "accounts.json"), JSON.stringify({ accounts: [{ name: "mine", method: "oauth-personal", dir: own, source: "added" }] }));
	const gem = path.join(home, ".gemini");
	mkdirSync(path.join(gem, "antigravity"), { recursive: true });
	writeFileSync(path.join(gem, "antigravity", "installation_id"), "x");
	const marked = mkdtempSync(path.join(TMP_ROOT, "marked-"));
	mkdirSync(path.join(marked, "antigravity-acp"));
	writeFileSync(path.join(marked, "antigravity-acp", "installation_id"), "x");
	for (const p of [path.join(root, "profiles", "default", "GEMINI.md"), path.join(root, "profiles", "x", "antigravity", "brain", "a.md"), path.join(own, "antigravity", "conversations", "c.pb"), path.join(own, "settings.json"), path.join(gem, "antigravity", "brain", "t.md"), path.join(gem, "settings.json"), path.join(marked, "history.db")])
		assert.equal(credentialPath(p, env), true, p);
	for (const p of [path.join(own, "GEMINI.md"), path.join(own, "AGENTS.md"), path.join(own, "config", "skills", "s", "SKILL.md"), path.join(gem, "antigravity-cli", "skills", "x.md"), path.join(gem, "config", "skills.json"), path.join(marked, "AGENTS.md"), path.join(home, "project", "a.ts")])
		assert.equal(credentialPath(p, env), false, p);
});

test("approvals in accounts.json: kept through another writer's change (the core's fields, unknown keys), read by approvalsOf", async () => {
	const home = mkdtempSync(path.join(TMP_ROOT, "home-"));
	const root = dataRoot({ HOME: home } as any);
	mkdirSync(root, { recursive: true });
	const file = path.join(root, "accounts.json");
	// as the core writes it: its own fields, one we do not know, and our approvals
	writeFileSync(file, JSON.stringify({ defaultAccount: "work", accounts: [{ name: "work", method: "oauth-personal", label: "Work", storage: "file", coreOnly: 1, approvals: "ask" }] }));
	assert.equal(approvalsOf(root, "work"), "ask");
	await updateAccounts(root, (accounts) => ({ accounts: accounts.map((a) => ({ ...a, label: "Work 2" })) }));
	const after = JSON.parse(readFileSync(file, "utf8"));
	assert.deepEqual(after.accounts, [{ name: "work", method: "oauth-personal", label: "Work 2", storage: "file", coreOnly: 1, approvals: "ask" }]);
	assert.equal(after.defaultAccount, "work");
	await updateAccounts(root, (accounts) => ({ accounts: accounts.map((a) => ({ ...a, approvals: undefined })) }));
	assert.equal(JSON.parse(readFileSync(file, "utf8")).accounts[0].approvals, undefined);
	assert.equal(approvalsOf(root, "work"), "allow");
});

test("pathsOf: locations, diffs and agy's path fields; a part without a readable path makes them unknown", () => {
	assert.deepEqual(pathsOf({ locations: [{ path: "/a" }], content: [{ type: "diff", path: "/b" }], rawInput: { TargetFile: "/c", AbsolutePath: "/a" } }).sort(), ["/a", "/b", "/c"]);
	assert.equal(pathsOf({ locations: [{ line: 3 }] }), "unknown");
	assert.deepEqual(pathsOf({ title: "x" }), []);
	const root = mkdtempSync(path.join(TMP_ROOT, "in-"));
	assert.equal(insideFolder(["a/b.ts", `${root}/c`], root), true);
	assert.equal(insideFolder(["../x"], root), false);
	assert.equal(insideFolder([], root), false, "a change that names no file is not known to be inside");
});

test("questions (ask_question) go through select with agy's options; dismissed or without a UI, cancelled", async () => {
	const p = project();
	const { ui, asked } = fakeUi({ select: ["b.ts", undefined] });
	const withUi = tab(p, { ui });
	const headless = tab(p);
	try {
		const q = await withUi.turn("question");
		assert.equal(textOf(q), 'question:{"outcome":{"outcome":"selected","optionId":"b"}}');
		assert.deepEqual(asked[0], { kind: "select", title: "Antigravity asks: Which file?", options: ["a.ts", "b.ts"] });
		assert.match(thinkingOf(q), /\? Which file\? → b\.ts\n/);
		const dismissed = await withUi.turn("question");
		assert.equal(textOf(dismissed), 'question:{"outcome":{"outcome":"cancelled"}}');
		const h = await headless.turn("question");
		assert.equal(textOf(h), 'question:{"outcome":{"outcome":"cancelled"}}');
		assert.match(thinkingOf(h), /✗ question not answered \(no UI\): Which file\?/);
	} finally {
		await withUi.ag.closeAll();
		await headless.ag.closeAll();
	}
});

test("form elicitations: a select per choice, yes/no for a boolean, an input for text and numbers; declined without a UI", async () => {
	const p = project();
	const { ui, asked } = fakeUi({ select: ["blue", "Yes"], input: ["3"] });
	const withUi = tab(p, { ui });
	const headless = tab(p);
	try {
		const e = await withUi.turn("elicitpick");
		assert.equal(textOf(e), 'elicit:{"action":"accept","content":{"color":"blue","sure":true,"n":3}}');
		assert.deepEqual(asked.map((a) => [a.kind, a.title]), [["select", "Antigravity asks: Which color?"], ["select", "Antigravity asks: Sure?"], ["input", "Antigravity asks: How many?"]]);
		const plain = await withUi.turn("elicit");
		assert.equal(textOf(plain), 'elicit:{"action":"cancel"}', "the input dismissed (no answer left)");
		const h = await headless.turn("elicit");
		assert.equal(textOf(h), 'elicit:{"action":"decline"}');
	} finally {
		await withUi.ag.closeAll();
		await headless.ag.closeAll();
	}
});

test("ask mode: every action is confirmed (no means rejected); without a UI every action is rejected", async () => {
	const p = project();
	const { ui, asked } = fakeUi({ confirm: [true, true, false, true] });
	const withUi = tab(p, { ui, mode: "ask" });
	const headless = tab(p, { mode: "ask" });
	try {
		const msg = await withUi.turn(`run: ls\nedit: ${p.cwd}/a.ts\nread: ${p.cwd}/README.md\nmcp:`);
		assert.deepEqual(outcomes(msg).map(([, o]) => o.optionId), ["once", "once", "deny", "once"]);
		assert.equal(asked.length, 4);
		assert.deepEqual(notes(msg), ["✓ you allowed: ls", "✓ you allowed: edit a.ts", "✗ you declined: Run view_file?", "✓ you allowed: MCP Tool deploy?"]);
		const h = await headless.turn(`run: ls\nedit: ${p.cwd}/a.ts\nread: ${p.cwd}/README.md`);
		assert.deepEqual(outcomes(h).map(([, o]) => o.optionId), ["deny", "deny", "deny"]);
		assert.equal((thinkingOf(h).match(/refused \(approvals: ask, and no UI\)/g) ?? []).length, 3);
	} finally {
		await withUi.ag.closeAll();
		await headless.ag.closeAll();
	}
});

test("an abort while a dialog is open dismisses it and answers the request cancelled", async () => {
	const p = project();
	const ac = new AbortController();
	let seen: AbortSignal | undefined;
	const ui = {
		...fakeUi().ui,
		confirm: (_t: string, _b: string, o?: { signal?: AbortSignal }) =>
			new Promise<boolean>((resolve) => {
				seen = o?.signal;
				o?.signal?.addEventListener("abort", () => resolve(false));
				setTimeout(() => ac.abort(), 30);
			}),
	};
	const decision = await decide("session/request_permission", { toolCall: { toolCallId: "c", kind: "execute", rawInput: { CommandLine: "ls" } }, options: [{ optionId: "once", kind: "allow_once" }, { optionId: "deny", kind: "reject_once" }] }, { cwd: p.cwd, hasUI: true, ui, readonly: false, mode: "ask", signal: ac.signal });
	assert.equal(seen, ac.signal, "the dialog gets the turn's signal");
	assert.deepEqual(decision.answer, { result: { outcome: { outcome: "cancelled" } } });
	assert.equal(decision.allowed, false);
});

test("ToolCallTracker: an id-only request takes the tracked call's kind, input and paths; a finished call is forgotten", () => {
	const t = new ToolCallTracker();
	t.track({ sessionId: "s", update: { sessionUpdate: "tool_call", toolCallId: "c", kind: "edit", title: "Run edit_file?", locations: [{ path: "/w/a.ts" }] } });
	t.track({ sessionId: "s", update: { sessionUpdate: "tool_call_update", toolCallId: "c", rawInput: { TargetFile: "/w/b.ts" } } });
	const got = t.withTracked("session/request_permission", { sessionId: "s", toolCall: { toolCallId: "c" } });
	assert.equal(got.toolCall.kind, "edit");
	assert.deepEqual(pathsOf(got.toolCall).sort(), ["/w/a.ts", "/w/b.ts"]);
	const own = t.withTracked("session/request_permission", { sessionId: "s", toolCall: { toolCallId: "c", kind: "read" } });
	assert.equal(own.toolCall.kind, "read", "the request's own fields win");
	assert.ok(pathsOf(own.toolCall).includes("/w/a.ts"), "but the tracked paths are added");
	assert.equal(t.withTracked("session/request_permission", { sessionId: "other", toolCall: { toolCallId: "c" } }).toolCall.kind, undefined, "another session's call");
	t.track({ sessionId: "s", update: { sessionUpdate: "tool_call_update", toolCallId: "c", status: "completed" } });
	assert.equal(t.withTracked("session/request_permission", { sessionId: "s", toolCall: { toolCallId: "c" } }).toolCall.kind, undefined);
});

// ---- the extension: the antigravity tool and /antigravity approvals ----

async function withEnv<T>(env: Record<string, string | undefined>, f: () => Promise<T>): Promise<T> {
	const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
	for (const [k, v] of Object.entries(env)) v === undefined ? delete process.env[k] : (process.env[k] = v);
	try {
		return await f();
	} finally {
		for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : (process.env[k] = v);
	}
}
const loaded: any[] = [];
after(async () => {
	for (const pi of loaded) await pi.fire("session_shutdown");
});

test("the antigravity tool follows the same policy (the caller's UI, folder and the account's mode); /antigravity approvals sets the mode in accounts.json", async () => {
	const p = project({ rules: [{ name: "nuke", pattern: "rm -rf", action: "block" }, { name: "pub", pattern: "npm publish", action: "ask" }] });
	const home = mkdtempSync(path.join(TMP_ROOT, "home-"));
	const bin = mkdtempSync(path.join(TMP_ROOT, "bin-"));
	symlinkSync(FAKE, path.join(bin, "agy"));
	const env = { HOME: home, XDG_DATA_HOME: path.join(home, ".local", "share"), PATH: [bin, process.env.PATH].join(path.delimiter), FAKE_AGY_LOG: p.log };
	await withEnv(env, async () => {
		const root = dataRoot();
		assert.ok(root.startsWith(home + path.sep));
		mkdirSync(path.join(root, "profiles", "default", "antigravity-acp"), { recursive: true });
		writeFileSync(path.join(root, "profiles", "default", "antigravity-acp", "acp_token.json"), "{}");
		const pi = piRules();
		loaded.push(pi);
		const mod = await import(`../extensions/antigravity/index.ts?${Math.random()}`);
		await pi.load(path.join(path.dirname(FAKE), "..", "extensions", "antigravity"), mod.default);
		await pi.start();
		const tool = pi.extensions[0].tools.get("antigravity");
		const run = (args: string, ctx: any) => pi.extensions[0].commands.get("antigravity").handler(args, ctx);
		const { ui, asked } = fakeUi();
		const notes: string[] = [];
		const withUi = { ...pi.ctx, cwd: p.cwd, hasUI: true, ui: { ...ui, notify: (m: string) => void notes.push(m), setStatus: () => {} } };
		const headless = { ...pi.ctx, cwd: p.cwd, hasUI: false };

		const a = await tool.execute("t1", { task: "run: rm -rf build\nrun: npm publish\nrun: ls" }, undefined, () => {}, headless);
		const out = a.content[0].text;
		assert.match(out, /^run:.*"optionId":"deny".*\nrun:.*"optionId":"deny".*\nrun:.*"optionId":"once"/);
		assert.match(out, /Refused: blocked by guardrails: rm -rf build; refused \(guardrails asks, and no UI\): npm publish/);
		const b = await tool.execute("t2", { task: "run: npm publish" }, undefined, () => {}, withUi);
		assert.match(b.content[0].text, /"optionId":"once"/, "with a UI, the ask rule is confirmed");
		assert.equal(asked.length, 1);

		await run("approvals ask", withUi);
		assert.match(notes.at(-1)!, /every action agy asks to take is confirmed first/);
		const saved = JSON.parse(readFileSync(path.join(root, "accounts.json"), "utf8"));
		assert.deepEqual(saved.accounts, [{ name: "default", method: "oauth-personal", approvals: "ask" }]);
		const c = await tool.execute("t3", { task: "run: ls" }, undefined, () => {}, headless);
		assert.match(c.content[0].text, /"optionId":"deny"/, "ask mode, no UI: refused");
		await run("approvals", withUi);
		assert.match(notes.at(-1)!, /- default: ask/);
		await run("approvals allow default", withUi);
		assert.equal(JSON.parse(readFileSync(path.join(root, "accounts.json"), "utf8")).accounts[0].approvals, undefined, "allow is the default: not written");
		const d = await tool.execute("t4", { task: "run: ls" }, undefined, () => {}, headless);
		assert.match(d.content[0].text, /"optionId":"once"/);
		await run("approvals sometimes", withUi);
		assert.match(notes.at(-1)!, /neither a mode nor an account/);
	});
});
