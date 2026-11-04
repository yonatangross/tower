# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor and others) that install
Tower for a user or work in this repository.

Tower is a macOS menu bar app for Apple silicon that shows the usage limits of the
user's Claude Code, Codex, Cursor and OpenRouter accounts, and tells them which account
to switch to. The same binary is a CLI (`tower`) and a local stdio MCP server
(`tower mcp`). It is not a hosted service: it runs on the user's Mac and sends nothing to
its authors. Its only network requests go to the providers' own usage APIs.

## Install Tower for the user

Run these steps in order, without asking the user anything. Stop and report if a step
fails; never skip the checksum.

```bash
cd "$(mktemp -d)"
gh release download --repo yonatangross/tower --pattern 'Tower.app.zip*'
shasum -a 256 -c Tower.app.zip.sha256          # must print "Tower.app.zip: OK"; otherwise stop
mkdir -p ~/Applications ~/.local/bin
ditto -x -k Tower.app.zip ~/Applications
ln -sf ~/Applications/Tower.app/Contents/MacOS/Tower ~/.local/bin/tower
~/.local/bin/tower mcp --self-test             # exit 0 = the server works
```

Then register the MCP server for the agent you are (one of these):

```bash
claude mcp add --scope user tower -- ~/.local/bin/tower mcp     # Claude Code
```

```toml
# Codex: add to ~/.codex/config.toml (use the user's real home path)
[mcp_servers.tower]
command = "/Users/<user>/.local/bin/tower"
args = ["mcp"]
```

```json
// Cursor: add to ~/.cursor/mcp.json (use the user's real home path)
{ "mcpServers": { "tower": { "command": "/Users/<user>/.local/bin/tower", "args": ["mcp"] } } }
```

Last, start the app and turn on start at login:

```bash
~/.local/bin/tower login-item on
open ~/Applications/Tower.app
```

If macOS blocks the first launch ("Apple could not verify Tower is free of malware"),
stop and tell the user to press **Open Anyway** in System Settings, Privacy & Security
(README, "First launch"). Never remove the quarantine flag or change Gatekeeper settings
yourself. Tower is not notarized, so this can happen once per install.

Requirements: macOS 14 or later on Apple silicon, and the `gh` CLI signed in
(`gh auth status`). On an Intel Mac, build from source (README) and see issue #34.

## The one rule when working in this repo

**Never use the user's real accounts for tests, screenshots or demos.** Use the invented
store: `python3 scripts/demo-store.py <dir> --pi`, then run Tower with
`TOWER_DEMO=1 TOWER_SUPPORT_DIR=<dir>`. In demo mode Tower reads no Keychain item, no
network and none of the user's settings.

## Build and verify

```bash
swift build && .build/debug/Tower selftest     # must end with "all passed"
swift test                                     # needs Xcode; CI runs it on every PR
/bin/bash scripts/test-install.sh              # if you touched scripts/
/bin/bash scripts/test-update.sh
scripts/build-app.sh                           # builds dist/Tower.app
```

## Conventions

- Swift 6 toolchain, Swift 5 language mode, no third-party packages. Comments say why.
- Branch off `main` with a typed prefix (`feat/`, `fix/`, `docs/`, `chore/`);
  Conventional Commits for messages and PR titles, no emoji.
- A reading Tower could not take is shown as unknown, never as zero.
- Background reads never show the Keychain dialog; only the user's Re-trust may.
- Never commit a real email, token, key, account name or panel screenshot, and never
  third-party product icons.

## Where to learn more

- `README.md`: install, configuration, MCP tools.
- `docs/reference.md`: the full manual (freshness, retention, signing, CLI).
- `docs/mcp-surface.md`: every MCP tool, resource and prompt.
- `docs/playbooks/`: setup, MCP, multi-account, troubleshooting, uninstall.
- `CONTRIBUTING.md` and `SECURITY.md`.
- Good first issues: https://github.com/yonatangross/tower/labels/good%20first%20issue
