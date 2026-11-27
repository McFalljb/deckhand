// pi's `antigravity` provider (extensions/antigravity): Google Antigravity's models, served by the
// user's own agy over ACP (lib/agy.ts). Registered as a complete pi-ai Provider object (pi's
// docs/custom-provider.md; like pi's own llama.cpp extension, dist/extensions/llama/provider.js),
// so it needs nothing from pi at run time and loads in node --test as it is.
//
// - Auth: agy keeps its own sign-in, so the provider is "configured" whenever agy was found (an
//   ambient api-key auth with no login and no key: pi-ai auth/types.d.ts ApiKeyAuth "Ambient-only
//   providers omit login"). /antigravity-login signs agy in.
// - Models: `default` (agy's own choice) always, so a session or `--model antigravity/default`
//   resolves before anything was asked of agy; the account's models once a session has listed them
//   (its `model` config option): after /antigravity-login, on /antigravity-models, and from every
//   session the provider opens. Kept in memory only: nothing is written to pi's model store.
//
// A passthrough: agy runs the whole turn (its model, its tools, its system prompt) and keeps the
// conversation; pi keeps its own transcript of what was said. Per pi session (options.sessionId)
// one agy process with one agy session, whose id goes on every answer (`responseId`), so the
// conversation carries on after a restart (session/resume) and pi's transcript says which agy
// session it belongs to.
//
// - Each turn sends agy only the user messages after the last answer (planTurn). When pi's
//   transcript is no longer the one agy has (another provider answered before; the user went back
//   in /tree), a new agy session starts with pi's transcript as text in front of the message.
// - agy's text streams as pi text, its thoughts as pi thinking, and its tool calls, plan and the
//   requests it was refused as short lines of thinking (and the tab's status line), never as pi
//   tool calls: pi's tools are not offered to agy and pi runs nothing for it.
// - Abort sends session/cancel and waits for agy to end the turn (10 s, then the process stops).
// - Usage is agy's per-turn PromptResponse.usage (input without the cached part, as Antigravity
//   1.5 reports it: t3code geminiPromptUsage); cost 0 (a subscription).
// - pi's summaries (compaction, /tree branch summaries) are answered here, without agy: agy has
//   the whole conversation, so the summary says so instead of spending a turn of agy's
//   (isSummaryRequest; the extension's session_before_compact does the same for /compact).
// - Replays (options.disableContinuation: pi's cache warming, which needs a model promptCache this
//   provider never sets) are refused.
import type { AgyModel } from "./agy.ts";
import { AgySession } from "./agy.ts";


export const PROVIDER_ID = "antigravity";
export const API = "antigravity-acp";
export const DEFAULT_MODEL_ID = "default";
// agy does not report these; Gemini's window, and an output cap agy enforces itself
const CONTEXT_WINDOW = 1_000_000;
const MAX_TOKENS = 65_536;
const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
const CANCEL_WAIT_MS = 10_000;
const CATCH_UP_MAX = 40_000;
/** pi's summarization prompt (core/compaction/utils.js SUMMARIZATION_SYSTEM_PROMPT) starts so. */
const PI_SUMMARY_PROMPT = "You are a context summarization assistant";
export const SUMMARY_TEXT =
	"This conversation is held by Google Antigravity: its agy session keeps the whole context, so pi did not summarize it. Ask the agent to recall anything from earlier.";

/** One pi model for an agy model. Thinking is on offer when agy has thought levels. */
export function piModel(m: { id: string; name: string }, reasoning: boolean, provider = PROVIDER_ID, account = "default") {
	const where = account === "default" ? "Antigravity" : `Antigravity: ${account}`;
	return {
		id: m.id,
		name: m.id === DEFAULT_MODEL_ID ? `${where} (agy's default model)` : `${m.name} (${where})`,
		api: API,
		provider,
		baseUrl: "acp:agy",
		reasoning,
		input: ["text", "image"] as ("text" | "image")[],
		cost: { ...ZERO_COST },
		contextWindow: CONTEXT_WINDOW,
		maxTokens: MAX_TOKENS,
	};
}

export type PiModel = ReturnType<typeof piModel>;

/** The model list: `default` first, then the account's, without duplicates. */
export function modelList(models: AgyModel[], thinking: string[], provider = PROVIDER_ID, account = "default"): PiModel[] {
	const seen = new Set([DEFAULT_MODEL_ID]);
	const out = [piModel({ id: DEFAULT_MODEL_ID, name: "default" }, false, provider, account)];
	for (const m of models) if (!seen.has(m.id)) (seen.add(m.id), out.push(piModel(m, thinking.length > 0, provider, account)));
	return out;
}

// ---- the transcript ----

const textOf = (content: unknown): string =>
	typeof content === "string" ? content : Array.isArray(content) ? content.filter((b: any) => b?.type === "text").map((b: any) => String(b.text ?? "")).join("\n") : "";

/** A user message as ACP prompt blocks (text and images). */
export function userBlocks(m: any): any[] {
	if (typeof m?.content === "string") return m.content ? [{ type: "text", text: m.content }] : [];
	if (!Array.isArray(m?.content)) return [];
	return m.content.flatMap((b: any) =>
		b?.type === "text" && b.text ? [{ type: "text", text: String(b.text) }] : b?.type === "image" && b.data && b.mimeType ? [{ type: "image", mimeType: b.mimeType, data: b.data }] : [],
	);
}

/** Whether this request is pi's own summarization (compaction, branch summary). */
export function isSummaryRequest(messages: any[]): boolean {
	const sys = messages.find((m) => m?.role === "system");
	return !!sys && textOf(sys.content).trimStart().startsWith(PI_SUMMARY_PROMPT);
}

/** pi's transcript up to the last answer, as text for a new agy session (the end kept). */
export function catchUpText(messages: any[]): string {
	const lines: string[] = [];
	for (const m of messages) {
		if (m?.role === "user") lines.push(`User: ${textOf(m.content)}`);
		else if (m?.role === "assistant") {
			const t = textOf(m.content);
			if (t) lines.push(`Assistant: ${t}`);
		}
	}
	let body = lines.join("\n\n");
	if (body.length > CATCH_UP_MAX) body = `…${body.slice(-CATCH_UP_MAX)}`;
	return `[The conversation so far, from pi's transcript (an earlier part was answered elsewhere):]\n${body}\n[End of the earlier conversation. The new message follows.]`;
}

/** What one answer this provider produced was: its timestamp, and whether it completed. */
export interface Produced {
	ts: number;
	ok: boolean;
}

export type TurnPlan = { error: string } | { blocks: any[]; mode: "continue" | "resume" | "new"; resumeId?: string };

/**
 * How a turn reaches agy. `continue`: agy's session is pi's transcript (its last answer is the
 * newest one this session produced, or only failed ones came after it, which pi drops before a
 * retry). `resume`: the last answer came from an agy session not open here (a restart; another
 * branch). `new`: the first turn, or the transcript is not agy's (then with catchUpText first).
 */
export function planTurn(messages: any[], state: { acpSessionId?: string; produced: Produced[] } | undefined, provider = PROVIDER_ID): TurnPlan {
	const convo = messages.filter((m) => m?.role !== "system");
	let last = -1;
	for (let i = convo.length - 1; i >= 0; i--)
		if (convo[i].role === "assistant") {
			last = i;
			break;
		}
	const blocks = convo.slice(last + 1).filter((m) => m.role === "user").flatMap(userBlocks);
	if (blocks.length === 0) return { error: "Antigravity: there is no new message to send" };
	if (last < 0) return { blocks, mode: "new" };
	const answer = convo[last];
	if (answer.provider === provider && typeof answer.responseId === "string" && answer.responseId) {
		if (state?.acpSessionId !== answer.responseId) return { blocks, mode: "resume", resumeId: answer.responseId };
		const i = state.produced.findIndex((p) => p.ts === answer.timestamp);
		if (i >= 0 && state.produced.slice(i + 1).every((p) => !p.ok)) return { blocks, mode: "continue" };
	}
	return { blocks: [{ type: "text", text: catchUpText(convo.slice(0, last + 1)) }, ...blocks], mode: "new" };
}

// ---- the stream pi reads (pi-ai's AssistantMessageEventStream, utils/event-stream.js) ----

/** An async-iterable event queue with `result()`, as pi's agent loop reads a provider's stream. */
export class EventStream {
	private queue: any[] = [];
	private waiting: ((r: IteratorResult<any>) => void)[] = [];
	private done = false;
	private resolveResult!: (m: any) => void;
	private readonly final = new Promise<any>((r) => (this.resolveResult = r));
	push(e: any) {
		if (this.done) return;
		if (e.type === "done" || e.type === "error") {
			this.done = true;
			this.resolveResult(e.type === "done" ? e.message : e.error);
		}
		const w = this.waiting.shift();
		if (w) w({ value: e, done: false });
		else this.queue.push(e);
	}
	end() {
		this.done = true;
		for (const w of this.waiting.splice(0)) w({ value: undefined, done: true });
	}
	async *[Symbol.asyncIterator]() {
		while (true) {
			if (this.queue.length) yield this.queue.shift();
			else if (this.done) return;
			else {
				const r = await new Promise<IteratorResult<any>>((res) => this.waiting.push(res));
				if (r.done) return;
				yield r.value;
			}
		}
	}
	result() {
		return this.final;
	}
}

/** Builds one assistant message and its events: text and thinking blocks, balanced. */
class Answer {
	readonly msg: any;
	private cur: { type: "text" | "thinking"; index: number } | undefined;
	readonly stream: EventStream;
	started = false;
	constructor(model: any, stream: EventStream) {
		this.stream = stream;
		this.msg = {
			role: "assistant",
			content: [],
			api: model.api ?? API,
			provider: model.provider ?? PROVIDER_ID,
			model: model.id,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
			stopReason: "pending",
			timestamp: Date.now(),
		};
	}
	start() {
		if (this.started) return;
		this.started = true;
		this.stream.push({ type: "start", partial: this.msg });
	}
	private open(type: "text" | "thinking") {
		this.start();
		if (this.cur?.type === type) return this.cur.index;
		this.close();
		this.msg.content.push(type === "text" ? { type: "text", text: "" } : { type: "thinking", thinking: "" });
		this.cur = { type, index: this.msg.content.length - 1 };
		this.stream.push({ type: `${type}_start`, contentIndex: this.cur.index, partial: this.msg });
		return this.cur.index;
	}
	close() {
		if (!this.cur) return;
		const { type, index } = this.cur;
		const block = this.msg.content[index];
		this.stream.push({ type: `${type}_end`, contentIndex: index, content: type === "text" ? block.text : block.thinking, partial: this.msg });
		this.cur = undefined;
	}
	text(delta: string) {
		if (!delta) return;
		const i = this.open("text");
		this.msg.content[i].text += delta;
		this.stream.push({ type: "text_delta", contentIndex: i, delta, partial: this.msg });
	}
	thinking(delta: string) {
		if (!delta) return;
		const i = this.open("thinking");
		this.msg.content[i].thinking += delta;
		this.stream.push({ type: "thinking_delta", contentIndex: i, delta, partial: this.msg });
	}
	/** A line of agy's activity, in the thinking (on a line of its own). */
	note(line: string) {
		const i = this.cur?.type === "thinking" ? this.cur.index : -1;
		const prev = i >= 0 ? String(this.msg.content[i].thinking) : "";
		this.thinking(`${prev && !prev.endsWith("\n") ? "\n" : ""}${line}\n`);
	}
	finish(stopReason: string, errorMessage?: string) {
		this.close();
		this.msg.stopReason = stopReason;
		if (errorMessage) this.msg.errorMessage = errorMessage;
		if (stopReason === "error" || stopReason === "aborted") this.stream.push({ type: "error", reason: stopReason, error: this.msg });
		else this.stream.push({ type: "done", reason: stopReason, message: this.msg });
		this.stream.end();
	}
}

const clip1 = (s: unknown, n = 120) => {
	const t = String(s ?? "").replace(/\s+/g, " ").trim();
	return t.length > n ? `${t.slice(0, n - 1)}…` : t;
};

/** agy's PromptResponse.usage as pi's usage (Antigravity 1.5: input leaves out the cached part). */
export function usageOf(u: any) {
	const n = (x: unknown) => (typeof x === "number" && Number.isFinite(x) && x > 0 ? Math.round(x) : 0);
	const input = n(u?.inputTokens), cacheRead = n(u?.cachedReadTokens), output = n(u?.outputTokens), cacheWrite = n(u?.cachedWriteTokens);
	return { input, output, cacheRead, cacheWrite, totalTokens: input + cacheRead + cacheWrite + output, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}

// ---- the provider ----

/** What pi's model registry offers an extension (ctx.modelRegistry), as far as this uses it. */
export interface Registry {
	refresh(o: { providers: string[]; allowNetwork?: boolean }): Promise<unknown>;
}

export interface AntigravityOptions {
	agyPath: string;
	/** The folder agy works in (the pi session's cwd). */
	cwd: () => string;
	env?: NodeJS.ProcessEnv;
	/** This provider's id and account (lib/agy-accounts.ts: one provider per account). */
	providerId?: string;
	account?: string;
	/**
	 * How agy starts for this account, given the key pi resolved (API-key accounts): its arguments
	 * (the profile), environment, sign-in method and what a missing sign-in says.
	 */
	launch?: (apiKey: string | undefined) => { args?: string[]; env?: NodeJS.ProcessEnv; authMethod?: string; signInHint?: string };
	/** agy's error made actionable (SUBSCRIPTION_REQUIRED and the like). */
	explain?: (message: string) => string;
	/** The credential is an API key in pi's credential store (`/login <provider>`), not agy's own sign-in. */
	keyAuth?: boolean;
	/** The tab's status line: agy's current activity, undefined to clear. */
	status?: (text: string | undefined) => void;
	spawnImpl?: Parameters<typeof AgySession.open>[0]["spawnImpl"];
	cancelWaitMs?: number;
}

interface SessionState {
	agy?: AgySession;
	acpSessionId?: string;
	produced: Produced[];
	/** The running turn's handler for agy's session updates and refused requests. */
	sink?: { update: (u: any) => void; refused: (method: string, params: any) => void };
	busy: boolean;
}

/** The provider, its live model list and the agy sessions it holds. */
export function createAntigravity(o: AntigravityOptions) {
	const pid = o.providerId ?? PROVIDER_ID, account = o.account ?? "default";
	const explain = o.explain ?? ((m: string) => m);
	let models: PiModel[] = modelList([], [], pid, account);
	let registry: Registry | undefined;
	const sessions = new Map<string, SessionState>();
	const auth = { type: "api_key" as const, source: `agy (${o.agyPath})` };

	const setModels = async (list: AgyModel[], thinking: string[]) => {
		const next = modelList(list, thinking, pid, account);
		if (JSON.stringify(next) === JSON.stringify(models)) return false;
		models = next;
		// pi reads getModels() again when it recomposes the provider (ModelRuntime.refresh)
		await registry?.refresh({ providers: [pid], allowNetwork: false }).catch(() => {});
		return true;
	};

	const drop = (st: SessionState) => {
		const a = st.agy;
		st.agy = undefined;
		if (a) void a.close().catch(() => {});
	};

	async function ensureSession(st: SessionState, plan: Exclude<TurnPlan, { error: string }>, apiKey: string | undefined): Promise<AgySession> {
		if (plan.mode === "continue" && st.agy?.conn.alive) return st.agy;
		drop(st);
		const resumeId = plan.mode === "resume" ? plan.resumeId : plan.mode === "continue" ? st.acpSessionId : undefined;
		let agy: AgySession | undefined;
		const how = o.launch?.(apiKey) ?? {};
		agy = await AgySession.open({
			agyPath: o.agyPath,
			cwd: o.cwd(),
			env: how.env ?? o.env,
			args: how.args,
			authMethod: how.authMethod,
			signInHint: how.signInHint,
			resumeId,
			spawnImpl: o.spawnImpl,
			// only while a turn runs (st.sink), and only this session's: an update after the turn
			// ended (agy's background work) has nowhere to go in pi and is dropped
			onUpdate: (p) => {
				if (agy && p?.sessionId === agy.sessionId) st.sink?.update(p?.update);
			},
			onAgentRequest: (m, p) => st.sink?.refused(m, p),
			onExit: () => {
				if (agy && st.agy === agy) st.agy = undefined;
			},
		});
		if (plan.mode === "new" || agy.sessionId !== st.acpSessionId) st.produced = [];
		st.agy = agy;
		st.acpSessionId = agy.sessionId;
		void setModels(agy.models, agy.thinkingLevels);
		return agy;
	}

	function streamSimple(model: any, context: any, options?: any) {
		const stream = new EventStream();
		const answer = new Answer(model, stream);
		void run(model, context?.messages ?? [], options ?? {}, answer).catch((e) => {
			// never leaves pi waiting
			if (answer.msg.stopReason === "pending") answer.finish("error", `Antigravity: ${(e as Error)?.message ?? e}`);
		});
		return stream;
	}

	async function run(model: any, messages: any[], options: any, answer: Answer) {
		const signal: AbortSignal | undefined = options.signal;
		if (signal?.aborted) return answer.finish("aborted", "Request was aborted");
		if (isSummaryRequest(messages)) {
			answer.text(SUMMARY_TEXT);
			return answer.finish("stop");
		}
		if (options.disableContinuation) return answer.finish("error", "Antigravity keeps its own conversation: replaying a request is not supported");
		const key = typeof options.sessionId === "string" && options.sessionId ? options.sessionId : "default";
		let st = sessions.get(key);
		if (!st) sessions.set(key, (st = { produced: [], busy: false }));
		if (st.busy) return answer.finish("error", "Antigravity is still answering the previous message");
		// an answer is known by its timestamp (planTurn): two in one millisecond get distinct ones
		const newest = st.produced.at(-1)?.ts ?? 0;
		if (answer.msg.timestamp <= newest) answer.msg.timestamp = newest + 1;
		const plan = planTurn(messages, st, pid);
		if ("error" in plan) return answer.finish("error", plan.error);
		st.busy = true;
		const titles = new Map<string, string>();
		let aborted = false;
		const onAbort = () => {
			aborted = true;
			st!.agy?.cancel();
		};
		try {
			let agy: AgySession;
			try {
				agy = await ensureSession(st, plan, typeof options.apiKey === "string" ? options.apiKey : undefined);
				await agy.selectModel(model.id);
				await agy.selectThinking(options.reasoning);
			} catch (e) {
				return answer.finish("error", explain((e as Error).message)); // SignInRequired names the account's command
			}
			answer.msg.responseId = agy.sessionId;
			if (signal?.aborted) return answer.finish("aborted", "Request was aborted");
			let payload: any = { sessionId: agy.sessionId, prompt: plan.blocks };
			const replaced = await options.onPayload?.(payload, model);
			if (replaced !== undefined) payload = replaced;
			answer.start();
			st.sink = {
				update: (u: any) => {
					void options.onProviderStreamEvent?.(u, model);
					switch (u?.sessionUpdate) {
						case "agent_message_chunk":
							if (u.content?.type === "text") answer.text(String(u.content.text ?? ""));
							break;
						case "agent_thought_chunk":
							if (u.content?.type === "text") answer.thinking(String(u.content.text ?? ""));
							break;
						case "tool_call": {
							const title = clip1(u.title || u.kind || "a tool");
							titles.set(String(u.toolCallId), title);
							answer.note(`→ ${title}`);
							o.status?.(`Antigravity: ${title}`);
							break;
						}
						case "tool_call_update": {
							const title = u.title ? clip1(u.title) : titles.get(String(u.toolCallId)) ?? "a tool";
							if (u.title) titles.set(String(u.toolCallId), title);
							if (u.status === "failed") answer.note(`✗ ${title} failed`);
							break;
						}
						case "plan":
							if (Array.isArray(u.entries) && u.entries.length)
								answer.note(`Plan: ${u.entries.map((e: any) => `${e?.status === "completed" ? "[x]" : e?.status === "in_progress" ? "[>]" : "[ ]"} ${clip1(e?.content, 60)}`).join("; ")}`);
							break;
					}
				},
				refused: (method: string, params: any) => {
					const what = method === "session/request_permission" ? clip1(params?.toolCall?.title || "an action") : method.includes("elicitation") ? "a question" : method;
					answer.note(`✗ declined: ${what} (Deckhand does not grant Antigravity approvals yet)`);
				},
			};
			const ABORT = Symbol("abort"), GONE = Symbol("no answer");
			const abortSeen = new Promise<typeof ABORT>((resolve) => signal?.addEventListener("abort", () => resolve(ABORT), { once: true }));
			signal?.addEventListener("abort", onAbort, { once: true });
			let response: any;
			try {
				const turn = agy.prompt(payload.prompt ?? plan.blocks);
				response = await Promise.race([turn, abortSeen]);
				if (response === ABORT) {
					// session/cancel went out (onAbort): agy ends the turn with stopReason cancelled
					let timer: NodeJS.Timeout | undefined;
					response = await Promise.race([turn.catch(() => GONE), new Promise((r) => (timer = setTimeout(() => r(GONE), o.cancelWaitMs ?? CANCEL_WAIT_MS)))]);
					clearTimeout(timer);
				}
			} catch (e) {
				st.produced.push({ ts: answer.msg.timestamp, ok: false });
				if (aborted) return answer.finish("aborted", "Request was aborted");
				return answer.finish("error", explain((e as Error).message));
			}
			if (aborted) {
				if (response === GONE) drop(st); // agy did not end the turn: its process goes
				st.produced.push({ ts: answer.msg.timestamp, ok: false });
				return answer.finish("aborted", "Request was aborted");
			}
			answer.msg.usage = usageOf(response?.usage);
			const reason = response?.stopReason;
			const ok = reason === "end_turn" || reason === "max_tokens" || reason === "max_turn_requests";
			st.produced.push({ ts: answer.msg.timestamp, ok });
			if (reason === "end_turn" || reason === "max_turn_requests") return answer.finish("stop");
			if (reason === "max_tokens") return answer.finish("length");
			if (reason === "refusal") return answer.finish("error", "Antigravity refused to answer this");
			if (reason === "cancelled") return answer.finish("error", "Antigravity cancelled the turn");
			return answer.finish("error", `Antigravity ended the turn (${clip1(reason ?? "no stop reason", 40)})`);
		} finally {
			signal?.removeEventListener("abort", onAbort);
			st.sink = undefined;
			st.busy = false;
			o.status?.(undefined);
		}
	}

	// agy's own sign-in: configured whenever agy is there. An API-key account: pi's /login asks for the
	// key (masked) and keeps it in its credential store; agy gets it in its environment only.
	const apiKeyAuth = o.keyAuth
		? {
				name: `Antigravity API key (account ${account})`,
				login: async (interaction: any) => ({ type: "api_key" as const, key: String(await interaction.prompt({ type: "secret", message: `API key for the Antigravity account "${account}"` })).trim() }),
				check: async (input: any) => (input?.credential?.key ? { type: "api_key" as const, source: "stored credential" } : undefined),
				resolve: async (input: any) => (input?.credential?.key ? { auth: { apiKey: input.credential.key }, source: "stored credential" } : undefined),
			}
		: {
				name: `Antigravity sign-in (agy; account ${account})`,
				check: async () => auth,
				resolve: async () => ({ auth: {}, source: auth.source }),
			};
	const provider = {
		id: pid,
		name: account === "default" ? "Antigravity" : `Antigravity: ${account}`,
		baseUrl: "acp:agy",
		auth: { apiKey: apiKeyAuth },
		getModels: () => models,
		streamSimple,
		stream: streamSimple,
	};
	return {
		provider,
		get models() {
			return models;
		},
		sessions,
		/** Where model changes are announced (the session's ctx.modelRegistry). */
		bind(r: Registry | undefined) {
			registry = r;
		},
		/** The account's models, as a session listed them; pi's /model shows them after its refresh. */
		setModels,
		/** Ends every agy process (pi's session ends). */
		async closeAll() {
			const all = [...sessions.values()];
			sessions.clear();
			await Promise.all(all.map((st) => st.agy?.close().catch(() => {})));
		},
		/** SIGTERM to every agy process, synchronously (pi's process exits). */
		killAll() {
			for (const st of sessions.values()) st.agy?.conn.killNow();
		},
	};
}
