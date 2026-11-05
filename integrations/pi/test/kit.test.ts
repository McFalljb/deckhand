// pi-kit's tests of the code the optional guardrails and shell extensions bundle (lib/guardrails.ts,
// lib/shell.ts), ported from pi-kit's test/unit.test.ts at 6af842f with the imports pointed here.
// node --test test/kit.test.ts (Node 22.18+ strips the types; never runs pi).
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import fs from "node:fs";
import { checkCommand, commandVerdict, configPaths, describeRules, isShellLog, loadRules, mergeLayers, parseConfig, PRESETS, redact, warnOnce } from "../lib/guardrails.ts";
import { checkinText, clip, compilePattern, evictable, footerText, groupAlive, groupGone, groupSize, KEY_REDACTED, keyFilter, lastLines, lineMatcher, MATCH_CAP, MAX_LINE, panelRows, short, splitLines } from "../lib/shell.ts";

// every temp folder this file makes goes in one of its own, removed when its tests end (they were
// left in $TMPDIR)
const TMP_ROOT = mkdtempSync(path.join(os.tmpdir(), "deckhand-test-"));
process.on("exit", () => rmSync(TMP_ROOT, { recursive: true, force: true }));

test("splitLines carries the unterminated tail", () => {
	assert.deepEqual(splitLines("", "a\nb\r\nc"), { lines: ["a", "b"], rest: "c" });
	assert.deepEqual(splitLines("c", "d\n"), { lines: ["cd"], rest: "" });
	assert.deepEqual(splitLines("", ""), { lines: [], rest: "" });
});

test("clip strips escapes and redraws and caps length", () => {
	assert.equal(clip("\x1b[31mred\x1b[0m"), "red");
	assert.equal(clip("10%\r50%\r100%"), "100%");
	const long = clip("x".repeat(MAX_LINE + 5));
	assert.ok(long.startsWith("x".repeat(MAX_LINE)) && long.endsWith("[5 more chars]"));
});

test("lastLines skips blank lines", () => {
	assert.deepEqual(lastLines("a\n\nb\nc\n\n", 2), ["b", "c"]);
});

test("compilePattern", () => {
	assert.equal(compilePattern(undefined), undefined);
	assert.equal(compilePattern(""), undefined);
	assert.ok(compilePattern("^ERR")!.test("ERR x"));
	assert.throws(() => compilePattern("("), /Invalid pattern/);
});

test("guardrails are opt-in: with no config, no command asks or is blocked", () => {
	for (const c of ["git worktree remove --force ../wt", "kubectl delete pod x", "rm -rf build", "gh pr merge 5", "git push --force origin x", "helm upgrade r c", "terraform apply", "systemctl restart nginx", "docker rm x", "git stash drop"]) {
		assert.deepEqual(commandVerdict(c, false), { confirm: [] }, c);
	}
});

/** Active rules from config texts, in merge order (global, then project files, which are tighten-only). */
const rulesOf = (...texts: string[]) => mergeLayers(texts.map((t, i) => ({ ...parseConfig(t, `f${i}`).layer!, tightenOnly: i > 0 })));

test("commandVerdict: presets ask once enabled, read-only blocks mutation", () => {
	const git = rulesOf('{"enable": {"git-destructive": "ask"}}');
	assert.deepEqual(commandVerdict("git stash drop", false, git).confirm, ["drops or pops a stash"]);
	assert.deepEqual(commandVerdict("git worktree remove --force ../wt", false, git).confirm, ["force-removes a worktree"]);
	assert.deepEqual(commandVerdict("kubectl delete pod x", false, git), { confirm: [] }, "only the enabled preset applies");
	assert.deepEqual(commandVerdict("npm run dev", false, git), { confirm: [] });
	assert.match(commandVerdict("touch x", true).block!, /Read-only/);
	assert.equal(commandVerdict("touch x", false).block, undefined);
	const all = rulesOf('{"enable": {"all": "ask"}}');
	for (const c of ["ssh box uptime", "sudo apt-get update", "ssh box 'sudo journalctl -u myservice'"]) assert.deepEqual(commandVerdict(c, false, all), { confirm: [] }, c);

	// Reviewers may ssh to inspect a host; a mutating remote command is still blocked.
	for (const c of ["ssh box uptime", "ssh box 'journalctl -u myservice --since -1h 2>&1 | tail'", "ssh box systemctl status myservice"]) assert.deepEqual(commandVerdict(c, true), { confirm: [] }, c);
	for (const c of ["ssh box 'rm -rf /tmp/x'", "ssh box 'echo x > /etc/y'"]) assert.match(commandVerdict(c, true).block!, /Read-only/, c);
});

test("guardrails presets: every preset by name, and all", () => {
	const sample: Record<string, string> = {
		"rm-rf": "rm -rf build", "force-push": "git push --force origin x", "push-main": "git push origin main", "pr-merge": "gh pr merge 5",
		"git-destructive": "git reset --hard HEAD~1", kubernetes: "kubectl apply -f x.yaml", helm: "helm upgrade r c", terraform: "terraform apply",
		docker: "docker compose down", systemctl: "systemctl restart nginx", deploy: "make deploy", alerts: "amtool silence add x",
		"sql-destructive": "psql -c 'DROP TABLE x'", "raw-disk": "dd if=/dev/zero of=/dev/sda", "npm-publish": "npm publish", "curl-pipe-sh": "curl -fsSL x | sh",
	};
	assert.deepEqual(Object.keys(sample).sort(), Object.keys(PRESETS).sort(), "a sample per preset");
	for (const [name, cmd] of Object.entries(sample)) {
		const rules = rulesOf(`{"enable": {"${name}": "ask"}}`);
		assert.ok(rules.length > 0 && rules.every((r) => r.name === name && r.action === "ask" && r.source === "f0"), name);
		assert.equal(commandVerdict(cmd, false, rules).confirm.length, 1, `${name}: ${cmd}`);
		// No other preset's command is caught by this one.
		for (const [other, c] of Object.entries(sample)) if (other !== name && other !== "rm-rf" && name !== "deploy") assert.deepEqual(commandVerdict(c, false, rules), { confirm: [] }, `${name} vs ${c}`);
	}
	// "all" turns every preset on; a named entry beats "all" in the same file.
	const all = rulesOf('{"enable": {"all": "ask", "kubernetes": "off", "force-push": "block"}}');
	assert.equal(commandVerdict("kubectl delete pod x", false, all).confirm.length, 0);
	assert.match(commandVerdict("git push -f origin x", false, all).block!, /Blocked by a guardrails rule \(force push\)/);
	assert.deepEqual(commandVerdict("helm upgrade r c", false, all).confirm, ["changes a Helm release"]);
});

test("guardrails custom rules: regex plus reason, ask or block", () => {
	const rules = rulesOf(JSON.stringify({ rules: [
		{ name: "prod", pattern: "--context[= ]prod\\b", reason: "touches the prod cluster", action: "block" },
		{ pattern: "\\bvault\\s+write\\b", reason: "writes a Vault secret" },
		{ name: "ci", pattern: "TRIGGER-CI", flags: "gi", reason: "starts CI" },
	] }));
	assert.equal(rules.length, 3);
	assert.match(commandVerdict("kubectl get pods --context prod", false, rules).block!, /touches the prod cluster/);
	assert.deepEqual(commandVerdict("vault write secret/x a=b", false, rules).confirm, ["writes a Vault secret"], "action defaults to ask");
	// g is dropped, so repeated tests do not alternate.
	for (let i = 0; i < 3; i++) assert.deepEqual(commandVerdict("echo trigger-ci", false, rules).confirm, ["starts CI"]);
	assert.deepEqual(commandVerdict("kubectl get pods --context staging", false, rules), { confirm: [] });
	// Block wins over ask when both match.
	const both = rulesOf('{"enable": {"kubernetes": "ask"}, "rules": [{"pattern": "--context prod", "reason": "prod", "action": "block"}]}');
	assert.match(commandVerdict("kubectl delete pod x --context prod", false, both).block!, /\(prod\)/);
	assert.match(describeRules(["g", "p"], rules, [], false), /- block prod: touches the prod cluster \[f0\]/);
	assert.match(describeRules(["g", "p"], [], [], false), /No command rules are on/);
});

test("guardrails project file is tighten-only: adds rules and raises ask to block", () => {
	const global = JSON.stringify({ enable: { "force-push": "ask", kubernetes: "ask", helm: "ask" }, rules: [{ name: "prod", pattern: "prod", reason: "global prod", action: "ask" }] });
	const project = JSON.stringify({ enable: { kubernetes: "block", terraform: "ask" }, rules: [{ name: "prod", pattern: "prod", reason: "project prod", action: "block" }, { name: "extra", pattern: "extra-danger", reason: "extra" }] });
	const warnings: string[] = [];
	const rules = mergeLayers([{ ...parseConfig(global, "g").layer!, tightenOnly: false }, { ...parseConfig(project, "p").layer!, tightenOnly: true }], warnings);
	const by = (n: string) => rules.filter((r) => r.name === n).map((r) => `${r.action}@${r.source}`);
	assert.deepEqual(by("force-push"), ["ask@g"], "global rule kept");
	assert.deepEqual(by("kubernetes"), ["block@p"], "raised to block");
	assert.deepEqual(by("terraform"), ["ask@p"], "project adds a preset");
	assert.deepEqual(by("prod"), ["block@p"], "same pattern, raised to block");
	assert.deepEqual(by("extra"), ["ask@p"], "project adds a rule");
	assert.deepEqual(warnings, []);
});

test("guardrails project file cannot turn off or weaken the global config (one warning naming the file)", () => {
	const global = JSON.stringify({ enable: { "force-push": "block", kubernetes: "ask", helm: "block" }, rules: [{ name: "prod", pattern: "prod", reason: "global prod", action: "block" }, { name: "vault", pattern: "vault write", reason: "vault" }, { name: "ci", pattern: "ci-run", reason: "ci" }] });
	const project = JSON.stringify({
		enable: { "force-push": "off", kubernetes: "off", helm: "ask", terraform: "ask" },
		rules: [{ name: "prod", pattern: "prod", reason: "weaker", action: "ask" }, { name: "vault", pattern: "x", action: "off" }, { name: "ci", pattern: "never-matches", reason: "swapped pattern", action: "block" }],
	});
	const warnings: string[] = [];
	const rules = mergeLayers([{ ...parseConfig(global, "g").layer!, tightenOnly: false }, { ...parseConfig(project, "/repo/.pi/guardrails.json").layer!, tightenOnly: true }], warnings);
	const by = (n: string) => rules.filter((r) => r.name === n).map((r) => `${r.action}@${r.source}:${r.pattern.source}`);
	assert.deepEqual(by("force-push").map((x) => x.split(":")[0]), ["block@g"]);
	assert.deepEqual(by("kubernetes").map((x) => x.split(":")[0]), ["ask@g"]);
	assert.deepEqual(by("helm").map((x) => x.split(":")[0]), ["block@g"], "block is not lowered to ask");
	assert.deepEqual(by("terraform").map((x) => x.split(":")[0]), ["ask@/repo/.pi/guardrails.json"], "the valid entries still apply");
	assert.deepEqual(by("prod"), ["block@g:prod"]);
	assert.deepEqual(by("vault"), ["ask@g:vault write"]);
	assert.deepEqual(by("ci"), ["ask@g:ci-run"], "a different pattern cannot replace a global rule");
	assert.equal(warnings.length, 1, "one warning for the file");
	assert.match(warnings[0], /^\/repo\/\.pi\/guardrails\.json: ignored /);
	for (const w of ['"force-push": "off"', '"kubernetes": "off"', '"helm": "ask"', 'rule "prod"', 'rule "vault"', 'rule "ci"']) assert.ok(warnings[0].includes(w), w);

	// "all": "off" in a project file is ignored for everything the global file enabled.
	const w2: string[] = [];
	const r2 = mergeLayers([{ ...parseConfig(global, "g").layer!, tightenOnly: false }, { ...parseConfig('{"enable": {"all": "off"}}', "p").layer!, tightenOnly: true }], w2);
	assert.deepEqual(r2.filter((r) => PRESETS[r.name]).map((r) => r.name), ["force-push", "kubernetes", "helm"]);
	assert.equal(w2.length, 1);
	// A project "all": "ask" turns the rest on and leaves "block" presets at block, without a warning.
	const w3: string[] = [];
	const r3 = mergeLayers([{ ...parseConfig(global, "g").layer!, tightenOnly: false }, { ...parseConfig('{"enable": {"all": "ask"}}', "p").layer!, tightenOnly: true }], w3);
	assert.equal(r3.find((r) => r.name === "helm")!.action, "block");
	assert.equal(r3.find((r) => r.name === "terraform")!.action, "ask");
	assert.deepEqual(w3, []);
	// Without a global file the project file is still tighten-only against nothing: it just adds.
	assert.deepEqual(mergeLayers([{ ...parseConfig('{"enable": {"helm": "ask"}}', "p").layer!, tightenOnly: true }]).map((r) => r.name), ["helm"]);
});

test("guardrails bad config warns and keeps the valid rules", () => {
	const { layer, warnings } = parseConfig(JSON.stringify({
		enable: { "force-push": "ask", "no-such": "ask", helm: "maybe" },
		rules: [{ name: "bad", pattern: "(", reason: "x" }, { name: "good", pattern: "ok-danger", reason: "good" }, "nope", { pattern: "" }, { pattern: "x", action: "deny" }],
		enabled: {},
	}), "cfg");
	const rules = mergeLayers([layer!]);
	assert.deepEqual(rules.map((r) => r.name), ["force-push", "good"]);
	for (const w of [/unknown preset "no-such"/, /preset "helm": action/, /rule "bad": bad regex/, /rule 3: must be an object/, /rule 4: "pattern"/, /rule 5: action/, /unknown key "enabled"/]) {
		assert.ok(warnings.some((x) => w.test(x) && x.startsWith("cfg: ")), String(w));
	}
	// Invalid JSON: no layer from that file, a warning, and the other file's rules still apply.
	const broken = parseConfig("{ enable: ", "p");
	assert.equal(broken.layer, undefined);
	assert.match(broken.error!, /^invalid JSON/);
	assert.match(parseConfig("[]", "p").error!, /expected a JSON object/);
	// Only own preset names count: "toString" is not a preset.
	assert.match(parseConfig('{"enable": {"toString": "ask"}}', "p").warnings[0], /unknown preset "toString"/);

	const dir = mkdtempSync(path.join(TMP_ROOT, "deckhand-guard-"));
	const g = path.join(dir, "global.json"), p = path.join(dir, "project.json");
	writeFileSync(g, '{"enable": {"kubernetes": "ask"}}');
	writeFileSync(p, "{ not json");
	const loaded = loadRules([g, p, path.join(dir, "missing.json")]);
	assert.deepEqual(loaded.rules.map((r) => r.name), ["kubernetes"]);
	assert.equal(loaded.warnings.length, 1, "a missing file is not a warning");
	assert.match(loaded.warnings[0], /project\.json: invalid JSON .*none of its rules apply until it is fixed/);
	// An edit applies to the next load.
	writeFileSync(p, '{"enable": {"helm": "block"}}');
	assert.deepEqual(loadRules([g, p]).rules.map((r) => r.name), ["kubernetes", "helm"]);
	assert.deepEqual(loadRules([g, p]).warnings, []);
	// A directory where the file should be is a warning, not a crash.
	assert.match(loadRules([dir]).warnings[0], /not a regular file/);

	// Each warning is shown once while it persists: a UI notice, or stderr without a UI.
	const notes: string[] = [];
	const ui = { notify: (m: string) => notes.push(m) } as never;
	warnOnce(["w-unique-1", "w-unique-1"], { hasUI: true, ui });
	warnOnce(["w-unique-1"], { hasUI: true, ui });
	assert.deepEqual(notes, ["Deckhand guardrails: w-unique-1"]);
	// Fixed, then broken again: warned again.
	warnOnce([], { hasUI: true, ui });
	warnOnce(["w-unique-1"], { hasUI: true, ui });
	assert.deepEqual(notes, ["Deckhand guardrails: w-unique-1", "Deckhand guardrails: w-unique-1"]);
});

test("guardrails config: a half-written file keeps that path's last good rules", () => {
	const dir = mkdtempSync(path.join(TMP_ROOT, "deckhand-guard-"));
	const f = path.join(dir, "config.json");
	writeFileSync(f, '{"enable": {"force-push": "block"}}');
	assert.deepEqual(loadRules([f]).rules.map((r) => r.name), ["force-push"]);
	writeFileSync(f, '{"enable": {"force-push": "blo');
	const half = loadRules([f]);
	assert.deepEqual(half.rules.map((r) => `${r.name}:${r.action}`), ["force-push:block"]);
	assert.match(half.warnings[0], /invalid JSON .*keeping its last good rules until it is fixed/);
	writeFileSync(f, '{"enable": {"helm": "ask"}}');
	assert.deepEqual(loadRules([f]), { rules: loadRules([f]).rules, warnings: [] });
	assert.deepEqual(loadRules([f]).rules.map((r) => r.name), ["helm"]);
	// Deleting the file is a deliberate change: its rules go.
	rmSync(f);
	assert.deepEqual(loadRules([f]), { rules: [], warnings: [] });
});

test("guardrails config: only regular files up to 64 KB are read", () => {
	const dir = mkdtempSync(path.join(TMP_ROOT, "deckhand-guard-"));
	const big = path.join(dir, "big.json");
	writeFileSync(big, `{"enable": {"helm": "ask"}}${" ".repeat(70 * 1024)}`);
	const r = loadRules([big]);
	assert.deepEqual(r.rules, []);
	assert.match(r.warnings[0], /larger than 64 KB/);
	// A symlink to a device is not a regular file.
	const dev = path.join(dir, "dev.json");
	symlinkSync("/dev/zero", dev);
	assert.match(loadRules([dev]).warnings[0], /not a regular file/);
});

test("guardrails config: a FIFO is skipped, not read (it would hang pi)", () => {
	const dir = mkdtempSync(path.join(TMP_ROOT, "deckhand-guard-"));
	const fifo = path.join(dir, "guardrails.json");
	execFileSync("mkfifo", [fifo]);
	const core = new URL("../lib/guardrails.ts", import.meta.url).href;
	const r = spawnSync(process.execPath, ["--input-type=module", "-e", `import { loadRules } from ${JSON.stringify(core)}; console.log(JSON.stringify(loadRules([${JSON.stringify(fifo)}])))`], { timeout: 10_000, encoding: "utf8" });
	assert.equal(r.signal, null, "loadRules hung on a FIFO");
	assert.match(JSON.parse(r.stdout).warnings[0], /not a regular file/);
});

test("guardrails custom rules see at most the first 64 KB of a command; presets see all of it", () => {
	const rules = rulesOf('{"enable": {"rm-rf": "ask"}, "rules": [{"name": "tail", "pattern": "tail-marker", "reason": "tail"}]}');
	const pad = "a".repeat(70 * 1024);
	assert.deepEqual(commandVerdict(`echo ${pad} tail-marker`, false, rules), { confirm: [] });
	assert.deepEqual(commandVerdict(`echo tail-marker ${pad}`, false, rules).confirm, ["tail"]);
	assert.deepEqual(commandVerdict(`echo ${pad}; rm -rf build`, false, rules).confirm, ["recursive force delete"]);
	// A custom rule named like a preset is still a custom rule.
	const named = rulesOf('{"rules": [{"name": "kubernetes", "pattern": "tail-marker", "reason": "tail"}]}');
	assert.deepEqual(commandVerdict(`echo ${pad} tail-marker`, false, named), { confirm: [] });
});

test("checkCommand: config files, ask vs block, with a UI and headless", async () => {
	const dir = mkdtempSync(path.join(TMP_ROOT, "deckhand-guard-"));
	const agent = path.join(dir, "agent"), cwd = path.join(dir, "repo");
	const saved = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = agent;
	try {
		assert.deepEqual(configPaths(cwd), [path.join(agent, "extensions/guardrails/config.json"), path.join(cwd, ".pi/guardrails.json")]);
		const asked: string[] = [];
		const ctx = (hasUI: boolean, answer = false) => ({ cwd, hasUI, ui: { confirm: async (_t: string, m: string) => (asked.push(m), answer), notify: () => {} } as never });
		// No config: everything runs, with or without a UI, and nothing is asked.
		for (const c of ["git worktree remove --force ../wt", "kubectl delete pod x", "gh pr merge 5"]) {
			assert.equal(await checkCommand(c, false, ctx(true)), undefined, c);
			assert.equal(await checkCommand(c, false, ctx(false)), undefined, c);
		}
		assert.deepEqual(asked, []);

		mkdirSync(path.join(agent, "extensions/guardrails"), { recursive: true });
		mkdirSync(path.join(cwd, ".pi"), { recursive: true });
		writeFileSync(path.join(agent, "extensions/guardrails/config.json"), '{"enable": {"pr-merge": "ask", "kubernetes": "ask"}}');
		writeFileSync(path.join(cwd, ".pi/guardrails.json"), '{"enable": {"kubernetes": "block", "pr-merge": "off"}, "rules": [{"pattern": "drop-prod-db", "reason": "drops the prod db", "action": "ask"}]}');
		const loaded = loadRules(configPaths(cwd));
		assert.equal(loaded.warnings.length, 1);
		assert.match(loaded.warnings[0], /\.pi\/guardrails\.json: ignored "pr-merge": "off"/);

		// ask: the UI decides; headless blocks with the report-it message.
		assert.equal(await checkCommand("gh pr merge 5", false, ctx(true, true)), undefined);
		assert.equal(await checkCommand("gh pr merge 5", false, ctx(true, false)), "User declined: merge a pull request (may deploy)");
		assert.equal(await checkCommand("gh pr merge 5", false, ctx(false)), "Needs user approval (merge a pull request (may deploy)), and no UI is available. Report it to the orchestrator instead.");
		assert.match((await checkCommand("echo drop-prod-db", false, ctx(false)))!, /Needs user approval \(drops the prod db\)/);
		// block: blocked with or without a UI, never asked.
		const n = asked.length;
		for (const ui of [true, false]) assert.match((await checkCommand("kubectl delete pod x", false, ctx(ui, true)))!, /^Blocked by a guardrails rule \(changes a cluster\)/);
		assert.equal(asked.length, n);
		// Everything else runs.
		assert.equal(await checkCommand("git worktree remove --force ../wt", false, ctx(false)), undefined);
		// Read-only still blocks mutation, whatever the config says.
		assert.match((await checkCommand("rm -f x", true, ctx(true, true)))!, /Read-only/);
	} finally {
		if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = saved;
	}
});

test("read-only blocks mutation with no config at all", () => {
	for (const c of ["git commit -m x", "rm x", "echo x > f", "sed -i s/a/b/ f", "git worktree remove ../wt"]) assert.match(commandVerdict(c, true).block!, /Read-only/, c);
});

test("redact", () => {
	assert.equal(redact("t ghp_abcdefghijklmnopqrstuvwxyz0123456789AB", false), "t [REDACTED]");
	assert.equal(redact("password=supersecretvalue123", true), "password=[REDACTED]");
	assert.equal(redact("password=supersecretvalue123", false), "password=supersecretvalue123");
});

// A fake PEM block (random filler, not a key).
const FAKE_KEY = ["-----BEGIN RSA PRIVATE KEY-----", "MIIEfakefakefakeAAAAQQQQ1111", "ZZZZfakebodyline2zzzzzzzzzzz", "-----END RSA PRIVATE KEY-----"];
const GH = "ghp_abcdefghijklmnopqrstuvwxyz0123456789AB";
const JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.c2lnbmF0dXJlLXBhcnQtMTIzNDU2";

test("clip redacts before it cuts (P1-1)", () => {
	const gh = clip(`${"x".repeat(MAX_LINE - 10)} ${GH}`);
	assert.ok(!gh.includes("ghp_") && !gh.includes("abcdefgh"), gh);
	// The JWT's signature starts past the cut.
	const jwt = clip(`${"y".repeat(MAX_LINE - JWT.indexOf(".", 25) - 5)} ${JWT}`);
	assert.ok(!jwt.includes("eyJ"), jwt);
	// A token straddling MATCH_CAP leaves no fragment either.
	// A token straddling MATCH_CAP leaves no fragment, even when redaction shrinks what is before it.
	const [b, e] = ["-----BEGIN X PRIVATE KEY-----", "-----END X PRIVATE KEY-----"];
	const far = clip(`${b}${"a".repeat(MATCH_CAP - 20 - b.length - e.length - 1)}${e} ${GH}`);
	assert.ok(!far.includes("ghp_"), far);
});

test("keyFilter and lastLines drop private key blocks (P1-1)", () => {
	const st = { inKey: false };
	assert.deepEqual(["before", ...FAKE_KEY, "after"].map((l) => keyFilter(st, l)), ["before", KEY_REDACTED, undefined, undefined, undefined, "after"]);
	assert.deepEqual(lastLines(["start", ...FAKE_KEY, "done"].join("\n"), 10), ["start", KEY_REDACTED, "done"]);
	// The tail window starts inside the block: its first line is partial and its BEGIN is out of view.
	assert.deepEqual(lastLines(["kefakebody", ...FAKE_KEY.slice(1), "done"].join("\n"), 10, false), [KEY_REDACTED, "done"]);
	// A partial first line of the window is dropped (it may be the end of a cut token).
	assert.deepEqual(lastLines("WXYZ0123456789AB\nnext", 10, false), ["next"]);
	// Unterminated block: nothing after BEGIN is shown.
	assert.deepEqual(lastLines(FAKE_KEY.slice(0, 3).join("\n"), 10), [KEY_REDACTED]);
});

test("compilePattern rejects nested quantifiers (P2-2)", () => {
	assert.throws(() => compilePattern(String.raw`(\w+\s?)+$`), /repeats a group that itself repeats/);
	assert.throws(() => compilePattern("(a+)*b"), /repeats a group/);
	assert.ok(compilePattern(String.raw`(ERR|WARN) \d+`));
	assert.ok(compilePattern(String.raw`^\[(\d+)\] .*failed`));
});

test("lineMatcher bounds a slow pattern (P2-2)", () => {
	const ok = lineMatcher(/^ERR/);
	assert.deepEqual(ok.test(["ERR 1", "ok"]), [true, false]);
	ok.close();
	const slow = lineMatcher(/.*.*x/, 300);
	const t0 = Date.now();
	assert.equal(slow.test(["a".repeat(4096)]), undefined);
	assert.ok(Date.now() - t0 < 2000);
});

test("leftover process groups (P1-2, P2-1)", async () => {
	const child = spawn("bash", ["-c", "sleep 30 &"], { detached: true, stdio: "ignore" });
	await new Promise((r) => child.once("exit", r));
	const pid = child.pid!;
	assert.equal(groupAlive(pid), true);
	assert.equal(groupSize(pid), 1);
	const t: { pid: number; ended?: number; gone?: boolean } = { pid, ended: Date.now() };
	assert.equal(groupGone(t), false);
	process.kill(-pid, "SIGKILL");
	await new Promise((r) => setTimeout(r, 200));
	assert.equal(groupAlive(pid), false);
	assert.equal(groupGone(t), true);
	// Latched: a reused group id never makes a gone task signalable again.
	assert.equal(groupGone(t, () => true), true);
	// A running task is never "gone".
	assert.equal(groupGone({ pid }, () => false), false);
});

test("evictable keeps tasks whose group may be alive (P1-2)", () => {
	const ts = [{ id: 1, ended: 1, gone: true }, { id: 2, ended: 2 }, { id: 3, ended: 3, gone: true }, { id: 4 }, { id: 5, ended: 5, gone: true }];
	assert.deepEqual(evictable(ts, 1).map((t) => t.id), [1, 3]);
	assert.deepEqual(evictable(ts, 3), []);
	// Oldest by end time, not by start: a long task that just ended is kept.
	assert.deepEqual(evictable([{ id: 1, ended: 9, gone: true }, { id: 2, ended: 3, gone: true }], 1).map((t) => t.id), [2]);
});

test("secret files and credential commands are not blocked (agents use judgement)", () => {
	for (const c of ["rg credentials", "cat ~/.aws/credentials", "aws sso login --profile dev", "tsh login --proxy=tele.example", "sops -d secrets.sops.yaml", "TOKEN=$(gcloud auth print-access-token) curl -H x", "cat .env", "printenv", "cat ~/.ssh/id_ed25519"]) {
		assert.equal(commandVerdict(c, false).block, undefined, c);
	}
});

test("shell log reads get assignment redaction (P3-4)", () => {
	const dir = path.join(os.tmpdir(), "pi-shell-abc123");
	assert.equal(isShellLog(path.join(dir, "sh1.log"), "/x"), true);
	assert.equal(isShellLog("sh1.log", dir), true);
	assert.equal(isShellLog(path.join(dir, "notes.txt"), "/x"), false);
	assert.equal(isShellLog("/repo/sh1.log", "/x"), false);
});

test("short: one redacted line, cut to n", () => {
	assert.equal(short("npm run\n  dev"), "npm run dev");
	assert.equal(short("x".repeat(60), 10), `${"x".repeat(9)}…`);
	const s = short(`curl -H "Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789AB" https://example.com/${"p".repeat(80)}`);
	assert.ok(!s.includes("ghp_abc") && s.length <= 48, s);
});

test("panelRows: shells, monitors, leftovers, timers, cap", () => {
	const now = 100_000;
	const rows = panelRows(
		[
			{ id: "sh1", command: "sleep 30", started: now - 12_000, watch: { re: /READY/, matches: 1 } },
			{ id: "sh2", command: "tail -f log", started: now - 75_000, watch: { matches: 3 } },
			{ id: "sh3", command: "make", started: 0, ended: now },
			{ id: "sh4", command: "serve &", started: 0, ended: now, leftover: true },
		],
		[{ id: "wk5", prompt: "check\nthe deploy", due: now + 90_000 }],
		now,
	);
	assert.deepEqual(rows, [
		{ id: "sh1", status: "12s · watching /READY/ · 1 match", label: "sleep 30" },
		{ id: "sh2", status: "1m15s · watching all lines · 3 lines", label: "tail -f log" },
		{ id: "sh4", status: "exited, processes left in its group", label: "serve &", warn: true },
		{ id: "wk5", status: "wakes in 1m30s", label: "check the deploy" },
	]);
	const many = panelRows([], Array.from({ length: 8 }, (_, i) => ({ id: `wk${i}`, prompt: "p", due: now })), now);
	assert.equal(many.length, 6);
	assert.deepEqual(many[5], { id: "", status: "+3 more · /shells", label: "" });
	assert.equal(panelRows([], Array.from({ length: 8 }, (_, i) => ({ id: `wk${i}`, prompt: "p", due: now })), now, Infinity).length, 8);
	assert.deepEqual(panelRows([], [], now), []);
});

test("checkinText: headless check-in lists tasks and timers, flags quiet tasks, stops nothing", () => {
	const now = 10_000_000;
	const min = 60_000;
	const text = checkinText(
		[
			{ id: "sh1", command: "npm run build", started: now - 62 * min, lastOutput: now - 2 * min },
			{ id: "sh2", command: "python train.py --token ghp_abcdefghijklmnopqrstuvwxyz0123456789AB", started: now - 45 * min, lastOutput: now - 41 * min },
			{ id: "sh3", command: "sleep 9999", started: now - 31 * min },
			{ id: "sh4", command: "make test", started: now - 5 * min },
		],
		[{ id: "wk5", prompt: "check\nthe deploy", due: now + 12 * min }],
		30 * min,
		now,
		30 * min,
	);
	const lines = text.split("\n");
	assert.match(lines[0], /^Background shells check-in: no notice for 30m00s\. Nothing was stopped/);
	assert.equal(lines[1], "- sh1 running 62m00s, last wrote to its log 2m00s ago: `npm run build`");
	assert.match(lines[2], /^- sh2 running 45m00s, nothing written to its log for 41m00s: `python train\.py --token \[REDACTED\]`$/);
	assert.equal(lines[3], "- sh3 running 31m00s, nothing written to its log for 31m00s: `sleep 9999`");
	assert.equal(lines[4], "- sh4 running 5m00s, nothing written to its log yet: `make test`");
	assert.equal(lines[5], "- wk5 timer, wakes in 12m00s: check the deploy");
	assert.match(text, /This headless run cannot finish until every task listed stops\./);
	assert.match(text, /Stop servers, watchers and anything whose result you do not need now with shell_stop <id>/);
	assert.match(text, /only wait for work you expect to finish: end your turn and the next check-in comes in 30m00s/);
	assert.ok(!text.includes("ghp_abc"));
});

test("footerText counts each kind", () => {
	assert.equal(footerText({ shells: 2, monitors: 1, timers: 1, leftovers: 0 }), "2 shells · 1 monitor · 1 timer · /shells");
	assert.equal(footerText({ shells: 0, monitors: 0, timers: 0, leftovers: 1 }), "1 leftover · /shells");
	assert.equal(footerText({ shells: 0, monitors: 0, timers: 0, leftovers: 0 }), undefined);
});

