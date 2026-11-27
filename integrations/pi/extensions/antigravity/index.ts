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
 * - `/antigravity`: the status (agy and its version, each account, its method, whether it is signed
 *   in, its models) and a menu; `/antigravity add|login|logout|remove|models [name]` directly;
 *   `/antigravity path [/abs/agy]` sets (or clears) agy's path.
 *   `/antigravity-login`: the default account's sign-in.
 * - Honest: Deckhand's own client name (deckhand-pi), no spoofed headers; agy keeps its sign-in,
 *   Deckhand never reads it and never calls Google. An API key lives in pi's credential store
 *   (`/login antigravity-<name>`) and reaches agy only in its environment.
 * - Approvals: none yet. agy runs in its `default` mode, every permission request is rejected and
 *   every question declined (lib/acp.ts).
 * - No tools or flags are registered (test/conflicts.test.ts).
 */
import fs from "node:fs";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { findAgy, usableAgyPath } from "../../lib/acp.ts";
import { agyLogout, agyVersion, probeModels } from "../../lib/agy.ts";
import {
	type Account,
	agyArgs,
	agyEnvFor,
	dataRoot,
	explainError,
	hasSavedLogin,
	isMethod,
	loadAccounts,
	METHODS,
	type Method,
	methodLabel,
	notSignedIn,
	prepareProfile,
	profileOf,
	providerIdOf,
	runDir,
	updateAccounts,
	signInCommand,
	storedAccounts,
	storedAgyPath,
	usesKey,
	validName,
} from "../../lib/agy-accounts.ts";
import { agyLogin } from "../../lib/agy-login.ts";
import { createAntigravity, type Registry, SUMMARY_TEXT } from "../../lib/antigravity.ts";

/** What ends the agy processes when pi exits: one exit listener for the process, however often the extension loads. */
const KILLERS: Set<() => void> = ((globalThis as any)[Symbol.for("deckhand.antigravity.killers")] ??= (() => {
	const set = new Set<() => void>();
	process.once("exit", () => {
		for (const kill of set) kill();
	});
	return set;
})());

const SUBCOMMANDS = ["status", "add", "login", "logout", "remove", "models", "path"] as const;
export const NOT_FOUND =
	"Antigravity CLI (agy) not found. Install it from https://antigravity.google/docs/getting-started (1.5.12 or newer), or set its path with /antigravity path <abs path>";

export default function antigravity(pi: ExtensionAPI) {
	const root = dataRoot();
	let agyPath = findAgy(process.env, storedAgyPath(root));
	let active = false;
	let cwd = process.cwd();
	let setStatus: ((text: string | undefined) => void) | undefined;
	let registry: Registry | undefined;
	let version = "";
	const live = new Map<string, { account: Account; ag: ReturnType<typeof createAntigravity> }>();

	/** How agy runs for an account: its profile, environment and method. */
	const launchOf = (a: Account, key: string | undefined, login = false) => {
		const p = prepareProfile(root, a);
		const run = runDir(p); // this process's own TMPDIR, removed when it ends
		return { args: agyArgs(p, login), env: agyEnvFor(a, p, key, process.env, run), runDir: run, authMethod: a.method, signInHint: notSignedIn(a) };
	};

	const register = (a: Account) => {
		const ag = createAntigravity({
			agyPath: agyPath!,
			cwd: () => cwd,
			status: (t) => setStatus?.(t),
			providerId: providerIdOf(a.name),
			account: a.name,
			keyAuth: usesKey(a),
			explain: (m) => explainError(m, a),
			launch: (key) => launchOf(a, key),
			ledgerDir: path.join(profileOf(root, a.name).acpDir, "deckhand-sessions"),
		});
		ag.bind(registry);
		const old = live.get(a.name);
		live.set(a.name, { account: a, ag });
		if (old) void old.ag.closeAll();
		pi.registerProvider(ag.provider as any);
	};
	/**
	 * Registers the accounts' providers, the hooks and /antigravity-login, once agy is found: at load,
	 * or later in the session from /antigravity path (`ctx` then stands in for session_start).
	 */
	const activate = (ctx?: ExtensionContext) => {
		if (active || !agyPath) return;
		active = true;
		for (const a of loadAccounts(root)) register(a);
		// agy processes end with pi: with the session (below), and at exit
		const kill = () => {
			for (const { ag } of live.values()) ag.killAll();
		};
		KILLERS.add(kill);

		pi.on("session_start", (_e: unknown, ctx: ExtensionContext) => {
			cwd = ctx.cwd || cwd;
			registry = (ctx as any).modelRegistry;
			for (const { ag } of live.values()) ag.bind(registry);
			setStatus = ctx.hasUI ? (t) => ctx.ui.setStatus("antigravity", t) : undefined;
		});

		pi.on("session_shutdown", async () => {
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

		pi.registerCommand("antigravity-login", {
			description: "Sign in to Google Antigravity (the default account; /antigravity for the others)",
			handler: async (_args: string, c: ExtensionContext) => login(c, "default"),
		});
		if (ctx) {
			cwd = ctx.cwd || cwd;
			registry = (ctx as any).modelRegistry;
			for (const { ag } of live.values()) ag.bind(registry);
			setStatus = ctx.hasUI ? (t) => ctx.ui.setStatus("antigravity", t) : undefined;
		}
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

	const accountOf = (name: string | undefined) => live.get(name || "default")?.account;
	const fail = (ctx: ExtensionContext, m: string) => ctx.ui.notify(m, "error");

	/** A throwaway session's models into the account's provider; the line to show. Throws agy's error, explained. */
	const listModels = async (ctx: ExtensionContext, a: Account, signIn?: { showLink: (url: string) => void; timeoutMs: number }) => {
		const key = await keyOf(ctx, a);
		if (usesKey(a) && !key) throw new Error(notSignedIn(a));
		try {
			const r = await probeModels({ agyPath, cwd, ...launchOf(a, key), ...(signIn ? { signIn } : {}) });
			version = r.version || version;
			await live.get(a.name)!.ag.setModels(r.models, r.thinking);
			return `${r.models.length} model${r.models.length === 1 ? "" : "s"} of the Antigravity account "${a.name}" in /model (provider ${providerIdOf(a.name)})`;
		} catch (e) {
			throw new Error(explainError((e as Error).message, a));
		}
	};

	/** One line per account: provider, method, signed in or what to run, models. */
	const statusLines = async (ctx: ExtensionContext) => {
		if (!version) version = await agyVersion({ agyPath, cwd, ...launchOf(accountOf("default")!, undefined) }).catch(() => "");
		const set = storedAgyPath(root);
		const lines = [`Antigravity CLI: ${agyPath} (${version || "version unknown"})${set === agyPath ? ", set by /antigravity path" : ""}`];
		if (set && set !== agyPath) lines.push(`  The path set by /antigravity path is not an executable file, so agy is taken from PATH: ${set}`);
		lines.push(`Accounts (${root}):`);
		for (const { account: a, ag } of live.values()) {
			let state: string;
			if (usesKey(a)) state = (await keyOf(ctx, a)) ? "API key saved in pi" : `no API key: run ${signInCommand(a)}`;
			else if (a.method === "agent-platform") state = `Application Default Credentials (${a.gcpProject}, ${a.gcpLocation})`;
			else state = hasSavedLogin(profileOf(root, a.name)) ? "signed in" : `not signed in: run ${signInCommand(a)}`;
			const n = ag.models.length - 1;
			lines.push(`- ${a.name} → ${providerIdOf(a.name)} · ${methodLabel(a.method)}${a.method === "oauth-business" ? ` (${a.gcpProject}, ${a.gcpLocation})` : ""} · ${state} · ${n > 0 ? `${n} models` : "models not listed yet"}`);
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
		const how = launchOf(a, undefined, true);
		const r = await agyLogin({
			agyPath,
			cwd,
			args: how.args,
			env: how.env,
			runDir: how.runDir,
			showLink: (url) => show(`${url}\nThen paste the code the Antigravity page shows.`),
			askCode: () => ctx.ui.input("Antigravity sign-in code", "paste the code from the page"),
		});
		if (!r.ok) return ctx.ui.notify(r.error, r.error === "Sign-in cancelled" ? "info" : "error");
		ctx.ui.notify(`Signed in to Antigravity (account "${a.name}")`, "info");
		try {
			ctx.ui.notify(await listModels(ctx, a), "info");
		} catch (e) {
			ctx.ui.notify(`Signed in, but the models could not be listed: ${(e as Error).message}`, "warning");
		}
	};

	const logout = async (ctx: ExtensionContext, name?: string) => {
		const a = accountOf(name);
		if (!a) return fail(ctx, `No Antigravity account "${name}"`);
		await live.get(a.name)!.ag.closeAll();
		if (usesKey(a)) return ctx.ui.notify(`Run /logout and pick ${providerIdOf(a.name)}: pi removes the stored key. The account and its history stay.`, "info");
		if (!usesKeyOrBrowser(a)) return ctx.ui.notify(`The account "${a.name}" uses Application Default Credentials: nothing is saved to sign out of (gcloud auth application-default revoke)`, "info");
		try {
			await agyLogout({ agyPath, cwd, ...launchOf(a, undefined) });
			ctx.ui.notify(`Signed out of Antigravity (account "${a.name}"); its history is kept`, "info");
		} catch (e) {
			fail(ctx, explainError((e as Error).message, a));
		}
	};
	const usesKeyOrBrowser = (a: Account) => usesKey(a) || a.method === "oauth-personal" || a.method === "oauth-business";

	const remove = async (ctx: ExtensionContext, name?: string, yes = false) => {
		const a = accountOf(name);
		if (!name || !a) return fail(ctx, `No Antigravity account "${name ?? ""}": /antigravity remove <name>`);
		if (a.name === "default") return fail(ctx, `The default account stays: /antigravity logout signs it out, /antigravity add default changes its sign-in method`);
		const p = profileOf(root, a.name);
		if (!ctx.hasUI && !yes) return ctx.ui.notify(`Removing the Antigravity account "${a.name}" deletes its profile and history: run /antigravity remove ${a.name} --yes`, "warning");
		if (ctx.hasUI && !yes && !(await ctx.ui.confirm(`Remove the Antigravity account "${a.name}"?`, `Its provider ${providerIdOf(a.name)} goes, and its profile with its saved sign-in and history (${p.geminiHome}).`))) return;
		await live.get(a.name)!.ag.closeAll();
		if (!usesKey(a) && hasSavedLogin(p)) await agyLogout({ agyPath, cwd, ...launchOf(a, undefined) }).catch(() => {});
		fs.rmSync(p.geminiHome, { recursive: true, force: true });
		await updateAccounts(root, (accounts) => ({ accounts: accounts.filter((x) => x.name !== a.name) }));
		live.delete(a.name);
		pi.unregisterProvider(providerIdOf(a.name));
		ctx.ui.notify(`Removed the Antigravity account "${a.name}"${usesKey(a) ? `; its key is still in pi's store: /logout and pick ${providerIdOf(a.name)}` : ""}`, "info");
	};

	const add = async (ctx: ExtensionContext, name?: string, methodArg?: string) => {
		if (!name && ctx.hasUI) name = (await ctx.ui.input("New Antigravity account: a short name (work, personal…)", "work"))?.trim();
		if (!name) return fail(ctx, "Name the account: /antigravity add <name> [oauth-personal|oauth-business|gemini-api-key|agent-platform]");
		if (!validName(name)) return fail(ctx, `"${name}" cannot name an account: lower-case letters, digits and -, up to 32`);
		if (name !== "default" && live.has(name)) return fail(ctx, `The account "${name}" exists: /antigravity remove ${name} first`);
		let method: Method | undefined = isMethod(methodArg) ? methodArg : undefined;
		if (methodArg && !method) return fail(ctx, `Unknown sign-in method "${methodArg}": ${METHODS.map((m) => m.id).join(", ")}`);
		if (!method && ctx.hasUI) {
			const pick = await ctx.ui.select(`Sign-in method for "${name}"`, METHODS.map((m) => m.label));
			method = METHODS.find((m) => m.label === pick)?.id;
		}
		method ??= "oauth-personal";
		const a: Account = { name, method };
		if (method === "oauth-business" || method === "agent-platform") {
			const optional = method === "agent-platform" ? " (empty: use an API key)" : "";
			const project = ctx.hasUI ? (await ctx.ui.input(`GCP project${optional}`, ""))?.trim() : undefined;
			const location = project && ctx.hasUI ? (await ctx.ui.input("GCP location", "global"))?.trim() : undefined;
			if (method === "oauth-business" && !(project && location)) return fail(ctx, "Gemini Enterprise needs a GCP project and location");
			if (project && location) Object.assign(a, { gcpProject: project, gcpLocation: location });
		}
		try {
			await updateAccounts(root, (accounts) => ({ accounts: [...accounts.filter((x) => x.name !== a.name), a] }));
		} catch (e) {
			return fail(ctx, (e as Error).message);
		}
		register(a);
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
		const next = p || findAgy(process.env);
		await updateAccounts(root, () => ({ agyPath: p || null }));
		if (!next) return ctx.ui.notify("Cleared agy's path. There is no agy or antigravity on your PATH, so Antigravity is off from pi's next start", "warning");
		await Promise.all([...live.values()].map(({ ag }) => ag.closeAll()));
		agyPath = next;
		version = "";
		for (const { account } of [...live.values()]) register(account);
		ctx.ui.notify(p ? `Antigravity now runs ${p}` : `Cleared agy's path: Antigravity runs ${next} from your PATH`, "info");
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
		const names = [...live.keys()].filter((n) => pick !== actions[3] || n !== "default");
		if (!names.length) return;
		const name = names.length === 1 ? names[0] : await ctx.ui.select("Which account?", names);
		if (!name) return;
		if (pick === actions[1]) return login(ctx, name);
		if (pick === actions[2]) return logout(ctx, name);
		if (pick === actions[3]) return remove(ctx, name);
		return models(ctx, name);
	};

	pi.registerCommand("antigravity", {
		description: "Google Antigravity: status and accounts (add, login, logout, remove, models), agy's path",
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
					return logout(ctx, name);
				case "remove":
					return remove(ctx, name, method === "--yes");
				case "models":
					return models(ctx, name);
				default:
					return fail(ctx, `Unknown: /antigravity ${sub}. Try /antigravity ${SUBCOMMANDS.join("|")} [name]`);
			}
		},
	} as any);

	activate();
}
