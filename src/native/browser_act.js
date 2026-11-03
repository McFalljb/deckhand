// What an agent's actions need from the page (docs/BROWSER.md §4, step 8): browser_act.odin
// (#load). Evaluated as one expression in the "pi-desk" isolated world of the page's top frame
// (the overlay's world, as browser_read.js): the page's scripts share the DOM but not this
// world's globals or prototypes, so they cannot patch what it calls. The input itself (clicks,
// keys) is CDP's Input domain, sent by pi-desk; this only finds targets, checks fields and reports.
// Called as (THIS)(req); returns a JSON string (op "file_el": the element itself):
//   init    {}     the password tracker (also at every new document's start: browser_annotate.odin)
//   target  {sel?, x?, y?, center?, scroll, focus, need}   the element (a ref, a simple selector, or the
//           one at x,y): scrolled into view (scroll), focused (focus), its centre and what it is
//           → {x, y, hit, disabled?, covered?, active?, sensitive?, multiple?, origin?}
//           need: "any", "field" (typing: an editable text field), "select", "file"
//   check   {select?}  the focused element now (focus can move): {hit, kind, sensitive, frame,
//           editable, multiline, origin}; kind: "text" (where text keys may go: a plain text input,
//           a textarea or contenteditable in the top document, not sensitive), "field" (another
//           form field), "none" (body, a button, a link…), "opaque" (a custom element whose shadow
//           root is closed, an unknown element: cannot be checked), "frame" (focus is inside an
//           embedded document: cannot be checked), "sensitive"; plain: a "none" that is the page
//           itself or focusable by nature (a button, a link). select: a "text" target's content
//           is selected (clear: the text pi-desk inserts next replaces it)
//   revealed {}    how many password fields show their text now (type flipped by a "show
//           password" button, or a password autocomplete field with text): screenshots wait
//   select  {sel, label?, value?}  choose an option of a <select> (input and change events)
//   scroll  {x, y}  the scroll offsets: the page's and the scrollers' under x,y
//   file_el {sel, origin}   the file input itself (returnByValue false: DOM.setFileInputFiles takes
//           it), only an <input type=file> and only on the origin the upload bar named
// Errors: {error, code}. Never reads a field's value (revealed counts non-empty ones): names come
// from labels, and a hit inside a field or editable content is described as that field.
((req) => {
  const out = (o) => JSON.stringify(o);
  const one = (s, n) => String(s == null ? "" : s).replace(/\s+/g, " ").trim().slice(0, n);
  const fail = (code, error) => out({ code, error });
  const parentOf = (n) => n.parentElement || (n.parentNode && n.parentNode.host) || null;
  const cssEditable = (n) => {
    const m = getComputedStyle(n).getPropertyValue("-webkit-user-modify");
    return !!m && m !== "read-only";
  };
  const editableEl = (n) => n instanceof HTMLElement && (n.isContentEditable || cssEditable(n));
  const TEXTY = new Set(["text", "search", "email", "url", "tel", "number", "password", "date", "datetime-local", "month", "week", "time", ""]);
  // a form field's kind, or "" (as browser_read.js)
  const fieldKind = (el) => {
    if (el instanceof HTMLInputElement) {
      const t = (el.type || "text").toLowerCase();
      if (t === "hidden") return "hidden";
      if (t === "submit" || t === "reset" || t === "button" || t === "image") return "";
      if (t === "checkbox" || t === "radio" || t === "file") return t;
      return t === "password" ? "password" : "textbox";
    }
    if (el instanceof HTMLTextAreaElement) return "textbox";
    if (el instanceof HTMLSelectElement) return "combobox";
    if (editableEl(el) && !(el.parentElement && editableEl(el.parentElement))) return "editable";
    return "";
  };
  const LIST = new Set(["SELECT", "OPTION", "OPTGROUP", "DATALIST"]);
  // the outermost field, option list or editable content holding el (el itself included), or null
  const holderOf = (el) => {
    let found = null;
    for (let n = el; n; n = parentOf(n)) {
      if (!(n instanceof Element)) continue;
      const k = fieldKind(n);
      if ((k && k !== "editable") || LIST.has(n.tagName) || n instanceof HTMLTextAreaElement || editableEl(n)) found = n;
    }
    return found;
  };
  // what holds el when that is not el itself (a field's or a draft's inside), or null
  const inside = (el) => {
    const h = holderOf(el);
    return h && h !== el ? h : null;
  };

  // ---- the sensitive-field rule ----
  // A password input, a field ever seen as one (its type flipped by a "show password" button), a
  // field drawn as dots (-webkit-text-security), anything whose autocomplete (or its form's) names
  // a card (cc-*), a password or a one-time code, or anything inside such an element (shadow hosts
  // crossed): agents never type, press or choose there.
  const SENSITIVE_TOKENS = new Set(["current-password", "new-password", "one-time-code"]);
  const isPw = (n) => n instanceof HTMLInputElement && String(n.type || "").toLowerCase() === "password";
  // the tracker: every element seen as a password field, for as long as the document lives (this
  // world's globals: the page cannot reach them)
  const PW = globalThis.__pdPw || (globalThis.__pdPw = new WeakSet());
  const WATCHED = globalThis.__pdWatched || (globalThis.__pdWatched = new WeakSet());
  const watch = (root) => {
    if (!root || WATCHED.has(root) || typeof MutationObserver !== "function") return;
    WATCHED.add(root);
    // type changes only (a field's old type tells): no work per added node on busy pages
    new MutationObserver((recs) => {
      for (const r of recs) if (String(r.oldValue || "").toLowerCase() === "password" || isPw(r.target)) PW.add(r.target);
    }).observe(root, { subtree: true, attributes: true, attributeFilter: ["type"], attributeOldValue: true });
  };
  // every element of root and its open shadow roots
  const deepAll = (root, out) => {
    for (const e of root.querySelectorAll("*")) {
      out.push(e);
      if (e.shadowRoot) deepAll(e.shadowRoot, out);
    }
    return out;
  };
  // the tracker brought up to date: password fields now, open shadow roots watched
  const scan = () => {
    watch(document);
    const all = deepAll(document, []);
    for (const e of all) {
      if (isPw(e)) PW.add(e);
      if (e.shadowRoot) watch(e.shadowRoot);
    }
    return all;
  };
  const acSensitive = (n) => {
    const a = n && n.getAttribute && n.getAttribute("autocomplete");
    if (!a) return false;
    return a.toLowerCase().split(/\s+/).some((t) => t.startsWith("cc-") || SENSITIVE_TOKENS.has(t));
  };
  const sensitiveSelf = (n) => {
    if (!(n instanceof Element)) return false;
    if (isPw(n) || PW.has(n) || acSensitive(n)) return true;
    if (n.form && acSensitive(n.form)) return true;
    const ts = getComputedStyle(n).getPropertyValue("-webkit-text-security");
    return !!ts && ts !== "none";
  };
  const sensitive = (el) => {
    for (let n = el; n; n = parentOf(n)) if (sensitiveSelf(n)) return true;
    return false;
  };
  // the focused element, through open shadow roots; frame: focus is inside an embedded document
  const deepActive = () => {
    let a = document.activeElement;
    while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
    const frame = !!a && /^(IFRAME|FRAME|OBJECT|EMBED|FENCEDFRAME|PORTAL)$/.test(a.tagName);
    return { el: a, frame };
  };
  // where text keys may go: a plain text input, a textarea, contenteditable (allowlisted)
  const TEXT_TYPES = new Set(["text", "search", "email", "url", "tel", "number", ""]);
  const textTarget = (el) => {
    if (el instanceof HTMLInputElement) return TEXT_TYPES.has(String(el.type || "").toLowerCase()) && !el.readOnly && !el.disabled;
    if (el instanceof HTMLTextAreaElement) return !el.readOnly && !el.disabled;
    return el instanceof HTMLElement && el.isContentEditable === true;
  };
  // what cannot be checked: an unknown element, a custom element without an open shadow root (a
  // closed one, or its insides out of reach)
  const opaque = (el) => (typeof HTMLUnknownElement === "function" && el instanceof HTMLUnknownElement) || (el.tagName.includes("-") && !el.shadowRoot);
  // what other keys (Backspace, Delete, shortcuts) may go to besides a field: the page itself, or
  // an element focusable by nature (a button, a link…) that is not editable
  const plainTarget = (el) => {
    if (!el) return true;
    if (el instanceof HTMLElement && (el.isContentEditable || editableEl(el))) return false;
    const t = el.tagName;
    if (t === "BUTTON" || t === "SUMMARY" || t === "DETAILS") return true;
    if ((t === "A" || t === "AREA") && el.hasAttribute("href")) return true;
    if ((t === "VIDEO" || t === "AUDIO") && el.hasAttribute("controls")) return true;
    return false;
  };
  const multiline = (el) => el instanceof HTMLTextAreaElement || (el instanceof HTMLElement && !(el instanceof HTMLInputElement) && editableEl(el));

  // ---- what an element is (page data: names from labels and text, never a field's value) ----
  const labelOf = (el) => {
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const t = by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((e) => textName(e)).join(" ");
      if (one(t, 120)) return one(t, 120);
    }
    const a = el.getAttribute("aria-label");
    if (a) return one(a, 120);
    if (el.labels && el.labels[0]) {
      const t = textName(el.labels[0]);
      if (t) return t;
    }
    return one(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || el.id, 120);
  };
  // visible text of el, skipping anything inside a field or editable content
  const textName = (el) => {
    let s = "";
    const walk = (n) => {
      if (s.length > 120) return;
      if (n.nodeType === 3) {
        s += n.data;
        return;
      }
      if (n.nodeType !== 1 && n.nodeType !== 11) return;
      if (n.nodeType === 1) {
        if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(n.tagName)) return;
        if (holderOf(n)) return;
        if (n.tagName === "IMG") {
          s += " " + (n.getAttribute("alt") || "") + " ";
          return;
        }
      }
      for (const k of n.shadowRoot ? n.shadowRoot.childNodes : n.childNodes) walk(k);
    };
    walk(el);
    return one(s, 120);
  };
  const roleOf = (el) => {
    const r = one(el.getAttribute("role"), 30).split(" ")[0];
    if (r) return r;
    const k = fieldKind(el);
    if (k) return k === "file" ? "file input" : k;
    const t = el.tagName;
    if (/^H[1-6]$/.test(t)) return "heading";
    if (t === "A" && el.hasAttribute("href")) return "link";
    if (t === "BUTTON" || (el instanceof HTMLInputElement && /^(submit|reset|button|image)$/i.test(el.type))) return "button";
    if (t === "IMG") return "img";
    return t.toLowerCase();
  };
  const refOf = (el) => {
    const refs = globalThis.__pdRefs;
    if (!refs) return "";
    for (const [k, w] of refs) if (w.deref() === el) return `ref=${k}`;
    return "";
  };
  const describe = (el) => {
    if (!el || !(el instanceof Element)) return { role: "document", name: one(document.title, 120), tag: "" };
    const h = inside(el);
    if (h) el = h; // a part of a field or draft: the field
    if (LIST.has(el.tagName) && el.tagName !== "SELECT") for (let n = el; n; n = parentOf(n)) if (n instanceof HTMLSelectElement) el = n;
    const role = roleOf(el);
    let name = "";
    if (fieldKind(el)) name = labelOf(el);
    else if (el instanceof HTMLInputElement) name = one(el.value || el.type, 120); // a submit button's label
    else name = one(el.getAttribute("aria-label"), 120) || textName(el) || one(el.getAttribute("title"), 120) || one(el.getAttribute("alt"), 120);
    const o = { role, name, tag: el.tagName.toLowerCase() };
    const ref = refOf(el);
    if (ref) o.ref = ref;
    return o;
  };

  // ---- finding the target ----
  const visible = (el) => {
    if (typeof el.checkVisibility === "function") return el.checkVisibility({ visibilityProperty: true });
    const s = getComputedStyle(el);
    return s.display !== "none" && s.visibility !== "hidden";
  };
  // a ref, or the first match of a simple selector outside fields' insides (visible first)
  const resolve = (sel) => {
    const m = /^ref=(e\d+)$/.exec(sel);
    if (m) {
      const refs = globalThis.__pdRefs;
      const w = refs && refs.get(m[1]);
      const el = w && w.deref();
      if (!el || !el.isConnected) return { error: `nothing on the page has ref ${m[1]} now (refs last until the next outline or navigation; read an outline again)`, code: "not_found" };
      return { el };
    }
    let all = [];
    try {
      all = document.querySelectorAll(sel);
    } catch (e) {
      return { error: `not a valid CSS selector: ${one(sel, 200)}`, code: "bad_args" };
    }
    let first = null;
    for (const el of all) {
      if (inside(el)) continue;
      if (visible(el)) return { el };
      first = first || el;
    }
    if (first) return { el: first };
    return { error: `nothing on the page matches ${one(sel, 200)}`, code: "not_found" };
  };
  const deepAt = (x, y) => {
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  };
  const contains = (outer, el) => {
    for (let n = el; n; n = parentOf(n)) if (n === outer) return true;
    return false;
  };
  // the centre of el's first box that shows in the viewport (null: none does)
  const centre = (el) => {
    const vw = innerWidth;
    const vh = innerHeight;
    for (const r of el.getClientRects()) {
      const x0 = Math.max(r.left, 0);
      const y0 = Math.max(r.top, 0);
      const x1 = Math.min(r.right, vw);
      const y1 = Math.min(r.bottom, vh);
      if (x1 - x0 >= 1 && y1 - y0 >= 1) return { x: (x0 + x1) / 2, y: (y0 + y1) / 2 };
    }
    return null;
  };

  // ---- the focused element ----
  const activeInfo = () => {
    scan();
    const d = deepActive();
    const el = d.el && d.el !== document.body && d.el !== document.documentElement ? d.el : null;
    let kind = "none";
    if (d.frame) kind = "frame";
    else if (!el) kind = "none";
    else if (sensitive(el)) kind = "sensitive";
    else if (opaque(el)) kind = "opaque";
    else if (textTarget(el)) kind = "text";
    else if (fieldKind(el) || editableEl(el)) kind = "field";
    return {
      hit: describe(el),
      kind,
      sensitive: kind === "sensitive",
      frame: d.frame,
      editable: kind === "text",
      multiline: kind === "text" && multiline(el),
      plain: kind === "none" && plainTarget(el),
      origin: location.origin,
      el,
    };
  };

  const op = req && req.op;
  if (op === "init") {
    scan();
    return out({ ok: true });
  }
  if (op === "check") {
    const o = activeInfo();
    const el = o.el;
    delete o.el;
    if (req.select && o.kind === "text") {
      if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) el.select();
      else {
        const r = document.createRange();
        r.selectNodeContents(el);
        const s = getSelection();
        s.removeAllRanges();
        s.addRange(r);
      }
    }
    return out(o);
  }
  if (op === "clear") {
    // (kept for a direct call; browser_act.odin clears with check {select})
    const o = activeInfo();
    if (o.kind === "frame") return fail("frame_focused", "focus is inside an embedded frame");
    if (o.kind !== "text") return fail(o.kind === "sensitive" ? "sensitive_field" : "not_a_field", "the focused element cannot be cleared by an agent");
    return out({ ok: true });
  }
  if (op === "revealed") {
    let n = 0;
    for (const e of scan()) {
      if (!(e instanceof HTMLInputElement) || isPw(e)) continue;
      if (!PW.has(e) && !String(e.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/).some((t) => t === "current-password" || t === "new-password")) continue;
      if (!(String(e.value || "").length > 0) || !visible(e) || !centre(e)) continue;
      n++;
    }
    return out({ revealed: n });
  }
  if (op === "scroll") {
    let inner = 0;
    for (let n = deepAt(req.x, req.y); n; n = parentOf(n)) if (n instanceof Element) inner += n.scrollTop + n.scrollLeft;
    return out({ x: Math.round(scrollX), y: Math.round(scrollY), inner: Math.round(inner) });
  }
  if (op === "file_el") {
    if (location.origin !== req.origin) return fail("page_changed", "the page is not on the origin the upload bar named: nothing was sent");
    const f = resolve(req.sel);
    if (f.error) return fail(f.code, f.error);
    if (!(f.el instanceof HTMLInputElement && String(f.el.type).toLowerCase() === "file")) return fail("not_a_file_input", "the target is not a file input now: nothing was sent");
    return f.el;
  }
  if (op === "select") {
    const f = resolve(req.sel);
    if (f.error) return fail(f.code, f.error);
    const el = f.el;
    if (!(el instanceof HTMLSelectElement)) return fail("not_a_select", `the target is a ${roleOf(el)}, not a select (a dropdown); click custom dropdowns instead`);
    if (sensitive(el)) return fail("sensitive_field", "this is a card, password or one-time-code field");
    if (el.disabled) return fail("disabled", "the select is disabled");
    const opts = Array.from(el.options);
    let pick = null;
    if (typeof req.label === "string") pick = opts.find((o) => one(o.label || o.text, 500) === one(req.label, 500)) || opts.find((o) => one(o.label || o.text, 500).toLowerCase() === one(req.label, 500).toLowerCase());
    else if (typeof req.value === "string") pick = opts.find((o) => o.value === req.value);
    if (!pick) {
      // the options (not which one is chosen: that is the field's value)
      const labels = opts.slice(0, 50).map((o) => one(o.label || o.text, 80));
      return out({ code: "no_option", error: `no option with that ${typeof req.label === "string" ? "label" : "value"}; the options are: ${JSON.stringify(labels)}${opts.length > 50 ? ` (and ${opts.length - 50} more)` : ""}` });
    }
    if (pick.disabled) return fail("disabled", "that option is disabled");
    el.focus({ preventScroll: true });
    pick.selected = true;
    el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return out({ hit: describe(el), chosen: { label: one(pick.label || pick.text, 120) } });
  }
  if (op === "target") {
    let el = null;
    let x = req.x;
    let y = req.y;
    if (req.sel) {
      const f = resolve(req.sel);
      if (f.error) return fail(f.code, f.error);
      el = f.el;
      if (!visible(el)) return fail("not_found", `${describe(el).role} ${JSON.stringify(describe(el).name)} is not visible`);
      if (req.scroll !== false) el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
      const c = centre(el);
      if (!c) return fail("not_found", `${describe(el).role} ${JSON.stringify(describe(el).name)} is not in the viewport (it has no box on screen)`);
      x = c.x;
      y = c.y;
    } else {
      if (req.center) {
        x = innerWidth / 2;
        y = innerHeight / 2;
      }
      if (!(x >= 0 && y >= 0 && x < innerWidth && y < innerHeight)) return fail("bad_args", `x,y must be inside the viewport (0..${innerWidth - 1}, 0..${innerHeight - 1})`);
      el = deepAt(x, y);
    }
    const o = { x, y, hit: describe(el) };
    if (el && (el.disabled || el.getAttribute("aria-disabled") === "true")) o.disabled = true;
    if (req.sel) {
      const top = deepAt(x, y);
      if (top && !contains(el, top) && !contains(top, el)) o.covered = describe(top);
      else if (!top) o.covered = { role: "nothing", name: "", tag: "" };
    }
    if (req.need === "select" && !(el instanceof HTMLSelectElement)) return fail("not_a_select", "the target is not a select");
    if (req.need === "file") {
      if (!(el instanceof HTMLInputElement && String(el.type).toLowerCase() === "file")) return fail("not_a_file_input", `the target is a ${roleOf(el)}, not a file input (<input type=file>)`);
      o.multiple = !!el.multiple;
      o.origin = location.origin;
    }
    o.sensitive = !!el && sensitive(el);
    if (req.focus && el && req.sel) {
      if (typeof el.focus === "function") el.focus({ preventScroll: true });
    }
    if (req.focus || req.need === "field") {
      const a = activeInfo();
      delete a.el;
      o.active = a;
    }
    return out(o);
  }
  return fail("bad_args", `unknown op ${one(op, 40)}`);
})
