---
name: Bug report
about: Something in Tower shows the wrong thing or does not work
labels: bug
---

**What happened, and what you expected**

**Steps to reproduce**

**Environment**

- Tower version (panel footer or `tower_config_get`):
- macOS version and chip (Apple silicon or Intel):
- Installed from: release zip / `install.sh` / built from source

**Checks** (paste the output; replace every email with `<email>` first)

```
tower selftest
```

```
tower mcp --self-test
```

Please do not paste tokens, Keychain dumps, `accounts.json` or
`quota-cache.json`. Security problems go to SECURITY.md, not to an issue.
