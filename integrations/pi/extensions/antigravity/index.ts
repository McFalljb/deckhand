/**
 * Deckhand's Antigravity extension: Google Antigravity in pi tabs, through the user's own
 * Antigravity CLI (`agy acp`, ACP over stdio: lib/acp.ts, lib/agy.ts), as t3code drives it.
 *
 * - Dormant without agy: when no agy is found (DECKHAND_AGY_PATH, else `agy` or `antigravity` on
 *   PATH: a few stats) it registers nothing at all. No provider, command, hook or output.
 * - With agy: the `antigravity` provider (lib/antigravity.ts) and its models in /model,
 *   /antigravity-login (Google sign-in by agy's own `agy acp --login`: lib/agy-login.ts) and
 *   /antigravity-models (lists the account's models again).
 * - Honest: Deckhand's own client name (deckhand-pi), no spoofed headers; agy keeps its sign-in,
 *   Deckhand never reads it and never calls Google.
 * - Approvals: none yet. agy runs in its `default` mode, every permission request is rejected and
 *   every question declined (lib/acp.ts), so agy does nothing that needs an approval.
 * - No tools or flags are registered (test/conflicts.test.ts); the two commands have names of
 *   their own.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { findAgy } from "../../lib/acp.ts";
import { probeModels } from "../../lib/agy.ts";
import { agyLogin } from "../../lib/agy-login.ts";
import { createAntigravity, PROVIDER_ID, SUMMARY_TEXT } from "../../lib/antigravity.ts";

export default function antigravity(pi: ExtensionAPI) {
	const agyPath = findAgy();
	if (!agyPath) return;
	let cwd = process.cwd();
	let setStatus: ((text: string | undefined) => void) | undefined;
	const ag = createAntigravity({ agyPath, cwd: () => cwd, status: (t) => setStatus?.(t) });
	pi.registerProvider(ag.provider as any);
	// agy processes end with pi: with the session (below), and at exit
	process.once("exit", () => ag.killAll());

	pi.on("session_shutdown", async () => {
		setStatus?.(undefined);
		await ag.closeAll();
	});

	// pi's compaction would ask agy for a summary of what agy already holds: pi keeps a note instead
	pi.on("session_before_compact", (event: any, ctx: ExtensionContext) => {
		if (ctx.model?.provider !== PROVIDER_ID || !event?.preparation) return undefined;
		return { compaction: { summary: SUMMARY_TEXT, firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } };
	});

	/** A throwaway session's models into the provider; the line to show. Throws agy's error. */
	const listModels = async () => {
		const r = await probeModels({ agyPath, cwd });
		await ag.setModels(r.models, r.thinking);
		return `${r.models.length} Antigravity model${r.models.length === 1 ? "" : "s"} in /model (agy ${r.version || "?"})`;
	};

	pi.on("session_start", (_e: unknown, ctx: ExtensionContext) => {
		cwd = ctx.cwd || cwd;
		ag.bind((ctx as any).modelRegistry);
		setStatus = ctx.hasUI ? (t) => ctx.ui.setStatus("antigravity", t) : undefined;
	});

	pi.registerCommand("antigravity-login", {
		description: "Sign in to Google Antigravity (runs agy's own sign-in)",
		handler: async (_args: string, ctx: ExtensionContext) => {
			if (!ctx.hasUI) {
				ctx.ui.notify("/antigravity-login needs the interactive pi: or run `agy acp --login` in a terminal", "warning");
				return;
			}
			const r = await agyLogin({
				agyPath,
				cwd,
				showLink: (url) => ctx.ui.notify(`Open this link and sign in with Google, then paste the code the Antigravity page shows:\n${url}`, "info"),
				askCode: () => ctx.ui.input("Antigravity sign-in code", "paste the code from the page"),
			});
			if (!r.ok) {
				ctx.ui.notify(r.error, r.error === "Sign-in cancelled" ? "info" : "error");
				return;
			}
			ctx.ui.notify("Signed in to Antigravity", "info");
			try {
				ctx.ui.notify(await listModels(), "info");
			} catch (e) {
				ctx.ui.notify(`Signed in, but the models could not be listed: ${(e as Error).message}`, "warning");
			}
		},
	});

	pi.registerCommand("antigravity-models", {
		description: `List your Google Antigravity models again (provider ${PROVIDER_ID})`,
		handler: async (_args: string, ctx: ExtensionContext) => {
			try {
				ctx.ui.notify(await listModels(), "info");
			} catch (e) {
				ctx.ui.notify((e as Error).message, "error");
			}
		},
	});
}
