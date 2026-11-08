# Contributing to Deckhand

Thanks for your interest. Deckhand is a small project, so keep changes focused and easy to review.

## Build

You need macOS 14 or later on Apple silicon, [Odin](https://odin-lang.org/) `dev-2026-09`, and
`clang` from the Xcode command line tools. Node 22.18 or later runs the pi integration's tests.

```sh
git clone --recursive https://github.com/McFalljb/deckhand.git
cd deckhand
./build.sh          # release build: build/Deckhand.app and build/deckhand
./build.sh run      # build, then run
```

The first build downloads CEF (about 135 MB, checksummed). [docs/DEVELOPING.md](docs/DEVELOPING.md)
covers the build, the source layout and the architecture.

## Test

```sh
./build.sh test               # unit, binding and pi integration tests
./build.sh scenes --changed   # test-mode scenes for what you changed
./build.sh scenes NAME        # one scene again, after a fix
```

Run `./build.sh scenes --all` only when you change the build or the test runner, and before a
release: `--changed` and CI cover everything else ([docs/TESTING.md](docs/TESTING.md#what-to-run)).

Scenes run the real app in test mode: a fake `HOME`, a fake pi, a temporary data folder and no
network. They never start a real `pi` or `claude`. [docs/TESTING.md](docs/TESTING.md) explains
the tiers, what CI runs, and how to write a scene.

Some scripts run a real pi against paid models (tier `paid` in `tests/scenes.txt`). Only run
those on purpose, with your own account.

## Pull requests

- One change per pull request, with a short description of what it does and why.
- Add or update tests for behaviour you change. A bug fix should come with a test that failed
  before the fix.
- `./build.sh test` passes, and the scenes for the parts you touched pass.
- If you change something users see, update [docs/GUIDE.md](docs/GUIDE.md) in the same pull
  request. A unit test checks that every action is in GUIDE.md and every control-socket command
  is in GUIDE.md or [docs/PROTOCOL.md](docs/PROTOCOL.md). See
  [Contributing in DEVELOPING.md](docs/DEVELOPING.md#contributing).
- CI runs the unit tests and the required scenes on every pull request.

## Reporting bugs and security issues

Open an issue for bugs, with your Deckhand and macOS versions and the steps to reproduce.
Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## Licence

By contributing, you agree that your contributions are licensed under the [MIT licence](LICENSE).
