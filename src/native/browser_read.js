// What an agent reads from a page (docs/BROWSER.md §4, step 7): browser_read and browser_wait
// (src/browser_agent.odin, #load). Evaluated as one expression in the "pi-desk" isolated world of
// the page's top frame (the overlay's world, Runtime.evaluate with its contextId): the page's
// scripts share the DOM but not this world's globals or prototypes. Called as
// (THIS)(mode, selector, max, value); returns a JSON string:
//   text     {url, title, text, chars, truncated, frames}  the visible text, blocks on their own lines
//   outline  {url, title, text, chars, truncated, frames}  one line per heading, landmark, link,
//            control, image and text run, indented by nesting: `e3 button "Save"`. The ref (e3)
//            names the element for later calls (selector "ref=e3") until the next outline or
//            navigation.
//   html     {url, title, text, chars, truncated, frames}  the element's HTML (values hidden)
//   has_selector {found}   an element matches the selector and is visible
//   has_text     {found}   the visible text (as `text` reads it) contains value
//   ready        {ready}   document.readyState is "complete"
// Errors: {error}. Form values are never read (as comment mode, browser_overlay.js): an input's,
// textarea's or select's value, a checkbox's state and editable content's text are
// "[value hidden]", with the field's kind and name instead. A CSS selector never lands inside a
// field, a select's options or editable content (firstMatch: a match only there is "nothing
// matches", as a real miss); a ref there reads only the field's line (html: "[value hidden]"), and
// has_text never finds anything there. html mode drops scripts' text and the content of
// csrf/token/nonce metas. Selectors are simple CSS (tags, #ids, .classes, spaces, >) or refs,
// checked before this runs (browser_agent.odin, agent_selector_ok). Iframes are not looked into (frames:
// how many there are). `max` caps the text (chars), cut at the end with truncated: true.
((mode, selector, max, value) => {
  const out = (o) => JSON.stringify(o);
  const one = (s, n) => String(s == null ? "" : s).replace(/\s+/g, " ").trim().slice(0, n);
  const HIDDEN = "[value hidden]";
  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "TITLE"]);
  const BLOCK = new Set(["ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "BODY", "DD", "DETAILS", "DIALOG", "DIV", "DL", "DT", "FIELDSET", "FIGCAPTION", "FIGURE", "FOOTER", "FORM", "H1", "H2", "H3", "H4", "H5", "H6", "HEADER", "HR", "LI", "MAIN", "NAV", "OL", "P", "PRE", "SECTION", "SUMMARY", "TABLE", "TR", "UL", "CAPTION", "THEAD", "TBODY", "TFOOT", "LEGEND", "OPTION"]);
  const WALK_MAX = 50000; // nodes looked at; past it the text says it stopped
  const cap = Math.max(100, Math.min(Number(max) || 20000, 200000));

  const visible = (el) => {
    if (typeof el.checkVisibility === "function") return el.checkVisibility({ visibilityProperty: true });
    const s = getComputedStyle(el);
    return s.display !== "none" && s.visibility !== "hidden";
  };
  const cssEditable = (n) => {
    const m = getComputedStyle(n).getPropertyValue("-webkit-user-modify");
    return !!m && m !== "read-only";
  };
  const editable = (el) => el.isContentEditable || cssEditable(el);
  const labelOf = (el) => {
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const t = by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((e) => e.textContent).join(" ");
      if (one(t, 200)) return one(t, 200);
    }
    const a = el.getAttribute("aria-label");
    if (a) return one(a, 200);
    if (el.labels && el.labels[0]) return one(el.labels[0].textContent, 200);
    return one(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || el.id, 200);
  };
  // a form field: its kind (textbox, checkbox, …), or "" (not a field)
  const fieldKind = (el) => {
    if (el instanceof HTMLInputElement) {
      const t = (el.type || "text").toLowerCase();
      if (t === "hidden") return "hidden";
      if (t === "submit" || t === "reset" || t === "button" || t === "image") return "";
      if (t === "checkbox" || t === "radio") return t;
      return t === "password" ? "password" : "textbox";
    }
    if (el instanceof HTMLTextAreaElement) return "textbox";
    if (el instanceof HTMLSelectElement) return "combobox";
    if (el instanceof HTMLElement && editable(el) && !(el.parentElement && editable(el.parentElement))) return "editable";
    return "";
  };
  const fieldLine = (el, kind) => `[${kind} ${JSON.stringify(labelOf(el))}: ${HIDDEN}]`;
  // the element, crossing shadow roots
  const parentOf = (n) => n.parentElement || (n.parentNode && n.parentNode.host) || null;
  // What holds el's content as a value: el itself or an ancestor that is a field, a select's
  // option list or editable content (the outermost such one), else null. A selector that starts
  // inside it (`#card option`, `[contenteditable] p`) reads nothing of it.
  const LIST = new Set(["SELECT", "OPTION", "OPTGROUP", "DATALIST"]);
  const holderOf = (el) => {
    let found = null;
    for (let n = el; n; n = parentOf(n)) {
      if (!(n instanceof Element)) continue;
      const k = fieldKind(n);
      if ((k && k !== "editable") || LIST.has(n.tagName) || n instanceof HTMLTextAreaElement) found = n;
      else if (n instanceof HTMLElement && (n.isContentEditable || cssEditable(n))) found = n;
    }
    return found;
  };
  // inside a holder (not the field element itself, which the readers hide on their own)
  const inside = (el) => {
    const h = holderOf(el);
    if (!h) return null;
    if (h === el && fieldKind(el) && !LIST.has(el.tagName)) return null;
    return h;
  };
  const holderLine = (h) => {
    let field = h;
    for (let n = h; n; n = parentOf(n)) if (n instanceof HTMLSelectElement) field = n;
    const kind = fieldKind(field) || (LIST.has(field.tagName) ? "list" : "editable");
    return fieldLine(field, kind);
  };
  // children to walk: an open shadow root's (with slots' assigned nodes), else the light DOM's
  const kids = (n) => {
    if (n.shadowRoot) return Array.from(n.shadowRoot.childNodes);
    if (n instanceof HTMLSlotElement) {
      const a = n.assignedNodes({ flatten: true });
      return a.length ? a : Array.from(n.childNodes);
    }
    return Array.from(n.childNodes);
  };
  const frames = document.querySelectorAll("iframe, frame").length;
  let root = document.body || document.documentElement;
  // The first element matching a CSS selector that is not inside a field, a select's options or
  // editable content (and visible, if asked): what is in there never counts, so a selector that
  // matches only there is a miss like any other (its presence would tell what was typed).
  // Returns {el} or {error}.
  const firstMatch = (sel, mustShow) => {
    let all = [];
    try {
      all = document.querySelectorAll(sel);
    } catch (e) {
      return { error: `not a valid CSS selector: ${one(sel, 200)}` };
    }
    for (const el of all) if (!inside(el) && (!mustShow || visible(el))) return { el };
    return { el: null };
  };
  if (mode === "has_selector") {
    if (!selector) return out({ error: "selector is needed" });
    const f = firstMatch(selector, true);
    return f.error ? out({ error: f.error }) : out({ found: !!f.el });
  }
  if (selector) {
    const m = /^ref=(e\d+)$/.exec(selector);
    if (m) {
      const refs = globalThis.__pdRefs;
      const w = refs && refs.get(m[1]);
      root = w && w.deref();
      if (!root || !root.isConnected) return out({ error: `nothing on the page has ref ${m[1]} now (refs last until the next outline or navigation)` });
    } else {
      const f = firstMatch(selector, false);
      if (f.error) return out({ error: f.error });
      root = f.el;
      if (!root) return out({ error: `nothing on the page matches ${one(selector, 200)}` });
    }
  }
  const page = { url: location.href, title: one(document.title, 300), frames };
  // a ref (from our own outline) to a part inside a field, an option list or a draft: only that it
  // is one (a CSS selector never lands there: firstMatch)
  const holder = selector ? inside(root) : null;

  // ---- text: the visible text, blocks on their own lines ----
  const textOf = (start) => {
    const parts = [];
    let seen = 0;
    let stopped = false;
    const walk = (n) => {
      if (stopped) return;
      if (++seen > WALK_MAX) {
        stopped = true;
        return;
      }
      if (n.nodeType === 3) {
        const t = n.data.replace(/\s+/g, " ");
        if (t.trim()) parts.push(t);
        return;
      }
      if (n.nodeType === 11) return kids(n).forEach(walk);
      if (n.nodeType !== 1) return;
      const el = n;
      if (SKIP.has(el.tagName)) return;
      if (!visible(el) && el !== start) return;
      const kind = fieldKind(el);
      if (kind === "hidden") return;
      if (kind) {
        parts.push(" " + fieldLine(el, kind) + " ");
        return;
      }
      if (el.tagName === "IFRAME" || el.tagName === "FRAME") {
        parts.push(" [frame] ");
        return;
      }
      if (el instanceof HTMLInputElement) {
        parts.push(` [button ${JSON.stringify(one(el.value || el.type, 100))}] `); // submit/reset/button: its label
        return;
      }
      if (el.tagName === "BR") return void parts.push("\n");
      if (el.tagName === "IMG") {
        const alt = one(el.getAttribute("alt"), 200);
        if (alt) parts.push(` [image ${JSON.stringify(alt)}] `);
        return;
      }
      const block = BLOCK.has(el.tagName);
      const head = /^H[1-6]$/.test(el.tagName);
      if (block) parts.push("\n");
      if (head) parts.push("#".repeat(Number(el.tagName[1])) + " ");
      if (el.tagName === "LI") parts.push("- ");
      if (el.tagName === "TD" || el.tagName === "TH") parts.push(" | ");
      kids(el).forEach(walk);
      if (block) parts.push("\n");
    };
    walk(start);
    let s = parts.join("").split("\n").map((l) => l.replace(/[ \t]+/g, " ").trim()).join("\n").replace(/\n{3,}/g, "\n\n").trim();
    if (stopped) s += "\n[stopped: the page is too big to read whole; read a part with selector]";
    return s;
  };

  // ---- outline: roles and names, indented ----
  const LANDMARK = { HEADER: "banner", FOOTER: "contentinfo", NAV: "navigation", MAIN: "main", ASIDE: "complementary", FORM: "form", DIALOG: "dialog", TABLE: "table", UL: "list", OL: "list" };
  const ACTIVE = new Set(["link", "button", "textbox", "password", "checkbox", "radio", "combobox", "editable", "tab", "menuitem", "switch", "option", "slider", "searchbox"]);
  const roleOf = (el) => {
    const r = one(el.getAttribute("role"), 30).split(" ")[0];
    if (r) return r;
    const kind = fieldKind(el);
    if (kind) return kind;
    const t = el.tagName;
    if (/^H[1-6]$/.test(t)) return "heading";
    if (t === "A" && el.hasAttribute("href")) return "link";
    if (t === "BUTTON" || (el instanceof HTMLInputElement && /^(submit|reset|button|image)$/i.test(el.type))) return "button";
    if (t === "IMG") return el.getAttribute("alt") ? "img" : "";
    if (t === "LI") return "listitem";
    if (t === "SECTION" && (el.getAttribute("aria-label") || el.getAttribute("aria-labelledby"))) return "region";
    return LANDMARK[t] || "";
  };
  const nameFor = (el, role) => {
    if (fieldKind(el)) return labelOf(el);
    const a = el.getAttribute("aria-label") || (el.getAttribute("aria-labelledby") && labelOf(el));
    if (a) return one(a, 200);
    if (role === "img") return one(el.getAttribute("alt"), 200);
    if (el instanceof HTMLInputElement) return one(el.value || el.type, 100);
    if (role === "heading" || role === "link" || role === "button" || role === "listitem" || role === "tab" || role === "menuitem" || role === "option") {
      return one(textOf(el).replace(/^(#+|-) /gm, ""), 200); // the text without its heading and list marks
    }
    return one(el.getAttribute("title"), 200);
  };
  const outlineOf = (start) => {
    const lines = [];
    const refs = new Map();
    let next = 0;
    let seen = 0;
    let stopped = false;
    let size = 0;
    const add = (depth, s) => {
      const l = "  ".repeat(Math.min(depth, 20)) + s;
      lines.push(l);
      size += l.length + 1;
      if (size > cap) stopped = true;
    };
    const walk = (n, depth) => {
      if (stopped) return;
      if (++seen > WALK_MAX) {
        stopped = true;
        return;
      }
      if (n.nodeType === 3) {
        const t = one(n.data, 300);
        if (t) add(depth, `text ${JSON.stringify(t)}`);
        return;
      }
      if (n.nodeType === 11) return kids(n).forEach((k) => walk(k, depth));
      if (n.nodeType !== 1) return;
      const el = n;
      if (SKIP.has(el.tagName)) return;
      if (!visible(el) && el !== start) return;
      if (el.getAttribute("aria-hidden") === "true") return;
      if (el.tagName === "IFRAME" || el.tagName === "FRAME") return void add(depth, "frame (not looked into)");
      const role = roleOf(el);
      if (role === "hidden") return;
      if (!role || role === "none" || role === "presentation" || role === "generic") return kids(el).forEach((k) => walk(k, depth));
      let line = role;
      if (ACTIVE.has(role) || role === "heading") {
        next++;
        refs.set(`e${next}`, new WeakRef(el));
        line = `e${next} ${role}`;
      }
      if (role === "heading") line += ` (level ${/^H[1-6]$/.test(el.tagName) ? el.tagName[1] : one(el.getAttribute("aria-level"), 2) || "?"})`;
      const name = nameFor(el, role);
      if (name) line += ` ${JSON.stringify(name)}`;
      if (fieldKind(el)) line += ` ${HIDDEN}`;
      if (role === "link") {
        const href = one(el.getAttribute("href"), 200);
        if (href) line += ` -> ${href}`;
      }
      if (el.disabled || el.getAttribute("aria-disabled") === "true") line += " (disabled)";
      add(depth, line);
      // what a named control holds is its name already; a field's inside is its value
      if (fieldKind(el) || role === "link" || role === "button" || role === "heading" || role === "img" || role === "option" || role === "tab" || role === "menuitem") return;
      kids(el).forEach((k) => walk(k, depth + 1));
    };
    walk(start, 0);
    globalThis.__pdRefs = refs;
    let s = lines.join("\n");
    if (stopped) s += "\n[stopped: the outline is too big; read a part with selector]";
    return s;
  };

  // ---- html: the element's markup, values hidden (scripts' text and token metas too) ----
  const htmlOf = (start) => {
    const copy = start.cloneNode(true); // open shadow roots are not copied: their content is left out
    // the copy's fields and editable parts, found from the original (computed style, isContentEditable)
    const orig = [start, ...start.querySelectorAll("*")];
    const dup = [copy, ...copy.querySelectorAll("*")];
    for (let i = 0; i < orig.length && i < dup.length; i++) {
      const o = orig[i];
      const d = dup[i];
      if (o instanceof HTMLInputElement) {
        if (d.hasAttribute("value") && fieldKind(o) !== "") d.setAttribute("value", HIDDEN); // hidden inputs too (tokens)
        d.removeAttribute("checked");
      } else if (o instanceof HTMLTextAreaElement) d.textContent = HIDDEN;
      else if (o instanceof HTMLSelectElement) d.textContent = HIDDEN;
      else if (o instanceof HTMLElement && fieldKind(o) === "editable") d.textContent = HIDDEN;
      else if (o instanceof HTMLScriptElement) d.textContent = "";
      else if (o instanceof HTMLMetaElement && /csrf|token|nonce/i.test(o.getAttribute("name") || "") && d.hasAttribute("content")) d.setAttribute("content", HIDDEN);
    }
    return copy.outerHTML;
  };

  if (mode === "has_text") return out({ found: !holder && !!value && textOf(root).includes(String(value)) });
  if (mode === "ready") return out({ ready: document.readyState === "complete" });
  let text;
  if (holder && (mode === "outline" || mode === "html" || mode === "text" || !mode)) text = mode === "html" ? HIDDEN : holderLine(holder);
  else if (mode === "outline") text = outlineOf(root);
  else if (mode === "html") text = htmlOf(root);
  else if (mode === "text" || !mode) text = textOf(root);
  else return out({ error: `mode is text, outline or html (got ${one(mode, 40)})` });
  const truncated = text.length > cap;
  if (truncated) text = text.slice(0, cap);
  return out(Object.assign({ mode: mode || "text", text, chars: text.length, truncated }, page));
})
