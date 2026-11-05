# Sourced by scenes: claude_stub HOME puts a stand-in `claude` where Claude Code's native installer
# puts it (HOME/.local/bin/claude), so pi-desk finds Claude Code "installed" whatever the PATH
# (claude_installed: stat only, it never runs claude). It is never run: scenes that open Claude tabs
# set PI_DESK_CLAUDE_CMD to the fake (tests/scripts/fake-claude.py); if anything ran it, it fails.
claude_stub() {
  mkdir -p "$1/.local/bin"
  printf '#!/bin/sh\necho "stand-in claude (tests): never run" >&2\nexit 1\n' > "$1/.local/bin/claude"
  chmod 755 "$1/.local/bin/claude"
}
