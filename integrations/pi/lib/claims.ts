// How the bundled integration steps back when another extension provides a piece of it
// (docs/HARNESSES.md "Overlap"; unit-tested in test/deckhand.test.ts and test/conflicts.test.ts).
//
// - Capability claims: at session_start the panels producer emits CAPS_QUERY on pi.events. An
//   extension that provides a capability itself answers with CAPS_CLAIM {capability, owner,
//   version}, then or at any later time; Deckhand's copy leaves that piece to it.
// - Tool names. pi's rule (core/resource-loader.js detectExtensionConflicts, main.js; pi 1.4.0 and
//   1.5.0): two extensions that register one tool or flag name while loading stop pi from starting
//   ("Tool \"x\" conflicts with <path>", exit 1). A tool registered later (at session_start) is never
//   checked: at run time the first extension in load order that has the name wins, and `-e` (ours)
//   loads first. So no bundled extension registers a tool or flag while loading
//   (test/conflicts.test.ts). The required ones (desk, browser) register theirs at session_start and
//   win by load order. The optional shell registers at session_start only when no tool already
//   loaded has one of its names (loadedTools): next to pi-kit's shell, or anyone's, the user's copy
//   is the one.
// - Command names are not checked: pi keeps every copy and names them `name:1`, `name:2`, … So the
//   optional extensions register a command at session_start only when its name is free
//   (loadedCommands), and the user's copy keeps its plain name.
// - Hooks have no order to win by: every copy's tool_call and turn_end handlers run. So an optional
//   extension made of hooks (guardrails, notes) also steps back for pi-kit's copy, which makes no
//   claim, by what that copy positively leaves behind: its /guardrails registered from pi-kit's own
//   entry file (commandPaths, isKitGuardrails in guardrails.ts), or its reminder message.

export const CAPS_QUERY = "deckhand:capabilities?";
export const CAPS_CLAIM = "deckhand:capabilities";
/** The panel capabilities Deckhand's producer offers, by the panel each one is. */
export const PANEL_CAPS: Readonly<Record<string, string>> = { "panels:todos": "todos", "panels:subagents": "subagents", "panels:shells": "shells" };
/** The optional guardrails extension's capability: its tool_call and tool_result hooks. */
export const GUARDRAILS_CAP = "guardrails";
/** The optional notes extension's capability: the compaction reminder. */
export const NOTES_CAP = "notes";

export interface Claim {
	capability: string;
	owner: string;
	version: string;
}

/** A CAPS_CLAIM payload as a claim, or undefined (malformed, or Deckhand's own). */
export function parseClaim(v: unknown): Claim | undefined {
	const c = v as Record<string, unknown> | null | undefined;
	if (!c || typeof c !== "object") return undefined;
	if (typeof c.capability !== "string" || !c.capability || typeof c.owner !== "string" || !c.owner || c.owner === "deckhand") return undefined;
	return { capability: c.capability, owner: c.owner, version: typeof c.version === "string" ? c.version : "" };
}

/**
 * The source file of each extension's copy of slash command `name` (pi lists several copies as
 * `name:1`, `name:2`, …: getCommands, from pi's resolveRegisteredCommands; `sourceInfo.path` is the
 * extension's file). [] when pi cannot say.
 */
export function commandPaths(pi: { getCommands?: () => { name: string; source?: string; sourceInfo?: { path?: string } }[] }, name: string): string[] {
	const copy = (n: string) => n === name || (n.startsWith(`${name}:`) && /^\d+$/.test(n.slice(name.length + 1)));
	try {
		return (pi.getCommands?.() ?? []).filter((c) => c?.source === "extension" && copy(String(c.name))).map((c) => String(c.sourceInfo?.path ?? ""));
	} catch {
		return [];
	}
}

type Lister = { getAllTools?: () => { name: string; sourceInfo?: { path?: string } }[]; getCommands?: () => { name: string; source?: string; sourceInfo?: { path?: string } }[] };

/**
 * Which of `names` a tool already loaded in this pi has (pi's getAllTools: every extension's and
 * pi's own), with its source file ("" when pi does not say). Empty when pi cannot tell (while
 * extensions load, or a pi without getAllTools): call it at session_start.
 */
export function loadedTools(pi: Lister, names: readonly string[]): Map<string, string> {
	const out = new Map<string, string>();
	try {
		for (const t of pi.getAllTools?.() ?? []) if (names.includes(String(t?.name)) && !out.has(t.name)) out.set(t.name, String(t.sourceInfo?.path ?? ""));
	} catch {}
	return out;
}

/** Which of `names` a slash command already loaded has (any copy: `name`, `name:1`, …), with its source file. Empty when pi cannot tell. */
export function loadedCommands(pi: Lister, names: readonly string[]): Map<string, string> {
	const out = new Map<string, string>();
	try {
		for (const c of pi.getCommands?.() ?? []) {
			const n = String(c?.name ?? "").replace(/:\d+$/, "");
			if (names.includes(n) && !out.has(n)) out.set(n, String(c.sourceInfo?.path ?? ""));
		}
	} catch {}
	return out;
}
