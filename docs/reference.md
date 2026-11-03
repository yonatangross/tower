# Tower reference

The detailed manual. Start with the [README](../README.md); task-shaped guides
are in [playbooks/](playbooks/).

> Ships as `Tower.app`. It covers Claude Code accounts, Codex, Cursor, and the
> OpenRouter balance, so it is not Claude-specific.

macOS menubar app that answers one question before you start work: **which account can
take this, and what is already running?**

It reads **real** Claude Code usage limits across all your accounts, so switching between
them stops being a guessing game, and it carries the rest of the picture alongside them:
Codex tier, Cursor model-pool usage, OpenRouter balance and spend trend, live agent sessions per
repo, and threshold alerts. Hence "Tower", not "Limits": it is air-traffic control
for the fleet, not a gauge.

Not an estimator. It reads the same authoritative numbers Claude Code's own `/usage`
screen renders.

```
📊 TOWER                                               21:32
──────────────────────────────────────────────────────────────
▶ side max     🟢
    5h   ██░░░░░░░░░░ 14%  resets Jul 25 02:10
    7d   ░░░░░░░░░░░░ 3%   resets Jul 29 21:00
    Fable░░░░░░░░░░░░ 2%   resets Jul 29 20:59
  work   max     🟠
    5h   ░░░░░░░░░░░░ 0%   reset ✓
    7d   ████████░░░░ 68%  resets Jul 27 09:00
    snapshot 4h ago
──────────────────────────────────────────────────────────────
✅ Most headroom: side at 14% used
```

Other providers get their own section, with only the windows they actually publish:

```
CURSOR  (1 available)
  work   pro     🟢
    month ░░░░░░░░░░░░ 4%    resets Sep 1 03:00
    credits $0.76 of $20 used
```

## Install

Tagged releases (`v*`) are the supported install. The README's quick start and
the [setup playbook](playbooks/setup.md) cover the plain zip. From a clone,
`install.sh` does the same download, checksum check and install, and also
handles start at login and an upgrade from a build before v0.1:

```bash
./scripts/install.sh --from-release v0.1.0
ln -sf ~/Applications/Tower.app/Contents/MacOS/Tower ~/.local/bin/tower
tower login-item on
```

Prerequisites: the `gh` CLI, authenticated (`gh auth status`).

Every push to `main` also builds a `tower-app-<sha>` workflow artifact, for
testing an unreleased change: `./scripts/install.sh --from-artifact` takes the
newest successful `Release Tower app` run on `main`. Both options verify the
archive's SHA-256 against the checksum shipped alongside it before unpacking; a
checksum mismatch or a malformed manifest fails the install rather than
installing an unverified bundle.

Installing to `~/Applications` (the default) rather than running from `dist/`
matters: the login item registers against the bundle's path, and `build-app.sh`
starts with `rm -rf dist/`.

Rollback: install an older tag with `--from-release <tag>`. For an untagged
build, download that run's `tower-app-<sha>` artifact by hand and apply the same
checksum check before unpacking:

```bash
gh run download <run-id> --repo yonatangross/tower --name tower-app-<sha> --dir /tmp/tower-old
cd /tmp/tower-old && shasum -a 256 -c Tower.app.zip.sha256
```

If you already have a local build, `./scripts/build-app.sh` followed by a bare
`./scripts/install.sh` (no flags) installs `dist/Tower.app` directly.

## Updating after a merge

Nothing installs on its own when a PR merges: `release-app.yml` builds a fresh
`tower-app-<sha>` artifact on every push to `main`, but the copy in
`~/Applications` keeps running whatever was installed last. Pull the newest
build with:

```bash
./scripts/update.sh
```

It finds the newest successful `Release Tower app` run on `main`, then
delegates the download, SHA-256 verification, install and relaunch to
`install.sh`. It prints the old and new build sha, and skips the reinstall
when the installed build already matches the newest artifact (relaunching the
app anyway if it is not running). The checksum verifies integrity, not
provenance: the archive and its checksum ship inside the same artifact, so
trust rests on who can write artifacts to this repo.

The build sha is `CFBundleVersion` inside the bundle's `Info.plist`, stamped
from the short git sha at build time (with a `-dirty` suffix for uncommitted
changes). Builds from before stamping existed still read `1`. Check what is
installed with:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' ~/Applications/Tower.app/Contents/Info.plist
```

## CLI

The same binary answers without the GUI. Symlink it once:

```bash
ln -sf ~/Applications/Tower.app/Contents/MacOS/Tower ~/.local/bin/tower
```

| Command | Does |
|---|---|
| `tower status` | Print the table for every known account, grouped by provider |
| `tower selftest` | Pure-logic checks, no network, no GUI |
| `tower login-item [on\|off]` | Read or set start-at-login |
| `tower rotate` | Advisory manual login plan: which Claude seat to sign into next, through which Chrome profile |
| `tower panelshot [out.png] [light] [expand]` | Render the real panel offscreen from persisted data, no credential read |
| `tower mcp` | Stdio MCP server over the same store and Keychain, for any lane that can speak MCP (see below) |
| `tower mcp --self-test` | List the tools and read one account, an MCP preflight; exits non zero on a broken server |

## MCP

`tower mcp` is the same binary answering over the Model Context Protocol on
stdin and stdout, so a cursor, codex, pi or Claude lane gets Tower's real
numbers rather than a copy of the cache. Register it in your agent's MCP
config as `${HOME}/.local/bin/tower mcp` (after installing, since the installed
app has to carry the verb).

Twenty tools carry every read Tower does (`tower_status`, `tower_room`,
`tower_advice`, `tower_alerts`, `tower_seats`, `tower_resets`, `tower_lanes`,
`tower_sessions`, `tower_panelshot` as an image, and the rest) and every write
the panel or the CLI performs (`tower_refresh`,
`tower_forget_seats`, `tower_config_set`, `tower_alert_ack`). Every tool
returns `structuredContent` under a published `outputSchema`, every write is
annotated (`readOnlyHint`, `destructiveHint`, `idempotentHint`,
`openWorldHint`) and is refused with a named code when one of Tower's own
preconditions fails (`NoResetTime`, `NotPollable`).
The quota cache is a subscribable resource (`tower://quota-cache`), each
account is a resource (`tower://accounts/{id}`), and three prompts ask the
questions a multi-agent setup asks ("pick an account for a lane of class X",
"is there room for a long job", "rotation brief").

The server speaks the current spec revision, `2026-07-28` (stateless,
`server/discover`, `subscriptions/listen`), and the legacy `initialize`
handshake for `2025-11-25` and earlier, which is what Claude Code 2.1.278
sends. Reads never touch the Keychain; `tower_seats` and `tower_refresh`
read it the way `tower status` does. The full enumeration, with a
`file:line` per capability and the reason for each one left unmapped, is
[`docs/mcp-surface.md`](docs/mcp-surface.md).

## Alerts

Crossing 80%, 95% and 100% of either window posts a native notification, at most once
per level per window. Bookkeeping is keyed by the window's `resets_at`, so a new window
starts silent on its own and stale keys self-prune. macOS will ask for notification
permission on first launch.

## How it works

| Step | Detail |
|---|---|
| Credential | Reads the active login via `/usr/bin/security find-generic-password -s "Claude Code-credentials"`. Shelling out to Apple-signed `security` avoids a Keychain prompt on every rebuild. |
| Usage | `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <accessToken>`. |
| Identity | `GET /api/oauth/profile` for the account email, cached per access token since that binding never changes. |
| Storage | `~/Library/Application Support/Tower/accounts.json`, guarded by a cross-process advisory lock (`flock`). The GUI app and `tower status` are separate processes doing read-modify-write on the same file. Before v0.1 the directory was `HQClaudeLimits`; the first launch of v0.1 moves its entries here (README, "Upgrading from a build before v0.1"). |
| Window states on disk | `accounts.json` and its mirror `~/.claude/quota-cache.json` carry three states per window. A missing pct key means not measured. A pct with no flag is a capture. A pct of 0 with `fiveHourReset: true`, `weeklyReset: true`, or `reset: true` on a scoped limit is derived: that window's `resetsAt` passed after the capture, so Tower zeroed it. The flag is written only in that case and is recomputed on every save, so a new capture clears it. |
| Lane rows on disk | Muse, Devin and Antigravity have rows in `accounts.json` and the mirror, keys `muse:muse@local`, `devin:devin@local`, `agy:agy@local`. They are never ranked (`isRankable` is false). Percentages are percent USED. `fiveHourPct` is the lane's SHORT window (Devin: a day, Muse: "window"), `weeklyPct` the weekly one, each with its own `...ResetsAt`; the names are in `scoped` labels. `capturedAt` is when the tool observed the numbers (Devin's cache fetch time, Muse's `asOfMs`), `readAt` is when Tower looked, `source` is `live` (`muse usage --json`, one bounded call per refresh) or `cache` (Devin's own `user_status` cache). A lane row exists ONLY when it has a real `capturedAt` and a valid percent: platform validates the whole mirror at once and requires `capturedAt` on every row, so one row without it would turn every account unknown. A lane Tower cannot read (not logged in, no cache, nothing exposed) has NO row, and a row it had before is removed so an older capture cannot outlive a failed read; its reason stays in `tower_lanes` over MCP. Antigravity exposes nothing readable, so it has no row today. |
| Claude seat retention | On by default. After Tower verifies a Claude identity, it stores that seat's access token and nonsecret metadata in a Tower-owned Keychain item. Turn off **Remember Claude seats** to delete those items, or choose **Forget** to delete them while keeping future retention on. A remembered seat reads needs login once its access token expires; Tower never renews it. Seat items are read from the Keychain once per launch and kept in memory. An owned item a rebuilt (ad-hoc signed) Tower cannot read is skipped, named on its row, and re-created once from the CLI credential when it is the active seat, or at that seat's next login otherwise; see "Signing" below. The panel, `tower status` and `tower mcp` read this switch from one settings domain, the app's bundle id, even when `tower` runs through its PATH symlink (#121); `tower_config_get` reports it as `identity.settingsDomain`. |
| Text size | The panel footer's **Text size** picker (S 100 %, M 115 %, L 130 %, XL 150 %) scales every font and text column; a fresh install starts at M. When the boards outgrow the screen they scroll under a fixed header and footer. `TOWER_TEXT_SIZE` (s, m, l or xl) overrides it for one run, which is how `panelshot` renders a given size (#121). |
| Cursor | Identity from Cursor's own state (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, an unencrypted SQLite key/value table read via `sqlite3 -readonly`), so nothing is pasted and nothing goes stale behind you. The two monthly model pools from `GET /api/usage-summary` on cursor.com, authenticated by the session cookie composed from that state. Nothing is written and no Keychain prompt is raised. |
| Poll rate | On menu open (debounced: skipped if the last *attempt* was under 20 seconds ago, so an offline machine does not re-run request timeouts on every open), every 300 seconds on a timer, and on wake from sleep (`NSWorkspace.didWakeNotification`). The timer sits well inside the 15 minute freshness TTL, so the active account stays live with margin. |

### The one real constraint

**Claude Code keeps exactly one usable credential at a time.** The Keychain holds a
single live `Claude Code-credentials` item.

Verified 2026-07-26: there are 15 `Claude Code-credentials-<hash>` siblings. Fourteen
contain only an `mcpOAuth` key, so they really are per-plugin MCP OAuth stores. One
(`Claude Code-credentials-fbb6028b`) does contain a full `claudeAiOauth` object with
accessToken, refreshToken, scopes and `subscriptionType: max`. That one is dead: its
`expiresAt` is 2026-02-01, and a live `GET /api/oauth/profile` with its accessToken
returned HTTP 401. A stray full credential can therefore exist among the siblings, but it
is an expired leftover, which leaves the single live item as the only usable source.

Tower retains each verified seat's **access token** in its own Keychain item, so it can
read live usage for the seats it has observed until each token expires. It never stores
or presents a refresh token and never renews a token. Retention is on by default and can
be disabled from the panel, which deletes Tower-owned retained seats. **Forget** deletes
them immediately while leaving future retention enabled.

### Signing, and why an owned item can refuse a rebuild

A Keychain item's ACL names the code signature of the build that wrote it. `scripts/build-app.sh`
signs with a self-signed code-signing identity named **Tower Dev** when
`security find-identity -v -p codesigning` lists one, and ad-hoc (`codesign --sign -`) otherwise.

- **Tower Dev**: every local build carries the same designated requirement, so the owned
  items written by one build stay readable by the next, with no prompt.
- **Ad-hoc**: the signature is new per build, so the item written by yesterday's Tower answers
  `errSecAuthFailed` (-25293) or `errSecInteractionNotAllowed` (-25308) to today's. CI and
  `release-app.yml` always sign ad-hoc (no identity or signing secret exists there), so a CI
  artifact arrives in this case.
- **Installing an artifact or a release** (`scripts/install.sh --from-artifact`,
  `--from-release <tag>`, and `scripts/update.sh`, which delegates to it) re-signs the
  downloaded bundle with **Tower Dev** before its first launch when this machine has the
  identity (#121), so an update no longer orphans every owned seat item. Without the identity
  the artifact keeps its ad-hoc signature. `scripts/sign-app.sh` holds the one rule both
  scripts use.

#### Creating the Tower Dev identity (once per machine)

Keychain Access:

1. Keychain Access, menu **Keychain Access > Certificate Assistant > Create a Certificate...**
2. Name `Tower Dev`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**, then **Create**.
3. In the login keychain open the new `Tower Dev` certificate, expand **Trust**, and set
   **Code Signing** to **Always Trust**. Close the window and enter your password.
4. Check: `security find-identity -v -p codesigning` lists `"Tower Dev"`.

The `security` CLI equivalent (the key never leaves `$TMPDIR`, the bundle is deleted at the end):

```bash
work="$(mktemp -d)" && cd "$work"
printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' \
  '[dn]' 'CN = Tower Dev' \
  '[ext]' 'basicConstraints = critical, CA:false' 'keyUsage = critical, digitalSignature' \
  'extendedKeyUsage = critical, codeSigning' > tower-dev.cnf
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config tower-dev.cnf \
  -keyout tower-dev.key -out tower-dev.pem
export P12PASS="$(openssl rand -hex 16)"
# Homebrew OpenSSL 3 needs -legacy here, or `security import` rejects the bundle.
openssl pkcs12 -export -inkey tower-dev.key -in tower-dev.pem -name "Tower Dev" \
  -passout env:P12PASS -out tower-dev.p12
security import tower-dev.p12 -k ~/Library/Keychains/login.keychain-db -P "$P12PASS" -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db tower-dev.pem
security find-identity -v -p codesigning
cd - && rm -rf "$work"
```

`-T /usr/bin/codesign` lets `codesign` use the key without a prompt; `add-trusted-cert` asks for
your password once. The next `scripts/build-app.sh` prints `codesign with "Tower Dev"`. Items the
previous ad-hoc builds wrote still refuse that first build once, and are re-created as described
below; after that, rebuilds read them silently.

#### What Tower does when an owned item refuses the build

- The roster **falls back to the CLI credential** (the live `Claude Code-credentials` item,
  read through Apple-signed `security`) plus every owned item this build can read. The
  active seat stays listed and refreshable.
- **Seat items are read once per launch.** The first listing is kept in memory, the vault's
  own writes and deletes are applied to it, and later refreshes are served from that copy.
  That first read is also the only one allowed to show the Keychain dialog: it is your one
  **Always Allow** chance to bless the current signer (one dialog per item the ACL does not
  yet cover). A denial, a dismissed dialog or a locked keychain is kept as that item's
  answer and asked again no sooner than 60 seconds later, always with interaction
  suppressed, so a refused item can never start a prompt storm. An unreadable item is never
  deleted, re-created or overwritten except as described below.
- The unreadable seat's row says **which item and which status**
  (`needs login: Keychain item Tower-seat-<email> unreadable (-25293); ...`) instead of a
  bare needs login, and it stays out of ranking.
- When the refused item is the **active seat**, the first refresh verifies the CLI credential
  against the profile endpoint, deletes that exact item (service, account, label) and writes
  a fresh one under the current signer. That happens **once per launch per token**: if the
  delete or write fails, it is logged and not retried until the next launch or a new login.
  Any other refused seat is re-created the same way at its next verified login.
- Every event is **one line** in the unified log and on stderr (`retained seat unreadable, ...`
  once per launch per item, `retained seat re-created ...` or `retained seat re-create failed, ...`),
  so how often this fires is countable. It never writes a trace file of its own:
  `log show --last 7d --predicate 'subsystem == "ai.yonyon.tower" AND category == "retention"'`.
- Each refresh logs how many `SecItemCopyMatching` calls it made (category `keychain`,
  `SecItemCopyMatching calls this refresh: N (launch total M)`); add `--debug` to see each call:
  `log show --last 1h --debug --predicate 'subsystem == "ai.yonyon.tower" AND category == "keychain"'`.

Two Keychain calls, not one: on macOS 26 the login keychain rejects a single
`SecItemCopyMatching` that combines `kSecMatchLimitAll` with `kSecReturnData` with
`errSecParam` (-50), even when nothing matches. Tower lists attributes first and then reads
each owned item on its own, which is also what makes the per-item fallback possible.

A passed `resets_at` permits reset arithmetic for the captured window. It does not
measure usage since that capture, so it cannot make an old snapshot current again.
Only a successful usage fetch advances `capturedAt`.

## Freshness

Trust is tracked per **window**, not per account. Every window is in one of three states:

| State | Meaning |
|---|---|
| `unknown` | Never captured, or no reading for that window. |
| `live` | The usage capture is at most 15 minutes old and contains a reading for this window. |
| `stale` | The capture is older than 15 minutes, or its timestamp is in the future. A reset cannot renew it. |

The freshness clock uses `capturedAt`, Tower's successful-fetch timestamp. The existing
15-minute TTL is stricter than every provider's shortest quota window, including Claude's
five hours. A snapshot older than that window therefore cannot regain room eligibility
when a reset passes. Missing windows remain unknown, and all of an account's ranked
windows must be live before its room can be compared.

Stale rows show `unknown since <age>` without percentages in the panel and CLI. They stay
visible in the unknown/resting section, sorted by name rather than cached room, and are
excluded from room ordering and every `next` fallback regardless of the resting filter.
`tower rotate` lists unknown seats with their age and Chrome profile separately from its
usable seats; it produces no login plan when every mapped seat is stale or capped.

A remembered seat polls until its access token expires; the freshness rules here are about
the capture age, not the credential. Staleness of seats Tower cannot poll at all remains #20.

## Configuration

`~/Library/Application Support/Tower/known-accounts.json` lists the accounts to
show as slots before they have ever been captured. Edit freely.

`retired-accounts.json` in the same directory hides explicitly retired Claude seats.
To return a seat to service, run `/login` in Claude Code with that account, then refresh
Tower. A verified active profile clears the old retirement and the usage response restores
its row and quota mirror. If usage cannot be read, its percentages remain unknown. A
retirement written while profile verification is in flight takes precedence; Tower asks
for `/login` and another refresh instead of silently undoing that change.

The Jev credit row (TypeSafe) cannot be read live: TypeSafe's API publishes no balance
or billing endpoint. The figure is entered by hand and greys out after three days. Read the
balance off the TypeSafe console's Billing page, then set it with the MCP tool
`tower_config_set` (`key` `typesafe.balanceUSD`, `value` the dollars left). Tower dates the
entry today; `null` clears it. With no entry the row is hidden.

Nicknames default to the first six characters of the email's local part. To pick
your own, write `nicknames.json` in the same directory, for example
`{"work@example.com": "work"}`. It is read at launch.

The OpenRouter key comes from `OPENROUTER_API_KEY`, or from a command you set
(see the README, "Configuration").

`TOWER_SUPPORT_DIR` points Tower at another store directory instead of
`~/Library/Application Support/Tower`. `TOWER_DEMO=1`, honoured only together with
`TOWER_SUPPORT_DIR`, makes that store a demo: the active login is read from
`<dir>/demo-credential.json` (`{"accessToken": "...", "emailHint": "..."}`) and never
from the Keychain, refresh never reaches the network, the quota mirror stays inside the
store, and this Mac's Chrome profiles, agent lanes, sessions, OpenRouter key, login item
and settings are not read or changed. Without the file the active seat is unverified.
Only `tower mcp` and `tower panelshot` run in demo mode; other verbs, and `TOWER_DEMO=1`
without `TOWER_SUPPORT_DIR`, exit 2. `python3 scripts/demo-store.py <dir> --active work`
writes an invented store whose `active-seat.json` is bound to its invented credential:

```
python3 scripts/demo-store.py /tmp/tower-demo --active work
TOWER_DEMO=1 TOWER_SUPPORT_DIR=/tmp/tower-demo tower mcp
```

When Tower cannot verify which seat the CLI holds, `tower_advice` keeps `kind`
`activeUnknown` and its summary names the roomiest seat and its room, for example
`no verified active seat; most room: side (88%)`. The panel banner reads the same.

## Caveats

- `/api/oauth/usage` is an **undocumented** endpoint used by the Claude Code client. It
  can change or disappear on any release. If the app goes blank, that is the first
  suspect.
- Cursor's `GET /api/usage-summary` route is **undocumented** and can change with the
  dashboard. Tower reads `autoPercentUsed` as **Cursor Models** and `apiPercentUsed` as
  **Other Models**, with the reset from `billingCycleEnd`. Missing readings stay unknown.
- Cursor's aggregate `totalCostCents` is model-rate usage cost in cents, not the amount
  billed or the fraction of either model pool. Tower does not divide it by the subscription
  price or show it as credits consumed. The old `cursor.monthlyCreditsUSD` override is no
  longer used.
- A **Cursor session token expires**, and when it does the row does not vanish and does not
  read zero: its last capture ages into `unknown since <age>` after the freshness TTL,
  with `Cursor session refused (HTTP <code>)` on the row. Signing in again in Cursor
  clears it. An unauthenticated call is answered with a `307` redirect to the login page
  rather than a `401`, so `307` is treated as a refusal here.
- Cursor has two independent pools per **billing month**. Both appear by name in its row;
  ranking uses the more-used pool only when both readings are known. The mirror's
  `weeklyPct` stores that monthly maximum for compatibility, and `scoped` carries both
  named readings. Claude and Codex keep saying `7d`.
- It also rate-limits. An HTTP 429 from it is real and reachable, so after a failed refresh
  the menu-open retry backs off to 60 seconds instead of 20. A 429 shows up as
  `⚠️` in the menubar title alongside the last known number, not as a blank readout.
- Accounts show as "never captured" until you have been logged into them at least once
  while the app is installed. Two accounts sitting at "never captured" is expected until
  you log into each one.
- Only the currently active account can ever be refreshed. Inactive accounts drift (their
  windows go stale) until you next switch into them.
- Refresh failures surface in the UI, in the menubar header and on the affected account
  row, rather than being swallowed. The "last refreshed" age no longer advances when a
  refresh fails, so it always reflects the last reading that actually landed.
