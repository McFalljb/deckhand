# Contributing to Deckhand

Thanks for your interest. Deckhand is a small project, so keep changes focused and easy to review.

## Build and test

You need macOS 14 or later on Apple silicon, [Odin](https://odin-lang.org/) `dev-2026-09`,
`clang` from the Xcode command line tools, and Node 22.18 or later for the pi integration's tests.

```sh
git clone --recursive https://github.com/McFalljb/deckhand.git
cd deckhand
./build.sh run                # build (the first one downloads CEF, ~135 MB), then run
./build.sh test               # every unit layer
./build.sh scenes --changed   # the test-mode scenes for what you changed
./build.sh scenes NAME        # one scene again, after a fix
```

Scenes run the real app in test mode, with a fake `HOME`, a fake pi and no network; they never
start a real `pi` or `claude`. Run `--all` only for a change to the build or the runner, and
before a release ([What to run](docs/TESTING.md#what-to-run)). Scenes in the `paid` tier run a
real pi against paid models: only run those on purpose, with your own account.

[docs/DEVELOPING.md](docs/DEVELOPING.md) covers the build, signing, the architecture and test mode;
[docs/TESTING.md](docs/TESTING.md) covers the tests and CI.

## Pull requests

- One change per pull request, with a short description of what it does and why.
- Add or update tests for behaviour you change. A bug fix comes with a test that failed before
  the fix.
- `./build.sh test` passes, and so do the scenes for the parts you touched.
- If users see the change, update [docs/GUIDE.md](docs/GUIDE.md) in the same pull request. A unit
  test checks that every action is in the guide and every command in the guide or
  [docs/PROTOCOL.md](docs/PROTOCOL.md). See [Contributing in DEVELOPING.md](docs/DEVELOPING.md#contributing)
  for that and the other rules CI enforces (the session holder's revision, the core boundary).
- CI runs the unit tests and the required scenes on every pull request.

## Reporting bugs and security issues

Open an issue for bugs, with your Deckhand and macOS versions and the steps to reproduce.
Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## Licence

By contributing, you agree that your contributions are licensed under the [MIT licence](LICENSE).
