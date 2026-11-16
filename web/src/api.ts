// The few plain HTTP calls before the socket: is this browser paired, pair it, unpair it. The
// token is an HttpOnly cookie the browser keeps; nothing here reads or stores it. A cookie is a
// host name's, not a port's, so pairing also returns a key this page keeps in its own storage
// (localStorage is per origin, so per port): the hello says it, and unpair sends it
// (docs/PROTOCOL.md §5b). No key here: this browser is not paired, whatever the cookie says.

const KEY_STORE = "deckhand.key";

export function pairKey(): string | null {
  try {
    const k = localStorage.getItem(KEY_STORE);
    return k && /^[0-9a-f]{64}$/.test(k) ? k : null;
  } catch {
    return null;
  }
}

function keepKey(k: string): boolean {
  try {
    localStorage.setItem(KEY_STORE, k);
    return localStorage.getItem(KEY_STORE) === k;
  } catch {
    return false;
  }
}

export function forgetKey(): void {
  try {
    localStorage.removeItem(KEY_STORE);
  } catch {
    /* nothing kept */
  }
}

export interface Whoami {
  paired: boolean;
  name?: string;
  core?: string;
  version?: string;
}

// null: no answer (the core is down or unreachable), as opposed to an answer of "not paired".
// Paired needs the cookie (the core's answer) and this page's key.
export async function whoami(): Promise<Whoami | null> {
  try {
    const r = await fetch("/api/whoami", { credentials: "same-origin", cache: "no-store" });
    if (r.status === 401) return { paired: false };
    if (!r.ok) return null;
    const w = (await r.json()) as Whoami;
    return w.paired && !pairKey() ? { paired: false } : w;
  } catch {
    return null;
  }
}

export type PairResult = "ok" | "refused" | "unreachable" | "nostorage";

export async function pair(code: string, name: string): Promise<PairResult> {
  try {
    const r = await fetch("/api/pair", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, name }),
    });
    if (r.ok) {
      const body = (await r.json()) as { key?: unknown };
      if (typeof body.key !== "string" || !/^[0-9a-f]{64}$/.test(body.key)) return "unreachable";
      return keepKey(body.key) ? "ok" : "nostorage";
    }
    if (r.status === 403 || r.status === 400 || r.status === 429) return "refused";
    return "unreachable";
  } catch {
    return "unreachable";
  }
}

export async function unpair(): Promise<boolean> {
  try {
    const k = pairKey();
    const r = await fetch("/api/unpair", { method: "POST", credentials: "same-origin", headers: k ? { "X-Deckhand-Key": k } : {} });
    forgetKey();
    return r.ok;
  } catch {
    return false;
  }
}

// A default name for this browser, from what it says it is ("iPhone Safari", "Mac Chrome").
export function defaultBrowserName(): string {
  const ua = navigator.userAgent;
  const device = /iPhone/.test(ua)
    ? "iPhone"
    : /iPad/.test(ua)
      ? "iPad"
      : /Android/.test(ua)
        ? "Android"
        : /Mac OS X/.test(ua)
          ? "Mac"
          : /Windows/.test(ua)
            ? "Windows"
            : /Linux/.test(ua)
              ? "Linux"
              : "Browser";
  const app = /Edg\//.test(ua)
    ? "Edge"
    : /Firefox\/|FxiOS/.test(ua)
      ? "Firefox"
      : /Chrome\/|CriOS/.test(ua)
        ? "Chrome"
        : /Safari\//.test(ua)
          ? "Safari"
          : "";
  return app ? `${device} ${app}` : device;
}
