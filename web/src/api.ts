// The few plain HTTP calls before the socket: is this browser paired, pair it, unpair it. The
// token is an HttpOnly cookie the browser keeps; nothing here reads or stores it.

export interface Whoami {
  paired: boolean;
  name?: string;
  core?: string;
  version?: string;
}

// null: no answer (the core is down or unreachable), as opposed to an answer of "not paired".
export async function whoami(): Promise<Whoami | null> {
  try {
    const r = await fetch("/api/whoami", { credentials: "same-origin", cache: "no-store" });
    if (r.status === 401) return { paired: false };
    if (!r.ok) return null;
    return (await r.json()) as Whoami;
  } catch {
    return null;
  }
}

export type PairResult = "ok" | "refused" | "unreachable";

export async function pair(code: string, name: string): Promise<PairResult> {
  try {
    const r = await fetch("/api/pair", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, name }),
    });
    if (r.ok) return "ok";
    if (r.status === 403 || r.status === 400 || r.status === 429) return "refused";
    return "unreachable";
  } catch {
    return "unreachable";
  }
}

export async function unpair(): Promise<boolean> {
  try {
    const r = await fetch("/api/unpair", { method: "POST", credentials: "same-origin" });
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
