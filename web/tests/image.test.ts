import { test } from "node:test";
import assert from "node:assert/strict";
import { fromBase64, imageCaption, isImagePath, isSvgPath, notAnImage, oneAtATime, sizeText, svgDataUrl } from "../src/app/image.ts";

test("which file tabs show a picture", () => {
  for (const p of ["/p/a.png", "/p/B.JPG", "/p/c.jpeg", "/p/d.gif", "/p/e.bmp", "/p/f.webp"]) assert.ok(isImagePath(p), p);
  for (const p of ["/p/a.svg", "/p/.png", "/p/png", "/p/a.png.txt", "/p/x.tiff", "/p.png/readme"]) assert.ok(!isImagePath(p), p);
  assert.ok(isSvgPath("/p/logo.SVG") && !isSvgPath("/p/.svg") && !isSvgPath("/p/a.svgz"));
});

test("bytes, sizes and the caption", () => {
  assert.deepEqual([...fromBase64("iVBORw==")], [0x89, 0x50, 0x4e, 0x47]);
  assert.equal(sizeText(512), "512 B");
  assert.equal(sizeText(3 * 1024 + 400), "3.4 KB");
  assert.equal(sizeText(12 << 20), "12.0 MB");
  assert.equal(imageCaption("image/png", 2048), "PNG · 2.0 KB");
  assert.equal(imageCaption("image/jpeg", 100, 640, 480), "JPEG · 640 × 480 px · 100 B");
  assert.equal(imageCaption("image/svg+xml", 10, 24, 24), "SVG · 24 × 24 px · 10 B");
});

test("one image read at a time, in order, a failure not stopping the next", async () => {
  const one = oneAtATime();
  let running = 0, most = 0;
  const order: number[] = [];
  const job = (n: number, fail = false) => async () => {
    running++;
    most = Math.max(most, running);
    await new Promise((r) => setTimeout(r, 5));
    running--;
    order.push(n);
    if (fail) throw new Error("x");
    return n;
  };
  const r = await Promise.allSettled([one(job(1)), one(job(2, true)), one(job(3))]);
  assert.equal(most, 1);
  assert.deepEqual(order, [1, 2, 3]);
  assert.deepEqual(r.map((x) => x.status), ["fulfilled", "rejected", "fulfilled"]);
});

test("an SVG preview is a data: URL of its UTF-8 text", () => {
  const u = svgDataUrl("<svg>é</svg>");
  assert.ok(u.startsWith("data:image/svg+xml;base64,"));
  assert.equal(Buffer.from(u.slice(u.indexOf(",") + 1), "base64").toString("utf8"), "<svg>é</svg>");
});

test("a reply that says text, not an image: the tab falls back to text", () => {
  assert.ok(notAnImage({ ok: false, error: "not an image Deckhand shows (PNG, JPEG, GIF, BMP, WebP)" }));
  assert.ok(notAnImage({ ok: true, data: JSON.stringify({ path: "/a.png", text: "hi" }) })); // a core without image reads
  assert.ok(!notAnImage({ ok: false, error: "too large to open in a browser" }));
  assert.ok(!notAnImage({ ok: true, data: JSON.stringify({ same: true }) }));
  assert.ok(!notAnImage({ ok: true, data: { image: "image/png", base64: "AA==" } }));
});
