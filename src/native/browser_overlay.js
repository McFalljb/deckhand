// Deckhand's annotation overlay (docs/BROWSER.md §3.2-3.5), embedded in Deckhand
// (src/browser_annotate.odin, #load) and run in the "deckhand" isolated world of
// each page's top frame: Page.addScriptToEvaluateOnNewDocument for new
// documents, Page.createIsolatedWorld + Runtime.evaluate for the one already
// there. The page's scripts share the DOM but not this world's globals, and
// the binding (__pdAnnot, Runtime.addBinding with executionContextName) exists
// here only: a page cannot call it.
//
// The page finds, Deckhand draws: nothing is added to the DOM. Deckhand calls
// __pd.* (Runtime.evaluate in this world, numbers and JSON only); answers and
// changes go back through the binding as one JSON string each:
//   hello  {url, title, sx, sy, vw, vh}           a document is ready (or came back from the cache)
//   hover  {seq, r: [x,y,w,h] | null, label}      the element under a viewport point
//   pick   {seq, tag, type, role, name, sel, text, r, sx, sy, url, title}   an element picked
//   area   {seq, r, els: [selectors], sx, sy, url, title}             an area dragged
//   layout {sx, sy, vw, vh, url, m: [[id, x, y, w, h] | [id]]}        markers in document px
//                                                  (only when something changed, and only while
//                                                  there are markers or comment mode is on)
// Rects: CSS px; r is in the viewport, layout's in the document (scroll added).
// Element text is capped (TEXT_MAX). What the user typed or chose is never
// read: an input's, textarea's or select's value and editable content's text
// are "[value hidden]" (the field's name, placeholder, label and type are said
// instead), whatever the field's type or autocomplete.
(() => {
  if (window !== window.top) return; // the top document only (iframes: later)
  // own property only: an element with id="__pd" is a named property of the window, not ours
  if (Object.prototype.hasOwnProperty.call(globalThis, "__pd")) {
    globalThis.__pd.hello();
    return;
  }
  const TEXT_MAX = 500;
  const post = (m) => {
    const f = globalThis.__pdAnnot;
    if (typeof f === "function") f(JSON.stringify(m));
  };
  const R = (v) => Math.round(v);
  const viewRect = (el) => {
    const r = el.getBoundingClientRect();
    return [R(r.x), R(r.y), R(r.width), R(r.height)];
  };
  const one = (s, n) => String(s || "").replace(/\s+/g, " ").trim().slice(0, n);

  // the element under a viewport point, into open shadow roots
  const at = (x, y) => {
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  };

  // A selector for el: tag#id, or tag.class:nth-of-type(n) under parents until unique.
  const part = (el) => {
    const tag = el.tagName.toLowerCase();
    if (el.id) return tag + "#" + CSS.escape(el.id);
    let s = tag;
    const cls = typeof el.className === "string" ? el.className.trim().split(/\s+/).filter(Boolean).slice(0, 2) : [];
    if (cls.length) s += "." + cls.map((c) => CSS.escape(c)).join(".");
    const p = el.parentElement;
    if (p) {
      const same = Array.from(p.children).filter((c) => c.tagName === el.tagName);
      if (same.length > 1) s += ":nth-of-type(" + (same.indexOf(el) + 1) + ")";
    }
    return s;
  };
  const unique = (s) => {
    try {
      return document.querySelectorAll(s).length === 1;
    } catch (e) {
      return false;
    }
  };
  const selectorFor = (el) => {
    let s = part(el);
    let cur = el;
    for (let i = 0; i < 6 && !unique(s); i++) {
      cur = cur.parentElement;
      if (!cur || cur === document.documentElement) break;
      s = part(cur) + " > " + s;
    }
    return s;
  };

  const field = (el) =>
    el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement || el.isContentEditable;
  // The user's input inside: a field, or editable content (by attribute or by CSS), in el's subtree
  // and open shadow roots. Past WALK_MAX nodes it is assumed to hold some (fail closed).
  const WALK_MAX = 2000;
  // editable by CSS alone (isContentEditable stays false for it in Chromium)
  const cssEditable = (n) => {
    const m = getComputedStyle(n).getPropertyValue("-webkit-user-modify");
    return !!m && m !== "read-only";
  };
  const holdsInput = (el) => {
    const todo = [el];
    let seen = 0;
    while (todo.length) {
      const n = todo.pop();
      if (++seen > WALK_MAX) return true;
      if (n instanceof HTMLElement && (field(n) || cssEditable(n))) return true;
      if (n.shadowRoot) todo.push(n.shadowRoot);
      for (let c = n.firstElementChild; c; c = c.nextElementSibling) todo.push(c);
    }
    return false;
  };
  const textOf = (el) => (holdsInput(el) ? "[value hidden]" : one(el.innerText || el.textContent, TEXT_MAX));
  const nameOf = (el) => {
    const a = el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt");
    if (a) return one(a, 200);
    if (el.labels && el.labels[0]) return one(el.labels[0].innerText, 200);
    return one(el.getAttribute("placeholder") || el.getAttribute("name"), 200);
  };
  const page = () => ({
    sx: R(scrollX), sy: R(scrollY), vw: R(innerWidth), vh: R(innerHeight), url: location.href, title: one(document.title, 300),
  });

  // picked elements (by pick seq): a marker follows the element itself while it is connected
  const picked = new Map();
  let markers = []; // [{id, k: "e"|"a", sel, seq, box}]
  let commenting = false; // comment mode: scroll and viewport are reported without markers too
  let last = "";

  const report = () => {
    if (!markers.length && !commenting) return;
    const p = page();
    const m = [];
    for (const k of markers) {
      if (k.k !== "e") continue;
      let el = picked.get(k.seq);
      if (!el || !el.isConnected) {
        el = null;
        try {
          el = document.querySelector(k.sel);
        } catch (e) {}
        if (el) picked.set(k.seq, el);
      }
      if (!el) {
        m.push([k.id]);
        continue;
      }
      const r = el.getBoundingClientRect();
      m.push([k.id, R(r.x + scrollX), R(r.y + scrollY), R(r.width), R(r.height)]);
    }
    const msg = JSON.stringify([p.sx, p.sy, p.vw, p.vh, p.url, m]);
    if (msg === last) return;
    last = msg;
    post(Object.assign({ t: "layout", m }, p));
  };
  let queued = false;
  const soon = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      report();
    });
  };
  addEventListener("scroll", soon, { passive: true, capture: true });
  addEventListener("resize", soon, { passive: true });
  // layout that moves without a scroll (content added, an animation): checked now and then
  setInterval(() => {
    if (markers.length) report();
  }, 400);

  globalThis.__pd = {
    hello() {
      last = "";
      post(Object.assign({ t: "hello" }, page()));
    },
    probe(kind, x, y, seq) {
      const el = at(x, y);
      if (kind === "hover") {
        post({ t: "hover", seq, r: el ? viewRect(el) : null, label: el ? one(part(el), 120) : "" });
        return;
      }
      if (!el) return;
      if (picked.size > 64) picked.delete(picked.keys().next().value);
      picked.set(seq, el);
      post(Object.assign({
        t: "pick", seq, tag: el.tagName.toLowerCase(), type: field(el) && el.type ? one(el.type, 40) : "",
        role: one(el.getAttribute("role"), 40), name: nameOf(el),
        sel: selectorFor(el), text: textOf(el), r: viewRect(el),
      }, page()));
    },
    // the elements an area mostly covers (outermost first, at most 5)
    area(x, y, w, h, seq) {
      const els = [];
      const seen = [];
      const all = document.body ? document.body.getElementsByTagName("*") : [];
      for (let i = 0; i < all.length && i < 5000 && els.length < 5; i++) {
        const el = all[i];
        if (seen.some((s) => s.contains(el))) continue;
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) continue;
        const ix = Math.max(0, Math.min(r.right, x + w) - Math.max(r.left, x));
        const iy = Math.max(0, Math.min(r.bottom, y + h) - Math.max(r.top, y));
        if (ix * iy < 0.6 * r.width * r.height) continue;
        seen.push(el);
        els.push(selectorFor(el));
      }
      post(Object.assign({ t: "area", seq, r: [R(x), R(y), R(w), R(h)], els }, page()));
    },
    // the markers to follow in this document (Deckhand's list replaces the last one), and comment mode
    track(list, on) {
      markers = Array.isArray(list) ? list : [];
      commenting = !!on;
      last = "";
      report();
    },
  };
  addEventListener("pageshow", (e) => {
    if (e.persisted) globalThis.__pd.hello(); // back from the cache: a new context may be listening
  });
  globalThis.__pd.hello();
})();
