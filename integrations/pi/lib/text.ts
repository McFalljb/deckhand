// Text helpers the panels, the bridge and the shell share (unit-tested in test/unit.test.ts).
// Copied from pi-kit (extensions/shell/lines.ts clip/duration); redact is lib/guardrails.ts's, so
// the bundled integration needs nothing from pi-kit.

import { redact } from "./guardrails.ts";

export { redact };

export const MAX_LINE = 300; // characters kept per line
export const MATCH_CAP = 4096; // chars of a line that are matched and redacted (bounds their cost)

const ANSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07/g;

/**
 * Strip terminal escapes and carriage-return redraws, redact secrets, then cap the length.
 * Redaction runs before the cut, so a cut never leaves a token too short to be recognised.
 */
export function clip(line: string): string {
	const plain = line.replace(ANSI, "");
	const shown = plain.slice(plain.lastIndexOf("\r") + 1);
	// Past MATCH_CAP, drop the token-like fragment the cut leaves, since it may be part of a secret.
	const head = shown.length > MATCH_CAP ? shown.slice(0, MATCH_CAP).replace(/[\w+/=.-]+$/, "") : shown;
	const safe = redact(head, true);
	const more = shown.length - head.length + Math.max(0, safe.length - MAX_LINE);
	return more > 0 ? `${safe.slice(0, MAX_LINE)}… [${more} more chars]` : safe;
}

export function duration(ms: number): string {
	const s = Math.round(ms / 1000);
	return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s`;
}
