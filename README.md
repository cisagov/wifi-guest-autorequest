# wifi-guest-autorequest #

[![GitHub Build Status](https://github.com/cisagov/wifi-guest-autorequest/workflows/build/badge.svg)](https://github.com/cisagov/wifi-guest-autorequest/actions)
[![License](https://img.shields.io/github/license/cisagov/wifi-guest-autorequest
)](https://spdx.org/licenses/)
[![CodeQL](https://github.com/cisagov/wifi-guest-autorequest/workflows/CodeQL/badge.svg)](https://github.com/cisagov/wifi-guest-autorequest/actions/workflows/codeql-analysis.yml)

Automates a sponsored-guest WiFi captive portal on macOS: detects the
portal, submits the access-request forms, waits for sponsor approval,
confirms connectivity, and dismisses the captive-portal popup window.

- No dependencies — stock macOS `bash`, `curl`, and `dig` only.
- Works while another connection (e.g. USB tethering) is active; it
  forces both DNS and traffic out the WiFi interface.
- No portal addresses are hardcoded — it resolves whatever host the
  portal redirects to, using the WiFi network's own DNS server, so
  portal moves don't break it.

## Setup ##

1. Create `~/.config/portal-request/config` (your organization will
   tell you the portal host pattern):

   ```sh
   GUEST_NAME="Jack Smith"
   GUEST_EMAIL="jack.smith@example.gov"
   SPONSOR_EMAIL="sponsor@example.gov"
   PORTAL_HOST_PATTERN="*.guest-portal.example.com"
   ```

   and `chmod 600` it. The file is parsed (`KEY="value"` lines only),
   never executed, and unknown keys are ignored.

1. Join the guest SSID.
1. Run `./portal-request.sh` and wait for `🎉 Approved — you're online!`
   (your sponsor must click the approval link they receive by email).

## Automatic mode (optional) ##

```sh
./install-launchagent.sh
```

installs a per-user LaunchAgent that re-checks for a captive portal on
every network change. When your portal appears, it submits the request
for you and reports progress via macOS notifications; on any other
network it exits silently. Activity is logged to
`~/Library/Logs/portal-request.log`.

The installer copies the scripts to
`~/Library/Application Support/portal-request/` (launchd can't execute
from Desktop/Documents/Downloads), so re-run it after updating the
scripts; config changes take effect on their own. Remove with
`./install-launchagent.sh --uninstall` (your config file is left in
place).

## What it sends, and where ##

- Your name, email, and sponsor email are submitted only to a portal
  host matching `PORTAL_HOST_PATTERN`, over TLS with certificate
  verification. Automatic mode will never fill your details into some
  other network's captive portal.
- Portal detection sends an empty probe request to `captive.apple.com`
  (the same probe macOS itself uses).
- Logs and notifications stay on your machine. Splash URLs are logged
  with the query string stripped, since it carries client identifiers
  and one-time tokens.

## Tips ##

- Set **Private Wi-Fi Address** to **Fixed** or **Off** for the guest
  network (Wi-Fi settings → Details). Portal authorization is tied to
  your MAC address, so the "Rotating" setting silently de-authorizes
  you when the address rotates — harmless with automatic mode
  installed, surprising without it.
- Portals may clamp the requested access duration server-side; when
  access expires, automatic mode simply re-requests it.
- If the script fails partway, run `DEBUG=1 ./portal-request.sh` to
  save each portal page as HTML (gitignored — they contain session
  tokens). The usual cause is a portal operator changing the form flow;
  the script was built against a two-stage guest/sponsor form with an
  XHR approval poll, and the saved pages show what changed.

## Contributing ##

We welcome contributions!  Please see [`CONTRIBUTING.md`](CONTRIBUTING.md) for
details.

## License ##

This project is in the worldwide [public domain](LICENSE).

This project is in the public domain within the United States, and
copyright and related rights in the work worldwide are waived through
the [CC0 1.0 Universal public domain
dedication](https://creativecommons.org/publicdomain/zero/1.0/).

All contributions to this project will be released under the CC0
dedication. By submitting a pull request, you are agreeing to comply
with this waiver of copyright interest.
