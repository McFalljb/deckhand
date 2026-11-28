// Deckhand's record of the agy sessions it drove, per account profile (`<profile>/antigravity-acp/
// deckhand-sessions/`): which answers each session holds, and which pi session holds it now. It is
// what lets a turn pick an agy session up again (session/resume) only when that session holds
// exactly the transcript's turns, and never from two pi sessions at once (review finding 1).
//
// - `<key>.json` {sessionId, produced: [{ts, ok}…]}: the answers in that agy session, oldest first
//   (an answer is known by its timestamp, as in planTurn). Written whole, temp file then rename.
// - `<key>.lock` {pid}: the session is held by a pi session in process `pid`. Taken with O_EXCL;
//   one whose process is gone is stale and taken over. Within one process the holder is tracked
//   in memory (several pi sessions, several providers).
// Never agy's own files: Deckhand does not read those.
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { Produced } from "./antigravity.ts";
import { EMPTY_LOCK_GRACE_MS, readLock, tryLock, unlock as unlockFile } from "./agy-lock.ts";

const KEEP = 200;

/** Which in-process owner holds each lock file (shared by every provider in this process). */
const HELD: Map<string, object> = ((globalThis as any)[Symbol.for("deckhand.antigravity.held")] ??= new Map());

/** Whether process `pid` exists (EPERM: it does, owned by someone else). */
export function alive(pid: number): boolean {
	if (!Number.isInteger(pid) || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (e: any) {
		return e?.code === "EPERM";
	}
}

/** A session record not written for this long is pruned (its agy session is not picked up after that: a new one, caught up). */
export const RECORD_MAX_AGE_MS = 30 * 86_400_000;
/** Lock temp files (agy-lock.ts) left by a process that died mid-way are pruned after this. */
const TEMP_MAX_AGE_MS = 3_600_000;

/**
 * Prunes a ledger folder (lib/agy-accounts.ts runs it with each launch's sweep): records unused for
 * RECORD_MAX_AGE_MS (unless a live process holds their session), locks whose process is gone (and
 * that no owner in this process holds), and old lock temp files.
 */
export function pruneLedger(dir: string, now = Date.now()) {
	let entries: string[] = [];
	try {
		entries = fs.readdirSync(dir);
	} catch {
		return;
	}
	const root = path.resolve(dir);
	const live = (lockPath: string) => {
		if (HELD.has(lockPath)) return true;
		const seen = readLock(lockPath);
		if (!seen) return false;
		if (seen.pid === undefined) return now - seen.mtimeMs <= EMPTY_LOCK_GRACE_MS;
		return alive(seen.pid);
	};
	for (const e of entries) {
		const p = path.join(root, e);
		try {
			if (/\.lock$/.test(e)) {
				if (!live(p)) fs.rmSync(p, { force: true });
			} else if (/\.json$/.test(e)) {
				if (now - fs.statSync(p).mtimeMs > RECORD_MAX_AGE_MS && !live(p.replace(/\.json$/, ".lock"))) fs.rmSync(p, { force: true });
			} else if (/\.(lock\.(new|stale)|json\.tmp)-/.test(e)) {
				if (now - fs.statSync(p).mtimeMs > TEMP_MAX_AGE_MS) fs.rmSync(p, { force: true });
			}
		} catch {}
	}
}

export interface Ledger {
	/** The answers recorded for an agy session, or undefined when Deckhand never drove it here. */
	read(sessionId: string): Produced[] | undefined;
	write(sessionId: string, produced: Produced[]): void;
	/** Whether `owner` may take the session (nobody else alive holds it). */
	free(sessionId: string, owner: object): boolean;
	/** Takes the session for `owner`; false when someone else holds it. */
	claim(sessionId: string, owner: object): boolean;
	release(sessionId: string, owner: object): void;
	/** Gives up every session `owner` holds in this ledger. */
	releaseAll(owner: object): void;
}

export function fileLedger(dir: string): Ledger {
	const key = (id: string) => createHash("sha256").update(id).digest("hex").slice(0, 32);
	const file = (id: string) => path.join(dir, `${key(id)}.json`);
	const lock = (id: string) => path.join(path.resolve(dir), `${key(id)}.lock`);
	/** Someone else holds it: another owner in this process, or another live process (or one still writing its lock). */
	const taken = (id: string, owner: object) => {
		const p = lock(id);
		const held = HELD.get(p);
		if (held) return held !== owner;
		const seen = readLock(p);
		if (!seen) return false;
		if (seen.pid === undefined) return Date.now() - seen.mtimeMs <= EMPTY_LOCK_GRACE_MS;
		return seen.pid !== process.pid && alive(seen.pid);
	};
	const unlock = (p: string, owner: object) => {
		if (HELD.get(p) !== owner) return;
		HELD.delete(p);
		unlockFile(p);
	};
	return {
		read(id) {
			try {
				const r = JSON.parse(fs.readFileSync(file(id), "utf8"));
				if (r?.sessionId !== id || !Array.isArray(r.produced)) return undefined;
				return r.produced.filter((x: any) => typeof x?.ts === "number").map((x: any) => ({ ts: x.ts, ok: !!x.ok }));
			} catch {
				return undefined;
			}
		},
		write(id, produced) {
			try {
				fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
				const tmp = `${file(id)}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`;
				fs.writeFileSync(tmp, JSON.stringify({ sessionId: id, produced: produced.slice(-KEEP) }), { mode: 0o600 });
				fs.renameSync(tmp, file(id));
			} catch {}
		},
		free: (id, owner) => !taken(id, owner),
		claim(id, owner) {
			const p = lock(id);
			const held = HELD.get(p);
			if (held) return held === owner;
			// stale: a dead process's, or this process's own that no owner holds any more
			const ok = tryLock(p, (seen) => (seen.pid === process.pid ? !HELD.has(p) : !alive(seen.pid!)));
			if (ok) HELD.set(p, owner);
			return ok;
		},
		release(id, owner) {
			unlock(lock(id), owner);
		},
		releaseAll(owner) {
			for (const [p, held] of [...HELD]) if (held === owner && path.dirname(p) === path.resolve(dir)) unlock(p, owner);
		},
	};
}
