// The `antigravity` tool (extensions/antigravity): any pi model hands a self-contained task to a
// fresh agy session and gets agy's final answer back. The session is the same as a tab's
// (lib/agy.ts): the account's profile and environment, Deckhand's identity, no fs or terminal
// capability, every permission request and question declined, agy's `default` mode set and
// confirmed before the prompt goes out (fail closed), abort sends session/cancel. One session per
// call, closed at the end: nothing is resumed or kept.
import { type AgySession, ModeUnconfirmed } from "./agy.ts";

export const DELEGATE_TOOL = "antigravity";
export const DELEGATE_DESCRIPTION =
	"Hand a self-contained task to Google Antigravity (the user's own agy CLI, on one of their signed-in accounts) and get its final answer. It runs in a fresh Antigravity session in this tab's folder, with no memory of this conversation: put everything it needs in `task`. Antigravity uses its own tools (reading files, searching); it cannot be granted approvals, so actions that need one are declined. Use it for a second opinion or a separate piece of work, not for edits you can make yourself.";
const CANCEL_WAIT_MS = 10_000;
const PROGRESS_MAX = 4000;

const clip1 = (s: unknown, n = 80) => {
	const t = String(s ?? "").replace(/\s+/g, " ").trim();
	return t.length > n ? `${t.slice(0, n - 1)}…` : t;
};

export interface DelegateRun {
	/** Opens the session (AgySession.open with the account's launch), routing its updates and agent requests here. */
	open: (onUpdate: (params: any) => void, onAgentRequest: (method: string, params: any) => void) => Promise<AgySession>;
	task: string;
	model?: string;
	signal?: AbortSignal;
	/** The progress so far (tool calls, plan, the answer's tail). */
	progress?: (text: string) => void;
}

/** Runs the task; resolves with agy's final text (and what was declined). Throws on a failure or an abort. */
export async function delegate(o: DelegateRun): Promise<string> {
	if (o.signal?.aborted) throw new Error("Antigravity task cancelled");
	let text = "";
	const notes: string[] = [];
	const declined: string[] = [];
	let modeLeft = false;
	let agy: AgySession | undefined;
	const show = () => {
		const body = [...notes.slice(-12), text ? `\n${text}` : ""].join("\n").trim();
		o.progress?.(body.length > PROGRESS_MAX ? `…${body.slice(-PROGRESS_MAX)}` : body);
	};
	const onUpdate = (p: any) => {
		const u = p?.update;
		switch (u?.sessionUpdate) {
			case "agent_message_chunk":
				if (u.content?.type === "text") text += String(u.content.text ?? "");
				break;
			case "tool_call":
				notes.push(`→ ${clip1(u.title || u.kind || "a tool")}`);
				break;
			case "plan":
				if (Array.isArray(u.entries) && u.entries.length) notes.push(`Plan: ${u.entries.map((e: any) => clip1(e?.content, 40)).join("; ")}`);
				break;
			case "current_mode_update":
			case "config_option_update":
				if (agy?.currentMode && agy.currentMode !== "default") modeLeft = true;
				break;
			default:
				return;
		}
		show();
	};
	const onAgentRequest = (method: string, params: any) => {
		const what = method === "session/request_permission" ? clip1(params?.toolCall?.title || "an action") : method.includes("elicitation") || method.includes("interaction") ? "a question" : method;
		declined.push(what);
		notes.push(`✗ declined: ${what}`);
		show();
	};
	agy = await o.open(onUpdate, onAgentRequest);
	let cancelled = false;
	const onAbort = () => {
		cancelled = true;
		agy!.cancel();
		setTimeout(() => void agy!.close(), CANCEL_WAIT_MS).unref?.();
	};
	try {
		try {
			await agy.setMode("default");
		} catch (e) {
			if (e instanceof ModeUnconfirmed) throw new Error("Antigravity did not confirm its default mode, so the task was not sent");
			throw e;
		}
		if (o.model) await agy.selectModel(o.model);
		if (o.signal?.aborted) throw new Error("Antigravity task cancelled");
		o.signal?.addEventListener("abort", onAbort, { once: true });
		const r = await agy.prompt([{ type: "text", text: o.task }]);
		if (cancelled || r?.stopReason === "cancelled") throw new Error("Antigravity task cancelled");
		const tail: string[] = [];
		if (declined.length) tail.push(`Declined: ${declined.join("; ")} (Deckhand does not grant Antigravity approvals)`);
		if (modeLeft) tail.push("Note: Antigravity left its default mode during the task");
		if (r?.stopReason && r.stopReason !== "end_turn") tail.push(`Antigravity stopped: ${r.stopReason}`);
		return [text.trim() || "(Antigravity gave no text)", ...tail].join("\n\n");
	} catch (e) {
		if (cancelled) throw new Error("Antigravity task cancelled");
		throw e;
	} finally {
		o.signal?.removeEventListener("abort", onAbort);
		await agy.close();
	}
}
