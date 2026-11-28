/**
 * Deckhand's Antigravity extension: Google Antigravity in pi tabs, through the user's own
 * Antigravity CLI (`agy acp`, ACP over stdio: lib/acp.ts, lib/agy.ts), as t3code drives it.
 *
 * - Without agy (the path set by `/antigravity path` in accounts.json, else `agy` on
 *   PATH: a few stats, no process) only `/antigravity` is registered: it says
 *   where to get agy and sets its path. No provider, hook, status line or output. Once a path is
 *   set, the rest is registered in the same pi session. No environment variable picks the binary.
 * - With agy: one pi provider per account (lib/agy-accounts.ts): `antigravity` for the account
 *   `default`, `antigravity-<name>` for the others, each with a private agy profile and its own
 *   sign-in method. The user picks the account by picking its model; nothing switches accounts by
 *   itself. Loading reads accounts.json only; profiles are made when agy first runs for an account.
 *   accounts.json is read again whenever the extension acts (Deckhand changes it too); an account
 *   Deckhand added while pi runs gets its provider at pi's next start or /reload.
 * - `/antigravity`: the status (agy and its version, each account, its method, whether it is signed
 *   in, its models) and a menu; `/antigravity add|login|logout|remove|models [name]` directly;
 *   `/antigravity path [/abs/agy]` sets (or clears) agy's path; `/antigravity login` (no name)
 *   signs in the default account. It is the only command: pi 1.5.2 builds its autocomplete list
 *   at start, reload and session switch only, so a command registered later (by /antigravity path)
 *   would not be offered until then.
 * - Honest: Deckhand's own client name (deckhand-pi), no spoofed headers; agy keeps its sign-in,
 *   Deckhand never reads it and never calls Google. An API key lives in pi's credential store
 *   (`/login antigravity-<name>`) and reaches agy only in its environment.
 * - Approvals (lib/agy-approvals.ts): agy runs in its `default` mode and asks; Deckhand answers as a
 *   pi tab treats pi's own tools: allowed once (never "always"), except what the user's guardrails
 *   rules block or ask, what a read-only session forbids and protected credential files (refused). `/antigravity approvals ask [name]` confirms every
 *   action of that account; `allow` (the default) goes back. agy's questions are a select.
 * - One tool, `antigravity` (lib/agy-delegate.ts): any pi model hands a self-contained task to a
 *   fresh agy session on a signed-in account and gets agy's final answer. Registered at
 *   session_start (never while loading: test/conflicts.test.ts), and only when agy is found, an
 *   account is signed in and no other extension has the name. No flags.
 */
import fs from "node:fs";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { findAgy, NOT_FOUND, SignInRequired, signalGroup, usableAgyPath } from "../../lib/acp.ts";
import { Type } from "typebox";
import { AgySession, agyLogout, agyVersion, probeModels } from "../../lib/agy.ts";
import { APPROVAL_MODES, type ApprovalMode, isApprovalMode, readonlySession } from "../../lib/agy-approvals.ts";
import { DELEGATE_DESCRIPTION, DELEGATE_TOOL, delegate } from "../../lib/agy-delegate.ts";
import { loadedTools } from "../../lib/claims.ts";
import {
	type Account,
	agyArgs,
	agyEnvFor,
	approvalsOf,
	dataRoot,
	defaultNameOf,
	explainError,
	hasSavedLogin,
	isMethod,
	loadAccounts,
	METHODS,
	type Method,
	methodLabel,
	noteAgySeen,
	cachedModels,
	noteModelList,
	noteModels,
	notSignedIn,
	prepareProfile,
	profileOf,
	providerIdOf,
	runDir,
	noteKeychainSignIn,
	signInHint,
	updateAccounts,
	signInCommand,
	storedAgyPath,
	usesKey,
	validName,
} from "../../lib/agy-accounts.ts";
import { agyLogin } from "../../lib/agy-login.ts";
import { createAntigravity, modelList, type Registry, SUMMARY_TEXT } from "../../lib/antigravity.ts";

/** What ends the agy processes when pi exits: one exit listener for the process, however often the extension loads. */
const KILLERS: Set<() => void> = ((globalThis as any)[Symbol.for("deckhand.antigravity.killers")] ??= (() => {
	const set = new Set<() => void>();
	process.once("exit", () => {
		for (const kill of set) kill();
	});
	return set;
})());

/**
 * The background model listing after pi starts (refreshModels): `off` turns it off (the tests'
 * helper, test/pi-rules.ts, does, so no test lists models unless it asks), `delayMs` is how long
 * after session_start it waits, `last` is the running one. One object for the process.
 */
const PROBE: { off?: boolean; delayMs: number; last?: Promise<void> } = ((globalThis as any)[Symbol.for("deckhand.antigravity.probe")] ??= { delayMs: 3000 });
/** A list this young (or a listing tried this recently, by any pi) is not asked for again at start. */
export const MODELS_FRESH_MS = 10 * 60_000;

const SUBCOMMANDS = ["status", "add", "login", "logout", "remove", "models", "approvals", "path"] as const;

export default function antigravity(pi: ExtensionAPI) {
	const root = dataRoot();
	let agyPath = findAgy(process.env, storedAgyPath(root)); // env-read-ok: PATH only (findAgy)
	let active = false;
	let cwd = process.cwd();
	let setStatus: ((text: string | undefined) => void) | undefined;
	let registry: Registry | undefined;
	/** The session's context (session_start): its UI answers agy's approvals in a tab. */
	let uiCtx: ExtensionContext | undefined;
	let version = "";
	const live = new Map<string, { account: Account; ag: ReturnType<typeof createAntigravity> }>();

	/** The accounts as accounts.json has them now (Deckhand may have changed it), `default` first. */
	const accountsNow = () => loadAccounts(root);
	const accountNow = (name: string) => accountsNow().find((a) => a.name === name);

	/**
	 * How agy runs for an account: its profile, environment and method. A sign-in (`login`) gets the
	 * same environment as the account's sessions, so it stores where they read: the keychain account
	 * in the keychain, every other one in its profile (lib/agy-accounts.ts agyEnvFor).
	 */
	const launchOf = (a: Account, key: string | undefined, login = false) => {
		const p = prepareProfile(root, a);
		// the process's own TMPDIR is made only when agy starts (and removed when it ends)
		return { args: agyArgs(p, login), env: agyEnvFor(a, p, key), makeRunDir: () => runDir(p), authMethod: a.method, signInHint: notSignedIn(a) };
	};
	/** agy authenticated the account: a file-mode account with no file of its own used the keychain, recorded (noteKeychainSignIn). */
	const authenticated = (name: string) => void noteKeychainSignIn(root, name).catch(() => {});

	const register = (a: Account) => {
		const ag = createAntigravity({
			agyPath: agyPath!,
			cwd: () => cwd,
			status: (t) => setStatus?.(t),
			providerId: providerIdOf(a.name),
			account: a.name,
			keyAuth: usesKey(a),
			explain: (m) => explainError(m, a),
			launch: (key) => launchOf(accountNow(a.name) ?? a, key),
			ledgerDir: path.join(profileOf(root, a).acpDir, "deckhand-sessions"),
			onModels: (n, list, thinking) => noteModels(root, a.name, list, thinking, n),
			initialModels: cachedModels(root, a.name),
			onOpened: () => authenticated(a.name),
			approvals: () => ({ cwd, hasUI: !!uiCtx?.hasUI, ui: uiCtx?.hasUI ? (uiCtx.ui as any) : undefined, readonly: readonlySession(), mode: approvalsOf(root, a.name) }),
		});
		ag.bind(registry);
		const old = live.get(a.name);
		live.set(a.name, { account: a, ag });
		if (old) void old.ag.closeAll();
		pi.registerProvider(ag.provider as any);
	};
	/**
	 * Registers the accounts' providers and the hooks, once agy is found: at load,
	 * or later in the session from /antigravity path (`ctx` then stands in for session_start).
	 */
	const activate = (ctx?: ExtensionContext) => {
		if (active || !agyPath) return;
		active = true;
		for (const a of loadAccounts(root)) register(a);
		// agy processes end with pi: with the session (below), and at exit
		const kill = () => {
			for (const { ag } of live.values()) ag.killAll();
			probeKill?.();
		};
		KILLERS.add(kill);

		pi.on("session_start", async (_e: unknown, ctx: ExtensionContext) => {
			cwd = ctx.cwd || cwd;
			uiCtx = ctx;
			registry = (ctx as any).modelRegistry;
			for (const { ag } of live.values()) ag.bind(registry);
			setStatus = ctx.hasUI ? (t) => ctx.ui.setStatus("antigravity", t) : undefined;
			await offerTool(ctx);
			scheduleRefresh(ctx);
		});

		pi.on("session_shutdown", async () => {
			clearTimeout(refreshTimer);
			stopped = true;
			probeKill?.();
			KILLERS.delete(kill);
			setStatus?.(undefined);
			await Promise.all([...live.values()].map(({ ag }) => ag.closeAll()));
		});

		// pi's compaction would ask agy for a summary of what agy already holds: pi keeps a note instead
		pi.on("session_before_compact", (event: any, ctx: ExtensionContext) => {
			const p = ctx.model?.provider;
			if (!p || ![...live.values()].some(({ ag }) => ag.provider.id === p) || !event?.preparation) return undefined;
			return { compaction: { summary: SUMMARY_TEXT, firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } };
		});

		if (ctx) {
			cwd = ctx.cwd || cwd;
			uiCtx = ctx;
			registry = (ctx as any).modelRegistry;
			for (const { ag } of live.values()) ag.bind(registry);
			setStatus = ctx.hasUI ? (t) => ctx.ui.setStatus("antigravity", t) : undefined;
			void offerTool(ctx);
			scheduleRefresh(ctx);
		}
	};

	/**
	 * Once after pi starts, in the background: each account whose cached list is older than
	 * MODELS_FRESH_MS (or that was never listed) is listed again, one at a time, and its provider
	 * gets the models if they changed. Never a sign-in: no link is taken (a link fails the listing)
	 * and a Google account gets SSH_CONNECTION, so agy says it has no sign-in instead of opening a
	 * browser. No sign-in keeps the cached models and marks the account (the status says to sign
	 * in); any other failure changes nothing. An API-key account without its key is left out.
	 */
	let refreshTimer: ReturnType<typeof setTimeout> | undefined;
	let refreshed = false;
	let stopped = false;
	let probeKill: (() => void) | undefined;
	const scheduleRefresh = (ctx: ExtensionContext) => {
		if (refreshed || PROBE.off) return;
		refreshed = true;
		refreshTimer = setTimeout(() => {
			PROBE.last = refreshModels(ctx).catch(() => {});
		}, PROBE.delayMs);
		refreshTimer.unref?.();
	};
	const refreshModels = async (ctx: ExtensionContext) => {
		for (const a of accountsNow()) {
			if (stopped || !agyPath) return;
			const ag = live.get(a.name)?.ag;
			if (!ag) continue;
			const c = cachedModels(root, a.name);
			if (c && Date.now() - Math.max(c.at, c.triedAt ?? 0) < MODELS_FRESH_MS) continue;
			const key = await keyOf(ctx, a);
			if (usesKey(a) && !key) continue;
			let how: ReturnType<typeof launchOf>;
			try {
				how = launchOf(a, key);
			} catch {
				continue; // a folder used in place that is gone
			}
			noteModelList(root, a.name, (x) => ({ ...x, triedAt: Date.now() }));
			const env = usesKey(a) ? how.env : { ...how.env, SSH_CONNECTION: how.env.SSH_CONNECTION || "127.0.0.1 0 127.0.0.1 0" };
			let s: AgySession | undefined;
			try {
				// its process group is ended with pi's (the exit listener below), even while it opens
				const spawnImpl = ((cmd: string, args: string[], opts: any) => {
					const child = spawn(cmd, args, opts);
					probeKill = () => signalGroup(child.pid, "SIGTERM");
					return child;
				}) as typeof spawn;
				s = await AgySession.open({ agyPath, cwd, ...how, env, spawnImpl });
				const r = { models: s.models, thinking: s.thinkingLevels, version: s.agentVersion };
				if (stopped) return;
				authenticated(a.name);
				version = r.version || version;
				// setModels tells onModels (noteModels: the list, its count, no longer signed out)
				await (live.get(a.name)?.ag ?? ag).setModels(r.models, r.thinking);
			} catch (e) {
				if (e instanceof SignInRequired) noteModelList(root, a.name, (x) => ({ ...x, signedOut: true }));
			} finally {
				await s?.close().catch(() => {});
				probeKill = undefined;
			}
		}
	};

	/**
	 * The accounts the tool may use now: every Google or Agent Platform account (whether agy has a
	 * sign-in is agy's to say: a stat cannot see the keychain), and an API-key account with its key.
	 */
	const signedIn = async (ctx: ExtensionContext) => {
		const out: Account[] = [];
		for (const a of accountsNow()) if (!usesKey(a) || !!(await keyOf(ctx, a))) out.push(a);
		return out;
	};

	/** Registers the `antigravity` tool once: agy found, an account signed in, the name free. */
	let toolOn = false;
	const offerTool = async (ctx: ExtensionContext) => {
		if (toolOn || !agyPath || loadedTools(pi as any, [DELEGATE_TOOL]).size) return;
		const accounts = await signedIn(ctx);
		if (!accounts.length || toolOn) return;
		toolOn = true;
		pi.registerTool({
			name: DELEGATE_TOOL,
			label: "Antigravity",
			description: DELEGATE_DESCRIPTION,
			promptSnippet: "Hand a self-contained task to Google Antigravity and get its answer",
			parameters: Type.Object({
				task: Type.String({ description: "The whole task: Antigravity sees nothing of this conversation" }),
				account: Type.Optional(Type.String({ description: `An Antigravity account (default: "${defaultNameOf(root)}", or the first signed in). Signed in when this tab started: ${accounts.map((a) => a.name).join(", ")}` })),
				model: Type.Optional(Type.String({ description: "An Antigravity model id (as in /model, without the provider); its default if omitted" })),
			}),
			async execute(_id: string, p: { task: string; account?: string; model?: string }, signal: AbortSignal | undefined, onUpdate: any, c: ExtensionContext) {
				const now = await signedIn(c);
				const def = defaultNameOf(root);
				const a = p.account ? now.find((x) => x.name === p.account) : (now.find((x) => x.name === def) ?? now[0]);
				if (!a) throw new Error(p.account ? `No signed-in Antigravity account "${p.account}": signed in are ${now.map((x) => x.name).join(", ") || "none"}` : "No Antigravity account is signed in: /antigravity login");
				const key = await keyOf(c, a);
				const text = await delegate({
					task: p.task,
					model: p.model,
					signal,
					progress: (t) => onUpdate?.({ content: [{ type: "text", text: t }], details: undefined }),
					approvals: () => ({ cwd: c.cwd || cwd, hasUI: !!c.hasUI, ui: c.hasUI ? (c.ui as any) : undefined, readonly: readonlySession(), mode: approvalsOf(root, a.name) }),
					open: async (onU, answer) => {
						const s = await AgySession.open({ agyPath: agyPath!, cwd: c.cwd || cwd, ...launchOf(a, key), onUpdate: onU, answer });
						authenticated(a.name);
						return s;
					},
				});
				return { content: [{ type: "text" as const, text }], details: undefined };
			},
		} as any);
	};

	/** pi's stored key for an API-key account (pi's credential store), else undefined. */
	const keyOf = async (ctx: ExtensionContext, a: Account): Promise<string | undefined> => {
		if (!usesKey(a)) return undefined;
		try {
			const r = await (ctx as any).modelRegistry?.getProviderAuth?.(providerIdOf(a.name));
			return typeof r?.auth?.apiKey === "string" && r.auth.apiKey ? r.auth.apiKey : undefined;
		} catch {
			return undefined;
		}
	};

	/** The account named, or with no name the default one (accounts.json's defaultAccount), as accounts.json has it now. */
	const accountOf = (name: string | undefined) => {
		const list = accountsNow();
		const n = name || defaultNameOf(root, list);
		return list.find((a) => a.name === n);
	};
	const fail = (ctx: ExtensionContext, m: string) => ctx.ui.notify(m, "error");

	/** A throwaway session's models into the account's provider; the line to show. Throws agy's error, explained. */
	const listModels = async (ctx: ExtensionContext, a: Account, signIn?: { showLink: (url: string) => void; timeoutMs: number }) => {
		const key = await keyOf(ctx, a);
		if (usesKey(a) && !key) throw new Error(notSignedIn(a));
		try {
			const r = await probeModels({ agyPath, cwd, ...launchOf(a, key), ...(signIn ? { signIn } : {}) });
			authenticated(a.name);
			version = r.version || version;
			noteAgySeen(root, agyPath!, version);
			noteModels(root, a.name, r.models, r.thinking, modelList(r.models, r.thinking).length - 1);
			const ag = live.get(a.name)?.ag;
			if (ag) await ag.setModels(r.models, r.thinking);
			return `${r.models.length} model${r.models.length === 1 ? "" : "s"} of the Antigravity account "${a.name}" ${ag ? "in /model" : "in /model after pi's next start or /reload"} (provider ${providerIdOf(a.name)})`;
		} catch (e) {
			throw new Error(explainError((e as Error).message, a));
		}
	};

	/** One line per account: provider, method, signed in or what to run, models. */
	const statusLines = async (ctx: ExtensionContext) => {
		if (!version) {
			version = await (async () => agyVersion({ agyPath, cwd, ...launchOf(accountOf("default")!, undefined) }))().catch(() => "");
			noteAgySeen(root, agyPath!, version);
		}
		const set = storedAgyPath(root);
		const lines = [`Antigravity CLI: ${agyPath} (${version || "version unknown"})${set === agyPath ? ", set by /antigravity path" : ""}`];
		if (set && set !== agyPath) lines.push(`  The path set by /antigravity path is not an executable file, so agy is taken from PATH: ${set}`);
		lines.push(`Accounts (${root}):`);
		const list = accountsNow();
		const def = defaultNameOf(root, list);
		for (const a of list) {
			const ag = live.get(a.name)?.ag;
			let state: string;
			if (usesKey(a)) state = (await keyOf(ctx, a)) ? "API key saved in pi" : `no API key: run ${signInCommand(a)}`;
			else if (a.method === "agent-platform") state = `Application Default Credentials (${a.gcpProject}, ${a.gcpLocation})`;
			else {
				// a hint only: agy is asked whenever the account is used, and says when it has no sign-in
				const hint = signInHint(root, a);
				state = cachedModels(root, a.name)?.signedOut ? `sign in: ${signInCommand(a)}` : hint === "file" ? "signed in (in its profile)" : hint === "keychain" ? "signed in (system keychain, not checked)" : `sign-in unknown until agy is used (${signInCommand(a)} to sign in)`;
			}
			const n = (ag?.models.length ?? 1) - 1;
			const label = a.label && a.label !== a.name ? ` (${a.label})` : "";
			const where = a.dir ? ` · folder ${a.dir}` : "";
			const models = !ag ? "provider after pi's next start or /reload" : n > 0 ? `${n} models` : "models not listed yet";
			lines.push(`- ${a.name}${label} → ${providerIdOf(a.name)} · ${methodLabel(a.method)}${a.method === "oauth-business" ? ` (${a.gcpProject}, ${a.gcpLocation})` : ""}${where} · ${state} · ${models}${list.length > 1 && a.name === def ? " · the default account" : ""}`);
		}
		return lines.join("\n");
	};

	const status = async (ctx: ExtensionContext) => ctx.ui.notify(await statusLines(ctx), "info");

	const login = async (ctx: ExtensionContext, name?: string) => {
		const a = accountOf(name);
		if (!a) return fail(ctx, `No Antigravity account "${name}": /antigravity add ${name}`);
		if (usesKey(a)) return ctx.ui.notify(`Run /login ${providerIdOf(a.name)}: pi asks for the ${methodLabel(a.method)} (hidden as you type) and keeps it in its credential store. Then /antigravity models ${a.name}.`, "info");
		if (a.method === "agent-platform") {
			try {
				return ctx.ui.notify(await listModels(ctx, a), "info");
			} catch (e) {
				return fail(ctx, (e as Error).message);
			}
		}
		if (!ctx.hasUI) return ctx.ui.notify(`Signing in needs the interactive pi: run ${signInCommand(a)} in a pi tab`, "warning");
		const show = (url: string) => ctx.ui.notify(`Open this link and sign in with Google${a.name === "default" ? "" : ` (account "${a.name}")`}:\n${url}`, "info");
		if (a.method === "oauth-business") {
			// agy's own browser sign-in, which returns to agy on this Mac (t3code: ACP authenticate)
			try {
				const line = await listModels(ctx, a, { showLink: show, timeoutMs: 5 * 60_000 });
				ctx.ui.notify(`Signed in to Antigravity (account "${a.name}")`, "info");
				return ctx.ui.notify(line, "info");
			} catch (e) {
				return fail(ctx, (e as Error).message);
			}
		}
		let how: ReturnType<typeof launchOf>;
		try {
			how = launchOf(a, undefined, true);
		} catch (e) {
			return fail(ctx, (e as Error).message); // a folder used in place that is gone
		}
		const r = await agyLogin({
			agyPath,
			cwd,
			args: how.args,
			env: how.env,
			makeRunDir: how.makeRunDir,
			showLink: (url) => show(`${url}\nThen paste the code the Antigravity page shows.`),
			askCode: () => ctx.ui.input("Antigravity sign-in code", "paste the code from the page"),
		});
		if (!r.ok) return ctx.ui.notify(r.error, r.error === "Sign-in cancelled" ? "info" : "error");
		ctx.ui.notify(`Signed in to Antigravity (account "${a.name}")`, "info");
		// stored where its sessions read: the keychain account in the keychain, any other in its profile (launchOf)
		await offerTool(ctx);
		try {
			ctx.ui.notify(await listModels(ctx, accountNow(a.name) ?? a), "info");
		} catch (e) {
			ctx.ui.notify(`Signed in, but the models could not be listed: ${(e as Error).message}`, "warning");
		}
	};

	const logout = async (ctx: ExtensionContext, name?: string, yes = false) => {
		const a = accountOf(name);
		if (!a) return fail(ctx, `No Antigravity account "${name}"`);
		// the keychain account's sign-out clears the one keychain entry, which every Google account
		// without a sign-in of its own also signs in with: named first, confirmed (or --yes)
		const shared = a.keyring ? keychainUsers(a) : [];
		if (shared.length && !yes) {
			const line = sharedSignOutText(a, shared);
			if (!ctx.hasUI) return ctx.ui.notify(`${line} To sign them all out, run /antigravity logout ${a.name} --yes`, "warning");
			if (!(await ctx.ui.confirm(`Sign out of Antigravity?`, line))) return;
		}
		await live.get(a.name)?.ag.closeAll();
		for (const x of shared) await live.get(x.name)?.ag.closeAll();
		if (usesKey(a)) return ctx.ui.notify(`Run /logout and pick ${providerIdOf(a.name)}: pi removes the stored key. The account and its history stay.`, "info");
		if (!usesKeyOrBrowser(a)) return ctx.ui.notify(`The account "${a.name}" uses Application Default Credentials: nothing is saved to sign out of (gcloud auth application-default revoke)`, "info");
		try {
			await agyLogout({ agyPath, cwd, ...launchOf(a, undefined) });
			ctx.ui.notify(`Signed out of Antigravity (account "${a.name}"${shared.length ? ` and ${listNames(shared)}, which shared it` : ""}${a.keyring ? ", its sign-in in the system keychain, which agy outside Deckhand uses too" : ""}); its history is kept`, "info");
		} catch (e) {
			fail(ctx, explainError((e as Error).message, a));
		}
	};
	/** The other Google accounts with no sign-in of their own, so signed in from the keychain account's (agy reads its file, else the keychain). */
	const keychainUsers = (k: Account) => accountsNow().filter((x) => x.name !== k.name && x.method === "oauth-personal" && !x.keyring && !hasSavedLogin(profileOf(root, x)));
	const listNames = (l: Account[]) => (l.length === 1 ? l[0].name : `${l.slice(0, -1).map((x) => x.name).join(", ")} and ${l.at(-1)!.name}`);
	const sharedSignOutText = (k: Account, l: Account[]) =>
		`This signs out ${listNames([k, ...l])} (they share the macOS keychain sign-in). Use /antigravity login ${l[0].name} to give ${l.length === 1 ? l[0].name : "an account"} its own.`;
	const usesKeyOrBrowser = (a: Account) => usesKey(a) || a.method === "oauth-personal" || a.method === "oauth-business";

	const remove = async (ctx: ExtensionContext, name?: string, yes = false) => {
		const a = name ? accountOf(name) : undefined;
		if (!name || !a) return fail(ctx, `No Antigravity account "${name ?? ""}": /antigravity remove <name>`);
		if (a.name === "default") return fail(ctx, `The default account stays: /antigravity logout signs it out, /antigravity add default changes its sign-in method`);
		const p = profileOf(root, a);
		// a folder used in place is the user's own: only the entry goes (no sign-out, nothing deleted)
		const what = p.inPlace ? `its folder ${p.geminiHome} stays as it is, with its sign-in` : `its profile with its saved sign-in and history (${p.geminiHome})`;
		if (!ctx.hasUI && !yes) return ctx.ui.notify(p.inPlace ? `Removing the Antigravity account "${a.name}" removes it from Deckhand (its folder ${p.geminiHome} stays): run /antigravity remove ${a.name} --yes` : `Removing the Antigravity account "${a.name}" deletes its profile and history: run /antigravity remove ${a.name} --yes`, "warning");
		if (ctx.hasUI && !yes && !(await ctx.ui.confirm(`Remove the Antigravity account "${a.name}"?`, `Its provider ${providerIdOf(a.name)} goes, and ${what}.`))) return;
		try {
			await updateAccounts(root, (accounts, rest) => ({
				accounts: accounts.filter((x) => x.name !== a.name),
				...(rest.defaultAccount === a.name ? { defaultAccount: null } : {}),
				...(a.source === "found" && a.dir && !rest.removedDirs.includes(a.dir) ? { removedDirs: [...rest.removedDirs, a.dir] } : {}),
			}));
		} catch (e) {
			return fail(ctx, (e as Error).message);
		}
		await live.get(a.name)?.ag.closeAll();
		if (!p.inPlace) {
			if (!usesKey(a) && hasSavedLogin(p)) await agyLogout({ agyPath, cwd, ...launchOf(a, undefined) }).catch(() => {});
			fs.rmSync(p.geminiHome, { recursive: true, force: true });
		}
		if (live.delete(a.name)) pi.unregisterProvider(providerIdOf(a.name));
		ctx.ui.notify(`Removed the Antigravity account "${a.name}"${p.inPlace ? `; its folder ${p.geminiHome} is kept` : ""}${usesKey(a) ? `; its key is still in pi's store: /logout and pick ${providerIdOf(a.name)}` : ""}`, "info");
	};

	const add = async (ctx: ExtensionContext, name?: string, methodArg?: string) => {
		if (!name && ctx.hasUI) name = (await ctx.ui.input("New Antigravity account: a short name (work, personal…)", "work"))?.trim();
		if (!name) return fail(ctx, "Name the account: /antigravity add <name> [oauth-personal|oauth-business|gemini-api-key|agent-platform]");
		if (!validName(name)) return fail(ctx, `"${name}" cannot name an account: lower-case letters, digits and -, up to 32`);
		const existing = accountNow(name);
		if (name !== "default" && (existing || live.has(name))) return fail(ctx, `The account "${name}" exists: /antigravity remove ${name} first`);
		let method: Method | undefined = isMethod(methodArg) ? methodArg : undefined;
		if (methodArg && !method) return fail(ctx, `Unknown sign-in method "${methodArg}": ${METHODS.map((m) => m.id).join(", ")}`);
		if (!method && ctx.hasUI) {
			const pick = await ctx.ui.select(`Sign-in method for "${name}"`, METHODS.map((m) => m.label));
			method = METHODS.find((m) => m.label === pick)?.id;
		}
		method ??= "oauth-personal";
		// `default` again: its method changes; its folder, label and the rest stay
		const { gcpProject: _p, gcpLocation: _l, keyring: _k, ...kept } = existing ?? ({} as Partial<Account>);
		const a: Account = { ...kept, name, method };
		if (method === "oauth-business" || method === "agent-platform") {
			const optional = method === "agent-platform" ? " (empty: use an API key)" : "";
			const project = ctx.hasUI ? (await ctx.ui.input(`GCP project${optional}`, ""))?.trim() : undefined;
			const location = project && ctx.hasUI ? (await ctx.ui.input("GCP location", "global"))?.trim() : undefined;
			if (method === "oauth-business" && !(project && location)) return fail(ctx, "Gemini Enterprise needs a GCP project and location");
			if (project && location) Object.assign(a, { gcpProject: project, gcpLocation: location });
		}
		try {
			await updateAccounts(root, (accounts) => ({ accounts: accounts.some((x) => x.name === a.name) ? accounts.map((x) => (x.name === a.name ? a : x)) : [...accounts, a] }));
		} catch (e) {
			return fail(ctx, (e as Error).message);
		}
		register(accountNow(a.name) ?? a);
		ctx.ui.notify(`Added the Antigravity account "${a.name}" (${methodLabel(a.method)}): its models will be under provider ${providerIdOf(a.name)}. Next: ${signInCommand(a)}`, "info");
		// a name removed and added again: pi's store may still hold the old account's key
		if (usesKey(a) && (await keyOf(ctx, a)))
			ctx.ui.notify(`pi still has an API key for ${providerIdOf(a.name)} (from before): it will be used. To enter another, /logout and pick ${providerIdOf(a.name)}, then /login ${providerIdOf(a.name)}`, "warning");
	};

	const models = async (ctx: ExtensionContext, name?: string) => {
		const a = accountOf(name);
		if (!a) return fail(ctx, `No Antigravity account "${name}"`);
		try {
			ctx.ui.notify(await listModels(ctx, a), "info");
		} catch (e) {
			fail(ctx, (e as Error).message);
		}
	};

	/** Sets agy's path (absolute, executable), or clears it (PATH's agy again); every account's provider follows. */
	const setPath = async (ctx: ExtensionContext, given: string) => {
		const p = given.trim();
		if (p && !usableAgyPath(p)) return fail(ctx, `Not an absolute path to an executable file: ${p}`);
		if (!active) {
			if (!p) return ctx.ui.notify(NOT_FOUND, "warning");
			await updateAccounts(root, () => ({ agyPath: p }));
			agyPath = p;
			activate(ctx);
			return ctx.ui.notify(`Antigravity now runs ${p}: its models are in /model; /antigravity shows the accounts and signs them in`, "info");
		}
		const next = p || findAgy(process.env); // env-read-ok: PATH only (findAgy)
		await updateAccounts(root, () => ({ agyPath: p || null }));
		if (!next) return ctx.ui.notify("Cleared agy's path. There is no agy on your PATH, so Antigravity is off from pi's next start (/antigravity path sets it again)", "warning");
		await Promise.all([...live.values()].map(({ ag }) => ag.closeAll()));
		agyPath = next;
		version = "";
		for (const { account } of [...live.values()]) register(accountNow(account.name) ?? account);
		ctx.ui.notify(p ? `Antigravity now runs ${p}` : `Cleared agy's path: Antigravity runs ${next} from your PATH`, "info");
	};

	/** `/antigravity approvals [allow|ask] [name]`: shows each account's mode, or sets one (accounts.json; the next request reads it). */
	const approvals = async (ctx: ExtensionContext, x?: string, y?: string) => {
		const mode: ApprovalMode | undefined = isApprovalMode(x) ? x : undefined;
		const name = mode ? y : x;
		if (!mode && x && !live.has(x)) return fail(ctx, `/antigravity approvals ${APPROVAL_MODES.join("|")} [account]: "${x}" is neither a mode nor an account`);
		if (!mode) {
			const lines = [...live.values()].filter(({ account }) => !name || account.name === name).map(({ account }) => `- ${account.name}: ${approvalsOf(root, account.name)}`);
			return ctx.ui.notify(
				`Antigravity approvals (allow: agy's actions run unless your guardrails rules, a read-only session or a credential file say otherwise; ask: every action is confirmed first):\n${lines.join("\n")}\nSet with /antigravity approvals ${APPROVAL_MODES.join("|")} [account]`,
				"info",
			);
		}
		const a = accountOf(name);
		if (!a) return fail(ctx, `No Antigravity account "${name}"`);
		try {
			await updateAccounts(root, (accounts) => {
				const next: Account = { ...(accounts.find((x) => x.name === a.name) ?? a), approvals: mode === "ask" ? "ask" : undefined };
				return { accounts: accounts.some((x) => x.name === a.name) ? accounts.map((x) => (x.name === a.name ? next : x)) : [...accounts, next] };
			});
		} catch (e) {
			return fail(ctx, (e as Error).message);
		}
		live.get(a.name)!.account.approvals = mode === "ask" ? "ask" : undefined;
		ctx.ui.notify(
			mode === "ask"
				? `Antigravity (account "${a.name}"): every action agy asks to take is confirmed first; without a UI it is refused`
				: `Antigravity (account "${a.name}"): agy's actions run unless your guardrails rules, a read-only session or a credential file say otherwise`,
			"info",
		);
	};

	const menu = async (ctx: ExtensionContext) => {
		const actions = ["Add an account…", "Sign in…", "Sign out…", "Remove an account…", "List models again…", "Set agy's path…", "Close"];
		const pick = await ctx.ui.select("Antigravity", actions);
		if (!pick || pick === "Close") return;
		if (pick === actions[0]) return add(ctx);
		if (pick === actions[5]) {
			const p = await ctx.ui.input("agy's full path (empty: the agy on your PATH)", agyPath ?? "");
			return p === undefined ? undefined : setPath(ctx, p);
		}
		const names = accountsNow().map((a) => a.name).filter((n) => pick !== actions[3] || n !== "default");
		if (!names.length) return;
		const name = names.length === 1 ? names[0] : await ctx.ui.select("Which account?", names);
		if (!name) return;
		if (pick === actions[1]) return login(ctx, name);
		if (pick === actions[2]) return logout(ctx, name);
		if (pick === actions[3]) return remove(ctx, name);
		return models(ctx, name);
	};

	pi.registerCommand("antigravity", {
		description: "Google Antigravity: status and accounts (add, login, logout, remove, models, approvals), agy's path",
		getArgumentCompletions: (prefix: string) => SUBCOMMANDS.filter((s) => s.startsWith(prefix)).map((s) => ({ value: s, label: s })),
		handler: async (args: string, ctx: ExtensionContext) => {
			const [sub, name, method] = (args ?? "").trim().split(/\s+/).filter(Boolean);
			if (!active && sub !== "path") {
				ctx.ui.notify(NOT_FOUND, "warning");
				if (sub !== undefined || !ctx.hasUI) return;
				if ((await ctx.ui.select("Antigravity", ["Set agy's path…", "Close"])) !== "Set agy's path…") return;
				const p = await ctx.ui.input("agy's full path", "/usr/local/bin/agy");
				return p?.trim() ? setPath(ctx, p) : undefined;
			}
			switch (sub) {
				case "path":
					return setPath(ctx, (args ?? "").trim().slice("path".length));
				case undefined:
					await status(ctx);
					if (ctx.hasUI) await menu(ctx);
					return;
				case "status":
					return status(ctx);
				case "add":
					return add(ctx, name, method);
				case "login":
					return login(ctx, name);
				case "logout":
					return name === "--yes" ? logout(ctx, undefined, true) : logout(ctx, name, method === "--yes");
				case "remove":
					return remove(ctx, name, method === "--yes");
				case "models":
					return models(ctx, name);
				case "approvals":
					return approvals(ctx, name, method);
				default:
					return fail(ctx, `Unknown: /antigravity ${sub}. Try /antigravity ${SUBCOMMANDS.join("|")} [name]`);
			}
		},
	} as any);

	activate();
}
