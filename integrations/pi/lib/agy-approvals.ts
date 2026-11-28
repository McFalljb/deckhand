// Approvals for Deckhand's Antigravity sessions (lib/antigravity.ts in tabs, lib/agy-delegate.ts for
// the antigravity tool): how each request agy makes of the client is answered, matching how a pi tab
// treats pi's own tools (lib/guardrails.ts). agy runs in its `default` mode, where it asks before
// it acts, and every ask is answered here, once: never `allow_always`, so agy keeps no standing grant.
//
// - Default (`allow`): allowed (agy's allow_once option), with no dialog, as a pi tab runs pi's own
//   tools; only the user's own opt-ins ask. Except:
//   - a command (an `execute` call, or any call whose rawInput carries CommandLine / command_line /
//     commandLine / command, the fields t3code normalizes) goes through guardrails' checkCommand,
//     the one command gate: a `block` rule rejects it, an `ask` rule (the user wrote it) confirms
//     it, rejected without a UI; a read-only session rejects mutating commands.
//   - read-only sessions (PI_KIT_READONLY=1) reject every edit, delete and move, every command
//     Deckhand cannot read, and every call of a kind that is not a read, search, fetch or think
//     (MCP tools, subagents: they may write).
//   - a read or edit of a protected credential file (lib/credential-paths.ts credentialPath: the
//     core's rule), or a command naming one, is rejected, with a note and no dialog; so is a search
//     in (or a folder read of) a folder that holds credentials (credentialFolder). Every readable
//     path is checked. A command Deckhand cannot read is checked against guardrails' block rules
//     by its title and input.
//   - agy asking to change its mode (kind switch_mode) is rejected: Deckhand keeps it in `default`,
//     so its requests keep coming here.
// - `ask` (per account, /antigravity approvals ask): everything that is not rejected above is
//   confirmed first; without a UI it is rejected.
// - Questions (agy's ask_question: a permission request whose toolCallId is `interaction_…`) are a
//   ctx.ui.select of agy's options; form elicitations a select or input per field. Without a UI,
//   or when the user dismisses them, cancelled (a question) or declined (a form).
// - Every answer adds one line to the thinking (note): "✓ ran: npm test", "✗ blocked by guardrails:
//   rm -rf …". Commands in notes go through guardrails' redact() and are clipped; no file contents.
//
// A dialog is dismissed when the turn is aborted or ends (the turn's own signal): the request is
// then answered `cancelled`, as ACP asks of a client after session/cancel; every request after Esc
// is `cancelled` too. An `interaction_` request shaped as an action is judged as one.
//
// This is a gate on what agy asks, not a sandbox: what agy does without asking is never seen here.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { type AgentAnswer, answerAgentRequest } from "./acp.ts";
import { checkCommand as guardrailsCheck, commandVerdict, configPaths, loadRules, redact } from "./guardrails.ts";
import { credentialFolder, credentialPath } from "./credential-paths.ts";

export type ApprovalMode = "allow" | "ask";
export const APPROVAL_MODES: readonly ApprovalMode[] = ["allow", "ask"];
export const isApprovalMode = (m: unknown): m is ApprovalMode => m === "allow" || m === "ask";

/** The part of pi's ExtensionUIContext used here. */
export interface ApprovalUi {
	confirm(title: string, message: string, opts?: { signal?: AbortSignal }): Promise<boolean>;
	select(title: string, options: string[], opts?: { signal?: AbortSignal }): Promise<string | undefined>;
	input(title: string, placeholder?: string, opts?: { signal?: AbortSignal }): Promise<string | undefined>;
	notify(message: string, type?: "info" | "warning" | "error"): void;
}

export interface ApprovalContext {
	/** The tab's working folder: relative paths resolve against it; the project guardrails file is read from it. */
	cwd: string;
	hasUI: boolean;
	ui?: ApprovalUi;
	/** A read-only session (PI_KIT_READONLY=1). */
	readonly: boolean;
	mode: ApprovalMode;
	/** The turn's abort signal: an open dialog is dismissed (and the request cancelled) on abort. */
	signal?: AbortSignal;
	/** The command gate (guardrails' checkCommand; tests may stand in). */
	checkCommand?: typeof guardrailsCheck;
	/** The environment the credential rules read (HOME, PI_CODING_AGENT_DIR, CODEX_HOME, CLAUDE_CONFIG_DIR). */
	env?: NodeJS.ProcessEnv;
}

export type Answer = AgentAnswer;
export interface Decision {
	answer: Answer;
	/** The line for the thinking stream (and the delegate tool's summary). */
	note: string;
	/** Whether agy may go ahead. */
	allowed: boolean;
	/**
	 * Who said no to an action (not to a question): Deckhand's policy or guardrails' block
	 * ("deckhand"; agy may be asked to carry on without it), or the user in a dialog ("user").
	 */
	refusedBy?: "deckhand" | "user";
}

export const readonlySession = () => process.env.PI_KIT_READONLY === "1";

const ELICITATION = new Set(["session/elicitation", "_session/elicitation", "elicitation/create"]);
const READ_KINDS = new Set(["read", "search", "think", "fetch"]);
const MUTATION_KINDS = new Set(["edit", "delete", "move"]);
const COMMAND_FIELDS = ["CommandLine", "command_line", "commandLine", "command"] as const;
const CWD_FIELDS = ["Cwd", "WorkingDirectory", "working_dir", "workingDir", "cwd"] as const;
// agy's own tools name their file in these (t3code AntigravityChildWork, clientPolicy ACP_RAW_INPUT_PATH_KEYS)
const PATH_FIELDS = ["path", "filePath", "file_path", "Path", "TargetFile", "AbsolutePath", "File", "DirectoryPath", "SearchPath", "SearchDirectory", "Url"] as const; // Url: a file:// one is a path (resolvePath), another scheme is ignored
const MAX_PATHS = 256;

const rec = (v: unknown): Record<string, any> | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, any>) : undefined);
const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);

/** One line of agy's text for a note or a label: control characters (escapes, bidi marks) out, clipped. */
export const clip = (s: unknown, n = 120) => {
	const t = String(s ?? "")
		.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]/g, "")
		.replace(/\s+/g, " ")
		.trim();
	return t.length > n ? `${t.slice(0, n - 1)}…` : t;
};
/** A command as it may appear in a note: secrets redacted, one line, clipped. */
export const shownCommand = (cmd: string, n = 120) => clip(redact(cmd, true), n);

// ---- reading a request ----

/** The command a tool call runs (its rawInput's command field), else undefined. */
export function commandOf(toolCall: any): string | undefined {
	const input = rec(toolCall?.rawInput);
	for (const k of COMMAND_FIELDS) {
		const c = str(input?.[k]);
		if (c) return c;
	}
	return undefined;
}

/** The working folder a command names (rawInput Cwd and the like), else undefined. */
export function commandCwd(toolCall: any): string | undefined {
	const input = rec(toolCall?.rawInput);
	for (const k of CWD_FIELDS) {
		const c = str(input?.[k]);
		if (c) return c;
	}
	return undefined;
}

/**
 * Every path a tool call names (locations, diffs, its rawInput's path fields), each as agy sent
 * it, and whether every part that names one could be read (`complete`). The readable ones are
 * always all there, however many: each is checked.
 */
export function pathsOf(toolCall: any): { paths: string[]; complete: boolean } {
	const out = new Set<string>();
	let complete = true;
	const want = (v: unknown) => {
		if (typeof v !== "string" || !v.trim() || v.includes("\0")) complete = false;
		else out.add(v);
	};
	const { locations, content } = toolCall ?? {};
	if (Array.isArray(locations)) for (const l of locations) want(rec(l)?.path);
	else if (locations != null) complete = false;
	if (Array.isArray(content))
		for (const c of content) {
			const e = rec(c);
			if (e?.type !== "diff") continue;
			if (e.path != null) want(e.path);
			if (Array.isArray(e.changes)) for (const ch of e.changes) for (const k of ["path", "oldPath"]) if (rec(ch)?.[k] != null) want(rec(ch)![k]);
		}
	const input = rec(toolCall?.rawInput);
	if (input) for (const k of PATH_FIELDS) if (input[k] != null) want(input[k]);
	return { paths: [...out], complete: complete && out.size <= MAX_PATHS };
}

/** `p` made absolute against `cwd` (`~` is the home folder); undefined when it cannot be read so. */
export function resolvePath(p: string, cwd: string, home = os.homedir()): string | undefined {
	let s = p.trim();
	if (/^file:\/\//i.test(s)) {
		try {
			s = decodeURIComponent(new URL(s).pathname);
		} catch {
			return undefined;
		}
	}
	if (s === "~") s = home;
	else if (s.startsWith("~/")) s = path.join(home, s.slice(2));
	else if (s.startsWith("~")) return undefined; // another user's home
	if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(s)) return undefined; // another scheme
	return path.resolve(cwd, s);
}

export { canonical, credentialFolder, credentialPath } from "./credential-paths.ts";

/**
 * The credential files a command names: its words read as paths against `cwd` (quotes and
 * backslashes anywhere in a word dropped, $HOME, ${HOME} and ~ expanded), and a glob whose folder
 * holds credentials (credentialFolder) counts as naming them. Best effort: a script, a variable or
 * `cd … && cat auth.json` (a path relative to a folder the command moves to) hides them.
 */
export function credentialsInCommand(cmd: string, cwd: string, env: NodeJS.ProcessEnv = process.env): string[] { // env-read-ok: HOME and credentialPath's names
	const home = env.HOME || os.homedir();
	const words = cmd
		.replace(/\$\{HOME\}|\$HOME\b/g, home)
		.split(/[\s;&|<>()`=]+/)
		.map((w) => w.replace(/["'\\]/g, ""))
		.filter((w) => w && /[./~*?[]/.test(w) && !w.startsWith("-"));
	const out: string[] = [];
	for (const w of words.slice(0, 512)) {
		const glob = w.search(/[*?[]/);
		if (glob >= 0) {
			const dir = resolvePath(w.slice(0, glob).replace(/[^/]*$/, "") || ".", cwd, home);
			// the folder holds credentials, or what the glob is made of names one there (`.claude.json*`),
			// or any file there would be one (a Claude config folder's transcripts)
			const lit = w.slice(w.lastIndexOf("/", glob) + 1).split("/")[0].replace(/[*?[\]]/g, "");
			if (dir && (credentialFolder(dir, env) || (lit && credentialPath(path.join(dir, lit), env)) || credentialPath(path.join(dir, "deckhand-glob-probe"), env))) out.push(w);
			continue;
		}
		const abs = resolvePath(w, cwd, home);
		if (abs && credentialPath(abs, env)) out.push(w);
	}
	return out;
}

// ---- answers ----

const option = (params: any, kind: string) => (Array.isArray(params?.options) ? params.options : []).find((o: any) => o?.kind === kind && typeof o.optionId === "string" && o.optionId.trim());
const allowOnce = (params: any): Answer | undefined => {
	const o = option(params, "allow_once");
	return o ? { result: { outcome: { outcome: "selected", optionId: o.optionId } } } : undefined;
};
/** agy's reject_once option, else cancelled (never reject_always: nothing is remembered either way). */
const rejectOnce = (params: any): Answer => {
	const o = option(params, "reject_once");
	return { result: { outcome: o ? { outcome: "selected", optionId: o.optionId } : { outcome: "cancelled" } } };
};
const CANCELLED: Answer = { result: { outcome: { outcome: "cancelled" } } };

const isQuestion = (params: any) => String(params?.toolCall?.toolCallId ?? "").startsWith("interaction_");
/** A tool call that says what it does (a kind, an input, locations): an action, whatever its id. */
const actionShaped = (tc: any) => !!(tc && ((typeof tc.kind === "string" && tc.kind) || (rec(tc.rawInput) && Object.keys(tc.rawInput).length) || (Array.isArray(tc.locations) && tc.locations.length)));

/** A dialog that resolves undefined when the turn is aborted (or there is no UI). */
async function dialog<T>(c: ApprovalContext, f: (ui: ApprovalUi, opts: { signal?: AbortSignal }) => Promise<T>): Promise<T | undefined> {
	if (!c.hasUI || !c.ui || c.signal?.aborted) return undefined;
	try {
		const v = await f(c.ui, c.signal ? { signal: c.signal } : {});
		return c.signal?.aborted ? undefined : v;
	} catch {
		return undefined;
	}
}

/** Unique labels for agy's options (its names; a repeated one numbered). */
export const MAX_OPTIONS = 50;
function labels(options: any[]): string[] {
	const names = options.map((o) => clip(o?.name || o?.optionId, 200) || clip(o?.optionId, 200));
	const count = new Map<string, number>();
	for (const n of names) count.set(n, (count.get(n) ?? 0) + 1);
	const seen = new Map<string, number>();
	return names.map((n) => {
		const k = (seen.get(n) ?? 0) + 1;
		seen.set(n, k);
		return count.get(n)! > 1 ? `${n} (${k})` : n;
	});
}

async function answerQuestion(params: any, c: ApprovalContext): Promise<Decision> {
	const q = clip(params?.toolCall?.title || "Antigravity asks", 200);
	const options = (Array.isArray(params?.options) ? params.options : []).filter((o: any) => typeof o?.optionId === "string" && o.optionId.trim()).slice(0, MAX_OPTIONS);
	if (!options.length) return { answer: CANCELLED, note: `✗ question not answered (no choices): ${q}`, allowed: false };
	const ls = labels(options);
	const pick = await dialog(c, (ui, o) => ui.select(`Antigravity asks: ${q}`, ls, o));
	const i = pick === undefined ? -1 : ls.indexOf(pick);
	if (i < 0) return { answer: CANCELLED, note: `✗ question not answered${c.hasUI ? "" : " (no UI)"}: ${q}`, allowed: false };
	return { answer: { result: { outcome: { outcome: "selected", optionId: options[i].optionId } } }, note: `? ${q} → ${ls[i]}`, allowed: true };
}

/** A form elicitation (agy's ask_question as a form): a select or an input per field; anything else declined. */
async function answerElicitation(params: any, c: ApprovalContext): Promise<Decision> {
	const message = clip(params?.message || "Antigravity asks", 200);
	const schema = rec(params?.requestedSchema);
	const props = rec(schema?.properties);
	const declined = (why: string): Decision => ({ answer: { result: { action: "decline" } }, note: `✗ question declined (${why}): ${message}`, allowed: false });
	if (params?.mode !== undefined && params.mode !== "form") return declined("not a form");
	if (!props || !Object.keys(props).length) return declined("no fields");
	if (!c.hasUI) return declined("no UI");
	const required = new Set(Array.isArray(schema?.required) ? schema!.required : []);
	const content: Record<string, unknown> = {};
	const shown: string[] = [];
	for (const [key, raw] of Object.entries(props)) {
		const f = rec(raw) ?? {};
		const title = clip(f.title || f.description || key, 200);
		const choices: { label: string; value: unknown }[] | undefined =
			f.type === "boolean"
				? [{ label: "Yes", value: true }, { label: "No", value: false }]
				: Array.isArray(f.oneOf)
					? f.oneOf.filter((o: any) => typeof o?.const === "string").slice(0, MAX_OPTIONS).map((o: any) => ({ label: clip(o.title || o.const, 200), value: o.const }))
					: Array.isArray(f.enum)
						? f.enum.filter((v: unknown) => typeof v === "string").slice(0, MAX_OPTIONS).map((v: string) => ({ label: clip(v, 200) || JSON.stringify(v), value: v }))
						: undefined;
		let value: unknown;
		if (choices) {
			if (!choices.length) return declined("a field Deckhand cannot ask");
			const ls = labels(choices.map((x) => ({ name: x.label, optionId: x.label })));
			const pick = await dialog(c, (ui, o) => ui.select(`Antigravity asks: ${title}`, ls, o));
			if (pick === undefined) return { answer: { result: { action: "cancel" } }, note: `✗ question not answered: ${message}`, allowed: false };
			value = choices[ls.indexOf(pick)]?.value;
		} else if (f.type === undefined || f.type === "string" || f.type === "number" || f.type === "integer") {
			const text = await dialog(c, (ui, o) => ui.input(`Antigravity asks: ${title}`, "", o));
			if (text === undefined) return { answer: { result: { action: "cancel" } }, note: `✗ question not answered: ${message}`, allowed: false };
			if (f.type === "number" || f.type === "integer") {
				const n = Number(text.trim());
				if (!text.trim() || !Number.isFinite(n) || (f.type === "integer" && !Number.isInteger(n))) {
					if (required.has(key)) return declined("not a number");
					continue;
				}
				value = n;
			} else value = text;
		} else return declined("a field Deckhand cannot ask");
		if (value === "" && !required.has(key)) continue;
		content[key] = value;
		shown.push(title);
	}
	return { answer: { result: { action: "accept", content } }, note: `? answered: ${clip(shown.join("; ") || message, 120)}`, allowed: true };
}

/** A confirm; undefined (no UI, dismissed, aborted) and false both mean no. */
async function confirm(c: ApprovalContext, title: string, body: string): Promise<boolean> {
	return (await dialog(c, (ui, o) => ui.confirm(title, body, o))) === true;
}

/** The answer to one request agy made of the client, under the policy above. */
export async function decide(method: string, params: any, c: ApprovalContext): Promise<Decision> {
	// the turn was stopped (Esc): nothing more goes ahead
	if (c.signal?.aborted) {
		if (ELICITATION.has(method)) return { answer: { result: { action: "cancel" } }, note: "✗ stopped: a question", allowed: false };
		if (method !== "session/request_permission") return { answer: answerAgentRequest(method, params), note: `✗ stopped: ${clip(method, 60)}`, allowed: false };
		return { answer: CANCELLED, note: `✗ stopped: ${clip(params?.toolCall?.title || params?.toolCall?.kind || "an action")}`, allowed: false };
	}
	if (ELICITATION.has(method)) return answerElicitation(params, c);
	if (method !== "session/request_permission") return { answer: answerAgentRequest(method, params), note: `✗ refused: ${clip(method, 60)} (Deckhand offers agy no ${method.split("/")[0]} access)`, allowed: false };
	// a question is agy's choices; an interaction_ id with an action's shape (a kind, an input,
	// locations) is judged as the action
	if (isQuestion(params) && !actionShaped(params?.toolCall)) return answerQuestion(params, c);

	const tc = params?.toolCall ?? {};
	const title = clip(tc.title || tc.kind || "an action");
	const reject = (why: string, what = title): Decision => ({ answer: c.signal?.aborted ? CANCELLED : rejectOnce(params), note: `✗ ${why}: ${what}`, allowed: false, refusedBy: why === "you declined" ? "user" : "deckhand" });
	const once = allowOnce(params);
	const allow = (what: string): Decision => (once ? { answer: once, note: `✓ ${what}`, allowed: true } : reject("refused (agy offered no one-time approval)"));
	const env = c.env ?? process.env; // env-read-ok: credentialPath's names only
	const cmd = commandOf(tc);
	const kind = typeof tc.kind === "string" && tc.kind ? tc.kind : cmd ? "execute" : "other";
	const known = pathsOf(tc).paths;
	/** Confirmed: allowed (note `✓ you allowed: what`); else rejected (`✗ you declined: what`, or `noUi` without a UI). */
	const confirmed = async (header: string, body: string, what: string, noUi: string): Promise<Decision> => {
		if (!c.hasUI) return reject(noUi, what);
		return (await confirm(c, header, body)) ? allow(`you allowed: ${what}`) : reject("you declined", what);
	};

	// credential files: never read, changed or named by a command
	const creds = known.filter((p) => {
		const abs = resolvePath(p, c.cwd);
		return !!abs && credentialPath(abs, env);
	});
	if (creds.length) return reject("refused (a protected credential file)", clip(creds[0], 120));
	// a search in a folder that holds credentials, or a read of one of its folders (a listing):
	// what it would match is not known. A file there is judged by its name (above): pi's own
	// settings.json in its agent dir may be read, as in Deckhand
	if (READ_KINDS.has(kind)) {
		const folder = known.find((p) => {
			const abs = resolvePath(p, c.cwd);
			return !!abs && credentialFolder(abs, env) && (kind === "search" || fs.statSync(abs, { throwIfNoEntry: false })?.isFile() !== true);
		});
		if (folder) return reject("refused (a folder with credentials in it)", clip(folder, 120));
	}
	if (cmd) {
		const named = credentialsInCommand(cmd, commandCwd(tc) ? resolvePath(commandCwd(tc)!, c.cwd) ?? c.cwd : c.cwd, env);
		if (named.length) return reject("refused (the command names a protected credential file)", shownCommand(cmd));
	}

	if (kind === "switch_mode") return reject("refused (Deckhand keeps Antigravity in its default mode)");

	if (kind === "execute" || cmd) {
		if (!cmd) {
			// read-only cannot tell whether it mutates: refused; otherwise it runs, as pi's own tools do
			if (c.readonly) return reject("refused (read-only session)");
			// guardrails' block rules against what agy did say of it (its title, its input)
			const rules = loadRules(configPaths(c.cwd)).rules;
			for (const text of [String(tc.title ?? ""), JSON.stringify(tc.rawInput ?? {})]) if (text && commandVerdict(text, false, rules).block) return reject("blocked by guardrails", title);
			if (c.mode === "ask") return confirmed("Allow this Antigravity command?", `${title}\n\nDeckhand cannot read the command line agy sent.`, title, "refused (approvals: ask, and no UI)");
			return allow(`ran: ${title} (a command Deckhand cannot read)`);
		}
		const shown = shownCommand(cmd);
		let asked = false;
		const gateCtx = {
			cwd: c.cwd,
			hasUI: c.hasUI,
			ui: {
				notify: (m: string, t?: any) => c.ui?.notify(m, t),
				confirm: async (t: string, body: string) => ((asked = true), confirm(c, t.replace("this command", "this Antigravity command"), body)),
			},
		} as any;
		const blocked = await (c.checkCommand ?? guardrailsCheck)(cmd, c.readonly, gateCtx);
		if (blocked) {
			const why = /^Read-only/.test(blocked) ? "refused (read-only session)" : /^Blocked by a guardrails rule/.test(blocked) ? "blocked by guardrails" : /^User declined/.test(blocked) ? "you declined" : /no UI/.test(blocked) ? "refused (guardrails asks, and no UI)" : "refused";
			return reject(why, shown);
		}
		if (asked) return allow(`you allowed: ${shown}`);
		if (c.mode === "ask") return confirmed("Allow this Antigravity command?", cmd, shown, "refused (approvals: ask, and no UI)");
		return allow(`ran: ${shown}`);
	}

	if (MUTATION_KINDS.has(kind)) {
		if (c.readonly) return reject("refused (read-only session)");
		const what = known.length ? `${kind} ${clip(known.map((p) => path.basename(p)).join(", "), 100)}` : title;
		if (c.mode === "ask") return confirmed("Allow this Antigravity change?", `${title}\n\n${known.join("\n")}`, what, "refused (approvals: ask, and no UI)");
		return allow(`allowed: ${what}`);
	}

	if (c.readonly && !READ_KINDS.has(kind)) return reject("refused (read-only session)");
	if (c.mode === "ask") return confirmed("Allow this Antigravity action?", title, title, "refused (approvals: ask, and no UI)");
	return allow(`allowed: ${title}`);
}

// ---- tool calls named by id only ----

/**
 * The tool calls of a session as agy's updates described them, so a permission request that names
 * its call by id only is judged by what the call is (t3code withTrackedPermissionToolCall,
 * withTrackedChangedPaths): omitted fields come from the tracked call, and its paths are added.
 */
export class ToolCallTracker {
	private calls = new Map<string, any>();
	private static MAX = 256;

	track(p: any) {
		const u = p?.update;
		if (u?.sessionUpdate !== "tool_call" && u?.sessionUpdate !== "tool_call_update") return;
		if (typeof u.toolCallId !== "string" || !u.toolCallId) return;
		const key = `${p.sessionId}\0${u.toolCallId}`;
		if (u.status === "completed" || u.status === "failed") return void this.calls.delete(key);
		const old = this.calls.get(key) ?? {};
		const next = { ...old };
		for (const k of ["title", "kind", "rawInput"]) if (u[k] !== undefined && u[k] !== null) next[k] = u[k];
		for (const k of ["locations", "content"]) if (Array.isArray(u[k])) next[k] = [...(old[k] ?? []), ...u[k]].slice(-MAX_PATHS);
		this.calls.delete(key);
		this.calls.set(key, next);
		while (this.calls.size > ToolCallTracker.MAX) this.calls.delete(this.calls.keys().next().value!);
	}

	/** The request with what its tracked call said filled in. */
	withTracked(method: string, params: any): any {
		if (method !== "session/request_permission") return params;
		const tc = params?.toolCall;
		const t = typeof tc?.toolCallId === "string" ? this.calls.get(`${params.sessionId}\0${tc.toolCallId}`) : undefined;
		if (!t) return params;
		const own = { ...tc };
		for (const k of ["title", "kind"]) if (own[k] === undefined && t[k] !== undefined) own[k] = t[k];
		// the request's input, with what the tracked call said where it says nothing (a command, a path)
		const ti = rec(t.rawInput), oi = rec(own.rawInput);
		if (ti) own.rawInput = { ...ti, ...Object.fromEntries(Object.entries(oi ?? {}).filter(([, v]) => v !== undefined && v !== null && v !== "")) };
		// the tracked call's readable paths added to the request's own (never in their place)
		const tpaths = pathsOf({ locations: t.locations, content: t.content, rawInput: t.rawInput }).paths;
		if (tpaths.length) own.locations = [...(Array.isArray(own.locations) ? own.locations : []), ...tpaths.map((p) => ({ path: p }))];
		return { ...params, toolCall: own };
	}
}
