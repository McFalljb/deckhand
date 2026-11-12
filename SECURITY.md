# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/McFalljb/deckhand/security/advisories/new)). Do not open a
public issue or pull request for a vulnerability.

A useful report says:

- the Deckhand version (**About Deckhand**, or the release you downloaded) and your macOS version
  (and the Linux distribution, when another machine's core is involved);
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
- the updater, or an install or update of another machine's core, installing something other
  than a signed Deckhand release;
- secrets (keys, tokens, Claude credentials) leaking into logs, saved state or other processes;
- other machines (Machines over SSH): a machine connecting to this one while *Allow other machines
  to connect* is off, or other than over ssh as you; a connected machine running this machine's
  own-user-only commands (`machine_*`, notification settings); this core forwarding a connected
  machine's commands on to a third machine; another machine's text (titles, errors, job output) acting as anything but
  data here.

By design, a machine you allow to connect acts as you on this one: it can see and drive its
sessions, as you can, and through Atlas or a shell here reach the machines this one reaches.
Allow only machines you trust as yourself ([docs/ATLAS.md](docs/ATLAS.md) §7.1).

The design notes in [docs/BROWSER.md](docs/BROWSER.md), [docs/CLAUDE.md](docs/CLAUDE.md) and
[docs/PROTOCOL.md](docs/PROTOCOL.md) (§5a, the hub) describe the intended boundaries.
