# Harness logos

The marks Deckhand shows for the agents it runs (session rows, tabs, the **New session** picker,
the Claude account rows). These files are the reference copies, as obtained on 2026-11-04.
The app does not read them at run time: `src/logos.odin` holds both marks as the same pixel
grids (one character a cell) and rasterises them into the glyph atlas. If a mark changes,
update both.

| File | Mark | Source | Colours | Terms |
|---|---|---|---|---|
| `pi.svg` | pi's logo | <https://pi.dev/logo.svg> (the same file as `logo-auto.svg`, the logo in the README of `@earendil-works/pi-coding-agent` 1.5.0) | `#F09082`, `#4D9ABF`, `#F1BE58` | pi is MIT licensed (© 2025 Mario Zechner, <https://github.com/earendil-works/pi>); no separate brand or trademark terms were found on pi.dev or in the package. pi.dev's favicon (<https://pi.dev/favicon.svg>) is the same mark in one colour (`#111111` / `#f6f6f6`). |
| `clawd.txt` | Clawd, Claude Code's mascot (the little orange creature on its welcome screen) | Claude Code 2.1.318's own art, read from its installed native binary (never run): the welcome-screen block characters (its `EH` constant and default pose) and its theme colours, matching the crispEdges pixel-art Clawd SVG the same build ships. The file has the art verbatim and the 17 x 10 grid Deckhand draws. | `#D77757` (`clawd_body`, rgb(215,119,87)), eyes `#000000` (`clawd_background`, rgb(0,0,0)) | Claude Code, its art included, is "© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service." ([its LICENSE.md](https://github.com/anthropics/claude-code/blob/main/LICENSE.md)); no separate licence for the mascot was found. Anthropic's [Trademark Guidelines](https://www.anthropic.com/legal/trademark-guidelines) (effective 1 Aug 2024) cover its marks and logos: use only as Anthropic permits and in materials it approves beforehand; no alterations (colour, proportion or otherwise); nothing implying sponsorship, endorsement or affiliation; no background that hurts readability; reasonable space around the mark; no ™ symbol. Inquiries: marketing@anthropic.com. |

Deckhand uses each mark only to say which agent a session runs (nominative use), at its own
colours and proportions. Anthropic's guidelines ask for prior approval of any use; that approval
has not been obtained.

Until 2026-11-04 the Claude mark was Anthropic's spark (<https://claude.ai/favicon.svg>, `#D97757`);
Clawd replaced it as the mark of Claude Code itself rather than of Anthropic or Claude.

**Switching Clawd off.** One constant decides whether it is shown:
`LOGO_CLAUDE_ON :: #config(DECKHAND_CLAUDE_LOGO, true)` in `src/logos.odin`. For a build
without it, change its default to `false` (`./build.sh` passes no extra defines), or pass
`-define:DECKHAND_CLAUDE_LOGO=false` when running `odin build src` / `odin test src` by hand.
Every Claude row, tab and picker entry then shows the plain fallback glyph instead: an
asterisk, drawn in the row's colour. Nothing else changes, and the unit tests pass both ways.

The marks are drawn exactly as published: their own colours and proportions, every cell a
whole number of px, so they are crisp at every size (never blurred, thickened or anti-aliased).
Clawd is 17 cells wide and 10 tall: on a 14 pt row it is one cell a point (17 x 10 pt), reaching
about 1.5 pt past its 14 pt square into the gap on each side (`LOGO_WIDE`), since a smaller whole
cell would not fit. A dimmed row (hidden, or its folder gone) shows the plain glyph in the
muted colour rather than a faded mark.

SHA-256:

```
abd66e7868b2d24f0f0895f9237ee8a6dcb22337583b0dc54aeb595acecb4d6b  pi.svg
2849db62dc0882617c72ec276756db27069c92b938a6a1e299b6141b29c9d6b9  clawd.txt (written from the binary, not downloaded)
```
