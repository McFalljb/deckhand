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
import { createAntigravity, planTurn, SUMMARY_TEXT } from "../lib/antigravity.ts";
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
	assert.deepEqual(planTurn([u("x"), a(5), u("y")], { acpSessionId: "T", produced: [] }), { blocks: [{ type: "text", text: "y" }], mode: "resume", resumeId: "S" });
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
	await withEnv({ DECKHAND_AGY_PATH: FAKE }, async () => {
		const pi = await loadExtension();
		await pi.start();
		const [h] = pi.extensions[0].handlers.get("session_before_compact");
		const event = { preparation: { firstKeptEntryId: "e7", tokensBefore: 123456 } };
		assert.deepEqual(await h(event, { ...pi.ctx, model: { provider: "antigravity", id: "default" } }), { compaction: { summary: SUMMARY_TEXT, firstKeptEntryId: "e7", tokensBefore: 123456 } });
		assert.equal(await h(event, { ...pi.ctx, model: { provider: "anthropic", id: "x" } }), undefined);
		await pi.fire("session_shutdown");
	});
});
