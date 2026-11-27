#!/usr/bin/env node
// A stand-in for Google's Antigravity CLI (`agy acp`, `agy acp --login`) for the tests: never a
// real agy, no network. It answers as agy does in t3code's fixtures and adapters
// (packages/effect-acp/test/fixtures/antigravity-initialize.json: protocolVersion 2 with the v1
// shape; authMethods; session/new with `model` and `thought_level` config options and modes;
// streamed agent_thought_chunk / agent_message_chunk / tool_call / tool_call_update / plan updates;
// session/cancel; session/request_permission, ask_question as `interaction_…`, elicitation).
//
// What a prompt does depends on its text: "crash", "permission", "question", "elicit", "fsread",
// "slow" (streams until cancelled), "stubborn" (ignores cancel), "late" (an update after the
// prompt ended), "refuse"; anything else streams a thought, a tool call, a plan and an echo.
// Environment: FAKE_AGY_LOG (every message received, one JSON per line), FAKE_AGY_VERSION,
// FAKE_AGY_SIGNED_OUT=1 (no sign-in: auth_required, and authenticate prints the link),
// FAKE_AGY_AUTH_ONCE=1 (auth_required until authenticate), FAKE_AGY_NO_MODES=1 (modes by
// session/set_mode, not a config option), FAKE_AGY_LOGIN_CODE (the code --login accepts).
import fs from "node:fs";
import readline from "node:readline";

const env = process.env;
const log = (x) => env.FAKE_AGY_LOG && fs.appendFileSync(env.FAKE_AGY_LOG, `${JSON.stringify(x)}\n`);
const send = (x) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...x })}\n`);
const LINK = "https://accounts.google.com/o/oauth2/auth?client_id=fake&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback&response_type=code&state=s123";
const args = process.argv.slice(2);
log({ argv: args, cwd: process.cwd(), deckhandEnv: Object.keys(env).filter((k) => k.startsWith("DECKHAND_") && k !== "DECKHAND_AGY_PATH") });

if (args[0] !== "acp") {
	process.stderr.write("usage: agy acp [--login]\n");
	process.exit(2);
}

if (args.includes("--login")) {
	process.stdout.write("Signing in to Antigravity.\n");
	process.stdout.write(`${LINK}\n`);
	process.stdout.write("Paste the code here: ");
	const rl = readline.createInterface({ input: process.stdin });
	rl.once("line", (code) => {
		log({ loginCode: code });
		if (code.trim() === (env.FAKE_AGY_LOGIN_CODE ?? "good-code")) {
			process.stdout.write("\nSigned in.\n");
			process.exit(0);
		}
		process.stdout.write("\nThat code did not work.\n");
		process.exit(1);
	});
	rl.once("close", () => process.exit(1));
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
	const configOptions = (s) => [
		...(env.FAKE_AGY_NO_MODES === "1" ? [] : [{ id: "mode", name: "Mode", category: "mode", type: "select", currentValue: s.mode, options: [{ value: "default", name: "Default" }, { value: "auto", name: "Auto" }] }]),
		{
			id: "model",
			name: "Model",
			category: "model",
			type: "select",
			currentValue: s.model,
			options: [
				{ value: "gemini-3.8-pro", name: "Gemini 3.8 Pro", description: "Most capable" },
				{ group: "Fast", name: "Fast", options: [{ value: "gemini-3.8-flash", name: "Gemini 3.8 Flash" }] },
			],
		},
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
		...(env.FAKE_AGY_NO_MODES === "1" ? { modes: { currentModeId: s.mode, availableModes: [{ id: "default", name: "Default" }, { id: "auto", name: "Auto" }] } } : {}),
	});

	async function prompt(id, p) {
		const s = sessions.get(p.sessionId);
		if (!s) return send({ id, error: { code: -32602, message: "unknown session" } });
		const text = (p.prompt ?? []).filter((b) => b.type === "text").map((b) => b.text).join("\n");
		const images = (p.prompt ?? []).filter((b) => b.type === "image").length;
		s.turns++;
		const turn = { sessionId: s.id, id, cancelled: false, stubborn: /stubborn/.test(text) };
		active = turn;
		const end = (stopReason, usage) => {
			if (active === turn) active = undefined;
			send({ id, result: { stopReason, ...(usage ? { usage } : {}) } });
		};
		const sid = s.id;
		if (/crash/.test(text)) {
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "about to" } });
			setTimeout(() => process.exit(3), 20);
			return;
		}
		if (/refuse/.test(text)) return end("refusal");
		if (/permission/.test(text)) {
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
		if (/question/.test(text)) {
			const r = await ask("session/request_permission", {
				sessionId: sid,
				toolCall: { toolCallId: "interaction_q1", title: "Which file?", status: "pending" },
				options: [{ optionId: "a", name: "a.ts", kind: "allow_once" }, { optionId: "b", name: "b.ts", kind: "allow_once" }],
			});
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `question:${JSON.stringify(r)}` } });
			return end("end_turn");
		}
		if (/elicit/.test(text)) {
			const r = await ask("session/elicitation", { sessionId: sid, mode: "form", message: "1 question", requestedSchema: { type: "object", properties: { q: { title: "Name?" } } } });
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `elicit:${JSON.stringify(r)}` } });
			return end("end_turn");
		}
		if (/fsread/.test(text)) {
			const r = await ask("fs/read_text_file", { sessionId: sid, path: "/etc/hosts" });
			update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `fsread:${JSON.stringify(r)}` } });
			return end("end_turn");
		}
		if (/slow|stubborn/.test(text)) {
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
		if (/late/.test(text)) setTimeout(() => update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "LATE" } }), 30);
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
			case "initialize":
				return send({
					id,
					result: {
						protocolVersion: 2,
						agentCapabilities: {
							loadSession: true,
							promptCapabilities: { image: true, audio: true, embeddedContext: true },
							mcpCapabilities: { http: true, sse: true },
							sessionCapabilities: { list: {}, resume: {}, close: {} },
							auth: { logout: {} },
						},
						authMethods: [
							{ id: "oauth-personal", name: "Log in with Google", description: "Log in with your Google account" },
							{ id: "gemini-api-key", name: "Gemini API key", description: "Use an API key with Gemini Developer API" },
						],
						agentInfo: { name: "antigravity-acp", title: "Google Antigravity", version: env.FAKE_AGY_VERSION ?? "agy_acp_server_1.5.12" },
					},
				});
			case "authenticate":
				if (env.FAKE_AGY_SIGNED_OUT === "1") {
					process.stdout.write(`Open the following link to authenticate the ACP server: ${LINK}\n`);
					return; // waits for a browser that never comes
				}
				authed = true;
				return send({ id, result: {} });
			case "session/new":
				if (!authed) return send({ id, error: { code: -32000, message: "Authentication required" } });
				return send({ id, result: setup(newSession(`sess-${process.pid}-${sessions.size + 1}`)) });
			case "session/resume": {
				if (!authed) return send({ id, error: { code: -32000, message: "Authentication required" } });
				const s = sessions.get(params.sessionId) ?? newSession(params.sessionId);
				return send({ id, result: { configOptions: setup(s).configOptions } });
			}
			case "session/set_config_option": {
				const s = sessions.get(params.sessionId);
				if (!s) return send({ id, error: { code: -32602, message: "unknown session" } });
				if (params.configId === "mode") s.mode = params.value;
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
	rl.on("close", () => process.exit(0));
}
