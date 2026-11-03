# Setup playbook

From nothing to a panel that shows your accounts. About five minutes.

## 1. Install

Requirements: macOS 14 or later on Apple silicon. On an Intel Mac, build from
source (see the README, "Build from source").

```bash
gh release download --repo yonatangross/tower --pattern 'Tower.app.zip*'
shasum -a 256 -c Tower.app.zip.sha256
ditto -x -k Tower.app.zip ~/Applications
```

`shasum` must print `Tower.app.zip: OK`. Anything else, stop and delete the
download.

No `gh`? Download `Tower.app.zip` and `Tower.app.zip.sha256` from the
[latest release](https://github.com/yonatangross/tower/releases/latest) in a
browser and run the same two commands from the download folder.

Optional, for the CLI and the MCP server:

```bash
mkdir -p ~/.local/bin
ln -sf ~/Applications/Tower.app/Contents/MacOS/Tower ~/.local/bin/tower
tower selftest
```

## 2. First launch

Open `~/Applications/Tower.app`. Release builds are ad hoc signed, not
notarized, so macOS may block the first launch. If it does, see
[troubleshooting](troubleshooting.md#macos-blocks-the-first-launch).

Tower lives in the menu bar; there is no Dock icon. Click it to open the panel.
macOS asks once for permission to post notifications (Tower alerts at 80, 95
and 100 percent of a window).

Start at login: the checkbox in the panel, or `tower login-item on`.

## 3. Keychain trust

Tower reads the Claude Code credential through Apple's own `security` tool, so
a fresh install shows **no** Keychain dialog. It then keeps each signed in
seat's access token in a Keychain item it owns (`Tower-seat-<email>`), so it
can read that seat after you switch away.

| Situation | Keychain prompts |
| --- | --- |
| Fresh install | 0 |
| A new release (ad hoc signed, so a new identity) | 1, when you press **Re-trust** in the panel |
| Background refresh, `tower status`, `tower mcp` | 0, always |

Tower never asks for your login password, never stores a refresh token and
never renews a token. To delete what it stored, press **Forget**, or turn off
**Remember Claude seats**.

## 4. Add your accounts

Tower can only read a Claude Code account it has seen you signed into. Add each
one once:

1. In Claude Code, run `/login` and sign into the account.
2. Open the Tower panel (opening it refreshes).
3. Repeat for the next account.

Each seat stays readable until its access token expires; after that the row
reads **needs login** until you sign into it again.

Optional: list accounts before you have signed into them, so they show as empty
slots, and give them short names:

```bash
cd ~/Library/Application\ Support/Tower
echo '["work@example.com", "side@example.com"]' > known-accounts.json
echo '{"work@example.com": "work", "side@example.com": "side"}' > nicknames.json
```

Codex and Cursor need no setup: Tower reads them from their own local state
when they are installed and signed in. See the
[multi-account playbook](multi-account.md).

## 5. Check it

```bash
tower status
```

You should see every account you signed into, with its 5 hour and weekly
windows. Next: [let your agents ask Tower](mcp.md).
