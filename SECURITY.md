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

Only the latest release gets security fixes, for the macOS app and the Linux core it installs
on other machines. Deckhand updates itself from GitHub Releases (it asks first), and updates other
machines' cores from Settings › Machines. pi-desk 0.1.x builds do not update to Deckhand: install
it fresh ([From pi-desk to Deckhand](docs/GUIDE.md#from-pi-desk-to-deckhand)).

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
- secrets (keys, tokens, Claude or Codex credentials) leaking into logs, saved state or other processes;
- other machines (Machines over SSH): a machine connecting to this one while *Allow other machines
  to connect* is off, or other than over ssh as you; a connected machine running the commands
  only the user at this Mac may run (`machine_*`, `pi_handoff`, `holder_recover`, and the settings
  that bound other machines and agents: letting machines connect, the machine list, pi extensions,
  Claude's default flags, notifications); this core forwarding a connected machine's commands on
  to a third machine; another machine's text (titles, errors, job output) acting as anything but
  data here;
- web access ([docs/PROTOCOL.md](docs/PROTOCOL.md) §5b): a browser using this machine without a
  code typed while one is open, a page of another site driving the pairing or the WebSocket, a
  paired browser running what only the user at this Mac may run, a paired browser reading or
  writing a file outside a project folder, or a credentials file (`file_read`, `file_save`), text
  from an agent, a terminal or a file running as script in the page, or the code or a token
  reaching a log, State or another process. Reading plain-HTTP traffic on the network is not in
  scope: it is the documented cost of the setting;
- **Continue this conversation on <machine>** moving a conversation *into* this Mac, or started by
  anyone but the user at this Mac's window.

By design, a machine you allow to connect acts as you on this one: it can see and drive its
sessions, as you can, and through Atlas or a shell here reach the machines this one reaches.
Allow only machines you trust as yourself ([docs/ATLAS.md](docs/ATLAS.md) §7.1). The same holds for
a browser you pair with web access, which Deckhand serves over plain HTTP.

The design notes in [docs/BROWSER.md](docs/BROWSER.md), [docs/CLAUDE-TABS.md](docs/CLAUDE-TABS.md),
[docs/CODEX.md](docs/CODEX.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md) (§5a, the hub) describe the intended boundaries.
