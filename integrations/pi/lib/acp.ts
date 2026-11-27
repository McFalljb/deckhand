// A small client for the Agent Client Protocol (ACP: JSON-RPC 2.0, one message per line over a
// child's stdio), enough to drive Google's Antigravity CLI (`agy acp`) from pi
// (extensions/antigravity). Written for agy as t3code drives it (apps/server/src/provider/acp/
// AntigravityAcpSupport.ts, packages/effect-acp), without its dependencies:
//
// - Identity: clientInfo `deckhand-pi`. Nothing here claims to be another client, sends a header,
//   reads agy's stored sign-in or talks to Google: agy runs the whole turn (model, tools, its own
//   system prompt) and keeps its credential itself.
// - Capabilities: none. No fs (read or write) and no terminal, so agy uses its own tools, and every
//   request it makes of the client is answered: session/request_permission and ask_question
//   (`interaction_…` tool calls) are declined, elicitations declined, anything else "method not
//   found". Approvals are a later, separately reviewed step (docs/HARNESSES.md §3a).
// - agy reports `protocolVersion: 2` with the v1 response shape (agentInfo, agentCapabilities:
//   effect-acp client.ts "Antigravity, for example, reports version 2 with the v1 … shape"), so the
//   request carries both shapes, as t3code's does, and the response is read as v1.
// - Version: agentInfo.version (`agy_acp_server_1.5.12`); below 1.5.1 is refused (older runtimes
//   allowlist the editors their models serve: t3code OPEN_MODEL_ACCESS_RELEASE). Unparseable passes.
// - agy prints its sign-in link on stdout or stderr when it has no sign-in ("Open the following
//   link to authenticate the ACP server: <url>"); such a line is not JSON-RPC and means "sign in".
import { type ChildProcess, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export const CLIENT_INFO = { name: "deckhand-pi", title: "Deckhand (pi)", version: "0.1.0" } as const;
export const AGY_MIN_VERSION = "1.5.1";
export const AGY_RECOMMENDED_VERSION = "1.5.12";
/** Overrides the PATH lookup with an absolute path to agy (or a stand-in, in tests). */
export const SIGN_IN_PREFIX = "Open the following link to authenticate the ACP server: ";
/** What every request of agy's for approval or input gets until approvals are reviewed. */
export const DECLINED_NOTE = "declined: Deckhand's Antigravity tabs do not grant approvals yet";
const MAX_LINE = 16 * 1024 * 1024;

/** agy's version as [major, minor, patch] (`agy_acp_server_1.5.12`, `v1.5.12`, `1.5.12`), else undefined. */
export function parseAgyVersion(v: unknown): [number, number, number] | undefined {
	const m = /^(?:v|agy_acp_server_)?(\d+)\.(\d+)\.(\d+)/.exec(typeof v === "string" ? v.trim() : "");
	return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : undefined;
}

/** Whether a reported version is below the minimum. An unparseable or missing one is not. */
export function agyTooOld(v: unknown, min = AGY_MIN_VERSION): boolean {
	const got = parseAgyVersion(v), want = parseAgyVersion(min)!;
	if (!got) return false;
	for (let i = 0; i < 3; i++) if (got[i] !== want[i]) return got[i] < want[i];
	return false;
}

function executable(p: string): boolean {
	try {
		const st = fs.statSync(p);
		if (!st.isFile()) return false;
		fs.accessSync(p, fs.constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

/** Whether `p` can be agy's path setting: an absolute path to an executable file (never looked up). */
export const usableAgyPath = (p: string | undefined): p is string => !!p && path.isAbsolute(p) && executable(p);

/**
 * The agy binary: `agy` or `antigravity` (the name of macOS downloads) on PATH. A few stats, no
 * process started. The user's own path setting (`/antigravity path`) comes first: the extension
 * passes it as `configured` when it is usable.
 */
export function findAgy(env: NodeJS.ProcessEnv = process.env, configured?: string): string | undefined {
	if (usableAgyPath(configured)) return configured;
	const dirs = (env.PATH ?? "").split(path.delimiter).filter((d) => d && path.isAbsolute(d));
	for (const name of ["agy", "antigravity"]) for (const d of dirs) if (executable(path.join(d, name))) return path.join(d, name);
	return undefined;
}

/** The environment agy runs with: pi's, without Deckhand's own variables. */
export function agyEnv(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
	return Object.fromEntries(Object.entries(env).filter(([k]) => !k.startsWith("DECKHAND_")));
}

export class AcpError extends Error {
	code?: number;
	data?: unknown;
	constructor(message: string, code?: number, data?: unknown) {
		super(message);
		this.code = code;
		this.data = data;
	}
}
/** agy has no sign-in (it printed its link, or answered auth_required). */
export class SignInRequired extends AcpError {}

/** ACP's auth_required error code. */
export const AUTH_REQUIRED = -32000;

/** The answer to a request agy makes of the client: every approval and question declined. */
export function answerAgentRequest(method: string, params: any): { result?: unknown; error?: { code: number; message: string } } {
	if (method === "session/request_permission") {
		// A question (agy's ask_question: `interaction_…`) has choices, not approvals: none is picked.
		const question = String(params?.toolCall?.toolCallId ?? "").startsWith("interaction_");
		const reject = question ? undefined : (params?.options ?? []).find((o: any) => o?.kind === "reject_once" && typeof o.optionId === "string" && o.optionId.trim());
		return { result: { outcome: reject ? { outcome: "selected", optionId: reject.optionId } : { outcome: "cancelled" } } };
	}
	if (method === "session/elicitation" || method === "_session/elicitation" || method === "elicitation/create") return { result: { action: "decline" } };
	return { error: { code: -32601, message: `Method not found: ${method}` } };
}

/** A sign-in link in one line of agy's output, or undefined. */
export function signInLink(line: string): string | undefined {
	const s = line.trim();
	if (s.startsWith(SIGN_IN_PREFIX)) return s.slice(SIGN_IN_PREFIX.length).trim();
	return undefined;
}

export interface AcpConnectionOptions {
	cwd: string;
	env?: NodeJS.ProcessEnv;
	/** Each session/update notification's params. */
	onUpdate?: (params: any) => void;
	/** Each request agy made of the client, after it was answered (method, params, the answer). */
	onAgentRequest?: (method: string, params: any, answer: unknown) => void;
	/** agy printed a sign-in link. */
	onSignIn?: (url: string) => void;
	/** The process ended (after start). */
	onExit?: (code: number | null, signal: NodeJS.Signals | null) => void;
	spawnImpl?: typeof spawn;
}

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void; method: string };

/** One agy process and its JSON-RPC stream. */
export class AcpConnection {
	readonly command: string;
	readonly args: string[];
	private child?: ChildProcess;
	private nextId = 1;
	private pending = new Map<number, Pending>();
	private buf = "";
	private ended?: Error;
	private opts: AcpConnectionOptions;
	readonly exited: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
	private markExited!: (x: { code: number | null; signal: NodeJS.Signals | null }) => void;

	constructor(command: string, args: string[], opts: AcpConnectionOptions) {
		this.command = command;
		this.args = args;
		this.opts = opts;
		this.exited = new Promise((r) => (this.markExited = r));
	}

	get alive(): boolean {
		return !!this.child && !this.ended;
	}

	start(): void {
		const child = (this.opts.spawnImpl ?? spawn)(this.command, this.args, { cwd: this.opts.cwd, env: this.opts.env ?? agyEnv(), stdio: ["pipe", "pipe", "pipe"] });
		this.child = child;
		child.stdout!.setEncoding("utf8");
		child.stdout!.on("data", (s: string) => this.onData(s));
		let errBuf = "";
		child.stderr!.setEncoding("utf8");
		child.stderr!.on("data", (s: string) => {
			// only sign-in links are read; the rest of agy's log stays out of pi
			const lines = (errBuf + s).split("\n");
			errBuf = (lines.pop() ?? "").slice(-MAX_LINE);
			for (const l of lines) this.noticeLink(l);
		});
		child.stdin!.on("error", () => {}); // EPIPE after a crash: reported by "exit"
		child.on("error", (e) => this.fail(new AcpError(`Antigravity (agy) could not start: ${e.message}`)));
		child.on("exit", (code, signal) => {
			this.fail(new AcpError(`Antigravity (agy) ended${code !== null ? ` with exit code ${code}` : signal ? ` (${signal})` : ""}`));
			this.markExited({ code, signal });
			this.opts.onExit?.(code, signal);
		});
	}

	private noticeLink(line: string) {
		const url = signInLink(line);
		if (url) this.opts.onSignIn?.(url);
	}

	private onData(s: string) {
		this.buf += s;
		if (this.buf.length > MAX_LINE && !this.buf.includes("\n")) {
			this.buf = "";
			this.fail(new AcpError("Antigravity (agy) sent a line that is too long"));
			this.close();
			return;
		}
		let i: number;
		while ((i = this.buf.indexOf("\n")) >= 0) {
			const line = this.buf.slice(0, i).replace(/\r$/, "");
			this.buf = this.buf.slice(i + 1);
			this.onLine(line);
		}
	}

	private onLine(line: string) {
		if (!line.trim()) return;
		let msg: any;
		try {
			msg = JSON.parse(line);
		} catch {
			this.noticeLink(line); // agy's own text on stdout: only its sign-in link means anything
			return;
		}
		if (!msg || typeof msg !== "object" || msg.jsonrpc !== "2.0") return;
		if (typeof msg.method === "string" && msg.id !== undefined && msg.id !== null) {
			const answer = answerAgentRequest(msg.method, msg.params);
			this.write({ jsonrpc: "2.0", id: msg.id, ...answer });
			this.opts.onAgentRequest?.(msg.method, msg.params, answer.result ?? answer.error);
			return;
		}
		if (typeof msg.method === "string") {
			if (msg.method === "session/update") this.opts.onUpdate?.(msg.params);
			return;
		}
		const p = typeof msg.id === "number" ? this.pending.get(msg.id) : undefined;
		if (!p) return;
		this.pending.delete(msg.id);
		if (msg.error) {
			const e = msg.error;
			const Err = e?.code === AUTH_REQUIRED ? SignInRequired : AcpError;
			p.reject(new Err(`Antigravity: ${typeof e?.message === "string" && e.message ? e.message : "request failed"} (${p.method})`, e?.code, e?.data));
		} else p.resolve(msg.result ?? {});
	}

	private write(msg: unknown) {
		if (!this.child || this.ended) return;
		this.child.stdin!.write(`${JSON.stringify(msg)}\n`);
	}

	/** One request; rejects on its error, the process's end, or `timeoutMs`. */
	request(method: string, params: unknown, timeoutMs = 0): Promise<any> {
		if (this.ended) return Promise.reject(this.ended);
		if (!this.child) return Promise.reject(new AcpError("Antigravity (agy) is not started"));
		const id = this.nextId++;
		return new Promise((resolve, reject) => {
			let timer: NodeJS.Timeout | undefined;
			const done = (f: (x: any) => void) => (x: any) => {
				if (timer) clearTimeout(timer);
				f(x);
			};
			this.pending.set(id, { resolve: done(resolve), reject: done(reject), method });
			if (timeoutMs > 0)
				timer = setTimeout(() => {
					if (this.pending.delete(id)) reject(new AcpError(`Antigravity (agy) did not answer ${method} in ${Math.round(timeoutMs / 1000)} s`));
				}, timeoutMs);
			this.write({ jsonrpc: "2.0", id, method, params });
		});
	}

	notify(method: string, params: unknown): void {
		this.write({ jsonrpc: "2.0", method, params });
	}

	private fail(e: Error) {
		if (this.ended) return;
		this.ended = e;
		for (const p of this.pending.values()) p.reject(e);
		this.pending.clear();
	}

	/** SIGTERM now, synchronously (pi is exiting). */
	killNow(): void {
		this.fail(new AcpError("Antigravity (agy) was stopped"));
		try {
			if (this.child && this.child.exitCode === null && this.child.signalCode === null) this.child.kill("SIGTERM");
		} catch {}
	}

	/** Ends the process: SIGTERM, then SIGKILL after `graceMs`. */
	close(graceMs = 1000): Promise<void> {
		const child = this.child;
		this.fail(new AcpError("Antigravity (agy) was stopped"));
		if (!child || child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
		try {
			child.stdin!.end();
			child.kill("SIGTERM");
		} catch {}
		const t = setTimeout(() => {
			try {
				child.kill("SIGKILL");
			} catch {}
		}, graceMs);
		t.unref?.();
		return this.exited.then(() => clearTimeout(t));
	}
}

/** initialize's request: v2's fields plus v1's (clientCapabilities, clientInfo), as agy accepts. */
export function initializeParams() {
	return {
		protocolVersion: 2,
		info: CLIENT_INFO,
		capabilities: {},
		clientInfo: CLIENT_INFO,
		clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
	};
}
