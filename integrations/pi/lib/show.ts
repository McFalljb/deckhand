// desk_show (extensions/browser; unit-tested in test/unit.test.ts): a pi tab shows the user a file
// in a tab of its own session, through Deckhand's show_file (docs/PROTOCOL.md §3). A Markdown file
// opens rendered in a Markdown tab, any other text file in an editor tab; the tab opens next to the
// pi tab, behind the user's view. Display only: nothing of the file comes back.

type R = Record<string, any>;

export const SHOW_DESCRIPTION =
	"Show the user a file in a tab of your Deckhand session, next to yours: a Markdown file renders in a Markdown tab (anchor: a heading id to scroll to), any other text file opens in an editor tab (line). path: absolute, or relative to your session's folder; outside the project is fine. It opens behind the user's view (what they see does not change): tell them it is there. Use it when the user asks to open or show a file in a tab, never a local web server or a file: URL. Display only: you get nothing of the file back and cannot edit the tab. Binary files (images, PDFs), files over 20 MB and credentials files are refused.";

/** Deckhand's show_file command; throws on a bad path, line or anchor. `session` only from Home (a pi tab's is its own). */
export function showCommand(p: { path?: unknown; line?: unknown; anchor?: unknown; session?: unknown }, home: boolean): R {
	if (typeof p.path !== "string" || !p.path.trim()) throw new Error("path is required: the file to show (absolute, or relative to your session's folder).");
	if (p.line !== undefined && (typeof p.line !== "number" || !Number.isInteger(p.line) || p.line < 1)) throw new Error("line is a line number, 1 or more.");
	if (p.anchor !== undefined && (typeof p.anchor !== "string" || !p.anchor.replace(/^#/, "").trim())) throw new Error("anchor is a Markdown heading id (e.g. setup for ## Setup).");
	if (p.line !== undefined && p.anchor !== undefined) throw new Error("give line or anchor, not both (anchor: a Markdown heading id).");
	return {
		type: "show_file",
		path: p.path,
		...(p.line !== undefined && { line: p.line }),
		...(p.anchor !== undefined && { anchor: p.anchor }),
		...(home && typeof p.session === "number" && { session: p.session }),
	};
}

/** desk_show's text for Deckhand's result; throws its refusal (error, code, hint). */
export function showText(r: R): string {
	if (!r?.ok) {
		const code = typeof r?.data?.code === "string" && /^[a-z0-9_]{1,40}$/.test(r.data.code) ? ` (${r.data.code})` : "";
		const hint = typeof r?.data?.hint === "string" && !/[\r\n]/.test(r.data.hint) ? ` ${r.data.hint.slice(0, 1000)}` : "";
		throw new Error(`Deckhand: ${String(r?.error ?? "not shown").slice(0, 1000)}${code}.${hint}`);
	}
	const d = r.data ?? {};
	const what = d.kind === "markdown" ? "Markdown tab" : "editor tab";
	const where = typeof d.path === "string" ? ` (${d.path})` : "";
	return d.already_open
		? `The file${where} is already open in ${what} ${r.created_id} of your session (scrolled to what you asked). Tell the user which tab.`
		: `Opened ${what} ${r.created_id}${where} next to your tab, behind the user's view (what they see did not change). Tell the user it is there.`;
}
