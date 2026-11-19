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
