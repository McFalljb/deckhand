// Toasts and bottom sheets: the few overlays phase 1 needs.

import { h, replace } from "./dom.ts";

let toastBox: HTMLElement;
let sheetBox: HTMLElement;

export function overlayInit(root: HTMLElement): void {
  toastBox = h("div", { class: "toasts", "aria-live": "polite" });
  sheetBox = h("div", { class: "sheet-layer", hidden: true });
  sheetBox.addEventListener("click", (e) => {
    if (e.target === sheetBox) closeSheet();
  });
  root.append(toastBox, sheetBox);
}

export function toast(text: string, err = false): void {
  if (!text) return;
  const t = h("div", { class: err ? "toast err" : "toast", role: err ? "alert" : "status" }, text);
  toastBox.append(t);
  while (toastBox.childElementCount > 3) toastBox.firstElementChild?.remove();
  window.setTimeout(() => t.remove(), err ? 6000 : 3500);
}

export interface SheetAction {
  label: string;
  primary?: boolean;
  danger?: boolean;
  run: () => void;
}

export function openSheet(title: string, body: (Node | string)[], actions: SheetAction[] = []): void {
  const bar = h("div", { class: "sheet-actions" });
  for (const a of actions) {
    bar.append(
      h(
        "button",
        {
          class: "btn" + (a.primary ? " primary" : "") + (a.danger ? " danger" : ""),
          type: "button",
          on: {
            click: () => {
              closeSheet();
              a.run();
            },
          },
        },
        a.label,
      ),
    );
  }
  bar.append(h("button", { class: "btn", type: "button", on: { click: closeSheet } }, actions.length ? "Cancel" : "Close"));
  replace(sheetBox, h("div", { class: "sheet", role: "dialog", "aria-label": title }, h("div", { class: "sheet-title" }, title), ...body, bar));
  sheetBox.hidden = false;
}

export function closeSheet(): void {
  sheetBox.hidden = true;
  sheetBox.replaceChildren();
}

// A link from a terminal (or the core): shown first, opened only on a tap.
export function offerLink(url: string): void {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    toast("Not a web address", true);
    return;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") {
    toast("Only http and https links open here", true);
    return;
  }
  openSheet("Open this link?", [h("div", { class: "sheet-url" }, u.href)], [
    { label: "Open", primary: true, run: () => window.open(u.href, "_blank", "noopener,noreferrer") },
    { label: "Copy", run: () => offerCopy(u.href) },
  ]);
}

// No async clipboard on a page that is not a secure context: show the text, selected, with a
// Copy button (execCommand works on a tap), and the user can always copy it by hand.
export function offerCopy(text: string): void {
  const area = h("textarea", { class: "sheet-copy", readOnly: true, rows: Math.min(8, text.split("\n").length + 1) });
  area.value = text;
  openSheet("Copy", [area], [
    {
      label: "Copy",
      primary: true,
      run: () => {
        let ok = false;
        try {
          if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(
              () => toast("Copied"),
              () => toast("Could not copy", true),
            );
            return;
          }
          const tmp = h("textarea", { class: "offscreen", readOnly: true });
          tmp.value = text;
          document.body.append(tmp);
          tmp.select();
          ok = document.execCommand("copy");
          tmp.remove();
        } catch {
          ok = false;
        }
        toast(ok ? "Copied" : "Could not copy: select the text and copy it", !ok);
      },
    },
  ]);
  window.setTimeout(() => {
    area.focus();
    area.select();
  }, 0);
}
