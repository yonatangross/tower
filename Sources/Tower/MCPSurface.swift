import Foundation

/// The Tower MCP surface: every tool, resource and prompt in docs/mcp-surface.md,
/// implemented over the same Store, vault, refresher and readers the panel and the CLI
/// use. Reads never touch the Keychain (they hydrate the way `tower panelshot` does,
/// from the store and the disk identity hint); the seat and refresh tools do,
/// exactly as `tower status` does.
///
/// Everything that touches the machine goes through `Environment`, so the tests run
/// the whole surface against a temp store with no network and no Keychain.
struct TowerMCPService: MCPService {
    struct Environment: @unchecked Sendable {
        var store: Store
        var now: () -> Date
        /// The active login's email as last verified by a profile fetch and persisted
        /// in the store. Never `~/.claude.json`: that file is rewritten by every
        /// session, so reporting it as identity repeats a rumour. nil is honest.
        var verifiedActiveEmail: () -> String?
        var switchProfiles: () -> [String: ChromeProfileHint]
        var lanes: () -> [Provider: AgentLane.Outcome]
        var sessions: () async -> AgentSummary?
        var refresh: () async -> RefreshResult
        /// The active CLI credential, read through `security`. Seats and refresh
        /// need it; nothing else calls it.
        var activeCredential: () -> ClaudeCredential?
        var vault: ClaudeSeatVault
        var defaults: UserDefaults
        var launchAtLogin: () -> Bool
        var setLaunchAtLogin: (Bool) -> String?
        var openRouterKeyFingerprint: () -> String?
        /// The Tower binary, for the two verbs that need their own process.
        var executable: URL?
        var mirrorPath: URL
        var supportDirectory: URL
        var buildVersion: String?
        /// The machine half of "room". Defaulted so fixtures that predate it still build;
        /// tests inject a fixed reading.
        var machine: () -> MachineLoad? = { MachineLoad.sample() }

        /// `keychainCredential` is the one Keychain reader of the active login; it is a
        /// parameter so the selftest can prove a demo run never calls it.
        static func live(
            processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
            keychainCredential: @escaping () -> ClaudeCredential? = { Keychain.activeOAuth() }
        ) -> Environment {
            if let demo = DemoMode.supportDirectory(env: processEnvironment) {
                return .demo(supportDirectory: demo)
            }
            let vault = ClaudeSeatVault.shared
            return Environment(
                store: Store.shared,
                now: { Date() },
                verifiedActiveEmail: { Store.shared.verifiedActiveSeat()?.email },
                switchProfiles: { Store.shared.switchProfilesByEmail() },
                // Only the lanes the operator turned ON are read; an OFF Muse never spawns.
                lanes: {
                    AgentLane.readAll(museRunner: AgentLane.runMuseUsage,
                                      only: ProviderGate.current(defaults: TowerPreferences.shared).lanes)
                },
                sessions: { await AgentProbe.fetch() },
                refresh: { await Refresher.refreshActive() },
                activeCredential: keychainCredential,
                vault: vault,
                defaults: TowerPreferences.shared,
                launchAtLogin: { LaunchAtLogin.isEnabled },
                setLaunchAtLogin: { LaunchAtLogin.set($0) },
                openRouterKeyFingerprint: { OpenRouter.keyFingerprint() },
                // The resolved bundle (#121): started through the PATH symlink,
                // Bundle.main has no Info.plist and the build stamp read as null.
                executable: ProductIdentity.runningBundle()?.executableURL ?? Bundle.main.executableURL,
                mirrorPath: Store.defaultMirrorPath(),
                supportDirectory: Store.defaultSupportDirectory(),
                buildVersion: ProductIdentity.runningBundle()?
                    .object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        }

        /// `TOWER_DEMO=1`: everything comes from the demo store. The active credential is
        /// the store's invented one, the seat vault holds nothing, refresh never reaches
        /// the network, and the readers of this Mac's own state (lanes, sessions, Chrome
        /// profiles, the OpenRouter key, the login item, the settings domain) answer as
        /// an empty machine, so a demo can neither read nor change the real one.
        static func demo(supportDirectory dir: URL) -> Environment {
            let store = Store(dir: dir, mirror: dir.appendingPathComponent("quota-cache.json"))
            let vault = ClaudeSeatVault(
                keychain: DemoSeatKeychain(),
                lockURL: dir.appendingPathComponent(".seat-keychain.lock"),
                stateURL: dir.appendingPathComponent("seat-retention-state.plist"),
                retentionEnabled: { false },
                setRetentionEnabled: { _ in },
                mayPrompt: { false })
            return Environment(
                store: store,
                now: { Date() },
                verifiedActiveEmail: { store.verifiedActiveSeat()?.email },
                switchProfiles: { [:] },
                lanes: { [:] },
                sessions: { AgentSummary() },
                refresh: {
                    RefreshResult(
                        accounts: store.load(), activeEmail: nil,
                        outcome: .failed("demo mode: no network refresh"),
                        openRouterOutcome: .notConfigured, openRouterFoldCommitted: false)
                },
                activeCredential: { DemoMode.credential(in: dir) },
                vault: vault,
                // Its own suite, never the real settings domain: a demo config_set must not
                // change the operator's Tower. The name is not the bundle id, so it exists.
                defaults: UserDefaults(suiteName: ProductIdentity.bundleIdentifier + ".demo")!,
                launchAtLogin: { false },
                setLaunchAtLogin: { _ in "demo mode does not change the login item" },
                openRouterKeyFingerprint: { nil },
                executable: ProductIdentity.runningBundle()?.executableURL ?? Bundle.main.executableURL,
                mirrorPath: dir.appendingPathComponent("quota-cache.json"),
                supportDirectory: dir,
                buildVersion: ProductIdentity.runningBundle()?
                    .object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        }
    }

    let env: Environment

    init(env: Environment) {
        self.env = env
    }

    // MARK: MCPService identity

    var serverName: String { "tower" }
    var serverVersion: String { env.buildVersion ?? "dev" }
    var instructions: String {
        """
        Tower is the estate's account and quota instrument for Claude Code, Codex, Cursor \
        and OpenRouter. Read tools return the persisted snapshot (no network) with Tower's \
        own derivations: a window is live only when its capture is under 15 minutes old, \
        a seat is recommendable only when every ranked window is live, 95 percent used is \
        capped, and a stale row is an action (switch into it and refresh), not a wait. \
        tower_refresh polls the providers the way tower status does. Writes are refused \
        with a named error code when Tower's own preconditions fail. Resource \
        tower://quota-cache is the mirror file the hooks read; subscribe to it for changes.
        """
    }

    // MARK: Tool catalogue

    /// Verb to tool: the CLI verbs in main.swift and the tool that carries each. The
    /// surface test walks main.swift and checks this map is complete.
    static let verbToTool: [String: String] = [
        "status": "tower_status",
        "selftest": "tower_selftest",
        "rotate": "tower_rotate",
        "login-item": "tower_config_get",
        "retrust": "tower_retrust",
        "panelshot": "tower_panelshot",
        "mcp": "tower_config_get",
    ]

    static let accountRef: JSON = [
        "type": "string",
        "description": "nickname (ben), email, store key (codex:a@b) or provider:nickname",
    ]

    static let windowSchema: JSON = [
        "type": "object",
        "required": ["name", "percentUsed", "resetsAt", "didReset", "trust"],
        "properties": [
            "name": ["type": "string", "description": "5h, 7d, month, or the scoped label"],
            "percentUsed": ["type": ["number", "null"]],
            "resetsAt": ["type": ["string", "null"]],
            "didReset": ["type": "boolean"],
            "trust": ["type": "string", "enum": ["live", "stale", "unknown"]],
        ],
    ]

    static let restingSchema: JSON = [
        "type": ["object", "null"],
        "required": ["reason", "kind", "timeGated", "reopensAt"],
        "properties": [
            "reason": ["type": "string"],
            "kind": ["type": "string", "enum": ["capped", "meteredCapped", "stale", "cappedAndStale", "neverCaptured"]],
            "timeGated": ["type": "boolean"],
            "reopensAt": ["type": ["string", "null"]],
        ],
    ]

    static let accountSchema: JSON = [
        "type": "object",
        "required": [
            "id", "provider", "email", "nickname", "plan", "tier", "isActive", "windows",
            "capturedAt", "captureAgeSeconds", "lastError", "needsLogin", "worstTrust",
            "recommendable", "usedPct", "trustedUsedPct", "headroomPct",
            "trustedHeadroomPct", "roomPct", "overCap",
            "binding", "exhaustedScoped", "resting", "crossing", "notified",
            "creditBalance", "balanceUSD", "availablePct", "model",
        ],
        "properties": [
            "id": ["type": "string"],
            "provider": ["type": "string"],
            "email": ["type": "string"],
            "nickname": ["type": "string"],
            "plan": ["type": "string"],
            "tier": ["type": ["string", "null"]],
            "isActive": ["type": "boolean"],
            "windows": ["type": "array", "items": windowSchema],
            "capturedAt": ["type": ["string", "null"]],
            "captureAgeSeconds": ["type": ["number", "null"]],
            "lastError": ["type": ["string", "null"]],
            "needsLogin": ["type": "boolean"],
            "worstTrust": ["type": "string", "enum": ["live", "stale", "unknown"]],
            "recommendable": ["type": "boolean"],
            "usedPct": ["type": ["number", "null"], "description": "worst window percent used, stale readings included"],
            "trustedUsedPct": ["type": ["number", "null"], "description": "worst window percent used over live windows only"],
            "headroomPct": ["type": ["number", "null"], "description": "deprecated alias of usedPct; the name is wrong, the value is percent used"],
            "trustedHeadroomPct": ["type": ["number", "null"], "description": "deprecated alias of trustedUsedPct; the name is wrong, the value is percent used"],
            "roomPct": ["type": ["number", "null"]],
            "overCap": ["type": "boolean"],
            "binding": [
                "type": ["object", "null"],
                "required": ["limit", "percent", "resetsAt", "didReset", "usableFor"],
                "properties": [
                    "limit": ["type": "string"],
                    "percent": ["type": "number"],
                    "resetsAt": ["type": ["string", "null"]],
                    "didReset": ["type": "boolean"],
                    "usableFor": ["type": ["string", "null"]],
                ],
            ],
            "exhaustedScoped": ["type": "array", "items": ["type": "string"]],
            "resting": restingSchema,
            "crossing": ["type": ["string", "null"], "enum": ["amber", "red", .null]],
            "notified": ["type": "object"],
            "creditBalance": ["type": ["string", "null"]],
            "balanceUSD": ["type": ["number", "null"]],
            "availablePct": ["type": ["number", "null"]],
            "model": ["type": ["string", "null"], "description": "the model this seat runs, when its own files say"],
        ],
    ]

    static let machineSchema: JSON = [
        "type": ["object", "null"],
        "required": ["load1", "compressorGiB", "swapUsedGiB", "swapTotalGiB", "level", "hasRoom", "refusal", "line", "gate"],
        "properties": [
            "load1": ["type": "number"], "compressorGiB": ["type": "number"],
            "swapUsedGiB": ["type": ["number", "null"]], "swapTotalGiB": ["type": ["number", "null"]],
            "level": ["type": "string", "enum": ["green", "amber", "red"]],
            "hasRoom": ["type": "boolean"], "refusal": ["type": ["string", "null"]],
            "line": ["type": "string"],
            "gate": ["type": "object", "required": ["load1", "compressorGiB"],
                     "properties": ["load1": ["type": "number"], "compressorGiB": ["type": "number"]]],
        ],
    ]

    static let blastRadiusSchema: JSON = [
        "type": ["object", "null"],
        "required": ["nickname", "riders", "unknown", "interactive", "percentUsed", "level", "warnAt", "line", "moveFirst", "moveFirstLine"],
        "properties": [
            "nickname": ["type": "string"], "riders": ["type": "integer"], "unknown": ["type": "integer"],
            "interactive": ["type": "integer"],
            "percentUsed": ["type": ["number", "null"]],
            "level": ["type": "string", "enum": ["clear", "warn", "stopped", "unknown"]],
            "warnAt": ["type": "number"], "line": ["type": "string"],
            "moveFirstLine": ["type": ["string", "null"]],
            "moveFirst": ["type": "array", "items": [
                "type": "object", "required": ["id", "label", "busy", "accountKnown"],
                "properties": ["id": ["type": "string"], "label": ["type": "string"],
                               "busy": ["type": "boolean"], "accountKnown": ["type": "boolean"]],
            ]],
        ],
    ]

    static let noArgs: JSON = ["type": "object", "properties": [:], "additionalProperties": false]

    static func write(_ title: String, destructive: Bool, idempotent: Bool, openWorld: Bool) -> MCPToolSpec.Annotations {
        MCPToolSpec.Annotations(
            title: title, readOnlyHint: false, destructiveHint: destructive,
            idempotentHint: idempotent, openWorldHint: openWorld)
    }

    static func read(_ title: String, openWorld: Bool = false) -> MCPToolSpec.Annotations {
        var a = MCPToolSpec.Annotations.read
        a.title = title
        a.openWorldHint = openWorld
        return a
    }

    /// One TypeSafe decision model's entered credit (Jev or Clef). No live field is ever
    /// true: TypeSafe publishes no billing endpoint, so every figure was typed in.
    static func typesafeModelProperties(reenterKey: String) -> JSON {
        [
            "entered": ["type": "boolean", "description": "false until a balance was entered; the other figures are then null"],
            "balanceUSD": ["type": ["number", "null"]], "asOf": ["type": ["string", "null"]],
            "level": ["type": ["string", "null"], "description": "green, amber or red; null until entered"],
            "text": ["type": "string"], "live": ["type": "boolean"],
            "ageDays": ["type": ["number", "null"], "description": "days since the entered figure was read"],
            "stale": ["type": "boolean", "description": "true once the entered figure is over 3 days old or cannot be dated"],
            "reenter": ["type": ["string", "null"], "description": .string("how to re-enter a stale figure (tower_config_set \(reenterKey)); null while fresh")],
        ]
    }

    static let typesafeModelRequired: JSON = ["entered", "balanceUSD", "asOf", "level", "text", "live", "ageDays", "stale"]

    /// The TypeSafe group: the top-level fields stay the Jev credit they always were, so a
    /// client written before Clef existed reads the same figure, and `models` carries every
    /// decision model (Jev and Clef) under its own name.
    static let typesafeGroupSchema: JSON = {
        var properties = typesafeModelProperties(reenterKey: TypeSafe.Model.jev.balanceKey).objectValue ?? [:]
        var models: [String: JSON] = [:]
        for model in TypeSafe.Model.allCases {
            var p = typesafeModelProperties(reenterKey: model.configKey).objectValue ?? [:]
            p["model"] = ["type": "string"]
            p["name"] = ["type": "string"]
            p["vendor"] = ["type": "string", "description": "who makes the model: TypeSafe (Jev) or Cloudflare (Clef)"]
            models[model.rawValue] = ["type": "object", "required": typesafeModelRequired, "properties": .object(p)]
        }
        properties["models"] = [
            "type": "object",
            "description": "every decision model by name (jev from TypeSafe, clef from Cloudflare), each with the same fields as the Jev figures above plus its vendor",
            "required": .array(TypeSafe.Model.allCases.map { .string($0.rawValue) }),
            "properties": .object(models),
        ]
        var required = typesafeModelRequired.arrayValue ?? []
        required.append("models")
        return ["type": "object", "required": .array(required), "properties": .object(properties)]
    }()

    static let tools: [MCPToolSpec] = [
        MCPToolSpec(
            name: "tower_status", title: "Tower status",
            description: "The tower status picture from the persisted store: accounts by provider, active seat, ranked room, resting rows, the exhausted, stale and uncaptured lists, the TypeSafe entered balance and the menubar title. No network; call tower_refresh first for live numbers.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object",
                "required": ["generatedAt", "activeEmail", "activeEmailVerifiedAt", "activeNickname", "menubarTitle", "refreshError", "sections", "resting", "mostHeadroom", "exhausted", "modelLimitReached", "tooStale", "cursorStale", "notYetCaptured", "typesafe"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "activeEmail": ["type": ["string", "null"], "description": "the Tower-verified active login, or null when unverified; never the raw ~/.claude.json identity"],
                    "activeEmailVerifiedAt": ["type": ["string", "null"], "description": "when the reported active email was last proven by a profile fetch"],
                    "activeNickname": ["type": ["string", "null"]],
                    "menubarTitle": ["type": "string"],
                    "refreshError": ["type": ["string", "null"]],
                    "sections": ["type": "array", "items": [
                        "type": "object", "required": ["provider", "label", "accounts"],
                        "properties": [
                            "provider": ["type": "string"], "label": ["type": "string"],
                            "accounts": ["type": "array", "items": accountSchema],
                        ],
                    ]],
                    "resting": ["type": "array", "items": [
                        "type": "object", "required": ["id", "nickname", "provider", "resting"],
                        "properties": ["id": ["type": "string"], "nickname": ["type": "string"], "provider": ["type": "string"], "resting": restingSchema],
                    ]],
                    "mostHeadroom": ["type": ["object", "null"], "required": ["nickname", "percentUsed"],
                                     "properties": ["nickname": ["type": "string"], "percentUsed": ["type": "number"]]],
                    "exhausted": ["type": "array", "items": ["type": "string"]],
                    "modelLimitReached": ["type": "array", "items": [
                        "type": "object", "required": ["nickname", "scopes"],
                        "properties": ["nickname": ["type": "string"], "scopes": ["type": "array", "items": ["type": "string"]]],
                    ]],
                    "tooStale": ["type": "array", "items": ["type": "string"]],
                    "cursorStale": ["type": "array", "items": [
                        "type": "object", "required": ["nickname", "error"],
                        "properties": ["nickname": ["type": "string"], "error": ["type": ["string", "null"]]],
                    ]],
                    "notYetCaptured": ["type": "array", "items": ["type": "string"]],
                    "typesafe": Self.typesafeGroupSchema,
                ],
            ],
            annotations: read("Tower status")),
        MCPToolSpec(
            name: "tower_accounts", title: "All accounts",
            description: "Every account row with its persisted fields and Tower's derived fields (trust per window, room, binding quota, resting reason, reopening). Optional provider filter.",
            inputSchema: [
                "type": "object",
                "properties": ["provider": ["type": "string", "enum": .array(Provider.allCases.map { .string($0.rawValue) })]],
                "additionalProperties": false,
            ],
            outputSchema: [
                "type": "object", "required": ["generatedAt", "activeEmail", "accounts"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "activeEmail": ["type": ["string", "null"]],
                    "accounts": ["type": "array", "items": accountSchema],
                ],
            ],
            annotations: read("All accounts")),
        MCPToolSpec(
            name: "tower_account", title: "One account",
            description: "One account by nickname, email, store key or provider:nickname, with the same derived fields as tower_accounts.",
            inputSchema: ["type": "object", "required": ["account"], "properties": ["account": accountRef], "additionalProperties": false],
            outputSchema: accountSchema,
            annotations: read("One account")),
        MCPToolSpec(
            name: "tower_room", title: "Ranked room",
            description: "Which seat has room: active accounts in Tower's ranking (live first, most headroom first), then resting rows with reason and reopening, plus machine room (load1, compressor, swap against the dispatch gate's own marks). Optional provider filter and minimum room percent.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "provider": ["type": "string", "enum": .array(Provider.allCases.map { .string($0.rawValue) })],
                    "minimumRoom": ["type": "number", "minimum": 0, "maximum": 100, "description": "drop active rows with less room than this"],
                ],
                "additionalProperties": false,
            ],
            outputSchema: [
                "type": "object", "required": ["generatedAt", "activeEmail", "recommended", "active", "resting", "readySummary", "machine", "machineRoom"],
                "properties": [
                    "machine": machineSchema,
                    "machineRoom": ["type": ["boolean", "null"], "description": "false when the dispatch gate would refuse a new lane on this machine; null when load could not be read"],
                    "generatedAt": ["type": "string"],
                    "activeEmail": ["type": ["string", "null"]],
                    "recommended": ["type": ["string", "null"], "description": "nickname of the roomiest live Claude seat, or null"],
                    "readySummary": ["type": "string"],
                    "active": ["type": "array", "items": [
                        "type": "object", "required": ["id", "nickname", "provider", "roomPct", "trustedUsedPct", "trustedHeadroomPct", "capturedAt", "binding", "isActive"],
                        "properties": [
                            "id": ["type": "string"], "nickname": ["type": "string"], "provider": ["type": "string"],
                            "roomPct": ["type": ["number", "null"]], "trustedUsedPct": ["type": ["number", "null"]],
                            "trustedHeadroomPct": ["type": ["number", "null"], "description": "deprecated alias of trustedUsedPct; the value is percent used"],
                            "capturedAt": ["type": ["string", "null"]], "binding": ["type": ["object", "null"]], "isActive": ["type": "boolean"],
                        ],
                    ]],
                    "resting": ["type": "array", "items": [
                        "type": "object", "required": ["id", "nickname", "provider", "resting"],
                        "properties": ["id": ["type": "string"], "nickname": ["type": "string"], "provider": ["type": "string"], "resting": restingSchema],
                    ]],
                ],
            ],
            annotations: read("Ranked room")),
        MCPToolSpec(
            name: "tower_advice", title: "Advice",
            description: "The panel's top line: stay on the active seat, switch to a named seat via /login and a Chrome profile, all resting with the earliest reset, or activeUnknown when Tower cannot verify which seat the CLI holds (the roomiest seat is still named, with roomPct, but nothing is claimed about staying).",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "kind", "nickname", "percentUsed", "roomPct", "next", "command", "chromeProfile", "earliestReset"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "kind": ["type": "string", "enum": ["stay", "switch", "activeUnknown", "activeFiveHourUnknown", "allResting"]],
                    "nickname": ["type": ["string", "null"]],
                    "percentUsed": ["type": ["number", "null"]],
                    "roomPct": ["type": ["number", "null"], "description": "room on the named seat; set for activeUnknown, null elsewhere"],
                    "next": ["type": ["string", "null"]],
                    "command": ["type": ["string", "null"]],
                    "chromeProfile": ["type": ["object", "null"], "required": ["displayName", "chooserEmail", "label"],
                                      "properties": ["displayName": ["type": "string"], "chooserEmail": ["type": ["string", "null"]], "label": ["type": "string"]]],
                    "earliestReset": ["type": ["string", "null"]],
                ],
            ],
            annotations: read("Advice")),
        MCPToolSpec(
            name: "tower_rotate", title: "Rotate plan",
            description: "The tower rotate advisory login plan: usable Claude seats with room, age and Chrome profile, unknown seats, and the two line manual plan. Changes nothing.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "exitCode", "usable", "lines"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "exitCode": ["type": "integer"],
                    "usable": ["type": "array", "items": [
                        "type": "object", "required": ["nickname", "email", "roomPct", "capturedAt", "chromeProfile"],
                        "properties": [
                            "nickname": ["type": "string"], "email": ["type": "string"], "roomPct": ["type": ["number", "null"]],
                            "capturedAt": ["type": ["string", "null"]], "chromeProfile": ["type": ["object", "null"]],
                        ],
                    ]],
                    "lines": ["type": "array", "items": ["type": "string"]],
                ],
            ],
            annotations: read("Rotate plan")),
        MCPToolSpec(
            name: "tower_resets", title: "Resets",
            description: "Every window's reset instant per account, whether it has passed, the reopening time of capped rows, and the next instant any stored percentage expires.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "nextWindowExpiry", "accounts"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "nextWindowExpiry": ["type": ["string", "null"]],
                    "accounts": ["type": "array", "items": [
                        "type": "object", "required": ["id", "nickname", "provider", "reopensAt", "windows"],
                        "properties": [
                            "id": ["type": "string"], "nickname": ["type": "string"], "provider": ["type": "string"],
                            "reopensAt": ["type": ["string", "null"]],
                            "windows": ["type": "array", "items": [
                                "type": "object", "required": ["name", "resetsAt", "passed", "percentUsed", "secondsUntilReset"],
                                "properties": [
                                    "name": ["type": "string"], "resetsAt": ["type": ["string", "null"]], "passed": ["type": "boolean"],
                                    "percentUsed": ["type": ["number", "null"]], "secondsUntilReset": ["type": ["number", "null"]],
                                ],
                            ]],
                        ],
                    ]],
                ],
            ],
            annotations: read("Resets")),
        MCPToolSpec(
            name: "tower_alerts", title: "Alerts",
            description: "Threshold and rail state per account: announced levels per window, the alerts that would fire on the next evaluation, the standing rail crossing and the marks on each meter.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "levels", "rail", "accounts"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "levels": ["type": "array", "items": ["type": "number"]],
                    "rail": ["type": "object", "required": ["amberMark", "redMark"], "properties": ["amberMark": ["type": "number"], "redMark": ["type": "number"]]],
                    "accounts": ["type": "array", "items": [
                        "type": "object", "required": ["id", "nickname", "provider", "crossing", "railMarks", "announced", "pending"],
                        "properties": [
                            "id": ["type": "string"], "nickname": ["type": "string"], "provider": ["type": "string"],
                            "crossing": ["type": ["string", "null"]],
                            "railMarks": ["type": "object"],
                            "announced": ["type": "array", "items": [
                                "type": "object", "required": ["key", "window", "level", "expiresAt"],
                                "properties": ["key": ["type": "string"], "window": ["type": "string"], "level": ["type": "number"], "expiresAt": ["type": ["string", "null"]]],
                            ]],
                            "pending": ["type": "array", "items": [
                                "type": "object", "required": ["window", "percentUsed", "level", "resetsAt"],
                                "properties": ["window": ["type": "string"], "percentUsed": ["type": "number"], "level": ["type": "number"], "resetsAt": ["type": ["string", "null"]]],
                            ]],
                        ],
                    ]],
                ],
            ],
            annotations: read("Alerts")),
        MCPToolSpec(
            name: "tower_freshness", title: "Freshness",
            description: "Per window trust and capture age for every account, plus the freshness rules: TTLs, poll interval, debounce, and why inactive seats drift.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "rules", "accounts"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "rules": ["type": "object", "required": ["freshnessTTLSeconds", "restingStaleTTLSeconds", "pollIntervalSeconds", "openDebounceSeconds", "failureBackoffSeconds", "cappedPct", "constraint"],
                              "properties": [
                                "freshnessTTLSeconds": ["type": "number"], "restingStaleTTLSeconds": ["type": "number"],
                                "pollIntervalSeconds": ["type": "number"], "openDebounceSeconds": ["type": "number"],
                                "failureBackoffSeconds": ["type": "number"], "cappedPct": ["type": "number"],
                                "constraint": ["type": "string"],
                              ]],
                    "accounts": ["type": "array", "items": [
                        "type": "object", "required": ["id", "nickname", "provider", "capturedAt", "captureAgeSeconds", "worstTrust", "recommendable", "windows"],
                        "properties": [
                            "id": ["type": "string"], "nickname": ["type": "string"], "provider": ["type": "string"],
                            "capturedAt": ["type": ["string", "null"]], "captureAgeSeconds": ["type": ["number", "null"]],
                            "worstTrust": ["type": "string"], "recommendable": ["type": "boolean"],
                            "windows": ["type": "array", "items": windowSchema],
                        ],
                    ]],
                ],
            ],
            annotations: read("Freshness")),
        MCPToolSpec(
            name: "tower_seats", title: "Seat retention",
            description: "Seat retention state: whether retention is on, the active login, every Tower owned seat this build can read (plan, tier, expiry), and owned items it cannot read. Reads the Keychain the way tower status does; tokens never leave the process.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "retentionEnabled", "active", "retained", "unreadable"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "retentionEnabled": ["type": "boolean"],
                    "active": ["type": ["object", "null"], "required": ["email", "plan", "tier", "expiresAt", "expired"],
                               "properties": ["email": ["type": ["string", "null"]], "plan": ["type": "string"], "tier": ["type": ["string", "null"]], "expiresAt": ["type": ["string", "null"]], "expired": ["type": "boolean"]]],
                    "retained": ["type": "array", "items": [
                        "type": "object", "required": ["email", "service", "plan", "tier", "expiresAt", "expired"],
                        "properties": [
                            "email": ["type": "string"], "service": ["type": "string"], "plan": ["type": "string"], "tier": ["type": ["string", "null"]],
                            "expiresAt": ["type": ["string", "null"]], "expired": ["type": "boolean"],
                        ],
                    ]],
                    "unreadable": ["type": "array", "items": [
                        "type": "object", "required": ["service", "account", "status", "signerRefusal", "message"],
                        "properties": ["service": ["type": "string"], "account": ["type": "string"], "status": ["type": "integer"], "signerRefusal": ["type": "boolean"], "message": ["type": "string"]],
                    ]],
                ],
            ],
            annotations: read("Seat retention")),
        MCPToolSpec(
            name: "tower_lanes", title: "Agent lanes",
            description: "Muse, Devin, the Cursor CLI, Antigravity and Pi: installed or not, config model, last dispatch from the optional dispatch ledger, last limit refusal, and what the lane's own files say about its usage. Pi's usage is its spend this month and today from its session logs, with its share of the OpenRouter budget and the dollars left, or the reason there is no share. File reads only.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "lanes"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "lanes": ["type": "array", "items": [
                        "type": "object", "required": ["provider", "label", "state", "error", "headerDetail", "modelPin", "configModel", "lastDispatch", "lastLimitHit", "usage", "opusFlag"],
                        "properties": [
                            "provider": ["type": "string"], "label": ["type": "string"],
                            "state": ["type": "string", "enum": ["notConfigured", "unavailable", "ok"]],
                            "opusFlag": ["type": ["string", "null"], "description": "Cursor only: set when the metered pool refuses Opus; Auto still runs"],
                            "error": ["type": ["string", "null"]], "headerDetail": ["type": ["string", "null"]],
                            "modelPin": ["type": ["string", "null"]], "configModel": ["type": ["string", "null"]],
                            "lastDispatch": ["type": ["object", "null"]], "lastLimitHit": ["type": ["object", "null"]],
                            "usage": ["type": ["object", "null"]],
                        ],
                    ]],
                ],
            ],
            annotations: read("Agent lanes")),
        MCPToolSpec(
            name: "tower_sessions", title: "Running sessions",
            description: "Running Claude Code sessions from claude agents --json: interactive sessions busy first with repo and resolved account, grouped rows, the background count, and the blast radius (riders: sessions measured on the active login; unknown: sessions with no owner record, background rows included; the level follows the live usage when either count is above zero, warn at 85 percent, stopped at 100 percent; level unknown means no live usage reading, never unknown ownership). available=false when the probe cannot run.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "available", "interactive", "groups", "backgroundCount", "blastRadius"],
                "properties": [
                    "blastRadius": blastRadiusSchema,
                    "generatedAt": ["type": "string"],
                    "available": ["type": "boolean"],
                    "interactive": ["type": "array", "items": ["type": "object"]],
                    "groups": ["type": "array", "items": ["type": "object"]],
                    "backgroundCount": ["type": "integer"],
                ],
            ],
            annotations: read("Running sessions", openWorld: false)),
        MCPToolSpec(
            name: "tower_openrouter_history", title: "OpenRouter history",
            description: "Locally observed OpenRouter balance samples (30 day retention) and the trend Tower derives. Recorded by the app process; empty when it has not run.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "samples", "trend"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "samples": ["type": "array", "items": [
                        "type": "object", "required": ["capturedAt", "available", "spent", "totalCredits"],
                        "properties": ["capturedAt": ["type": "string"], "available": ["type": "number"], "spent": ["type": "number"], "totalCredits": ["type": "number"]],
                    ]],
                    "trend": ["type": ["object", "null"]],
                ],
            ],
            annotations: read("OpenRouter history")),
        MCPToolSpec(
            name: "tower_config_get", title: "Configuration",
            description: "Every configuration key Tower honours, the file paths, the constants (TTLs, thresholds, rail marks), the TypeSafe entered balance and product identity.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["generatedAt", "settings", "paths", "constants", "identity", "typesafe", "openrouter"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "settings": ["type": "object", "required": ["retainClaudeSeats", "launchAtLogin", "expandedSections", "knownAccounts", "retiredAccounts"],
                                 "properties": [
                                    "retainClaudeSeats": ["type": "boolean"], "launchAtLogin": ["type": "boolean"],
                                    "expandedSections": ["type": "array", "items": ["type": "string"]],
                                    "knownAccounts": ["type": "array", "items": ["type": "string"]],
                                    "retiredAccounts": ["type": "array", "items": ["type": "string"]],
                                    "watch": SettingsConfig.schema,
                                 ]],
                    "paths": ["type": "object"],
                    "constants": ["type": "object"],
                    "identity": ["type": "object", "required": ["displayName", "bundleIdentifier", "supportDirectoryName", "processName", "buildVersion", "settingsDomain"],
                                 "properties": ["displayName": ["type": "string"], "bundleIdentifier": ["type": "string"], "supportDirectoryName": ["type": "string"], "processName": ["type": "string"], "buildVersion": ["type": ["string", "null"]], "settingsDomain": ["type": "string"]]],
                    "typesafe": Self.typesafeGroupSchema,
                    "openrouter": ["type": "object", "required": ["keyConfigured", "keyFingerprint", "monthlyBudgetUSD", "lastSuccessAt"],
                                   "properties": ["keyConfigured": ["type": "boolean"], "keyFingerprint": ["type": ["string", "null"]], "monthlyBudgetUSD": ["type": ["number", "null"]], "lastSuccessAt": ["type": ["string", "null"]]]],
                ],
            ],
            annotations: read("Configuration")),
        MCPToolSpec(
            name: "tower_selftest", title: "Selftest",
            description: "Runs tower selftest (pure logic checks, no network) in a child process and returns the pass and fail counts with the failing lines.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["exitCode", "passed", "failed", "failures"],
                "properties": [
                    "exitCode": ["type": "integer"], "passed": ["type": "integer"], "failed": ["type": "integer"],
                    "failures": ["type": "array", "items": ["type": "string"]],
                ],
            ],
            annotations: read("Selftest")),
        MCPToolSpec(
            name: "tower_panelshot", title: "Panel shot",
            description: "Renders the real panel offscreen from persisted data (no credential read, no refresh) and returns the PNG as image content. light selects the light appearance; expand opens the first ready seat row.",
            inputSchema: [
                "type": "object",
                "properties": ["light": ["type": "boolean", "default": false], "expand": ["type": "boolean", "default": false]],
                "additionalProperties": false,
            ],
            outputSchema: [
                "type": "object", "required": ["width", "height", "bytes", "mimeType"],
                "properties": ["width": ["type": "integer"], "height": ["type": "integer"], "bytes": ["type": "integer"], "mimeType": ["type": "string"]],
            ],
            annotations: read("Panel shot")),
        MCPToolSpec(
            name: "tower_refresh", title: "Refresh",
            description: "One refresh cycle, the same one tower status runs: Cursor and OpenRouter probes, the Claude roster (active login plus retained seats), one locked store mutation and mirror rewrite. Threshold and rail bookkeeping is left to the app so no notification is consumed here. With account, refuses a seat Tower cannot poll (NotPollable).",
            inputSchema: ["type": "object", "properties": ["account": accountRef], "additionalProperties": false],
            outputSchema: [
                "type": "object", "required": ["generatedAt", "outcome", "error", "activeEmail", "keychainCalls", "openRouter", "cursorKey", "pendingAlerts", "accounts"],
                "properties": [
                    "generatedAt": ["type": "string"],
                    "outcome": ["type": "string", "enum": ["ok", "failed", "noCredential"]],
                    "error": ["type": ["string", "null"]],
                    "activeEmail": ["type": ["string", "null"]],
                    "keychainCalls": ["type": "integer"],
                    "openRouter": ["type": "string", "enum": ["notConfigured", "rejected", "unavailable", "ok"]],
                    "cursorKey": ["type": ["string", "null"]],
                    "pendingAlerts": ["type": "array", "items": ["type": "object"]],
                    "accounts": ["type": "array", "items": accountSchema],
                ],
            ],
            annotations: write("Refresh", destructive: false, idempotent: false, openWorld: true)),
        MCPToolSpec(
            name: "tower_retrust", title: "Re-trust remembered seats",
            description: "The panel's Re-trust: one Keychain read of the remembered Claude seats with the system dialog allowed. macOS then asks the USER to click Always Allow once per seat; this tool only opens those dialogs and never answers them. Use it after an upgrade or a new signing identity, when seats read needs login. Returns how many seats are readable and how many are still unreadable. Refused with RetrustRefused for an unsigned build or a demo store, which never show the dialog. The running app re-reads an unreadable seat by itself within a minute.",
            inputSchema: noArgs,
            outputSchema: [
                "type": "object", "required": ["readable", "unreadable"],
                "properties": ["readable": ["type": "integer"], "unreadable": ["type": "integer"]],
            ],
            annotations: write("Re-trust remembered seats", destructive: false, idempotent: false, openWorld: false)),
        MCPToolSpec(
            name: "tower_forget_seats", title: "Forget retained seats",
            description: "Deletes every Tower owned seat item and advances the observation fence so an in flight login cannot recreate one. Retention stays on. The panel's Forget button.",
            inputSchema: noArgs,
            outputSchema: ["type": "object", "required": ["forgotten"], "properties": ["forgotten": ["type": "boolean"]]],
            annotations: write("Forget retained seats", destructive: true, idempotent: true, openWorld: false)),
        MCPToolSpec(
            name: "tower_config_set", title: "Set configuration",
            description: "Sets one configuration key: retainClaudeSeats (false deletes every owned seat first), launchAtLogin, openrouter.monthlyBudgetUSD (null clears), typesafe.balanceUSD (the Jev credit balance read off the TypeSafe console, dated today; null clears it and hides the row), cloudflare.clef.balanceUSD (the same for Cloudflare's Clef decision model, read off the Cloudflare dashboard; typesafe.clef.balanceUSD is the older alias), knownAccounts, retiredAccounts. Refused with UnknownKey, BadValue, KeychainRefused or the underlying error.",
            inputSchema: [
                "type": "object", "required": ["key", "value"],
                "properties": [
                    "key": ["type": "string", "enum": .array(SettingsConfig.allConfigKeys)],
                    "value": ["description": "boolean, number or null, or an array of emails, depending on the key"],
                ],
                "additionalProperties": false,
            ],
            outputSchema: [
                "type": "object", "required": ["key", "value", "previous"],
                "properties": ["key": ["type": "string"]],
            ],
            annotations: write("Set configuration", destructive: true, idempotent: true, openWorld: false)),
        MCPToolSpec(
            name: "tower_alert_ack", title: "Acknowledge a threshold",
            description: "Records a threshold level (80, 95 or 100) as already announced for one account window, the same bookkeeping write Thresholds.evaluate performs after posting, so the app stays silent for it until the window resets. Refused with NoResetTime, BadLevel, UnknownWindow, UnknownAccount or SaveFailed.",
            inputSchema: [
                "type": "object", "required": ["account", "window", "level"],
                "properties": [
                    "account": accountRef,
                    "window": ["type": "string", "description": "5h, 7d or month"],
                    "level": ["type": "number", "enum": [80, 95, 100]],
                ],
                "additionalProperties": false,
            ],
            outputSchema: [
                "type": "object", "required": ["id", "window", "key", "level", "previous"],
                "properties": ["id": ["type": "string"], "window": ["type": "string"], "key": ["type": "string"], "level": ["type": "number"], "previous": ["type": "number"]],
            ],
            annotations: write("Acknowledge a threshold", destructive: false, idempotent: true, openWorld: false)),
    ]

    func listTools() -> [MCPToolSpec] { Self.tools }

    // MARK: Resources

    static let quotaCacheURI = "tower://quota-cache"
    static let accountURIPrefix = "tower://accounts/"
    static let configURI = "tower://config"
    static let surfaceURI = "tower://surface"

    func listResources() -> [MCPResourceSpec] {
        var out = [
            MCPResourceSpec(
                uri: Self.quotaCacheURI, name: "quota-cache", title: "Quota cache",
                description: "The mirror file the hooks read (accounts.json bytes). Subscribe for change notifications.",
                mimeType: "application/json"),
            MCPResourceSpec(
                uri: Self.configURI, name: "config", title: "Configuration",
                description: "The tower_config_get payload.", mimeType: "application/json"),
            MCPResourceSpec(
                uri: Self.surfaceURI, name: "surface", title: "Surface",
                description: "Every tool, resource and prompt this server offers, as markdown.",
                mimeType: "text/markdown"),
        ]
        let now = env.now()
        for a in visibleAccounts().values.sorted(by: { AccountSnapshot.ranked($0, $1, now: now) }) {
            out.append(MCPResourceSpec(
                uri: Self.accountURIPrefix + a.id, name: a.id,
                title: "\(a.nickname) (\(a.kind.label))",
                description: "One account row with Tower's derived fields.",
                mimeType: "application/json"))
        }
        return out
    }

    func listResourceTemplates() -> [MCPResourceTemplate] {
        [MCPResourceTemplate(
            uriTemplate: Self.accountURIPrefix + "{id}", name: "account", title: "Account",
            description: "One account by store key: the email for Claude, provider:email otherwise.",
            mimeType: "application/json")]
    }

    func readResource(_ uri: String) async throws -> [MCPResourceContent] {
        switch uri {
        case Self.quotaCacheURI:
            return [MCPResourceContent(uri: uri, mimeType: "application/json", text: quotaCacheText())]
        case Self.configURI:
            return [MCPResourceContent(uri: uri, mimeType: "application/json", text: configJSON().prettyText)]
        case Self.surfaceURI:
            return [MCPResourceContent(uri: uri, mimeType: "text/markdown", text: surfaceMarkdown())]
        default:
            guard uri.hasPrefix(Self.accountURIPrefix) else { throw MCPError.notFound("unknown resource \(uri)") }
            let id = String(uri.dropFirst(Self.accountURIPrefix.count))
            let accounts = visibleAccounts()
            guard let a = accounts[id] else { throw MCPError.notFound("no account \(id)") }
            let json = Self.accountJSON(a, activeEmail: activeEmail(accounts), now: env.now())
            return [MCPResourceContent(uri: uri, mimeType: "application/json", text: json.prettyText)]
        }
    }

    /// The mirror's bytes when it exists, else the authoritative file's, else an empty
    /// object. Both files carry identical bytes on every save, so either is the cache.
    /// Rows of providers that are OFF are dropped on the way out (b87 on #31); the file on
    /// disk stays whole, because the hooks read it. With nothing hidden the bytes go out
    /// exactly as stored.
    func quotaCacheText() -> String {
        let raw: Data
        if let data = try? Data(contentsOf: env.mirrorPath), !data.isEmpty {
            raw = data
        } else if let data = try? Data(contentsOf: env.supportDirectory.appendingPathComponent("accounts.json")),
                  !data.isEmpty {
            raw = data
        } else {
            return "{}"
        }
        let hidden = Set(env.store.load().keys).subtracting(visibleAccounts().keys)
        guard !hidden.isEmpty else { return String(decoding: raw, as: UTF8.self) }
        guard var object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            // Never hand out rows that may be OFF when the file cannot be filtered.
            return "{}"
        }
        for key in hidden { object.removeValue(forKey: key) }
        guard let filtered = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: filtered, as: UTF8.self)
    }

    func surfaceMarkdown() -> String {
        var lines = ["# Tower MCP surface", "", "Spec revision \(MCPServer.latestProtocolVersion). Server version \(serverVersion).", "", "## Tools", ""]
        for t in Self.tools {
            let kind = t.annotations.readOnlyHint ? "read" : (t.annotations.destructiveHint ? "write, destructive" : "write")
            lines.append("- `\(t.name)` (\(kind)): \(t.description)")
        }
        lines += ["", "## Resources", ""]
        lines.append("- `\(Self.quotaCacheURI)`: the mirror file, subscribable")
        lines.append("- `\(Self.accountURIPrefix){id}`: one account row")
        lines.append("- `\(Self.configURI)`: configuration")
        lines += ["", "## Prompts", ""]
        for p in Self.prompts { lines.append("- `\(p.name)`: \(p.description)") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Prompts

    static let laneClasses = ["claude", "codex", "cursor", "pi", "muse", "devin", "agy"]

    static let prompts: [MCPPromptSpec] = [
        MCPPromptSpec(
            name: "pick_account_for_lane", title: "Pick an account for a lane",
            description: "Pick a seat for a lane of class X from Tower's ranked room, under Tower's rules.",
            arguments: [
                .init(name: "lane_class", description: "claude, codex, cursor, pi, muse, devin or agy", required: true),
                .init(name: "minimum_room", description: "percent of room the lane needs, default 20", required: false),
                .init(name: "model", description: "the model the lane will pin, if known", required: false),
            ]),
        MCPPromptSpec(
            name: "promote_room_check", title: "Is there room for a promote",
            description: "Whether the active Claude seat and the fleet have room for a promote, under the quota rail rule (amber at 80 percent of 5h, red at 90 percent of 5h or 7d).",
            arguments: [
                .init(name: "expected_prompts", description: "how many prompts the promote is expected to cost, default 30", required: false),
            ]),
        MCPPromptSpec(
            name: "rotation_brief", title: "Rotation brief",
            description: "The tower rotate plan as a brief the operator can act on.",
            arguments: []),
    ]

    func listPrompts() -> [MCPPromptSpec] { Self.prompts }

    func getPrompt(_ name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        switch name {
        case "pick_account_for_lane":
            guard let laneClass = arguments["lane_class"], !laneClass.isEmpty else {
                throw MCPError.invalidParams("lane_class is required")
            }
            let minimum = Double(arguments["minimum_room"] ?? "") ?? 20
            let model = arguments["model"].flatMap { $0.isEmpty ? nil : $0 }
            let room = try await callTool("tower_room", arguments: ["minimumRoom": .number(minimum)])
            let provider: String
            switch laneClass {
            case "claude", "pi": provider = "claude"
            case "codex": provider = "codex"
            case "cursor": provider = "cursor"
            default: provider = laneClass
            }
            let text = """
            Pick one seat for a lane of class \(laneClass)\(model.map { " pinning model \($0)" } ?? "") that needs at least \(Int(minimum)) percent room.

            Tower's rules, which the numbers below already apply:
            - Only a live capture counts: a window is live when its capture is under 15 minutes old. A stale row is an action (switch into it and run tower_refresh), never a wait, and it must not be picked on its old number.
            - 95 percent used is capped. A capped seat reopens at the reset of its binding window, the later one when both are capped.
            - The Fable scope is informational: a Fable cap does not stop Opus or Sonnet. Aggregate caps do.
            - A \(laneClass) lane draws on the \(provider) provider. Codex and Cursor rows are never the answer for a Claude lane, however roomy.
            - The rail refuses new stations above amber (80 percent of the 5h meter); a rotation brief is due at 90.
            - Between seats with equal room prefer the one that is not the active login, so the operator's own session keeps its headroom.

            Answer with the seat's nickname, its room percent, the window that binds it, and the /login Chrome profile hint if a switch is needed. If nothing qualifies, say which seat reopens first and when.

            Current room (tower_room, minimumRoom \(Int(minimum))):
            \(room.structuredContent?.prettyText ?? "{}")
            """
            return MCPPromptResult(description: "Pick a seat for a \(laneClass) lane", messages: [("user", text)])
        case "promote_room_check":
            let expected = Int(arguments["expected_prompts"] ?? "") ?? 30
            let room = try await callTool("tower_room", arguments: [:])
            let alerts = try await callTool("tower_alerts", arguments: [:])
            let text = """
            Is there room for a promote of about \(expected) prompts right now?

            Judge the active Claude seat first, then the fleet:
            - The 5h meter is the binding one for a burst of prompts; the 7d meter says whether the week can absorb it.
            - The quota rail refuses a new agent lane above amber (80 percent on 5h) and calls a rotation brief due at 90 on 5h or 7d. A standing crossing of amber or red on the active seat means no.
            - A seat is usable only when every ranked window is live; a stale reading is unknown, not zero.
            - If the active seat cannot take it, name the roomiest live Claude seat and the /login profile to switch through, or the earliest reopening if all are resting.

            Answer yes or no first, then the seat, the binding window and its percent, and the risk in one line.

            tower_room:
            \(room.structuredContent?.prettyText ?? "{}")

            tower_alerts:
            \(alerts.structuredContent?.prettyText ?? "{}")
            """
            return MCPPromptResult(description: "Room for a promote", messages: [("user", text)])
        case "rotation_brief":
            let rotate = try await callTool("tower_rotate", arguments: [:])
            let text = """
            Write the rotation brief for the operator from Tower's rotate plan below. This command switches nothing: Claude Code holds one machine global credential, so the operator runs /login in the target pane and picks the named Chrome profile. State the usable seats in Tower's order, the unknown seats with their age, and the exact two line plan.

            tower_rotate:
            \(rotate.structuredContent?.prettyText ?? "{}")
            """
            return MCPPromptResult(description: "Rotation brief", messages: [("user", text)])
        default:
            throw MCPError.invalidParams("unknown prompt \(name)")
        }
    }

    func complete(refType: String, refName: String, argument: String, value: String) -> [String] {
        let lower = value.lowercased()
        func filter(_ candidates: [String]) -> [String] {
            candidates.filter { lower.isEmpty || $0.lowercased().hasPrefix(lower) }
        }
        if refType == "ref/prompt", argument == "lane_class" { return filter(Self.laneClasses) }
        if refType == "ref/resource", argument == "id" {
            return filter(visibleAccounts().keys.sorted())
        }
        return []
    }

    // MARK: Tool dispatch

    var accessEnabled: Bool { MCPAccess.isEnabled(defaults: env.defaults) }

    func callTool(_ name: String, arguments: JSON) async throws -> MCPToolResult {
        // Settings ▸ Agents: MCP off refuses every tool with one clear, structured error.
        guard MCPAccess.isEnabled(defaults: env.defaults) else {
            return .refused(MCPAccess.refusalCode, MCPAccess.refusalMessage)
        }
        switch name {
        case "tower_status": return status()
        case "tower_accounts": return accounts(provider: arguments["provider"].stringValue)
        case "tower_account":
            guard let ref = arguments["account"].stringValue else { return .refused("InvalidArguments", "account is required") }
            return account(ref)
        case "tower_room": return room(provider: arguments["provider"].stringValue, minimumRoom: arguments["minimumRoom"].doubleValue)
        case "tower_advice": return advice()
        case "tower_rotate": return rotate()
        case "tower_resets": return resets()
        case "tower_alerts": return alerts()
        case "tower_freshness": return freshness()
        case "tower_seats": return seats()
        case "tower_lanes": return lanes()
        case "tower_sessions": return await sessions()
        case "tower_openrouter_history": return openRouterHistory()
        case "tower_config_get": return .ok("configuration", configJSON())
        case "tower_selftest": return await selftest()
        case "tower_panelshot":
            return await panelshot(light: arguments["light"].boolValue ?? false, expand: arguments["expand"].boolValue ?? false)
        case "tower_refresh": return await refresh(account: arguments["account"].stringValue)
        case "tower_forget_seats": return forgetSeats()
        case "tower_retrust": return retrust()
        case "tower_config_set":
            guard let key = arguments["key"].stringValue else { return .refused("InvalidArguments", "key is required") }
            return configSet(key: key, value: arguments["value"])
        case "tower_alert_ack":
            guard let ref = arguments["account"].stringValue, let window = arguments["window"].stringValue,
                  let level = arguments["level"].doubleValue
            else { return .refused("InvalidArguments", "account, window and level are required") }
            return alertAck(ref, window: window, level: level)
        default:
            throw MCPError.invalidParams("unknown tool \(name)")
        }
    }

    // MARK: Shared shaping

    func activeEmail(_ accounts: [String: AccountSnapshot]) -> String? {
        // The BOUND record, not the raw persisted one: a record whose token no
        // longer matches the live credential is a memory of a previous login,
        // and isActive markers must not keep pointing at its seat.
        SeatCacheHydration.activeEmail(hint: boundActiveEmail(now: env.now()), accounts: Array(accounts.values))
    }

    /// The verified identity bound to the token the CLI holds right now. The
    /// persisted record counts only while its access-token digest matches the
    /// live credential, the verification is fresh, and no hint disputes it;
    /// anything less is an unknown active seat.
    func boundActiveEmail(now: Date) -> String? {
        guard let live = env.activeCredential(),
              let record = env.store.verifiedActiveSeat(),
              record.binds(to: live, now: now) else { return nil }
        return record.email
    }

    /// Resolves a reference the way a human would type it: store key, email, nickname,
    /// or provider:nickname. A bare nickname prefers the Claude row, since one email
    /// can hold a Claude and a Codex subscription (the operator's does).
    static func resolve(_ ref: String, in accounts: [String: AccountSnapshot]) -> AccountSnapshot? {
        if let exact = accounts[ref] { return exact }
        let lower = ref.lowercased()
        let rows = accounts.values.sorted { AccountSnapshot.ranked($0, $1) }
        if let byEmail = rows.first(where: { $0.email.lowercased() == lower }) { return byEmail }
        if let colon = ref.firstIndex(of: ":"),
           let provider = Provider(rawValue: String(ref[..<colon]).lowercased()) {
            let tail = String(ref[ref.index(after: colon)...]).lowercased()
            return rows.first { $0.kind == provider && ($0.nickname.lowercased() == tail || $0.email.lowercased() == tail) }
        }
        let byNick = rows.filter { $0.nickname.lowercased() == lower }
        return byNick.first { $0.kind == .claude } ?? byNick.first
    }

    static func trustName(_ t: Trust) -> String {
        switch t {
        case .live: return "live"
        case .stale: return "stale"
        case .unknown: return "unknown"
        }
    }

    static func windows(_ a: AccountSnapshot, now: Date) -> [(name: String, pct: Double?, resetsAt: Date?, trust: Trust)] {
        var out: [(String, Double?, Date?, Trust)] = []
        if a.kind.hasFiveHourWindow {
            out.append(("5h", a.fiveHourPct, a.fiveHourResetsAt, a.trustFiveHour(now: now)))
        }
        if a.kind.isRankable && a.kind != .cursor {
            out.append((a.kind.primaryWindowLabel, a.weeklyPct, a.weeklyResetsAt, a.trustWeekly(now: now)))
        }
        for s in a.scoped {
            out.append((s.label, s.percent, s.resetsAt,
                        AccountSnapshot.trust(pct: s.percent, resetsAt: s.resetsAt, capturedAt: a.capturedAt, now: now)))
        }
        return out.map { (name: $0.0, pct: $0.1, resetsAt: $0.2, trust: $0.3) }
    }

    static func windowJSON(_ w: (name: String, pct: Double?, resetsAt: Date?, trust: Trust), now: Date) -> JSON {
        let effective = AccountSnapshot.effective(pct: w.pct, resetsAt: w.resetsAt, now: now)
        return [
            "name": .string(w.name),
            "percentUsed": .number(effective.pct),
            "resetsAt": .date(w.resetsAt),
            "didReset": .bool(effective.reset),
            "trust": .string(trustName(w.trust)),
        ]
    }

    static func restingJSON(_ reason: AccountSnapshot.RestReason?, account: AccountSnapshot, now: Date) -> JSON {
        guard let reason else { return .null }
        let kind: String
        switch reason {
        case .capped: kind = "capped"
        case .meteredCapped: kind = "meteredCapped"
        case .stale: kind = "stale"
        case .cappedAndStale: kind = "cappedAndStale"
        case .neverCaptured: kind = "neverCaptured"
        }
        return [
            "reason": .string(reason.text),
            "kind": .string(kind),
            "timeGated": .bool(reason.isTimeGated),
            "reopensAt": .date(reason.isTimeGated ? AccountSnapshot.reopening(account, now: now) : nil),
        ]
    }

    /// The resting reason the panel and the CLI would show: capture trust first, then
    /// the `.either` rule, the same order `partition` applies.
    static func restingReason(_ a: AccountSnapshot, now: Date) -> AccountSnapshot.RestReason? {
        if a.kind.isRankable && !a.isRecommendable(now: now) {
            return a.capturedAt.map { .stale(max(0, now.timeIntervalSince($0))) } ?? .neverCaptured
        }
        return a.restingReason(rule: .either, now: now)
    }

    static func accountJSON(_ a: AccountSnapshot, activeEmail: String?, now: Date) -> JSON {
        let binding: JSON = a.bindingQuota(now: now).map { b in
            [
                "limit": .string(b.label(for: a.kind)),
                "percent": .number(b.percent),
                "resetsAt": .date(b.resetsAt),
                "didReset": .bool(b.didReset),
                "usableFor": .string(a.bindingUsableFor(now: now)),
            ]
        } ?? .null
        let notified = JSON.object(a.notified.mapValues { .number($0) })
        return [
            "id": .string(a.id),
            "provider": .string(a.kind.rawValue),
            "email": .string(a.email),
            "nickname": .string(a.nickname),
            "plan": .string(a.plan),
            "tier": .string(a.tier),
            "isActive": .bool(a.email == activeEmail && a.kind == .claude),
            "windows": .array(windows(a, now: now).map { windowJSON($0, now: now) }),
            "capturedAt": .date(a.capturedAt),
            "captureAgeSeconds": .number(a.capturedAt.map { max(0, now.timeIntervalSince($0)) }),
            "lastError": .string(a.lastError),
            "needsLogin": .bool(a.needsLogin),
            "worstTrust": .string(trustName(a.worstTrust(now: now))),
            "recommendable": .bool(a.isRecommendable(now: now)),
            "usedPct": .number(a.usedPct(now: now)),
            "trustedUsedPct": .number(a.trustedUsedPct(now: now)),
            // Deprecated one-release aliases: the names claimed headroom but the
            // values have always been percent used.
            "headroomPct": .number(a.usedPct(now: now)),
            "trustedHeadroomPct": .number(a.trustedUsedPct(now: now)),
            "roomPct": .number(a.roomPct(now: now)),
            "overCap": .bool(a.isOverCap(now: now)),
            "binding": binding,
            "exhaustedScoped": .array(a.exhaustedScoped(now: now).map { .string($0) }),
            "resting": restingJSON(restingReason(a, now: now), account: a, now: now),
            "crossing": .string(a.crossing),
            "notified": notified,
            "creditBalance": .string(a.creditBalance),
            "balanceUSD": .number(a.balanceUSD),
            "availablePct": .number(a.availablePct),
            "model": .string(a.model),
        ]
    }

    static func machineJSON(_ m: MachineLoad?) -> JSON {
        guard let m else { return .null }
        return [
            "load1": .number(m.load1), "compressorGiB": .number(m.compressorGiB),
            "swapUsedGiB": .number(m.swapUsedGiB), "swapTotalGiB": .number(m.swapTotalGiB),
            "level": .string(m.level.rawValue), "hasRoom": .bool(m.hasRoom),
            "refusal": .string(m.refusal), "line": .string(m.line),
            "gate": ["load1": .number(MachineLoad.gateLoad1), "compressorGiB": .number(MachineLoad.gateCompressorGiB)],
        ]
    }

    static func blastRadiusJSON(_ b: BlastRadius?) -> JSON {
        guard let b else { return .null }
        return [
            "nickname": .string(b.nickname), "riders": .int(b.riders), "unknown": .int(b.unknown),
            "interactive": .int(b.interactive),
            "percentUsed": .number(b.percentUsed), "level": .string(b.level.rawValue),
            "warnAt": .number(BlastRadius.warnMark), "line": .string(b.line),
            "moveFirstLine": .string(b.moveFirstLine),
            "moveFirst": .array(b.moveFirst.map { candidate in
                ["id": .string(candidate.id), "label": .string(candidate.label),
                 "busy": .bool(candidate.busy), "accountKnown": .bool(candidate.accountKnown)]
            }),
        ]
    }

    static func profileJSON(_ p: ChromeProfileHint?) -> JSON {
        guard let p else { return .null }
        return ["displayName": .string(p.displayName), "chooserEmail": .string(p.chooserEmail), "label": .string(p.label)]
    }

    /// `LimitsModel.title`, computed from persisted data: the active row's own error
    /// stands in for the app's last refresh error.
    static func menubarTitle(accounts: [AccountSnapshot], activeEmail: String?, refreshError: String?) -> String {
        guard let activeEmail,
              let a = accounts.first(where: { $0.email == activeEmail && $0.kind == .claude })
        else { return refreshError == nil ? "CC ??" : "CC ⚠️" }
        let pct = a.usedPct()
        let glyph = MenubarTitle.glyph(pct: pct, failing: refreshError != nil)
        guard let pct else { return glyph + a.nickname }
        return "\(glyph)\(a.nickname) \(Int(pct.rounded()))%"
    }

    /// One decision model's entered credit, the shape `typesafeModelProperties` declares.
    static func typesafeModelJSON(_ model: TypeSafe.Model, now: Date = Date(),
                                  defaults: UserDefaults = TowerPreferences.shared) -> JSON {
        let text = JSON.string(TypeSafe.statusRowText(model: model, now: now, defaults: defaults))
        guard let entry = TypeSafe.entry(model: model, defaults: defaults) else {
            return [
                "entered": false, "balanceUSD": .null, "asOf": .null, "level": .null,
                "text": text, "live": false, "ageDays": .null, "stale": false, "reenter": .null,
            ]
        }
        let level: String
        switch TypeSafe.balanceLevel(entry.usd) {
        case .green: level = "green"
        case .amber: level = "amber"
        case .red: level = "red"
        }
        return [
            "entered": true,
            "balanceUSD": .number(entry.usd),
            "asOf": .string(entry.asOf),
            "level": .string(level),
            "text": text,
            "live": false,
            "ageDays": .number(TypeSafe.balanceAgeDays(model: model, now: now, defaults: defaults).map { Double($0) }),
            "stale": .bool(TypeSafe.balanceIsStale(model: model, now: now, defaults: defaults)),
            "reenter": .string(TypeSafe.reenterHint(model: model, now: now, defaults: defaults)),
        ]
    }

    /// The TypeSafe group for `tower_status` and `tower_config_get`: the Jev figures at the
    /// top level, where they have always been, plus every model under `models`.
    static func typesafeJSON(now: Date = Date(), defaults: UserDefaults = TowerPreferences.shared) -> JSON {
        var group = typesafeModelJSON(.jev, now: now, defaults: defaults).objectValue ?? [:]
        var models: [String: JSON] = [:]
        for model in TypeSafe.Model.allCases {
            var m = typesafeModelJSON(model, now: now, defaults: defaults).objectValue ?? [:]
            m["model"] = .string(model.rawValue)
            m["name"] = .string(model.name)
            m["vendor"] = .string(model.vendor)
            models[model.rawValue] = .object(m)
        }
        group["models"] = .object(models)
        return .object(group)
    }

    // MARK: Read tools

    /// The stored rows an agent may see: only providers the operator turned ON in Settings
    /// (b88 on #26). Every MCP read goes through this, never through `env.store.load()`.
    func visibleAccounts() -> [String: AccountSnapshot] {
        env.store.load().filter { ProviderToggles.isRowVisible($0.value, defaults: env.defaults) }
    }

    func status() -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        let active = activeEmail(map)
        let all = Array(map.values)
        let sorted = all.sorted { AccountSnapshot.ranked($0, $1, now: now) }
        let split = AccountSnapshot.partition(all, rule: .either, now: now)
        let activeRow = all.first { $0.email == active && $0.kind == .claude }
        let refreshError = activeRow?.lastError

        var sections: [JSON] = []
        for provider in Provider.allCases {
            let rows = split.active.filter { $0.kind == provider }
            guard !rows.isEmpty else { continue }
            sections.append([
                "provider": .string(provider.rawValue),
                "label": .string(provider.label),
                "accounts": .array(rows.map { Self.accountJSON($0, activeEmail: active, now: now) }),
            ])
        }
        let trusted = sorted.filter { $0.kind == .claude && $0.isRecommendable(now: now) }
        let most: JSON = trusted.first.flatMap { best in
            best.trustedUsedPct(now: now).map { ["nickname": .string(best.nickname), "percentUsed": .number($0)] }
        } ?? .null
        let exhausted = trusted.filter { ($0.trustedUsedPct(now: now) ?? 0) >= 100 }
        let scopedOut = sorted.filter { !$0.exhaustedScoped(now: now).isEmpty }
        let stale = sorted.filter { $0.kind == .claude && $0.capturedAt != nil && $0.worstTrust(now: now) != .live }
        let cursorStale = sorted.filter { $0.kind == .cursor && ($0.capturedAt == nil || $0.worstTrust(now: now) != .live) }
        let uncaptured = sorted.filter { $0.capturedAt == nil }

        let payload: JSON = [
            "generatedAt": .date(now),
            "activeEmail": .string(active),
            "activeEmailVerifiedAt": .date(env.store.verifiedActiveSeat()?.verifiedAt),
            "activeNickname": .string(activeRow?.nickname),
            "menubarTitle": .string(Self.menubarTitle(accounts: all, activeEmail: active, refreshError: refreshError)),
            "refreshError": .string(refreshError),
            "sections": .array(sections),
            "resting": .array(split.resting.map { row in
                ["id": .string(row.0.id), "nickname": .string(row.0.nickname), "provider": .string(row.0.kind.rawValue),
                 "resting": Self.restingJSON(row.1, account: row.0, now: now)]
            }),
            "mostHeadroom": most,
            "exhausted": .array(exhausted.map { .string($0.nickname) }),
            "modelLimitReached": .array(scopedOut.map {
                ["nickname": .string($0.nickname), "scopes": .array($0.exhaustedScoped(now: now).map { .string($0) })]
            }),
            "tooStale": .array(stale.map { .string($0.nickname) }),
            "cursorStale": .array(cursorStale.map { ["nickname": .string($0.nickname), "error": .string($0.lastError)] }),
            "notYetCaptured": .array(uncaptured.map { .string($0.nickname) }),
            "typesafe": Self.typesafeJSON(now: now, defaults: env.defaults),
        ]
        let summary: String
        if all.isEmpty {
            summary = "no accounts captured yet"
        } else if let best = trusted.first, let pct = best.trustedUsedPct(now: now), pct < 100 {
            summary = "\(split.active.count) of \(all.filter { $0.kind.isRankable }.count) ready; most room \(best.nickname) at \(Int(pct.rounded()))% used"
        } else {
            summary = "\(split.active.count) ready; no Claude seat has a current reading with room"
        }
        return .ok(summary, payload)
    }

    func accounts(provider: String?) -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        let active = activeEmail(map)
        var rows = map.values.sorted { AccountSnapshot.ranked($0, $1, now: now) }
        if let provider {
            guard let p = Provider(rawValue: provider) else { return .refused("BadValue", "unknown provider \(provider)") }
            rows = rows.filter { $0.kind == p }
        }
        return .ok("\(rows.count) account(s)", [
            "generatedAt": .date(now),
            "activeEmail": .string(active),
            "accounts": .array(rows.map { Self.accountJSON($0, activeEmail: active, now: now) }),
        ])
    }

    func account(_ ref: String) -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        guard let a = Self.resolve(ref, in: map) else {
            return .refused("UnknownAccount", "no account matches \(ref)", extra: ["known": .array(map.keys.sorted().map { .string($0) })])
        }
        let json = Self.accountJSON(a, activeEmail: activeEmail(map), now: now)
        let room = a.roomPct(now: now).map { "\(Int($0.rounded()))% room" } ?? "room unknown"
        return .ok("\(a.nickname) (\(a.kind.label)): \(room), \(Self.trustName(a.worstTrust(now: now)))", json)
    }

    func room(provider: String?, minimumRoom: Double?) -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        let active = activeEmail(map)
        var all = Array(map.values)
        if let provider {
            guard let p = Provider(rawValue: provider) else { return .refused("BadValue", "unknown provider \(provider)") }
            all = all.filter { $0.kind == p }
        }
        // Money never competes for a seat: OpenRouter sits in `partition`'s active
        // list (it cannot rest), but it is not room, so the ranked lists here are the
        // rankable providers only.
        let rankable = all.filter { $0.kind.isRankable }
        let split = AccountSnapshot.partition(rankable, rule: .either, now: now)
        let activeRows = split.active.filter { a in
            guard let minimumRoom else { return true }
            return (a.roomPct(now: now) ?? 0) >= minimumRoom
        }
        let recommended = split.active.first { $0.kind == .claude && $0.isRecommendable(now: now) }
        // Room is seat room AND machine room: a seat with headroom is no use to a lane
        // the dispatch gate refuses for load.
        let machine = env.machine()
        let payload: JSON = [
            "machine": Self.machineJSON(machine),
            "machineRoom": machine.map { .bool($0.hasRoom) } ?? .null,
            "generatedAt": .date(now),
            "activeEmail": .string(active),
            "recommended": .string(recommended?.nickname),
            "readySummary": .string(MenuContent.readySummary(
                ready: split.active.count, total: rankable.count,
                resting: split.resting, now: now)),
            "active": .array(activeRows.map { a in
                [
                    "id": .string(a.id), "nickname": .string(a.nickname), "provider": .string(a.kind.rawValue),
                    "roomPct": .number(a.roomPct(now: now)),
                    "trustedUsedPct": .number(a.trustedUsedPct(now: now)),
                    "trustedHeadroomPct": .number(a.trustedUsedPct(now: now)),
                    "capturedAt": .date(a.capturedAt),
                    "binding": Self.accountJSON(a, activeEmail: active, now: now)["binding"],
                    "isActive": .bool(a.email == active && a.kind == .claude),
                ]
            }),
            "resting": .array(split.resting.map { row in
                ["id": .string(row.0.id), "nickname": .string(row.0.nickname), "provider": .string(row.0.kind.rawValue),
                 "resting": Self.restingJSON(row.1, account: row.0, now: now)]
            }),
        ]
        let summary = recommended.map { "\($0.nickname) has the most room (\(Int(($0.roomPct(now: now) ?? 0).rounded()))%)" }
            ?? "no Claude seat has a current reading with room"
        return .ok(summary, payload)
    }

    func advice() -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        // Advice is a decision, so it needs the bound identity: a persisted record
        // that no longer matches the live token is a stale rumour, not "known".
        let active = SeatCacheHydration.activeEmail(
            hint: boundActiveEmail(now: now), accounts: Array(map.values))
        let advice = AccountSnapshot.advise(
            activeEmail: active, accounts: Array(map.values), switchProfiles: env.switchProfiles(),
            rule: .either, now: now)
        let payload: JSON
        let summary: String
        switch advice {
        case .stay(let nick, let pct, let next):
            payload = ["kind": "stay", "nickname": .string(nick), "percentUsed": .number(pct), "roomPct": .null, "next": .string(next),
                       "command": .null, "chromeProfile": .null, "earliestReset": .null]
            summary = "stay on \(nick)" + (next.map { ", next \($0)" } ?? "")
        case .switchTo(let nick, let pct, let via):
            payload = ["kind": "switch", "nickname": .string(nick), "percentUsed": .number(pct), "roomPct": .null, "next": .null,
                       "command": .string(advice.command), "chromeProfile": Self.profileJSON(via), "earliestReset": .null]
            summary = "switch to \(nick) via /login" + (via.map { " as Chrome \($0.label)" } ?? "")
        case .activeUnknown(let nick, let room, let via):
            payload = ["kind": "activeUnknown", "nickname": .string(nick), "percentUsed": .null, "roomPct": .number(room), "next": .null,
                       "command": .string(advice.command), "chromeProfile": Self.profileJSON(via), "earliestReset": .null]
            // Same words as the panel banner; the kind stays activeUnknown for the schema.
            summary = RecommendBanner.unverifiedActiveLine(nick: nick, roomPct: room)
                + (via.map { ", /login as Chrome \($0.label)" } ?? "")
        case .activeFiveHourUnknown(let nick, let room, let next):
            payload = ["kind": "activeFiveHourUnknown", "nickname": .string(nick), "percentUsed": .null, "roomPct": .number(room),
                       "next": .string(next), "command": .null, "chromeProfile": .null, "earliestReset": .null]
            summary = RecommendBanner.fiveHourUnknownLine(nick: nick, weekRoom: room) + (next.map { ", next \($0)" } ?? "")
        case .allResting(let first):
            payload = ["kind": "allResting", "nickname": .null, "percentUsed": .null, "roomPct": .null, "next": .null,
                       "command": .null, "chromeProfile": .null, "earliestReset": .date(first)]
            summary = "no ready Claude seat" + (first.map { ", earliest reset \(JSON.iso.string(from: $0))" } ?? "")
        }
        var withTime = payload.objectValue ?? [:]
        withTime["generatedAt"] = .date(now)
        return .ok(summary, .object(withTime))
    }

    func rotate() -> MCPToolResult {
        let now = env.now()
        let profiles = env.switchProfiles()
        let report = CLI.rotateReport(accounts: Array(visibleAccounts().values), switchProfiles: profiles, now: now)
        let payload: JSON = [
            "generatedAt": .date(now),
            "exitCode": .int(Int(report.code)),
            "usable": .array(report.seats.map { s in
                ["nickname": .string(s.nickname), "email": .string(s.email), "roomPct": .number(s.roomPct(now: now)),
                 "capturedAt": .date(s.capturedAt), "chromeProfile": Self.profileJSON(profiles[s.email])]
            }),
            "lines": .array(report.lines.map { .string($0) }),
        ]
        return .ok(report.code == 0 ? "\(report.seats.count) usable seat(s)" : "no login plan", payload)
    }

    func resets() -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        let rows = map.values.sorted { AccountSnapshot.ranked($0, $1, now: now) }
        let payload: JSON = [
            "generatedAt": .date(now),
            "nextWindowExpiry": .date(AccountSnapshot.nextWindowExpiry(rows)),
            "accounts": .array(rows.map { a in
                [
                    "id": .string(a.id), "nickname": .string(a.nickname), "provider": .string(a.kind.rawValue),
                    "reopensAt": .date(AccountSnapshot.reopening(a, now: now)),
                    "windows": .array(Self.windows(a, now: now).map { w in
                        [
                            "name": .string(w.name),
                            "resetsAt": .date(w.resetsAt),
                            "passed": .bool(w.resetsAt.map { now >= $0 } ?? false),
                            "percentUsed": .number(w.pct),
                            "secondsUntilReset": .number(w.resetsAt.map { max(0, $0.timeIntervalSince(now)) }),
                        ]
                    }),
                ]
            }),
        ]
        let next = AccountSnapshot.nextWindowExpiry(rows).map { "next expiry \(JSON.iso.string(from: $0))" } ?? "no stored window is pending a reset"
        return .ok(next, payload)
    }

    func alerts() -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        let rows = map.values.sorted { AccountSnapshot.ranked($0, $1, now: now) }
        var pendingTotal = 0
        let accounts: [JSON] = rows.map { a in
            var copy = a
            let pending = Thresholds.evaluate(&copy, now: now, settings: AlertSettings.current(defaults: env.defaults))
            pendingTotal += pending.count
            var marks: [String: JSON] = [:]
            if a.kind.hasFiveHourWindow { marks["5h"] = .array(Rail.marks(fiveHour: true).compactMap { $0.level.label.map { .string($0) } }) }
            if a.kind.isRankable { marks[a.kind.primaryWindowLabel] = .array(Rail.marks(fiveHour: false).compactMap { $0.level.label.map { .string($0) } }) }
            return [
                "id": .string(a.id), "nickname": .string(a.nickname), "provider": .string(a.kind.rawValue),
                "crossing": .string(a.crossing),
                "railMarks": .object(marks),
                "announced": .array(a.notified.sorted { $0.key < $1.key }.map { key, level in
                    let window = key.split(separator: "@").first.map(String.init) ?? key
                    return ["key": .string(key), "window": .string(window), "level": .number(level),
                            "expiresAt": .date(Thresholds.expiry(ofKey: key, now: now))]
                }),
                "pending": .array(pending.map { alert in
                    ["window": .string(alert.window), "percentUsed": .number(alert.pct),
                     "level": .number(Thresholds.levels.last { alert.pct >= $0 } ?? 0),
                     "resetsAt": .date(alert.resetsAt)]
                }),
            ]
        }
        let payload: JSON = [
            "generatedAt": .date(now),
            "levels": .array(Thresholds.levels.map { .number($0) }),
            "rail": ["amberMark": .number(Rail.amberMark), "redMark": .number(Rail.redMark)],
            "accounts": .array(accounts),
        ]
        let standing = rows.filter { $0.crossing != nil }.map { "\($0.nickname) (\($0.kind.rawValue)) \($0.crossing ?? "")" }
        let summary = (standing.isEmpty ? "no standing rail crossing" : "standing: " + standing.joined(separator: ", "))
            + "; \(pendingTotal) threshold alert(s) pending"
        return .ok(summary, payload)
    }

    func freshness() -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        let rows = map.values.sorted { AccountSnapshot.ranked($0, $1, now: now) }
        let payload: JSON = [
            "generatedAt": .date(now),
            "rules": [
                "freshnessTTLSeconds": .number(AccountSnapshot.freshnessTTL),
                "restingStaleTTLSeconds": .number(AccountSnapshot.restingStaleTTL),
                "pollIntervalSeconds": 300,
                "openDebounceSeconds": 20,
                "failureBackoffSeconds": 60,
                "cappedPct": .number(AccountSnapshot.cappedPct),
                "constraint": "Claude Code keeps one usable credential at a time, so only the active login and the seats Tower retains can be polled; every other seat drifts until you switch into it. Only a successful capture renews trust; a passed reset zeroes the captured window but cannot make an old snapshot current.",
            ],
            "accounts": .array(rows.map { a in
                [
                    "id": .string(a.id), "nickname": .string(a.nickname), "provider": .string(a.kind.rawValue),
                    "capturedAt": .date(a.capturedAt),
                    "captureAgeSeconds": .number(a.capturedAt.map { max(0, now.timeIntervalSince($0)) }),
                    "worstTrust": .string(Self.trustName(a.worstTrust(now: now))),
                    "recommendable": .bool(a.isRecommendable(now: now)),
                    "windows": .array(Self.windows(a, now: now).map { Self.windowJSON($0, now: now) }),
                ]
            }),
        ]
        let live = rows.filter { $0.worstTrust(now: now) == .live }.count
        return .ok("\(live) of \(rows.count) account(s) live within \(Int(AccountSnapshot.freshnessTTL / 60)) minutes", payload)
    }

    func seats() -> MCPToolResult {
        let now = env.now()
        let active = env.activeCredential()
        let roster: ClaudeSeatRoster
        switch env.vault.rosterResult(active: active) {
        case .success(let r): roster = r
        case .failure(let error): return .refused("KeychainRefused", error.message)
        }
        let retained = roster.credentials.filter { $0.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix) }
        let payload: JSON = [
            "generatedAt": .date(now),
            "retentionEnabled": .bool(env.vault.isRetentionEnabled()),
            "active": active.map { c in
                ["email": .string(c.emailHint), "plan": .string(c.subscriptionType), "tier": .string(c.rateLimitTier),
                 "expiresAt": .date(c.expiresAt), "expired": .bool(c.isExpired(now: now))]
            } ?? .null,
            "retained": .array(retained.map { c in
                [
                    "email": .string(c.emailHint ?? ""), "service": .string(c.service),
                    "plan": .string(c.subscriptionType), "tier": .string(c.rateLimitTier),
                    "expiresAt": .date(c.expiresAt), "expired": .bool(c.isExpired(now: now)),
                ]
            }),
            "unreadable": .array(roster.unreadable.map { item in
                ["service": .string(item.service), "account": .string(item.account), "status": .int(Int(item.status)),
                 "signerRefusal": .bool(item.isSignerRefusal), "message": .string(item.panelMessage)]
            }),
        ]
        return .ok("retention \(env.vault.isRetentionEnabled() ? "on" : "off"); \(retained.count) retained seat(s), \(roster.unreadable.count) unreadable", payload)
    }

    func lanes() -> MCPToolResult {
        let now = env.now()
        let outcomes = env.lanes()
        // An agent sees only the lanes the operator turned ON, whatever the reader returned.
        let on = ProviderGate.current(defaults: env.defaults).lanes
        let lanes: [JSON] = AgentLane.lanes.filter { on.contains($0) }.map { provider in
            let outcome = outcomes[provider] ?? .notConfigured
            var row: [String: JSON] = [
                "provider": .string(provider.rawValue), "label": .string(provider.label),
                "error": .null, "headerDetail": .null, "modelPin": .null, "configModel": .null,
                "lastDispatch": .null, "lastLimitHit": .null, "usage": .null, "opusFlag": .null,
            ]
            switch outcome {
            case .notConfigured:
                row["state"] = "notConfigured"
            case .unavailable(let why):
                row["state"] = "unavailable"
                row["error"] = .string(why)
            case .ok(let r):
                row["state"] = "ok"
                // The Cursor CLI lane spends the Cursor seat, so its header carries that
                // seat's pools; the other lanes never read a seat.
                let seat = provider == .cursor
                    ? visibleAccounts().values.first { $0.kind == .cursor } : nil
                row["headerDetail"] = .string(AgentLane.headerDetail(r, cursorSeat: seat, now: now))
                row["modelPin"] = .string(r.modelPin)
                row["configModel"] = .string(r.configModel)
                if provider == .cursor {
                    // The metered pool refuses Opus while Auto keeps running; the refusal
                    // itself is never on disk, so the flag comes from the measured pool.
                    row["opusFlag"] = .string(CursorPool.laneFlag(seat, laneModel: r.modelPin, now: now))
                }
                row["lastDispatch"] = r.lastDispatch.map { ["model": .string($0.model), "at": .date($0.at)] } ?? .null
                // `current` is AgentLane.limitIsCurrent: false once the refusal is past
                // the lane's own reset or the fixed horizon, so a reader need not guess.
                row["lastLimitHit"] = r.lastLimitHit.map {
                    ["at": .date($0.at), "summary": .string($0.summary), "message": .string($0.message),
                     "current": .bool(AgentLane.limitIsCurrent(r, now: now))]
                } ?? .null
                switch r.usage {
                case .notExposed:
                    row["usage"] = ["kind": "notExposed"]
                case .notReadable(let why):
                    row["usage"] = ["kind": "notReadable", "reason": .string(why)]
                case .quota(let q):
                    row["usage"] = [
                        "kind": "quota", "plan": .string(q.plan),
                        "dailyRemainingPct": .number(q.dailyRemainingPct), "weeklyRemainingPct": .number(q.weeklyRemainingPct),
                        "dailyResetsAt": .date(q.dailyResetsAt), "weeklyResetsAt": .date(q.weeklyResetsAt),
                        "fetchedAt": .date(q.fetchedAt), "bindingRemainingPct": .number(q.bindingRemainingPct),
                    ]
                case .spend(let s):
                    // The share uses the persisted OpenRouter row, the same one the panel's
                    // MONEY band shows, so this tool never polls OpenRouter itself.
                    let share = PiLane.share(s, openRouter: OpenRouter.persistedOutcome(
                        from: Array(visibleAccounts().values), lastSuccessAt: nil))
                    var usage: [String: JSON] = [
                        "kind": "spend", "provider": .string(s.provider), "model": .string(s.model),
                        "monthUSD": .number(s.monthUSD), "todayUSD": .number(s.todayUSD),
                        "messages": .int(s.messages), "files": .int(s.files),
                        "skippedLines": .int(s.skippedLines), "partialFiles": .int(s.partialFiles),
                        "newestAt": .date(s.newest),
                        "openRouterPct": .null, "openRouterLeftUSD": .null, "openRouterLimitUSD": .null,
                        "shareReason": .null,
                    ]
                    switch share {
                    case .openRouter(let pct, let left, let limit):
                        usage["openRouterPct"] = .number(pct)
                        usage["openRouterLeftUSD"] = .number(left)
                        usage["openRouterLimitUSD"] = .number(limit)
                    case .spendOnly(let why):
                        usage["shareReason"] = .string(why)
                    }
                    row["usage"] = .object(usage)
                }
            }
            return .object(row)
        }
        let installed = lanes.filter { $0["state"] != "notConfigured" }.count
        return .ok("\(installed) of \(lanes.count) lane(s) installed", ["generatedAt": .date(now), "lanes": .array(lanes)])
    }

    func sessions() async -> MCPToolResult {
        let now = env.now()
        guard let summary = await env.sessions() else {
            return .ok("session probe unavailable", [
                "generatedAt": .date(now), "available": false, "interactive": [], "groups": [], "backgroundCount": 0,
                "blastRadius": .null,
            ])
        }
        let map = visibleAccounts()
        let activeKey = activeEmail(map)
        let blast = BlastRadius.evaluate(
            active: map.values.first { $0.email == activeKey && $0.kind == .claude },
            sessions: summary, now: now)
        let payload: JSON = [
            "generatedAt": .date(now),
            "available": true,
            "interactive": .array(summary.interactive.map { s in
                ["kind": .string(s.kind), "status": .string(s.status), "cwd": .string(s.cwd), "repo": .string(s.repoName),
                 "sessionId": .string(s.sessionId), "name": .string(s.sessionName),
                 "label": .string(s.displayName), "pid": s.pid.map { .int($0) } ?? .null,
                 "startedAt": .string(s.startedAt), "accountEmail": .string(s.accountEmail),
                 "accountEvidence": .string(s.accountEvidence), "busy": .bool(s.isBusy)]
            }),
            "groups": .array(summary.groups.map { g in
                ["label": .string(g.label), "count": .int(g.count), "busy": .bool(g.busy), "cwd": .string(g.cwd),
                 "name": .string(g.sessionName),
                 "accountEmail": .string(g.accountEmail), "accountLabel": .string(g.accountLabel),
                 "accountEvidence": .string(g.accountEvidence)]
            }),
            "backgroundCount": .int(summary.backgroundCount),
            "blastRadius": Self.blastRadiusJSON(blast),
        ]
        let busy = summary.groups.filter(\.busy).count
        return .ok("\(summary.groups.count) group(s), \(busy) busy, \(summary.backgroundCount) background", payload)
    }

    func openRouterHistory() -> MCPToolResult {
        let now = env.now()
        let samples = OpenRouter.History.load(defaults: env.defaults)
        let trend = OpenRouter.History.trend(samples)
        func sample(_ s: OpenRouter.History.Sample) -> JSON {
            ["capturedAt": .date(s.capturedAt), "available": .number(s.available), "spent": .number(s.spent), "totalCredits": .number(s.totalCredits)]
        }
        let payload: JSON = [
            "generatedAt": .date(now),
            "samples": .array(samples.map(sample)),
            "trend": trend.map { t in
                ["first": sample(t.first), "previous": sample(t.previous), "latest": sample(t.latest),
                 "minimum": .number(t.minimum), "maximum": .number(t.maximum),
                 "changeSincePrevious": .number(t.changeSincePrevious), "changeSpanSeconds": .number(t.changeSpan),
                 "observedSpanSeconds": .number(t.observedSpan), "hasMeaningfulChange": .bool(t.hasMeaningfulChange)]
            } ?? .null,
        ]
        return .ok("\(samples.count) sample(s)", payload)
    }

    func knownAccounts() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: env.store.declaredFile))) ?? []
    }

    func configJSON() -> JSON {
        let now = env.now()
        let budget = env.defaults.double(forKey: OpenRouter.budgetKey)
        let fingerprint = env.openRouterKeyFingerprint()
        return [
            "generatedAt": .date(now),
            "settings": [
                "retainClaudeSeats": .bool(env.vault.isRetentionEnabled()),
                "launchAtLogin": .bool(env.launchAtLogin()),
                "expandedSections": .array((env.defaults.stringArray(forKey: "expandedSections") ?? []).map { .string($0) }),
                "knownAccounts": .array(knownAccounts().map { .string($0) }),
                "retiredAccounts": .array(env.store.retiredEmails.sorted().map { .string($0) }),
                "watch": SettingsConfig.json(defaults: env.defaults),
            ],
            "paths": [
                "supportDirectory": .string(env.supportDirectory.path),
                "accounts": .string(env.supportDirectory.appendingPathComponent("accounts.json").path),
                "mirror": .string(env.mirrorPath.path),
                "knownAccounts": .string(env.store.declaredFile.path),
                "retiredAccounts": .string(env.store.retiredFile.path),
                "claudeConfigDir": .string(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]),
                "executable": .string(env.executable?.path),
            ],
            "constants": [
                "freshnessTTLSeconds": .number(AccountSnapshot.freshnessTTL),
                "restingStaleTTLSeconds": .number(AccountSnapshot.restingStaleTTL),
                "cappedPct": .number(AccountSnapshot.cappedPct),
                "thresholdLevels": .array(Thresholds.levels.map { .number($0) }),
                "railAmberMark": .number(Rail.amberMark),
                "railRedMark": .number(Rail.redMark),
                "seatReadRetryBackoffSeconds": .number(ClaudeSeatVault.readRetryBackoff),
                "pollIntervalSeconds": 300,
                "openDebounceSeconds": 20,
                "failureBackoffSeconds": 60,
                "openRouterHistoryRetentionDays": 30,
                "devinLogScanWindowSeconds": .number(AgentLane.logScanWindow),
            ],
            "identity": [
                "displayName": .string(ProductIdentity.displayName),
                "bundleIdentifier": .string(ProductIdentity.bundleIdentifier),
                "supportDirectoryName": .string(ProductIdentity.supportDirectoryName),
                "processName": .string(ProductIdentity.processName),
                "buildVersion": .string(env.buildVersion),
                // #121: the UserDefaults domain this process reads, the same one the panel reads.
                "settingsDomain": .string(TowerPreferences.domainName),
            ],
            "typesafe": Self.typesafeJSON(now: now, defaults: env.defaults),
            "openrouter": [
                "keyConfigured": .bool(fingerprint != nil),
                "keyFingerprint": .string(fingerprint),
                "monthlyBudgetUSD": budget > 0 ? .number(budget) : .null,
                "lastSuccessAt": .date(OpenRouter.lastSuccessTime(defaults: env.defaults)),
                "keychainService": .null,
                "keySource": .string(OpenRouter.KeySource.current(defaults: env.defaults).kind),
            ],
        ]
    }

    // MARK: Child process verbs

    struct ChildResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func runChild(_ executable: URL, _ args: [String], timeout: TimeInterval) async -> ChildResult? {
        await Task.detached(priority: .utility) { () -> ChildResult? in
            let p = Process()
            p.executableURL = executable
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); return nil }
            return ChildResult(
                status: p.terminationStatus,
                stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }.value
    }

    func selftest() async -> MCPToolResult {
        guard let exe = env.executable else { return .refused("NoExecutable", "the Tower binary path is unknown") }
        guard let result = await Self.runChild(exe, ["selftest"], timeout: 120) else {
            return .refused("ChildFailed", "tower selftest did not finish")
        }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let passed = lines.filter { $0.contains("✅") && !$0.contains("all passed") }.count
        let failures = lines.filter { $0.contains("❌") && !$0.contains(" failed") }
        let payload: JSON = [
            "exitCode": .int(Int(result.status)),
            "passed": .int(passed),
            "failed": .int(failures.count),
            "failures": .array(failures.map { .string($0.trimmingCharacters(in: .whitespaces)) }),
        ]
        return MCPToolResult(
            content: [.text(result.status == 0 ? "selftest passed (\(passed) checks)" : "selftest failed: \(failures.count) check(s)")],
            structuredContent: payload, isError: result.status != 0)
    }

    func panelshot(light: Bool, expand: Bool) async -> MCPToolResult {
        guard let exe = env.executable else { return .refused("NoExecutable", "the Tower binary path is unknown") }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-mcp-panel-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        var args = ["panelshot", out.path]
        if light { args.append("light") }
        if expand { args.append("expand") }
        guard let result = await Self.runChild(exe, args, timeout: 60), result.status == 0,
              let png = try? Data(contentsOf: out)
        else { return .refused("ChildFailed", "tower panelshot did not produce an image") }
        // "wrote /path (430x612)"
        var width = 0, height = 0
        if let open = result.stdout.lastIndex(of: "("), let close = result.stdout.lastIndex(of: ")"), open < close {
            let dims = result.stdout[result.stdout.index(after: open)..<close].split(separator: "x")
            if dims.count == 2 { width = Int(dims[0]) ?? 0; height = Int(dims[1]) ?? 0 }
        }
        return MCPToolResult(
            content: [
                .text("panel rendered \(width)x\(height), \(png.count) bytes"),
                .image(base64: png.base64EncodedString(), mimeType: "image/png"),
            ],
            structuredContent: ["width": .int(width), "height": .int(height), "bytes": .int(png.count), "mimeType": "image/png"])
    }

    // MARK: Write tools

    func refresh(account: String?) async -> MCPToolResult {
        let before = visibleAccounts()
        var wanted: AccountSnapshot?
        if let account {
            guard let a = Self.resolve(account, in: before) else {
                return .refused("UnknownAccount", "no account matches \(account)")
            }
            if a.kind == .claude {
                // Tower's rule: only the active login and a readable retained seat are
                // pollable. Everything else drifts until the operator switches into it.
                let active = env.activeCredential()
                let pollable: Set<String>
                switch env.vault.rosterResult(active: active) {
                case .success(let roster):
                    pollable = Set(roster.credentials.compactMap(\.emailHint))
                case .failure(let error):
                    return .refused("KeychainRefused", error.message)
                }
                let isActive = a.email == boundActiveEmail(now: env.now())
                guard isActive || pollable.contains(a.email) else {
                    return .refused("NotPollable", "\(a.nickname) is not the active login and Tower holds no readable token for it; run /login in Claude Code to capture it",
                                    extra: ["email": .string(a.email)])
                }
            }
            wanted = a
        }
        let start = KeychainCallCounter.shared.total
        let result = await env.refresh()
        let calls = KeychainCallCounter.shared.total - start
        let now = env.now()
        let active = result.activeEmail ?? activeEmail(result.accounts)
        var rows = result.accounts.values
            .filter { ProviderToggles.isRowVisible($0, defaults: env.defaults) }
            .sorted { AccountSnapshot.ranked($0, $1, now: now) }
        if let wanted { rows = rows.filter { $0.id == wanted.id } }
        var pending: [JSON] = []
        for a in rows {
            var copy = a
            for alert in Thresholds.evaluate(&copy, now: now, settings: AlertSettings.current(defaults: env.defaults)) {
                pending.append(["nickname": .string(alert.nickname), "window": .string(alert.window),
                                "percentUsed": .number(alert.pct), "resetsAt": .date(alert.resetsAt)])
            }
        }
        let outcome: String
        switch result.outcome {
        case .ok: outcome = "ok"
        case .failed: outcome = "failed"
        case .noCredential: outcome = "noCredential"
        }
        let openRouter: String
        switch result.openRouterOutcome {
        case .notConfigured: openRouter = "notConfigured"
        case .rejected: openRouter = "rejected"
        case .unavailable: openRouter = "unavailable"
        case .ok: openRouter = "ok"
        }
        let payload: JSON = [
            "generatedAt": .date(now),
            "outcome": .string(outcome),
            "error": .string(result.outcome.errorText),
            "activeEmail": .string(active),
            "keychainCalls": .int(calls),
            "openRouter": .string(openRouter),
            "cursorKey": .string(result.cursorKey),
            "pendingAlerts": .array(pending),
            "accounts": .array(rows.map { Self.accountJSON($0, activeEmail: active, now: now) }),
        ]
        let summary = result.outcome.isOK
            ? "refreshed; active \(active ?? "?"), \(rows.count) row(s)"
            : "refresh \(outcome): \(result.outcome.errorText ?? "")"
        return MCPToolResult(content: [.text(summary)], structuredContent: payload, isError: false)
    }

    /// The panel's Re-trust, started by an agent: one Keychain read with the system dialog
    /// allowed, so macOS asks the USER to Always Allow once per remembered seat. The tool
    /// only opens those dialogs; it never answers them. Refused when the vault may not
    /// prompt (an unsigned build, or a demo, whose vault has no real Keychain).
    func retrust() -> MCPToolResult {
        switch env.vault.retrust() {
        case .failure(let error):
            return .refused("RetrustRefused", error.message)
        case .success(let counts):
            return .ok(
                "re-trust: \(counts.readable) readable, \(counts.unreadable) still unreadable; macOS asks Always Allow once per seat",
                ["readable": .number(Double(counts.readable)), "unreadable": .number(Double(counts.unreadable))])
        }
    }

    func forgetSeats() -> MCPToolResult {
        if let error = env.vault.forgetAll(suppressing: env.activeCredential()) {
            return .refused("KeychainRefused", error)
        }
        return .ok("retained seats forgotten; retention stays \(env.vault.isRetentionEnabled() ? "on" : "off")", ["forgotten": true])
    }

    static func validEmails(_ value: JSON) -> [String]? {
        guard let list = value.arrayValue else { return nil }
        var out: [String] = []
        for item in list {
            guard let s = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), s.contains("@"),
                  !s.hasPrefix("@"), !s.hasSuffix("@") else { return nil }
            out.append(s)
        }
        return out
    }

    func configSet(key: String, value: JSON) -> MCPToolResult {
        if let result = SettingsConfig.set(key: key, value: value, defaults: env.defaults) { return result }
        switch key {
        case "retainClaudeSeats":
            guard let on = value.boolValue else { return .refused("BadValue", "retainClaudeSeats takes a boolean") }
            let previous = env.vault.isRetentionEnabled()
            if on {
                env.vault.enableRetention()
            } else if let error = env.vault.disableAndForget(suppressing: env.activeCredential()) {
                // The switch stays on after a Keychain failure, the panel's rule: a
                // successful opt out that left seats behind would be a lie.
                return .refused("KeychainRefused", error, extra: ["value": .bool(env.vault.isRetentionEnabled())])
            }
            let after = env.vault.isRetentionEnabled()
            return .ok("retainClaudeSeats \(after)", ["key": .string(key), "value": .bool(after), "previous": .bool(previous)])
        case "launchAtLogin":
            guard let on = value.boolValue else { return .refused("BadValue", "launchAtLogin takes a boolean") }
            let previous = env.launchAtLogin()
            if let error = env.setLaunchAtLogin(on) { return .refused("LoginItemFailed", error) }
            let after = env.launchAtLogin()
            return .ok("launchAtLogin \(after)", ["key": .string(key), "value": .bool(after), "previous": .bool(previous)])
        case "openrouter.monthlyBudgetUSD":
            let previous = env.defaults.double(forKey: OpenRouter.budgetKey)
            if value.isNull {
                env.defaults.removeObject(forKey: OpenRouter.budgetKey)
                return .ok("openrouter.monthlyBudgetUSD cleared", ["key": .string(key), "value": .null, "previous": previous > 0 ? .number(previous) : .null])
            }
            guard let usd = value.doubleValue, usd > 0 else { return .refused("BadValue", "openrouter.monthlyBudgetUSD takes a positive number or null") }
            env.defaults.set(usd, forKey: OpenRouter.budgetKey)
            return .ok("openrouter.monthlyBudgetUSD \(usd)", ["key": .string(key), "value": .number(usd), "previous": previous > 0 ? .number(previous) : .null])
        case _ where TypeSafe.Model.forConfigKey(key) != nil:
            // No endpoint publishes a decision model's balance, so a re-entry is the only
            // way its row stops being stale. The as-of day is the day of entry, stamped here.
            let model = TypeSafe.Model.forConfigKey(key) ?? .jev
            let previous: JSON = TypeSafe.entry(model: model, defaults: env.defaults).map { .number($0.usd) } ?? .null
            if value.isNull {
                TypeSafe.clearEntry(model: model, defaults: env.defaults)
                return .ok("\(key) cleared; the \(model.name) row is hidden until a new entry", [
                    "key": .string(key), "value": .null, "asOf": .null, "previous": previous,
                ])
            }
            guard let usd = value.doubleValue, usd >= 0, usd.isFinite else {
                return .refused("BadValue", "\(key) takes a non negative number or null")
            }
            let entry = TypeSafe.enter(usd, model: model, now: env.now(), defaults: env.defaults)
            return .ok("\(key) \(TypeSafe.money(entry.usd)) as of \(entry.asOf)", [
                "key": .string(key), "value": .number(entry.usd), "asOf": .string(entry.asOf), "previous": previous,
            ])
        case "knownAccounts":
            guard let emails = Self.validEmails(value) else { return .refused("BadValue", "knownAccounts takes an array of emails") }
            let previous = knownAccounts()
            // The same reconciliation seedDeclaredAccounts applies: retired addresses
            // never re-enter the roster through this file.
            let reconciled = emails.filter { !env.store.retiredEmails.contains($0) }
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted]
                try enc.encode(reconciled).write(to: env.store.declaredFile, options: .atomic)
            } catch {
                return .refused("SaveFailed", error.localizedDescription)
            }
            return .ok("knownAccounts: \(reconciled.count) address(es)", [
                "key": .string(key), "value": .array(reconciled.map { .string($0) }), "previous": .array(previous.map { .string($0) }),
            ])
        case "retiredAccounts":
            guard let emails = Self.validEmails(value) else { return .refused("BadValue", "retiredAccounts takes an array of emails") }
            let previous = env.store.retiredEmails.sorted()
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted]
                try enc.encode(emails).write(to: env.store.retiredFile, options: .atomic)
            } catch {
                return .refused("SaveFailed", error.localizedDescription)
            }
            return .ok("retiredAccounts: \(emails.count) address(es)", [
                "key": .string(key), "value": .array(emails.map { .string($0) }), "previous": .array(previous.map { .string($0) }),
            ])
        default:
            return .refused("UnknownKey", "no configuration key \(key)",
                            extra: ["known": .array(SettingsConfig.allConfigKeys)])
        }
    }

    func alertAck(_ ref: String, window: String, level: Double) -> MCPToolResult {
        let now = env.now()
        let map = visibleAccounts()
        guard let a = Self.resolve(ref, in: map) else { return .refused("UnknownAccount", "no account matches \(ref)") }
        guard Thresholds.levels.contains(level)
                || AlertSettings.current(defaults: env.defaults).levels(forWindow: window).contains(level) else {
            return .refused("BadLevel", "level must be one of \(Thresholds.levels.map { Int($0) })")
        }
        let resetsAt: Date?
        if window == "5h", a.kind.hasFiveHourWindow {
            resetsAt = a.fiveHourResetsAt
        } else if window == a.kind.primaryWindowLabel, a.kind.isRankable {
            resetsAt = a.weeklyResetsAt
        } else {
            let known = ([a.kind.hasFiveHourWindow ? "5h" : nil, a.kind.isRankable ? a.kind.primaryWindowLabel : nil]).compactMap { $0 }
            return .refused("UnknownWindow", "\(a.nickname) has no \(window) window", extra: ["windows": .array(known.map { .string($0) })])
        }
        // Tower's own silence rule: no reset time means no window identity to key on,
        // and a passed reset is an empty window that announces nothing.
        guard let resetsAt, resetsAt > now else {
            return .refused("NoResetTime", "\(a.nickname) \(window) has no future reset to key the acknowledgement on")
        }
        let key = Thresholds.key(window, resetsAt)
        var previous: Double = 0
        let (_, saveError) = env.store.mutate { accounts in
            guard var row = accounts[a.id] else { return }
            previous = row.notified[key] ?? 0
            row.notified[key] = max(previous, level)
            accounts[a.id] = row
        }
        if let saveError { return .refused("SaveFailed", saveError) }
        return .ok("\(a.nickname) \(window) acknowledged at \(Int(level))%", [
            "id": .string(a.id), "window": .string(window), "key": .string(key), "level": .number(max(previous, level)), "previous": .number(previous),
        ])
    }
}
