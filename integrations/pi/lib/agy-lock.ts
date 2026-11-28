// A lock file taken atomically, for agy-ledger.ts (an agy session's holder) and agy-accounts.ts
// (accounts.json's writer). The lock's content ({pid}) is written to a temp file first and
// hard-linked into place, so it appears whole or not at all, and only when no lock is there. A
// stale lock is taken over by renaming it aside under a unique name, checking that the file moved
// is the one seen stale (its inode), and only then linking ours: two processes taking over one
// stale lock, or one taking over a lock another process has just taken, never both hold it.
import fs from "node:fs";
import path from "node:path";

/** What a lock file holds as seen: its holder's pid (undefined: no content yet), its inode and age. */
export interface LockSeen {
	pid?: number;
	ino: number;
	mtimeMs: number;
}

/** A lock with no content yet is being written: held until it is older than this. */
export const EMPTY_LOCK_GRACE_MS = 2000;

export function readLock(p: string): LockSeen | undefined {
	let st: fs.Stats;
	try {
		st = fs.statSync(p);
	} catch {
		return undefined;
	}
	let pid: number | undefined;
	try {
		const n = Number(JSON.parse(fs.readFileSync(p, "utf8"))?.pid);
		if (Number.isInteger(n) && n > 0) pid = n;
	} catch {}
	return { pid, ino: st.ino, mtimeMs: st.mtimeMs };
}

const rand = () => Math.random().toString(36).slice(2, 10);

/**
 * Takes lock `p` for this process; false when someone holds it. `stale(seen)` says whether a lock
 * seen there may be taken over (its holder is gone); a lock with no content is never stale before
 * EMPTY_LOCK_GRACE_MS.
 */
export function tryLock(p: string, stale: (seen: LockSeen) => boolean): boolean {
	fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
	const mine = `${p}.new-${process.pid}-${rand()}`;
	fs.writeFileSync(mine, JSON.stringify({ pid: process.pid }), { mode: 0o600 });
	try {
		for (let attempt = 0; attempt < 4; attempt++) {
			try {
				fs.linkSync(mine, p);
				return true;
			} catch (e: any) {
				if (e?.code !== "EEXIST") throw e;
			}
			const seen = readLock(p);
			if (!seen) continue; // gone meanwhile: try again
			const old = seen.pid === undefined ? Date.now() - seen.mtimeMs > EMPTY_LOCK_GRACE_MS : stale(seen);
			if (!old) return false;
			const aside = `${p}.stale-${process.pid}-${rand()}`;
			try {
				fs.renameSync(p, aside);
			} catch {
				continue; // someone else moved it first
			}
			const moved = readLock(aside);
			if (!moved || moved.ino !== seen.ino) {
				// not the stale lock seen: another process took it in the meantime. Put it back (if no
				// third lock appeared there since) and give way.
				try {
					fs.linkSync(aside, p);
				} catch {}
				fs.rmSync(aside, { force: true });
				return false;
			}
			fs.rmSync(aside, { force: true });
		}
		return false;
	} finally {
		fs.rmSync(mine, { force: true });
	}
}

/** Removes lock `p` when this process holds it. */
export function unlock(p: string) {
	if (readLock(p)?.pid !== process.pid) return;
	try {
		fs.rmSync(p, { force: true });
	} catch {}
}
