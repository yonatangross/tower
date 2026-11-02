# Contributing

Thanks for helping. Tower is a small project; issues and pull requests are
welcome.

## Before you open a pull request

1. Build and run the pure-logic checks:
   ```bash
   swift build && .build/debug/Tower selftest
   ```
2. If you have Xcode, run the unit tests: `swift test`. CI runs them on every
   pull request either way.
3. Run the script tests if you touched `scripts/`:
   ```bash
   /bin/bash scripts/test-install.sh
   /bin/bash scripts/test-update.sh
   ```
4. Keep the change small and say in the description what you measured.

## Rules that keep users safe

- Never commit a real email, token, key, account name or screenshot of a real
  panel. Use `example.com` addresses in tests and `scripts/demo-store.py` for
  screenshots.
- Never commit third-party product icons. `scripts/extract-brand-marks.sh`
  copies them locally and `.gitignore` keeps them out.
- A reading Tower could not take is shown as unknown, never as zero.
- Do not add code that sends account data anywhere other than the provider's
  own API.

## Style

Swift 6 toolchain, Swift 5 language mode, no third-party packages. Comments say
why, not what.
