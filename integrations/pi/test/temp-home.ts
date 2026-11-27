// Imported first by every test that loads extensions/antigravity: HOME and XDG_DATA_HOME point into
// a fresh temporary folder for the whole test process, so Deckhand's data dir (where the
// Antigravity accounts and agy profiles live), ~/.gemini and os.homedir() are never the user's.
// assertTempData() refuses to go on when they are not (a test that set them back, or forgot this).
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { dataRoot } from "../lib/agy-accounts.ts";

const TMP = realpathSync(os.tmpdir());
export const TEMP_HOME = mkdtempSync(path.join(TMP, "deckhand-test-home-"));
process.env.HOME = TEMP_HOME;
process.env.XDG_DATA_HOME = path.join(TEMP_HOME, ".local", "share");
process.on("exit", () => rmSync(TEMP_HOME, { recursive: true, force: true }));

const TMPS = [TMP, path.resolve(os.tmpdir())]; // /var and /private/var: one folder on macOS
const inTemp = (p: string | undefined) => !!p && TMPS.some((t) => path.resolve(p).startsWith(t + path.sep));

/** Throws unless HOME, XDG_DATA_HOME, os.homedir() and Deckhand's data dir are all in the temporary folder. */
export function assertTempData() {
	const where = { HOME: process.env.HOME, XDG_DATA_HOME: process.env.XDG_DATA_HOME, homedir: os.homedir(), dataRoot: dataRoot() };
	for (const [k, v] of Object.entries(where))
		if (!inTemp(v)) throw new Error(`refusing to run: ${k} is ${v ?? "unset"}, not in ${TMP} (a test would write into the real data dir)`);
}
