// Antigravity accounts for pi tabs (extensions/antigravity), after t3code's provider instances
// (apps/server/src/provider/antigravityAuthSupport.ts; docs/user/providers-antigravity.md "Sign-in
// methods", "Multiple accounts and removal"):
//
// - Each account has a private profile (the folder agy's --gemini-dir names; agy 1.5.18 reads no
//   GEMINI_HOME or other variable for it), so sign-ins, hooks and MCP settings of
//   one never reach another or the user's own `~/.gemini`; the user's global skills and rules are
//   linked in (linkUserConfig). agy runs with `acp --gemini-dir <profile> --app-data-dir
//   antigravity-acp`, and its sign-in method in `<profile>/antigravity-acp/settings.json`.
// - Each account is its own pi provider: `antigravity` (the account named `default`) and
//   `antigravity-<name>`. The user picks an account by picking its model; nothing here ever
//   switches accounts by itself (t3code leaves that out on purpose: providers' terms).
// - agy's environment is pi's without the variables that choose a credential or a profile behind
//   the account's back (GEMINI_API_KEY, GOOGLE_*, BROWSER…: t3code's list; GEMINI_HOME too, which
//   agy 1.5.18 ignores but older or other builds may not), so an API
//   key in the shell never bills instead of the subscription. An API-key account's key comes from
//   pi's own credential store (`/login antigravity-<name>`, a masked prompt; pi keeps it in
//   auth.json, 0600, as every pi API key) and reaches agy only in its process environment.
// - Where: <Deckhand's data dir>/antigravity (macOS `~/Library/Application Support/Deckhand`, or
//   the older `pi-desk` when only that exists; Linux `~/.local/share/deckhand`, as the core).
//   accounts.json there (0600) holds names, methods, GCP project/location, labels, approvals
//   (`/antigravity approvals`: allow, the default, or ask), the folders of accounts used in
//   place, agy's path when the user set one (`/antigravity path`) and the default account, never
//   a secret; profiles/<name> (0700) the profiles Deckhand made. Deckhand's core
//   writes it too (same lock, agy-lock.ts): each writer keeps what it does not understand.
// - An account with `dir` is the user's own folder (e.g. ~/.gemini), used in place: nothing is
//   written in it but its antigravity-acp/ folder, it is never chmod'ed, linked into or deleted.
// - At most one Google account keeps its sign-in in agy's OS keyring: the first `storage: "keyring"`
//   entry, else the default account (a Google account not marked `storage: "file"`). agy 1.5.18 has
//   one keychain entry for every profile: it signs in there unless AGY_CLI_FORCE_FILE_TOKEN_STORAGE
//   is set (then into the profile's antigravity-acp/acp_token.json), and it reads a sign-in from the
//   profile's file, else from the keychain, whichever mode (as the real agy showed: neither
//   SSH_CONNECTION nor AGY_ACP_FORCE_FILE_STORAGE changes where it stores). So the keychain account
//   signs in and runs in keychain mode, every other one in file mode, login and sessions alike.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { groupAlive, reapGroup, signalGroup } from "./acp.ts";
import { alive, pruneLedger } from "./agy-ledger.ts";
import { readLock, tryLock, unlock } from "./agy-lock.ts";
import type { ApprovalMode } from "./agy-approvals.ts";

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
	/** How agy's requests are answered (lib/agy-approvals.ts); `allow` when absent. */
	approvals?: ApprovalMode;
	/** A display name (Deckhand's rename edits only this); the name stays the id. */
	label?: string;
	/** An absolute profile folder used in place (the user's own: found by Deckhand's scan, or picked there); absent: `<root>/profiles/<name>`. */
	dir?: string;
	/** "found" (Deckhand's scan), "added" (picked in Deckhand), or absent (a profile made under profiles/). */
	source?: string;
	/** "keyring" or "file" (absent: file), as stored. */
	storage?: "keyring" | "file";
	/** Derived, never stored: this is the one account whose Google sign-in is agy's OS keyring entry (the first `storage: "keyring"`). */
	keyring?: boolean;
}

/** The account fields accounts.json holds that this extension knows (others are kept as they are). */
const STORED_KEYS = ["method", "gcpProject", "gcpLocation", "label", "dir", "source", "storage", "approvals"] as const;

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
export function dataRoot(env: NodeJS.ProcessEnv = process.env, platform = process.platform): string { // env-read-ok: dataRoot reads HOME only
	const home = env.HOME || os.homedir(); // dataRoot(env) for tests; os.homedir() reads HOME too
	if (platform === "darwin") {
		const support = path.join(home, "Library", "Application Support");
		const dh = path.join(support, "Deckhand"), old = path.join(support, "pi-desk");
		return path.join(!fs.existsSync(dh) && fs.existsSync(old) ? old : dh, "antigravity");
	}
	// as the core's data dir (src/core/platform.odin data_dir_under): never XDG_DATA_HOME
	return path.join(home, ".local", "share", "deckhand", "antigravity");
}

const accountsFile = (root: string) => path.join(root, "accounts.json");

/** `text` into `file` (0600) by a temp file and a rename; a failed write or rename leaves no temp file. Throws as fs does. */
function writeAtomic(file: string, text: string) {
	const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
	try {
		fs.writeFileSync(tmp, text, { mode: 0o600 });
		fs.renameSync(tmp, file);
	} catch (e) {
		fs.rmSync(tmp, { force: true });
		throw e;
	}
}

const isObj = (x: unknown): x is Record<string, any> => !!x && typeof x === "object" && !Array.isArray(x);

/** accounts.json as it is (an object; {} when missing or not JSON). */
function readRaw(root: string): Record<string, any> {
	try {
		const raw = JSON.parse(fs.readFileSync(accountsFile(root), "utf8"));
		return isObj(raw) ? raw : {};
	} catch {
		return {};
	}
}

/** One raw entry as an account, or undefined when it is not one this extension can use. */
function parseAccount(a: any): Account | undefined {
	if (!isObj(a) || typeof a.name !== "string" || !validName(a.name) || !isMethod(a.method)) return undefined;
	if (a.dir !== undefined && !(typeof a.dir === "string" && path.isAbsolute(a.dir))) return undefined; // a folder not absolute: ignored
	const str = (k: string) => (typeof a[k] === "string" && a[k] ? { [k]: a[k] as string } : {});
	return {
		name: a.name,
		method: a.method,
		...str("gcpProject"),
		...str("gcpLocation"),
		...str("label"),
		...str("dir"),
		...str("source"),
		...(a.storage === "keyring" || a.storage === "file" ? { storage: a.storage } : {}),
		...(a.approvals === "ask" ? { approvals: "ask" as const } : {}),
	};
}

/** The accounts of a raw accounts.json (bad and repeated entries skipped; `keyring` is loadAccounts'). */
function accountsOfRaw(raw: Record<string, any>): Account[] {
	const seen = new Set<string>();
	const list: Account[] = [];
	for (const e of Array.isArray(raw.accounts) ? raw.accounts : []) {
		const a = parseAccount(e);
		if (!a || seen.has(a.name)) continue;
		seen.add(a.name);
		list.push(a);
	}
	return list;
}

/** The accounts accounts.json holds (bad and repeated entries skipped). */
export const storedAccounts = (root: string): Account[] => accountsOfRaw(readRaw(root));

/** The accounts, `default` first (implicit: a Google account, until configured). */
export function loadAccounts(root: string): Account[] {
	const list = storedAccounts(root);
	// the default is always Deckhand's own profile (<root>/profiles/default), as the core has it
	const { dir: _dir, ...def } = list.find((a) => a.name === "default") ?? DEFAULT_ACCOUNT;
	const all: Account[] = [def, ...list.filter((a) => a.name !== "default")];
	const h = keychainHolder(root, all);
	return h ? all.map((a) => (a === h ? { ...a, keyring: true } : a)) : all;
}

/**
 * The one account whose Google sign-in is agy's keychain entry (the core's agy_keychain_holder: the
 * same rule). In order, `default` first then the file's: the first Google account (oauth-personal)
 * with storage "keyring" and no sign-in file of its own; when no Google account has storage
 * "keyring", the default, if it is a Google account not marked "file" with no file of its own;
 * else none. An account with its own file always runs in file mode, since agy reads the file
 * before the keychain.
 */
export function keychainHolder(root: string, ordered: Account[]): Account | undefined {
	const google = (a: Account) => a.method === "oauth-personal";
	const own = (a: Account) => hasSavedLogin(profileOf(root, a));
	const marked = ordered.filter((a) => google(a) && a.storage === "keyring");
	if (marked.length) return marked.find((a) => !own(a));
	const d = ordered.find((a) => a.name === "default");
	return d && google(d) && d.storage !== "file" && !own(d) ? d : undefined;
}

/**
 * Why a Google account cannot be used, or undefined: one with no sign-in file of its own that is
 * not the keychain account would run as the keychain's sign-in (agy falls back to it), which is
 * another account's: refused (turns, the tool, listings) until it signs in itself.
 */
export function riderReason(root: string, a: Account, all: Account[] = loadAccounts(root)): string | undefined {
	if (a.method !== "oauth-personal" || a.keyring || hasSavedLogin(profileOf(root, a))) return undefined;
	const h = all.find((x) => x.keyring);
	// agy's own profile: a sign-in file there is what agy outside Deckhand reads first
	const p = profileOf(root, a);
	const own = p.inPlace && path.resolve(p.geminiHome) === path.resolve(os.homedir(), ".gemini") ? `: that writes a sign-in file into ${p.geminiHome}, which agy outside Deckhand then uses too` : "";
	return `Antigravity account "${a.name}" has no sign-in of its own (it would run as ${h ? `${h.name}'s` : "the macOS keychain's sign-in"}). Run ${signInCommand(a)}${own}.`;
}

/** agy's path as the user set it (`/antigravity path`), unchecked; undefined when not set. */
export function storedAgyPath(root: string): string | undefined {
	const p = readRaw(root).agyPath;
	return typeof p === "string" && p.trim() ? p.trim() : undefined;
}

/** The name of the account used when none is named: accounts.json's `defaultAccount` when it is one of `accounts`, else `default`. */
export function defaultNameOf(root: string, accounts: Account[] = loadAccounts(root)): string {
	const d = readRaw(root).defaultAccount;
	return typeof d === "string" && accounts.some((a) => a.name === d) ? d : "default";
}

/** What a change to accounts.json sees besides the accounts. */
export interface StoredRest {
	agyPath?: string;
	defaultAccount?: string;
	removedDirs: string[];
}
/** A change: what to replace (undefined: keep; null: remove the key). */
export interface AccountsChange {
	accounts?: Account[];
	agyPath?: string | null;
	defaultAccount?: string | null;
	removedDirs?: string[];
}

/**
 * accounts.json with `change` applied to `raw`, keeping everything this extension does not
 * understand: unknown top-level keys, unknown keys of each account, and entries it cannot use. An
 * account's known keys are written only where the change made them differ.
 */
function applyChange(raw: Record<string, any>, change: AccountsChange): Record<string, any> {
	const out: Record<string, any> = { ...raw };
	out.about ??= "Deckhand's Antigravity accounts (pi tabs and Deckhand). No secrets: API keys are in pi's credential store.";
	for (const k of ["agyPath", "defaultAccount"] as const) {
		const v = change[k];
		if (v === null) delete out[k];
		else if (v !== undefined) out[k] = v;
	}
	if (change.removedDirs) out.removedDirs = change.removedDirs;
	if (change.accounts) {
		const before = new Map(accountsOfRaw(raw).map((a) => [a.name, a]));
		const after = new Map(change.accounts.map((a) => [a.name, a]));
		const done = new Set<string>();
		const entries: any[] = [];
		const merged = (e: Record<string, any>, b: Account | undefined, a: Account) => {
			const o: Record<string, any> = { ...e, name: a.name };
			for (const k of STORED_KEYS)
				if (!b || b[k] !== a[k]) {
					if (a[k] === undefined) delete o[k];
					else o[k] = a[k];
				}
			return o;
		};
		for (const e of Array.isArray(raw.accounts) ? raw.accounts : []) {
			const name = isObj(e) && typeof e.name === "string" ? e.name : undefined;
			const b = name !== undefined ? before.get(name) : undefined;
			if (!b) {
				// an entry this extension cannot use (or a name it does not know): kept, unless it now names an account
				if (name === undefined || !after.has(name)) entries.push(e);
				continue;
			}
			if (done.has(b.name)) continue; // a repeat of an account: dropped
			done.add(b.name);
			const a = after.get(b.name);
			if (a) entries.push(merged(e, b, a)); // else: removed
		}
		for (const a of change.accounts) if (!done.has(a.name)) (done.add(a.name), entries.push(merged({}, undefined, a)));
		out.accounts = entries;
	}
	return out;
}

function writeRaw(root: string, raw: Record<string, any>) {
	fs.mkdirSync(root, { recursive: true, mode: 0o700 });
	const tmp = `${accountsFile(root)}.tmp-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
	fs.writeFileSync(tmp, `${JSON.stringify(raw, null, 2)}\n`, { mode: 0o600 });
	fs.renameSync(tmp, accountsFile(root));
}

/**
 * Records the version agy reported (initialize's agentInfo.version) beside accounts.json, as
 * `agy-seen.json` {path, size, mtime (s), version}: Deckhand's coding-agents checklist reads it to
 * show agy's version without ever running agy, and trusts it only while the binary at `path` still
 * has that size and mtime. Nothing secret; 0600 like the rest. Written only when it changes.
 */
export function noteAgySeen(root: string, agyPath: string, version: string) {
	if (!version || !path.isAbsolute(agyPath)) return;
	try {
		const st = fs.statSync(agyPath);
		const body = JSON.stringify({ path: agyPath, size: st.size, mtime: Math.floor(st.mtimeMs / 1000), version });
		const file = path.join(root, "agy-seen.json");
		try {
			if (fs.readFileSync(file, "utf8").trim() === body) return;
		} catch {}
		fs.mkdirSync(root, { recursive: true, mode: 0o700 });
		writeAtomic(file, `${body}\n`);
	} catch {}
}

/**
 * Records an account's model count (agy's models, without the `default` placeholder) in
 * `agy-models.json` {<name>: {count, at (s)}} beside accounts.json, for Deckhand's Settings, which
 * only reads it. A cache: no lock, last writer wins, other names kept; written only when the count
 * changed. 0600, temp file then rename. Nothing secret.
 */
export function noteModelCount(root: string, name: string, count: number) {
	if (!validName(name) || !Number.isInteger(count) || count < 0) return;
	try {
		const file = path.join(root, "agy-models.json");
		let all: Record<string, any> = {};
		try {
			const raw = JSON.parse(fs.readFileSync(file, "utf8"));
			if (isObj(raw)) all = raw;
		} catch {}
		if (isObj(all[name]) && all[name].count === count) return;
		all[name] = { count, at: Math.floor(Date.now() / 1000) };
		fs.mkdirSync(root, { recursive: true, mode: 0o700 });
		writeAtomic(file, `${JSON.stringify(all)}\n`);
	} catch {}
}

/**
 * Each account's last model list, for /model at pi's start before agy is asked again:
 * `agy-model-lists.json` {<name>: {models [{id, name, description?}], thinking [ids], at (ms, when
 * agy listed them), triedAt? (ms, a background listing started), signedOut? (the background listing
 * found no sign-in)}} beside accounts.json. pi's alone (Deckhand reads agy-models.json's counts).
 * A cache like that one: no lock, last writer wins, other names kept, 0600, temp file then rename;
 * model names only, nothing secret. What does not look like a list is ignored.
 */
export interface ModelCache {
	models: { id: string; name: string; description?: string }[];
	thinking: string[];
	at: number;
	triedAt?: number;
	signedOut?: boolean;
}
const MODEL_LISTS = "agy-model-lists.json";
const MODEL_LISTS_MAX = 512 * 1024;
const str = (v: unknown, max = 2000): v is string => typeof v === "string" && v.length > 0 && v.length <= max;

function readModelLists(root: string): Record<string, unknown> {
	try {
		const file = path.join(root, MODEL_LISTS);
		if (fs.statSync(file).size > MODEL_LISTS_MAX) return {};
		const raw = JSON.parse(fs.readFileSync(file, "utf8"));
		return isObj(raw) ? raw : {};
	} catch {
		return {};
	}
}

/** The account's cached model list, or undefined. */
export function cachedModels(root: string, name: string): ModelCache | undefined {
	const e = readModelLists(root)[name];
	if (!validName(name) || !isObj(e)) return undefined;
	const models = Array.isArray(e.models)
		? e.models
				.filter((m: any) => isObj(m) && str(m.id, 200) && str(m.name, 200))
				.slice(0, 200)
				.map((m: any) => ({ id: m.id, name: m.name, ...(str(m.description) ? { description: m.description } : {}) }))
		: [];
	const thinking = Array.isArray(e.thinking) ? e.thinking.filter((t: unknown) => str(t, 100)).slice(0, 20) : [];
	const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined);
	return { models, thinking, at: num(e.at) ?? 0, ...(num(e.triedAt) !== undefined ? { triedAt: num(e.triedAt) } : {}), ...(e.signedOut === true ? { signedOut: true } : {}) };
}

/** Changes the account's cached model list (`change` gets what is there, or an empty one). */
export function noteModelList(root: string, name: string, change: (c: ModelCache) => ModelCache) {
	if (!validName(name)) return;
	try {
		const all = readModelLists(root);
		all[name] = change(cachedModels(root, name) ?? { models: [], thinking: [], at: 0 });
		fs.mkdirSync(root, { recursive: true, mode: 0o700 });
		const file = path.join(root, MODEL_LISTS);
		writeAtomic(file, `${JSON.stringify(all)}\n`);
	} catch {}
}

/**
 * Claims the account's background listing for this process: under `agy-model-lists.json.lock`
 * (agy-lock.ts; one whose process is gone is taken over), the cache is read again and, unless a
 * list or a try is younger than `freshMs`, a try is recorded. False: fresh, tried by another pi
 * meanwhile, or the lock held (another pi is claiming): not listed here.
 */
export function claimListing(root: string, name: string, freshMs: number): boolean {
	if (!validName(name)) return false;
	try {
		fs.mkdirSync(root, { recursive: true, mode: 0o700 });
	} catch {
		return false;
	}
	const lock = path.join(root, `${MODEL_LISTS}.lock`);
	if (!tryLock(lock, (seen) => !alive(seen.pid!))) return false;
	try {
		const c = cachedModels(root, name);
		if (c && Date.now() - Math.max(c.at, c.triedAt ?? 0) < freshMs) return false;
		noteModelList(root, name, (x) => ({ ...x, triedAt: Date.now() }));
		return true;
	} finally {
		unlock(lock);
	}
}

/** agy listed the account's models (a session, a listing): the list, its count for Deckhand, and the account is signed in. */
export function noteModels(root: string, name: string, models: ModelCache["models"], thinking: string[], count: number) {
	noteModelCount(root, name, count);
	noteModelList(root, name, (c) => ({ models: models.map((m) => ({ id: m.id, name: m.name, ...(m.description ? { description: m.description } : {}) })), thinking: [...thinking], at: Date.now(), ...(c.triedAt ? { triedAt: c.triedAt } : {}) }));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Changes accounts.json under a lock (`accounts.json.lock`, agy-lock.ts: created atomically, with
 * this pid; Deckhand's core takes the same lock), reading it again inside, so two writers never
 * lose each other's change. A lock whose process is gone is taken over; one held longer than
 * `waitMs` is an error. What the change does not touch is written back as it was read.
 */
export async function updateAccounts(root: string, change: (accounts: Account[], rest: StoredRest) => AccountsChange, waitMs = 5000): Promise<void> {
	fs.mkdirSync(root, { recursive: true, mode: 0o700 });
	const lock = `${accountsFile(root)}.lock`;
	const until = Date.now() + waitMs;
	while (!tryLock(lock, (seen) => !alive(seen.pid!))) {
		if (Date.now() > until) throw new Error(`Another pi (process ${readLock(lock)?.pid ?? "unknown"}) is changing the Antigravity accounts: try again`);
		await sleep(50);
	}
	try {
		const raw = readRaw(root);
		const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);
		const rest: StoredRest = {
			agyPath: str(raw.agyPath),
			defaultAccount: str(raw.defaultAccount),
			removedDirs: Array.isArray(raw.removedDirs) ? raw.removedDirs.filter((d: unknown) => typeof d === "string") : [],
		};
		writeRaw(root, applyChange(raw, change(accountsOfRaw(raw), rest)));
	} finally {
		unlock(lock);
	}
}

export interface Profile {
	geminiHome: string;
	acpDir: string;
	tmpDir: string;
	/** The user's own folder (the account's `dir`), used in place: only its antigravity-acp/ is Deckhand's. */
	inPlace: boolean;
}

/** An account's profile: its `dir` in place, else `<root>/profiles/<name>`. */
export const profileOf = (root: string, a: Pick<Account, "name" | "dir">): Profile => {
	const inPlace = !!a.dir && path.isAbsolute(a.dir);
	const geminiHome = inPlace ? a.dir! : path.join(root, "profiles", a.name);
	const acpDir = path.join(geminiHome, "antigravity-acp");
	return { geminiHome, acpDir, tmpDir: path.join(acpDir, "tmp"), inPlace };
};

/**
 * The files whose presence marks a folder as an agy profile to guard (the core's AGY_GUARD_MARKS):
 * agy's app data (antigravity-acp/ for agy acp, antigravity-cli/ for its interactive CLI) and the
 * Antigravity IDE's (~/.gemini/antigravity/).
 */
export const PROFILE_MARKS = ["antigravity-acp/acp_token.json", "antigravity-acp/installation_id", "antigravity-cli/installation_id", "antigravity/installation_id"] as const;
/** Whether folder `d` holds agy's marks (a profile agy has run in). */
export const profileMarked = (d: string) => PROFILE_MARKS.some((m) => fs.statSync(path.join(d, m), { throwIfNoEntry: false })?.isFile() === true);

/**
 * Every agy profile Deckhand guards, as the core's agy_profile_dirs: `<root>/profiles` (all of
 * it), each account's profile (a folder used in place included), a removed account's folder and
 * agy's default profile (~/.gemini: agy 1.5.18 reads no variable for it) while they hold agy's marks. HOME or above is
 * never one. Absolute, as written (callers compare real paths too).
 */
export function profileDirs(root: string, env: NodeJS.ProcessEnv = process.env): string[] { // env-read-ok: profileDirs reads HOME only
	const home = path.resolve(env.HOME || os.homedir());
	const out = new Set<string>();
	const add = (d: string | undefined) => {
		if (!d || !path.isAbsolute(d)) return;
		const c = path.resolve(d);
		if (c === "/" || home === c || home.startsWith(`${c}/`)) return;
		out.add(c);
	};
	add(path.join(root, "profiles"));
	for (const a of loadAccounts(root)) add(profileOf(root, a).geminiHome);
	const raw = readRaw(root);
	for (const d of Array.isArray(raw.removedDirs) ? raw.removedDirs : []) if (typeof d === "string" && path.isAbsolute(d) && profileMarked(d)) add(d);
	const def = path.join(home, ".gemini");
	if (profileMarked(def)) add(def);
	return [...out];
}

/** A run folder: `<pi's pid>-<6 random>`, under the profile's tmp. */
const RUN_DIR = /^(\d+)-[A-Za-z0-9]{6}$/;

/** Whether `pid` is an agy run for this profile (its command line names the profile): a pid of its own, not a reused one. */
function agyOfProfile(pid: number, geminiHome: string): boolean {
	const r = spawnSync("ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8", timeout: 2000 });
	return r.status === 0 && r.stdout.includes("acp") && r.stdout.includes(geminiHome);
}

/**
 * Cleans the run folders whose pi is gone (the name's pid): agy's process group is ended first
 * (its leader, an agy no client talks to any more, checked by its command line; or what a dead agy
 * left in its group), then the folder is removed. A folder whose pi is alive is never touched,
 * nor is anything else in tmp. Resolves once done; launches do not wait for it.
 */
export async function sweepRunDirs(tmpDir: string): Promise<void> {
	let entries: string[] = [];
	try {
		entries = fs.readdirSync(tmpDir);
	} catch {
		return;
	}
	const geminiHome = path.dirname(path.dirname(tmpDir));
	const jobs: Promise<void>[] = [];
	for (const e of entries) {
		const m = RUN_DIR.exec(e);
		if (!m || alive(Number(m[1]))) continue;
		const dir = path.join(tmpDir, e);
		let agyPid = 0;
		try {
			agyPid = Number(fs.readFileSync(path.join(dir, "agy.pid"), "utf8").trim());
		} catch {}
		if (agyPid && alive(agyPid)) {
			if (!agyOfProfile(agyPid, geminiHome)) continue; // a reused pid: not ours to end
			signalGroup(agyPid, "SIGTERM"); // an orphaned agy: its pi is gone
		}
		jobs.push(
			(async () => {
				if (agyPid) {
					for (const end = Date.now() + 3000; alive(agyPid) && Date.now() < end; ) await new Promise((r) => setTimeout(r, 25));
					if (alive(agyPid) && agyOfProfile(agyPid, geminiHome)) signalGroup(agyPid, "SIGKILL");
					// a group can only be agy's while it has members (its id is not reused before)
					if (groupAlive(agyPid)) await reapGroup(agyPid);
				}
				try {
					fs.rmSync(dir, { recursive: true, force: true });
				} catch {}
			})(),
		);
	}
	await Promise.all(jobs);
}

/** agy's own logs kept per profile (`log/acp-server-<date>-<pid>.log`, one per agy run). */
export const KEPT_LOGS = 20;
const AGY_LOG = /^acp-server-.*-(\d+)\.log$/;

/**
 * Trims agy's logs in a profile to the newest KEPT_LOGS (by mtime). Only a log whose agy (the pid in
 * its name) is gone is removed: one still running is kept, however old; anything else is left.
 * Both places agy may keep them are looked at: the profile, and its app-data folder; in a folder
 * used in place (the user's own) only the app-data folder, Deckhand's part of it.
 */
export function trimAgyLogs(p: Profile) {
	for (const dir of [...(p.inPlace ? [] : [path.join(p.geminiHome, "log")]), path.join(p.acpDir, "log")]) {
		let logs: { p: string; pid: number; t: number }[] = [];
		try {
			for (const e of fs.readdirSync(dir)) {
				const m = AGY_LOG.exec(e);
				if (!m) continue;
				const full = path.join(dir, e);
				const st = fs.lstatSync(full);
				if (st.isFile()) logs.push({ p: full, pid: Number(m[1]), t: st.mtimeMs });
			}
		} catch {
			continue;
		}
		logs.sort((x, y) => y.t - x.t);
		for (const l of logs.slice(KEPT_LOGS)) {
			if (alive(l.pid)) continue;
			try {
				fs.rmSync(l.p, { force: true });
			} catch {}
		}
	}
}

/**
 * A new agy process's own TMPDIR: `tmp/<pi's pid>-<random>`, 0700, so a pi's agy runs never share
 * temp files (agy 1.5.18 wrote nothing there before sign-in on macOS, and writes its ~1 MB of
 * builtin/, config/, databases and logs into the profile; a folder per run costs next to nothing).
 * Each launch first sweeps dead processes' leftovers (as t3code's retireAntigravityRuntimeTempDirs,
 * but by pid: several pi processes share a profile), prunes the session ledger and trims agy's
 * logs. The connection removes the folder when agy ends.
 */
export function runDir(p: Profile): string {
	fs.mkdirSync(p.tmpDir, { recursive: true, mode: 0o700 });
	void sweepRunDirs(p.tmpDir);
	pruneLedger(path.join(p.acpDir, "deckhand-sessions"));
	trimAgyLogs(p);
	return fs.mkdtempSync(path.join(p.tmpDir, `${process.pid}-`));
}

/** agy's arguments for a profile (t3code buildAntigravityAcpSpawnInput); `--login` for the code sign-in. */
export const agyArgs = (p: Profile, login = false) => ["acp", "--gemini-dir", p.geminiHome, "--app-data-dir", "antigravity-acp", ...(login ? ["--login"] : [])];

/** Whether agy keeps a saved Google sign-in in the profile (its file storage: the file is only stat'ed, never read). A display hint only: agy also reads the keychain. */
/** A saved sign-in: a regular file (a link to one too), as the core's agy_signed_in_file. */
export const hasSavedLogin = (p: Profile) => {
	try {
		return fs.statSync(path.join(p.acpDir, "acp_token.json"), { throwIfNoEntry: false })?.isFile() === true;
	} catch {
		return false; // not a folder on the way, no access: no sign-in Deckhand can see
	}
};

/**
 * Whether a Google account is known to be signed in: its saved sign-in by stat, or, for the keyring
 * account, always (the keyring is never read; agy's own error says so when it is not). A display
 * hint only: nothing is refused on it, since agy may find the keychain's sign-in for any profile.
 */
export const savedSignIn = (root: string, a: Account) => !!a.keyring || hasSavedLogin(profileOf(root, a));

/** What a stat tells of a Google account's sign-in, for the status: its file, the keychain (the keychain account), or unknown. */
export const signInHint = (root: string, a: Account): "file" | "keychain" | "none" => (hasSavedLogin(profileOf(root, a)) ? "file" : a.keyring ? "keychain" : "none");

/**
 * Makes the profile: its folders (0700), the method in settings.json (no credential), and links to
 * the user's ~/.gemini skills and rules (t3code linkAntigravityUserConfig). Returns it. A folder
 * used in place is the user's own: only its antigravity-acp/ is made (0700; one already there is
 * left as it is), nothing is linked into it and its mode is never changed; it must exist.
 */
export function prepareProfile(root: string, a: Account, home = os.homedir()): Profile {
	const p = profileOf(root, a);
	if (p.inPlace) {
		if (!fs.statSync(p.geminiHome, { throwIfNoEntry: false })?.isDirectory()) throw new Error(`The folder of the Antigravity account "${a.name}" is not there: ${p.geminiHome}`);
		for (const d of [p.acpDir, p.tmpDir]) fs.mkdirSync(d, { recursive: true, mode: 0o700 });
		writeSettings(p, a);
		return p;
	}
	for (const d of [root, path.dirname(p.geminiHome), p.geminiHome, p.acpDir, p.tmpDir]) {
		fs.mkdirSync(d, { recursive: true, mode: 0o700 });
		fs.chmodSync(d, 0o700);
	}
	writeSettings(p, a);
	linkUserConfig(p.geminiHome, path.join(home, ".gemini"));
	return p;
}

/** The sign-in method (and GCP project) in the profile's antigravity-acp/settings.json: no credential. */
function writeSettings(p: Profile, a: Account) {
	const gcp = { ...(a.gcpProject ? { project: a.gcpProject } : {}), ...(a.gcpLocation ? { location: a.gcpLocation } : {}) };
	fs.writeFileSync(path.join(p.acpDir, "settings.json"), `${JSON.stringify({ auth: { type: a.method }, ...(Object.keys(gcp).length ? { gcp } : {}) })}\n`, { mode: 0o600 });
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

export { REMOVED_ENV, secretEnvName } from "./acp.ts";
import { REMOVED_ENV, secretEnvName } from "./acp.ts";

/**
 * agy's environment for an account (t3code antigravityEnvironment): pi's, without REMOVED_ENV
 * (case-insensitively), any GOOGLE_*, Deckhand's own variables and anything that looks like a
 * secret (secretEnvName: SSH_AUTH_SOCK, proxies, locale, PATH and HOME stay); then file storage,
 * no self-update, its own TMPDIR, and the account's key when it has one. Every account but the
 * keychain one (`a.keyring`) runs in file mode, AGY_CLI_FORCE_FILE_TOKEN_STORAGE=1 (the variable agy
 * 1.5.18 reads), so its sign-in goes into its own profile and never overwrites the shared keychain
 * entry; a Google account in file mode also gets SSH_CONNECTION, so agy never opens a browser by
 * itself when it has no sign-in. The keychain account gets neither (an SSH_CONNECTION pi has is
 * passed on as it is). Login and sessions get the same environment.
 */
export function agyEnvFor(a: Account, p: Profile, apiKey: string | undefined, base: NodeJS.ProcessEnv = process.env, tmpDir = p.tmpDir): NodeJS.ProcessEnv { // env-read-ok: agy's environment is pi's, filtered (REMOVED_ENV)
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
		if (REMOVED_ENV.has(K) || K.startsWith("GOOGLE_") || K.startsWith("DECKHAND_") || secretEnvName(K)) continue;
		env[k] = v;
	}
	const key = apiKey?.trim();
	return {
		...env,
		...(key && a.method === "gemini-api-key" ? { GEMINI_API_KEY: key } : {}),
		...(key && a.method === "agent-platform" ? { GOOGLE_API_KEY: key } : {}),
		...(a.method === "oauth-personal" && !a.keyring ? { SSH_CONNECTION: base.SSH_CONNECTION || "127.0.0.1 0 127.0.0.1 0" } : {}),
		...(a.keyring ? {} : { AGY_CLI_FORCE_FILE_TOKEN_STORAGE: "1" }),
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
	return a.name === "default" ? "/antigravity login" : `/antigravity login ${a.name}`;
}
export const notSignedIn = (a: Account) =>
	`Antigravity account "${a.name}" is not signed in: run ${signInCommand(a)}`;

/** An account's approvals mode as accounts.json has it now (another pi may have changed it): `allow` unless set to `ask`. */
export function approvalsOf(root: string, name: string): ApprovalMode {
	return storedAccounts(root).find((a) => a.name === name)?.approvals === "ask" ? "ask" : "allow";
}
