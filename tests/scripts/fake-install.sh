#!/bin/sh
# Stand-in for the harness checklist's install and update commands (PI_DESK_INSTALL_CMD,
# harness_install.odin): it gets the item's id and the exact command as "$@", records them in
# $HOME/install-argv.txt and "installs" into the scene's fake HOME (never a real install).
# FAKE_INSTALL_SLOW=N waits N seconds first (a run that is still going).
printf '%s\t%s\n' "$1" "$2" >> "$HOME/install-argv.txt"
echo "fake install: $1: $2"
# sudo inside a run reaches Deckhand's refusing shim (never the real one: -n never prompts)
{ sudo -n true 2>&1; echo "sudo exit $? askpass ${SUDO_ASKPASS:-}"; } >> "$HOME/sudo.txt"
[ -n "${FAKE_INSTALL_SLOW:-}" ] && sleep "$FAKE_INSTALL_SLOW"
case "$1" in
  claude)
    mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
    printf '#!/bin/sh\necho "stand-in claude (tests): never run" >&2\nexit 1\n' > "$HOME/.local/share/claude/versions/2.1.300"
    chmod 755 "$HOME/.local/share/claude/versions/2.1.300"
    ln -sf "$HOME/.local/share/claude/versions/2.1.300" "$HOME/.local/bin/claude" ;;
  pi)
    pkg="$HOME/.pi/agent/lib/node_modules/@earendil-works/pi-coding-agent"
    mkdir -p "$pkg/dist" "$HOME/.pi/agent/bin"
    printf '{"name":"@earendil-works/pi-coding-agent","version":"1.5.0"}\n' > "$pkg/package.json"
    printf '#!/bin/sh\necho "stand-in pi (tests): never run" >&2\nexit 1\n' > "$pkg/dist/cli.js"
    chmod 755 "$pkg/dist/cli.js"
    ln -sf "$pkg/dist/cli.js" "$HOME/.pi/agent/bin/pi" ;;
  pi-subagents)
    # as `pi install` would: pi's own package manager adds it to its settings
    printf '{"packages":["npm:pi-subagents@0.84.0"]}\n' > "$HOME/.pi/agent/settings.json" ;;
esac
echo "fake install: done"
