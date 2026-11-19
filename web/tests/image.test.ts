import { test } from "node:test";
import assert from "node:assert/strict";
import { fromBase64, imageCaption, isImagePath, isSvgPath, sizeText } from "../src/app/image.ts";

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
