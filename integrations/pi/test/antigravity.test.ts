// The Antigravity extension (extensions/antigravity, lib/acp.ts, lib/agy.ts) against a stand-in agy
// (test/fake-agy.mjs): never a real agy, pi or model. node --test test/antigravity.test.ts
import { assertTempData } from "./temp-home.ts"; // first: HOME and XDG_DATA_HOME in a temp folder
import "./typebox-stub.ts"; // before the extension: typebox comes with pi
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { AcpConnection, agyEnv, agyTooOld, answerAgentRequest, CLIENT_INFO, findAgy, initializeParams, NOT_FOUND, parseAgyVersion, SignInRequired, signInLink } from "../lib/acp.ts";
import { AgySession, agyVersion, modelsOf, probeModels, SIGN_IN_HINT } from "../lib/agy.ts";
import { agyEnvFor, dataRoot, linkUserConfig, loadAccounts, PLANS_URL, profileOf, storedAccounts, sweepRunDirs, updateAccounts } from "../lib/agy-accounts.ts";
import { fileLedger } from "../lib/agy-ledger.ts";
import { agyLogin, CODE_REDIRECT_URI, linkInLine, loginAnswer, parseSignInLink } from "../lib/agy-login.ts";
import { createAntigravity, planTurn, RETRY_NOTE, SUMMARY_TEXT } from "../lib/antigravity.ts";
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
		assert.equal(s.agentVersion, "1.5.18");
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
	await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env }), /1\.5\.0 is older than 1\.5\.1.*update agy \(1\.5\.18/);
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
	// agy 1.5.18's own texts: each becomes the account's sign-in command, never agy's advice (`agy acp --login`)
	const nokey = fake();
	await assert.rejects(
		AgySession.open({ agyPath: FAKE, cwd: nokey.cwd, env: nokey.env, authMethod: "gemini-api-key", signInHint: 'Antigravity account "k" is not signed in: run /login antigravity-k' }),
		(e: any) => e instanceof SignInRequired && e.message === 'Antigravity account "k" is not signed in: run /login antigravity-k',
	);
	assert.deepEqual(methods(nokey.read()), ["initialize", "authenticate"]);
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

test("a session without an answerer (probes, sign-in checks): every permission request rejected, questions and elicitations declined, fs reads refused", async () => {
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
		assert.equal(NOT_FOUND, "Antigravity CLI (agy) not found. Install it from https://antigravity.google/docs/getting-started (1.5.18 or newer), or set its path with /antigravity path <abs path>");
		assert.deepEqual(menus, [["Set agy's path…", "Close"]], "the menu offers only the path");
		await run(pi, "antigravity", "status", c);
		await run(pi, "antigravity", "add work", c);
		assert.deepEqual(notes.slice(1), [NOT_FOUND, NOT_FOUND]);
		await run(pi, "antigravity", "path relative/agy", c);
		assert.equal(notes.at(-1), "Not an absolute path to an executable file: relative/agy");
		assert.equal(x.providers.length, 0);
		// a path from the menu: the providers and hooks, now (no new command: pi 1.5.2 does not autocomplete one registered after start)
		const m = { ...c, ui: { ...c.ui, select: async () => "Set agy's path…", input: async () => FAKE } };
		await run(pi, "antigravity", "", m);
		assert.match(notes.at(-1)!, new RegExp(`^Antigravity now runs ${FAKE.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}: its models are in /model`));
		assert.deepEqual(x.providers.map((p: any) => p.id), ["antigravity"]);
		assert.deepEqual([...x.commands.keys()], ["antigravity"]);
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

test("with agy: one provider per account (antigravity for the default), only /antigravity (one command, so pi autocompletes it from the start); loading writes and starts nothing", async () => {
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
		assert.deepEqual([...x.commands.keys()], ["antigravity"]);
		assert.deepEqual([...x.tools.keys(), ...x.flags.keys()], []);
		await pi.start();
		assert.equal(f.read().length, 0, "agy is not started by loading or by session start");
		assert.ok(!existsSync(path.join(a.root, "profiles")), "no profile made until agy runs");
		assert.deepEqual(pi.notices, []);
	});
});

test("/antigravity login (no name: the default account, the keychain account): agy's --login in its own profile (GEMINI_HOME, its TMPDIR) in keychain mode, as its sessions run, then its models; sign-out by agy's logout", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity", "login", ctx);
		assert.match(notes[0], /Open this link and sign in with Google:\nhttps:\/\/accounts\.google\.com\/.*\nThen paste the code/s);
		assert.deepEqual(notes.slice(1), ['Signed in to Antigravity (account "default")', '2 models of the Antigravity account "default" in /model (provider antigravity)']);
		const prof = path.join(a.root, "profiles", "default");
		const starts = f.read().filter((m) => m.argv);
		assert.deepEqual(starts[0].argv, ["acp", "--gemini-dir", prof, "--app-data-dir", "antigravity-acp", "--login"]);
		for (const s of starts) {
			assert.equal(path.dirname(s.env.TMPDIR), path.join(prof, "antigravity-acp", "tmp"), "its own folder in the profile's tmp");
			assert.deepEqual({ ...s.env, TMPDIR: undefined }, { GEMINI_HOME: prof, TMPDIR: undefined, AGY_CLI_DISABLE_AUTO_UPDATE: "true", ELECTRON_RUN_AS_NODE: "1" }, "login and sessions alike: no file mode, no SSH_CONNECTION");
		}
		assert.ok(f.read().some((m) => m.loginStored === "keyring"), "signed in where plain agy signs in: the keychain");
		assert.ok(!existsSync(path.join(prof, "antigravity-acp", "acp_token.json")));
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
		assert.match(st.notes[0], /^Antigravity CLI: .*\/agy \(1\.5\.18\)\nAccounts \(.*\):\n- default → antigravity · Google account · signed in \(system keychain, not checked\) · 2 models$/);
		await run(pi, "antigravity", "logout", st.ctx);
		assert.equal(st.notes.at(-1), 'Signed out of Antigravity (account "default", its sign-in in the system keychain, which agy outside Deckhand uses too); its history is kept');
		assert.ok(f.read().some((m) => m.method === "logout"));
		await run(pi, "antigravity", "status", st.ctx);
		assert.match(st.notes.at(-1)!, /default → antigravity · Google account · signed in \(system keychain, not checked\)/, "a stat cannot see the keychain: a hint only");
		assert.ok(!existsSync(path.join(a.home, ".fake-agy-keychain")), "agy signed the keychain out");
	});
});

test("GEMINI_API_KEY, GOOGLE_* and BROWSER in pi's environment never reach agy: an account's credential is its own", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log, GEMINI_API_KEY: "ambient-key", GOOGLE_API_KEY: "ambient-g", GOOGLE_CLOUD_PROJECT: "p", GOOGLE_GENAI_USE_VERTEXAI: "1", BROWSER: "/bin/echo", GEMINI_HOME: "/elsewhere", Gemini_Api_Key: "mixed-case" });
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity", "login", ctx);
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
		const e = agyEnvFor({ name: "default", method: "oauth-personal" }, profileOf(a.root, { name: "default" }), undefined, { Gemini_Api_Key: "x", google_cloud_location: "y", PATH: "/bin", DECKHAND_TOKEN: "t" });
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
		assert.match(notes.at(-2)!, /Added the Antigravity account "work" \(Gemini API key\).*provider antigravity-work\. Next: \/login antigravity-work/);
		assert.match(notes.at(-1)!, /^pi still has an API key for antigravity-work/, "the key here is already in pi's store");
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
		assert.ok(existsSync(path.join(a.root, "profiles", "work", "antigravity-acp", "deckhand-sessions")), "the account's own record of its agy sessions");
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
		assert.match(notes.at(-1)!, /- default → antigravity · Google account · signed in \(in its profile\) · 2 models · the default account\n- work → antigravity-work · Gemini API key · API key saved in pi · 2 models$/);
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
		assert.equal((await turn("antigravity")).msg.errorMessage, 'Antigravity account "default" is not signed in: run /antigravity login');
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
		assert.match(notes.at(-1)!, /^Antigravity CLI: .*fake-agy\.mjs \(1\.5\.18\), set by \/antigravity path\n/);
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
		assert.match(c2.notes[0], new RegExp(`^Antigravity CLI: ${AGY.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")} \\(1\\.5\\.18\\)\\n  The path set by /antigravity path is not an executable file, so agy is taken from PATH: /nowhere/agy\\n`));
	});
});

test("finding 4: closing agy: its stdin first, SIGTERM only when it stays, SIGKILL after the grace", async () => {
	const events = (f: any) => f.read().filter((m: any) => m.event);
	const f = fake();
	const c = new AcpConnection(FAKE, ["acp"], { cwd: f.cwd, env: f.env });
	c.start();
	await c.request("initialize", initializeParams());
	await c.close();
	assert.deepEqual(events(f).map((e: any) => e.event), ["stdin closed"], "an agy that ends on its own gets no signal");
	const h = fake({ FAKE_AGY_HOLD_ON: "1" });
	const d = new AcpConnection(FAKE, ["acp"], { cwd: h.cwd, env: h.env });
	d.start();
	await d.request("initialize", initializeParams());
	const t0 = Date.now();
	await d.close({ stdinWaitMs: 150, termGraceMs: 200 });
	const e = events(h);
	assert.deepEqual(e.map((x: any) => x.event), ["stdin closed", "sigterm"]);
	assert.ok(e[1].t - e[0].t >= 120, `SIGTERM ${e[1].t - e[0].t} ms after stdin closed`);
	assert.equal((await d.exited).signal, "SIGKILL");
	assert.ok(Date.now() - t0 >= 330);
});

test("finding 4: each agy process has its own TMPDIR folder, gone when it ends; leftovers of dead processes are swept, live ones never", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	const prof = path.join(a.root, "profiles", "default");
	const tmp = path.join(prof, "antigravity-acp", "tmp");
	mkdirSync(tmp, { recursive: true });
	writeFileSync(path.join(prof, "antigravity-acp", "acp_token.json"), "{}"); // as if signed in
	const dead = spawnSync("true").pid!; // a process that has ended
	const leftovers = { dead: `${dead}-aaaaaa`, piAlive: `${process.pid}-bbbbbb`, agyAlive: `${dead}-cccccc`, other: "agy-own" };
	for (const d of Object.values(leftovers)) mkdirSync(path.join(tmp, d));
	writeFileSync(path.join(tmp, leftovers.agyAlive, "agy.pid"), String(process.pid));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", "models", ctx);
		assert.match(notes.at(-1)!, /2 models/);
		const used = f.read().filter((m) => m.argv).map((m) => m.env.TMPDIR);
		assert.ok(used.length >= 1);
		for (const t of used) {
			assert.match(t, new RegExp(`^${tmp.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}/${process.pid}-[A-Za-z0-9]{6}$`), "its own folder");
			assert.ok(!existsSync(t), "removed when agy ended");
		}
		assert.ok(!existsSync(path.join(tmp, leftovers.dead)), "a dead process's leftover is swept");
		for (const k of ["piAlive", "agyAlive", "other"] as const) assert.ok(existsSync(path.join(tmp, leftovers[k])), `${k} kept`);
	});
});

test("polish: loading the extension again adds no second exit listener", async () => {
	await withEnv(accountsEnv().env, async () => {
		await loadExtension();
		const before = process.listenerCount("exit");
		for (let i = 0; i < 3; i++) await loadExtension();
		assert.equal(process.listenerCount("exit"), before);
	});
});

test("polish: /antigravity remove without a UI needs --yes", async () => {
	await withEnv(accountsEnv().env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", "add work oauth-personal", ctx);
		const headless = { ...ctx, hasUI: false };
		await run(pi, "antigravity", "remove work", headless);
		assert.equal(notes.at(-1), 'Removing the Antigravity account "work" deletes its profile and history: run /antigravity remove work --yes');
		assert.ok(prov(pi, "antigravity-work") && !pi.extensions[0].unregistered.includes("antigravity-work"), "still there");
		await run(pi, "antigravity", "remove work --yes", headless);
		assert.deepEqual(pi.extensions[0].unregistered, ["antigravity-work"]);
	});
});

test("polish: ADC variables (GOOGLE_APPLICATION_CREDENTIALS, CLOUDSDK_CONFIG, CLOUDSDK_AUTH_*) reach only an Agent Platform account that signs in with ADC", () => {
	const base = { PATH: "/bin", GOOGLE_APPLICATION_CREDENTIALS: "/k.json", CLOUDSDK_CONFIG: "/gc", CLOUDSDK_AUTH_ACCESS_TOKEN_FILE: "/t", cloudsdk_auth_x: "y" };
	const p = profileOf("/r", { name: "x" });
	const adc = (a: any, key?: string) => Object.keys(agyEnvFor(a, p, key, base)).filter((k) => /^(GOOGLE_APPLICATION|CLOUDSDK_(CONFIG|AUTH))/i.test(k)).sort();
	assert.deepEqual(adc({ name: "x", method: "oauth-personal" }), []);
	assert.deepEqual(adc({ name: "x", method: "gemini-api-key" }, "k"), []);
	assert.deepEqual(adc({ name: "x", method: "agent-platform" }, "k"), [], "a key: not ADC");
	assert.deepEqual(adc({ name: "x", method: "agent-platform", gcpProject: "p", gcpLocation: "l" }), ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE", "CLOUDSDK_CONFIG", "GOOGLE_APPLICATION_CREDENTIALS", "cloudsdk_auth_x"]);
});

test("polish: re-adding an API-key account whose old key is still in pi's store says so", async () => {
	await withEnv(accountsEnv().env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi, {}, { "antigravity-k": "old-key" });
		await run(pi, "antigravity", "add k gemini-api-key", ctx);
		assert.match(notes.at(-1)!, /pi still has an API key for antigravity-k \(from before\): it will be used\. To enter another, \/logout and pick antigravity-k, then \/login antigravity-k/);
		assert.ok(!notes.join("\n").includes("old-key"), "never the key itself");
	});
});

test("polish: changing accounts.json waits for another process's change and keeps it", async () => {
	const a = accountsEnv();
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx } = cmdCtx(pi);
		mkdirSync(a.root, { recursive: true });
		const file = path.join(a.root, "accounts.json");
		const other = spawn("sleep", ["5"]); // another pi, changing accounts.json
		writeFileSync(`${file}.lock`, JSON.stringify({ pid: other.pid }));
		const adding = run(pi, "antigravity", "add mine oauth-personal", ctx);
		await new Promise((r) => setTimeout(r, 150));
		writeFileSync(file, JSON.stringify({ accounts: [{ name: "theirs", method: "oauth-personal" }] }));
		rmSync(`${file}.lock`);
		other.kill();
		await adding;
		assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).accounts.map((x: any) => x.name).sort(), ["mine", "theirs"]);
	});
});

test("round 2, finding 5: clearing agy's path with no agy on PATH names only agy", async () => {
	const a = accountsEnv();
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", `path ${FAKE}`, ctx);
		await withEnv({ PATH: mkdtempSync(path.join(TMP_ROOT, "empty-")) }, () => run(pi, "antigravity", "path", ctx));
		assert.equal(notes.at(-1), "Cleared agy's path. There is no agy on your PATH, so Antigravity is off from pi's next start (/antigravity path sets it again)");
	});
});

/** Whether process `pid` exists. */
const pidAlive = (pid: number) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch (e: any) {
		return e?.code === "EPERM";
	}
};
const until = async (f: () => boolean, ms = 3000) => {
	const end = Date.now() + ms;
	while (!f() && Date.now() < end) await new Promise((r) => setTimeout(r, 25));
	return f();
};
const childOf = async (f: any) => {
	await until(() => f.read().some((m: any) => m.event === "child"), 2000);
	return f.read().find((m: any) => m.event === "child")!.pid as number;
};

test("gap A1: agy runs in its own process group; closing it, or pi exiting, ends agy's own children too", async () => {
	const kids: number[] = [];
	try {
		const f = fake({ FAKE_AGY_CHILD: "1" });
		const c = new AcpConnection(FAKE, ["acp"], { cwd: f.cwd, env: f.env });
		c.start();
		await c.request("initialize", initializeParams());
		const kid = await childOf(f);
		kids.push(kid);
		await c.close();
		assert.ok(await until(() => !pidAlive(kid)), "agy's child ended with it");
		const g = fake({ FAKE_AGY_CHILD: "1" });
		const d = new AcpConnection(FAKE, ["acp"], { cwd: g.cwd, env: g.env });
		d.start();
		await d.request("initialize", initializeParams());
		const kid2 = await childOf(g);
		kids.push(kid2);
		d.killNow(); // pi's exit: synchronous
		assert.ok(await until(() => !pidAlive(kid2)), "killNow ends the whole group");
	} finally {
		for (const k of kids) if (pidAlive(k)) process.kill(k, "SIGKILL");
	}
});

test("gap A1: the sweep ends what is left of a dead agy's group before it removes its run folder", async () => {
	const tmp = mkdtempSync(path.join(TMP_ROOT, "runs-"));
	const dead = spawnSync("true").pid!;
	// a group whose leader (the agy) has ended and one member still runs
	const leader = spawn("sh", ["-c", "sleep 60 & echo $!; exit 0"], { detached: true, stdio: ["ignore", "pipe", "ignore"] });
	const member = Number(await new Promise<string>((r) => leader.stdout!.once("data", (d) => r(String(d).trim()))));
	await new Promise((r) => leader.once("exit", r));
	try {
		const dir = path.join(tmp, `${dead}-zzzzzz`);
		mkdirSync(dir);
		writeFileSync(path.join(dir, "agy.pid"), String(leader.pid));
		assert.ok(pidAlive(member));
		await sweepRunDirs(tmp);
		assert.ok(await until(() => !pidAlive(member)), "the leftover member is ended");
		assert.ok(await until(() => !existsSync(dir)), "then the folder goes");
	} finally {
		if (pidAlive(member)) process.kill(member, "SIGKILL");
	}
});

/**
 * Runs f while fs.rmSync and fs.renameSync, the first time they touch `lock`, first put another
 * live process's lock in its place: the moment between seeing a stale lock and taking it over.
 */
async function racing<T>(lock: string, livePid: number, f: () => T | Promise<T>): Promise<T> {
	const fsm = (await import("node:fs")).default as any;
	const { rmSync, renameSync, writeFileSync: write } = fsm;
	let planted = false;
	const plant = (p: unknown) => {
		if (planted || p !== lock) return;
		planted = true;
		const t = `${lock}.planted`;
		write(t, JSON.stringify({ pid: livePid }));
		renameSync(t, lock); // a new file in its place
	};
	fsm.rmSync = (p: any, ...a: any[]) => (plant(p), rmSync(p, ...a));
	fsm.renameSync = (p: any, ...a: any[]) => (plant(p), renameSync(p, ...a));
	try {
		return await f();
	} finally {
		fsm.rmSync = rmSync;
		fsm.renameSync = renameSync;
	}
}

test("gap A2: taking over a stale lock never takes one another process took in the meantime (ledger and accounts.json)", async () => {
	const other = spawn("sleep", ["30"]);
	try {
		const dead = spawnSync("true").pid!;
		const dir = mkdtempSync(path.join(TMP_ROOT, "ledger-"));
		const ledger = fileLedger(dir);
		const lock = path.join(dir, `${createHash("sha256").update("S").digest("hex").slice(0, 32)}.lock`);
		writeFileSync(lock, JSON.stringify({ pid: dead })); // stale
		const me = {};
		const got = await racing(lock, other.pid!, () => ledger.claim("S", me));
		assert.equal(got, false, "the live lock is not taken");
		assert.equal(JSON.parse(readFileSync(lock, "utf8")).pid, other.pid, "and is still there");
		const root = mkdtempSync(path.join(TMP_ROOT, "acct-"));
		const alock = path.join(root, "accounts.json.lock");
		writeFileSync(alock, JSON.stringify({ pid: dead }));
		await assert.rejects(
			racing(alock, other.pid!, () => updateAccounts(root, (accounts) => ({ accounts }), 200)),
			/Another pi .* is changing the Antigravity accounts/,
		);
		assert.equal(JSON.parse(readFileSync(alock, "utf8")).pid, other.pid);
		// a stale lock no one races for is taken over as before
		writeFileSync(lock, JSON.stringify({ pid: dead }));
		assert.equal(ledger.claim("S", me), true);
		writeFileSync(alock, JSON.stringify({ pid: dead }));
		await updateAccounts(root, (accounts) => ({ accounts }), 200);
		assert.ok(!existsSync(alock));
	} finally {
		other.kill();
	}
});

test("gap A3: each launch's sweep prunes session records unused for 30 days and locks of dead processes", async () => {
	const a = accountsEnv();
	const acp = path.join(a.root, "profiles", "default", "antigravity-acp");
	const ledger = path.join(acp, "deckhand-sessions");
	mkdirSync(ledger, { recursive: true });
	writeFileSync(path.join(acp, "acp_token.json"), "{}"); // as if signed in
	const other = spawn("sleep", ["30"]);
	const dead = spawnSync("true").pid!;
	try {
		const files = { old: "a.json", fresh: "b.json", deadLock: "c.lock", liveLock: "d.lock", oldLeft: "e.lock.new-1-x" };
		writeFileSync(path.join(ledger, files.old), JSON.stringify({ sessionId: "old", produced: [] }));
		writeFileSync(path.join(ledger, files.fresh), JSON.stringify({ sessionId: "fresh", produced: [] }));
		writeFileSync(path.join(ledger, files.deadLock), JSON.stringify({ pid: dead }));
		writeFileSync(path.join(ledger, files.liveLock), JSON.stringify({ pid: other.pid }));
		writeFileSync(path.join(ledger, files.oldLeft), "{}");
		const longAgo = new Date(Date.now() - 31 * 86_400_000);
		utimesSync(path.join(ledger, files.old), longAgo, longAgo);
		utimesSync(path.join(ledger, files.oldLeft), longAgo, longAgo);
		await withEnv(a.env, async () => {
			const pi = await loadExtension();
			await pi.start();
			const { ctx, notes } = cmdCtx(pi);
			await run(pi, "antigravity", "models", ctx);
			assert.match(notes.at(-1)!, /2 models/);
		});
		const left = readdirSync(ledger).sort();
		assert.ok(!left.includes(files.old), "a record unused for 31 days goes");
		assert.ok(!left.includes(files.deadLock), "a dead process's lock goes");
		assert.ok(!left.includes(files.oldLeft), "an old leftover temp file goes");
		assert.ok(left.includes(files.fresh) && left.includes(files.liveLock), "the rest stays");
	} finally {
		other.kill();
	}
});

test("gap A4: ending pi's session closes its agy processes in parallel within about 3 s, even ones that ignore stdin and SIGTERM", async () => {
	const r = rig({ FAKE_AGY_HOLD_ON: "1" });
	await r.turn("one", { sessionId: "pi-1" });
	await r.turn("two", { sessionId: "pi-2" });
	const t0 = Date.now();
	await r.ag.closeAll();
	const took = Date.now() - t0;
	assert.ok(took >= 2500 && took < 3800, `closed in ${took} ms`);
	assert.equal(r.f.read().filter((m) => m.event === "sigterm").length, 2, "both got SIGTERM after their stdin closed");
});

test("gap A5: an agy run folder is made only when agy starts, and removed when it ends or fails to start", async () => {
	const tmp = mkdtempSync(path.join(TMP_ROOT, "runs-"));
	const made: string[] = [];
	const makeRunDir = () => {
		const d = mkdtempSync(path.join(tmp, `${process.pid}-`));
		made.push(d);
		return d;
	};
	const f = fake();
	const c = new AcpConnection(FAKE, ["acp"], { cwd: f.cwd, env: f.env, makeRunDir });
	assert.equal(made.length, 0, "not before agy starts");
	c.start();
	await c.request("initialize", initializeParams());
	assert.equal(made.length, 1);
	assert.equal(f.read().find((m) => m.argv).env.TMPDIR, made[0], "agy's TMPDIR");
	await c.close();
	assert.ok(!existsSync(made[0]), "gone once agy ended");
	const broken = new AcpConnection(FAKE, ["acp"], { cwd: f.cwd, env: f.env, makeRunDir, spawnImpl: (() => { throw new Error("no spawn"); }) as any });
	assert.throws(() => broken.start(), /no spawn/);
	assert.equal(made.length, 2);
	assert.ok(!existsSync(made[1]), "a start that throws leaves no folder");
	assert.deepEqual(readdirSync(tmp), []);
});
test("agy 1.5.18: every agy Deckhand starts (sessions, probes, the login) has AGY_CLI_DISABLE_AUTO_UPDATE=true, whatever env it is given", async () => {
	const f = fake({ AGY_CLI_DISABLE_AUTO_UPDATE: "false" });
	const c = new AcpConnection(FAKE, ["acp"], { cwd: f.cwd, env: f.env });
	c.start();
	await c.request("initialize", initializeParams());
	await c.close();
	await agyVersion({ agyPath: FAKE, cwd: f.cwd, env: f.env });
	await agyLogin({ agyPath: FAKE, cwd: f.cwd, env: f.env, showLink: () => {}, askCode: async () => "good-code" });
	const starts = f.read().filter((m) => m.argv);
	assert.equal(starts.length, 3);
	for (const s of starts) assert.equal(s.env.AGY_CLI_DISABLE_AUTO_UPDATE, "true", s.argv.join(" "));
});

test("agy 1.5.18's initialize: protocol 1, a bare version, its capabilities; images go only when promptCapabilities.image, audio only when .audio", async () => {
	const f = fake();
	const s = await AgySession.open({ agyPath: FAKE, cwd: f.cwd, env: f.env });
	try {
		assert.equal(s.initialize.protocolVersion, 1);
		assert.deepEqual(s.initialize.agentInfo, { name: "Antigravity ACP Server", version: "1.5.18" });
		assert.deepEqual(s.initialize.agentCapabilities.promptCapabilities, { image: true, audio: false, embeddedContext: true });
		assert.equal(s.initialize.agentCapabilities.mcpCapabilities, undefined);
		assert.equal(s.agentVersion, "1.5.18");
		const img = { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" };
		const audio = { type: "audio", mimeType: "audio/wav", data: "UklGRg==" };
		await s.prompt([{ type: "text", text: "look" }, img, audio]);
		const sent = f.read().filter((m) => m.method === "session/prompt").at(-1).params.prompt;
		assert.deepEqual(sent.map((b: any) => b.type), ["text", "image", "text"], "the image goes; the audio becomes a note");
		assert.match(sent[2].text, /audio .*left out/i);
	} finally {
		await s.close();
	}
	const g = fake({ FAKE_AGY_NO_IMAGE: "1" });
	const t = await AgySession.open({ agyPath: FAKE, cwd: g.cwd, env: g.env });
	try {
		await t.prompt([{ type: "text", text: "look" }, { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }]);
		const sent = g.read().filter((m) => m.method === "session/prompt").at(-1).params.prompt;
		assert.deepEqual(sent.map((b: any) => b.type), ["text", "text"]);
		assert.match(sent[1].text, /image .*left out/i);
	} finally {
		await t.close();
	}
	// the prefixed form some builds report still parses
	const p = fake({ FAKE_AGY_VERSION: "agy_acp_server_1.5.12" });
	const u = await AgySession.open({ agyPath: FAKE, cwd: p.cwd, env: p.env });
	assert.equal(u.agentVersion, "agy_acp_server_1.5.12");
	await u.close();
});

test("agy 1.5.18's --login output: three lines, the link indented two spaces; a bare code or the full page URL is accepted; stdin's end cancels", async () => {
	const AGY_LOGIN_OUT = ["Open this link in a browser to log in with Google:", `  ${LINK}`, "Then paste the authorization code, or the full URL of the page you land on, and press Enter:"];
	// the fake prints exactly that
	const raw = spawnSync(process.execPath, [FAKE, "acp", "--login"], { input: "", encoding: "utf8", env: fake().env });
	assert.deepEqual(raw.stdout.split("\n").slice(0, 3), AGY_LOGIN_OUT);
	assert.equal(raw.stdout.split("\n")[3], "login cancelled: no authorization code was entered");
	assert.equal(raw.status, 1);
	// the indented link line is the link
	assert.equal(linkInLine(AGY_LOGIN_OUT[1])?.url, LINK);
	assert.equal(linkInLine(AGY_LOGIN_OUT[0]), undefined);
	assert.equal(linkInLine(AGY_LOGIN_OUT[2]), undefined);
	// the full URL of the page landed on, as agy takes it
	const f = fake();
	const page = "https://antigravity.google/oauth-callback?state=s123&code=good-code";
	assert.deepEqual(await agyLogin({ agyPath: FAKE, cwd: f.cwd, env: f.env, showLink: () => {}, askCode: async () => page }), { ok: true });
	assert.equal(f.read().find((m) => m.loginCode)?.loginCode, page);
});

test("agy 1.5.18's logs: each launch's sweep keeps the newest 20 log/acp-server-*.log per profile, and never one whose agy still runs", async () => {
	const a = accountsEnv();
	const prof = path.join(a.root, "profiles", "default");
	const acp = path.join(prof, "antigravity-acp");
	mkdirSync(acp, { recursive: true });
	writeFileSync(path.join(acp, "acp_token.json"), "{}"); // as if signed in
	const other = spawn("sleep", ["30"]);
	const dead = spawnSync("true").pid!;
	try {
		const logs = path.join(prof, "log");
		mkdirSync(logs, { recursive: true });
		const at = (name: string, ageMin: number) => {
			const p = path.join(logs, name);
			writeFileSync(p, "x");
			const t = new Date(Date.now() - ageMin * 60_000);
			utimesSync(p, t, t);
		};
		for (let i = 0; i < 25; i++) at(`acp-server-2026-11-${String(i + 1).padStart(2, "0")}-${dead}.log`, 100 + i);
		at(`acp-server-2026-10-01-${other.pid}.log`, 10_000); // the oldest, but its agy still runs
		at("notes.txt", 10_000); // not agy's log
		await withEnv(a.env, async () => {
			const pi = await loadExtension();
			await pi.start();
			const { ctx, notes } = cmdCtx(pi);
			await run(pi, "antigravity", "models", ctx);
			assert.match(notes.at(-1)!, /2 models/);
		});
		const left = readdirSync(logs).sort();
		const dropped = Array.from({ length: 5 }, (_, i) => `acp-server-2026-11-${String(25 - i).padStart(2, "0")}-${dead}.log`); // the 5 oldest dead ones
		for (const d of dropped) assert.ok(!left.includes(d), `${d} goes`);
		assert.equal(left.filter((f) => f.endsWith(`-${dead}.log`)).length, 20);
		assert.ok(left.includes(`acp-server-2026-10-01-${other.pid}.log`), "a running agy's log stays");
		assert.ok(left.includes("notes.txt"));
	} finally {
		other.kill();
	}
});

test("agy-seen.json: the version agy reported, with the binary's size and mtime, for Deckhand's checklist to read without running agy; never at load", async () => {
	const a = accountsEnv();
	const acp = path.join(a.root, "profiles", "default", "antigravity-acp");
	mkdirSync(acp, { recursive: true });
	writeFileSync(path.join(acp, "acp_token.json"), "{}"); // as if signed in
	const seen = path.join(a.root, "agy-seen.json");
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		assert.ok(!existsSync(seen), "nothing at load");
		const { ctx } = cmdCtx(pi);
		await run(pi, "antigravity", "models", ctx);
	});
	const st = statSync(realpathSync(AGY));
	assert.deepEqual(JSON.parse(readFileSync(seen, "utf8")), { path: AGY, size: st.size, mtime: Math.floor(st.mtimeMs / 1000), version: "1.5.18" });
	assert.equal(statSync(seen).mode & 0o777, 0o600);
});

const signIn = (root: string, name = "default") => {
	const acp = path.join(root, "profiles", name, "antigravity-acp");
	mkdirSync(acp, { recursive: true });
	writeFileSync(path.join(acp, "acp_token.json"), "{}");
};

test("the antigravity tool: with agy, registered at session start (never while loading), whether or not a sign-in file is there (agy may sign in from the keychain: it says when it cannot)", async () => {
	const a = accountsEnv();
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		assert.deepEqual([...pi.extensions[0].tools.keys()], [], "nothing while loading");
		await pi.start();
		assert.ok(!existsSync(path.join(a.root, "profiles", "default", "antigravity-acp", "acp_token.json")));
		const t = pi.extensions[0].tools.get("antigravity");
		assert.ok(t, "registered with no sign-in file");
		assert.match(t.description, /self-contained task/);
		assert.deepEqual(Object.keys(t.parameters.properties).sort(), ["account", "model", "task"]);
	});
	const empty = { ...a.env, PATH: mkdtempSync(path.join(TMP_ROOT, "empty-")) };
	await withEnv(empty, async () => {
		const pi = await loadExtension();
		await pi.start();
		assert.equal(pi.extensions[0].tools.get("antigravity"), undefined, "no agy: no tool");
	});
});

test("the antigravity tool: a fresh agy session in the tab's folder, default mode, progress as updates, agy's final answer back; refusals and abort as in tabs", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	signIn(a.root);
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const t = pi.extensions[0].tools.get("antigravity");
		const cwd = mkdtempSync(path.join(TMP_ROOT, "proj-"));
		const ctx = { ...pi.ctx, cwd };
		const updates: string[] = [];
		const r = await t.execute("c1", { task: "summarize the repo" }, undefined, (u: any) => updates.push(u.content[0].text), ctx);
		assert.match(r.content[0].text, /summarize the repo/, "agy's final answer (the fake echoes)");
		assert.ok(updates.length > 0 && updates.some((u) => /→ /.test(u)), "tool calls as progress");
		const starts = f.read().filter((m) => m.argv);
		assert.equal(starts.at(-1).cwd, realpathSync(cwd));
		assert.equal(starts.at(-1).env.AGY_CLI_DISABLE_AUTO_UPDATE, "true");
		assert.equal(starts.at(-1).env.GEMINI_API_KEY, undefined);
		const ms = methods(f.read());
		assert.ok(ms.indexOf("session/new") >= 0 && !ms.includes("session/resume"), "a fresh session");
		const before = f.read().filter((m) => m.method === "session/prompt").at(-1);
		assert.equal(before.params.prompt.at(-1).text, "summarize the repo");
		// a permission request is answered as in tabs (test/agy-approvals.test.ts): allowed once here;
		// a question with no UI is not answered, and the caller is told
		const p = await t.execute("c2", { task: "permission please" }, undefined, () => {}, ctx);
		assert.match(p.content[0].text, /"optionId":"allow"/, "agy's allow_once");
		const q = await t.execute("c2q", { task: "question" }, undefined, () => {}, { ...ctx, hasUI: false });
		assert.match(q.content[0].text, /Refused: question not answered \(no UI\): Which file\?/);
		// abort: session/cancel, and the call fails
		const ac = new AbortController();
		const slow = t.execute("c3", { task: "slow" }, ac.signal, () => {}, ctx);
		setTimeout(() => ac.abort(), 300);
		await assert.rejects(slow, /cancel/i);
		assert.ok(methods(f.read()).includes("session/cancel"));
		// an account that is not signed in (or does not exist)
		await assert.rejects(t.execute("c4", { task: "x", account: "nope" }, undefined, () => {}, ctx), /No signed-in Antigravity account "nope"/);
	});
	const g = fake();
	const b = accountsEnv({ FAKE_AGY_LOG: g.log, FAKE_AGY_NO_MODE_AT_ALL: "1" });
	signIn(b.root);
	await withEnv(b.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const t = pi.extensions[0].tools.get("antigravity");
		await assert.rejects(t.execute("c5", { task: "hello" }, undefined, () => {}, pi.ctx), /default mode/);
		assert.ok(!methods(g.read()).includes("session/prompt"), "fail closed: no prompt");
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
	assert.equal(dataRoot({ HOME: "/h", XDG_DATA_HOME: "/x" }, "linux"), "/h/.local/share/deckhand/antigravity", "as the core: never XDG_DATA_HOME");
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

test("round 2, finding 1: agy changing its mode or model between turns is seen; default and the chosen model are set again before the next prompt", async () => {
	for (const [what, want] of [["mode", /mode default/], ["model", /model gemini-3\.8-pro/]] as const) {
		const r = rig({ FAKE_AGY_DRIFT_BETWEEN: what });
		const pro = { ...MODEL, id: "gemini-3.8-pro" }; // a model picked in /model (not agy's own pick)
		try {
			await r.turn("one", {}, pro);
			await new Promise((res) => setTimeout(res, 50)); // agy's update arrives between turns
			const two = await r.turn("two", {}, pro);
			assert.equal(two.msg.stopReason, "stop", what);
			assert.match(textOfMsg(two.msg), want, `${what}: set back before turn 2`);
		} finally {
			await r.ag.closeAll();
		}
	}
});

test("round 2, finding 1: agy switching its mode during a turn is shown; the next prompt goes out only once default is back", async () => {
	const r = rig({ FAKE_AGY_DRIFT_DURING: "mode" });
	try {
		const one = await r.turn("one");
		assert.match(thinkingOf(one.msg), /Antigravity switched to its auto mode during this turn/);
		const two = await r.turn("two");
		assert.match(textOfMsg(two.msg), /mode default/);
	} finally {
		await r.ag.closeAll();
	}
	const s = rig({ FAKE_AGY_DRIFT_BETWEEN: "mode", FAKE_AGY_DRIFT_STICKY: "1" });
	try {
		await s.turn("one");
		await new Promise((res) => setTimeout(res, 50));
		const before = s.prompts().length;
		const two = await s.turn("two");
		assert.equal(two.msg.stopReason, "error");
		assert.match(two.msg.errorMessage, /cannot confirm that Antigravity runs in its default mode/);
		assert.equal(s.prompts().length, before, "refused before the prompt");
	} finally {
		await s.ag.closeAll();
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


test("finding 1: /fork never writes into the agy session another pi session holds, nor resumes one ahead of its branch", async () => {
	const ledgerDir = mkdtempSync(path.join(TMP_ROOT, "ledger-"));
	const r = rig({}, { ledgerDir });
	const forkTurn = async (key: string, msgs: any[]) => drive(r.ag.provider.streamSimple(MODEL, { messages: msgs }, { sessionId: key }));
	try {
		const a1 = (await r.turn("one")).msg;
		const a2 = (await r.turn("two")).msg;
		const S = a2.responseId;
		assert.equal(a1.responseId, S);
		// a fork from the earlier answer: S holds "two" as well, which this branch does not have
		const early = await forkTurn("pi-fork-early", [SYS, r.messages[1], a1, user("forked early")]);
		assert.equal(early.msg.stopReason, "stop");
		assert.notEqual(early.msg.responseId, S, "a new agy session");
		assert.match(r.prompts().at(-1)![0].text, /^\[The conversation so far[\s\S]*User: one/);
		// a fork from the latest answer, while pi-1 still holds S
		const late = await forkTurn("pi-fork-late", [SYS, r.messages[1], a1, r.messages[3], a2, user("forked late")]);
		assert.notEqual(late.msg.responseId, S, "S is pi-1's: never two pi sessions in one agy session");
		assert.ok(!r.f.read().some((m) => m.method === "session/resume"), "S was never resumed");
		const own = await r.turn("three");
		assert.equal(own.msg.responseId, S, "pi-1 goes on in S");
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: "three" }]);
	} finally {
		await r.ag.closeAll();
	}
});

test("finding 1: a new pi process resumes an agy session only from its latest answer; an older branch gets a new session", async () => {
	const ledgerDir = mkdtempSync(path.join(TMP_ROOT, "ledger-"));
	const r = rig({}, { ledgerDir });
	const a1 = (await r.turn("one")).msg;
	const a2 = (await r.turn("two")).msg;
	await r.ag.closeAll();
	const again = () => createAntigravity({ agyPath: FAKE, cwd: () => r.f.cwd, env: r.f.env, ledgerDir });
	const p1 = again();
	try {
		// /resume onto the older branch after a restart
		const older = await drive(p1.provider.streamSimple(MODEL, { messages: [SYS, r.messages[1], a1, user("older branch")] }, { sessionId: "pi-1" }));
		assert.equal(older.msg.stopReason, "stop");
		assert.notEqual(older.msg.responseId, a1.responseId);
		assert.ok(!r.f.read().some((m) => m.method === "session/resume"));
		assert.match(r.prompts().at(-1)![0].text, /^\[The conversation so far[\s\S]*User: one/);
	} finally {
		await p1.closeAll();
	}
	const p2 = again();
	try {
		const latest = await drive(p2.provider.streamSimple(MODEL, { messages: [...r.messages, user("latest branch")] }, { sessionId: "pi-2" }));
		assert.equal(latest.msg.responseId, a2.responseId, "the latest answer: resumed");
		assert.deepEqual(r.prompts().at(-1), [{ type: "text", text: "latest branch" }]);
	} finally {
		await p2.closeAll();
	}
	const p3 = again();
	try {
		const none = createAntigravity({ agyPath: FAKE, cwd: () => r.f.cwd, env: r.f.env });
		const blind = await drive(none.provider.streamSimple(MODEL, { messages: [...r.messages, user("no record")] }, { sessionId: "pi-3" }));
		assert.notEqual(blind.msg.responseId, a2.responseId, "no record of agy's sessions: never resumed");
		await none.closeAll();
	} finally {
		await p3.closeAll();
	}
});

test("round 2, finding 2: a resume that does not happen (agy fails it, or cannot resume) leaves the agy session free for another pi session", async () => {
	for (const knob of ["FAKE_AGY_RESUME_FAIL", "FAKE_AGY_NO_RESUME"]) {
		const ledgerDir = mkdtempSync(path.join(TMP_ROOT, "ledger-"));
		const r = rig({}, { ledgerDir });
		const a1 = (await r.turn("one")).msg;
		await r.ag.closeAll();
		const tried = createAntigravity({ agyPath: FAKE, cwd: () => r.f.cwd, env: { ...r.f.env, [knob]: "1" }, ledgerDir });
		const other = createAntigravity({ agyPath: FAKE, cwd: () => r.f.cwd, env: r.f.env, ledgerDir });
		try {
			const t = await drive(tried.provider.streamSimple(MODEL, { messages: [...r.messages, user("try")] }, { sessionId: "pi-a" }));
			assert.notEqual(t.msg.responseId === a1.responseId && t.msg.stopReason === "stop", true, `${knob}: not resumed`);
			const o = await drive(other.provider.streamSimple(MODEL, { messages: [...r.messages, user("other")] }, { sessionId: "pi-b" }));
			assert.equal(o.msg.responseId, a1.responseId, `${knob}: the session is free, so the other pi session resumes it`);
		} finally {
			await tried.closeAll();
			await other.closeAll();
		}
	}
});

test("round 2, finding 3: closeAll gives up an agy session's lock only after agy has ended", async () => {
	const ledgerDir = mkdtempSync(path.join(TMP_ROOT, "ledger-"));
	const r = rig({}, { ledgerDir });
	const a1 = (await r.turn("one")).msg;
	const lock = path.join(ledgerDir, `${createHash("sha256").update(a1.responseId).digest("hex").slice(0, 32)}.lock`);
	assert.ok(existsSync(lock));
	const closing = r.ag.closeAll();
	assert.ok(existsSync(lock), "agy is still ending: the lock stays");
	await closing;
	assert.ok(!existsSync(lock), "released once agy ended");
});

test("round 2, finding 4: a resumed session that cannot confirm its default mode gives way to a new one, caught up; a new one that cannot either is refused", async () => {
	const ledgerDir = mkdtempSync(path.join(TMP_ROOT, "ledger-"));
	const r = rig({}, { ledgerDir });
	const a1 = (await r.turn("one")).msg;
	await r.ag.closeAll();
	const p = createAntigravity({ agyPath: FAKE, cwd: () => r.f.cwd, env: { ...r.f.env, FAKE_AGY_RESUME_NO_MODES: "1" }, ledgerDir });
	try {
		const t = await drive(p.provider.streamSimple(MODEL, { messages: [...r.messages, user("after")] }, { sessionId: "pi-1" }));
		assert.equal(t.msg.stopReason, "stop", "not an error every turn");
		assert.notEqual(t.msg.responseId, a1.responseId);
		const sent = r.prompts().at(-1)!;
		assert.match(sent[0].text, /^\[The conversation so far[\s\S]*User: one/);
		assert.deepEqual(sent.at(-1), { type: "text", text: "after" });
	} finally {
		await p.closeAll();
	}
	const none = rig({ FAKE_AGY_NO_MODE_AT_ALL: "1" });
	try {
		const t = await none.turn("hi");
		assert.equal(t.msg.stopReason, "error");
		assert.match(t.msg.errorMessage, /cannot confirm that Antigravity runs in its default mode/);
		assert.deepEqual(none.prompts(), []);
	} finally {
		await none.ag.closeAll();
	}
});
test("pi restarted: a new provider resumes the agy session named on the transcript's last answer (the record says it ends there)", async () => {
	const ledgerDir = mkdtempSync(path.join(TMP_ROOT, "ledger-"));
	const r = rig({}, { ledgerDir });
	const first = await r.turn("hi");
	await r.ag.closeAll();
	const again = createAntigravity({ agyPath: FAKE, cwd: () => r.f.cwd, env: r.f.env, ledgerDir });
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
	assert.equal((planTurn([u("x"), a(5), u("y")], { acpSessionId: "T", produced: [] }) as any).mode, "new", "no record of S: never resumed");
	const seen: any[] = [];
	const { prior, ...resume } = planTurn([u("x"), a(5), u("y")], { acpSessionId: "T", produced: [] }, "antigravity", (id, ts) => (seen.push([id, ts]), true)) as any;
	assert.deepEqual(seen, [["S", 5]]);
	assert.deepEqual(resume, { blocks: [{ type: "text", text: "y" }], mode: "resume", resumeId: "S" });
	assert.deepEqual(prior, [u("x"), a(5)], "the transcript to catch agy up with, if it cannot resume");
	const retried = { acpSessionId: "S", produced: [{ ts: 5, ok: true }, { ts: 6, ok: false }] };
	assert.equal((planTurn([u("x"), a(5), u("y")], retried) as any).mode, "continue", "pi dropped the failed attempt and retries");
	const ahead = { acpSessionId: "S", produced: [{ ts: 5, ok: true }, { ts: 7, ok: true }] };
	assert.equal((planTurn([u("x"), a(5), u("y")], ahead) as any).mode, "new", "agy is ahead of this branch");
	assert.equal((planTurn([u("x"), a(5, "openai"), u("y")], st) as any).mode, "new");
});

test("approvals inside a turn (no UI, no guardrails rules: lib/agy-approvals.ts): a command allowed once and shown in the thinking; a question cancelled", async () => {
	const r = rig();
	try {
		const { msg } = await r.turn("permission please");
		assert.equal(textOfMsg(msg), 'permission:{"outcome":{"outcome":"selected","optionId":"allow"}}', "allow_once, never allow_always");
		assert.match(thinkingOf(msg), /→ Run rm -rf build\n✓ ran: rm -rf build\n/);
		const q = await r.turn("question");
		assert.match(thinkingOf(q.msg), /✗ question not answered \(no UI\): Which file\?/);
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
	assert.equal(a.msg.errorMessage, "Antigravity is not signed in: run /antigravity login");
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

// ---- accounts.json shared with Deckhand's core (PR #211) ----

/** accounts.json in the core's shape: unknown keys at the top and in accounts, entries the extension cannot use. */
const coreFile = (dirs: { work: string; gemini: string }) => ({
	about: "Deckhand's Antigravity accounts",
	agyPath: FAKE,
	defaultAccount: "work",
	removedDirs: ["/abs/.gemini-old"],
	coreOnly: { version: 3, flags: ["a"] },
	accounts: [
		{ name: "default", method: "oauth-personal" },
		{ name: "work", method: "oauth-personal", label: "Work", dir: dirs.work, source: "found", storage: "file", seenAt: 17 },
		{ name: "gemini", method: "oauth-personal", label: "Gemini", dir: dirs.gemini, source: "found", storage: "keyring", extra: { x: 1 } },
		{ name: "future", method: "some-new-method", note: "a method this extension does not know" },
		{ name: "rel", method: "oauth-personal", dir: "relative/dir" },
	],
});
const readJson = (f: string) => JSON.parse(readFileSync(f, "utf8"));

test("accounts.json round trip: what the extension does not understand survives its writes; only the intended edit changes", async () => {
	const root = mkdtempSync(path.join(TMP_ROOT, "acct-"));
	const file = path.join(root, "accounts.json");
	const orig = coreFile({ work: "/Users/u/.gemini-work", gemini: "/Users/u/.gemini" });
	writeFileSync(file, JSON.stringify(orig));
	assert.deepEqual(storedAccounts(root).map((a) => a.name), ["default", "work", "gemini"], "an unknown method and a relative dir are ignored");
	await updateAccounts(root, (accounts) => ({ accounts }));
	assert.deepEqual(readJson(file), orig, "no change: the file as it was");
	await updateAccounts(root, (accounts) => ({ accounts: [...accounts, { name: "new", method: "gemini-api-key" }] }));
	assert.deepEqual(readJson(file), { ...orig, accounts: [...orig.accounts, { name: "new", method: "gemini-api-key" }] });
	await updateAccounts(root, (accounts) => ({ accounts: accounts.filter((a) => a.name !== "new").map((a) => (a.name === "gemini" ? { ...a, storage: "file" as const } : a)) }));
	const g = { ...orig.accounts[2], storage: "file" };
	assert.deepEqual(readJson(file), { ...orig, accounts: [orig.accounts[0], orig.accounts[1], g, ...orig.accounts.slice(3)] }, "one key of one entry, its unknown keys kept");
	await updateAccounts(root, (accounts, rest) => {
		assert.deepEqual(rest, { agyPath: FAKE, defaultAccount: "work", removedDirs: ["/abs/.gemini-old"] });
		return { accounts: accounts.filter((a) => a.name !== "work"), defaultAccount: null, removedDirs: [...rest.removedDirs, "/Users/u/.gemini-work"] };
	});
	const { defaultAccount: _d, ...noDefault } = orig;
	assert.deepEqual(readJson(file), { ...noDefault, removedDirs: ["/abs/.gemini-old", "/Users/u/.gemini-work"], accounts: [orig.accounts[0], g, ...orig.accounts.slice(3)] });
	assert.equal(statSync(file).mode & 0o777, 0o600);
	assert.deepEqual(readdirSync(root).sort(), ["accounts.json"], "no temp file or lock left");
});

test("accounts.json lock, as the core takes it: a live holder is waited for, then 'try again'; a dead one's taken over; an empty lock is respected for 2 s; the change applies to the file read inside the lock", async () => {
	const root = mkdtempSync(path.join(TMP_ROOT, "acct-"));
	const file = path.join(root, "accounts.json"), lock = `${file}.lock`;
	writeFileSync(file, JSON.stringify({ accounts: [{ name: "a", method: "oauth-personal" }] }));
	const add = (name: string) => (accounts: any[]) => ({ accounts: [...accounts, { name, method: "oauth-personal" as const }] });
	const other = spawn("sleep", ["30"]);
	try {
		writeFileSync(lock, JSON.stringify({ pid: other.pid })); // the core's lock: {"pid":N}
		const t0 = Date.now();
		await assert.rejects(updateAccounts(root, add("b"), 400), new RegExp(`Another pi \\(process ${other.pid}\\) is changing the Antigravity accounts: try again`));
		assert.ok(Date.now() - t0 >= 400, "it waited");
		assert.equal(readJson(lock).pid, other.pid, "the holder's lock untouched");
		assert.deepEqual(readJson(file).accounts.map((x: any) => x.name), ["a"], "nothing written");
		// a dead holder's lock is taken over
		writeFileSync(lock, JSON.stringify({ pid: spawnSync("true").pid }));
		await updateAccounts(root, add("b"), 400);
		assert.deepEqual(readJson(file).accounts.map((x: any) => x.name), ["a", "b"]);
		assert.ok(!existsSync(lock));
		// an empty lock (its writer between creating and filling it) is respected while young, taken over once older than 2 s
		writeFileSync(lock, "");
		await assert.rejects(updateAccounts(root, add("c"), 300), /try again/);
		const old = (Date.now() - 3000) / 1000;
		utimesSync(lock, old, old);
		await updateAccounts(root, add("c"), 300);
		assert.deepEqual(readJson(file).accounts.map((x: any) => x.name), ["a", "b", "c"]);
		// a concurrent writer (the core) changes the file after the extension first read it, while it holds the lock
		const seenFirst = storedAccounts(root).map((x) => x.name);
		writeFileSync(lock, JSON.stringify({ pid: other.pid }));
		const mine = updateAccounts(root, add("mine"), 3000);
		await new Promise((r) => setTimeout(r, 150));
		writeFileSync(file, JSON.stringify({ coreKey: true, accounts: [{ name: "theirs", method: "oauth-personal", coreField: 1 }] }));
		rmSync(lock);
		await mine;
		assert.deepEqual(seenFirst, ["a", "b", "c"]);
		assert.deepEqual(readJson(file), { coreKey: true, about: readJson(file).about, accounts: [{ name: "theirs", method: "oauth-personal", coreField: 1 }, { name: "mine", method: "oauth-personal" }] }, "applied to what the core wrote, its keys kept");
	} finally {
		other.kill();
	}
});

test("a folder used in place (dir): agy runs in it; never chmod'ed, nothing linked in, settings only in antigravity-acp/; remove keeps it and records a found one in removedDirs", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	const own = mkdtempSync(path.join(TMP_ROOT, "users-gemini-work-"));
	chmodSync(own, 0o755);
	writeFileSync(path.join(own, "mine.txt"), "the user's own");
	mkdirSync(a.root, { recursive: true });
	const file = path.join(a.root, "accounts.json");
	writeFileSync(file, JSON.stringify({ accounts: [{ name: "work", method: "oauth-personal", label: "Work", dir: own, source: "found" }, { name: "picked", method: "oauth-personal", dir: own, source: "added" }] }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		assert.deepEqual(pi.extensions[0].providers.map((p: any) => p.id), ["antigravity", "antigravity-work", "antigravity-picked"]);
		const { ctx, notes } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity", "login work", ctx);
		assert.equal(notes[1], 'Signed in to Antigravity (account "work")');
		const starts = f.read().filter((m) => m.argv);
		assert.deepEqual(starts[0].argv, ["acp", "--gemini-dir", own, "--app-data-dir", "antigravity-acp", "--login"]);
		for (const s of starts) {
			assert.equal(s.env.GEMINI_HOME, own);
			assert.equal(s.env.SSH_CONNECTION, "127.0.0.1 0 127.0.0.1 0", "a file account");
			assert.equal(path.dirname(s.env.TMPDIR), path.join(own, "antigravity-acp", "tmp"));
		}
		assert.equal(statSync(own).mode & 0o777, 0o755, "never chmod'ed");
		assert.equal(statSync(path.join(own, "antigravity-acp")).mode & 0o777, 0o700);
		assert.deepEqual(readJson(path.join(own, "antigravity-acp", "settings.json")), { auth: { type: "oauth-personal" } });
		assert.deepEqual(readdirSync(own).sort(), ["antigravity-acp", "mine.txt"], "no settings.json, no links, nothing else in the user's folder");
		assert.ok(!existsSync(path.join(a.root, "profiles", "work")), "no profile under profiles/");
		const st = cmdCtx(pi);
		await run(pi, "antigravity", "status", st.ctx);
		assert.match(st.notes[0], new RegExp(`- work \\(Work\\) → antigravity-work · Google account · folder ${own.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")} · signed in \\(in its profile\\) · 2 models`));
		// remove: the entry goes, the folder (and its sign-in) stay; no sign-out
		const before = f.read().length;
		await run(pi, "antigravity", "remove work", st.ctx);
		assert.equal(st.notes.at(-1), `Removed the Antigravity account "work"; its folder ${own} is kept`);
		assert.ok(existsSync(path.join(own, "mine.txt")) && existsSync(path.join(own, "antigravity-acp", "acp_token.json")));
		assert.ok(!f.read().slice(before).some((m) => m.method === "logout" || m.argv), "agy not even started");
		assert.deepEqual(pi.extensions[0].unregistered, ["antigravity-work"]);
		assert.deepEqual(readJson(file).removedDirs, [own]);
		assert.deepEqual(readJson(file).accounts.map((x: any) => x.name), ["picked"]);
		// one the user picked (added): no removedDirs entry
		await run(pi, "antigravity", "remove picked --yes", { ...st.ctx, hasUI: false });
		assert.deepEqual(readJson(file).removedDirs, [own]);
		assert.ok(existsSync(own));
	});
});

test("the keyring account: only the first storage:keyring entry runs in keychain mode (no SSH_CONNECTION, no file storage), its sign-in too; every other account in file mode (AGY_CLI_FORCE_FILE_TOKEN_STORAGE)", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	const gemini = path.join(a.home, ".gemini");
	mkdirSync(a.root, { recursive: true });
	const file = path.join(a.root, "accounts.json");
	writeFileSync(file, JSON.stringify({ accounts: [{ name: "gemini", method: "oauth-personal", dir: gemini, source: "found", storage: "keyring" }, { name: "second", method: "oauth-personal", storage: "keyring" }] }));
	const [g, second] = storedAccounts(a.root);
	assert.deepEqual([g.keyring, second.keyring], [true, undefined]);
	assert.equal(loadAccounts(a.root)[0].keyring, undefined, "an entry holds the keychain: the default does not");
	const e1 = agyEnvFor(g, profileOf(a.root, g), undefined, { PATH: "/bin", AGY_CLI_FORCE_FILE_TOKEN_STORAGE: "1" });
	assert.equal(e1.SSH_CONNECTION, undefined);
	assert.equal(e1.AGY_CLI_FORCE_FILE_TOKEN_STORAGE, undefined, "not even pi's own");
	assert.equal(e1.AGY_ACP_FORCE_FILE_STORAGE, undefined);
	assert.equal(agyEnvFor(g, profileOf(a.root, g), undefined, { SSH_CONNECTION: "10.0.0.1 5 10.0.0.2 22" }).SSH_CONNECTION, "10.0.0.1 5 10.0.0.2 22", "a real SSH session's is left as it is");
	const e2 = agyEnvFor(second, profileOf(a.root, second), undefined, {});
	assert.deepEqual([e2.SSH_CONNECTION, e2.AGY_CLI_FORCE_FILE_TOKEN_STORAGE, e2.AGY_ACP_FORCE_FILE_STORAGE], ["127.0.0.1 0 127.0.0.1 0", "1", undefined], "a second keyring entry is a file account");
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const st = cmdCtx(pi);
		await run(pi, "antigravity", "status", st.ctx);
		assert.match(st.notes[0], /- gemini → antigravity-gemini · Google account · folder .*\/\.gemini · signed in \(system keychain, not checked\) · models not listed yet/);
		const { ctx, notes } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity", "login gemini", ctx);
		assert.equal(notes[1], 'Signed in to Antigravity (account "gemini")');
		const login = f.read().find((m) => m.argv?.includes("--login"));
		assert.deepEqual([login.env.SSH_CONNECTION, login.env.AGY_CLI_FORCE_FILE_TOKEN_STORAGE], [undefined, undefined], "the keychain account signs in to the keychain");
		assert.ok(f.read().some((m) => m.loginStored === "keyring"));
		assert.equal(readJson(file).accounts[0].storage, "keyring", "and stays the keychain account");
		await drive(prov(pi, "antigravity-gemini").streamSimple({ id: "default", provider: "antigravity-gemini", api: "antigravity-acp" }, { messages: [user("k")] }, { sessionId: "k1" }));
		const turn = f.read().filter((m) => m.argv).at(-1);
		assert.equal(turn.env.GEMINI_HOME, gemini);
		assert.deepEqual([turn.env.SSH_CONNECTION, turn.env.AGY_CLI_FORCE_FILE_TOKEN_STORAGE], [undefined, undefined]);
		assert.ok(f.read().some((m) => m.authenticatedVia === "keyring"));
		assert.ok(lstatSync(path.join(gemini, "config", "skills")).isDirectory() && !lstatSync(path.join(gemini, "config", "skills")).isSymbolicLink(), "~/.gemini never linked into itself");
		assert.ok(!existsSync(path.join(gemini, "settings.json")));
	});
});

test("a keychain sign-in (no file in the profile, as agy 1.5.18 signs in on a Mac): after pi restarts, the default account starts a session with no sign-in prompt", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	writeFileSync(path.join(a.home, ".fake-agy-keychain"), "{}"); // the user's own agy sign-in
	await withEnv(a.env, async () => {
		for (const k of [1, 2]) {
			const pi = await loadExtension(); // a fresh pi each time
			await pi.start();
			const r = await drive(prov(pi, "antigravity").streamSimple({ id: "default", provider: "antigravity", api: "antigravity-acp" }, { messages: [user(`hi ${k}`)] }, { sessionId: `r${k}` }));
			assert.equal(r.msg.stopReason, "stop", r.msg.errorMessage);
			assert.ok(pi.extensions[0].tools.get("antigravity"), "the tool too");
			await pi.fire("session_shutdown");
		}
		assert.ok(!existsSync(path.join(a.root, "profiles", "default", "antigravity-acp", "acp_token.json")));
		assert.ok(f.read().filter((m) => m.authenticatedVia).every((m) => m.authenticatedVia === "keyring"));
		assert.ok(f.read().filter((m) => m.method === "authenticate").length >= 2, "agy is asked every time, never a stat");
		const pi3 = await loadExtension();
		await pi3.start();
		const st = cmdCtx(pi3);
		await run(pi3, "antigravity", "status", st.ctx);
		assert.match(st.notes[0], /- default → antigravity · Google account · signed in \(system keychain, not checked\)/);
	});
});

test("login and sessions get the same environment for every kind of account (keychain, file Google account, folder in place, Gemini Enterprise, API key, Agent Platform)", async () => {
	const f = fake({ FAKE_AGY_BROWSER_SIGNIN: "1" });
	const a = accountsEnv({ FAKE_AGY_LOG: f.log, FAKE_AGY_BROWSER_SIGNIN: "1" });
	const own = mkdtempSync(path.join(TMP_ROOT, "own-"));
	mkdirSync(a.root, { recursive: true });
	writeFileSync(path.join(a.root, "accounts.json"), JSON.stringify({ accounts: [
		{ name: "work", method: "oauth-personal" },
		{ name: "own", method: "oauth-personal", dir: own, source: "added" },
		{ name: "biz", method: "oauth-business", gcpProject: "p", gcpLocation: "global" },
	] }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		for (const name of ["default", "work", "own", "biz"]) {
			const before = f.read().length;
			const { ctx } = cmdCtx(pi, { input: ["good-code"] });
			await run(pi, "antigravity", name === "default" ? "login" : `login ${name}`, ctx);
			await drive(prov(pi, name === "default" ? "antigravity" : `antigravity-${name}`).streamSimple({ id: "default", provider: "x", api: "antigravity-acp" }, { messages: [user("hi")] }, { sessionId: `e-${name}` }));
			const starts = f.read().slice(before).filter((m) => m.argv);
			assert.ok(starts.length >= 2, name);
			const envs = starts.map((s) => JSON.stringify({ ...s.env, TMPDIR: undefined }));
			assert.equal(new Set(envs).size, 1, `${name}: ${envs.join(" vs ")}`);
			const e = starts[0].env;
			assert.equal(e.AGY_CLI_FORCE_FILE_TOKEN_STORAGE, name === "default" ? undefined : "1", name);
		}
		assert.ok(existsSync(path.join(a.root, "profiles", "work", "antigravity-acp", "acp_token.json")), "a file account's sign-in in its profile");
		assert.ok(existsSync(path.join(own, "antigravity-acp", "acp_token.json")));
	});
	const k = { name: "k", method: "gemini-api-key" } as const, ap = { name: "ap", method: "agent-platform", gcpProject: "p", gcpLocation: "l" } as const;
	for (const x of [k, ap]) assert.equal(agyEnvFor(x, profileOf(a.root, x), "key", {}).AGY_CLI_FORCE_FILE_TOKEN_STORAGE, "1", x.name);
});

test("a second account never takes the keychain: with the default holding it, a file account that agy signs in from the keychain stays a file account; a default marked file with no file of its own that agy signs in from the keychain becomes the keychain account", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	writeFileSync(path.join(a.home, ".fake-agy-keychain"), "{}");
	mkdirSync(a.root, { recursive: true });
	const file = path.join(a.root, "accounts.json");
	writeFileSync(file, JSON.stringify({ accounts: [{ name: "work", method: "oauth-personal" }] }));
	const turnOn = async (pi: any, id: string) => drive(prov(pi, id).streamSimple({ id: "default", provider: id, api: "antigravity-acp" }, { messages: [user("hi")] }, { sessionId: `t-${id}-${Math.random()}` }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		assert.equal((await turnOn(pi, "antigravity-work")).msg.stopReason, "stop", "agy reads the keychain for any profile");
		await new Promise((r) => setTimeout(r, 100));
		assert.deepEqual(readJson(file).accounts, [{ name: "work", method: "oauth-personal" }], "work does not take the default's keychain");
		assert.equal(loadAccounts(a.root)[0].keyring, true, "the default holds it");
	});
	writeFileSync(file, JSON.stringify({ accounts: [{ name: "default", method: "oauth-personal", storage: "file" }, { name: "work", method: "oauth-personal" }] }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		assert.equal((await turnOn(pi, "antigravity")).msg.stopReason, "stop");
		await new Promise((r) => setTimeout(r, 100));
		assert.equal(readJson(file).accounts.find((x: any) => x.name === "default").storage, "keyring", "signed in from the keychain: recorded");
		assert.equal((await turnOn(pi, "antigravity-work")).msg.stopReason, "stop");
		await new Promise((r) => setTimeout(r, 100));
		assert.equal(readJson(file).accounts.find((x: any) => x.name === "work").storage, undefined, "the keychain is taken: work stays a file account");
		const turn = f.read().filter((m) => m.argv).at(-1);
		assert.equal(turn.env.AGY_CLI_FORCE_FILE_TOKEN_STORAGE, "1");
	});
});

test("defaultAccount: the account the tool and /antigravity login|logout|models use when none is named; status marks it; removing it resets it; the provider ids stay", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	mkdirSync(a.root, { recursive: true });
	const file = path.join(a.root, "accounts.json");
	writeFileSync(file, JSON.stringify({ defaultAccount: "work", accounts: [{ name: "work", method: "oauth-personal" }] }));
	signIn(a.root);
	signIn(a.root, "work");
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		assert.deepEqual(pi.extensions[0].providers.map((p: any) => p.id), ["antigravity", "antigravity-work"]);
		const t = pi.extensions[0].tools.get("antigravity");
		await t.execute("d1", { task: "hello" }, undefined, () => {}, { ...pi.ctx, cwd: TMP_ROOT });
		assert.equal(f.read().filter((m) => m.argv).at(-1).env.GEMINI_HOME, path.join(a.root, "profiles", "work"), "the chosen default");
		await t.execute("d2", { task: "hello", account: "default" }, undefined, () => {}, { ...pi.ctx, cwd: TMP_ROOT });
		assert.equal(f.read().filter((m) => m.argv).at(-1).env.GEMINI_HOME, path.join(a.root, "profiles", "default"), "a named account");
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", "models", ctx);
		assert.equal(notes.at(-1), '2 models of the Antigravity account "work" in /model (provider antigravity-work)');
		await run(pi, "antigravity", "status", ctx);
		assert.match(notes.at(-1)!, /- default → antigravity · Google account · signed in \(in its profile\) · models not listed yet\n- work → antigravity-work · Google account · signed in \(in its profile\) · 2 models · the default account$/);
		// Deckhand changes the default while pi runs: seen at once
		writeFileSync(file, JSON.stringify({ defaultAccount: "nope", accounts: [{ name: "work", method: "oauth-personal" }] }));
		await t.execute("d3", { task: "hello" }, undefined, () => {}, { ...pi.ctx, cwd: TMP_ROOT });
		assert.equal(f.read().filter((m) => m.argv).at(-1).env.GEMINI_HOME, path.join(a.root, "profiles", "default"), "an unknown default: `default`");
		writeFileSync(file, JSON.stringify({ defaultAccount: "work", accounts: [{ name: "work", method: "oauth-personal" }] }));
		await run(pi, "antigravity", "remove work", ctx);
		assert.equal(readJson(file).defaultAccount, undefined, "reset");
		await run(pi, "antigravity", "remove default", ctx);
		assert.match(notes.at(-1)!, /The default account stays/);
	});
});

test("an account Deckhand adds while pi runs: in the status (its provider after /reload) and usable by the tool; agy-models.json records model counts for Deckhand's Settings", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	mkdirSync(a.root, { recursive: true });
	const file = path.join(a.root, "accounts.json");
	const models = path.join(a.root, "agy-models.json");
	writeFileSync(models, JSON.stringify({ other: { count: 5, at: 1 } }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const own = mkdtempSync(path.join(TMP_ROOT, "picked-"));
		writeFileSync(file, JSON.stringify({ accounts: [{ name: "picked", method: "oauth-personal", dir: own, source: "added", label: "Picked" }] }));
		const { ctx, notes } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity", "status", ctx);
		assert.match(notes.at(-1)!, /- picked \(Picked\) → antigravity-picked · Google account · folder .* · sign-in unknown until agy is used \(\/antigravity login picked to sign in\) · provider after pi's next start or \/reload/);
		await run(pi, "antigravity", "login picked", ctx);
		assert.equal(notes.at(-1), '2 models of the Antigravity account "picked" in /model after pi\'s next start or /reload (provider antigravity-picked)');
		assert.deepEqual(pi.extensions[0].providers.map((p: any) => p.id), ["antigravity"], "no provider registered mid-session");
		const counts = readJson(models);
		assert.deepEqual(Object.keys(counts).sort(), ["other", "picked"], "other names kept");
		assert.deepEqual(counts.other, { count: 5, at: 1 });
		assert.equal(counts.picked.count, 2, "agy's models, not the default placeholder");
		assert.ok(Math.abs(counts.picked.at - Date.now() / 1000) < 60);
		assert.equal(statSync(models).mode & 0o777, 0o600);
		// the same count again: not written
		writeFileSync(models, JSON.stringify({ ...counts, picked: { count: 2, at: 7 } }));
		await run(pi, "antigravity", "models picked", ctx);
		assert.equal(readJson(models).picked.at, 7);
		// a provider's own session reports its models too
		signIn(a.root);
		await drive(prov(pi, "antigravity").streamSimple({ id: "default", provider: "antigravity", api: "antigravity-acp" }, { messages: [user("hi")] }, { sessionId: "m1" }));
		assert.equal(readJson(models).default.count, 2);
		const t = pi.extensions[0].tools.get("antigravity");
		assert.ok(t);
		await t.execute("p1", { task: "hello", account: "picked" }, undefined, () => {}, { ...pi.ctx, cwd: TMP_ROOT });
		assert.equal(f.read().filter((m) => m.argv).at(-1).env.GEMINI_HOME, own);
	});
});

test("a folder used in place that is gone: never made again; login and turns say so; the status still shows", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	const gone = path.join(TMP_ROOT, `gone-${Math.random().toString(36).slice(2)}`);
	mkdirSync(a.root, { recursive: true });
	writeFileSync(path.join(a.root, "accounts.json"), JSON.stringify({ defaultAccount: "old", accounts: [{ name: "default", method: "oauth-personal", dir: gone, source: "found" }, { name: "old", method: "oauth-personal", dir: gone, source: "found" }] }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi, { input: ["good-code"] });
		await run(pi, "antigravity", "login", ctx);
		assert.equal(notes.at(-1), `The folder of the Antigravity account "old" is not there: ${gone}`);
		await run(pi, "antigravity", "status", ctx);
		assert.match(notes.at(-1)!, /- old → antigravity-old · .* · sign-in unknown until agy is used \(\/antigravity login old to sign in\) · models not listed yet · the default account/);
		const r = await drive(prov(pi, "antigravity-old").streamSimple({ id: "default", provider: "antigravity-old", api: "antigravity-acp" }, { messages: [user("x")] }, { sessionId: "g1" }));
		assert.equal(r.msg.stopReason, "error");
		assert.match(r.msg.errorMessage, /is not there/);
		assert.ok(!existsSync(gone), "never created");
		assert.equal(f.read().filter((m) => m.argv).length, 0);
	});
});

// ---- models at pi's start: the cached list at once, a background listing after ----

const PROBE = (globalThis as any)[Symbol.for("deckhand.antigravity.probe")];
/** Runs `f` with the background listing on (no delay); restores it off after. */
async function withProbe<T>(f: () => Promise<T>): Promise<T> {
	const was = { ...PROBE };
	Object.assign(PROBE, { off: false, delayMs: 0, last: undefined });
	try {
		return await f();
	} finally {
		Object.assign(PROBE, was);
	}
}
const settled = async () => {
	for (let i = 0; i < 50 && !PROBE.last; i++) await new Promise((r) => setTimeout(r, 10));
	await PROBE.last;
};
const OLD_LIST = { models: [{ id: "gemini-old", name: "Gemini Old" }], thinking: ["low", "high"] };
const modelIds = (pi: any, id = "antigravity") => prov(pi, id).getModels().map((m: any) => m.id);
const spawned = (f: ReturnType<typeof fake>) => f.read().filter((m) => m.argv);
/** A UI that records any dialog (a background listing must not open one). */
const watchDialogs = (pi: any) => {
	const asked: string[] = [];
	for (const k of ["confirm", "select", "input", "notify"]) pi.ctx.ui[k] = async (...x: any[]) => void asked.push(`${k}: ${x[0]}`);
	return asked;
};

test("models at start: the cached list is in /model when the provider registers, with no agy started; a list under 10 minutes old is not asked for again", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	mkdirSync(a.root, { recursive: true });
	writeFileSync(path.join(a.root, "agy-model-lists.json"), JSON.stringify({ default: { ...OLD_LIST, at: Date.now() - 60_000 } }));
	await withEnv(a.env, async () => {
		const pi = await loadExtension();
		assert.deepEqual(modelIds(pi), ["default", "gemini-old"], "from the cache, before session_start");
		assert.equal(prov(pi, "antigravity").getModels()[1].reasoning, true, "its thinking levels too");
		await pi.start();
		assert.deepEqual(spawned(f), [], "background listing off in tests: nothing started");
		await withProbe(async () => {
			const p2 = await loadExtension();
			await p2.start();
			await settled();
			assert.deepEqual(spawned(f), [], "fresh: not listed again");
			assert.deepEqual(modelIds(p2), ["default", "gemini-old"]);
		});
	});
});

test("models at start: an old list, and an account never listed, are listed once in the background (one agy at a time, never a sign-in); the provider and the cache get agy's models", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	mkdirSync(a.root, { recursive: true });
	const own = mkdtempSync(path.join(TMP_ROOT, "never-"));
	writeFileSync(path.join(a.root, "accounts.json"), JSON.stringify({ accounts: [{ name: "personal", method: "oauth-personal", dir: own, source: "added" }] }));
	const lists = path.join(a.root, "agy-model-lists.json");
	writeFileSync(lists, JSON.stringify({ default: { ...OLD_LIST, at: Date.now() - 11 * 60_000 } }));
	signIn(a.root);
	mkdirSync(path.join(own, "antigravity-acp"), { recursive: true });
	writeFileSync(path.join(own, "antigravity-acp", "acp_token.json"), "{}");
	await withEnv(a.env, async () => {
		await withProbe(async () => {
			const pi = await loadExtension();
			const asked = watchDialogs(pi);
			assert.deepEqual(modelIds(pi), ["default", "gemini-old"]);
			assert.deepEqual(modelIds(pi, "antigravity-personal"), ["default"], "never listed: none yet");
			await pi.start();
			await settled();
			assert.deepEqual(modelIds(pi), ["default", "gemini-3.8-pro", "gemini-3.8-flash"], "updated in place");
			assert.deepEqual(modelIds(pi, "antigravity-personal"), ["default", "gemini-3.8-pro", "gemini-3.8-flash"]);
			const runs = spawned(f);
			assert.equal(runs.length, 2, "once per account");
			for (const r of runs) assert.ok(r.env.SSH_CONNECTION, "agy says it has no sign-in rather than opening a browser");
			assert.deepEqual(asked, [], "nothing shown");
			const c = readJson(lists);
			assert.deepEqual(c.default.models.map((m: any) => m.id), ["gemini-3.8-pro", "gemini-3.8-flash"]);
			assert.equal(c.default.models[0].description, "Most capable");
			assert.deepEqual(c.default.thinking, ["low", "high"]);
			assert.ok(Date.now() - c.personal.at < 60_000 && c.personal.triedAt <= c.personal.at);
			assert.equal(statSync(lists).mode & 0o777, 0o600);
			assert.equal(readJson(path.join(a.root, "agy-models.json")).personal.count, 2, "Deckhand's count too");
			// a second pi right after: both lists fresh, nothing started
			const p2 = await loadExtension();
			await p2.start();
			PROBE.last = undefined;
			await settled();
			assert.equal(spawned(f).length, 2);
			assert.deepEqual(modelIds(p2, "antigravity-personal"), ["default", "gemini-3.8-pro", "gemini-3.8-flash"], "from the cache");
		});
	});
});

test("models at start: no sign-in in the background listing keeps the cached models, opens nothing, and the status says to sign in; a later listing clears it", async () => {
	const f = fake({ FAKE_AGY_SIGNED_OUT: "1" });
	const a = accountsEnv({ FAKE_AGY_LOG: f.log, FAKE_AGY_SIGNED_OUT: "1" });
	mkdirSync(a.root, { recursive: true });
	const lists = path.join(a.root, "agy-model-lists.json");
	writeFileSync(lists, JSON.stringify({ default: { ...OLD_LIST, at: 1 } }));
	await withEnv(a.env, async () => {
		await withProbe(async () => {
			const pi = await loadExtension();
			const asked = watchDialogs(pi);
			await pi.start();
			await settled();
			assert.equal(spawned(f).length, 1, "the keychain account was asked");
			assert.deepEqual(asked, [], "no link, no dialog, no notice");
			assert.deepEqual(modelIds(pi), ["default", "gemini-old"], "the cached models kept");
			const c = readJson(lists).default;
			assert.equal(c.signedOut, true);
			assert.ok(c.triedAt > 1, "tried: another pi waits 10 minutes");
			const { ctx, notes } = cmdCtx(pi);
			await run(pi, "antigravity", "status", ctx);
			assert.match(notes.at(-1)!, /- default → antigravity · Google account · sign in: \/antigravity login · 1 models/);
		});
		// signed in again: the next listing (here /antigravity models) clears the mark
		delete process.env.FAKE_AGY_SIGNED_OUT;
		signIn(a.root);
		const pi = await loadExtension();
		await pi.start();
		const { ctx, notes } = cmdCtx(pi);
		await run(pi, "antigravity", "models", ctx);
		assert.equal(readJson(lists).default.signedOut, undefined);
		await run(pi, "antigravity", "status", ctx);
		assert.doesNotMatch(notes.at(-1)!, /sign in: /);
	});
});

test("models at start: a cache file that is not a list is ignored; an API-key account without its key is not listed", async () => {
	const f = fake();
	const a = accountsEnv({ FAKE_AGY_LOG: f.log });
	mkdirSync(a.root, { recursive: true });
	writeFileSync(path.join(a.root, "accounts.json"), JSON.stringify({ accounts: [{ name: "key", method: "gemini-api-key", source: "added" }] }));
	writeFileSync(path.join(a.root, "agy-model-lists.json"), JSON.stringify({ default: { models: [{ id: 7 }, "x", { id: "ok", name: "OK" }], thinking: [1], at: Date.now() }, key: "nonsense" }));
	await withEnv(a.env, async () => {
		await withProbe(async () => {
			const pi = await loadExtension();
			assert.deepEqual(modelIds(pi), ["default", "ok"]);
			assert.equal(prov(pi, "antigravity").getModels()[1].reasoning, false);
			await pi.start();
			await settled();
			assert.deepEqual(spawned(f), [], "default fresh, key without its key");
		});
	});
});
