# Uninstall

Removes Tower and everything it stored. Run the steps in order: the Keychain
items are easiest to delete while the app still runs.

1. **Delete the stored seat tokens.** In the panel press **Forget** (or turn
   off **Remember Claude seats**). This deletes every `Tower-seat-<email>` item
   Tower created in your login Keychain.
2. **Stop start at login.**

   ```bash
   tower login-item off
   ```

3. **Quit** from the panel.
4. **Remove the app, its data, its settings and the CLI link.**

   ```bash
   rm -rf ~/Applications/Tower.app
   rm -rf ~/Library/Application\ Support/Tower
   defaults delete ai.yonyon.tower
   rm -f ~/.local/bin/tower
   ```

5. **Optional.** Tower mirrors its readings to `~/.claude/quota-cache.json` for
   hooks that read it. Delete that file if nothing else of yours uses it. Remove
   the `tower` entry from any agent MCP config you added
   ([MCP playbook](mcp.md)).

Upgraded from a build before v0.1? Also remove the old id:

```bash
rm -rf ~/Library/Application\ Support/HQClaudeLimits
defaults delete ai.yonatan-hq.claude-limits
```

Missed step 1? Delete the items in Keychain Access: search for `Tower-seat-`
and delete each match.
