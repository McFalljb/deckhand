// tests/readonly-vectors.json against pi-kit's real MUTATING regexes (read from its core.ts), so the
// two lists cannot drift: node tests/scripts/readonly-vectors-pikit.mjs <pi-kit>/extensions/guardrails/core.ts tests/readonly-vectors.json
import fs from "node:fs";
const [core, vec] = process.argv.slice(2);
const src = fs.readFileSync(core, "utf8");
const m = src.match(/const MUTATING: RegExp\[\] = (\[[\s\S]*?\n\]);/);
const MUTATING = eval(m[1]);
const v = JSON.parse(fs.readFileSync(vec, "utf8"));
let bad = 0;
for (const c of v.deny) if (!MUTATING.some(r => r.test(c))) { console.log("pi-kit does NOT block:", JSON.stringify(c)); bad++; }
for (const c of v.allow) if (MUTATING.some(r => r.test(c))) { console.log("pi-kit blocks:", JSON.stringify(c)); bad++; }
console.log(`${v.deny.length} deny, ${v.allow.length} allow, ${bad} disagree`);
process.exit(bad ? 1 : 0);
