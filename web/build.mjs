// Builds Deckhand's browser client into web/dist/: index.html, app.<hash>.js (one bundle),
// app.<hash>.css (one stylesheet) and icon.<hash>.svg, each with a .gz copy. The core serves
// index.html at / (no-cache, an ETag) and the others at /assets/<name>: a name with its content's
// hash is cached for good (immutable), and its .gz copy goes to a browser that takes gzip.
// Nothing comes from a CDN; xterm.js is bundled from node_modules (pinned in package-lock.json).
//
//   npm ci && npm run build        (from web/)

import { build } from "esbuild";
import { copyFileSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = dirname(fileURLToPath(import.meta.url));
const dist = join(web, "dist");

await import("./tools/theme.mjs"); // src/theme.gen.css and .ts from the Odin tokens

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

const pkg = (name) => JSON.parse(readFileSync(join(web, "node_modules", name, "package.json"), "utf8")).version;

await build({
  entryPoints: { app: join(web, "src/main.ts") },
  outdir: dist,
  bundle: true,
  format: "esm",
  target: ["es2020", "safari15", "chrome100", "firefox100"],
  minify: true,
  sourcemap: false,
  legalComments: "none",
  charset: "utf8",
  logLevel: "warning",
  jsx: "automatic",
  jsxImportSource: "preact",
  banner: {
    js: `/*! Deckhand browser client. Bundles xterm.js ${pkg("@xterm/xterm")} and @xterm/addon-fit ${pkg("@xterm/addon-fit")} (MIT, the xterm.js authors) and Preact ${pkg("preact")} (MIT, Jason Miller): see THIRD_PARTY_NOTICES.md */`,
  },
});

copyFileSync(join(web, "..", "assets", "icon", "deckhand.svg"), join(dist, "icon.svg")); // the tab's icon (the app's)

// each asset named by its content's hash (base.<10 hex>.ext), index.html pointing at them
let html = readFileSync(join(web, "index.html"), "utf8");
const names = [];
for (const f of ["app.js", "app.css", "icon.svg"]) {
  const data = readFileSync(join(dist, f));
  const dot = f.lastIndexOf(".");
  const name = `${f.slice(0, dot)}.${createHash("sha256").update(data).digest("hex").slice(0, 10)}${f.slice(dot)}`;
  renameSync(join(dist, f), join(dist, name));
  if (!html.includes(`/assets/${f}"`)) throw new Error(`index.html does not name /assets/${f}`);
  html = html.replace(`/assets/${f}"`, `/assets/${name}"`);
  const gz = gzipSync(data, { level: 9 });
  if (gz.length < data.length) writeFileSync(join(dist, name + ".gz"), gz);
  names.push(name, name + ".gz");
}
writeFileSync(join(dist, "index.html"), html);

for (const f of ["index.html", ...names]) {
  const n = statSync(join(dist, f)).size;
  console.log(`dist/${f}  ${(n / 1024).toFixed(1)} KiB`);
}
