// Builds Deckhand's browser client into web/dist/: index.html, app.js (one bundle) and app.css
// (one stylesheet). The core serves index.html at / and the other two at /assets/<name>.
// Nothing comes from a CDN; xterm.js is bundled from node_modules (pinned in package-lock.json).
//
//   npm ci && npm run build        (from web/)

import { build } from "esbuild";
import { copyFileSync, mkdirSync, readFileSync, rmSync, statSync } from "node:fs";
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

copyFileSync(join(web, "index.html"), join(dist, "index.html"));
copyFileSync(join(web, "..", "assets", "icon", "deckhand.svg"), join(dist, "icon.svg")); // the tab's icon (the app's)

for (const f of ["index.html", "app.js", "app.css", "icon.svg"]) {
  const n = statSync(join(dist, f)).size;
  console.log(`dist/${f}  ${(n / 1024).toFixed(1)} KiB`);
}
