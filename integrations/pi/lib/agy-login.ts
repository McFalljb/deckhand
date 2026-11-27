// /antigravity-login: Google sign-in through agy's own `agy acp --login` (t3code's code login,
// Drivers/AntigravityDriver.ts codeLogin). agy prints an accounts.google.com link; the user opens
// it, signs in, and pastes back the code the Antigravity page shows; agy exchanges it and stores the
// credential itself. Deckhand only passes the link and the code along: it never sees, reads or
// stores a token. The link and the code are checked as t3code checks them
// (antigravityAuthSupport.ts parseAntigravityAuthorizationUrl, antigravityLoginResponse).
import { type ChildProcess, spawn } from "node:child_process";
import { agyEnv, SIGN_IN_PREFIX } from "./acp.ts";

const MAX_URL = 16_384;
/** Where `agy acp --login` sends Google; the page there shows the code. */
export const CODE_REDIRECT_URI = "https://antigravity.google/oauth-callback";

export interface SignInLink {
	url: string;
	redirectUri: string;
	state: string;
}

/** agy's sign-in link when it is a well-formed Google code-flow link, else undefined. */
export function parseSignInLink(s: string): SignInLink | undefined {
	if (s.length > MAX_URL || /\s/.test(s)) return undefined;
	let u: URL;
	try {
		u = new URL(s);
	} catch {
		return undefined;
	}
	const one = (k: string) => (u.searchParams.getAll(k).length === 1 ? u.searchParams.get(k)! : undefined);
	const state = one("state"), redirect = one("redirect_uri");
	if (u.origin !== "https://accounts.google.com" || !["/o/oauth2/auth", "/o/oauth2/v2/auth"].includes(u.pathname) || u.username || u.password || u.hash) return undefined;
	if (one("response_type") !== "code" || !state || state.length > 512 || !redirect) return undefined;
	return { url: s, redirectUri: redirect, state };
}

/** The link in one line of `agy acp --login`'s output (bare, or after agy's ACP sign-in prefix). */
export function linkInLine(line: string): SignInLink | undefined {
	let s = line.trim();
	if (s.startsWith(SIGN_IN_PREFIX)) s = s.slice(SIGN_IN_PREFIX.length).trim();
	return s.startsWith("https://accounts.google.com/") ? parseSignInLink(s) : undefined;
}

/** What may be written to agy's stdin: the page's code, or the page's URL answering this sign-in. One line. */
export function loginAnswer(link: SignInLink, answer: string): string | undefined {
	const v = answer.trim();
	if (/^[\w./~-]{1,2048}$/.test(v)) return v;
	if (v.length > MAX_URL || /\s/.test(v)) return undefined;
	let u: URL;
	try {
		u = new URL(v);
	} catch {
		return undefined;
	}
	const ok = `${u.origin}${u.pathname}` === link.redirectUri && !u.username && !u.password && u.searchParams.getAll("state").length === 1 && u.searchParams.get("state") === link.state && u.searchParams.getAll("code").length === 1 && !!u.searchParams.get("code");
	return ok ? v : undefined;
}

export interface LoginOptions {
	agyPath: string;
	cwd: string;
	env?: NodeJS.ProcessEnv;
	/** agy's arguments, `--login` included (the account's profile: agyArgs(p, true)). */
	args?: string[];
	/** Shows the link to the user. */
	showLink: (url: string) => void;
	/** Asks for the code; undefined or empty cancels. */
	askCode: () => Promise<string | undefined>;
	linkTimeoutMs?: number;
	finishTimeoutMs?: number;
	spawnImpl?: typeof spawn;
}

export type LoginResult = { ok: true } | { ok: false; error: string };

/** Runs `agy acp --login` to the end. Never throws. */
export async function agyLogin(o: LoginOptions): Promise<LoginResult> {
	let child: ChildProcess;
	try {
		child = (o.spawnImpl ?? spawn)(o.agyPath, o.args ?? ["acp", "--login"], { cwd: o.cwd, env: o.env ?? agyEnv(), stdio: ["pipe", "pipe", "pipe"] });
	} catch (e) {
		return { ok: false, error: `Antigravity (agy) could not start: ${(e as Error).message}` };
	}
	const exited = new Promise<number | null>((resolve) => {
		child.on("close", (code) => resolve(code)); // after stdout is read to its end
		child.on("error", () => resolve(-1));
	});
	child.stdin!.on("error", () => {});
	child.stderr!.resume(); // agy's log stays out of pi
	const link = await new Promise<SignInLink | undefined>((resolve) => {
		let buf = "";
		const timer = setTimeout(() => resolve(undefined), o.linkTimeoutMs ?? 30_000);
		child.stdout!.setEncoding("utf8");
		child.stdout!.on("data", (s: string) => {
			buf = (buf + s).slice(-MAX_URL * 2);
			const lines = buf.split("\n");
			buf = lines.pop() ?? "";
			for (const l of lines) {
				const found = linkInLine(l);
				if (found) {
					clearTimeout(timer);
					resolve(found);
				}
			}
		});
		void exited.then(() => {
			clearTimeout(timer);
			resolve(undefined);
		});
	});
	const stop = async () => {
		if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
		await exited;
	};
	if (!link) {
		await stop();
		return { ok: false, error: "Antigravity (agy) gave no Google sign-in link" };
	}
	o.showLink(link.url);
	let answer: string | undefined;
	try {
		answer = await o.askCode();
	} catch {
		answer = undefined;
	}
	if (!answer?.trim()) {
		await stop();
		return { ok: false, error: "Sign-in cancelled" };
	}
	const line = loginAnswer(link, answer);
	if (!line) {
		await stop();
		return { ok: false, error: "That is not a code from the Antigravity sign-in page: run /antigravity-login again" };
	}
	child.stdin!.write(`${line}\n`);
	const timer = setTimeout(() => child.kill("SIGTERM"), o.finishTimeoutMs ?? 120_000);
	const code = await exited;
	clearTimeout(timer);
	return code === 0 ? { ok: true } : { ok: false, error: "Antigravity could not finish the Google sign-in: run /antigravity-login again" };
}
