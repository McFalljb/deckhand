// The Antigravity extension (extensions/antigravity, lib/acp.ts, lib/agy.ts) against a stand-in agy
// (test/fake-agy.mjs): never a real agy, pi or model. node --test test/antigravity.test.ts
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { AcpConnection, agyEnv, agyTooOld, answerAgentRequest, CLIENT_INFO, findAgy, initializeParams, parseAgyVersion, SignInRequired, signInLink } from "../lib/acp.ts";
import { AgySession, modelsOf, probeModels, SIGN_IN_HINT } from "../lib/agy.ts";
import { agyLogin, CODE_REDIRECT_URI, linkInLine, loginAnswer, parseSignInLink } from "../lib/agy-login.ts";
import { piRules } from "./pi-rules.ts";

const TMP_ROOT = mkdtempSync(path.join(os.tmpdir(), "deckhand-agy-test-"));
process.on("exit", () => rmSync(TMP_ROOT, { recursive: true, force: true }));
const FAKE = path.join(path.dirname(new URL(import.meta.url).pathname), "fake-agy.mjs");
chmodSync(FAKE, 0o755);

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

test("findAgy: the override when it is an absolute executable, else agy then antigravity on PATH; never relative", () => {
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
	assert.equal(findAgy({ PATH: [dir, other].join(path.delimiter) }), anti, "macOS download name");
	const agy = mk(other, "agy");
	assert.equal(findAgy({ PATH: [dir, other].join(path.delimiter) }), agy, "agy before antigravity");
	mk(dir, "agy", 0o644);
	assert.equal(findAgy({ PATH: [dir, other].join(path.delimiter) }), agy, "not executable: skipped");
	assert.equal(findAgy({ PATH: "relative/bin" }), undefined);
	assert.equal(findAgy({ PATH: other, DECKHAND_AGY_PATH: FAKE }), FAKE, "the override");
	assert.equal(findAgy({ PATH: other, DECKHAND_AGY_PATH: "fake-agy.mjs" }), undefined, "a relative override is refused, not looked up");
	assert.equal(findAgy({ PATH: other, DECKHAND_AGY_PATH: path.join(dir, "missing") }), undefined);
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

test("startup: initialize, session/new, default mode; models from the config option; nothing else sent", async () => {
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
		assert.deepEqual(methods(msgs), ["initialize", "session/new", "session/set_config_option"]);
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

test("sign-in: auth_required then the link agy prints means /antigravity-login; auth_required alone is retried once with agy's own sign-in", async () => {
	const out = fake({ FAKE_AGY_SIGNED_OUT: "1" });
	const t0 = Date.now();
	await assert.rejects(AgySession.open({ agyPath: FAKE, cwd: out.cwd, env: out.env }), (e: any) => e instanceof SignInRequired && e.message === SIGN_IN_HINT);
	assert.ok(Date.now() - t0 < 10_000, "does not wait for a browser");
	assert.deepEqual(methods(out.read()), ["initialize", "session/new", "authenticate"]);
	const once = fake({ FAKE_AGY_AUTH_ONCE: "1" });
	const s = await AgySession.open({ agyPath: FAKE, cwd: once.cwd, env: once.env });
	await s.close();
	const msgs = once.read();
	assert.deepEqual(methods(msgs).slice(0, 4), ["initialize", "session/new", "authenticate", "session/new"]);
	assert.deepEqual(msgs.find((m) => m.method === "authenticate").params, { methodId: "oauth-personal" });
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
	await assert.rejects(AgySession.open({ agyPath: mjs, cwd: dir }), /Antigravity: boom \(session\/new\)/);
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
async function loadExtension() {
	const pi = piRules();
	const mod = await import(`../extensions/antigravity/index.ts?${Math.random()}`);
	await pi.load(path.join(ROOT, "extensions/antigravity"), mod.default);
	return pi;
}

test("dormant without agy: no provider, command, hook or notice", async () => {
	await withEnv({ DECKHAND_AGY_PATH: undefined, PATH: mkdtempSync(path.join(TMP_ROOT, "empty-")) }, async () => {
		const pi = await loadExtension();
		const [x] = pi.extensions;
		assert.deepEqual([x.providers.length, x.commands.size, x.tools.size, x.flags.size, x.handlers.size], [0, 0, 0, 0, 0]);
		assert.deepEqual(await pi.start(), { exitCode: 0, errors: [] });
		assert.deepEqual(pi.notices, []);
	});
});

test("with agy: the antigravity provider (agy's default model), /antigravity-login and /antigravity-models; nothing started while loading", async () => {
	const f = fake();
	await withEnv({ DECKHAND_AGY_PATH: FAKE, FAKE_AGY_LOG: f.log }, async () => {
		const pi = await loadExtension();
		const [x] = pi.extensions;
		assert.equal(x.providers.length, 1);
		const p = x.providers[0];
		assert.equal(p.id, "antigravity");
		assert.deepEqual(p.getModels().map((m: any) => [m.provider, m.id, m.api]), [["antigravity", "default", "antigravity-acp"]]);
		assert.deepEqual(await p.auth.apiKey.check({}), { type: "api_key", source: `agy (${FAKE})` });
		assert.equal(p.auth.apiKey.login, undefined, "no key to enter: agy keeps its sign-in");
		assert.deepEqual([...x.commands.keys()], ["antigravity-login", "antigravity-models"]);
		assert.deepEqual([...x.tools.keys(), ...x.flags.keys()], []);
		await pi.start();
		assert.equal(f.read().length, 0, "agy is not started by loading or by session start");
		assert.deepEqual(pi.notices, []);
	});
});

test("/antigravity-models lists the account's models into the provider, and pi's registry is refreshed", async () => {
	const f = fake();
	await withEnv({ DECKHAND_AGY_PATH: FAKE, FAKE_AGY_LOG: f.log }, async () => {
		const pi = await loadExtension();
		const refreshed: any[] = [];
		pi.ctx.modelRegistry = { refresh: async (o: any) => void refreshed.push(o) };
		await pi.start();
		const notes: string[] = [];
		const ctx = { ...pi.ctx, ui: { ...pi.ctx.ui, notify: (m: string) => notes.push(m) } };
		await pi.extensions[0].commands.get("antigravity-models").handler("", ctx);
		assert.deepEqual(notes, ["2 Antigravity models in /model (agy agy_acp_server_1.5.12)"]);
		const p = pi.extensions[0].providers[0];
		assert.deepEqual(p.getModels().map((m: any) => [m.id, m.name, m.reasoning]), [
			["default", "Antigravity (agy's default model)", false],
			["gemini-3.8-pro", "Gemini 3.8 Pro (Antigravity)", true],
			["gemini-3.8-flash", "Gemini 3.8 Flash (Antigravity)", true],
		]);
		assert.deepEqual(refreshed, [{ providers: ["antigravity"], allowNetwork: false }]);
		assert.deepEqual(methods(f.read()), ["initialize", "session/new", "session/set_config_option", "session/close"], "a throwaway session");
	});
});

test("/antigravity-login: the link shown, the code asked for, then the models listed", async () => {
	const f = fake();
	await withEnv({ DECKHAND_AGY_PATH: FAKE, FAKE_AGY_LOG: f.log }, async () => {
		const pi = await loadExtension();
		await pi.start();
		const notes: string[] = [];
		const asked: string[] = [];
		const ctx = { ...pi.ctx, hasUI: true, ui: { ...pi.ctx.ui, notify: (m: string) => notes.push(m), input: async (t: string) => (asked.push(t), "good-code") } };
		await pi.extensions[0].commands.get("antigravity-login").handler("", ctx);
		assert.match(notes[0], /Open this link and sign in with Google.*\nhttps:\/\/accounts\.google\.com\//s);
		assert.deepEqual(asked, ["Antigravity sign-in code"]);
		assert.deepEqual(notes.slice(1), ["Signed in to Antigravity", "2 Antigravity models in /model (agy agy_acp_server_1.5.12)"]);
		const headless = { ...ctx, hasUI: false };
		await pi.extensions[0].commands.get("antigravity-login").handler("", headless);
		assert.match(notes.at(-1)!, /needs the interactive pi/);
	});
});
