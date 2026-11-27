// Antigravity accounts for pi tabs (extensions/antigravity), after t3code's provider instances
// (apps/server/src/provider/antigravityAuthSupport.ts; docs/user/providers-antigravity.md "Sign-in
// methods", "Multiple accounts and removal"):
//
// - Each account has a private profile, agy's GEMINI_HOME, so sign-ins, hooks and MCP settings of
//   one never reach another or the user's own `~/.gemini`; the user's global skills and rules are
//   linked in (linkUserConfig). agy runs with `acp --gemini-dir <profile> --app-data-dir
//   antigravity-acp`, and its sign-in method in `<profile>/antigravity-acp/settings.json`.
// - Each account is its own pi provider: `antigravity` (the account named `default`) and
//   `antigravity-<name>`. The user picks an account by picking its model; nothing here ever
//   switches accounts by itself (t3code leaves that out on purpose: providers' terms).
// - agy's environment is pi's without the variables that choose a credential or a profile behind
//   the account's back (GEMINI_API_KEY, GOOGLE_*, GEMINI_HOME, BROWSER…: t3code's list), so an API
//   key in the shell never bills instead of the subscription. An API-key account's key comes from
//   pi's own credential store (`/login antigravity-<name>`, a masked prompt; pi keeps it in
//   auth.json, 0600, as every pi API key) and reaches agy only in its process environment.
// - Where: <Deckhand's data dir>/antigravity (macOS `~/Library/Application Support/Deckhand`, or
//   the older `pi-desk` when only that exists; Linux `$XDG_DATA_HOME/deckhand` or
//   `~/.local/share/deckhand`). accounts.json there (0600) holds names, methods and GCP
//   project/location, and agy's path when the user set one (`/antigravity path`), never a secret;
//   profiles/<name> (0700) the profiles.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { alive } from "./agy-ledger.ts";

export type Method = "oauth-personal" | "oauth-business" | "gemini-api-key" | "agent-platform";

export const METHODS: readonly { id: Method; label: string }[] = [
	{ id: "oauth-personal", label: "Google account" },
	{ id: "oauth-business", label: "Gemini Enterprise" },
	{ id: "gemini-api-key", label: "Gemini API key" },
	{ id: "agent-platform", label: "Agent Platform (Vertex AI)" },
];
export const methodLabel = (m: Method) => METHODS.find((x) => x.id === m)?.label ?? m;
export const isMethod = (m: unknown): m is Method => METHODS.some((x) => x.id === m);

export interface Account {
	name: string;
	method: Method;
	gcpProject?: string;
	gcpLocation?: string;
}

export const DEFAULT_ACCOUNT: Account = { name: "default", method: "oauth-personal" };
export const PLANS_URL = "https://antigravity.google/docs/plans";

/** A provider id per account: `antigravity` for the default one. */
export const providerIdOf = (name: string) => (name === "default" ? "antigravity" : `antigravity-${name}`);

/** Account names: short, lower case, a folder name and a provider id suffix. */
export const validName = (name: string) => /^[a-z0-9][a-z0-9-]{0,31}$/.test(name);

/** Whether the account's credential is an API key held by pi (no key: not configured). */
export function usesKey(a: Account): boolean {
	return a.method === "gemini-api-key" || (a.method === "agent-platform" && !(a.gcpProject && a.gcpLocation));
}
/** Whether its sign-in is in a browser (Google's). */
export const usesBrowser = (a: Account) => a.method === "oauth-personal" || a.method === "oauth-business";

/** Where the accounts and profiles live. */
export function dataRoot(env: NodeJS.ProcessEnv = process.env, platform = process.platform): string {
	const home = env.HOME || os.homedir(); // dataRoot(env) for tests; os.homedir() reads HOME too
	if (platform === "darwin") {
		const support = path.join(home, "Library", "Application Support");
		const dh = path.join(support, "Deckhand"), old = path.join(support, "pi-desk");
		return path.join(!fs.existsSync(dh) && fs.existsSync(old) ? old : dh, "antigravity");
	}
	return path.join(env.XDG_DATA_HOME && path.isAbsolute(env.XDG_DATA_HOME) ? path.join(env.XDG_DATA_HOME, "deckhand") : path.join(home, ".local", "share", "deckhand"), "antigravity");
}

const accountsFile = (root: string) => path.join(root, "accounts.json");

/** The accounts accounts.json holds (bad and repeated entries skipped). */
export function storedAccounts(root: string): Account[] {
	let list: Account[] = [];
	try {
		const raw = JSON.parse(fs.readFileSync(accountsFile(root), "utf8"));
		if (Array.isArray(raw?.accounts))
			list = raw.accounts
				.filter((a: any) => typeof a?.name === "string" && validName(a.name) && isMethod(a.method))
				.map((a: any) => ({
					name: a.name,
					method: a.method,
					...(typeof a.gcpProject === "string" && a.gcpProject ? { gcpProject: a.gcpProject } : {}),
					...(typeof a.gcpLocation === "string" && a.gcpLocation ? { gcpLocation: a.gcpLocation } : {}),
				}));
	} catch {}
	const seen = new Set<string>();
	return list.filter((a) => !seen.has(a.name) && (seen.add(a.name), true));
}

/** The accounts, `default` first (implicit: a Google account, until configured). */
export function loadAccounts(root: string): Account[] {
	const list = storedAccounts(root);
	const def = list.find((a) => a.name === "default") ?? DEFAULT_ACCOUNT;
	return [def, ...list.filter((a) => a.name !== "default")];
}

/** agy's path as the user set it (`/antigravity path`), unchecked; undefined when not set. */
export function storedAgyPath(root: string): string | undefined {
	try {
		const p = JSON.parse(fs.readFileSync(accountsFile(root), "utf8"))?.agyPath;
		return typeof p === "string" && p.trim() ? p.trim() : undefined;
	} catch {
		return undefined;
	}
}

/** Writes accounts.json (0600, in a 0700 folder), keeping or replacing agy's path. It never holds a key. */
export function saveAccounts(root: string, accounts: Account[], agyPath: string | null | undefined = storedAgyPath(root)) {
	fs.mkdirSync(root, { recursive: true, mode: 0o700 });
	const body = JSON.stringify({ about: "Deckhand's Antigravity accounts (pi tabs). No secrets: API keys are in pi's credential store.", ...(agyPath ? { agyPath } : {}), accounts: accounts.map(({ name, method, gcpProject, gcpLocation }) => ({ name, method, gcpProject, gcpLocation })) }, null, 2);
	const tmp = `${accountsFile(root)}.tmp-${process.pid}`;
	fs.writeFileSync(tmp, `${body}\n`, { mode: 0o600 });
	fs.renameSync(tmp, accountsFile(root));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Changes accounts.json under a lock (`accounts.json.lock`, O_EXCL, with this pid), reading it
 * again inside, so two pi processes changing accounts never lose each other's change. A lock whose
 * process is gone is taken over; one held longer than `waitMs` by a live process is an error.
 */
export async function updateAccounts(
	root: string,
	change: (accounts: Account[], agyPath: string | undefined) => { accounts?: Account[]; agyPath?: string | null },
	waitMs = 5000,
): Promise<void> {
	fs.mkdirSync(root, { recursive: true, mode: 0o700 });
	const lock = `${accountsFile(root)}.lock`;
	const until = Date.now() + waitMs;
	for (;;) {
		try {
			fs.writeFileSync(lock, JSON.stringify({ pid: process.pid }), { flag: "wx", mode: 0o600 });
			break;
		} catch (e: any) {
			if (e?.code !== "EEXIST") throw e;
		}
		let pid: number | undefined, age = 0;
		try {
			age = Date.now() - fs.statSync(lock).mtimeMs;
			pid = Number(JSON.parse(fs.readFileSync(lock, "utf8"))?.pid);
		} catch {}
		const stale = pid ? !alive(pid) : age > 2000; // no pid yet: being written, unless old
		if (stale) {
			fs.rmSync(lock, { force: true });
			continue;
		}
		if (Date.now() > until) throw new Error(`Another pi (process ${pid}) is changing the Antigravity accounts: try again`);
		await sleep(50);
	}
	try {
		const next = change(storedAccounts(root), storedAgyPath(root));
		saveAccounts(root, next.accounts ?? storedAccounts(root), next.agyPath === undefined ? storedAgyPath(root) : next.agyPath);
	} finally {
		fs.rmSync(lock, { force: true });
	}
}

export interface Profile {
	geminiHome: string;
	acpDir: string;
	tmpDir: string;
}

export const profileOf = (root: string, name: string): Profile => {
	const geminiHome = path.join(root, "profiles", name);
	const acpDir = path.join(geminiHome, "antigravity-acp");
	return { geminiHome, acpDir, tmpDir: path.join(acpDir, "tmp") };
};

/** A run folder: `<pi's pid>-<6 random>`, under the profile's tmp. */
const RUN_DIR = /^(\d+)-[A-Za-z0-9]{6}$/;

/**
 * Removes the run folders of processes that are gone: pi's (the name) and agy's (its agy.pid) both
 * dead. A folder either process still has is never touched; nor is anything else in tmp.
 */
export function sweepRunDirs(tmpDir: string) {
	let entries: string[] = [];
	try {
		entries = fs.readdirSync(tmpDir);
	} catch {
		return;
	}
	for (const e of entries) {
		const m = RUN_DIR.exec(e);
		if (!m || alive(Number(m[1]))) continue;
		const dir = path.join(tmpDir, e);
		let agyPid = 0;
		try {
			agyPid = Number(fs.readFileSync(path.join(dir, "agy.pid"), "utf8").trim());
		} catch {}
		if (agyPid && alive(agyPid)) continue;
		try {
			fs.rmSync(dir, { recursive: true, force: true });
		} catch {}
	}
}

/**
 * A new agy process's own TMPDIR (agy unpacks its runtime there): `tmp/<pi's pid>-<random>`, 0700,
 * after sweeping dead processes' leftovers (as t3code's retireAntigravityRuntimeTempDirs, but by
 * pid: several pi processes share a profile). The connection removes it when agy ends.
 */
export function runDir(p: Profile): string {
	fs.mkdirSync(p.tmpDir, { recursive: true, mode: 0o700 });
	sweepRunDirs(p.tmpDir);
	return fs.mkdtempSync(path.join(p.tmpDir, `${process.pid}-`));
}

/** agy's arguments for a profile (t3code buildAntigravityAcpSpawnInput); `--login` for the code sign-in. */
export const agyArgs = (p: Profile, login = false) => ["acp", "--gemini-dir", p.geminiHome, "--app-data-dir", "antigravity-acp", ...(login ? ["--login"] : [])];

/** Whether agy keeps a saved Google sign-in in the profile (its file storage: the file is only stat'ed, never read). */
export const hasSavedLogin = (p: Profile) => fs.existsSync(path.join(p.acpDir, "acp_token.json"));

/**
 * Makes the profile: its folders (0700), the method in settings.json (no credential), and links to
 * the user's ~/.gemini skills and rules (t3code linkAntigravityUserConfig). Returns it.
 */
export function prepareProfile(root: string, a: Account, home = os.homedir()): Profile {
	const p = profileOf(root, a.name);
	for (const d of [root, path.dirname(p.geminiHome), p.geminiHome, p.acpDir, p.tmpDir]) {
		fs.mkdirSync(d, { recursive: true, mode: 0o700 });
		fs.chmodSync(d, 0o700);
	}
	const gcp = { ...(a.gcpProject ? { project: a.gcpProject } : {}), ...(a.gcpLocation ? { location: a.gcpLocation } : {}) };
	fs.writeFileSync(path.join(p.acpDir, "settings.json"), `${JSON.stringify({ auth: { type: a.method }, ...(Object.keys(gcp).length ? { gcp } : {}) })}\n`, { mode: 0o600 });
	linkUserConfig(p.geminiHome, path.join(home, ".gemini"));
	return p;
}

/** The user's ~/.gemini parts linked into a profile. */
export const USER_CONFIG = [
	["config", "skills"],
	["antigravity-cli", "skills"],
	["AGENTS.md"],
	["GEMINI.md"],
	["config", "skills.json"],
] as const;

/** Links each USER_CONFIG part that exists; drops a link whose target went; never deletes content. */
export function linkUserConfig(profile: string, userGemini: string) {
	for (const segs of USER_CONFIG) {
		const link = path.join(profile, ...segs), target = path.join(userGemini, ...segs);
		try {
			let st: fs.Stats | undefined;
			try {
				st = fs.lstatSync(link);
			} catch {}
			if (!fs.existsSync(target)) {
				if (st?.isSymbolicLink()) fs.unlinkSync(link); // agy makes these folders itself; mkdir fails on a dangling link
				continue;
			}
			if (st?.isSymbolicLink()) {
				if (path.resolve(path.dirname(link), fs.readlinkSync(link)) === target) continue;
				fs.unlinkSync(link);
			} else if (st?.isDirectory()) {
				try {
					fs.rmdirSync(link); // agy's empty placeholder; a folder with content is left alone
				} catch {
					continue;
				}
			} else if (st) continue; // a file the profile has of its own
			fs.mkdirSync(path.dirname(link), { recursive: true, mode: 0o700 });
			fs.symlinkSync(target, link);
		} catch {}
	}
}

/** Variables that pick agy's credential or profile, or change how it starts: never passed through (t3code removedEnvironmentKeys). */
export const REMOVED_ENV = new Set([
	"GEMINI_API_KEY",
	"GOOGLE_API_KEY",
	"GOOGLE_APPLICATION_CREDENTIALS",
	"GOOGLE_CLOUD_PROJECT",
	"GOOGLE_CLOUD_LOCATION",
	"GOOGLE_CLOUD_QUOTA_PROJECT",
	"GOOGLE_GENAI_USE_VERTEXAI",
	"GCLOUD_PROJECT",
	"CLOUDSDK_CORE_PROJECT",
	"AGY_ACP_CCPA_PROJECT",
	"AGY_ACP_ENABLE_OAUTH",
	"GEMINI_HOME",
	"AGY_ACP_FORCE_FILE_STORAGE",
	"AGY_CLI_DISABLE_AUTO_UPDATE",
	"BROWSER",
	"PYTHONUNBUFFERED",
	"ELECTRON_RUN_AS_NODE",
	"CHROME_CRASHPAD_PIPE_NAME",
]);

/**
 * agy's environment for an account (t3code antigravityEnvironment): pi's, without REMOVED_ENV
 * (case-insensitively), any GOOGLE_* and Deckhand's own variables; then the profile, file storage,
 * no self-update, its own TMPDIR, and the account's key when it has one. A Google-account sign-in
 * also gets SSH_CONNECTION: agy 1.5 keeps Google sign-ins in one OS keyring entry for every
 * profile (it ignores AGY_ACP_FORCE_FILE_STORAGE) unless it believes it runs over SSH, so without it
 * two accounts would share, and overwrite, one sign-in.
 */
export function agyEnvFor(a: Account, p: Profile, apiKey: string | undefined, base: NodeJS.ProcessEnv = process.env, tmpDir = p.tmpDir): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {};
	// Application Default Credentials (gcloud's) are an Agent Platform account's own sign-in when it
	// has a project and no key; every other account gets none of them. (t3code drops
	// GOOGLE_APPLICATION_CREDENTIALS for every method and leaves CLOUDSDK_* alone.)
	const adc = a.method === "agent-platform" && !usesKey(a);
	for (const [k, v] of Object.entries(base)) {
		const K = k.toUpperCase();
		if (K === "GOOGLE_APPLICATION_CREDENTIALS" || K === "CLOUDSDK_CONFIG" || K.startsWith("CLOUDSDK_AUTH_")) {
			if (adc) env[k] = v;
			continue;
		}
		if (REMOVED_ENV.has(K) || K.startsWith("GOOGLE_") || K.startsWith("DECKHAND_")) continue;
		env[k] = v;
	}
	const key = apiKey?.trim();
	return {
		...env,
		...(key && a.method === "gemini-api-key" ? { GEMINI_API_KEY: key } : {}),
		...(key && a.method === "agent-platform" ? { GOOGLE_API_KEY: key } : {}),
		...(a.method === "oauth-personal" ? { SSH_CONNECTION: base.SSH_CONNECTION || "127.0.0.1 0 127.0.0.1 0" } : {}),
		GEMINI_HOME: p.geminiHome,
		AGY_ACP_FORCE_FILE_STORAGE: "1",
		AGY_CLI_DISABLE_AUTO_UPDATE: "true",
		PYTHONUNBUFFERED: "1",
		ELECTRON_RUN_AS_NODE: "1",
		TMPDIR: tmpDir,
	};
}

/** A message that says what to do, for agy's errors that have a known fix. */
export function explainError(message: string, a: Account): string {
	if (/SUBSCRIPTION_REQUIRED/.test(message))
		return `Google requires an eligible Antigravity subscription for the account "${a.name}" (${methodLabel(a.method)}): see ${PLANS_URL}`;
	return message;
}

/** The command that signs an account in. */
export function signInCommand(a: Account): string {
	if (usesKey(a)) return `/login ${providerIdOf(a.name)}`;
	return a.name === "default" ? "/antigravity-login" : `/antigravity login ${a.name}`;
}
export const notSignedIn = (a: Account) =>
	`Antigravity account "${a.name}" is not signed in: run ${signInCommand(a)}`;
