// pi's `antigravity` provider (extensions/antigravity): Google Antigravity's models, served by the
// user's own agy over ACP (lib/agy.ts). Registered as a complete pi-ai Provider object (pi's
// docs/custom-provider.md; like pi's own llama.cpp extension, dist/extensions/llama/provider.js),
// so it needs nothing from pi at run time and loads in node --test as it is.
//
// - Auth: agy keeps its own sign-in, so the provider is "configured" whenever agy was found (an
//   ambient api-key auth with no login and no key: pi-ai auth/types.d.ts ApiKeyAuth "Ambient-only
//   providers omit login"). /antigravity login signs agy in.
// - Models: `default` (agy's own choice) always, so a session or `--model antigravity/default`
//   resolves before anything was asked of agy; the account's models once a session has listed them
//   (its `model` config option): after /antigravity login, on /antigravity models, and from every
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
// - agy's text streams as pi text, its thoughts as pi thinking, and its tool calls, plan and what
//   was approved or refused as short lines of thinking (and the tab's status line), never as pi
//   tool calls: pi's tools are not offered to agy and pi runs nothing for it.
// - agy's requests during a turn (approvals, questions) are answered by lib/agy-approvals.ts with
//   the tab's UI, folder, read-only flag and the account's approvals mode (options.approvals);
//   outside a turn they are declined.
// - Abort sends session/cancel and waits for agy to end the turn (10 s, then the process stops).
// - Usage is agy's per-turn PromptResponse.usage (input without the cached part, as Antigravity
//   1.5 reports it: t3code geminiPromptUsage); cost 0 (a subscription).
// - pi's summaries (compaction, /tree branch summaries) are answered here, without agy: agy has
//   the whole conversation, so the summary says so instead of spending a turn of agy's
//   (isSummaryRequest; the extension's session_before_compact does the same for /compact).
// - Replays (options.disableContinuation: pi's cache warming, which needs a model promptCache this
//   provider never sets) are refused.
import type { AgyModel } from "./agy.ts";
import { AgySession, ModeUnconfirmed } from "./agy.ts";
import { fileLedger, type Ledger } from "./agy-ledger.ts";
import { type ApprovalContext, type Decision, decide, readonlySession } from "./agy-approvals.ts";
import { answerAgentRequest } from "./acp.ts";


export const PROVIDER_ID = "antigravity";
export const API = "antigravity-acp";
export const DEFAULT_MODEL_ID = "default";
// agy does not report these; Gemini's window, and an output cap agy enforces itself
const CONTEXT_WINDOW = 1_000_000;
const MAX_TOKENS = 65_536;
const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
const CANCEL_WAIT_MS = 10_000;

/** How often one user turn asks agy to carry on after a refused action. */
export const AUTO_CONTINUES = 3;
/** How many of agy's ask_question one user turn answers from a picker. */
const QUESTIONS_PER_TURN = 5;
export const WAITING_STATUS = "Antigravity is waiting for your answer";
export const OWN_ANSWER = "Type my own answer…";

/** The follow-up prompt after a refused action: what was refused and why (the decision's note). */
export function continueText(note: string): string {
	// agy's own words (a title) quoted, so they read as data; never one that poses as Deckhand's
	const what = note.replace(/^✗\s*/, "").replace(/\[deckhand\]\s*/gi, "").trim();
	return `[Deckhand] This was refused: ${JSON.stringify(what)}. It can't be done here. Carry on with the remaining steps and report what you did and didn't do.`;
}

/** agy's ask_question tool call (agy 1.5.18: title "Run ask_question"; its choices follow in its message). */
export function isAskQuestion(u: any): boolean {
	const tool = (v: unknown) => typeof v === "string" && /^ask_?question$/i.test(v.trim());
	const title = typeof u?.title === "string" ? u.title.trim().replace(/^run\s+/i, "").replace(/\?$/, "") : undefined;
	return tool(title) || tool(u?.rawInput?.toolName) || tool(u?.rawInput?.name) || tool(u?._meta?.toolName);
}

/**
 * An ask_question's question and choices: from its rawInput when it has them ({question, options:
 * [string | {label}]}, or questions[0]), else from agy's message after the call, as agy 1.5.18
 * writes it: the question on a line, then "- [1] (Recommended) scratch.md" per choice.
 */
export function parseAskQuestion(text: string, input?: any): { question: string; options: { label: string; answer: string }[] } {
	const opt = (label: string) => {
		const l = clip1(label, 200);
		return { label: l, answer: l.replace(/^\((recommended)\)\s*/i, "") };
	};
	const q0 = Array.isArray(input?.questions) ? input.questions[0] : input;
	const raw = Array.isArray(q0?.options) ? q0.options : undefined;
	if (raw?.length) {
		const options = raw.map((x: any) => (typeof x === "string" ? x : x?.label ?? x?.name ?? x?.value)).filter((x: unknown) => typeof x === "string" && x.trim()).slice(0, MAX_CHOICES).map(opt);
		if (options.length) return { question: clip1(q0?.question ?? q0?.title ?? "", 200), options };
	}
	const lines = String(text ?? "").split("\n");
	const options: { label: string; answer: string }[] = [];
	let question = "";
	for (const line of lines) {
		const m = /^\s*(?:[-*]\s*)?\[(\d+)\]\s*(.+?)\s*$/.exec(line);
		if (m) {
			if (options.length < MAX_CHOICES) options.push(opt(m[2]));
		} else if (!options.length && line.trim()) question = line.trim();
	}
	return { question: clip1(question, 200), options };
}

const MAX_CHOICES = 50;

/** The user's answer to an ask_question: a choice, or their own words; undefined if dismissed. */
async function pickAnswer(ui: any, q: ReturnType<typeof parseAskQuestion>, signal?: AbortSignal): Promise<string | undefined> {
	// each label once (a repeated one numbered), so a pick names one choice; "Type my own answer…"
	// is the last entry, known by its place, never by a choice that reads the same
	const count = new Map<string, number>();
	for (const o of q.options) count.set(o.label, (count.get(o.label) ?? 0) + 1);
	const seen = new Map<string, number>();
	const labels = q.options.map((o) => {
		const k = (seen.get(o.label) ?? 0) + 1;
		seen.set(o.label, k);
		return count.get(o.label)! > 1 || o.label === OWN_ANSWER ? `${o.label} (${k})` : o.label;
	});
	const all = [...labels, OWN_ANSWER];
	const title = `Antigravity asks: ${q.question || "pick one"}`;
	try {
		const pick = await ui.select(title, all, { signal });
		if (pick === undefined) return undefined;
		const i = all.lastIndexOf(pick);
		if (i === all.length - 1) {
			const own = await ui.input?.(title, "", { signal });
			return typeof own === "string" && own.trim() ? own.trim() : undefined;
		}
		return i >= 0 ? q.options[i]?.answer : undefined;
	} catch {
		return undefined;
	}
}
const CATCH_UP_MAX = 40_000;
/** pi's summarization prompt (core/compaction/utils.js SUMMARIZATION_SYSTEM_PROMPT) starts so. */
const PI_SUMMARY_PROMPT = "You are a context summarization assistant";
/** Put before a message pi sends again after a failed turn that had reached agy (its auto-retry). */
export const RETRY_NOTE = "[pi retried the previous message; Antigravity may already have received it]";
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

/** `prior`: the transcript up to the last answer, for catch-up text if agy cannot pick its session up. */
export type TurnPlan = { error: string } | { blocks: any[]; mode: "continue" | "resume" | "new"; resumeId?: string; prior?: any[] };

/** Whether an agy session whose answers are `produced` holds exactly the turns up to the answer `ts` (only failed ones after it, which pi drops before a retry). */
export function endsAt(produced: Produced[] | undefined, ts: number): boolean {
	const i = produced?.findIndex((p) => p.ts === ts) ?? -1;
	return i >= 0 && produced!.slice(i + 1).every((p) => !p.ok);
}

/**
 * How a turn reaches agy. `continue`: agy's session is pi's transcript (endsAt its last answer).
 * `resume`: the last answer came from an agy session not open here (a restart, /resume, /fork),
 * and `resumable` says that session ends at that answer and nobody else holds it (lib/agy-ledger.ts;
 * without it, never). `new`: the first turn, or the transcript is not agy's, or is not where its
 * session stands (then with catchUpText first).
 */
export function planTurn(
	messages: any[],
	state: { acpSessionId?: string; produced: Produced[] } | undefined,
	provider = PROVIDER_ID,
	resumable?: (sessionId: string, ts: number) => boolean,
): TurnPlan {
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
		const prior = convo.slice(0, last + 1);
		if (state?.acpSessionId === answer.responseId) {
			if (endsAt(state.produced, answer.timestamp)) return { blocks, mode: "continue", prior };
		} else if (resumable?.(answer.responseId, answer.timestamp)) return { blocks, mode: "resume", resumeId: answer.responseId, prior };
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
	/** Before the answer to a follow-up prompt: the text so far ends in a blank line. */
	gap() {
		const last = [...this.msg.content].reverse().find((b: any) => b.type === "text");
		if (!last?.text) return;
		const t = String(last.text);
		this.text(t.endsWith("\n\n") ? "" : t.endsWith("\n") ? "\n" : "\n\n");
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
	launch?: (apiKey: string | undefined) => { args?: string[]; env?: NodeJS.ProcessEnv; authMethod?: string; signInHint?: string; makeRunDir?: () => string };
	/** agy's error made actionable (SUBSCRIPTION_REQUIRED and the like). */
	explain?: (message: string) => string;
	/** The credential is an API key in pi's credential store (`/login <provider>`), not agy's own sign-in. */
	keyAuth?: boolean;
	/** The tab's status line: agy's current activity, undefined to clear. */
	status?: (text: string | undefined) => void;
	spawnImpl?: Parameters<typeof AgySession.open>[0]["spawnImpl"];
	cancelWaitMs?: number;
	/** Where the record of agy's sessions lives (lib/agy-ledger.ts; the account profile's). Without it, no session is ever resumed from a transcript. */
	ledgerDir?: string;
	/**
	 * How agy's requests are judged during a turn (lib/agy-approvals.ts), read for each request: the
	 * tab's UI, its folder, read-only, the account's approvals mode. Default: no UI, the session's
	 * folder, PI_KIT_READONLY, `allow`.
	 */
	approvals?: () => Omit<ApprovalContext, "signal">;
	/** Told agy's models, its thinking levels and their count (without `default`) whenever a list with models arrives. */
	onModels?: (count: number, models: AgyModel[], thinking: string[]) => void;
	/** The models /model shows until agy lists them (the account's cached list: agy-accounts cachedModels). */
	initialModels?: { models: AgyModel[]; thinking: string[] };
	/** agy opened a session for this account (it authenticated): the account's sign-in is known to work. */
	onOpened?: () => void;
}

interface SessionState {
	agy?: AgySession;
	acpSessionId?: string;
	produced: Produced[];
	/** The running turn's handler for agy's session updates and its requests of the client. */
	sink?: { update: (u: any) => void; answer: (method: string, params: any) => Promise<any> };
	busy: boolean;
	/** The blocks of the last turn that reached agy (session/prompt went out) and failed. */
	failedSent?: string;
}

/** The provider, its live model list and the agy sessions it holds. */
export function createAntigravity(o: AntigravityOptions) {
	const pid = o.providerId ?? PROVIDER_ID, account = o.account ?? "default";
	const explain = o.explain ?? ((m: string) => m);
	let models: PiModel[] = modelList(o.initialModels?.models ?? [], o.initialModels?.thinking ?? [], pid, account);
	let registry: Registry | undefined;
	const sessions = new Map<string, SessionState>();
	const ledger: Ledger | undefined = o.ledgerDir ? fileLedger(o.ledgerDir) : undefined;
	const auth = { type: "api_key" as const, source: `agy (${o.agyPath})` };

	const setModels = async (list: AgyModel[], thinking: string[]) => {
		const next = modelList(list, thinking, pid, account);
		if (next.length > 1) o.onModels?.(next.length - 1, list, thinking);
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

	/** The turn's agy session; `lost`: it was to resume a session and agy started a new one instead (no session/resume). */
	async function ensureSession(st: SessionState, plan: Exclude<TurnPlan, { error: string }>, apiKey: string | undefined): Promise<{ agy: AgySession; lost: boolean }> {
		if (plan.mode === "continue" && st.agy?.conn.alive) return { agy: st.agy, lost: false };
		drop(st);
		let resumeId = plan.mode === "resume" ? plan.resumeId : plan.mode === "continue" ? st.acpSessionId : undefined;
		// a session another pi session took in the meantime is not picked up: a new one, caught up
		const wanted = resumeId;
		const how = o.launch?.(apiKey) ?? {}; // before the claim: a launch that throws (a folder gone) holds nothing
		if (resumeId && ledger && !ledger.claim(resumeId, st)) resumeId = undefined;
		// claimed for this resume only (not st's own session): given up again if the resume does not happen
		const claimedNow = !!resumeId && !!ledger && resumeId !== st.acpSessionId;
		const unclaim = () => claimedNow && ledger!.release(resumeId!, st);
		let agy: AgySession | undefined;
		const open = (rid: string | undefined) => AgySession.open({
			agyPath: o.agyPath,
			cwd: o.cwd(),
			env: how.env ?? o.env,
			args: how.args,
			makeRunDir: how.makeRunDir,
			authMethod: how.authMethod,
			signInHint: how.signInHint,
			resumeId: rid,
			spawnImpl: o.spawnImpl,
			// only while a turn runs (st.sink), and only this session's: an update after the turn
			// ended (agy's background work) has nowhere to go in pi and is dropped
			onUpdate: (p) => {
				if (agy && p?.sessionId === agy.sessionId) st.sink?.update(p?.update);
			},
			// a request outside a turn (nobody to ask, nothing to show it in) is declined
			answer: (m, p) => (st.sink ? st.sink.answer(m, p) : answerAgentRequest(m, p)),
			onExit: () => {
				if (agy && st.agy === agy) st.agy = undefined;
			},
		});
		try {
			agy = await open(resumeId);
		} catch (e) {
			unclaim();
			// a resumed session whose default mode cannot be confirmed: a new one, caught up (which
			// is refused in turn if it cannot confirm it either), rather than failing every turn
			if (!(resumeId && e instanceof ModeUnconfirmed)) throw e;
			agy = await open(undefined);
		}
		if (agy.sessionId !== resumeId) unclaim(); // agy started a new session instead
		if (agy.sessionId !== st.acpSessionId) {
			if (st.acpSessionId) ledger?.release(st.acpSessionId, st);
			ledger?.claim(agy.sessionId, st);
			// resumed from the record (another process, or before a restart): its answers so far
			st.produced = plan.mode === "resume" && agy.sessionId === resumeId ? ledger?.read(agy.sessionId) ?? [] : [];
		} else if (plan.mode === "new") st.produced = [];
		st.agy = agy;
		st.acpSessionId = agy.sessionId;
		void setModels(agy.models, agy.thinkingLevels);
		return { agy, lost: !!wanted && agy.sessionId !== wanted };
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
		// every answer from here is on the record (planTurn knows it), and names the agy session it
		// belongs to, even one that ends before its prompt: the next turn then continues that session
		let recorded = false, dispatched = false, sentKey = "";
		const record = (ok: boolean) => {
			if (recorded) return;
			recorded = true;
			st!.produced.push({ ts: answer.msg.timestamp, ok });
			if (dispatched) st!.failedSent = ok ? undefined : sentKey;
			if (st!.acpSessionId) ledger?.write(st!.acpSessionId, st!.produced);
		};
		if (st.acpSessionId) answer.msg.responseId = st.acpSessionId;
		const owner = st;
		let plan = planTurn(messages, st, pid, (id, ts) => !!ledger && ledger.free(id, owner) && endsAt(ledger.read(id), ts));
		if ("error" in plan) {
			record(false);
			return answer.finish("error", plan.error);
		}
		st.busy = true;
		const titles = new Map<string, string>();
		let modeNoted = false;
		let aborted = false;
		let waiting = false;
		// this turn's own signal: pi's stop (Esc), and the turn's end, close its dialogs
		const turnAc = new AbortController();
		const turnSignal = turnAc.signal;
		if (signal?.aborted) turnAc.abort();
		else signal?.addEventListener("abort", () => turnAc.abort(), { once: true });
		const onAbort = () => {
			aborted = true;
			st!.agy?.cancel();
		};
		try {
			let agy: AgySession;
			try {
				const got = await ensureSession(st, plan, typeof options.apiKey === "string" ? options.apiKey : undefined);
				agy = got.agy;
				o.onOpened?.();
				// agy could not resume (it does not offer session/resume): its new session gets pi's transcript first
				if (got.lost) plan = { mode: "new", blocks: [{ type: "text", text: catchUpText(plan.prior ?? []) }, ...plan.blocks] };
				// before every prompt (agy may have changed them since): its default mode, refused if
				// it cannot be set again, then the chosen model against agy's current options
				await agy.setMode("default");
				await agy.selectModel(model.id);
				await agy.selectThinking(options.reasoning);
			} catch (e) {
				if (st.acpSessionId) answer.msg.responseId = st.acpSessionId;
				record(false);
				return answer.finish("error", explain((e as Error).message)); // SignInRequired names the account's command
			}
			answer.msg.responseId = agy.sessionId;
			if (signal?.aborted) return answer.finish("aborted", "Request was aborted");
			// listening from here: an abort while pi's onPayload hook runs is not lost
			const ABORT = Symbol("abort"), GONE = Symbol("no answer");
			const abortSeen = new Promise<typeof ABORT>((resolve) => signal?.addEventListener("abort", () => resolve(ABORT), { once: true }));
			signal?.addEventListener("abort", onAbort, { once: true });
			// pi's auto-retry sends a failed turn's message again; agy may have it already
			sentKey = JSON.stringify(plan.blocks);
			const retried = plan.mode !== "new" && st.failedSent === sentKey;
			let payload: any = { sessionId: agy.sessionId, prompt: retried ? [{ type: "text", text: RETRY_NOTE }, ...plan.blocks] : plan.blocks };
			const replaced = await options.onPayload?.(payload, model);
			if (replaced !== undefined) payload = replaced;
			// aborted before the prompt went out: nothing reached agy, so there is no turn to cancel
			if (aborted || signal?.aborted) return answer.finish("aborted", "Request was aborted");
			answer.start();
			// what this prompt's updates said: agy's last refused action with nothing after it, and
			// an ask_question agy is waiting on (answered by the next prompt)
			let refused: Decision | undefined;
			let question: { id: string; text: string; input: any } | undefined;
			st.sink = {
				update: (u: any) => {
					if (refused && ((u?.sessionUpdate === "agent_message_chunk" && String(u.content?.text ?? "").trim()) || u?.sessionUpdate === "tool_call")) refused = undefined;
					void options.onProviderStreamEvent?.(u, model);
					switch (u?.sessionUpdate) {
						case "current_mode_update":
						case "config_option_update": {
							// agy left its default mode mid-turn: what it does now cannot be undone, but it is shown,
							// and the next prompt goes out only once default is back (setMode above)
							const mode = agy.currentMode;
							if (mode && mode !== "default" && !modeNoted) {
								modeNoted = true;
								answer.note(`⚠ Antigravity switched to its ${clip1(mode, 40)} mode during this turn; Deckhand sets its default mode again before the next message, and refuses the message if it cannot`);
							}
							break;
						}
						case "agent_message_chunk":
							if (u.content?.type === "text") {
								answer.text(String(u.content.text ?? ""));
								if (question) question.text += String(u.content.text ?? "");
							}
							break;
						case "agent_thought_chunk":
							if (u.content?.type === "text") answer.thinking(String(u.content.text ?? ""));
							break;
						case "tool_call": {
							const title = clip1(u.title || u.kind || "a tool");
							titles.set(String(u.toolCallId), title);
							answer.note(`→ ${title}`);
							o.status?.(`Antigravity: ${title}`);
							if (isAskQuestion(u)) question = { id: String(u.toolCallId), text: "", input: u.rawInput };
							break;
						}
						case "tool_call_update": {
							const title = u.title ? clip1(u.title) : titles.get(String(u.toolCallId)) ?? "a tool";
							if (u.title) titles.set(String(u.toolCallId), title);
							if (u.status === "failed") answer.note(`✗ ${title} failed`);
							if (question?.id === String(u.toolCallId) && (u.status === "completed" || u.status === "failed")) question = undefined;
							break;
						}
						case "plan":
							if (Array.isArray(u.entries) && u.entries.length)
								answer.note(`Plan: ${u.entries.map((e: any) => `${e?.status === "completed" ? "[x]" : e?.status === "in_progress" ? "[>]" : "[ ]"} ${clip1(e?.content, 60)}`).join("; ")}`);
							break;
					}
				},
				answer: async (method: string, params: any) => {
					const c = o.approvals?.() ?? { cwd: o.cwd(), hasUI: false, readonly: readonlySession(), mode: "allow" as const };
					const d = await decide(method, params, { ...c, signal: turnSignal });
					if (answer.msg.stopReason === "pending") answer.note(d.note); // the turn may have ended while a dialog was open
					refused = d.refusedBy ? d : undefined;
					return d.answer;
				},
			};
			let response: any;
			let blocks: unknown[] = payload.prompt ?? plan.blocks;
			let continued = 0, answered = 0;
			const usage = { inputTokens: 0, outputTokens: 0, cachedReadTokens: 0, cachedWriteTokens: 0 };
			for (let follow = false; ; follow = true) {
				refused = undefined;
				question = undefined;
				if (follow) {
					// a follow-up prompt (after a refusal, an answer) as the first: agy's default mode set
					// again (it may have left it), refused if it cannot be, the chosen model and thinking
					try {
						await agy.setMode("default");
						await agy.selectModel(model.id);
						await agy.selectThinking(options.reasoning);
					} catch (e) {
						record(false);
						answer.msg.usage = usageOf(usage);
						return answer.finish("error", explain((e as Error).message));
					}
				}
				try {
					dispatched = true;
					const turn = agy.prompt(blocks);
					response = await Promise.race([turn, abortSeen]);
					if (response === ABORT) {
						// session/cancel went out (onAbort): agy ends the turn with stopReason cancelled
						let timer: NodeJS.Timeout | undefined;
						response = await Promise.race([turn.catch(() => GONE), new Promise((r) => (timer = setTimeout(() => r(GONE), o.cancelWaitMs ?? CANCEL_WAIT_MS)))]);
						clearTimeout(timer);
					}
				} catch (e) {
					record(false);
					if (aborted) return answer.finish("aborted", "Request was aborted");
					return answer.finish("error", explain((e as Error).message));
				}
				if (aborted) {
					if (response === GONE) drop(st); // agy did not end the turn: its process goes
					record(false);
					return answer.finish("aborted", "Request was aborted");
				}
				for (const k of Object.keys(usage) as (keyof typeof usage)[]) if (typeof response?.usage?.[k] === "number") usage[k] += response.usage[k];
				const stopped = response?.stopReason === "end_turn" || response?.stopReason === "cancelled";
				// agy 1.5.18 ends its turn on a refused action (end_turn at once, or cancelled) and waits
				// for the next prompt: it is asked to carry on without it, up to AUTO_CONTINUES times;
				// never after the user's own no
				if (refused && stopped) {
					const r: Decision = refused;
					if (r.refusedBy === "user") {
						answer.note("Antigravity stopped: you declined that action");
						response = { ...response, stopReason: "end_turn" };
					} else if (continued < AUTO_CONTINUES) {
						continued++;
						answer.note(`↻ Deckhand asks Antigravity to carry on without it (${continued} of ${AUTO_CONTINUES})`);
						answer.gap();
						blocks = [{ type: "text", text: continueText(r.note) }];
						continue;
					} else {
						answer.note(`Antigravity stopped after a refused action (Deckhand asked it to carry on ${AUTO_CONTINUES} times)`);
						response = { ...response, stopReason: "end_turn" };
					}
				}
				// an ask_question agy waits on: its choices in a picker, the pick sent as the next prompt
				if (question && response?.stopReason === "end_turn" && answered < QUESTIONS_PER_TURN) {
					const c = o.approvals?.();
					const q = parseAskQuestion(question.text, question.input);
					if (c?.hasUI && c.ui && q.options.length) {
						const pick = await pickAnswer(c.ui, q, turnSignal);
						if (signal?.aborted) {
							record(true); // agy's turn ended; only the picker was stopped
							answer.msg.usage = usageOf(usage);
							return answer.finish("aborted", "Request was aborted");
						}
						if (pick !== undefined) {
							answered++;
							answer.note(`? ${clip1(q.question || "Antigravity asks", 80)} → ${clip1(pick, 80)}`);
							answer.gap();
							blocks = [{ type: "text", text: pick }];
							continue;
						}
					}
					waiting = true; // the user's next message is agy's answer
				}
				break;
			}
			answer.msg.usage = usageOf(usage);
			const reason = response?.stopReason;
			const ok = reason === "end_turn" || reason === "max_tokens" || reason === "max_turn_requests";
			record(ok);
			if (reason === "end_turn" || reason === "max_turn_requests") return answer.finish("stop");
			if (reason === "max_tokens") return answer.finish("length");
			if (reason === "refusal") return answer.finish("error", "Antigravity refused to answer this");
			if (reason === "cancelled") return answer.finish("error", "Antigravity cancelled the turn");
			return answer.finish("error", `Antigravity ended the turn (${clip1(reason ?? "no stop reason", 40)})`);
		} finally {
			record(false);
			turnAc.abort(); // a dialog still open for this turn closes with it
			signal?.removeEventListener("abort", onAbort);
			st.sink = undefined;
			st.busy = false;
			o.status?.(waiting ? WAITING_STATUS : undefined);
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
			// each session's locks go only once its agy has ended
			await Promise.all(
				all.map(async (st) => {
					await st.agy?.close().catch(() => {});
					ledger?.releaseAll(st);
				}),
			);
		},
		/** SIGTERM to every agy process, synchronously (pi's process exits). */
		killAll() {
			for (const st of sessions.values()) st.agy?.conn.killNow();
		},
	};
}
