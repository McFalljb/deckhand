# Deckhand: notes for coding agents

Deckhand is a native macOS desk for coding agents: it runs pi, Claude Code and Codex in tabs
beside shells, an editor, browser tabs and files. The app is Odin (`src/`, the core in
`src/core/`); the browser client is TypeScript (`web/`); agent integrations are in `integrations/`.

## Where things are

- [README.md](README.md): what Deckhand is, and the table of every doc in `docs/`.
- [docs/DEVELOPING.md](docs/DEVELOPING.md): requirements, building, the source map, architecture,
  releases. [docs/TESTING.md](docs/TESTING.md): test layers, scenes, CI.
- [CONTRIBUTING.md](CONTRIBUTING.md): pull request rules. [SECURITY.md](SECURITY.md): reporting.
- `docs/CLAUDE-TABS.md` is the design doc for Claude Code tabs, not instructions for agents.

## Build and test

- Build: `./build.sh` (`./build.sh run` to build and run). On a Mac where nix's `clang`/`ld` come
  before Xcode's on `PATH`, run `PATH=/usr/bin:$PATH ./build.sh ...`: the build expects `clang`
  from the Xcode command line tools ([Requirements](docs/DEVELOPING.md#requirements)).
  That `PATH` makes `python3` Apple's 3.9; scenes whose fakes need `tomllib` want a Homebrew
  `python3` (3.11+) first.
- Every change: `./build.sh test`, plus `./build.sh scenes --changed` if it touches the app or a
  scene. A change in `web/`: `cd web && npm run check`. The full table:
  [What to run](docs/TESTING.md#what-to-run).
- Never run scenes in the `paid` tier (they start a real pi against paid models), and never start
  a real `pi`, `claude` or `codex` from a test.

## Rules (from CONTRIBUTING.md and DEVELOPING.md)

- One change per pull request; a bug fix comes with a test that failed before the fix.
- A user-visible change updates `docs/GUIDE.md` in the same branch; a unit test checks that every
  action, menu item and command is documented ([Contributing](docs/DEVELOPING.md#contributing)).
- `src/core` must not import window code (`scripts/check-core-boundary.sh`).
- A change to `src/holder`, `src/holderwire` or `src/trust` needs a `HOLDER_REV` bump.
- The window/core API is grow-only: `schema/released-*.json` allow additions only.
