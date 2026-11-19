// Images in file tabs (ImageView.tsx), pure parts. Which tabs show a picture: the extensions
// src/core/image_file.odin's image_ext names (change both together); the core reads the bytes
// (file_read with image: their type from their first bytes, else refused). An SVG is text: its
// tab is the editor, with a preview of that text as an image (never as markup).

const IMAGE_EXTS = ["png", "jpg", "jpeg", "gif", "bmp", "webp"];

// Whether a file tab of this path shows a picture (by its extension, any case).
export function isImagePath(path: string): boolean {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 && IMAGE_EXTS.includes(name.slice(dot + 1).toLowerCase());
}

export function isSvgPath(path: string): boolean {
  return /[^/]\.svg$/i.test(path);
}

// base64 (file_read's) to bytes.
export function fromBase64(b64: string): Uint8Array {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

// A file's size for people: 512 B, 3.4 KB, 12.0 MB (as the window's image_size_text).
export function sizeText(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1 << 20) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1 << 20)).toFixed(1)} MB`;
}

// The caption under a picture: its type, pixels (once loaded) and size.
export function imageCaption(mime: string, size: number, w = 0, h = 0): string {
  const kind = mime === "image/svg+xml" ? "SVG" : mime.replace(/^image\//, "").toUpperCase();
  return [kind, w > 0 && h > 0 ? `${w} × ${h} px` : "", sizeText(size)].filter(Boolean).join(" · ");
}

// Runs one job at a time, in the order asked (a failed job does not stop the next). An image read
// answers up to ~11 MB of base64: one at a time per page, so several tabs on a slow link never
// queue more than the link's backlog allows.
export function oneAtATime() {
  let last: Promise<unknown> = Promise.resolve();
  return <T>(job: () => Promise<T>): Promise<T> => {
    const p = last.then(job, job);
    last = p.catch(() => {});
    return p;
  };
}

// An SVG's text as a data: URL (an <img> of it, opened in a new tab, has an opaque origin).
export function svgDataUrl(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return "data:image/svg+xml;base64," + btoa(bin);
}

// An image read's reply that means "this is text, not an image": the core's refusal of a file
// whose first bytes are no image, or a core without image reads answering with its text. The tab
// shows the text instead.
export function notAnImage(r: { ok: boolean; error?: string; data?: unknown }): boolean {
  if (!r.ok) return (r.error ?? "").startsWith("not an image");
  const d = typeof r.data === "string" ? JSON.parse(r.data) : (r.data ?? {});
  return typeof d.text === "string" && typeof d.base64 !== "string";
}
