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
import type { AgyModel } from "./agy.ts";

export const PROVIDER_ID = "antigravity";
export const API = "antigravity-acp";
export const DEFAULT_MODEL_ID = "default";
// agy does not report these; Gemini's window, and an output cap agy enforces itself
const CONTEXT_WINDOW = 1_000_000;
const MAX_TOKENS = 65_536;
const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

/** One pi model for an agy model. Thinking is on offer when agy has thought levels. */
export function piModel(m: { id: string; name: string }, reasoning: boolean) {
	return {
		id: m.id,
		name: m.id === DEFAULT_MODEL_ID ? "Antigravity (agy's default model)" : `${m.name} (Antigravity)`,
		api: API,
		provider: PROVIDER_ID,
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
export function modelList(models: AgyModel[], thinking: string[]): PiModel[] {
	const seen = new Set([DEFAULT_MODEL_ID]);
	const out = [piModel({ id: DEFAULT_MODEL_ID, name: "default" }, false)];
	for (const m of models) if (!seen.has(m.id)) (seen.add(m.id), out.push(piModel(m, thinking.length > 0)));
	return out;
}

/** What pi's model registry offers an extension (ctx.modelRegistry), as far as this uses it. */
export interface Registry {
	refresh(o: { providers: string[]; allowNetwork?: boolean }): Promise<unknown>;
}

export interface AntigravityOptions {
	agyPath: string;
	streamSimple?: (model: any, context: any, options?: any) => any;
}

/** The provider and its live model list. */
export function createAntigravity(o: AntigravityOptions) {
	let models: PiModel[] = modelList([], []);
	let registry: Registry | undefined;
	const auth = { type: "api_key" as const, source: `agy (${o.agyPath})` };
	const provider = {
		id: PROVIDER_ID,
		name: "Antigravity",
		baseUrl: "acp:agy",
		auth: {
			apiKey: {
				name: "Antigravity CLI sign-in (agy; /antigravity-login)",
				check: async () => auth,
				resolve: async () => ({ auth: {}, source: auth.source }),
			},
		},
		getModels: () => models,
		streamSimple: (model: any, context: any, options?: any) => o.streamSimple!(model, context, options),
		stream: (model: any, context: any, options?: any) => o.streamSimple!(model, context, options),
	};
	return {
		provider,
		get models() {
			return models;
		},
		/** Where model changes are announced (the session's ctx.modelRegistry). */
		bind(r: Registry | undefined) {
			registry = r;
		},
		/** The account's models, as a session listed them; pi's /model shows them after its refresh. */
		async setModels(list: AgyModel[], thinking: string[]) {
			const next = modelList(list, thinking);
			if (JSON.stringify(next) === JSON.stringify(models)) return false;
			models = next;
			// pi reads getModels() again when it recomposes the provider (ModelRuntime.refresh)
			await registry?.refresh({ providers: [PROVIDER_ID], allowNetwork: false }).catch(() => {});
			return true;
		},
	};
}
