#!/usr/bin/env node
// A stand-in for Google's Antigravity CLI (`agy acp`, `agy acp --login`) for the tests: never a
// real agy, no network. Its initialize, its sign-in errors and its --login output are agy 1.5.18's,
// as a no-login handshake against the real binary showed (protocolVersion 1, agentInfo
// "Antigravity ACP Server" with a bare version; promptCapabilities image and embeddedContext, no
// audio; no mcpCapabilities); the rest is as t3code's fixtures and adapters have it (session/new
// with `model` and `thought_level` config options and modes;
// streamed agent_thought_chunk / agent_message_chunk / tool_call / tool_call_update / plan updates;
// session/cancel; session/request_permission, ask_question as `interaction_…`, elicitation).
//
// What a prompt does depends on its text: "crash", "permission", "question", "elicit", "fsread",
// "slow" (streams until cancelled), "stubborn" (ignores cancel), "late" (an update after the
// prompt ended), "refuse"; anything else streams a thought, a tool call, a plan and an echo.
// Environment: FAKE_AGY_LOG (every message received, one JSON per line), FAKE_AGY_VERSION (default
// 1.5.18; some builds report agy_acp_server_1.5.12), FAKE_AGY_NO_IMAGE=1 (promptCapabilities.image false),
// FAKE_AGY_SIGNED_OUT=1 (no sign-in: authenticate prints the link; with --gemini-dir, signed in
// means the profile's acp_token.json exists, which --login writes and logout removes; agy's
// stored sign-in is never read by the client), FAKE_AGY_BROWSER_SIGNIN=1 (a browser sign-in
// completes), FAKE_AGY_SUBSCRIPTION=1,
// FAKE_AGY_AUTH_ONCE=1 (auth_required until authenticate), FAKE_AGY_NO_MODES=1 (modes by
// session/set_mode, not a config option), FAKE_AGY_LOGIN_CODE (the code --login accepts).
import fs from "node:fs";
import readline from "node:readline";
import { spawn as spawnChild } from "node:child_process";

const env = process.env;
const log = (x) => env.FAKE_AGY_LOG && fs.appendFileSync(env.FAKE_AGY_LOG, `${JSON.stringify(x)}\n`);
// how it ends: on stdin's end it exits, unless FAKE_AGY_HOLD_ON=1 (then it also ignores SIGTERM)
const HOLD_ON = env.FAKE_AGY_HOLD_ON === "1";
process.on("SIGTERM", () => {
	log({ event: "sigterm", t: Date.now() });
	if (!HOLD_ON) process.exit(0);
});
const send = (x) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...x })}\n`);
const LINK = "https://accounts.google.com/o/oauth2/auth?client_id=fake&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback&response_type=code&state=s123";
const args = process.argv.slice(2);
const SEEN_ENV = ["GEMINI_HOME", "TMPDIR", "SSH_CONNECTION", "AGY_ACP_FORCE_FILE_STORAGE", "AGY_CLI_DISABLE_AUTO_UPDATE", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CLOUD_PROJECT", "BROWSER", "ELECTRON_RUN_AS_NODE"];
// FAKE_AGY_CHILD=1: a child of its own (agy's tools run that way), which outlives it unless its group is ended
if (env.FAKE_AGY_CHILD === "1") {
	const c = spawnChild("sleep", ["60"], { stdio: "ignore" });
	log({ event: "child", pid: c.pid, pgid: process.pid });
	c.unref();
}
log({ argv: args, cwd: process.cwd(), deckhandEnv: Object.keys(env).filter((k) => k.startsWith("DECKHAND_")), env: Object.fromEntries(SEEN_ENV.filter((k) => env[k] !== undefined).map((k) => [k, env[k]])) });
// the profile: --gemini-dir and --app-data-dir (joined beneath it), as agy takes them
const argOf = (name) => (args.indexOf(name) >= 0 ? args[args.indexOf(name) + 1] : undefined);
const profile = argOf("--gemini-dir");
const acpDir = profile ? `${profile}/${argOf("--app-data-dir") ?? "antigravity-acp"}` : undefined;
const tokenFile = acpDir ? `${acpDir}/acp_token.json` : undefined;
const settings = (() => {
	try {
		return JSON.parse(fs.readFileSync(`${acpDir}/settings.json`, "utf8"));
	} catch {
		return {};
	}
})();
const signedIn = () => (tokenFile ? fs.existsSync(tokenFile) : env.FAKE_AGY_SIGNED_OUT !== "1");

if (args[0] !== "acp") {
	process.stderr.write("usage: agy acp [--login]\n");
	process.exit(2);
}

if (args.includes("--login")) {
	// agy 1.5.18's own lines
	process.stdout.write("Open this link in a browser to log in with Google:\n");
	process.stdout.write(`  ${LINK}\n`);
	process.stdout.write("Then paste the authorization code, or the full URL of the page you land on, and press Enter:\n");
	const rl = readline.createInterface({ input: process.stdin });
	let answered = false;
	rl.once("line", (code) => {
		answered = true;
		log({ loginCode: code });
		const good = env.FAKE_AGY_LOGIN_CODE ?? "good-code";
		let pageCode;
		try {
			pageCode = new URL(code.trim()).searchParams.get("code");
		} catch {}
		if (code.trim() === good || pageCode === good) {
			if (tokenFile) fs.writeFileSync(tokenFile, JSON.stringify({ fake: "not a real token" }));
			process.stdout.write("\nSigned in.\n");
			process.exit(0);
		}
		process.stdout.write("\nThat code did not work.\n");
		process.exit(1);
	});
	rl.once("close", () => {
		if (answered) return;
		process.stdout.write("login cancelled: no authorization code was entered\n");
		process.exit(1);
	});
} else {
	serve();
}

function serve() {
	let authed = env.FAKE_AGY_AUTH_ONCE !== "1" && env.FAKE_AGY_SIGNED_OUT !== "1";
	let nextReq = 1000;
	const waiting = new Map(); // our requests to the client, by id
	const sessions = new Map();
	let active; // the running prompt: { sessionId, id, cancelled, timer, stubborn }

	const ask = (method, params) =>
		new Promise((resolve) => {
			const id = nextReq++;
			waiting.set(id, resolve);
			send({ id, method, params });
		});
	const update = (sessionId, u) => send({ method: "session/update", params: { sessionId, update: u } });
	// FAKE_AGY_NO_MODE_AT_ALL=1: neither a mode option nor modes; FAKE_AGY_RESUME_NO_MODES=1: a
	// resumed session reports none; FAKE_AGY_MODE_STUCK=1: setting the mode leaves it as it was;
	// FAKE_AGY_NO_MODEL_OPTION=1: no model option; FAKE_AGY_NO_RESUME=1: no session/resume
	const noModes = (s) => env.FAKE_AGY_NO_MODE_AT_ALL === "1" || (s.resumed && env.FAKE_AGY_RESUME_NO_MODES === "1");
	const configOptions = (s) => [
		...(env.FAKE_AGY_NO_MODES === "1" || noModes(s) ? [] : [{ id: "mode", name: "Mode", category: "mode", type: "select", currentValue: s.mode, options: [{ value: "default", name: "Default" }, { value: "auto", name: "Auto" }] }]),
		...(env.FAKE_AGY_NO_MODEL_OPTION === "1" ? [] : [{
			id: "model",
			name: "Model",
			category: "model",
			type: "select",
			currentValue: s.model,
			options: [
				{ value: "gemini-3.8-pro", name: "Gemini 3.8 Pro", description: "Most capable" },
				{ group: "Fast", name: "Fast", options: [{ value: "gemini-3.8-flash", name: "Gemini 3.8 Flash" }] },
			],
		}]),
		{ id: "thinking_level", name: "Thinking level", category: "thought_level", type: "select", currentValue: s.thinking, options: [{ value: "low", name: "Low" }, { value: "high", name: "High" }] },
	];
	const newSession = (id) => {
		const s = { id, mode: "auto", model: "gemini-3.8-pro", thinking: "high", turns: 0 };
		sessions.set(id, s);
		return s;
	};
	const setup = (s) => ({
		sessionId: s.id,
		configOptions: configOptions(s),
		...(env.FAKE_AGY_NO_MODES === "1" && !noModes(s) ? { modes: { currentModeId: s.mode, availableModes: [{ id: "default", name: "Default" }, { id: "auto", name: "Auto" }] } } : {}),
	});

	function drift(s, what) {
		if (what === "mode") {
			s.mode = "auto";
			s.drifted = true;
			update(s.id, { sessionUpdate: "current_mode_update", currentModeId: "auto" });
		} else if (what === "model") {
			s.model = "gemini-3.8-flash";
			update(s.id, { sessionUpdate: "config_option_update", configOptions: configOptions(s) });
		}
	}

	async function prompt(id, p) {
		const s = sessions.get(p.sessionId);
		if (!s) return send({ id, error: { code: -32602, message: "unknown session" } });
		const text = (p.prompt ?? []).filter((b) => b.type === "text").map((b) => b.text).join("\n");
		// what the prompt does depends on its last text block (the user's message; catch-up text comes first)
		const said = (p.prompt ?? []).filter((b) => b.type === "text").at(-1)?.text ?? "";
		const images = (p.prompt ?? []).filter((b) => b.type === "image").length;
		s.turns++;
		const turn = { sessionId: s.id, id, cancelled: false, stubborn: /stubborn/.test(said) };
		active = turn;
		// agy changing its own mode or model: FAKE_AGY_DRIFT_DURING=mode (in turn 1, before its
		// answer), FAKE_AGY_DRIFT_BETWEEN=mode|model (just after turn 1 ended); FAKE_AGY_DRIFT_STICKY=1:
		// a drifted mode cannot be set back
		if (s.turns === 1 && env.FAKE_AGY_DRIFT_DURING) drift(s, env.FAKE_AGY_DRIFT_DURING);
		const end = (stopReason, usage) => {
			if (active === turn) active = undefined;
			send({ id, result: { stopReason, ...(usage ? { usage } : {}) } });
			if (s.turns === 1 && env.FAKE_AGY_DRIFT_BETWEEN) setTimeout(() => drift(s, env.FAKE_AGY_DRIFT_BETWEEN), 5);
		};
		const sid = s.id;
		if (/crash/.test(said)) {
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "about to" } });
			setTimeout(() => process.exit(3), 20);
			return;
		}
		if (/refuse/.test(said)) return end("refusal");
		if (/permission/.test(said)) {
			const tc = { toolCallId: "call_perm", title: "Run rm -rf build", kind: "execute", status: "pending", rawInput: { CommandLine: "rm -rf build" } };
			update(sid, { sessionUpdate: "tool_call", ...tc });
			const r = await ask("session/request_permission", {
				sessionId: sid,
				toolCall: tc,
				options: [
					{ optionId: "allow", name: "Allow once", kind: "allow_once" },
					{ optionId: "always", name: "Allow always", kind: "allow_always" },
					{ optionId: "deny", name: "Deny", kind: "reject_once" },
				],
			});
			update(sid, { sessionUpdate: "tool_call_update", toolCallId: "call_perm", status: "failed" });
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `permission:${JSON.stringify(r)}` } });
			return end("end_turn");
		}
		if (/question/.test(said)) {
			const r = await ask("session/request_permission", {
				sessionId: sid,
				toolCall: { toolCallId: "interaction_q1", title: "Which file?", status: "pending" },
				options: [{ optionId: "a", name: "a.ts", kind: "allow_once" }, { optionId: "b", name: "b.ts", kind: "allow_once" }],
			});
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `question:${JSON.stringify(r)}` } });
			return end("end_turn");
		}
		if (/elicit/.test(said)) {
			const r = await ask("session/elicitation", { sessionId: sid, mode: "form", message: "1 question", requestedSchema: { type: "object", properties: { q: { title: "Name?" } } } });
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `elicit:${JSON.stringify(r)}` } });
			return end("end_turn");
		}
		if (/fsread/.test(said)) {
			const r = await ask("fs/read_text_file", { sessionId: sid, path: "/etc/hosts" });
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `fsread:${JSON.stringify(r)}` } });
			return end("end_turn");
		}
		if (/slow|stubborn/.test(said)) {
			let n = 0;
			turn.timer = setInterval(() => update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `tick${n++} ` } }), 20);
			turn.end = end;
			return;
		}
		// the ordinary turn
		update(sid, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Thinking about it." } });
		update(sid, { sessionUpdate: "tool_call", toolCallId: "call_1", title: "Read README.md", kind: "read", status: "in_progress", rawInput: { path: "README.md" } });
		update(sid, { sessionUpdate: "tool_call_update", toolCallId: "call_1", status: "completed", content: [{ type: "content", content: { type: "text", text: "# readme" } }] });
		update(sid, { sessionUpdate: "plan", entries: [{ content: "Answer", priority: "medium", status: "in_progress" }] });
		update(sid, { sessionUpdate: "available_commands_update", availableCommands: [{ name: "compact", description: "Compact" }] });
		update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "You said: " } });
		update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `${text}${images ? ` [+${images} image]` : ""} (model ${s.model}, mode ${s.mode}, thinking ${s.thinking}, turn ${s.turns})` } });
		if (/late/.test(said)) setTimeout(() => update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "LATE" } }), 30);
		end("end_turn", { inputTokens: 1200, outputTokens: 80, totalTokens: 1580, cachedReadTokens: 300, thoughtTokens: 20 });
	}

	const rl = readline.createInterface({ input: process.stdin });
	rl.on("line", (line) => {
		let msg;
		try {
			msg = JSON.parse(line);
		} catch {
			return;
		}
		log(msg);
		const { id, method, params } = msg;
		if (method === undefined) {
			const r = waiting.get(id);
			waiting.delete(id);
			r?.(msg.result ?? { error: msg.error });
			return;
		}
		switch (method) {
			case "initialize": {
				const sessionCaps = { ...(env.FAKE_AGY_NO_RESUME === "1" ? {} : { resume: {} }), close: {}, load: {}, list: {}, additionalDirectories: {} };
				// as agy 1.5.18 answers it (a no-login handshake against the real binary)
				return send({
					id,
					result: {
						protocolVersion: 1,
						agentCapabilities: {
							loadSession: true,
							load_session: true,
							promptCapabilities: { image: env.FAKE_AGY_NO_IMAGE !== "1", audio: false, embeddedContext: true },
							sessionCapabilities: sessionCaps,
							session_capabilities: sessionCaps,
							auth: { logout: {} },
							_meta: { antigravity: { tier: true, systemPrompt: { append: true } } },
						},
						agentInfo: { name: "Antigravity ACP Server", version: env.FAKE_AGY_VERSION ?? "1.5.18" },
						authMethods: [
							{ id: "oauth-personal", name: "Log in with Google", description: "Log in with your Google account" },
							{ id: "oauth-business", name: "Log in with Gemini Enterprise", description: "Log in with your Gemini Enterprise account" },
							{ id: "gemini-api-key", name: "Gemini API key", description: "Use an API key with Gemini Developer API" },
							{ id: "agent-platform", name: "Gemini Enterprise Agent Platform", description: "Use Gemini Enterprise Agent Platform (formerly Vertex AI) with Application Default Credentials" },
						],
					},
				});
			}
			case "authenticate": {
				const m = params?.methodId;
				const ok = () => ((authed = true), send({ id, result: {} }));
				const bad = (message) => send({ id, error: { code: -32602, message } });
				if (env.FAKE_AGY_SIGNED_OUT === "1" || ((m === "oauth-personal" || m === "oauth-business") && !signedIn())) {
					if (env.SSH_CONNECTION && m === "oauth-personal") return send({ id, error: { code: -32603, message: "No browser is available here (this is a remote (SSH) session, so the browser's sign-in redirect can't reach this machine). Run `agy acp --login` in a terminal on this machine, then retry; or use a Gemini API key." } });
					process.stdout.write(`Open the following link to authenticate the ACP server: ${LINK}\n`);
					if (env.FAKE_AGY_BROWSER_SIGNIN === "1" && tokenFile)
						setTimeout(() => (fs.writeFileSync(tokenFile, "{}"), ok()), 50); // the browser came back to agy's loopback
					return; // else waits for a browser that never comes
				}
				if (m === "oauth-personal") return ok();
				if (m === "oauth-business") return settings?.gcp?.project && settings?.gcp?.location ? ok() : bad("Gemini Enterprise needs a GCP project and location");
				if (m === "gemini-api-key") return env.GEMINI_API_KEY ? ok() : bad("GEMINI_API_KEY is not set; pass an API key in _meta.apiKey or set the GEMINI_API_KEY environment variable.");
				if (m === "agent-platform") return env.GOOGLE_API_KEY || (settings?.gcp?.project && settings?.gcp?.location) ? ok() : bad("Agent Platform needs a key or a project");
				return bad(`unknown method ${m}`);
			}
			case "logout":
				if (tokenFile) fs.rmSync(tokenFile, { force: true });
				return send({ id, result: {} });
			case "session/new":
				if (!authed) return send({ id, error: { code: -32000, message: "Authentication required" } });
				if (env.FAKE_AGY_SUBSCRIPTION === "1") return send({ id, error: { code: -32603, message: "Request failed: SUBSCRIPTION_REQUIRED for this account" } });
				return send({ id, result: setup(newSession(`sess-${process.pid}-${sessions.size + 1}`)) });
			case "session/resume": {
				if (!authed) return send({ id, error: { code: -32000, message: "Authentication required" } });
				if (env.FAKE_AGY_RESUME_FAIL === "1") return send({ id, error: { code: -32603, message: "Session not found" } });
				const s = sessions.get(params.sessionId) ?? newSession(params.sessionId);
				s.resumed = true;
				const { sessionId: _, ...rest } = setup(s);
				return send({ id, result: rest });
			}
			case "session/set_config_option": {
				const s = sessions.get(params.sessionId);
				if (!s) return send({ id, error: { code: -32602, message: "unknown session" } });
				if (params.configId === "mode") s.mode = env.FAKE_AGY_MODE_STUCK === "1" || (s.drifted && env.FAKE_AGY_DRIFT_STICKY === "1") ? s.mode : params.value;
				else if (params.configId === "model") s.model = params.value;
				else if (params.configId === "thinking_level") s.thinking = params.value;
				else return send({ id, error: { code: -32602, message: `unknown option ${params.configId}` } });
				return send({ id, result: { configOptions: configOptions(s) } });
			}
			case "session/set_mode": {
				const s = sessions.get(params.sessionId);
				if (s) s.mode = params.modeId;
				return send({ id, result: {} });
			}
			case "session/prompt":
				return void prompt(id, params);
			case "session/cancel":
				if (active && active.sessionId === params.sessionId && !active.stubborn) {
					const t = active;
					t.cancelled = true;
					clearInterval(t.timer);
					t.end?.("cancelled");
				}
				return;
			case "session/close":
				sessions.delete(params.sessionId);
				return send({ id, result: {} });
			default:
				if (id !== undefined) send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
		}
	});
	rl.on("close", () => {
		log({ event: "stdin closed", t: Date.now() });
		if (HOLD_ON) setInterval(() => {}, 1000);
		else process.exit(0);
	});
}
