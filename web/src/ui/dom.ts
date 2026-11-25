// A tiny element builder. Text from the core, agents or terminals goes in only as text nodes
// (textContent): never innerHTML, never attributes that run code, never inline styles (CSP).

type Child = Node | string | number | null | undefined | false;
type Attrs = {
  class?: string;
  on?: { [event: string]: (e: any) => void };
  [attr: string]: any;
};

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs?: Attrs | null, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === undefined || v === null || v === false) continue;
      if (k === "on") {
        for (const [ev, fn] of Object.entries(v as Record<string, (e: Event) => void>)) el.addEventListener(ev, fn);
      } else if (k === "class") {
        el.className = String(v);
      } else if (k === "style" || k.startsWith("on")) {
        throw new Error("no inline styles or handlers");
      } else if (k in el && typeof (el as any)[k] !== "function" && !k.startsWith("aria") && !k.startsWith("data")) {
        (el as any)[k] = v; // properties: value, type, disabled, placeholder, …
      } else {
        el.setAttribute(k, v === true ? "" : String(v));
      }
    }
  }
  append(el, children);
  return el;
}

export function append(el: Element, children: Child[]): void {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    el.append(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
  }
}

export function replace(el: Element, ...children: Child[]): void {
  el.replaceChildren();
  append(el, children);
}

// "2m", "3h", "4d" since a time in nanoseconds (State's time.Time on the wire); "" when unknown.
export function ago(ns: number | undefined, now = Date.now()): string {
  if (!ns || ns <= 0) return "";
  const s = Math.max(0, Math.floor((now - ns / 1e6) / 1000));
  if (s < 60) return "now";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  return Math.floor(s / 86400) + "d";
}

export function storageGet(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function storageSet(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* private mode, or storage off: a preference that does not stick */
  }
}

export function storageRemove(key: string): void {
  try {
    localStorage.removeItem(key);
  } catch {
    /* storage off: nothing kept to remove */
  }
}
