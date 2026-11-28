// The files and folders Deckhand never lets an agent read or change, by name: a port of the core's
// credential_path (src/core/settings_files.odin, claude_reload.odin claude_credential, codex.odin
// codex_credential, agy_accounts.odin agy_credential), rule for rule, so pi's antigravity
// extension refuses what Deckhand refuses. tests/credential-paths/cases.json is read by both
// sides' tests (integrations/pi/test/agy-approvals.test.ts, src/settings_files_test.odin).
//
// Not ported: other names for pi's sign-in files (hard links: the core compares the device and
// inode), and Claude Code or Codex accounts that only Deckhand's own lists name (a folder that
// holds Claude's sign-in or account file is found by its marks all the same). Never by a file's
// mode: a umask of 077 makes every file 0600.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { dataRoot, profileDirs, profileMarked } from "./agy-accounts.ts";

/** pi's sign-ins at the top of its agent dir (cursor-sdk*.json and intercom/ apart). */
const PI_SIGN_IN_FILES = new Set(["auth.json", "oauth.json", "mcp-auth.json", "models-store.json"]);
/** Folders (lower case) whose files are secrets: named for them, or where tools keep theirs. */
const SECRET_FOLDERS = new Set(["credential", "credentials", "secret", "secrets", "token", "tokens", ".secret", ".secrets", ".ssh", ".gnupg", ".aws", ".azure", ".docker", ".kube", ".git", ".password-store"]);
/** Dotfiles (lower case) that hold secrets, besides .env and .env.*. */
const SECRET_DOTFILES = new Set([".npmrc", ".netrc", ".pypirc", ".git-credentials", ".pgpass", ".htpasswd", ".dockercfg", ".s3cfg", ".boto"]);
/** Extensions of data files: there a name with token, secret or credential is taken for one. */
const DATA_EXTENSIONS = new Set(["", ".json", ".jsonl", ".txt", ".yaml", ".yml", ".toml", ".ini", ".env", ".conf", ".cfg"]);
/** Claude Code's own config in its folder: these files at the top, these folders. */
const CLAUDE_CONFIG_FILES = new Set(["settings.json", "settings.local.json", "CLAUDE.md", "keybindings.json"]);
const CLAUDE_CONFIG_FOLDERS = new Set(["agents", "skills", "commands", "output-styles", "rules", "hooks", "themes", "workflows"]);
/** Codex's own config (and hooks, shown read-only) in its home. */
const CODEX_CONFIG_FILES = new Set(["config.toml", "AGENTS.md", "AGENTS.override.md", "hooks.json"]);
const CODEX_CONFIG_FOLDERS = new Set(["prompts", "skills", "rules", "hooks"]);
/** agy's and Gemini's sign-ins by name anywhere. */
export const AGY_TOKEN_FILES = new Set(["acp_token.json", "oauth_creds.json", "google_accounts.json"]);

/** Whether a folder name (lower case) is one for secrets. */
export const secretFolder = (name: string) => SECRET_FOLDERS.has(name);

/** Whether a file name (lower case) looks like it holds a secret (the core's secret_looking_name). */
export function secretLookingName(name: string): boolean {
	if (name === ".env" || name.startsWith(".env.")) return true;
	if (SECRET_DOTFILES.has(name)) return true;
	if (name.startsWith("id_")) return true;
	if ([".key", ".pem", ".p12"].some((e) => name.endsWith(e))) return true;
	const ext = name.startsWith(".") && name.split(".").length === 2 ? "" : path.extname(name);
	if (!DATA_EXTENSIONS.has(ext)) return false;
	return ["token", "secret", "credential"].some((w) => name.includes(w));
}

/** The real path of `p`, or of its deepest existing folder with the rest appended; undefined on an error other than "not found". */
export function canonical(p: string): string | undefined {
	const rest: string[] = [];
	let at = p;
	for (;;) {
		try {
			return path.join(fs.realpathSync.native(at), ...rest);
		} catch (e: any) {
			if (e?.code !== "ENOENT") return undefined;
		}
		const up = path.dirname(at);
		if (up === at) return undefined;
		rest.unshift(path.basename(at));
		at = up;
	}
}

const under = (p: string, dir: string) => dir !== "" && p.length > dir.length && p.startsWith(dir) && p[dir.length] === "/";
const isFile = (p: string) => fs.statSync(p, { throwIfNoEntry: false })?.isFile() === true;
const expandHome = (d: string, home: string) => (d === "~" ? home : d.startsWith("~/") ? path.join(home, d.slice(2)) : d);
const both = (d: string) => [...new Set([d, canonical(d) ?? d])];
/** A user's home folder (another user's, or this one's when HOME is elsewhere). */
const userHome = (d: string) => {
	const parent = path.dirname(d);
	return parent === "/Users" || parent === "/home" || d === "/root" || d === "/var/root";
};

interface Where {
	home: string;
	homes: string[];
	agentDirs: string[];
	claudeDirs: string[];
	codexHomes: string[];
	codexAuth: string;
	agyDirs: string[];
	agyProfiles: string[];
	agyData: string[];
}

// env-read-ok: HOME, PI_CODING_AGENT_DIR, CLAUDE_CONFIG_DIR, CODEX_HOME by name
function whereOf(env: NodeJS.ProcessEnv): Where {
	const home = path.resolve(env.HOME || os.homedir());
	const homes = both(home);
	const tooHigh = (d: string) => d === "/" || homes.some((h) => d === h || under(h, d));
	const agentDir = path.resolve(expandHome(env.PI_CODING_AGENT_DIR || path.join(home, ".pi", "agent"), home));
	const claude = [path.join(home, ".claude"), ...(env.CLAUDE_CONFIG_DIR && path.isAbsolute(env.CLAUDE_CONFIG_DIR) ? [path.resolve(env.CLAUDE_CONFIG_DIR)] : [])];
	const codexEnv = env.CODEX_HOME && path.isAbsolute(env.CODEX_HOME) ? path.resolve(env.CODEX_HOME) : undefined;
	const codex = [path.join(home, ".codex"), ...(codexEnv ? [codexEnv] : [])].filter((d) => !tooHigh(d));
	const root = dataRoot(env);
	return {
		home,
		homes,
		agentDirs: both(agentDir),
		claudeDirs: claude.flatMap(both),
		codexHomes: codex.flatMap(both),
		codexAuth: codexEnv ? path.join(codexEnv, "auth.json") : path.join(home, ".codex", "auth.json"),
		agyDirs: profileDirs(root, env).flatMap(both),
		agyProfiles: both(path.join(root, "profiles")),
		agyData: both(root),
	};
}

const homeOrAbove = (d: string, w: Where) => d === "" || d === "/" || d === "." || w.homes.some((h) => d === h || under(h, d));

function agentRule(p: string, w: Where): boolean {
	const lp = p.toLowerCase();
	for (const ad of w.agentDirs) {
		const a = ad.toLowerCase().replace(/\/+$/, "");
		if (!a || !lp.startsWith(`${a}/`)) continue;
		const rel = lp.slice(a.length + 1);
		if (rel === "intercom" || rel.startsWith("intercom/")) return true;
		if (!rel.includes("/") && (PI_SIGN_IN_FILES.has(rel) || (rel.startsWith("cursor-sdk") && rel.endsWith(".json")))) return true;
		const parts = rel.split("/");
		if (parts.some((part, i) => (i === parts.length - 1 ? secretLookingName(part) : secretFolder(part)))) return true;
	}
	return false;
}

function claudeEntry(p: string, c: string): boolean {
	const rel = p.slice(c.length + 1);
	const i = rel.indexOf("/");
	const first = i < 0 ? rel : rel.slice(0, i);
	return CLAUDE_CONFIG_FOLDERS.has(first) || (i < 0 && CLAUDE_CONFIG_FILES.has(first));
}

function claudeRule(p: string, w: Where): boolean {
	const base = path.basename(p).toLowerCase();
	if (base === ".credentials.json" || base === ".claude.json" || base.startsWith(".claude.json.")) return true;
	for (const c of w.claudeDirs) if (!homeOrAbove(c, w) && under(p, c)) return !claudeEntry(p, c);
	for (let d = path.dirname(p); !homeOrAbove(d, w); d = path.dirname(d)) {
		if (userHome(d)) continue;
		if (isFile(path.join(d, ".credentials.json")) || isFile(path.join(d, ".claude.json"))) return !claudeEntry(p, d);
	}
	return false;
}

function codexRule(p: string, w: Where): boolean {
	if (path.basename(p).toLowerCase() === "auth.json" && path.basename(path.dirname(p)).toLowerCase() === ".codex") return true;
	const ra = canonical(w.codexAuth);
	if (p === w.codexAuth || (ra && (p === ra || canonical(p) === ra))) return true;
	for (const c of w.codexHomes) {
		if (!under(p, c)) continue;
		const rel = p.slice(c.length + 1);
		const i = rel.indexOf("/");
		const first = i < 0 ? rel : rel.slice(0, i);
		if (!(CODEX_CONFIG_FOLDERS.has(first) || (i < 0 && CODEX_CONFIG_FILES.has(first)))) return true;
	}
	return false;
}

/** The user's own config agy reads in a profile: GEMINI.md and AGENTS.md at its top, its skills. */
function agyEntry(p: string, d: string): boolean {
	const rel = p.slice(d.length + 1);
	return rel === "GEMINI.md" || rel === "AGENTS.md" || rel === "config/skills.json" || rel.startsWith("config/skills/") || rel.startsWith("antigravity-cli/skills/");
}

function agyRule(p: string, w: Where): boolean {
	if (AGY_TOKEN_FILES.has(path.basename(p).toLowerCase())) return true;
	for (const c of w.agyDirs) {
		if (homeOrAbove(c, w) || !under(p, c)) continue;
		if (w.agyProfiles.includes(c)) return true; // all of Deckhand's own profiles
		if (!agyEntry(p, c)) return true; // a profile nested in the config is looked for below
	}
	for (let d = path.dirname(p); !homeOrAbove(d, w); d = path.dirname(d)) {
		if (userHome(d)) continue;
		if (profileMarked(d) && !agyEntry(p, d)) return true;
	}
	return false;
}

/** Whether `p` (absolute; as written and real) is a credential file: the core's settings_credential by name. */
export function credentialPath(p: string, env: NodeJS.ProcessEnv = process.env): boolean { // env-read-ok: whereOf's names
	const w = whereOf(env);
	const abs = path.resolve(p);
	for (const c of both(abs)) if (agentRule(c, w) || claudeRule(c, w) || codexRule(c, w) || agyRule(c, w)) return true;
	return false;
}

/**
 * Whether `p` is a folder that holds credentials, or lies inside one: a Codex home, an agy profile
 * (Deckhand's profiles folder included), any `.ssh`, and pi's agent dir at its top and in its
 * sign-in folders (`intercom/`, a secret folder by name): not in `extensions/` and the like, where
 * each file is judged by its name (credentialPath), as in the core. A read of such a folder (a
 * listing) or a search in it is refused whole: what it would list or match is not known.
 */
export function credentialFolder(p: string, env: NodeJS.ProcessEnv = process.env): boolean { // env-read-ok: whereOf's names
	const w = whereOf(env);
	for (const c of both(path.resolve(p))) {
		if (c.split("/").some((part) => part.toLowerCase() === ".ssh")) return true;
		for (const d of [...w.codexHomes, ...w.agyDirs, ...w.agyProfiles]) if (!homeOrAbove(d, w) && (c === d || under(c, d))) return true;
		for (const ad of w.agentDirs) {
			if (homeOrAbove(ad, w)) continue;
			if (c === ad) return true;
			if (!under(c, ad)) continue;
			const parts = c.slice(ad.length + 1).toLowerCase().split("/");
			if (parts[0] === "intercom" || parts.some(secretFolder)) return true;
		}
	}
	return false;
}

/**
 * The first folder holding credentials that a search rooted at `root` would reach (it lies below
 * the root): pi's agent dir, a Codex home, Deckhand's antigravity data folder and every agy
 * profile, `~/.ssh`. Undefined when none does. Shown with `~` for the home folder.
 */
export function credentialFolderBelow(root: string, env: NodeJS.ProcessEnv = process.env): string | undefined { // env-read-ok: whereOf's names
	const w = whereOf(env);
	const named: [string, string][] = [
		...w.agentDirs.map((d) => [d, "pi's credential folder"] as [string, string]),
		...w.codexHomes.map((d) => [d, "Codex's folder"] as [string, string]),
		...w.agyData.map((d) => [d, "Deckhand's Antigravity folder"] as [string, string]),
		...w.agyDirs.map((d) => [d, "an Antigravity profile"] as [string, string]),
		...both(path.join(w.home, ".ssh")).map((d) => [d, "the SSH folder"] as [string, string]),
	];
	const shown = (d: string) => {
		const h = w.homes.find((x) => under(d, x));
		return h ? `~${d.slice(h.length)}` : d;
	};
	for (const r of both(path.resolve(root)))
		for (const [d, what] of named) if (!homeOrAbove(d, w) && under(d, r)) return `${what} ${shown(d)}`;
	return undefined;
}
