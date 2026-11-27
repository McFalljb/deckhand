// The Antigravity extension (extensions/antigravity, lib/acp.ts, lib/agy.ts) against a stand-in agy
// (test/fake-agy.mjs): never a real agy, pi or model. node --test test/antigravity.test.ts
import { assertTempData } from "./temp-home.ts"; // first: HOME and XDG_DATA_HOME in a temp folder
import assert from "node:assert/strict";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { AcpConnection, agyEnv, agyTooOld, answerAgentRequest, CLIENT_INFO, findAgy, initializeParams, parseAgyVersion, SignInRequired, signInLink } from "../lib/acp.ts";
import { AgySession, modelsOf, probeModels, SIGN_IN_HINT } from "../lib/agy.ts";
import { agyEnvFor, dataRoot, linkUserConfig, PLANS_URL, profileOf } from "../lib/agy-accounts.ts";
import { agyLogin, CODE_REDIRECT_URI, linkInLine, loginAnswer, parseSignInLink } from "../lib/agy-login.ts";
import { createAntigravity, planTurn, RETRY_NOTE, SUMMARY_TEXT } from "../lib/antigravity.ts";
import { NOT_FOUND } from "../extensions/antigravity/index.ts";
import { piRules } from "./pi-rules.ts";

const TMP_ROOT = mkdtempSync(path.join(os.tmpdir(), "deckhand-agy-test-"));
process.on("exit", () => rmSync(TMP_ROOT, { recursive: true, force: true }));
const FAKE = path.join(path.dirname(new URL(import.meta.url).pathname), "fake-agy.mjs");
chmodSync(FAKE, 0o755);
// the stand-in as `agy` on a PATH of its own (no environment variable picks agy's binary)
const AGY_BIN = mkdtempSync(path.join(TMP_ROOT, "agy-bin-"));
const AGY = path.join(AGY_BIN, "agy");
symlinkSync(FAKE, AGY);
const PATH_WITH_AGY = [AGY_BIN, process.env.PATH ?? ""].join(path.delimiter);

let n = 0;
/** A fresh log file and the env the stand-in runs with. */
function fake(extra: Record<string, string> = {}) {
	const log = path.join(TMP_ROOT, `log-${n++}.jsonl`);
	const env = { ...agyEnv(), FAKE_AGY_LOG: log, ...extra };
	const read = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
	return { env, log, read, cwd: TMP_ROOT };
}
const methods = (msgs: any[]) => msgs.filter((m) => m.method).map((m) => m.method);

// ---- step 1: the ACP client and the stand-in ----

test("agy versions: parse agy's forms; below 1.5.1 is too old; unparseable is not", () => {
	assert.deepEqual(parseAgyVersion("agy_acp_server_1.5.12"), [1, 5, 12]);
	assert.deepEqual(parseAgyVersion("v1.6.0"), [1, 6, 0]);
	assert.equal(parseAgyVersion("dev"), undefined);
	assert.equal(agyTooOld("agy_acp_server_1.5.0"), true);
	assert.equal(agyTooOld("agy_acp_server_1.1.1"), true);
	assert.equal(agyTooOld("1.5.1"), false);
	assert.equal(agyTooOld("2.0.0"), false);
	assert.equal(agyTooOld(undefined), false);
});

test("findAgy: the path setting when it is an absolute executable, else agy on PATH (finding 5: never `antigravity`, which may be the IDE's launcher); never relative", () => {
	const dir = mkdtempSync(path.join(TMP_ROOT, "bin-"));
	const other = mkdtempSync(path.join(TMP_ROOT, "bin-"));
	const mk = (d: string, name: string, mode = 0o755) => {
		const p = path.join(d, name);
		writeFileSync(p, "#!/bin/sh\n");
		chmodSync(p, mode);
		return p;
	};
	assert.equal(findAgy({ PATH: dir }), undefined, "nothing installed");
	const anti = mk(other, "antigravity");
	assert.equal(findAgy({ PATH: [dir, other].join(path.delimiter) }), undefined, "`antigravity` alone is not agy");
	const agy = mk(other, "agy");
	assert.equal(findAgy({ PATH: [dir, other].join(path.delimiter) }), agy, "agy");
	mk(dir, "agy", 0o644);
	assert.equal(findAgy({ PATH: [dir, other].join(path.delimiter) }), agy, "not executable: skipped");
	assert.equal(findAgy({ PATH: "relative/bin" }), undefined);
	assert.equal(findAgy({ PATH: other }, FAKE), FAKE, "the setting");
	assert.equal(findAgy({ PATH: dir }, anti), anti, "`antigravity` only when set by /antigravity path");
	assert.equal(findAgy({ PATH: dir }, "fake-agy.mjs"), undefined, "a relative setting is not looked up");
	assert.equal(findAgy({ PATH: other }, path.join(dir, "missing")), agy, "an unusable setting: PATH's");
	assert.equal(findAgy({ PATH: other, DECKHAND_AGY_PATH: FAKE }), agy, "no environment variable picks the binary");
	assert.deepEqual(Object.keys(agyEnv({ DECKHAND_TOKEN: "t", DECKHAND_SOCKET: "s", HOME: "/h" })), ["HOME"], "Deckhand's variables stay out of agy");
});

test("initialize: deckhand-pi's own identity, no fs and no terminal", () => {
	const p = initializeParams();
	assert.equal(p.clientInfo.name, "deckhand-pi");
	assert.deepEqual(p.clientInfo, CLIENT_INFO);
	assert.deepEqual(p.clientCapabilities, { fs: { readTextFile: false, writeTextFile: false }, terminal: false });
	assert.ok(!/t3|antigravity/i.test(JSON.stringify(p)), "claims to be nobody else");
});

test("requests agy makes of the client: permissions rejected (reject_once, else cancelled), questions and elicitations declined, the rest not found", () => {
	const perm = { toolCall: { toolCallId: "call_1" }, options: [{ optionId: "a", kind: "allow_once" }, { optionId: "aa", kind: "allow_always" }, { optionId: "r", kind: "reject_once" }] };
	assert.deepEqual(answerAgentRequest("session/request_permission", perm).result, { outcome: { outcome: "selected", optionId: "r" } });
	assert.deepEqual(answerAgentRequest("session/request_permission", { toolCall: { toolCallId: "c" }, options: [{ optionId: "a", kind: "allow_once" }] }).result, { outcome: { outcome: "cancelled" } });
	const q = { toolCall: { toolCallId: "interaction_1" }, options: [{ optionId: "x", kind: "reject_once" }] };
	assert.deepEqual(answerAgentRequest("session/request_permission", q).result, { outcome: { outcome: "cancelled" } }, "a question's choices are never picked");
	for (const m of ["session/elicitation", "_session/elicitation", "elicitation/create"]) assert.deepEqual(answerAgentRequest(m, {}).result, { action: "decline" });
	for (const m of ["fs/read_text_file", "fs/write_text_file", "terminal/create", "x/y"]) assert.equal(answerAgentRequest(m, {}).error?.code, -32601);
	assert.equal(signInLink("Open the following link to authenticate the ACP server: https://accounts.google.com/x"), "https://accounts.google.com/x");
	assert.equal(signInLink('{"jsonrpc":"2.0"}'), undefined);
});

test("startup: initialize, authenticate (oauth-personal by default), session/new, default mode; models from the config option; nothing else sent", async () => {
	const f = fake();
	const s = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env });
	try {
		assert.match(s.sessionId, /^sess-/);
		assert.equal(s.agentVersion, "agy_acp_server_1.5.12");
		assert.deepEqual(s.models.map((m) => m.id), ["gemini-3.8-pro", "gemini-3.8-flash"], "groups flattened");
		assert.deepEqual(s.thinkingLevels, ["low", "high"]);
		const msgs = f.read();
		assert.deepEqual(msgs[0].argv, ["acp"]);
		assert.deepEqual(msgs[0].deckhandEnv, []);
		assert.deepEqual(methods(msgs), ["initialize", "authenticate", "session/new", "session/set_config_option"]);
		assert.deepEqual(msgs.find((m) => m.method === "authenticate").params, { methodId: "oauth-personal" }, "up front, as t3code: agy picks its credential source from the method");
		const init = msgs.find((m) => m.method === "initialize");
		assert.equal(init.params.clientInfo.name, "deckhand-pi");
		assert.deepEqual(init.params.clientCapabilities, { fs: { readTextFile: false, writeTextFile: false }, terminal: false });
		assert.deepEqual(msgs.find((m) => m.method === "session/new").params, { cwd: f.cwd, mcpServers: [] });
		assert.deepEqual(msgs.find((m) => m.method === "session/set_config_option").params, { sessionId: s.sessionId, configId: "mode", value: "default" }, "agy's `default` mode (it starts in auto)");
	} finally {
		await s.close();
	}
	assert.equal(methods(f.read()).at(-1), "session/close");
});


test("finding 6: a session whose default mode cannot be confirmed is refused, new or resumed; so is a model agy offers no choice of", async () => {
	for (const knob of ["FAKE_AGY_NO_MODE_AT_ALL", "FAKE_AGY_MODE_STUCK"]) {
		const f = fake({ [knob]: "1" });
		await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env }), /cannot confirm that Antigravity runs in its default mode/, knob);
		assert.ok(!methods(f.read()).includes("session/prompt"));
	}
	const r = fake({ FAKE_AGY_RESUME_NO_MODES: "1" });
	const first = await AgySession.open({ agyPath: FAKE, cwd: r.cwd, env: r.env });
	await first.close();
	await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: r.cwd, env: r.env, resumeId: first.sessionId }), /cannot confirm that Antigravity runs in its default mode/, "after a resume too");
	const m = fake({ FAKE_AGY_NO_MODEL_OPTION: "1" });
	const s = await AgySession.open({ agyPath: FAKE, cwd: m.cwd, env: m.env });
	try {
		await s.selectModel("default"); // agy's own pick: fine
		await assert.rejects(s.selectModel("gemini-3.8-pro"), /offers no model choice.*gemini-3\.8-pro.*default model/);
	} finally {
		await s.close();
	}
});

test("startup without a mode config option: session/set_mode default", async () => {
	const f = fake({ FAKE_AGY_NO_MODES: "1" });
	const s = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env });
	await s.close();
	const set = f.read().find((m) => m.method === "session/set_mode");
	assert.deepEqual(set?.params, { sessionId: s.sessionId, modeId: "default" });
});

test("version refusal: agy older than 1.5.1 is stopped after initialize, with what to do", async () => {
	const f = fake({ FAKE_AGY_VERSION: "agy_acp_server_1.5.0" });
	await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env }), /1\.5\.0 is older than 1\.5\.1.*update agy \(1\.5\.12/);
	assert.deepEqual(methods(f.read()), ["initialize"], "no session started");
});

test("sign-in: the method is always passed to authenticate; a sign-in link, auth_required or agy's 'No browser' answer mean the account's sign-in command", async () => {
	const out = fake({ FAKE_AGY_SIGNED_OUT: "1" });
	const t0 = Date.now();
	await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: out.cwd, env: out.env }), (e: any) => e instanceof SignInRequired && e.message === SIGN_IN_HINT);
	assert.ok(Date.now() - t0 < 10_000, "does not wait for a browser");
	assert.deepEqual(methods(out.read()), ["initialize", "authenticate"], "no session without a sign-in");
	const ssh = fake({ FAKE_AGY_SIGNED_OUT: "1", SSH_CONNECTION: "127.0.0.1 0 127.0.0.1 0" });
	await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: ssh.cwd, env: ssh.env, signInHint: "run /antigravity login work" }), (e: any) => e instanceof SignInRequired && e.message === "run /antigravity login work");
	const key = fake({ GEMINI_API_KEY: "k-123" });
	const s = await AgySession.open({ agyPath: FAKE, cwd: key.cwd, env: key.env, authMethod: "gemini-api-key" });
	await s.close();
	assert.deepEqual(key.read().find((m) => m.method === "authenticate").params, { methodId: "gemini-api-key" });
	const nokey = fake();
	await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: nokey.cwd, env: nokey.env, authMethod: "gemini-api-key" }), /No GEMINI_API_KEY \(authenticate\)/);
});

test("prompt and streaming: thoughts, tool calls, plan and text arrive as session/update before the turn's response; model and thinking by config option", async () => {
	const f = fake();
	const updates: any[] = [];
	const s = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env, onUpdate: (p) => updates.push(p.update) });
	try {
		await s.selectModel("gemini-3.8-flash");
		await s.selectThinking("low");
		await s.selectThinking("xhigh"); // agy has no such level: left alone
		const r = await s.prompt([{ type: "text", text: "hello" }]);
		assert.equal(r.stopReason, "end_turn");
		assert.equal(r.usage.inputTokens, 1200);
		assert.deepEqual(updates.map((u) => u.sessionUpdate), ["agent_thought_chunk", "tool_call", "tool_call_update", "plan", "available_commands_update", "agent_message_chunk", "agent_message_chunk"]);
		assert.match(updates.at(-1).content.text, /hello \(model gemini-3\.8-flash, mode default, thinking low, turn 1\)/);
		await assert.rejects(s.selectModel("gemini-9"), /not available for this account/);
		await s.selectModel("default"); // agy's own: nothing sent
		const sets = f.read().filter((m) => m.method === "session/set_config_option").map((m) => [m.params.configId, m.params.value]);
		assert.deepEqual(sets, [["mode", "default"], ["model", "gemini-3.8-flash"], ["thinking_level", "low"]]);
	} finally {
		await s.close();
	}
});

test("every permission request is rejected, questions and elicitations declined, fs reads refused", async () => {
	const f = fake();
	const asked: string[] = [];
	const text: string[] = [];
	const s = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env, onUpdate: (p) => p.update.sessionUpdate === "agent_message_chunk" && text.push(p.update.content.text), onAgentRequest: (m) => asked.push(m) });
	try {
		for (const p of ["permission", "question", "elicit", "fsread"]) await s.prompt([{ type: "text", text: p }]);
	} finally {
		await s.close();
	}
	assert.deepEqual(asked, ["session/request_permission", "session/request_permission", "session/elicitation", "fs/read_text_file"]);
	assert.equal(text[0], 'permission:{"outcome":{"outcome":"selected","optionId":"deny"}}');
	assert.equal(text[1], 'question:{"outcome":{"outcome":"cancelled"}}');
	assert.equal(text[2], 'elicit:{"action":"decline"}');
	assert.match(text[3], /^fsread:\{"error":\{"code":-32601/);
	const answers = f.read().filter((m) => m.method === undefined && m.id >= 1000);
	assert.ok(answers.every((a) => !JSON.stringify(a).includes('"allow')), "never an allow option");
});

test("cancel: session/cancel ends the running prompt with stopReason cancelled", async () => {
	const f = fake();
	let ticks = 0;
	const s = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env, onUpdate: () => ticks++ });
	try {
		const turn = s.prompt([{ type: "text", text: "slow" }]);
		while (ticks < 3) await new Promise((r) => setTimeout(r, 10));
		s.cancel();
		assert.equal((await turn).stopReason, "cancelled");
		assert.deepEqual(f.read().find((m) => m.method === "session/cancel").params, { sessionId: s.sessionId });
		assert.equal((await s.prompt([{ type: "text", text: "again" }])).stopReason, "end_turn", "the session goes on");
	} finally {
		await s.close();
	}
});

test("process exit: a crash mid-turn rejects the prompt and later requests; close ends a live process", async () => {
	const f = fake();
	let exited = false;
	const s = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env, onExit: () => (exited = true) });
	await assert.rejects(s.prompt([{ type: "text", text: "crash" }]), /Antigravity \(agy\) ended with exit code 3/);
	assert.equal(exited, true);
	assert.equal(s.conn.alive, false);
	await assert.rejects(s.prompt([{ type: "text", text: "again" }]), /ended with exit code 3/);
	const missing = new AcpConnection(path.join(TMP_ROOT, "no-such-agy"), ["acp"], { cwd: TMP_ROOT });
	missing.start();
	await assert.rejects(missing.request("initialize", {}), /could not start|ended/);
	const live = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env });
	await live.close();
	assert.equal(live.conn.alive, false);
	await assert.rejects(live.prompt([]), /stopped/);
});

test("non-JSON stdout lines are skipped (only a sign-in link counts); a request answered with an error rejects", async () => {
	const dir = mkdtempSync(path.join(TMP_ROOT, "noisy-"));
	const mjs = path.join(dir, "agy.mjs");
	writeFileSync(mjs, `#!/usr/bin/env node
import readline from "node:readline";
process.stdout.write("agy starting up\\n");
readline.createInterface({ input: process.stdin }).on("line", (l) => {
	const m = JSON.parse(l);
	if (m.method === "initialize") process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: 2, agentInfo: { version: "1.5.12" } } }) + "\\nnot json\\n");
	else process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, error: { code: -32603, message: "boom" } }) + "\\n");
});
`);
	chmodSync(mjs, 0o755);
	await assert.rejects(AgySession.open({ agyPath: mjs, cwd: dir }), /Antigravity: boom \(authenticate\)/);
});

test("probeModels: a throwaway session, closed again", async () => {
	const f = fake();
	const r = await probeModels({ agyPath: FAKE, cwd: f.cwd, env: f.env });
	assert.deepEqual(r.models.map((m) => m.id), ["gemini-3.8-pro", "gemini-3.8-flash"]);
	assert.equal(r.models[0].description, "Most capable");
	assert.deepEqual(r.thinking, ["low", "high"]);
	assert.deepEqual(methods(f.read()).slice(-1), ["session/close"]);
	assert.deepEqual(modelsOf({ models: { availableModels: [{ modelId: "m1", name: "M 1" }, { name: "bad" }] } }), [{ id: "m1", name: "M 1" }], "v1's models field");
});

// ---- step 2: sign-in and models ----

const LINK = "https://accounts.google.com/o/oauth2/auth?client_id=fake&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback&response_type=code&state=s123";

test("sign-in link and answer checks (t3code's): Google's code flow only; a code, or the page URL of this sign-in", () => {
	const l = parseSignInLink(LINK)!;
	assert.equal(l.redirectUri, CODE_REDIRECT_URI);
	assert.equal(l.state, "s123");
	assert.equal(parseSignInLink(LINK.replace("accounts.google.com", "accounts.google.com.evil.example")), undefined);
	assert.equal(parseSignInLink(LINK.replace("response_type=code", "response_type=token")), undefined);
	assert.equal(parseSignInLink(`${LINK}&state=two`), undefined, "one state");
	assert.equal(parseSignInLink(`${LINK} x`), undefined);
	assert.equal(linkInLine(`  ${LINK}  `)?.url, LINK);
	assert.equal(linkInLine(`Open the following link to authenticate the ACP server: ${LINK}`)?.url, LINK);
	assert.equal(linkInLine("Paste the code here:"), undefined);
	assert.equal(loginAnswer(l, " 4/0Ab-cd_ef.gh~ "), "4/0Ab-cd_ef.gh~");
	assert.equal(loginAnswer(l, "code\nmore"), undefined, "one line only");
	assert.equal(loginAnswer(l, "https://antigravity.google/oauth-callback?state=s123&code=abc"), "https://antigravity.google/oauth-callback?state=s123&code=abc");
	assert.equal(loginAnswer(l, "https://antigravity.google/oauth-callback?state=other&code=abc"), undefined, "another sign-in's page");
	assert.equal(loginAnswer(l, "https://evil.example/oauth-callback?state=s123&code=abc"), undefined);
});

test("agyLogin: shows agy's link, writes the pasted code to agy's stdin, reports agy's result", async () => {
	const f = fake();
	const shown: string[] = [];
	const ok = await agyLogin({ agyPath: FAKE, cwd: f.cwd, env: f.env, showLink: (u) => shown.push(u), askCode: async () => " good-code " });
	assert.deepEqual(ok, { ok: true });
	assert.deepEqual(shown, [LINK]);
	assert.deepEqual(f.read().map((m) => m.argv ?? m.loginCode).filter(Boolean), [["acp", "--login"], "good-code"]);
	const bad = await agyLogin({ agyPath: FAKE, cwd: f.cwd, env: f.env, showLink: () => {}, askCode: async () => "wrong" });
	assert.equal(bad.ok, false);
	assert.match((bad as any).error, /could not finish/);
	const cancelled = await agyLogin({ agyPath: FAKE, cwd: f.cwd, env: f.env, showLink: () => {}, askCode: async () => undefined });
	assert.deepEqual(cancelled, { ok: false, error: "Sign-in cancelled" });
	const junk = fake();
	const refused = await agyLogin({ agyPath: FAKE, cwd: junk.cwd, env: junk.env, showLink: () => {}, askCode: async () => "https://evil.example/?code=1" });
	assert.match((refused as any).error, /not a code/);
	assert.equal(junk.read().filter((m) => m.loginCode !== undefined).length, 0, "nothing written to agy");
	const silent = path.join(TMP_ROOT, "silent-agy.mjs");
	writeFileSync(silent, "#!/usr/bin/env node\nprocess.stdout.write('no link here\\n');\n");
	chmodSync(silent, 0o755);
	assert.deepEqual(await agyLogin({ agyPath: silent, cwd: TMP_ROOT, showLink: () => assert.fail("no link"), askCode: async () => "x" }), { ok: false, error: "Antigravity (agy) gave no Google sign-in link" });
});

const ROOT = path.join(path.dirname(new URL(import.meta.url).pathname), "..");

/** Runs `f` with `env` set (undefined: unset) in process.env, then puts it back. */
async function withEnv<T>(env: Record<string, string | undefined>, f: () => Promise<T>): Promise<T> {
	const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
	for (const [k, v] of Object.entries(env)) v === undefined ? delete process.env[k] : (process.env[k] = v);
	try {
		return await f();
	} finally {
		for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : (process.env[k] = v);
	}
}

/** Loads extensions/antigravity into the model of pi (test/pi-rules.ts) as process.env is now. */
const loaded: any[] = [];
// every extension loaded here ends its agy processes (pi's session_shutdown), even after a failure
after(async () => {
	for (const pi of loaded) await pi.fire("session_shutdown");
});
async function loadExtension() {
	assertTempData();
	const pi = piRules();
	loaded.push(pi);
	const mod = await import(`../extensions/antigravity/index.ts?${Math.random()}`);
	await pi.load(path.join(ROOT, "extensions/antigravity"), mod.default);
	return pi;
}

test("without agy: only /antigravity, which says where to get agy; no provider, hook, status or output; a path set there turns the rest on in the same session", async () => {
	const home = mkdtempSync(path.join(TMP_ROOT, "home-"));
	await withEnv({ HOME: home, XDG_DATA_HOME: path.join(home, "xdg"), PATH: mkdtempSync(path.join(TMP_ROOT, "empty-")) }, async () => {
		const pi = await loadExtension();
		const [x] = pi.extensions;
		assert.deepEqual([...x.commands.keys()], ["antigravity"]);
		assert.deepEqual([x.providers.length, x.tools.size, x.flags.size, x.handlers.size], [0, 0, 0, 0]);
		assert.deepEqual(await pi.start(), { exitCode: 0, errors: [] });
		assert.deepEqual(pi.notices, []);
		assert.ok(!existsSync(path.join(home, "Library")) && !existsSync(path.join(home, "xdg")), "nothing written");
		const statuses: any[] = [];
		const menus: string[][] = [];
		const { ctx, notes } = cmdCtx(pi);
		const c = { ...ctx, ui: { ...ctx.ui, setStatus: (...a: any[]) => void statuses.push(a), select: async (_t: string, items: string[]) => (menus.push(items), "Close") } };
		await run(pi, "antigravity", "", c);
		assert.deepEqual(notes, [NOT_FOUND]);
		assert.equal(NOT_FOUND, "Antigravity CLI (agy) not found. Install it from https://antigravity.google/docs/getting-started (1.5.12 or newer), or set its path with /antigravity path <abs path>");
		assert.deepEqual(menus, [["Set agy's path…", "Close"]], "the menu offers only the path");
		await run(pi, "antigravity", "status", c);
		await run(pi, "antigravity", "add work", c);
		assert.deepEqual(notes.slice(1), [NOT_FOUND, NOT_FOUND]);
		await run(pi, "antigravity", "path relative/agy", c);
		assert.equal(notes.at(-1), "Not an absolute path to an executable file: relative/agy");
		assert.equal(x.providers.length, 0);
		// a path from the menu: the providers, hooks and /antigravity-login, now
		const m = { ...c, ui: { ...c.ui, select: async () => "Set agy's path…", input: async () => FAKE } };
		await run(pi, "antigravity", "", m);
		assert.match(notes.at(-1)!, new RegExp(`^Antigravity now runs ${FAKE.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}: its models are in /model`));
		assert.deepEqual(x.providers.map((p: any) => p.id), ["antigravity"]);
		assert.deepEqual([...x.commands.keys()], ["antigravity", "antigravity-login"]);
		assert.deepEqual([...x.handlers.keys()].sort(), ["session_before_compact", "session_shutdown", "session_start"]);
		assert.equal(JSON.parse(readFileSync(path.join(dataRoot(), "accounts.json"), "utf8")).agyPath, FAKE);
		await run(pi, "antigravity", "status", c);
		assert.match(notes.at(-1)!, /^Antigravity CLI: .*fake-agy\.mjs \(.*\), set by \/antigravity path\n/);
		await run(pi, "antigravity", `path ${FAKE}`, c);
		assert.equal(x.providers.filter((p: any) => p.id === "antigravity").length, 2, "a second path re-registers; no second set of hooks");
		assert.equal(x.handlers.get("session_start").length, 1);
	});
});

/** A temp HOME (with a ~/.gemini of skills and rules; Deckhand's data dir beneath it), agy = the stand-in on PATH. */
function accountsEnv(extra: Record<string, string | undefined> = {}) {
	const home = mkdtempSync(path.join(TMP_ROOT, "home-"));
	mkdirSync(path.join(home, ".gemini", "config", "skills", "my-skill"), { recursive: true });
	writeFileSync(path.join(home, ".gemini", "AGENTS.md"), "# my rules\n");
	const env = { HOME: home, XDG_DATA_HOME: path.join(home, ".local", "share"), PATH: PATH_WITH_AGY, ...extra };
	const root = dataRoot(env);
	assert.ok(root.startsWith(home + path.sep), "never the real data dir");
	assert.ok(home.startsWith(realpathSync(os.tmpdir())) || home.startsWith(os.tmpdir()), "HOME in a temp folder");
	return { home, root, env };
}
/** The provider registered last under `id`. */
const prov = (pi: any, id: string) => [...pi.extensions[0].providers].reverse().find((p: any) => p.id === id);
/** A command context that records notices and answers dialogs. */
function cmdCtx(pi: any, answers: { input?: string[]; select?: string[] } = {}, keys: Record<string, string> = {}) {
	const notes: string[] = [];
	const ctx = {
		...pi.ctx,
		hasUI: true,
		ui: { ...pi.ctx.ui, notify: (m: string) => void notes.push(m), input: async () => answers.input?.shift(), select: async () => answers.select?.shift(), confirm: async () => true, setStatus: () => {} },
		modelRegistry: { refresh: async () => {}, getProviderAuth: async (id: string) => (keys[id] ? { auth: { apiKey: keys[id] } } : undefined) },
	};
	return { ctx, notes };
}
const run = (pi: any, name: string, args: string, ctx: any) => pi.extensions[0].commands.get(name).handler(args, ctx);

test("with agy: one provider per account (antigravity for the default), /antigravity and /antigravity-login; loading writes and starts nothing", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	mkdirSync(a.root, { recursive: true });
	writeFileSync(path.join(a.root, "accounts.json"), JSON.stringify({ accounts: [{ name: "work", method: "gemini-api-key" }, { name: "Bad Name", method: "oauth-personal" }, { name: "x", method: "nope" }] }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		const [x] = pi.extensions;
		assert.deepEqual(x.providers.map((p: any) => p.id), ["antigravity", "antigravity-work"], "bad entries skipped");
		const p = x.providers[0];
		assert.deepEqual(p.getModels().map((m: any) => [m.provider, m.id, m.api]), [["antigravity", "default", "antigravity-acp"]]);
		assert.deepEqual(await p.auth.apiKey.check({}), { type: "api_key", source: `agy (${AGY})` });
		assert.equal(p.auth.apiKey.login, undefined, "a Google account: agy keeps the sign-in");
		const w = x.providers[1];
		assert.equal(typeof w.auth.apiKey.login, "function", "an API key: pi's /login asks for it");
		assert.equal(await w.auth.apiKey.check({}), undefined, "no key in pi's store: not configured");
		assert.deepEqual(await w.auth.apiKey.resolve({ credential: { type: "api_key", key: "k" } }), { auth: { apiKey: "k" }, source: "stored credential" });
		assert.deepEqual(await w.auth.apiKey.login({ prompt: async (q: any) => (assert.equal(q.type, "secret"), " k-typed ") }), { type: "api_key", key: "k-typed" }, "masked prompt");
		assert.deepEqual(w.getModels()[0].name, "Antigravity: work (agy's default model)");
		assert.deepEqual([...x.commands.keys()], ["antigravity", "antigravity-login"]);
		assert.deepEqual([...x.tools.keys(), ...x.flags.keys()], []);
		await pi.start();
		assert.equal(f.read().length, 0, "agy is not started by loading or by session start");
		assert.ok(!existsSync(path.join(a.root, "profiles")), "no profile made until agy runs");
		assert.deepEqual(pi.notices, []);
	});
});

test("/antigravity-login: agy's --login in the default account's own profile (GEMINI_HOME, file storage, SSH_CONNECTION, its TMPDIR), then its models; sign-out by agy's logout", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity-login", "", ctx);
		assert.match(notes[0], /Open this link and sign in with Google:\nhttps:\/\/accounts\.google\.com\/.*\nThen paste the code/s);
		assert.deepEqual(notes.slice(1), ['Signed in to Antigravity (account "default")', '2 models of the Antigravity account "default" in /model (provider antigravity)']);
		const prof = path.join(a.root, "profiles", "default");
		const starts = f.read().filter((m) => m.argv);
		assert.deepEqual(starts[0].argv, ["acp", "--gemini-dir", prof, "--app-data-dir", "antigravity-acp", "--login"]);
		for (const s of starts)
			assert.deepEqual(s.env, { GEMINI_HOME: prof, TMPDIR: path.join(prof, "antigravity-acp", "tmp"), SSH_CONNECTION: "127.0.0.1 0 127.0.0.1 0", AGY_ACP_FORCE_FILE_STORAGE: "1", AGY_CLI_DISABLE_AUTO_UPDATE: "true", ELECTRON_RUN_AS_NODE: "1" });
		assert.deepEqual(JSON.parse(readFileSync(path.join(prof, "antigravity-acp", "settings.json"), "utf8")), { auth: { type: "oauth-personal" } });
		assert.equal(statSync(prof).mode & 0o777, 0o700);
		assert.equal(f.read().find((m) => m.method === "authenticate").params.methodId, "oauth-personal");
		assert.deepEqual(prov(pi, "antigravity").getModels().map((m: any) => m.id), ["default", "gemini-3.8-pro", "gemini-3.8-flash"]);
		// the user's ~/.gemini skills and rules, linked in
		assert.equal(readlinkSync(path.join(prof, "config", "skills")), path.join(a.home, ".gemini", "config", "skills"));
		assert.equal(readlinkSync(path.join(prof, "AGENTS.md")), path.join(a.home, ".gemini", "AGENTS.md"));
		assert.ok(!existsSync(path.join(prof, "GEMINI.md")), "only what the user has");
		const st = cmdCtx(pi);
		await run(pi, "antigravity", "status", st.ctx);
		assert.match(st.notes[0], /^Antigravity CLI: .*\/agy \(agy_acp_server_1\.5\.12\)\nAccounts \(.*\):\n- default → antigravity · Google account · signed in · 2 models$/);
		await run(pi, "antigravity", "logout", st.ctx);
		assert.equal(st.notes.at(-1), 'Signed out of Antigravity (account "default"); its history is kept');
		assert.ok(f.read().some((m) => m.method === "logout"));
		await run(pi, "antigravity", "status", st.ctx);
		assert.match(st.notes.at(-1)!, /default → antigravity · Google account · not signed in: run \/antigravity-login/);
	});
});

test("GEMINI_API_KEY, GOOGLE_* and BROWSER in pi's environment never reach agy: an account's credential is its own", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log, GEMINI_API_KEY: "ambient-key", GOOGLE_API_KEY: "ambient-g", GOOGLE_CLOUD_PROJECT: "p", GOOGLE_GENAI_USE_VERTEXAI: "1", BROWSER: "/bin/echo", GEMINI_HOME: "/elsewhere", Gemini_Api_Key: "mixed-case" });
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity-login", "", ctx);
		const r = await drive(prov(pi, "antigravity").streamSimple({ id: "default", provider: "antigravity", api: "antigravity-acp" }, { messages: [user("hi")] }, { sessionId: "s1" }));
		assert.equal(r.msg.stopReason, "stop");
		const starts = f.read().filter((m) => m.argv);
		assert.ok(starts.length >= 2);
		for (const s of starts) {
			assert.equal(s.env.GEMINI_API_KEY, undefined);
			assert.equal(s.env.GOOGLE_API_KEY, undefined);
			assert.equal(s.env.GOOGLE_CLOUD_PROJECT, undefined);
			assert.equal(s.env.BROWSER, undefined);
			assert.equal(s.env.GEMINI_HOME, path.join(a.root, "profiles", "default"));
		}
		const e = agyEnvFor({ name: "default", method: "oauth-personal" }, profileOf(a.root, "default"), undefined, { Gemini_Api_Key: "x", google_cloud_location: "y", PATH: "/bin", DECKHAND_TOKEN: "t" });
		assert.deepEqual(Object.keys(e).filter((k) => /gemini_api|google|deckhand/i.test(k)), [], "case-insensitively");
		assert.equal(e.PATH, "/bin");
	});
});

test("two accounts: separate profiles (GEMINI_HOME) and providers; an API key from pi's store reaches only its account's agy, never accounts.json", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi, {}, { "antigravity-work": "k-work-123" });
		await run(pi, "antigravity", "add work gemini-api-key", ctx);
		assert.match(notes.at(-1)!, /Added the Antigravity account "work" \(Gemini API key\).*provider antigravity-work\. Next: \/login antigravity-work/);
		await run(pi, "antigravity", "add work oauth-personal", ctx);
		assert.match(notes.at(-1)!, /exists/);
		const file = path.join(a.root, "accounts.json");
		assert.equal(statSync(file).mode & 0o777, 0o600);
		assert.ok(!readFileSync(file, "utf8").includes("k-work"), "no key in accounts.json");
		await run(pi, "antigravity", "login work", ctx);
		assert.match(notes.at(-1)!, /Run \/login antigravity-work: pi asks for the Gemini API key \(hidden as you type\)/);
		await run(pi, "antigravity", "models work", ctx);
		assert.equal(notes.at(-1), '2 models of the Antigravity account "work" in /model (provider antigravity-work)');
		assert.deepEqual(prov(pi, "antigravity-work").getModels().map((m: any) => [m.provider, m.name]), [
			["antigravity-work", "Antigravity: work (agy's default model)"],
			["antigravity-work", "Gemini 3.8 Pro (Antigravity: work)"],
			["antigravity-work", "Gemini 3.8 Flash (Antigravity: work)"],
		]);
		assert.deepEqual(prov(pi, "antigravity").getModels().map((m: any) => m.id), ["default"], "the default account's list is its own");
		// a turn on each account: each runs in its own profile
		const work = await drive(prov(pi, "antigravity-work").streamSimple({ id: "gemini-3.8-flash", provider: "antigravity-work", api: "antigravity-acp" }, { messages: [user("w")] }, { sessionId: "s1", apiKey: "k-work-123" }));
		assert.equal(work.msg.stopReason, "stop");
		assert.equal(work.msg.provider, "antigravity-work");
		mkdirSync(path.join(a.root, "profiles", "default", "antigravity-acp"), { recursive: true });
		writeFileSync(path.join(a.root, "profiles", "default", "antigravity-acp", "acp_token.json"), "{}"); // as if signed in
		const def = await drive(prov(pi, "antigravity").streamSimple({ id: "default", provider: "antigravity", api: "antigravity-acp" }, { messages: [user("d")] }, { sessionId: "s1" }));
		assert.equal(def.msg.stopReason, "stop");
		const starts = f.read().filter((m) => m.argv);
		const homes = (re: RegExp) => starts.filter((s) => re.test(s.env.GEMINI_HOME ?? ""));
		const w = homes(/profiles\/work$/), d = homes(/profiles\/default$/);
		assert.ok(w.length >= 2 && d.length >= 1);
		assert.ok(w.every((s) => s.env.GEMINI_API_KEY === "k-work-123" && s.env.SSH_CONNECTION === undefined), "the key in its env only; no keyring trick for a key");
		assert.ok(d.every((s) => s.env.GEMINI_API_KEY === undefined));
		assert.deepEqual(f.read().filter((m) => m.method === "authenticate").map((m) => m.params.methodId).sort(), ["gemini-api-key", "gemini-api-key", "oauth-personal"].sort());
		await run(pi, "antigravity", "status", ctx);
		assert.match(notes.at(-1)!, /- default → antigravity · Google account · signed in · 2 models\n- work → antigravity-work · Gemini API key · API key saved in pi · 2 models/);
		// remove: its provider, profile and entry go; the default account stays
		await run(pi, "antigravity", "remove work", ctx);
		assert.match(notes.at(-1)!, /Removed the Antigravity account "work"; its key is still in pi's store: \/logout and pick antigravity-work/);
		assert.deepEqual(pi.extensions[0].unregistered, ["antigravity-work"]);
		assert.ok(!existsSync(path.join(a.root, "profiles", "work")));
		assert.ok(existsSync(path.join(a.root, "profiles", "default")));
		assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).accounts, []);
		await run(pi, "antigravity", "remove default", ctx);
		assert.match(notes.at(-1)!, /The default account stays/);
	});
});

test("an API-key account without a key, a signed-out account, SUBSCRIPTION_REQUIRED: each error names its fix; no other account is tried", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", "add biz oauth-personal", ctx);
		const turn = (id: string, key?: string) => drive(prov(pi, id).streamSimple({ id: "default", provider: id, api: "antigravity-acp" }, { messages: [user("hi")] }, { sessionId: "s", ...(key ? { apiKey: key } : {}) }));
		assert.equal((await turn("antigravity")).msg.errorMessage, 'Antigravity account "default" is not signed in: run /antigravity-login');
		assert.equal((await turn("antigravity-biz")).msg.errorMessage, 'Antigravity account "biz" is not signed in: run /antigravity login biz');
		await run(pi, "antigravity", "add k gemini-api-key", ctx);
		await run(pi, "antigravity", "models k", ctx);
		assert.equal(notes.at(-1), 'Antigravity account "k" is not signed in: run /login antigravity-k');
		const homes = new Set(f.read().filter((m) => m.argv).map((m) => m.env.GEMINI_HOME));
		assert.deepEqual([...homes].sort(), [path.join(a.root, "profiles", "biz"), path.join(a.root, "profiles", "default")].sort(), "each failure stays on its own account");
	});
	const s = fake({ FAKE_AGY_SUBSCRIPTION: "1" });
	const b = accountsEnv({ FAKE_AGY_LOG: s.log, FAKE_AGY_SUBSCRIPTION: "1" });
	await withEnv(b.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx } = cmdCtx(pi, {}, { "antigravity-k": "key" });
		await run(pi, "antigravity", "add k gemini-api-key", ctx);
		const r = await drive(prov(pi, "antigravity-k").streamSimple({ id: "default", provider: "antigravity-k", api: "antigravity-acp" }, { messages: [user("hi")] }, { sessionId: "s", apiKey: "key" }));
		assert.equal(r.msg.errorMessage, `Google requires an eligible Antigravity subscription for the account "k" (Gemini API key): see ${PLANS_URL}`);
	});
});

test("Gemini Enterprise: project and location in the profile's settings; sign-in by agy's own browser flow, its link shown", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log, FAKE_AGY_BROWSER_SIGNIN: "1" });
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi, { input: ["ent", "my-proj", "us-central1"], select: ["Gemini Enterprise"] });
		await run(pi, "antigravity", "add", ctx);
		assert.match(notes.at(-1)!, /Added the Antigravity account "ent" \(Gemini Enterprise\).*Next: \/antigravity login ent/);
		await run(pi, "antigravity", "login ent", ctx);
		assert.match(notes.at(-3)!, /Open this link and sign in with Google \(account "ent"\):\nhttps:\/\/accounts\.google\.com\//);
		assert.equal(notes.at(-2), 'Signed in to Antigravity (account "ent")');
		const settings = JSON.parse(readFileSync(path.join(a.root, "profiles", "ent", "antigravity-acp", "settings.json"), "utf8"));
		assert.deepEqual(settings, { auth: { type: "oauth-business" }, gcp: { project: "my-proj", location: "us-central1" } });
		assert.ok(f.read().filter((m) => m.argv).every((m) => m.env.SSH_CONNECTION === undefined), "a browser sign-in on this Mac");
	});
});


test("/antigravity path: an absolute executable is kept in accounts.json and used from then on (also by a new pi); anything else refused; no argument clears it", async () => {
	const a = accountsEnv();
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", "path fake-agy.mjs", ctx);
		assert.equal(notes.at(-1), "Not an absolute path to an executable file: fake-agy.mjs");
		await run(pi, "antigravity", `path ${path.join(a.home, "missing")}`, ctx);
		assert.match(notes.at(-1)!, /^Not an absolute path to an executable file/);
		assert.ok(!existsSync(path.join(a.root, "accounts.json")), "nothing saved");
		await run(pi, "antigravity", "add work oauth-personal", ctx);
		await run(pi, "antigravity", `path ${FAKE}`, ctx);
		assert.equal(notes.at(-1), `Antigravity now runs ${FAKE}`);
		const saved = JSON.parse(readFileSync(path.join(a.root, "accounts.json"), "utf8"));
		assert.equal(saved.agyPath, FAKE);
		assert.deepEqual(saved.accounts.map((x: any) => x.name), ["work"], "accounts kept");
		assert.deepEqual(await prov(pi, "antigravity-work").auth.apiKey.check({}), { type: "api_key", source: `agy (${FAKE})` }, "every account's provider follows");
		await run(pi, "antigravity", "status", ctx);
		assert.match(notes.at(-1)!, /^Antigravity CLI: .*fake-agy\.mjs \(agy_acp_server_1\.5\.12\), set by \/antigravity path\n/);
		await run(pi, "antigravity", "add other oauth-personal", ctx);
		assert.equal(JSON.parse(readFileSync(path.join(a.root, "accounts.json"), "utf8")).agyPath, FAKE, "kept when accounts change");
	});
	// a new pi, agy on no PATH: the setting finds it
	await withEnv({ ...a.env, PATH: mkdtempSync(path.join(TMP_ROOT, "empty-")) }, async () => {
		const pi = await loadExtension();
		assert.equal(prov(pi, "antigravity").baseUrl, "acp:agy");
		assert.deepEqual(await prov(pi, "antigravity").auth.apiKey.check({}), { type: "api_key", source: `agy (${FAKE})` });
	});
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", "path", ctx);
		assert.equal(notes.at(-1), `Cleared agy's path: Antigravity runs ${AGY} from your PATH`);
		assert.equal(JSON.parse(readFileSync(path.join(a.root, "accounts.json"), "utf8")).agyPath, undefined);
		// a setting that went stale: PATH's agy, and the status says why
		const file = path.join(a.root, "accounts.json");
		writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, "utf8")), agyPath: "/nowhere/agy" }));
		const again = await loadExtension();
		await again.start();
		const c2 = cmdCtx(again);
		await run(again, "antigravity", "status", c2.ctx);
		assert.match(c2.notes[0], new RegExp(`^Antigravity CLI: ${AGY.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")} \\(agy_acp_server_1\\.5\\.12\\)\\n  The path set by /antigravity path is not an executable file, so agy is taken from PATH: /nowhere/agy\\n`));
	});
});
test("linkUserConfig: links what ~/.gemini has, replaces agy's empty placeholder, drops dangling links, keeps a profile's own content", () => {
	const user = mkdtempSync(path.join(TMP_ROOT, "gem-"));
	const prof = mkdtempSync(path.join(TMP_ROOT, "prof-"));
	mkdirSync(path.join(user, "config", "skills"), { recursive: true });
	mkdirSync(path.join(user, "antigravity-cli", "skills"), { recursive: true });
	writeFileSync(path.join(user, "GEMINI.md"), "g");
	mkdirSync(path.join(prof, "config", "skills"), { recursive: true }); // agy's empty placeholder
	mkdirSync(path.join(prof, "antigravity-cli", "skills", "own"), { recursive: true }); // content of the profile's own
	symlinkSync(path.join(user, "AGENTS.md"), path.join(prof, "AGENTS.md")); // dangling
	linkUserConfig(prof, user);
	assert.equal(readlinkSync(path.join(prof, "config", "skills")), path.join(user, "config", "skills"));
	assert.ok(existsSync(path.join(prof, "antigravity-cli", "skills", "own")), "never deletes content");
	assert.equal(readlinkSync(path.join(prof, "GEMINI.md")), path.join(user, "GEMINI.md"));
	assert.throws(() => lstatSync(path.join(prof, "AGENTS.md")), "dangling link removed");
	assert.equal(dataRoot({ HOME: "/h" }, "darwin"), "/h/Library/Application Support/Deckhand/antigravity");
	assert.equal(dataRoot({ HOME: "/h" }, "linux"), "/h/.local/share/deckhand/antigravity");
	assert.equal(dataRoot({ HOME: "/h", XDG_DATA_HOME: "/x" }, "linux"), "/x/deckhand/antigravity");
	assert.equal(dataRoot({ HOME: "/h", DECKHAND_ANTIGRAVITY_DIR: "/x/ag" }, "darwin"), "/h/Library/Application Support/Deckhand/antigravity", "no environment override");
});

// ---- step 3: the passthrough provider ----

/** Reads a provider stream as pi's agent loop does (pi-agent-core agent-loop.js streamAssistantResponse). */
async function drive(stream: any) {
	const events: any[] = [];
	for await (const e of stream) events.push(e);
	const msg = await stream.result();
	return { events, msg };
}

/** pi's stream contract (docs/custom-provider.md "A custom stream must"): one start, balanced blocks, one terminal event. */
function assertContract(events: any[], msg: any) {
	const types = events.map((e) => e.type);
	assert.equal(types.filter((t) => t === "done" || t === "error").length, 1, types.join(","));
	assert.ok(["done", "error"].includes(types.at(-1)), "the terminal event is last");
	assert.ok(types.filter((t) => t === "start").length <= 1);
	if (types.includes("start")) assert.equal(types[0], "start");
	const open = new Map<number, string>();
	for (const e of events) {
		const m = /^(text|thinking|toolcall)_(start|delta|end)$/.exec(e.type);
		if (!m) continue;
		if (m[2] === "start") open.set(e.contentIndex, m[1]);
		else assert.equal(open.get(e.contentIndex), m[1], `${e.type} for an open block`);
		if (m[2] === "end") open.delete(e.contentIndex);
	}
	assert.equal(open.size, 0, "every block ended");
	assert.ok(!types.some((t) => t.startsWith("toolcall")), "never a pi tool call");
	assert.ok(!msg.content.some((b: any) => b.type === "toolCall"));
	assert.notEqual(msg.stopReason, "pending");
	if (msg.stopReason === "error" || msg.stopReason === "aborted") assert.ok(msg.errorMessage);
}

const SYS = { role: "system", content: "You are pi.", toolsAdded: [{ name: "bash", description: "run", parameters: {} }] };
let clock = 1_000;
const user = (text: string, extra: any[] = []) => ({ role: "user", content: [{ type: "text", text }, ...extra], timestamp: clock++ });
const MODEL = { id: "default", provider: "antigravity", api: "antigravity-acp" };

/** A provider against the stand-in, and a pi session talking to it. */
function rig(extra: Record<string, string> = {}, opts: any = {}) {
	const f = fake(extra);
	const statuses: (string | undefined)[] = [];
	const ag = createAntigravity({ agyPath: FAKE, cwd: () => f.cwd, env: f.env, status: (t) => statuses.push(t), ...opts });
	const messages: any[] = [SYS];
	const turn = async (text: string, o: any = {}, model: any = MODEL) => {
		messages.push(user(text, o.images ?? []));
		const r = await drive(ag.provider.streamSimple(model, { messages: [...messages] }, { sessionId: o.sessionId ?? "pi-1", ...o.options }));
		assertContract(r.events, r.msg);
		if (o.keep !== false) messages.push(r.msg);
		return r;
	};
	const prompts = () => f.read().filter((m) => m.method === "session/prompt").map((m) => m.params.prompt);
	return { f, ag, messages, turn, prompts, statuses };
}
const textOfMsg = (m: any) => m.content.filter((b: any) => b.type === "text").map((b: any) => b.text).join("");
const thinkingOf = (m: any) => m.content.filter((b: any) => b.type === "thinking").map((b: any) => b.thinking).join("");

test("a turn: agy's text as text, its thoughts and tool calls as thinking, usage, agy's session on the answer; pi's tools and system prompt not sent", async () => {
	const r = rig();
	try {
		const { events, msg } = await r.turn("hello");
		assert.equal(msg.stopReason, "stop");
		assert.equal(textOfMsg(msg), "You said: hello (model gemini-3.8-pro, mode default, thinking high, turn 1)");
		assert.equal(thinkingOf(msg), "Thinking about it.\n→ Read README.md\nPlan: [>] Answer\n");
		assert.deepEqual(msg.content.map((b: any) => b.type), ["thinking", "text"]);
		assert.deepEqual(msg.usage, { input: 1200, output: 80, cacheRead: 300, cacheWrite: 0, totalTokens: 1580, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
		assert.match(msg.responseId, /^sess-/);
		assert.equal(msg.provider, "antigravity");
		assert.equal(events[0].type, "start");
		assert.deepEqual(r.prompts(), [[{ type: "text", text: "hello" }]], "the user's message only");
		assert.ok(!JSON.stringify(r.f.read()).includes("You are pi") && !JSON.stringify(r.f.read()).includes('"bash"'));
		assert.deepEqual(r.statuses, ["Antigravity: Read README.md", undefined]);
	} finally {
		await r.ag.closeAll();
	}
});

test("later turns: only the new user messages go to the same agy session; images pass through", async () => {
	const r = rig();
	try {
		await r.turn("one");
		r.messages.push(user("steer A"));
		const { msg } = await r.turn("steer B", { images: [{ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }] });
		assert.match(textOfMsg(msg), /steer A\nsteer B \[\+1 image\] .*turn 2\)/);
		assert.deepEqual(r.prompts()[1], [{ type: "text", text: "steer A" }, { type: "text", text: "steer B" }, { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }]);
		assert.equal(r.f.read().filter((m) => m.argv).length, 1, "one agy process");
		assert.equal(r.f.read().filter((m) => m.method === "session/new").length, 1);
	} finally {
		await r.ag.closeAll();
	}
});

test("model and thinking: pi's model id and level select agy's; an unknown model is an error naming /model", async () => {
	const r = rig();
	try {
		const { msg } = await r.turn("hi", { options: { reasoning: "low" } }, { ...MODEL, id: "gemini-3.8-flash" });
		assert.match(textOfMsg(msg), /model gemini-3\.8-flash, mode default, thinking low/);
		assert.deepEqual(r.ag.models.map((m) => m.id), ["default", "gemini-3.8-pro", "gemini-3.8-flash"], "the session's models are listed for /model");
		const bad = await r.turn("again", { keep: false }, { ...MODEL, id: "gemini-9" });
		assert.equal(bad.msg.stopReason, "error");
		assert.match(bad.msg.errorMessage, /gemini-9' is not available.*\/model/);
	} finally {
		await r.ag.closeAll();
	}
});


test("finding 3: an abort while pi's onPayload hook runs ends the turn aborted, and no prompt reaches agy", async () => {
	const r = rig();
	try {
		const ac = new AbortController();
		const { msg } = await r.turn("hi", { options: { signal: ac.signal, onPayload: async () => void ac.abort() } });
		assert.equal(msg.stopReason, "aborted");
		assert.deepEqual(r.prompts(), [], "nothing sent: there is no turn to cancel");
		const next = await r.turn("again");
		assert.equal(next.msg.stopReason, "stop", "the session goes on");
	} finally {
		await r.ag.closeAll();
	}
});

test("finding 8: an answer that fails before its prompt keeps the agy session: the next message continues it", async () => {
	const r = rig();
	try {
		const first = await r.turn("hi");
		const bad = await r.turn("with a model agy lacks", {}, { ...MODEL, id: "no-such-model" });
		assert.equal(bad.msg.stopReason, "error");
		assert.equal(bad.msg.responseId, first.msg.responseId, "the failed answer names the live session");
		const next = await r.turn("next");
		assert.equal(next.msg.stopReason, "stop");
		assert.equal(next.msg.responseId, first.msg.responseId, "same agy session");
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: "next" }], "no catch-up text: agy has the conversation");
		assert.equal(r.f.read().filter((m) => m.method === "session/new").length, 1);
	} finally {
		await r.ag.closeAll();
	}
});

test("finding 7: pi retrying a message agy already got says so; a new message, or one that never reached agy, does not", async () => {
	const r = rig();
	// pi's retry: the same transcript again; its answer then joins the transcript
	const retry = async (model = MODEL) => {
		const res = await drive(r.ag.provider.streamSimple(model, { messages: [...r.messages] }, { sessionId: "pi-1" }));
		r.messages.push(res.msg);
		return res;
	};
	try {
		await r.turn("hi");
		const failed = await r.turn("refuse this", { keep: false }); // pi drops a failed answer before retrying
		assert.equal(failed.msg.stopReason, "error");
		await retry();
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: RETRY_NOTE }, { type: "text", text: "refuse this" }]);
		await r.turn("something else");
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: "something else" }], "a different message: no note");
		const before = r.prompts().length;
		await r.turn("never sent", { keep: false }, { ...MODEL, id: "no-such-model" });
		assert.equal(r.prompts().length, before, "failed before its prompt");
		await retry();
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: "never sent" }], "agy never got it: no note");
	} finally {
		await r.ag.closeAll();
	}
});
test("abort: session/cancel, the turn ends aborted, and the session goes on", async () => {
	const r = rig();
	try {
		const ac = new AbortController();
		r.messages.push(user("slow"));
		const s = r.ag.provider.streamSimple(MODEL, { messages: [...r.messages] }, { sessionId: "pi-1", signal: ac.signal });
		const events: any[] = [];
		for await (const e of s) {
			events.push(e);
			if (events.filter((x) => x.type === "text_delta").length === 3) ac.abort();
		}
		const msg = await s.result();
		assertContract(events, msg);
		assert.equal(msg.stopReason, "aborted");
		assert.equal(msg.errorMessage, "Request was aborted");
		assert.equal(r.f.read().filter((m) => m.method === "session/cancel").length, 1);
		r.messages.push(msg); // pi keeps an aborted answer
		const next = await r.turn("after");
		assert.match(textOfMsg(next.msg), /after .*turn 2\)/, "same agy session");
		const pre = new AbortController();
		pre.abort();
		r.messages.push(user("never"));
		const early = await drive(r.ag.provider.streamSimple(MODEL, { messages: [...r.messages] }, { sessionId: "pi-1", signal: pre.signal }));
		assert.equal(early.msg.stopReason, "aborted");
		assert.equal(r.prompts().length, 2, "an aborted request sends nothing");
	} finally {
		await r.ag.closeAll();
	}
});

test("abort when agy does not end the turn: its process is stopped, and the next turn resumes the agy session in a new one", async () => {
	const r = rig({}, { cancelWaitMs: 150 });
	try {
		const first = await r.turn("hi");
		const ac = new AbortController();
		r.messages.push(user("stubborn"));
		const s = r.ag.provider.streamSimple(MODEL, { messages: [...r.messages] }, { sessionId: "pi-1", signal: ac.signal });
		setTimeout(() => ac.abort(), 80);
		const { msg } = await drive(s);
		assert.equal(msg.stopReason, "aborted");
		r.messages.push(msg);
		const next = await r.turn("back");
		assert.equal(next.msg.stopReason, "stop");
		assert.equal(r.f.read().filter((m) => m.argv).length, 2, "a second agy process");
		assert.deepEqual(r.f.read().find((m) => m.method === "session/resume")?.params, { sessionId: first.msg.responseId, cwd: r.f.cwd, mcpServers: [] });
		assert.equal(next.msg.responseId, first.msg.responseId);
	} finally {
		await r.ag.closeAll();
	}
});

test("agy crashing mid-turn: an error that is not one pi retries; the next turn resumes agy's session", async () => {
	const r = rig();
	try {
		const first = await r.turn("hi");
		const crash = await r.turn("crash");
		assert.equal(crash.msg.stopReason, "error");
		assert.match(crash.msg.errorMessage, /Antigravity \(agy\) ended with exit code 3/);
		assert.equal(textOfMsg(crash.msg), "about to", "what streamed before stays");
		assert.ok(!/overloaded|rate.?limit|server.?error|internal.?error|connection.?(lost|error|refused)|network|socket|fetch failed|\b5\d\d\b/i.test(crash.msg.errorMessage), "pi's retry patterns (pi-ai utils/retry.js) do not match");
		const next = await r.turn("still there?");
		assert.equal(next.msg.stopReason, "stop");
		assert.equal(r.f.read().find((m) => m.method === "session/resume")?.params.sessionId, first.msg.responseId);
	} finally {
		await r.ag.closeAll();
	}
});

test("finding 2: when agy cannot resume, the new session gets pi's transcript as text first, not only the new message", async () => {
	const r = rig({ FAKE_AGY_NO_RESUME: "1" });
	try {
		await r.turn("hi");
		await r.turn("crash");
		const next = await r.turn("still there?");
		assert.equal(next.msg.stopReason, "stop");
		assert.ok(!r.f.read().some((m) => m.method === "session/resume"), "agy does not offer it");
		const sent = r.prompts().at(-1)!;
		assert.equal(sent.length, 2);
		assert.match(sent[0].text, /^\[The conversation so far, from pi's transcript[\s\S]*User: hi\n\nAssistant: You said: hi[\s\S]*User: crash/);
		assert.deepEqual(sent[1], { type: "text", text: "still there?" });
		assert.notEqual(next.msg.responseId, r.messages[2].responseId, "a new agy session");
		const after = await r.turn("and now?");
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: "and now?" }], "then it continues as usual");
		assert.equal(after.msg.responseId, next.msg.responseId);
	} finally {
		await r.ag.closeAll();
	}
});

test("pi restarted: a new provider resumes the agy session named on the transcript's last answer", async () => {
	const r = rig();
	const first = await r.turn("hi");
	await r.ag.closeAll();
	const again = createAntigravity({ agyPath: FAKE, cwd: () => r.f.cwd, env: r.f.env });
	try {
		r.messages.push(user("after restart"));
		const { msg } = await drive(again.provider.streamSimple(MODEL, { messages: r.messages }, { sessionId: "pi-1" }));
		assert.equal(msg.stopReason, "stop");
		assert.equal(msg.responseId, first.msg.responseId);
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: "after restart" }]);
		assert.equal(r.f.read().find((m) => m.method === "session/resume")?.params.sessionId, first.msg.responseId);
	} finally {
		await again.closeAll();
	}
});

test("a transcript agy does not have (another provider answered before; /tree went back): a new agy session, pi's transcript sent as text first", async () => {
	const r = rig();
	try {
		r.messages.push(user("what is 2+2?"), { role: "assistant", provider: "anthropic", api: "anthropic-messages", model: "x", content: [{ type: "text", text: "4" }], timestamp: clock++, stopReason: "stop" });
		const { msg } = await r.turn("and 3+3?");
		assert.equal(msg.stopReason, "stop");
		const [catchUp, newest] = r.prompts()[0];
		assert.match(catchUp.text, /^\[The conversation so far.*\nUser: what is 2\+2\?\n\nAssistant: 4\n\[End of the earlier conversation/s);
		assert.deepEqual(newest, { type: "text", text: "and 3+3?" });
		// back in /tree to the first answer, then a new message
		const firstAnswer = msg;
		await r.turn("second");
		const branch = [SYS, ...r.messages.slice(1, r.messages.indexOf(firstAnswer) + 1), user("a branch")];
		const b = await drive(r.ag.provider.streamSimple(MODEL, { messages: branch }, { sessionId: "pi-1" }));
		assert.equal(b.msg.stopReason, "stop");
		assert.equal(r.f.read().filter((m) => m.method === "session/new").length, 2, "agy's session is ahead of this branch: a new one");
		assert.match(r.prompts().at(-1)[0].text, /User: and 3\+3\?/);
	} finally {
		await r.ag.closeAll();
	}
});

test("planTurn: continue, resume, new; a retry after a failed answer continues", () => {
	const a = (ts: number, provider = "antigravity", responseId = "S") => ({ role: "assistant", provider, responseId, timestamp: ts, content: [] });
	const u = (t: string) => ({ role: "user", content: t, timestamp: 0 });
	assert.deepEqual(planTurn([SYS, u("x")], undefined), { blocks: [{ type: "text", text: "x" }], mode: "new" });
	assert.equal((planTurn([u("x"), a(5)], undefined) as any).error, "Antigravity: there is no new message to send");
	const st = { acpSessionId: "S", produced: [{ ts: 5, ok: true }] };
	assert.equal((planTurn([u("x"), a(5), u("y")], st) as any).mode, "continue");
	const { prior, ...resume } = planTurn([u("x"), a(5), u("y")], { acpSessionId: "T", produced: [] }) as any;
	assert.deepEqual(resume, { blocks: [{ type: "text", text: "y" }], mode: "resume", resumeId: "S" });
	assert.deepEqual(prior, [u("x"), a(5)], "the transcript to catch agy up with, if it cannot resume");
	const retried = { acpSessionId: "S", produced: [{ ts: 5, ok: true }, { ts: 6, ok: false }] };
	assert.equal((planTurn([u("x"), a(5), u("y")], retried) as any).mode, "continue", "pi dropped the failed attempt and retries");
	const ahead = { acpSessionId: "S", produced: [{ ts: 5, ok: true }, { ts: 7, ok: true }] };
	assert.equal((planTurn([u("x"), a(5), u("y")], ahead) as any).mode, "new", "agy is ahead of this branch");
	assert.equal((planTurn([u("x"), a(5, "openai"), u("y")], st) as any).mode, "new");
});

test("approvals inside a turn: agy's request is rejected and shown as declined in the thinking", async () => {
	const r = rig();
	try {
		const { msg } = await r.turn("permission please");
		assert.equal(textOfMsg(msg), 'permission:{"outcome":{"outcome":"selected","optionId":"deny"}}');
		assert.match(thinkingOf(msg), /→ Run rm -rf build\n✗ declined: Run rm -rf build \(Deckhand does not grant Antigravity approvals yet\)\n✗ Run rm -rf build failed/);
		const q = await r.turn("question");
		assert.match(thinkingOf(q.msg), /✗ declined: Which file\?/);
		assert.equal(textOfMsg(q.msg), 'question:{"outcome":{"outcome":"cancelled"}}');
	} finally {
		await r.ag.closeAll();
	}
});

test("pi's summaries are answered without agy; replays refused; busy refused", async () => {
	const r = rig();
	try {
		const summary = await drive(
			r.ag.provider.streamSimple(MODEL, { messages: [{ role: "system", content: "You are a context summarization assistant. Your task is..." }, user("<conversation>...</conversation>")] }, { sessionId: "x", cacheRetention: "none" }),
		);
		assertContract(summary.events, summary.msg);
		assert.equal(textOfMsg(summary.msg), SUMMARY_TEXT);
		assert.equal(r.f.read().length, 0, "agy not started");
		r.messages.push(user("hi"));
		const replay = await drive(r.ag.provider.streamSimple(MODEL, { messages: r.messages }, { sessionId: "pi-1", disableContinuation: true }));
		assert.equal(replay.msg.stopReason, "error");
		assert.match(replay.msg.errorMessage, /replaying a request is not supported/);
		const slow = r.ag.provider.streamSimple(MODEL, { messages: [...r.messages, user("slow")] }, { sessionId: "pi-1" });
		await new Promise((res) => setTimeout(res, 300));
		const busy = await drive(r.ag.provider.streamSimple(MODEL, { messages: [...r.messages, user("x")] }, { sessionId: "pi-1" }));
		assert.match(busy.msg.errorMessage, /still answering/);
		await r.ag.closeAll();
		const ended = await drive(slow);
		assert.equal(ended.msg.stopReason, "error", "a closed session ends its turn");
	} finally {
		await r.ag.closeAll();
	}
});

test("not signed in, or agy too old: the turn fails at once with what to do", async () => {
	const out = rig({ FAKE_AGY_SIGNED_OUT: "1" });
	const a = await out.turn("hi");
	assert.equal(a.msg.stopReason, "error");
	assert.equal(a.msg.errorMessage, "Antigravity is not signed in: run /antigravity-login");
	await out.ag.closeAll();
	const old = rig({ FAKE_AGY_VERSION: "agy_acp_server_1.4.9" });
	const b = await old.turn("hi");
	assert.match(b.msg.errorMessage, /1\.4\.9 is older than 1\.5\.1/);
	await old.ag.closeAll();
});

test("an update agy sends after its turn ended is dropped, not shown in the next answer", async () => {
	const r = rig();
	try {
		await r.turn("late please");
		await new Promise((res) => setTimeout(res, 120));
		const { msg } = await r.turn("next");
		assert.ok(!textOfMsg(msg).includes("LATE"), textOfMsg(msg));
	} finally {
		await r.ag.closeAll();
	}
});

test("pi's request hooks: onPayload sees (and may replace) the prompt; onProviderStreamEvent sees each update", async () => {
	const r = rig();
	try {
		const seen: any[] = [];
		const events: any[] = [];
		const { msg } = await r.turn("orig", { options: { onPayload: (p: any) => (seen.push(p), { ...p, prompt: [{ type: "text", text: "replaced" }] }), onProviderStreamEvent: (e: any) => void events.push(e.sessionUpdate) } });
		assert.deepEqual(seen[0].prompt, [{ type: "text", text: "orig" }]);
		assert.match(textOfMsg(msg), /You said: replaced/);
		assert.ok(events.includes("agent_message_chunk") && events.includes("tool_call"));
	} finally {
		await r.ag.closeAll();
	}
});

test("session_before_compact: an Antigravity session's compaction is a note, without asking agy; other models' are left to pi", async () => {
	await withEnv(accountsEnv().env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const [h] = pi.extensions[0].handlers.get("session_before_compact");
		const event = { preparation: { firstKeptEntryId: "e7", tokensBefore: 123456 } };
		assert.deepEqual(await h(event, { ...pi.ctx, model: { provider: "antigravity", id: "default" } }), { compaction: { summary: SUMMARY_TEXT, firstKeptEntryId: "e7", tokensBefore: 123456 } });
		assert.equal(await h(event, { ...pi.ctx, model: { provider: "anthropic", id: "x" } }), undefined);
		await pi.fire("session_shutdown");
	});
});

test("answers in one millisecond still get distinct timestamps (planTurn tells them apart by it)", async () => {
	const r = rig();
	try {
		const first = await r.turn("one");
		const st = r.ag.sessions.get("pi-1")!;
		st.produced.at(-1)!.ts = first.msg.timestamp = Date.now() + 60_000; // as if the next answer came in the same millisecond
		const second = await r.turn("two");
		assert.equal(second.msg.timestamp, first.msg.timestamp + 1);
		const third = await r.turn("three");
		assert.match(textOfMsg(third.msg), /turn 3\)/, "still in sync with agy's session");
	} finally {
		await r.ag.closeAll();
	}
});
