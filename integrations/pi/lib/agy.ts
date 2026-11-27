// One Antigravity session: an `agy acp` process (lib/acp.ts) with one ACP session in it, in agy's
// `default` mode. The steps are t3code's (provider-acp AcpSessionRuntime startOnce with
// authenticateEagerly, AntigravityAcpSupport): initialize, `authenticate` with the account's method
// (always: agy picks its credential source from the method, and accepts methods it does not list),
// session/new (or session/resume), the mode, then the model by its `model` config option
// (session/set_config_option); thinking by the option of category `thought_level`. The profile and
// environment are the account's (lib/agy-accounts.ts). No sign-in: auth_required, "No browser is
// available here" (agy 1.5 without a display), or a sign-in link on agy's output.
import { AcpConnection, type AcpConnectionOptions, AcpError, AGY_MIN_VERSION, AGY_RECOMMENDED_VERSION, agyEnv, agyTooOld, initializeParams, SignInRequired } from "./acp.ts";

export const SIGN_IN_HINT = "Antigravity is not signed in: run /antigravity-login";
const STARTUP_TIMEOUT_MS = 60_000;

export interface AgyModel {
	id: string;
	name: string;
	description?: string;
}

/** The models a session offers: its `model` config option (or v1's `models.availableModels`). */
export function modelsOf(setup: any): AgyModel[] {
	const opt = configOption(setup?.configOptions, "model");
	if (opt) return selectValues(opt).map((o) => ({ id: o.value, name: o.name || o.value, ...(o.description ? { description: o.description } : {}) }));
	const avail = setup?.models?.availableModels;
	if (Array.isArray(avail))
		return avail.filter((m: any) => typeof m?.modelId === "string" && m.modelId).map((m: any) => ({ id: m.modelId, name: typeof m.name === "string" && m.name ? m.name : m.modelId }));
	return [];
}

/** A config option by id, or (for model and thinking) by category. */
export function configOption(options: unknown, idOrCategory: string): any {
	if (!Array.isArray(options)) return undefined;
	return options.find((o: any) => o?.id === idOrCategory) ?? options.find((o: any) => o?.category === idOrCategory);
}

/** A select option's values, flattening groups. */
export function selectValues(opt: any): { value: string; name: string; description?: string }[] {
	if (opt?.type !== "select" || !Array.isArray(opt.options)) return [];
	return opt.options.flatMap((o: any) => ("value" in (o ?? {}) ? [o] : Array.isArray(o?.options) ? o.options : [])).filter((o: any) => typeof o?.value === "string" && o.value);
}

export interface AgySessionOptions {
	agyPath: string;
	cwd: string;
	/** Resume this agy session id instead of starting a new one (session/resume, when advertised). */
	resumeId?: string;
	/** agy's arguments (the account's profile: agyArgs); `acp` alone by default. */
	args?: string[];
	/** The process's own TMPDIR folder (agy-accounts runDir), removed when it ends. */
	runDir?: string;
	env?: NodeJS.ProcessEnv;
	/** The sign-in method passed to `authenticate` (the account's). */
	authMethod?: string;
	/** What a missing sign-in says (the account's command). */
	signInHint?: string;
	/** An interactive sign-in (Gemini Enterprise): agy's link is shown here instead of failing, and authenticate may take this long. */
	signIn?: { showLink: (url: string) => void; timeoutMs: number };
	onUpdate?: (params: any) => void;
	onAgentRequest?: AcpConnectionOptions["onAgentRequest"];
	onExit?: () => void;
	spawnImpl?: AcpConnectionOptions["spawnImpl"];
}

export class AgySession {
	readonly conn: AcpConnection;
	sessionId = "";
	initialize: any = {};
	configOptions: any[] = [];
	modes: any;
	models: AgyModel[] = [];
	agentVersion = "";
	private signInSeen = false;
	private signInWaiters: ((url: string) => void)[] = [];
	busy = false;

	private constructor(conn: AcpConnection) {
		this.conn = conn;
	}

	/** Starts agy and opens (or resumes) a session in `default` mode. Throws SignInRequired, AcpError. */
	static async open(o: AgySessionOptions): Promise<AgySession> {
		let self!: AgySession;
		const conn = new AcpConnection(o.agyPath, o.args ?? ["acp"], {
			cwd: o.cwd,
			runDir: o.runDir,
			env: o.env ?? agyEnv(),
			spawnImpl: o.spawnImpl,
			onUpdate: (p) => o.onUpdate?.(p),
			onAgentRequest: o.onAgentRequest,
			onSignIn: (url) => (o.signIn ? o.signIn.showLink(url) : self?.sawSignIn(url)),
			onExit: () => o.onExit?.(),
		});
		self = new AgySession(conn);
		conn.start();
		try {
			await self.handshake(o);
			return self;
		} catch (e) {
			await conn.close();
			throw e;
		}
	}

	private hint = SIGN_IN_HINT;

	private sawSignIn(url: string) {
		this.signInSeen = true;
		for (const w of this.signInWaiters.splice(0)) w(url);
	}

	/** `p`, failing with SignInRequired as soon as agy prints a sign-in link. */
	private untilSignIn<T>(p: Promise<T>): Promise<T> {
		if (this.signInSeen) return Promise.reject(new SignInRequired(this.hint));
		return new Promise<T>((resolve, reject) => {
			this.signInWaiters.push(() => reject(new SignInRequired(this.hint)));
			p.then(resolve, reject);
		});
	}

	private async handshake(o: AgySessionOptions) {
		if (o.signInHint) this.hint = o.signInHint;
		const init = await this.conn.request("initialize", initializeParams(), STARTUP_TIMEOUT_MS);
		this.initialize = init ?? {};
		this.agentVersion = String(this.initialize?.agentInfo?.version ?? this.initialize?.info?.version ?? "");
		if (agyTooOld(this.agentVersion))
			throw new AcpError(`Antigravity CLI ${this.agentVersion} is older than ${AGY_MIN_VERSION}, the first that serves other clients: update agy (${AGY_RECOMMENDED_VERSION} or newer)`);
		const signedOut = (e: unknown) =>
			e instanceof SignInRequired || (e instanceof AcpError && e.code === -32603 && /No browser is available here/.test(String(e.data ?? e.message)));
		const method = o.authMethod ?? "oauth-personal";
		try {
			await this.untilSignIn(this.conn.request("authenticate", { methodId: method }, o.signIn?.timeoutMs ?? STARTUP_TIMEOUT_MS));
		} catch (e) {
			throw signedOut(e) ? new SignInRequired(this.hint) : e;
		}
		let created: any;
		try {
			const caps = this.initialize?.agentCapabilities ?? {};
			if (o.resumeId && caps?.sessionCapabilities?.resume != null) {
				const r = await this.untilSignIn(this.conn.request("session/resume", { sessionId: o.resumeId, cwd: o.cwd, mcpServers: [] }, STARTUP_TIMEOUT_MS));
				created = { ...r, sessionId: o.resumeId };
			} else created = await this.untilSignIn(this.conn.request("session/new", { cwd: o.cwd, mcpServers: [] }, STARTUP_TIMEOUT_MS));
		} catch (e) {
			throw signedOut(e) ? new SignInRequired(this.hint) : e;
		}
		if (typeof created?.sessionId !== "string" || !created.sessionId) throw new AcpError("Antigravity: session/new returned no session id");
		this.sessionId = created.sessionId;
		this.configOptions = Array.isArray(created.configOptions) ? created.configOptions : [];
		this.modes = created.modes;
		this.models = modelsOf(created);
		await this.setMode("default");
	}

	/**
	 * agy's mode: by its `mode` config option, else session/set_mode when it reports modes. Fails
	 * closed: a session that reports neither, or whose option does not take the value, is refused
	 * (its mode decides what agy does without asking).
	 */
	async setMode(modeId: string) {
		const refuse = () =>
			new AcpError(`Deckhand cannot confirm that Antigravity runs in its ${modeId} mode (this agy reports no mode it can set): not sending messages to it; update agy`);
		const modeOpt = () => this.configOptions.find((x: any) => x?.category === "mode" && x?.type === "select");
		const opt = modeOpt();
		if (opt) {
			if (opt.currentValue !== modeId) await this.setConfig(opt.id, modeId);
			if (modeOpt()?.currentValue !== modeId) throw refuse();
			return;
		}
		if (!this.modes || !Array.isArray(this.modes.availableModes)) throw refuse();
		if (this.modes.currentModeId !== modeId) {
			if (!this.modes.availableModes.some((m: any) => m?.id === modeId)) throw refuse();
			await this.conn.request("session/set_mode", { sessionId: this.sessionId, modeId }, STARTUP_TIMEOUT_MS);
			this.modes = { ...this.modes, currentModeId: modeId };
		}
	}

	async setConfig(configId: string, value: string) {
		const r = await this.conn.request("session/set_config_option", { sessionId: this.sessionId, configId, value }, STARTUP_TIMEOUT_MS);
		if (Array.isArray(r?.configOptions)) this.configOptions = r.configOptions;
		else this.configOptions = this.configOptions.map((x: any) => (x?.id === configId ? { ...x, currentValue: value } : x));
	}

	get currentModel(): string | undefined {
		return configOption(this.configOptions, "model")?.currentValue;
	}

	/** Selects `modelId` (agy's own default for "default"). Throws when the account has no such model. */
	async selectModel(modelId: string) {
		if (!modelId || modelId === "default") return;
		const opt = configOption(this.configOptions, "model");
		if (!opt) throw new AcpError(`This Antigravity session offers no model choice, so it cannot run '${modelId}': pick Antigravity (agy's default model) in /model`);
		if (!selectValues(opt).some((v) => v.value === modelId)) throw new AcpError(`Antigravity model '${modelId}' is not available for this account: pick another in /model`);
		if (opt.currentValue !== modelId) await this.setConfig(opt.id, modelId);
	}

	/** Thinking: pi's level when agy's `thought_level` option has a value of that name. */
	async selectThinking(level: string | undefined) {
		const opt = configOption(this.configOptions, "thought_level");
		if (!opt || !level) return;
		if (selectValues(opt).some((v) => v.value === level) && opt.currentValue !== level) await this.setConfig(opt.id, level);
	}

	get thinkingLevels(): string[] {
		return selectValues(configOption(this.configOptions, "thought_level")).map((v) => v.value);
	}

	/** One prompt turn; resolves with agy's PromptResponse ({stopReason, usage?}). */
	prompt(prompt: unknown[]): Promise<any> {
		return this.conn.request("session/prompt", { sessionId: this.sessionId, prompt });
	}

	cancel() {
		this.conn.notify("session/cancel", { sessionId: this.sessionId });
	}

	/** session/close when agy advertises it, then the process ends. */
	async close() {
		if (this.conn.alive && this.initialize?.agentCapabilities?.sessionCapabilities?.close != null && this.sessionId)
			await this.conn.request("session/close", { sessionId: this.sessionId }, 2000).catch(() => {});
		await this.conn.close();
	}
}

/** The models of a throwaway session (closed again), for /model. */
export async function probeModels(o: Omit<AgySessionOptions, "resumeId">): Promise<{ models: AgyModel[]; thinking: string[]; version: string }> {
	const s = await AgySession.open(o);
	try {
		return { models: s.models, thinking: s.thinkingLevels, version: s.agentVersion };
	} finally {
		await s.close();
	}
}

type BareOptions = Pick<AgySessionOptions, "agyPath" | "cwd" | "args" | "env" | "spawnImpl" | "runDir">;

/** `initialize` only (no session, no sign-in): agy's reported version. */
export async function agyVersion(o: BareOptions): Promise<string> {
	const conn = new AcpConnection(o.agyPath, o.args ?? ["acp"], { cwd: o.cwd, env: o.env ?? agyEnv(), spawnImpl: o.spawnImpl, runDir: o.runDir });
	conn.start();
	try {
		const init = await conn.request("initialize", initializeParams(), 30_000);
		return String(init?.agentInfo?.version ?? init?.info?.version ?? "");
	} finally {
		await conn.close();
	}
}

/** Sign-out by agy's own ACP `logout` (t3code AntigravityAuth.logout): its saved login goes, its history stays. */
export async function agyLogout(o: BareOptions): Promise<void> {
	const conn = new AcpConnection(o.agyPath, o.args ?? ["acp"], { cwd: o.cwd, env: o.env ?? agyEnv(), spawnImpl: o.spawnImpl, runDir: o.runDir });
	conn.start();
	try {
		const init = await conn.request("initialize", initializeParams(), 30_000);
		if (init?.agentCapabilities?.auth?.logout == null) throw new AcpError("This Antigravity version cannot sign out: update agy");
		await conn.request("logout", {}, 90_000);
	} finally {
		await conn.close();
	}
}
