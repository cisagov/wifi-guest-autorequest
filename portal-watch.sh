#!/usr/bin/env bash
#
# launchd wrapper for portal-request.sh — triggered on network-configuration
# changes (see install-launchagent.sh). portal-request.sh exits quietly in
# about a second when there is no captive portal, so spurious triggers
# (power events, DNS rewrites during a join) are harmless.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${TMPDIR:-/tmp}/portal-watch.lock"

# A single network join rewrites config several times; skip if a run is
# already in flight (possibly mid-approval, which takes a minute or so)
if ! mkdir "$LOCK" 2> /dev/null; then
  echo "$(date '+%F %T') run already in progress; skipping"
  exit 0
fi
trap 'rmdir "$LOCK"' EXIT

sleep 3 # let DHCP settle after the network change

echo "$(date '+%F %T') checking for captive portal…"
AUTO=1 "$SCRIPT_DIR/portal-request.sh" || true
