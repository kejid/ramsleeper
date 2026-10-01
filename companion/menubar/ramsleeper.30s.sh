#!/usr/bin/env bash
# <xbar.title>RAM Sleeper</xbar.title>
# <xbar.version>v0.3.10</xbar.version>
# <xbar.desc>Memory used by each Claude Code session, with Unload.</xbar.desc>
# <xbar.dependencies>node</xbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# Menu bar item for xbar or SwiftBar (macOS) and Argos or Kargos (Linux).
# Symlink this file into the menu bar app's plugin folder; the "30s" in the
# name is the refresh interval. Everything else lives in sessions.mjs.

# Menu bar apps start plugins with a minimal PATH; add the usual Node locations.
PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$HOME/.local/bin:$PATH"
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
export PATH

self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
script="$(dirname "$self")/../../skills/ramsleeper/scripts/sessions.mjs"

if ! command -v node >/dev/null 2>&1; then
  echo "RAM ?"
  echo "---"
  echo "RAM Sleeper needs Node.js 18 or newer | disabled=true"
  exit 0
fi

exec node "$script" xbar
