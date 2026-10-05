#!/usr/bin/env bash
#
# Install a per-user LaunchAgent that runs portal-watch.sh whenever the
# system's network configuration changes (every WiFi join rewrites DNS
# config), so guest access is requested automatically when the captive
# portal appears. Run with --uninstall to remove it (your config file is
# left in place).

set -euo pipefail

LABEL="local.portal-watch"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$HOME/Library/Logs/portal-request.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# launchd cannot execute scripts in TCC-protected folders (Desktop,
# Documents, Downloads), so install copies outside the repo and run those.
# Re-run this installer after editing the scripts (config-file changes
# take effect on their own).
INSTALL_DIR="$HOME/Library/Application Support/portal-request"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2> /dev/null || true
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR"
  echo "✅ uninstalled $LABEL"
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$INSTALL_DIR"
cp "$SCRIPT_DIR/portal-request.sh" "$SCRIPT_DIR/portal-watch.sh" "$INSTALL_DIR/"

# resolv.conf paths catch DNS rewrites on network joins; the
# SystemConfiguration directory is the belt-and-suspenders catch-all
# (it also fires on unrelated config writes, which the wrapper absorbs)
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${INSTALL_DIR}/portal-watch.sh</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>/etc/resolv.conf</string>
		<string>/private/var/run/resolv.conf</string>
		<string>/Library/Preferences/SystemConfiguration</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>${LOG}</string>
	<key>StandardErrorPath</key>
	<string>${LOG}</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2> /dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✅ installed $LABEL"
echo "   runs:   ${INSTALL_DIR}/portal-watch.sh on network-config changes"
echo "   log:    $LOG"
echo "   note:   re-run this installer after editing the scripts"
echo "   remove: $0 --uninstall"
