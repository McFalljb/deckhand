// Pairing: the 8-character code Deckhand shows at the Mac (Settings › Machines › Pair a browser…)
// and a name for this browser. The core answers with an HttpOnly cookie this page never sees.

import { defaultBrowserName, pair } from "../api.ts";
import { h, storageGet, storageSet } from "./dom.ts";

const CODE_LEN = 8;

export function pairScreen(onPaired: () => void): HTMLElement {
  const code = h("input", {
    class: "field code",
    type: "text",
    inputMode: "text",
    autocomplete: "one-time-code",
    autocapitalize: "characters",
    spellcheck: false,
    maxLength: CODE_LEN + 2,
    placeholder: "XXXX-XXXX",
    "aria-label": "Pairing code",
  });
  const name = h("input", {
    class: "field",
    type: "text",
    maxLength: 64,
    autocomplete: "off",
    "aria-label": "Name for this browser",
  });
  name.value = storageGet("deckhand.browserName") ?? defaultBrowserName();
  const msg = h("p", { class: "pair-msg", role: "status" });
  const submit = h("button", { class: "btn primary wide", type: "submit" }, "Pair");

  const clean = (s: string) => s.toUpperCase().replace(/[^0-9A-Z]/g, "");
  code.addEventListener("input", () => {
    const c = clean(code.value);
    if (c !== code.value) code.value = c;
    msg.textContent = "";
  });

  const form = h(
    "form",
    {
      class: "pair",
      on: {
        submit: async (e: Event) => {
          e.preventDefault();
          const c = clean(code.value);
          const n = name.value.trim() || defaultBrowserName();
          if (c.length !== CODE_LEN) {
            msg.textContent = `The code has ${CODE_LEN} characters.`;
            return;
          }
          submit.disabled = true;
          msg.textContent = "Pairing…";
          const r = await pair(c, n);
          submit.disabled = false;
          if (r === "ok") {
            storageSet("deckhand.browserName", n);
            onPaired();
            return;
          }
          msg.textContent =
            r === "refused"
              ? "That code did not work. Codes last 2 minutes and work once: make a new one at the Mac."
              : r === "nostorage"
                ? "This browser does not keep site data here (a private window?), so it cannot stay paired. Revoke it at the Mac and use a normal window."
                : "Deckhand did not answer. Is web access still on at the Mac?";
        },
      },
    },
    h("h1", null, "Deckhand"),
    h("p", { class: "muted" }, "At the Mac, open Settings › Machines › Pair a browser…, then type the code it shows."),
    h("label", { class: "label" }, "Code", code),
    h("label", { class: "label" }, "This browser's name", name),
    submit,
    msg,
  );
  window.setTimeout(() => code.focus(), 0);
  return h("div", { class: "screen pair-screen" }, form);
}
