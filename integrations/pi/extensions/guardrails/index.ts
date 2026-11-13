/**
 * Deckhand's optional guardrails (Settings → pi extensions; on by default): pi-kit's guardrails,
 * bundled (lib/guardrails.ts). The user's opt-in ask/block rules on shell commands, read-only
 * blocking with PI_KIT_READONLY=1 (Deckhand sets it for read-only jobs), and secret redaction in
 * tool output. Steps back for another guardrails extension (pi-kit's): pi runs every copy's hooks,
 * so two would ask twice for one command.
 */
import { guardrails } from "../../lib/guardrails.ts";

export default guardrails(process.env.PI_KIT_READONLY === "1");
