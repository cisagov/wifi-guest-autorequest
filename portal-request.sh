#!/usr/bin/env bash
#
# Automatically request access on sponsored-guest WiFi captive portals (macOS).
#
# Join the guest SSID, then run this script. It detects the captive portal,
# submits the guest-info and sponsor-info forms, polls until the sponsor
# approves, then confirms connectivity and dismisses the macOS captive-portal
# popup (Captive Network Assistant).
#
# Personal settings (name, emails, portal domain) live in a config file,
# not in this script — see README.md.
#
# Works even when another connection (e.g. USB tethering to a phone) is the
# primary route: curl's --interface pins TCP connections but NOT DNS lookups,
# so this script queries the WiFi's DHCP-provided DNS server directly, with
# queries source-bound to the WiFi interface, and pins the answers via
# curl --resolve. No portal addresses are hardcoded.
#
# AUTO=1 runs unattended (used by the portal-watch LaunchAgent; see
# install-launchagent.sh): milestones become macOS notifications, and
# nothing-to-do conditions (WiFi off, no portal) exit quietly instead.
#
# Troubleshooting: run with DEBUG=1 to save each portal page (splash.html,
# guest_form_response.html, sponsor_form_response.html) for inspection.

set -euo pipefail

# Never needs root; running as root would let a user-writable config
# influence a privileged process
[ "${EUID:-$(id -u)}" -ne 0 ] || {
  echo "⚠️  do not run as root" >&2
  exit 1
}

### Defaults — personal values go in the config file, not here ###############

GUEST_NAME=""
GUEST_EMAIL=""
SPONSOR_EMAIL=""       # receives the approval request
PORTAL_HOST_PATTERN="" # e.g. "*.guest-portal.example.com"

# Portals may clamp the requested duration server-side; asking high is harmless
DURATION_QTY=52
DURATION_UNITS=604800 # seconds per unit: 60=min 3600=hr 86400=day 604800=wk

IFACE=en0 # WiFi interface
APPROVAL_TIMEOUT_SECS=600
NOTIFY_TITLE="Guest WiFi"

USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.10 Safari/605.1.1"

##############################################################################

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/portal-request/config"

# The config is parsed, never executed, so a tampered config can change
# settings but cannot run code. Format: KEY="value", one per line.
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in '' | \#*) continue ;; esac
    value="${value#[\"\']}"
    value="${value%[\"\']}"
    case "$key" in
      GUEST_NAME | GUEST_EMAIL | SPONSOR_EMAIL | PORTAL_HOST_PATTERN | \
        IFACE | NOTIFY_TITLE)
        printf -v "$key" '%s' "$value"
        ;;
      # numeric settings are used in arithmetic, where bash evaluates
      # non-numeric text (a code-execution vector) — digits only
      DURATION_QTY | DURATION_UNITS | APPROVAL_TIMEOUT_SECS)
        case "$value" in
          '' | *[!0-9]*) echo "   ignoring non-numeric value for $key" >&2 ;;
          *) printf -v "$key" '%s' "$value" ;;
        esac
        ;;
      *)
        echo "   ignoring unknown config key: $key" >&2
        ;;
    esac
  done < "$CONFIG_FILE"

  local perms
  perms=$(stat -f '%Lp' "$CONFIG_FILE")
  [ $((0$perms & 077)) -eq 0 ] \
    || echo "note: $CONFIG_FILE is readable by other users - chmod 600 it" >&2
}
load_config

AUTO="${AUTO:-}"

notify() { # notify <message> [sound-name] — echoed; banner in AUTO mode
  echo "$1"
  [ -n "$AUTO" ] || return 0
  # strip characters that would break out of the AppleScript string
  local msg="${1//[\"\\]/}" title="${NOTIFY_TITLE//[\"\\]/}"
  local script="display notification \"$msg\" with title \"$title\""
  [ -n "${2:-}" ] && script="$script sound name \"$2\""
  osascript -e "$script" > /dev/null 2>&1 || true
}

die() {
  notify "⚠️  $*" "Basso" >&2
  exit 1
}

# Pre-portal conditions (WiFi off, no portal) are errors interactively but
# routine in AUTO mode, where the agent probes on every network change
nothing_to_do() {
  [ -z "$AUTO" ] || exit 0
  die "$@"
}

# The config is only required once a portal is actually found, so the agent
# stays quiet on networks this tool isn't configured for
require_config() {
  local missing=()
  [ -n "$GUEST_NAME" ] || missing+=(GUEST_NAME)
  [ -n "$GUEST_EMAIL" ] || missing+=(GUEST_EMAIL)
  [ -n "$SPONSOR_EMAIL" ] || missing+=(SPONSOR_EMAIL)
  [ -n "$PORTAL_HOST_PATTERN" ] || missing+=(PORTAL_HOST_PATTERN)
  [ ${#missing[@]} -gt 0 ] || return 0
  cat >&2 <<- EOF
		Create $CONFIG_FILE (and chmod 600 it) containing:
		    GUEST_NAME="Jack Smith"
		    GUEST_EMAIL="jack.smith@example.gov"
		    SPONSOR_EMAIL="sponsor@example.gov"
		    PORTAL_HOST_PATTERN="*.guest-portal.example.com"
	EOF
  die "portal found, but config is missing: ${missing[*]}"
}

debug_save() { # debug_save <filename> <content>
  [ -n "${DEBUG:-}" ] && printf '%s' "$2" > "$1"
  return 0
}

COOKIE_JAR=$(mktemp -t portal_cookies)
trap 'rm -f "$COOKIE_JAR"' EXIT

IFACE_IP=$(ipconfig getifaddr "$IFACE") \
  || nothing_to_do "$IFACE has no IP address - is WiFi on?"
DNS_SERVER=$(ipconfig getoption "$IFACE" domain_name_server)
[ -n "$DNS_SERVER" ] || nothing_to_do "no DNS server from DHCP on $IFACE"
echo "→ $IFACE ip: $IFACE_IP, dns: $DNS_SERVER"

# Resolve a hostname using the WiFi's DNS server, forcing the query out the
# WiFi interface by source-binding it. Prints nothing on failure.
resolve_host() {
  dig +short +time=3 +tries=2 -b "$IFACE_IP" @"$DNS_SERVER" "$1" A \
    | awk '/^([0-9]+\.){3}[0-9]+$/ { print; exit }' || true
}

# Common curl options; portal host pins are appended once discovered
CURL=(curl --silent --show-error
  --interface "$IFACE"
  --user-agent "$USER_AGENT"
  --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR")

# 1) Probe a known-HTTP URL; the portal gateway answers with a redirect
CAPTIVE_HOST="captive.apple.com"
CAPTIVE_IP=$(resolve_host "$CAPTIVE_HOST")
[ -n "$CAPTIVE_IP" ] || nothing_to_do "could not resolve $CAPTIVE_HOST via $DNS_SERVER"

echo "→ probing http://$CAPTIVE_HOST for portal redirect…"
headers=$("${CURL[@]}" --head --resolve "${CAPTIVE_HOST}:80:${CAPTIVE_IP}" \
  "http://$CAPTIVE_HOST") || nothing_to_do "probe failed"

status=$(printf '%s\n' "$headers" | head -n1 | awk '{print $2}')
[ "$status" != "200" ] \
  || nothing_to_do "got HTTP 200 - no captive portal detected. Already authorized?"
echo "   status: $status (portal detected)"

# 2) The redirect Location is the portal splash URL
splash_url=$(printf '%s\n' "$headers" \
  | awk -F': ' '/^[Ll]ocation:/ { print $2; exit }' \
  | tr -d '\r')
[ -n "$splash_url" ] || die "no Location header in portal response"
# the query string carries client identifiers and one-time tokens; keep it
# out of terminal output and logs
echo "   splash URL: ${splash_url%%\?*} (query redacted)"

require_config

splash_host=$(printf '%s' "$splash_url" | sed -E 's#^https?://([^/:]+).*#\1#')
# Only submit personal info to the expected portal — keeps AUTO mode from
# filling it into some other network's captive portal
# shellcheck disable=SC2254 # glob expansion of the pattern is intended
case "$splash_host" in
  $PORTAL_HOST_PATTERN) ;;
  *) die "unrecognized portal host '$splash_host' - not submitting credentials" ;;
esac

notify "Captive portal detected — requesting guest access for ${GUEST_EMAIL}…"

# 3) Resolve the splash host and pin it for all remaining requests
splash_ip=$(resolve_host "$splash_host")
[ -n "$splash_ip" ] || die "could not resolve $splash_host via $DNS_SERVER"
echo "   splash host: $splash_host → $splash_ip"
CURL+=(--resolve "${splash_host}:443:${splash_ip}"
  --resolve "${splash_host}:80:${splash_ip}")

# 4) Fetch the splash page; its <base href> locates the login endpoint
echo "→ fetching splash page…"
splash_html=$("${CURL[@]}" "$splash_url")
debug_save splash.html "$splash_html"

base_href=$(printf '%s\n' "$splash_html" \
  | sed -n 's/.*<base href="\([^"]*\)".*/\1/p')
[ -n "$base_href" ] || die "no <base href> on splash page (DEBUG=1 to save it)"
login_url="${base_href}login"

# 5) Submit the two-stage form: guest info, then sponsor info
echo "→ submitting guest-info form…"
guest_response=$("${CURL[@]}" "$login_url" \
  --data-urlencode "utf8=✓" \
  --data-urlencode "guest_name=${GUEST_NAME}" \
  --data-urlencode "guest_email=${GUEST_EMAIL}" \
  --data "requested_duration_quantity=${DURATION_QTY}" \
  --data "requested_duration_units=${DURATION_UNITS}" \
  --data-urlencode "stage=guest_info" \
  --data-urlencode "commit=Continue")
debug_save guest_form_response.html "$guest_response"

echo "→ submitting sponsor-info form…"
sponsor_response=$("${CURL[@]}" "$login_url" \
  --data-urlencode "utf8=✓" \
  --data-urlencode "guest_name=${GUEST_NAME}" \
  --data-urlencode "guest_email=${GUEST_EMAIL}" \
  --data-urlencode "sponsor_email=${SPONSOR_EMAIL}" \
  --data "requested_duration_quantity=${DURATION_QTY}" \
  --data "requested_duration_units=${DURATION_UNITS}" \
  --data-urlencode "stage=sponsor_info" \
  --data-urlencode "commit=Request internet access")
debug_save sponsor_form_response.html "$sponsor_response"

# 6) The response page polls a status endpoint via XHR; extract its URL
poll_url=$(printf '%s' "$sponsor_response" | tr '\n' ' ' \
  | grep -o 'xmlhttp\.open("POST", "[^"]*set_sponsor_authorization_status_and_redirect[^"]*"' \
  | cut -d '"' -f4) || true
[ -n "$poll_url" ] \
  || die "no polling endpoint in response - portal flow may have changed (DEBUG=1 to save pages)"

notify "Request sent — waiting for sponsor approval (up to $((APPROVAL_TIMEOUT_SECS / 60)) min)…"
deadline=$((SECONDS + APPROVAL_TIMEOUT_SECS))
while :; do
  poll_response=$("${CURL[@]}" --location --request POST "$poll_url")
  approved=$(printf '%s' "$poll_response" \
    | sed -E 's/.*"success":[[:space:]]*([^,}]*).*/\1/')
  [ "$approved" = "true" ] && break
  [ "$SECONDS" -lt "$deadline" ] \
    || die "no approval after $((APPROVAL_TIMEOUT_SECS / 60)) minutes - check ${SPONSOR_EMAIL}'s inbox"
  echo "   still waiting… retrying in 10s"
  sleep 10
done
echo "🎉 approved!"

# 7) Confirm connectivity, then dismiss the macOS captive-portal popup
# (it only re-probes on its own schedule, so it lingers after we
# authorize behind its back)
echo "→ verifying connectivity…"
for _ in $(seq 1 12); do
  if "${CURL[@]}" --max-time 5 --resolve "${CAPTIVE_HOST}:80:${CAPTIVE_IP}" \
    "http://$CAPTIVE_HOST" | grep -q Success; then
    notify "🎉 Approved — you're online!" "Glass"
    killall "Captive Network Assistant" 2> /dev/null || true
    exit 0
  fi
  echo "   not yet… retrying in 5s"
  sleep 5
done

die "approved, but connectivity check never returned Success"
