# Tower MCP surface

`tower mcp` is a stdio MCP server built into the Tower binary. It reads the same
store, the same Keychain items and the same provider endpoints the menubar app
and the CLI use, so a lane asking over MCP gets Tower's real numbers, not a copy
that could drift. This file is the enumeration the server was built from: every
capability the current Tower has, where it lives in the source, whether it reads
or writes, and which MCP tool, resource or prompt carries it. A capability with
no mapping says why, in the same row.

Spec revision: **2026-07-28**, the current revision, and the legacy
`initialize` handshake for **2025-11-25** and earlier (a dual era server in the
spec's own words; see "Protocol revisions" and "Sources"). Transport: stdio only.
Every tool returns `structuredContent` that validates against its
`outputSchema`, plus a one-line text summary. Every write carries the tool
annotations for `readOnlyHint`, `destructiveHint`, `idempotentHint` and
`openWorldHint`, and is refused with a named error code when one of Tower's own
preconditions fails. Argument validation failures are tool errors, not protocol
errors (SEP-1303), so a model can correct itself.

Registration: point your agent's MCP config at `${HOME}/.local/bin/tower mcp`,
the installed app's symlink. Preflight: `tower mcp --self-test`.

The unit test `MCPSurfaceTests` walks the verbs in `Sources/Tower/main.swift`
and asserts that each has a tool named in this table, and that every tool the
server lists has a row here.

## Tools

| Tool | Reads or writes | Capability | Source |
|---|---|---|---|
| `tower_status` | read | The `tower status` picture from the persisted store: every account grouped by provider, the active seat as last VERIFIED by a profile fetch (`activeEmail` plus `activeEmailVerifiedAt`, null when Tower has no proof, never the `~/.claude.json` hint), ranked room, resting rows with reasons and reopening, exhausted and stale lists, the TypeSafe entered balances with their age and stale flag (`typesafe`: the Jev figures at the top level, as before, and every decision model, TypeSafe's Jev and Cloudflare's Clef, each with its `vendor`, under `typesafe.models`), the menubar title, and the refresh error. No network. | `CLI.swift:1935` (`run`), `Core.swift:532` (`ranked`), `Core.swift:673` (`partition`), `Core.swift:846` (`MenubarTitle.glyph`), `AppUI.swift:547` (`title`) |
| `tower_accounts` | read | Every account row with all persisted fields (email, nickname, plan, tier, 5h and 7d percent and reset, scoped windows such as Fable and the two Cursor pools, capturedAt, lastError, notified thresholds, standing crossing, Codex credit balance, OpenRouter balance and available percent) plus the derived fields Tower computes: trust per window, worst trust, recommendable, headroom, room, over cap, binding quota and what the seat is still usable for, resting reason, reopening time. Percent-used fields were renamed for honesty: `usedPct`/`trustedUsedPct` are percent USED; the previous `headroomPct`/`trustedHeadroomPct` keys ship as deprecated aliases for one release (same numbers, the old names said "headroom" for a used figure). | `Core.swift:235` (`AccountSnapshot`), `Core.swift:465` (`trust`), `Core.swift:355` (`bindingQuota`), `Core.swift:400` (`bindingUsableFor`), `Core.swift:641` (`restingReason`), `Core.swift:824` (`reopening`) |
| `tower_account` | read | One account by nickname, email or store key, same shape as one `tower_accounts` row. | `Core.swift:292` (`storeKey`), `Core.swift:80` (`Nickname.derive`) |
| `tower_room` | read | Ranked room over the rankable providers (Claude, Codex, Cursor; money never competes for a seat): active accounts in Tower's order (live first, most headroom first, nickname tie break) with trusted percent used, then resting rows with reason and reopening; optional provider filter and minimum room. Also carries machine room (`machine`, `machineRoom`): load1, compressor and swap against the dispatch gate's own marks, so room means seat room AND machine room. | `Core.swift` (`ranked`, `trustedUsedPct`, `partition`), `Fleet.swift` (`MachineLoad`) |
| `tower_advice` | read | The panel's top line: stay, switch, active unknown (the roomiest seat is still named with its room, but nothing is claimed about staying, for when Tower cannot verify which seat the CLI holds), or all resting, with the runner up, the `/login` command and the Chrome profile hint (display name and chooser email) for the switch. | `Core.swift:746` (`advise`), `Core.swift:1501` (`switchProfilesByEmail`) |
| `tower_rotate` | read | The `tower rotate` advisory login plan: usable Claude seats with room, snapshot age and Chrome profile, unknown seats listed separately, the two line manual plan, and the exit code the CLI would return. Changes nothing. | `CLI.swift:81` (`rotateReport`), `CLI.swift:51` (`loginPlan`) |
| `tower_resets` | read | Every window's reset instant per account (5h, 7d or month, each scoped window), whether it has already passed, the reopening time of capped rows, and the next instant any stored percentage expires. | `Core.swift:300` (`effective`), `Core.swift:419` (`nextWindowExpiry`), `Core.swift:824` (`reopening`) |
| `tower_alerts` | read | Threshold state per account and window: the levels (80, 95, 100), which level each window has already announced (the `notified` bookkeeping, key quantised to the minute), the alerts that would fire on the next evaluation, the standing rail crossing (amber at 80 on 5h, red at 90 on 5h or 7d), and the rail marks per meter. | `Core.swift:2017` (`Thresholds`), `Core.swift:2069` (`evaluate`), `Core.swift:2151` (`Rail`), `Core.swift:2210` (`Rail.evaluate`) |
| `tower_freshness` | read | Per window trust (`live`, `stale`, `unknown`), capture age, the freshness TTL (15 min), the resting stale TTL (24 h), the poll interval (300 s), the menu open debounce (20 s, 60 s after a failure), and why inactive seats drift (the one credential constraint). | `Core.swift:460` (`freshnessTTL`), `Core.swift:568` (`restingStaleTTL`), `AppUI.swift:201` (`pollInterval`), `AppUI.swift:207` (`openDebounce`), `AppUI.swift:240` (`failureBackoff`), `README.md` "Freshness" |
| `tower_seats` | read | Seat retention state: whether retention is on, every Tower owned seat item this build can read (email, service, plan, tier, expiry), owned items this build cannot read (service, account, status, whether it is a signer refusal), the active login (email, expiry, tier, plan). Tokens never leave the process. | `AccountRefresh.swift:312` (`ClaudeSeatRetention`), `AccountRefresh.swift:654` (`rosterResult`), `AccountRefresh.swift:52` (`ClaudeSeatUnreadableItem`) |
| `tower_lanes` | read | The agent lanes (Muse, Devin, Cursor CLI, Antigravity, Pi): installed or not, config model, last dispatch from the optional dispatch ledger (see the reference), last limit refusal, and the usage read (Devin's cached user status with daily and weekly remaining percent and resets; Muse's live `muse usage --json`, one bounded call, with its window and weekly percent and resets, or the reason it could not answer). The Cursor CLI lane carries `opusFlag` when the metered pool refuses Opus (Auto is unmetered and still runs); Cursor never writes that refusal to disk, so the flag comes from the measured pool. Pi's usage is `kind: "spend"`: `provider` and `model` from its settings, `monthUSD` and `todayUSD` summed from its session logs (local calendar), `messages`, `files`, `skippedLines`, `partialFiles` (non-zero means the sums are a floor), `newestAt`, and, against the persisted OpenRouter balance, `openRouterPct` (month spend over the OpenRouter limit), `openRouterLeftUSD` and `openRouterLimitUSD`, or `shareReason` when no share applies. | `PiLane.swift` (`PiLane.read`, `PiLane.share`), `Providers.swift:955` (`AgentLane`), `Providers.swift:1420` (`read`), `Providers.swift:1252` (`devinUserStatus`) |
| `tower_sessions` | read | Running Claude Code sessions from `claude agents --json`: interactive sessions busy first with repo, cwd, session name, status and resolved account, rows grouped by session id (name, then directory, for idless sessions) and labeled by the lane derived from the session name (leading emoji and ` · <branch>` tail dropped, a branch shaped head replaced by the worktree directory; the raw name stays in `name`) with counts; the account comes from the statusline's per-session reset anchor (`<config>/session-anchors/<id>`, installed by `scripts/install-statusline-anchor.sh`), else a transcript reset, else a bridge owner; background count, and `blastRadius`: `riders` (sessions measured on the active login), `unknown` (sessions with no owner record, background rows included), its live usage, and the level (warn at 85 %, stopped at 100 %), which follows the live usage whenever `riders` or `unknown` is above zero; level `unknown` means no live usage reading, never unknown ownership. Reports `unavailable` when the probe cannot run rather than an empty list. | `Jarvis.swift:187` (`AgentProbe.fetch`), `Jarvis.swift:45` (`groups`), `Jarvis.swift` (`SessionAccountResolver`, `SessionLabel`), `Fleet.swift` (`BlastRadius`) |
| `tower_openrouter_history` | read | The locally observed OpenRouter balance samples (30 day retention) and the trend Tower derives from them (change since previous, spans, meaningful change). Recorded by the app process only. | `Providers.swift:407` (`History`), `Providers.swift:471` (`trend`) |
| `tower_config_get` | read | Every configuration key Tower honours: `retainClaudeSeats`, `launchAtLogin`, `expandedSections`, `openrouter.monthlyBudgetUSD`, `openrouter.lastSuccessAt`, `typesafe.balanceUSD` and `typesafe.balanceAsOf` (Jev), `typesafe.clef.balanceUSD` and `typesafe.clef.balanceAsOf` (the storage pair for Cloudflare's Clef, set through `cloudflare.clef.balanceUSD`), OpenRouter key presence and fingerprint, `known-accounts.json`, `retired-accounts.json`, `CLAUDE_CONFIG_DIR`, the store, mirror and lock paths, the constants (TTLs, thresholds, rail marks, capped percent), the TypeSafe entered balances (the same `typesafe` object `tower_status` returns, with `models.jev` and `models.clef`), and product identity (display name, bundle id, support directory, process name, build sha). | `AccountRefresh.swift:313`, `AppUI.swift:9` (`LaunchAtLogin`), `AppUI.swift:167`, `Providers.swift:356`, `Providers.swift:524`, `Providers.swift:542`, `Core.swift:1206`, `Core.swift:907`, `Providers.swift:620`, `ProductIdentity.swift:6`, `README.md` "Configuration" |
| `tower_selftest` | read | Runs the `tower selftest` pure logic checks in a child process and returns pass and fail counts with the failing lines. | `CLI.swift:168` (`selftest`), `main.swift:20` |
| `tower_panelshot` | read | Renders the real panel offscreen from persisted data (no credential read, no refresh) and returns the PNG as image content, with `light` and `expand` options. Runs `tower panelshot` in a child process because the renderer needs the main actor and the GUI stack. | `PanelShot.swift:30` (`run`), `main.swift:47` |
| `tower_refresh` | write | One refresh cycle, the same one `tower status` runs: Cursor and OpenRouter probes, the Claude roster (active login plus every retained seat), one locked store mutation, mirror rewrite. Returns the outcome, the active email, per seat results, Keychain call count and the alerts that would announce. Threshold and rail bookkeeping is left to the app, so a notification is never lost by being consumed here. Refuses `account` when that seat is not pollable (`NotPollable`). | `Core.swift:1883` (`refreshActive`), `Core.swift:1661` (`refreshLoggedInAccount`), `AccountRefresh.swift:1119` (`collect`), `AccountRefresh.swift:145` (`KeychainCallCounter`) |
| `tower_forget_seats` | write, destructive | Deletes every Tower owned seat item, advancing the observation fence so an in flight login cannot recreate one; retention stays as it was. The panel's Forget button, which the panel never disables. Refused with `KeychainRefused` when an item will not delete. | `AppUI.swift:396` (`forgetRetainedClaudeSeats`), `AccountRefresh.swift:675` (`forgetAll`) |
| `tower_config_set` | write | Sets one configuration key: `retainClaudeSeats` (turning it off deletes every owned item first, the panel's toggle), `launchAtLogin` (`SMAppService`, the `tower login-item` verb), `openrouter.monthlyBudgetUSD` (a self imposed cap, null clears it), `typesafe.balanceUSD` (the Jev credit balance read off the TypeSafe console, dated the day it is set, null clears it and hides the row; the only fix for a stale row because TypeSafe publishes no balance endpoint), `cloudflare.clef.balanceUSD` (the same for Cloudflare's Clef decision model, read off the Cloudflare dashboard, its own row with its own as-of day; `typesafe.clef.balanceUSD` is the older alias and still works), `knownAccounts` and `retiredAccounts` (the two JSON files, reconciled the way Tower reconciles them). Refused with `UnknownKey`, `BadValue`, or the underlying error text. | `AppUI.swift:373` (`toggleClaudeSeatRetention`), `AccountRefresh.swift:506` (`disableAndForget`), `AppUI.swift:12` (`LaunchAtLogin.set`), `Providers.swift:514` (`monthlyBudget`), `Core.swift:1308` (`seedDeclaredAccounts`), `Core.swift:1227` (`retiredEmails`) |
| `tower_alert_ack` | write | Records a threshold level as already announced for one account window, the same `notified` write `Thresholds.evaluate` performs after posting, so the app will not announce it again until the window resets. Refused with `NoResetTime` when the window has no reset to key on (Tower's own silence rule), `BadLevel` outside 80, 95, 100, `UnknownWindow`, `UnknownAccount`. | `Core.swift:2030` (`key`), `Core.swift:2073` (`check`), `Core.swift:2096` (pruning) |

## Resources

| URI | Capability | Source |
|---|---|---|
| `tower://quota-cache` | The mirror file `$CLAUDE_CONFIG_DIR/quota-cache.json` (default `~/.claude/quota-cache.json`), byte identical to `accounts.json`, the file the eleven hooks read. Subscribable in both eras (`resources/subscribe` on a legacy session, `subscriptions/listen` with `resourceSubscriptions` on a modern one): the server watches the directory and sends `notifications/resources/updated` when the bytes change. | `Core.swift:1051` (`writeMirror`), `Core.swift:907` (mirror path) |
| `tower://accounts/{id}` | One account row by store key (`email` for Claude, `provider:email` otherwise), as JSON, the same derived shape as `tower_account`. Listed per row; `notifications/resources/list_changed` when rows appear or disappear; subscribable per row. | `Core.swift:292` (`storeKey`) |
| `tower://config` | The `tower_config_get` payload as JSON. | as `tower_config_get` |
| `tower://surface` | This document. | `docs/mcp-surface.md` |

## Prompts

| Prompt | Arguments | Capability |
|---|---|---|
| `pick_account_for_lane` | `lane_class` (claude, codex, cursor, pi, muse, devin, agy), `minimum_room` (percent, default 20), `model` (optional) | Asks the client to pick a seat for a lane of that class from Tower's ranked room, with Tower's rules stated: only live captures count, capped is 95, the Fable scope is informational, Codex is never advised for a Claude lane, a stale row is an action (switch and refresh) not a wait. Embeds the current `tower_room` result. |
| `promote_room_check` | `expected_prompts` (integer, default 30) | Asks whether there is room for a promote on the active Claude seat and the fleet, using the rail rule the floor enforces (no new stations above amber at 80, rotation brief due at 90), the 5h window as the binding meter, and the earliest reopening. Embeds `tower_room` and `tower_alerts`. |
| `rotation_brief` | none | The `tower rotate` plan as a brief the operator can act on. Embeds `tower_rotate`. |

## Left unmapped, with the reason

| Capability | Source | Why |
|---|---|---|
| Panel show, hide, toggle, hotkey (cmd+period, Esc) | `Hotkey.swift:24`, `AppUI.swift:1909` | The server is a separate process with no IPC to the running app; `tower_panelshot` renders the same panel offscreen instead. |
| Native notifications (threshold toasts, rail toasts, rail withdrawals) | `AppUI.swift:28` (`Notifier`) | `UNUserNotificationCenter` needs the app bundle's main run loop; the CLI never posts (`Core.swift:2068` keeps `evaluate` free of it on purpose). `tower_alerts` returns the same alerts as data; the app posts them on its next poll. |
| Copy `/login` to the clipboard | `AppUI.swift:928`, `AppUI.swift:1753` | A clipboard write from a lane process is not useful; `tower_advice` returns the command and the profile as fields. |
| Section disclosure state (`expandedSections`) | `AppUI.swift:154` | Read through `tower_config_get`; writing it from outside the app changes a panel the writer cannot see. |
| Login watch (5 s poll of the Keychain and `~/.claude.json`) | `AppUI.swift:272` | Process local timer; `tower_refresh` captures a fresh login on demand. |
| Expiry sweep (rewrite the store the second a window resets) | `AppUI.swift:516` | Process local timer; every read here applies the same reset arithmetic (`effective`) at read time, so a passed reset already reads as 0. |
| Quit | `AppUI.swift:1812` | No IPC to the app. |
| Unified log lines (categories `retention`, `keychain`, `hotkey`) | `AccountRefresh.swift:493` | Written by Tower, read with `log show --predicate 'subsystem == "ai.yonyon.tower"'`, which any lane can run; not a Tower read. |
| Install, update, build scripts | `scripts/` | Shell scripts around the artifact, not app behaviour; the installed build sha is in `tower_config_get`. |
| Brand marks and board layout | `DenseOpsUI.swift` | Rendering; `tower_panelshot` carries it. |

## Error codes

Every refused write returns an MCP tool error (`isError: true`) whose text starts
with the code, and `structuredContent.error.code` carries it:

`InvalidArguments`, `NotPollable`, `UnknownKey`, `BadValue`, `NoResetTime`, `BadLevel`,
`UnknownWindow`, `UnknownAccount`, `KeychainRefused`, `LoginItemFailed`,
`SaveFailed`, `NoExecutable`,
`ChildFailed`.

## Protocol revisions

The server selects its behaviour from how the client opens, as the 2026-07-28
"Versioning and Compatibility" page prescribes for a dual era server:

| Client opens with | Era | What the server does |
|---|---|---|
| any request carrying `_meta["io.modelcontextprotocol/protocolVersion"]` | modern, `2026-07-28` | Stateless. `server/discover` answers `supportedVersions`, capabilities and identity. Every result carries `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`. `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read` and `server/discover` carry `ttlMs` and `cacheScope: "private"`. `subscriptions/listen` opens a stream: `notifications/subscriptions/acknowledged` first, every notification tagged with `io.modelcontextprotocol/subscriptionId`, `notifications/cancelled` ends it silently, and a graceful closure response is sent when stdin closes. An unsupported version is `-32022` with `data.supported`; a request without `clientCapabilities` is `-32602`; an unknown resource is `-32602`; `ping`, `logging/setLevel` and `resources/subscribe` are `-32601`. |
| `initialize` | legacy, `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` | The handshake: the client's version is echoed when it is one of these, otherwise `2025-11-25` is offered. `ping`, `logging/setLevel` (gating `notifications/message`), `resources/subscribe` and `resources/unsubscribe`, `notifications/resources/list_changed`; an unknown resource is `-32002`. |

Measured 2026-09-22: Claude Code 2.1.278 opens with `initialize` at
`protocolVersion` `2025-11-25` (client `claude-code`, capabilities `roots` and
`elicitation`), then `notifications/initialized` and `tools/list`. It is served
on the legacy path; the modern path is ready for the client that moves.

### Why the official Swift SDK is not linked

The spec brief asked for the newest revision the Swift SDK supports: the SDK
(modelcontextprotocol/swift-sdk, latest tag 0.12.1, published 2026-05-07, read
2026-09-22) states in its README that it implements **2025-11-25**, one
revision behind the current 2026-07-28; this server serves 2025-11-25 on its
legacy path and 2026-07-28 on its modern one, so it is not held back by that.
The SDK has the types this server needs (`Tool.outputSchema`, `CallTool.Result.structuredContent`,
`Tool.Annotations`, `ResourceSubscribe`, image content), and its wire shapes are
mirrored here by name so a later swap is a rename. It is not linked because at
0.12.1 its `Package.swift` (swift-tools-version 6.1) pulls `swift-nio` 2.65 and an
unpinned `branch: "main"` of `swift-docc-plugin` into a package that has zero
dependencies today, which the repo's pin drift gate exists to refuse, and because
the CLT only shim runner (docs/decisions/2026-09-18) links Tower's sources with
bare `swiftc` and cannot resolve SPM dependencies. The protocol layer is one
file, `Sources/Tower/MCPProtocol.swift`, and it is the part the SDK would
replace.

## Lane wiring

Each agent reads its MCP servers from its own config file:

| Engine | File | Entry |
|---|---|---|
| Claude Code, pi | `<repo>/.mcp.json` (project) | as above |
| Codex CLI | `~/.codex/config.toml` | `[mcp_servers.tower]` `command = "/Users/<you>/.local/bin/tower"` `args = ["mcp"]` |
| Cursor | `~/.cursor/mcp.json` or `<repo>/.cursor/mcp.json` | `{"mcpServers": {"tower": {"command": "/Users/<you>/.local/bin/tower", "args": ["mcp"]}}}` |
| muse | `~/.config/muse/settings.json` `mcp_servers` | the same stdio shape |

Codex and Cursor do not expand `${HOME}`, so their entries carry the absolute
path.

## Sources

Read on 2026-09-22 unless stated. Dates are when the page was read, not when it
was published.

- MCP specification, versioning page: the current revision is `2026-07-28`; revisions `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25` are listed as earlier. https://modelcontextprotocol.io/specification/versioning
- 2026-07-28 changelog: stateless protocol, `server/discover`, `_meta` protocol fields, `subscriptions/listen` replacing `resources/subscribe`, `resultType`, `ttlMs` and `cacheScope`, resource not found `-32602`, error code policy (`-32020` to `-32099` reserved, `UnsupportedProtocolVersion` `-32022`), removal of `ping` and `logging/setLevel`, JSON Schema 2020-12 as the default dialect, logging and roots and sampling deprecated. https://modelcontextprotocol.io/specification/2026-07-28/changelog
- 2026-07-28 "Versioning and Compatibility": the dual era server model, the stdio probe with `server/discover`, the compatibility matrix. https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
- 2026-07-28 stdio transport: newline delimited messages, stderr free for logging, shutdown by closing stdin, backward compatibility probe. https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
- 2026-07-28 subscriptions: `subscriptions/listen`, the acknowledgement, `io.modelcontextprotocol/subscriptionId`, cancellation, graceful closure. https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions
- 2026-07-28 `server/discover`: `DiscoverResult` shape. https://modelcontextprotocol.io/specification/2026-07-28/server/discover
- 2026-07-28 base protocol: `_meta` reserved keys and the required per request fields, `resultType`, error codes. https://modelcontextprotocol.io/specification/2026-07-28/basic
- 2025-11-25 changelog: SEP-1303 (input validation errors as tool errors), icons, JSON Schema 2020-12, tool name guidance. https://modelcontextprotocol.io/specification/2025-11-25/changelog
- 2025-06-18 tools page (via context7, `/websites/modelcontextprotocol_io_specification_2025-06-18`): `outputSchema`, `structuredContent`, annotations `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint` and their defaults, image content `{type: image, data, mimeType}`.
- Swift SDK types (via context7, `/modelcontextprotocol/swift-sdk`): `Tool`, `Tool.Annotations`, `CallTool.Result`, `ResourceSubscribe`, `StdioTransport`. Package manifest, tags and README read from GitHub at tag 0.12.1: "implements both client and server components according to the 2025-11-25 (latest) version"; dependencies as stated above. https://github.com/modelcontextprotocol/swift-sdk
- Codex CLI and Cursor registration shapes: from a web research pass (tavily and web search summaries, not a primary page read), so the "Lane wiring" rows for those two engines are to be confirmed against the vendor docs when those lanes are wired; Codex may spell the environment map `env_vars`.
- Claude Code project `.mcp.json` shape and `claude mcp add <name> -- <command> <args>`: exercised live against Claude Code 2.1.278 (`claude mcp add`, `claude mcp list`, one headless `claude -p --mcp-config` call through `hq-headless.sh --sample 1`), output in the PR body.
