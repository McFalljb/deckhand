// The focus check of src/native/browser_act.js (docs/BROWSER.md §4, step 8), on a small fake DOM:
// the sensitive-field rule (autocomplete variants on the field or its form, a password input, a
// field inside a sensitive holder, shadow DOM, -webkit-text-security, a field ever seen as a
// password one), the allowlist of targets text keys may go to (kind), focus in an iframe, a
// revealed password for screenshots, file inputs, names from labels. The real page is the scene
// tests/scripts/browser-act.txt. Run by `./build.sh test` (node).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const src = readFileSync(process.env.BROWSER_ACT_JS || fileURLToPath(new URL("../src/native/browser_act.js", import.meta.url)), "utf8"); // BROWSER_ACT_JS: another copy (a mutation check)

// ---- a fake DOM: just what browser_act.js touches ----
class Node {
	constructor() {
		this.parentNode = null;
		this.childNodes = [];
	}
	get parentElement() {
		return this.parentNode instanceof Element ? this.parentNode : null;
	}
	append(...kids) {
		for (const k of kids) {
			k.parentNode = this;
			this.childNodes.push(k);
		}
		return this;
	}
}
class Text extends Node {
	constructor(data) {
		super();
		this.nodeType = 3;
		this.data = data;
	}
}
const observers = [];
class MutationObserver {
	constructor(cb) {
		this.cb = cb;
	}
	observe(root, opts) {
		observers.push({ root, opts, mo: this });
	}
}
// a type change as the page makes it: observers of an ancestor root hear it (attributeOldValue)
const setType = (el, type) => {
	const old = el.type;
	el.type = type;
	el.attrs.type = type;
	for (const o of observers) {
		let inRoot = false;
		for (let n = el; n; n = n.parentNode || null) if (n === o.root) inRoot = true;
		if (inRoot) o.mo.cb([{ type: "attributes", attributeName: "type", oldValue: old, target: el }]);
	}
};
const walkAll = (root, out) => {
	for (const k of root.childNodes) {
		if (!(k instanceof Element)) continue;
		out.push(k);
		walkAll(k, out);
	}
	return out;
};
class Element extends Node {
	constructor(tag, attrs = {}) {
		super();
		this.nodeType = 1;
		this.tagName = tag.toUpperCase();
		this.attrs = { ...attrs };
		this.shadowRoot = null;
		this.isContentEditable = false;
		this.id = attrs.id || "";
	}
	getAttribute(k) {
		return k in this.attrs ? this.attrs[k] : null;
	}
	hasAttribute(k) {
		return k in this.attrs;
	}
	attachShadow() {
		this.shadowRoot = new ShadowRoot(this);
		return this.shadowRoot;
	}
	get isConnected() {
		return true;
	}
	querySelectorAll(sel) {
		return walkAll(this, []).filter((e) => sel === "*" || e.tagName === sel.toUpperCase());
	}
	getClientRects() {
		return [{ left: 0, top: 0, right: 10, bottom: 10 }];
	}
	checkVisibility() {
		return !this.hidden;
	}
	get textContent() {
		let t = "";
		const w = (n) => {
			if (n.nodeType === 3) t += n.data;
			else for (const k of n.childNodes) w(k);
		};
		w(this);
		return t;
	}
}
class HTMLElement extends Element {}
class HTMLUnknownElement extends HTMLElement {}
class HTMLInputElement extends HTMLElement {
	constructor(attrs = {}) {
		super("input", attrs);
		this.type = (attrs.type || "text").toLowerCase();
		this.readOnly = false;
		this.disabled = false;
		this.value = "";
		this.form = null;
		this.labels = [];
	}
}
class HTMLTextAreaElement extends HTMLElement {
	constructor(attrs = {}) {
		super("textarea", attrs);
		this.value = "";
		this.labels = [];
	}
}
class HTMLSelectElement extends HTMLElement {
	constructor(attrs = {}) {
		super("select", attrs);
	}
}
class ShadowRoot extends Node {
	constructor(host) {
		super();
		this.nodeType = 11;
		this.host = host;
		this.activeElement = null;
	}
	querySelectorAll(sel) {
		return walkAll(this, []).filter((e) => sel === "*" || e.tagName === sel.toUpperCase());
	}
}
const listeners = new Map();
const g = globalThis;
Object.assign(g, {
	Node,
	Element,
	HTMLElement,
	HTMLInputElement,
	HTMLTextAreaElement,
	HTMLSelectElement,
	HTMLUnknownElement,
	MutationObserver,
	innerWidth: 1000,
	innerHeight: 800,
	location: { origin: "https://a.example", href: "https://a.example/form" },
	// -webkit-user-modify read-only (no CSS-editable content); -webkit-text-security from a style attribute
	getComputedStyle: (el) => ({ getPropertyValue: (k) => (k === "-webkit-text-security" ? (el.attrs && el.attrs.security) || "none" : "read-only") }),
	window: {
		addEventListener: (t, f) => listeners.set(t, f),
		removeEventListener: (t) => listeners.delete(t),
	},
});
const body = new HTMLElement("body");
const byId = new Map();
const document = new Node();
Object.assign(document, { nodeType: 9, body, documentElement: body, activeElement: body, title: "Fake", getElementById: (id) => byId.get(id) || null, querySelectorAll: (sel) => body.querySelectorAll(sel) });
document.append(body);
g.document = document;
const act = (0, eval)(src);
const run = (req) => JSON.parse(act(req));
const focus = (el) => (document.activeElement = el);

let n = 0;
let failed = 0;
const test = (name, f) => {
	n++;
	try {
		f();
		console.log(`ok ${n} ${name}`);
	} catch (e) {
		failed++;
		console.log(`not ok ${n} ${name}: ${e.message.split("\n")[0]}`);
	}
};

// ---- the rule ----
test("a password input is sensitive (any case of type)", () => {
	for (const type of ["password", "PASSWORD"]) {
		const pw = new HTMLInputElement({ type });
		body.append(pw);
		focus(pw);
		assert.equal(run({ op: "check" }).sensitive, true, type);
	}
});
test("autocomplete: cc-*, current-password, new-password, one-time-code (with sections, billing, webauthn, any case)", () => {
	const yes = ["cc-number", "billing cc-exp", "section-pay shipping cc-csc", "CC-NAME", "cc-exp-month", "current-password", "new-password webauthn", "one-time-code", "username current-password", "section-x One-Time-Code"];
	const no = ["username", "email", "off", "on", "cc", "acc-number", "tel", "", "shipping street-address", "password", "otp"];
	for (const a of yes) {
		const el = new HTMLInputElement({ autocomplete: a });
		body.append(el);
		focus(el);
		assert.equal(run({ op: "check" }).sensitive, true, `autocomplete=${JSON.stringify(a)}`);
	}
	for (const a of no) {
		const el = new HTMLInputElement({ autocomplete: a });
		body.append(el);
		focus(el);
		assert.equal(run({ op: "check" }).sensitive, false, `autocomplete=${JSON.stringify(a)}`);
	}
});
test("a field inside a sensitive holder is sensitive", () => {
	const holder = new HTMLElement("div", { autocomplete: "cc-number" });
	const inner = new HTMLInputElement({});
	holder.append(new HTMLElement("span").append(inner));
	body.append(holder);
	focus(inner);
	assert.equal(run({ op: "check" }).sensitive, true);
	const plain = new HTMLElement("form", { autocomplete: "off" });
	const ok = new HTMLInputElement({});
	plain.append(ok);
	body.append(plain);
	focus(ok);
	assert.equal(run({ op: "check" }).sensitive, false);
});
test("shadow DOM: a sensitive host, a password input inside a shadow root (focus found through it)", () => {
	const host = new HTMLElement("pay-card", { autocomplete: "cc-number" });
	const sr = host.attachShadow();
	const inner = new HTMLInputElement({});
	sr.append(inner);
	sr.activeElement = inner;
	body.append(host);
	focus(host);
	let c = run({ op: "check" });
	assert.equal(c.sensitive, true, "inside a cc host");
	assert.equal(c.hit.tag, "input", "the inner input is the one focused");
	const host2 = new HTMLElement("log-in");
	const sr2 = host2.attachShadow();
	const wrap = new HTMLElement("div");
	const pw = new HTMLInputElement({ type: "password" });
	wrap.append(pw);
	sr2.append(wrap);
	sr2.activeElement = pw;
	body.append(host2);
	focus(host2);
	c = run({ op: "check" });
	assert.equal(c.sensitive, true, "a password input in a shadow root");
	sr2.activeElement = null;
	c = run({ op: "check" });
	assert.equal(c.sensitive, false, "the host alone (nothing inside focused)");
});
test("focus inside an iframe cannot be checked: frame", () => {
	const f = new HTMLElement("iframe");
	body.append(f);
	focus(f);
	const c = run({ op: "check" });
	assert.equal(c.frame, true);
	assert.equal(c.editable, false);
});

test("clear refuses a sensitive or framed focus", () => {
	const pw = new HTMLInputElement({ type: "password" });
	body.append(pw);
	focus(pw);
	assert.equal(run({ op: "clear" }).code, "sensitive_field");
	const f = new HTMLElement("iframe");
	body.append(f);
	focus(f);
	assert.equal(run({ op: "clear" }).code, "frame_focused");
});

// ---- what text keys may go to (kind) ----
test("kind: text for plain text inputs, textareas and contenteditable; field, none, opaque, frame, sensitive for the rest", () => {
	for (const type of ["text", "search", "email", "url", "tel", "number"]) {
		const el = new HTMLInputElement({ type });
		body.append(el);
		focus(el);
		const c = run({ op: "check" });
		assert.equal(c.kind, "text", type);
		assert.equal(c.editable, true, type);
	}
	const ta = new HTMLTextAreaElement({});
	body.append(ta);
	focus(ta);
	assert.equal(run({ op: "check" }).kind, "text", "textarea");
	const ce = new HTMLElement("div");
	ce.isContentEditable = true;
	body.append(ce);
	focus(ce);
	assert.equal(run({ op: "check" }).kind, "text", "contenteditable");
	for (const type of ["date", "time", "color", "checkbox", "range", "file"]) {
		const el = new HTMLInputElement({ type });
		body.append(el);
		focus(el);
		assert.equal(run({ op: "check" }).kind, "field", type);
	}
	const ro = new HTMLInputElement({});
	ro.readOnly = true;
	body.append(ro);
	focus(ro);
	assert.equal(run({ op: "check" }).kind, "field", "read-only");
	focus(body);
	assert.equal(run({ op: "check" }).kind, "none", "body");
	document.activeElement = null;
	assert.equal(run({ op: "check" }).kind, "none", "nothing");
	const btn = new HTMLElement("button");
	body.append(btn);
	focus(btn);
	assert.equal(run({ op: "check" }).kind, "none", "a button");
	// a custom element whose shadow root is closed (shadowRoot null): it cannot be checked
	const closed = new HTMLElement("secret-box");
	body.append(closed);
	focus(closed);
	assert.equal(run({ op: "check" }).kind, "opaque", "closed shadow root");
	const unk = new HTMLUnknownElement("blink");
	unk.isContentEditable = true;
	body.append(unk);
	focus(unk);
	assert.equal(run({ op: "check" }).kind, "opaque", "an unknown element");
	// open shadow roots are crossed: an editable inside is text
	const host = new HTMLElement("rich-editor");
	const sr = host.attachShadow();
	const inner = new HTMLElement("div");
	inner.isContentEditable = true;
	sr.append(inner);
	sr.activeElement = inner;
	body.append(host);
	focus(host);
	assert.equal(run({ op: "check" }).kind, "text", "contenteditable in an open shadow root");
	const f = new HTMLElement("iframe");
	body.append(f);
	focus(f);
	assert.equal(run({ op: "check" }).kind, "frame");
	const pw = new HTMLInputElement({ type: "password" });
	body.append(pw);
	focus(pw);
	assert.equal(run({ op: "check" }).kind, "sensitive");
	assert.equal(run({ op: "check" }).editable, false, "never editable for agents");
});
test("sensitive: autocomplete on the field's form (form= too), -webkit-text-security", () => {
	const form = new HTMLElement("form", { autocomplete: "section-a cc-number" });
	const el = new HTMLInputElement({});
	el.form = form; // form= attribute: not an ancestor
	body.append(form, el);
	focus(el);
	assert.equal(run({ op: "check" }).kind, "sensitive", "the form's autocomplete");
	const dots = new HTMLInputElement({ security: "disc" });
	body.append(dots);
	focus(dots);
	assert.equal(run({ op: "check" }).kind, "sensitive", "-webkit-text-security: disc");
	const plain = new HTMLInputElement({ security: "none" });
	body.append(plain);
	focus(plain);
	assert.equal(run({ op: "check" }).kind, "text", "-webkit-text-security: none");
});
test("a field ever seen as a password one stays sensitive (type flipped to text: show password)", () => {
	run({ op: "init" });
	const pw = new HTMLInputElement({ type: "password" });
	body.append(pw);
	run({ op: "check" }); // seen
	setType(pw, "text");
	focus(pw);
	assert.equal(run({ op: "check" }).kind, "sensitive", "revealed");
	// flipped before any check: the observer saw the old type
	const pw2 = new HTMLInputElement({ type: "password" });
	body.append(pw2);
	setType(pw2, "text");
	focus(pw2);
	assert.equal(run({ op: "check" }).kind, "sensitive", "the observer");
	// inside an open shadow root: watched once a check has seen the root
	const host = new HTMLElement("login-form");
	const sr = host.attachShadow();
	const pw3 = new HTMLInputElement({ type: "password" });
	sr.append(pw3);
	body.append(host);
	run({ op: "check" });
	setType(pw3, "text");
	sr.activeElement = pw3;
	focus(host);
	assert.equal(run({ op: "check" }).kind, "sensitive", "in a shadow root");
});
test("revealed: a visible ex-password (or password-autocomplete) field with text, never its value", () => {
	for (const el of walkAll(body, [])) el.hidden = true; // earlier tests' fields
	run({ op: "init" });
	assert.equal(run({ op: "revealed" }).revealed, 0, "nothing");
	const pw = new HTMLInputElement({ type: "password" });
	body.append(pw);
	pw.value = "hunter2";
	assert.equal(run({ op: "revealed" }).revealed, 0, "dots on screen");
	setType(pw, "text");
	const r = run({ op: "revealed" });
	assert.equal(r.revealed, 1, "shown");
	assert.ok(!JSON.stringify(r).includes("hunter2"), "never the value");
	pw.value = "";
	assert.equal(run({ op: "revealed" }).revealed, 0, "empty");
	pw.value = "x";
	pw.hidden = true;
	assert.equal(run({ op: "revealed" }).revealed, 0, "hidden");
	const ac = new HTMLInputElement({ type: "text", autocomplete: "current-password" });
	ac.value = "secret";
	body.append(ac);
	assert.equal(run({ op: "revealed" }).revealed, 1, "password autocomplete");
	ac.hidden = true;
});
test("no key guard any more: the op is unknown", () => {
	assert.equal(run({ op: "guard", on: true }).code, "bad_args");
});
test("file_el: only an <input type=file>, only on the origin the bar named", () => {
	const fi = new HTMLInputElement({ type: "file", id: "up" });
	byId.set("up", fi);
	const txt = new HTMLInputElement({ id: "t" });
	const act2 = (0, eval)(src);
	g.document.querySelectorAll = (sel) => (sel === "#up" ? [fi] : sel === "#t" ? [txt] : []);
	assert.equal(act2({ op: "file_el", sel: "#up", origin: "https://a.example" }), fi);
	assert.equal(JSON.parse(act2({ op: "file_el", sel: "#t", origin: "https://a.example" })).code, "not_a_file_input");
	assert.equal(JSON.parse(act2({ op: "file_el", sel: "#up", origin: "https://evil.example" })).code, "page_changed");
	g.document.querySelectorAll = (sel) => body.querySelectorAll(sel);
});
test("names from aria-labelledby and labels skip what is inside fields", () => {
	const lab = new HTMLElement("span", { id: "lab" });
	const inner = new HTMLTextAreaElement({});
	inner.append(new Text("typed secret"));
	lab.append(new Text("Note "), inner);
	byId.set("lab", lab);
	const el = new HTMLInputElement({ "aria-labelledby": "lab" });
	body.append(lab, el);
	focus(el);
	assert.equal(run({ op: "check" }).hit.name, "Note");
	const label = new HTMLElement("label");
	const sel = new HTMLSelectElement({});
	sel.append(new Text("Option text"));
	label.append(new Text("Size "), sel);
	const el2 = new HTMLInputElement({});
	el2.labels = [label];
	body.append(label, el2);
	focus(el2);
	assert.equal(run({ op: "check" }).hit.name, "Size");
});

// ---- round 2 ----
test("the tracker watches type changes only (no childList: no work per added node)", () => {
	run({ op: "init" });
	const docObs = observers.filter((o) => o.root === document);
	assert.ok(docObs.length >= 1, "observes the document");
	for (const o of docObs) {
		assert.equal(!!o.opts.childList, false, "no childList");
		assert.deepEqual(o.opts.attributeFilter, ["type"]);
		assert.equal(o.opts.attributeOldValue, true);
	}
});
test("plain: the page itself, a button or a link takes other keys; an unclassified element does not", () => {
	focus(body);
	assert.equal(run({ op: "check" }).plain, true, "body");
	const btn = new HTMLElement("button");
	body.append(btn);
	focus(btn);
	assert.equal(run({ op: "check" }).plain, true, "a button");
	const a = new HTMLElement("a", { href: "/x" });
	body.append(a);
	focus(a);
	assert.equal(run({ op: "check" }).plain, true, "a link");
	const div = new HTMLElement("div", { tabindex: "0" });
	body.append(div);
	focus(div);
	const c = run({ op: "check" });
	assert.equal(c.kind, "none");
	assert.equal(c.plain, false, "a focusable div (a custom widget)");
	const anchor = new HTMLElement("a");
	body.append(anchor);
	focus(anchor);
	assert.equal(run({ op: "check" }).plain, false, "an a without href");
});
if (failed) {
	console.log(`browser_act.js: ${failed} of ${n} tests failed`);
	process.exit(1);
}
console.log(`browser_act.js: ${n} tests passed`);
