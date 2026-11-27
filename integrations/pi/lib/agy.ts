// One Antigravity session: an `agy acp` process (lib/acp.ts) with one ACP session in it, in agy's
// `default` mode. The steps are t3code's (provider-acp AcpSessionRuntime startOnce,
// AntigravityAcpSupport): initialize, session/new (or session/resume), the mode, then the model by
// its `model` config option (session/set_config_option); thinking by the option of category
// `thought_level`. Unlike t3code it runs the user's own agy profile (no --gemini-dir of its own)
// and does not authenticate eagerly: agy uses the sign-in it has, and on auth_required it is asked
// once to use it (`authenticate`, its first advertised method); a sign-in link instead means
// "run /antigravity-login".
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
	env?: NodeJS.ProcessEnv;
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
		const conn = new AcpConnection(o.agyPath, ["acp"], {
			cwd: o.cwd,
			env: o.env ?? agyEnv(),
			spawnImpl: o.spawnImpl,
			onUpdate: (p) => o.onUpdate?.(p),
			onAgentRequest: o.onAgentRequest,
			onSignIn: (url) => self?.sawSignIn(url),
			onExit: () => o.onExit?.(),
		});
		self = new AgySession(conn);
		conn.start();
		try {
			await self.handshake(o);
			return self;
		} catch (e) {
			await conn.close(200);
			throw e;
		}
	}

	private sawSignIn(url: string) {
		this.signInSeen = true;
		for (const w of this.signInWaiters.splice(0)) w(url);
	}

	/** `p`, failing with SignInRequired as soon as agy prints a sign-in link. */
	private untilSignIn<T>(p: Promise<T>): Promise<T> {
		if (this.signInSeen) return Promise.reject(new SignInRequired(SIGN_IN_HINT));
		return new Promise<T>((resolve, reject) => {
			this.signInWaiters.push(() => reject(new SignInRequired(SIGN_IN_HINT)));
			p.then(resolve, reject);
		});
	}

	private async handshake(o: AgySessionOptions) {
		const init = await this.conn.request("initialize", initializeParams(), STARTUP_TIMEOUT_MS);
		this.initialize = init ?? {};
		this.agentVersion = String(this.initialize?.agentInfo?.version ?? this.initialize?.info?.version ?? "");
		if (agyTooOld(this.agentVersion))
			throw new AcpError(`Antigravity CLI ${this.agentVersion} is older than ${AGY_MIN_VERSION}, the first that serves other clients: update agy (${AGY_RECOMMENDED_VERSION} or newer)`);
		const setup = async () => {
			const caps = this.initialize?.agentCapabilities ?? {};
			if (o.resumeId && caps?.sessionCapabilities?.resume != null) {
				const r = await this.untilSignIn(this.conn.request("session/resume", { sessionId: o.resumeId, cwd: o.cwd, mcpServers: [] }, STARTUP_TIMEOUT_MS));
				return { ...r, sessionId: o.resumeId };
			}
			return this.untilSignIn(this.conn.request("session/new", { cwd: o.cwd, mcpServers: [] }, STARTUP_TIMEOUT_MS));
		};
		let created: any;
		try {
			created = await setup();
		} catch (e) {
			if (!(e instanceof SignInRequired) || this.signInSeen) throw e instanceof SignInRequired ? new SignInRequired(SIGN_IN_HINT) : e;
			// auth_required: ask agy once to use the sign-in it has (its first method)
			const method = (this.initialize?.authMethods ?? []).find((m: any) => typeof m?.id === "string")?.id;
			if (!method) throw new SignInRequired(SIGN_IN_HINT);
			try {
				await this.untilSignIn(this.conn.request("authenticate", { methodId: method }, STARTUP_TIMEOUT_MS));
				created = await setup();
			} catch (e2) {
				throw e2 instanceof SignInRequired ? new SignInRequired(SIGN_IN_HINT) : e2;
			}
		}
		if (typeof created?.sessionId !== "string" || !created.sessionId) throw new AcpError("Antigravity: session/new returned no session id");
		this.sessionId = created.sessionId;
		this.configOptions = Array.isArray(created.configOptions) ? created.configOptions : [];
		this.modes = created.modes;
		this.models = modelsOf(created);
		await this.setMode("default");
	}

	/** agy's mode: by its `mode` config option, else session/set_mode when it reports modes. */
	async setMode(modeId: string) {
		const opt = this.configOptions.find((x: any) => x?.category === "mode" && x?.type === "select");
		if (opt) {
			if (opt.currentValue !== modeId) await this.setConfig(opt.id, modeId);
			return;
		}
		if (this.modes && this.modes.currentModeId !== modeId) {
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
		if (!opt) return;
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
