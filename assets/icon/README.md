# App icon

Deckhand's icon: the letter D as a ship's porthole, its counter glass showing waves.

| File | What |
|---|---|
| `deckhand.svg` | the source, 1024 × 1024 (the macOS Big Sur grid: an 824 squircle at 100,100) |
| `Deckhand.icns` | what the app bundle carries (`CFBundleIconFile`, copied by `scripts/bundle-app.sh`) |
| `dp_gen.py` | the generator: `python3 dp_gen.py OUTDIR` writes six variants, `dp-1.svg` … `dp-6.svg`; `deckhand.svg` is `dp-5.svg` |

To rebuild the `.icns` after changing the SVG: render it at 1024 px (any SVG renderer that keeps
transparency, e.g. headless Chrome's `--screenshot`), make the ten sizes of an `.iconset` with
`sips -z N N` (16, 32, 128, 256, 512 and their `@2x`), then `iconutil -c icns Deckhand.iconset`.
