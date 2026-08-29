#!/usr/bin/env bash
set -euo pipefail
LABEL="io.github.magacek.snag"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/snag"
rm -rf "$HOME/Applications/snag.app"
echo "==> Removed. Config kept at ~/.config/snag/config, history at ~/.local/state/snag/."
echo "    Also delete the snag rows in System Settings -> Privacy & Security ->"
echo "    Accessibility and Input Monitoring."
