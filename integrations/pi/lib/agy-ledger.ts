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

export interface Ledger {
	/** The answers recorded for an agy session, or undefined when Deckhand never drove it here. */
	read(sessionId: string): Produced[] | undefined;
	write(sessionId: string, produced: Produced[]): void;
	/** Whether `owner` may take the session (nobody else alive holds it). */
	free(sessionId: string, owner: object): boolean;
	/** Takes the session for `owner`; false when someone else holds it. */
	claim(sessionId: string, owner: object): boolean;
	release(sessionId: string, owner: object): void;
}

export function fileLedger(dir: string): Ledger {
	const key = (id: string) => createHash("sha256").update(id).digest("hex").slice(0, 32);
	const file = (id: string) => path.join(dir, `${key(id)}.json`);
	const lock = (id: string) => path.join(dir, `${key(id)}.lock`);
	const holderPid = (p: string): number | undefined => {
		try {
			return Number(JSON.parse(fs.readFileSync(p, "utf8"))?.pid);
		} catch {
			return undefined;
		}
	};
	/** Someone else holds it: another owner in this process, or another live process. */
	const taken = (id: string, owner: object) => {
		const p = lock(id);
		const held = HELD.get(p);
		if (held) return held !== owner;
		if (!fs.existsSync(p)) return false;
		const pid = holderPid(p);
		return pid !== undefined && pid !== process.pid && alive(pid);
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
			if (HELD.get(p) === owner) return true;
			if (taken(id, owner)) return false;
			try {
				fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
				fs.rmSync(p, { force: true }); // stale: its process is gone (or it is this process's own, unheld)
				fs.writeFileSync(p, JSON.stringify({ pid: process.pid }), { flag: "wx", mode: 0o600 });
			} catch {
				return false; // another process took it in between
			}
			HELD.set(p, owner);
			return true;
		},
		release(id, owner) {
			const p = lock(id);
			if (HELD.get(p) !== owner) return;
			HELD.delete(p);
			try {
				if (holderPid(p) === process.pid) fs.rmSync(p, { force: true });
			} catch {}
		},
	};
}
