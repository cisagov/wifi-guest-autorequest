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
# already in flight (possibly mid-approval, which takes a minute or so).
# A lock whose owner is gone (e.g. SIGKILL skipped the trap) is stale —
# reclaim it rather than letting it block requests until reboot.
if ! mkdir "$LOCK" 2> /dev/null; then
  owner=$(cat "$LOCK/pid" 2> /dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2> /dev/null; then
    echo "$(date '+%F %T') run already in progress (pid $owner); skipping"
    exit 0
  fi
  echo "$(date '+%F %T') reclaiming stale lock"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2> /dev/null || exit 0 # lost the race to another reclaimer
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

sleep 3 # let DHCP settle after the network change

echo "$(date '+%F %T') checking for captive portal…"
AUTO=1 "$SCRIPT_DIR/portal-request.sh" || true
