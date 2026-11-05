# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/McFalljb/deckhand/security/advisories/new)). Do not open a
public issue or pull request for a vulnerability.

A useful report says:

- the Deckhand version (**About Deckhand**, or the release you downloaded) and your macOS version;
- what an attacker can do, and from where (a web page in a browser tab, a project's files, an
  agent in a tab, another local user, ...);
- the steps to reproduce it, or a proof of concept.

You will get an answer in the advisory thread. Fixes ship in a new release, and the advisory is
published once the fix is out.

## Supported versions

Only the latest release gets security fixes. Deckhand updates itself from GitHub Releases; the
earlier pi-desk 0.1.x builds do not, so install Deckhand fresh (see the
[README](README.md#coming-from-pi-desk)).

## Scope

Deckhand runs coding agents with your user's permissions, so an agent can do what you can do in a
terminal. That is by design and not a vulnerability in itself. In scope are ways to get past the
limits Deckhand sets, for example:

- a web page in a browser tab reaching the control socket, the file system or another tab;
- an agent in one session acting on another session's tabs, or on browser tabs it was not given;
- a caller of the control socket doing more than its caller class allows (see
  [docs/PROTOCOL.md](docs/PROTOCOL.md));
- the updater installing something other than a signed Deckhand release;
- secrets (keys, tokens, Claude credentials) leaking into logs, saved state or other processes.

The design notes in [docs/BROWSER.md](docs/BROWSER.md), [docs/CLAUDE.md](docs/CLAUDE.md) and
[docs/PROTOCOL.md](docs/PROTOCOL.md) describe the intended boundaries.
