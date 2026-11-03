# Troubleshooting

## macOS blocks the first launch

Release builds are ad hoc signed and not notarized. If a browser downloaded the
zip, macOS marks it as quarantined and Gatekeeper may refuse the first launch
("Apple could not verify ...").

Check the checksum first (`shasum -a 256 -c Tower.app.zip.sha256` prints `OK`),
then either:

- **System Settings**: try to open Tower once, then open System Settings,
  Privacy & Security, scroll to the message about Tower and press
  **Open Anyway**. Confirm once.
- **Terminal**, if you prefer: remove the quarantine flag from the app you just
  verified.

  ```bash
  xattr -dr com.apple.quarantine ~/Applications/Tower.app
  ```

  Only do this for a bundle whose checksum matched.

Each new release is a new ad hoc signature, so Keychain asks you to **Re-trust**
once after an update (see the [setup playbook](setup.md#3-keychain-trust)).

## I have an Intel Mac

The release zip is arm64 only. Build from source (README, "Build from
source").

## `swift build` fails with `plugin for module 'SwiftUIMacros' not found`

Some Command Line Tools releases ship a newest SDK whose SwiftUI macro plugin
does not load. `scripts/build-app.sh` probes the installed SDKs and picks one
that works. For a bare `swift build`, pin an older SDK yourself:

```bash
ls /Library/Developer/CommandLineTools/SDKs/
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
```

`swift test` needs XCTest, which ships with Xcode, not with the CLT.

## A seat says `needs login`

Its stored access token expired. Run `/login` in Claude Code with that account
once and open the panel. Tower never renews tokens by design.

## A seat says `unknown since <age>`

The last reading is older than 15 minutes. Inactive seats can only be read
while their token is valid; switch into the seat, or open the panel to refresh.

## The panel says `active seat unknown`

Tower could not prove which account Claude Code holds right now. Open the panel
after your next `/login`, or run `tower status`. It still names the roomiest
seat.

## Everything went blank or shows ⚠️

Tower reads an **undocumented** Claude Code endpoint, which can change with any
Claude Code release, and the endpoint rate limits (HTTP 429, shown as ⚠️ beside
the last known number). Run `tower status` to see the error text, and open an
issue with it.

## A Keychain dialog keeps appearing

It should not: only the first read after a new build may ask, once per item,
and a refusal is not asked again for at least 60 seconds. If it repeats, press
**Forget**, then **Re-trust**, and open an issue with the output of:

```bash
log show --last 1h --predicate 'subsystem == "ai.yonyon.tower" AND category == "retention"'
```

## Reporting a bug

Include `tower selftest` and `tower mcp --self-test` output. Remove emails
before you paste.
