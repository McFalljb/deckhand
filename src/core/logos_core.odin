package core

// From src/logos.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

// Whether Claude Code's mascot is shown. Anthropic's trademark guidelines ask for approval
// before its marks are used (assets/harness/README.md); build with
// -define:DECKHAND_CLAUDE_LOGO=false and Claude rows show the plain glyph instead.
LOGO_CLAUDE_ON :: #config(DECKHAND_CLAUDE_LOGO, true)
