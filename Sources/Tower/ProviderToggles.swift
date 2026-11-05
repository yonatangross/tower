import Foundation

/// What the user chose to watch (approved-design/onboarding-mockup.txt, 2026-11-04):
/// one toggle per provider, pre-filled by name-only detection on the first run, and every
/// choice editable later in Settings. A provider whose toggle is off is never read.
///
/// Storage rule, chosen so an upgrade loses nothing: an unset toggle reads ON, exactly the
/// behaviour every install had before this setting existed. Only a fresh install marks the
/// first run pending (`FirstRun.resolveAtLaunch`), and while it is pending an unset toggle
/// reads OFF, so nothing is read before the user presses "Start watching".
enum WatchedProvider: String, CaseIterable, Sendable {
    case claude, codex, cursor, muse, devin, cursorCLI, antigravity, pi, openrouter, jev, clef

    /// The label a person reads in the first run and in Settings.
    var title: String {
        switch self {
        case .claude: return "Claude Code seats"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .muse: return "Muse"
        case .devin: return "Devin"
        case .cursorCLI: return "Cursor CLI"
        case .antigravity: return "Antigravity"
        case .pi: return "Pi"
        case .openrouter: return "OpenRouter"
        case .jev: return "Jev (TypeSafe)"
        case .clef: return "Clef (Cloudflare)"
        }
    }

    /// Money rows are entered by hand or keyed; the first run groups them apart.
    var isMoney: Bool { self == .openrouter || self == .jev || self == .clef }

    var defaultsKey: String { "providers.\(rawValue).enabled" }

    /// The store rows this toggle owns, so an OFF provider also leaves the panel.
    var rowProviders: Set<Provider> {
        switch self {
        case .claude: return [.claude]
        case .codex: return [.codex]
        case .cursor: return [.cursor]
        case .muse: return [.muse]
        case .devin: return [.devin]
        case .antigravity: return [.agy]
        case .pi: return [.pi]
        case .openrouter: return [.openrouter]
        case .cursorCLI, .jev, .clef: return []
        }
    }

    /// The agent lane this toggle reads, when it is one.
    var lane: Provider? {
        switch self {
        case .muse: return .muse
        case .devin: return .devin
        case .cursorCLI: return .cursor
        case .antigravity: return .agy
        case .pi: return .pi
        default: return nil
        }
    }
}

enum ProviderToggles {
    /// Set by a fresh install's first launch; cleared by "Start watching" or "Skip".
    static let setupPendingKey = "setup.pending"
    /// Set once the first run was answered either way, so it never opens again unasked.
    static let setupCompletedKey = "setup.completed"

    static func isEnabled(_ p: WatchedProvider, defaults: UserDefaults = TowerPreferences.shared) -> Bool {
        if let explicit = defaults.object(forKey: p.defaultsKey) as? Bool { return explicit }
        return !defaults.bool(forKey: setupPendingKey)
    }

    static func set(_ p: WatchedProvider, _ on: Bool, defaults: UserDefaults = TowerPreferences.shared) {
        defaults.set(on, forKey: p.defaultsKey)
    }

    /// Whether any store row of this provider may be shown. Rows with no provider are
    /// Claude seats (the store's oldest shape).
    static func isRowVisible(_ account: AccountSnapshot, defaults: UserDefaults = TowerPreferences.shared) -> Bool {
        let provider = account.provider ?? .claude
        for p in WatchedProvider.allCases where p.rowProviders.contains(provider) {
            return isEnabled(p, defaults: defaults)
        }
        return true
    }

    static func visible(_ accounts: [AccountSnapshot], defaults: UserDefaults = TowerPreferences.shared) -> [AccountSnapshot] {
        accounts.filter { isRowVisible($0, defaults: defaults) }
    }

    /// The OpenRouter money the panel may draw: nothing while OpenRouter is OFF, so a
    /// balance already on screen leaves when the toggle goes off (b90 on #41).
    static func money(orOutcome: OpenRouter.Outcome, orHistory: [OpenRouter.History.Sample],
                      defaults: UserDefaults = TowerPreferences.shared)
        -> (OpenRouter.Outcome, [OpenRouter.History.Sample]) {
        isEnabled(.openrouter, defaults: defaults) ? (orOutcome, orHistory) : (.notConfigured, [])
    }
}

extension TypeSafe.Model {
    /// The Settings toggle that governs this decision model's credit row.
    var watched: WatchedProvider {
        switch self {
        case .jev: return .jev
        case .clef: return .clef
        }
    }
}

/// The toggles frozen for one refresh, so a reader is either called or not, never half.
struct ProviderGate: Equatable, Sendable {
    var enabled: Set<WatchedProvider>

    static func current(defaults: UserDefaults = TowerPreferences.shared) -> ProviderGate {
        ProviderGate(enabled: Set(WatchedProvider.allCases.filter { ProviderToggles.isEnabled($0, defaults: defaults) }))
    }

    static let all = ProviderGate(enabled: Set(WatchedProvider.allCases))
    static let none = ProviderGate(enabled: [])

    func on(_ p: WatchedProvider) -> Bool { enabled.contains(p) }

    /// The agent lanes this gate allows a lane read for.
    var lanes: Set<Provider> {
        Set(WatchedProvider.allCases.filter { on($0) }.compactMap(\.lane))
    }
}

/// The readers one refresh may call. Injected, so a test can prove an OFF provider gets
/// zero calls; `live` is what the app and `tower_refresh` use.
struct ProviderReaders: Sendable {
    var cursor: @Sendable () async -> CursorUsage.Outcome
    var openRouter: @Sendable () async -> OpenRouter.Outcome
    var codex: @Sendable () async -> CodexReader.Reading?
    var lanes: @Sendable (Set<Provider>) async -> [Provider: AgentLane.Outcome]

    static let live = ProviderReaders(
        cursor: { await CursorUsage.fetch() },
        openRouter: { await OpenRouter.fetch() },
        codex: { await Task.detached(priority: .utility) { CodexLive.fetch() }.value },
        lanes: { allowed in
            await Task.detached(priority: .utility) {
                AgentLane.readAll(museRunner: AgentLane.runMuseUsage, only: allowed)
            }.value
        })
}

struct ProviderProbes {
    var cursor: CursorUsage.Outcome
    var openRouter: OpenRouter.Outcome
    var codex: CodexReader.Reading?
    var lanes: [Provider: AgentLane.Outcome]
}

extension ProviderReaders {
    /// Runs exactly the readers the gate allows, concurrently. An OFF provider's reader is
    /// never invoked; its slot carries the "not configured" outcome, which the store folds
    /// as "leave the row alone".
    func probe(_ gate: ProviderGate) async -> ProviderProbes {
        async let cursorOut: CursorUsage.Outcome = gate.on(.cursor) ? cursor() : .notConfigured
        async let orOut: OpenRouter.Outcome = gate.on(.openrouter) ? openRouter() : .notConfigured
        async let codexOut: CodexReader.Reading? = gate.on(.codex) ? codex() : nil
        let allowedLanes = gate.lanes
        async let laneOut: [Provider: AgentLane.Outcome] = allowedLanes.isEmpty ? [:] : lanes(allowedLanes)
        return ProviderProbes(cursor: await cursorOut, openRouter: await orOut,
                              codex: await codexOut, lanes: await laneOut)
    }
}

// MARK: - Alerts

/// The first warning level per window and whether alerts post at all. Defaults are the
/// approved mockup's: 5h 80 %, 7d 90 %, Fable 90 %, notifications on. 95 and 100 always
/// fire too, so a raised first level never hides the cap.
struct AlertSettings: Equatable, Sendable {
    var fiveHour: Double
    var weekly: Double
    var fable: Double
    var notify: Bool

    static let defaults = AlertSettings(fiveHour: 80, weekly: 90, fable: 90, notify: true)
    static let fiveHourKey = "alerts.warn.5h"
    static let weeklyKey = "alerts.warn.7d"
    static let fableKey = "alerts.warn.fable"
    static let notifyKey = "alerts.notify"
    /// A first level must sit under the fixed 95 and 100 marks.
    static let allowedWarn: ClosedRange<Double> = 50...94

    static func current(defaults store: UserDefaults = TowerPreferences.shared) -> AlertSettings {
        func level(_ key: String, _ fallback: Double) -> Double {
            guard let v = store.object(forKey: key) as? Double, allowedWarn.contains(v) else { return fallback }
            return v
        }
        return AlertSettings(
            fiveHour: level(fiveHourKey, defaults.fiveHour),
            weekly: level(weeklyKey, defaults.weekly),
            fable: level(fableKey, defaults.fable),
            notify: (store.object(forKey: notifyKey) as? Bool) ?? defaults.notify)
    }

    /// The panel's own writer (Settings ▸ Alerts and the first run). Out-of-range values
    /// are clamped into the allowed range rather than stored.
    static func write(_ key: String, _ value: Double, defaults store: UserDefaults = TowerPreferences.shared) {
        store.set(min(max(value, allowedWarn.lowerBound), allowedWarn.upperBound), forKey: key)
    }

    /// The levels announced for a window, low to high.
    func levels(forWindow window: String) -> [Double] {
        let first: Double
        switch window {
        case "5h": first = fiveHour
        case "Fable": first = fable
        default: first = weekly
        }
        return Array(Set([first, 95, 100])).sorted()
    }
}

// MARK: - MCP switch

/// MCP on or off (Settings ▸ Agents). Unset reads ON, so an upgrade keeps its agents
/// working; a fresh first run writes OFF unless the user turns it on.
enum MCPAccess {
    static let enabledKey = "mcp.enabled"
    static let refusalCode = "MCPDisabled"
    static let refusalMessage = "MCP is off in Settings: turn it on in Tower, menu ▸ Settings… ▸ Agents"

    /// Off while the first run is still pending (nothing is watched yet, so agents get
    /// nothing either). After it, an unset key reads ON, so an upgrade keeps MCP working.
    static func isEnabled(defaults: UserDefaults = TowerPreferences.shared) -> Bool {
        if defaults.bool(forKey: ProviderToggles.setupPendingKey) { return false }
        return (defaults.object(forKey: enabledKey) as? Bool) ?? true
    }
}

// MARK: - tower_config_get / tower_config_set

/// The Settings keys an agent can READ over MCP. They are the user's consent (what Tower
/// reads, whether agents may ask, whether and when it notifies), so tower_config_set
/// refuses every one of them; only the panel writes them.
enum SettingsConfig {
    static let providerKeys: [String] = WatchedProvider.allCases.map(\.defaultsKey)
    /// The refusal tower_config_set gives for a setting only the user may change.
    static let consentRefusalCode = "UserConsentRequired"
    static let keys: [String] = [MCPAccess.enabledKey, AlertSettings.fiveHourKey, AlertSettings.weeklyKey,
                                 AlertSettings.fableKey, AlertSettings.notifyKey] + providerKeys

    /// Every key tower_config_set accepts, as the schema enum lists them. The consent keys
    /// are not among them.
    static let allConfigKeys: [JSON] = ["retainClaudeSeats", "launchAtLogin", "openrouter.monthlyBudgetUSD",
                                        "typesafe.balanceUSD", "cloudflare.clef.balanceUSD", "typesafe.clef.balanceUSD",
                                        "knownAccounts", "retiredAccounts"]

    static func json(defaults: UserDefaults) -> JSON {
        let a = AlertSettings.current(defaults: defaults)
        var providers: [String: JSON] = [:]
        for p in WatchedProvider.allCases { providers[p.rawValue] = .bool(ProviderToggles.isEnabled(p, defaults: defaults)) }
        return [
            "mcpEnabled": .bool(MCPAccess.isEnabled(defaults: defaults)),
            "setupCompleted": .bool(defaults.bool(forKey: ProviderToggles.setupCompletedKey)),
            "providers": .object(providers),
            "alerts": ["warn5h": .number(a.fiveHour), "warn7d": .number(a.weekly), "warnFable": .number(a.fable), "notify": .bool(a.notify)],
        ]
    }

    static let schema: JSON = [
        "type": "object", "required": ["mcpEnabled", "setupCompleted", "providers", "alerts"],
        "properties": [
            "mcpEnabled": ["type": "boolean"], "setupCompleted": ["type": "boolean"],
            "providers": ["type": "object", "description": "one boolean per watched provider; false means Tower does not read it"],
            "alerts": ["type": "object", "required": ["warn5h", "warn7d", "warnFable", "notify"],
                       "properties": ["warn5h": ["type": "number"], "warn7d": ["type": "number"],
                                      "warnFable": ["type": "number"], "notify": ["type": "boolean"]]],
        ],
    ]

    /// nil when the key is not a consent key; the caller then tries the older keys. A
    /// consent key is refused and nothing is written.
    static func set(key: String, value: JSON, defaults: UserDefaults) -> MCPToolResult? {
        guard keys.contains(key) else { return nil }
        return .refused(consentRefusalCode, "\(key) is the user's choice: change this in Tower Settings",
                        extra: ["key": .string(key)])
    }
}
