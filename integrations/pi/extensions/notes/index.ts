/**
 * Deckhand's optional notes reminder (Settings → pi extensions; off by default), from pi-kit's
 * extensions/notes. When the context passes PI_KIT_NOTES_REMIND_PERCENT (default 75; 0 turns it
 * off) of the window, one note asks the session to rewrite its session note's status block before
 * pi compacts. Re-arms after each compaction. Not in pi-subagents children.
 *
 * - No paths of its own: the note names the notes folder only when PI_KIT_NOTES_DIR is set (Deckhand
 *   sets it to the main folder, or passes the user's own: folders.odin), and the session decides
 *   whether it keeps a note at all (pi-kit's session-notes skill, the user's AGENTS.md).
 * - Timing: due on a turn that ran tools (the run goes on) and passed the threshold; sent at the
 *   next turn_start or agent_end, never starting a turn (a final answer is never followed by an
 *   extra turn). One turn later than pi-kit's, which sends from turn_end: that is how it steps back.
 * - Next to pi-kit's notes (the same threshold, so it fires on the same turn_end): pi appends the
 *   messages turn_end handlers queued after all of them ran (agent-session's
 *   _flushPendingCustomMessages), so pi-kit's reminder is on the session branch before ours is due;
 *   finding it there, ours drops its own and stays quiet for good. So does an extension that claims
 *   NOTES_CAP (lib/claims.ts).
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { CAPS_CLAIM, CAPS_QUERY, NOTES_CAP, parseClaim } from "../../lib/claims.ts";

export const NOTES_TYPE = "deckhand-notes";
const KIT_NOTES_TYPE = "pi-kit-notes"; // pi-kit's reminder

/** The reminder's text: the notes folder only when PI_KIT_NOTES_DIR names one. */
export function reminderText(percent: number, notesDir: string | undefined): string {
	const where = notesDir ? ` (in ${notesDir})` : "";
	return `Context is ${percent.toFixed(1)}% full and will be compacted soon. If this session keeps a session note${where}, rewrite its status block now: goal, in flight (ids, output paths), waiting on the user, next step. Then carry on.`;
}

export default function notes(pi: ExtensionAPI) {
	const raw = process.env.PI_KIT_NOTES_REMIND_PERCENT;
	const PERCENT = raw ? Number(raw) : 75;
	if (process.env.PI_SUBAGENT_CHILD === "1" || !(PERCENT > 0)) return;
	let reminded = false; // since the last compaction
	let due: number | undefined; // the context percent of a reminder not sent yet
	let mark = 0; // the branch's length when it became due
	let other = false; // another notes reminder is loaded: this one stays quiet

	pi.events.on(CAPS_CLAIM, (c) => {
		if (parseClaim(c)?.capability === NOTES_CAP) other = true;
	});
	pi.on("session_start", () => {
		pi.events.emit(CAPS_QUERY, { from: "deckhand", capabilities: [NOTES_CAP] });
	});
	pi.on("session_compact", () => {
		reminded = false;
		due = undefined;
	});
	pi.on("turn_end", (event, ctx) => {
		if (other || reminded || !event.toolResults.length) return;
		const percent = ctx.getContextUsage()?.percent;
		if (percent == null || percent < PERCENT) return;
		reminded = true;
		due = percent;
		mark = branch(ctx).length;
	});
	const branch = (ctx: ExtensionContext): unknown[] => {
		try {
			return ctx.sessionManager.getBranch() ?? [];
		} catch {
			return [];
		}
	};
	const send = (_e: unknown, ctx: ExtensionContext) => {
		if (due === undefined) return;
		// pi-kit's reminder since it became due: it covers this one, and every later one
		const kit = branch(ctx).slice(mark).some((x) => (x as { type?: string; customType?: string })?.type === "custom_message" && (x as { customType?: string }).customType === KIT_NOTES_TYPE);
		if (kit) other = true;
		if (other) return void (due = undefined);
		const percent = due;
		due = undefined;
		// triggerTurn false: during a run, appended at the end of this turn; after it, at once
		pi.sendMessage({ customType: NOTES_TYPE, display: true, content: reminderText(percent, process.env.PI_KIT_NOTES_DIR || undefined), details: undefined }, { triggerTurn: false });
	};
	pi.on("turn_start", send);
	pi.on("agent_end", send);
}
