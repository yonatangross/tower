import AppKit
import Foundation
import SwiftUI

// First run and Settings (approved-design/onboarding-mockup.txt, approved 2026-11-04):
// the user chooses what Tower watches. Detection only pre-fills the toggles, and nothing
// is read until a toggle is on.

/// The only thing detection may ask the file system: does a path exist. There is no read
/// call on this type on purpose, so detection cannot open a token file, a Keychain item or
/// the network even by mistake. Tests inject a recorder and inspect every path asked.
protocol PathProbe {
    func exists(_ path: String) -> Bool
}

struct LivePathProbe: PathProbe {
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

/// What the first run says it found. "found" means installed, never "read".
struct Detection: Equatable {
    var found: Set<WatchedProvider>
    /// Claude seats already in Tower's own store (the store is Tower's file, not a token).
    var claudeSeats: Int

    func note(_ p: WatchedProvider) -> String {
        switch p {
        case .claude where claudeSeats > 0:
            return "\(claudeSeats) account\(claudeSeats == 1 ? "" : "s") signed in"
        case .cursor where found.contains(.cursor):
            return "needs Connect Cursor"
        case .openrouter, .jev, .clef:
            return "entered by hand"
        default:
            return ""
        }
    }
}

enum ProviderDetection {
    /// The paths each provider is recognised by: an app bundle, a CLI binary, or a folder
    /// the tool creates. Names only; nothing under them is opened.
    static func paths(_ p: WatchedProvider, home: String) -> [String] {
        switch p {
        case .claude: return ["\(home)/.claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex: return ["\(home)/.codex", "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        case .cursor: return ["/Applications/Cursor.app", "\(home)/Applications/Cursor.app"]
        case .muse: return ["\(home)/.local/bin/muse", "\(home)/.config/muse"]
        case .devin: return ["\(home)/.local/bin/devin", "\(home)/.cache/devin/cli"]
        case .cursorCLI: return ["\(home)/.local/bin/cursor-agent", "\(home)/.cursor/cli-config.json"]
        case .antigravity: return ["\(home)/.local/bin/agy", "/Applications/Antigravity.app"]
        case .pi: return ["\(home)/.local/bin/pi", "\(home)/.pi/agent"]
        // Money is keyed or entered by hand, so it is never pre-filled on.
        case .openrouter, .jev, .clef: return []
        }
    }

    static func detect(probe: PathProbe = LivePathProbe(),
                       home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                       claudeSeats: () -> Int) -> Detection {
        var found = Set<WatchedProvider>()
        for p in WatchedProvider.allCases where paths(p, home: home).contains(where: probe.exists) {
            found.insert(p)
        }
        let seats = claudeSeats()
        if seats > 0 { found.insert(.claude) }
        return Detection(found: found, claudeSeats: seats)
    }

    /// Claude rows in Tower's store. The store is Tower's own JSON; no token is in it.
    static func claudeSeatCount(store: Store = .shared) -> Int {
        store.load().values.filter { ($0.provider ?? .claude) == .claude }.count
    }
}

/// The choices the first run asks for, pre-filled from detection.
struct SetupChoices: Equatable {
    var watch: [WatchedProvider: Bool]
    var alerts: AlertSettings
    var startAtLogin: Bool
    var rememberSeats: Bool
    var mcp: Bool

    /// Detection pre-fills ON exactly what it found. Cursor stays OFF until it is
    /// connected, and MCP stays OFF until the user turns it on.
    static func prefilled(_ d: Detection) -> SetupChoices {
        var watch: [WatchedProvider: Bool] = [:]
        for p in WatchedProvider.allCases {
            watch[p] = d.found.contains(p) && p != .cursor && !p.isMoney
        }
        return SetupChoices(watch: watch, alerts: .defaults, startAtLogin: true, rememberSeats: true, mcp: false)
    }
}

enum FirstRun {
    static let closingLine = "You can change any of this later: menu ▸ Settings…"
    static let skippedLine = "Tower is watching nothing yet. Open it any time: menu ▸ Settings…"

    enum LaunchDecision: Equatable { case show, done }

    /// Decided once per launch. An install that already has store rows is an upgrade: it
    /// keeps every provider on and never sees the first run. A fresh install marks the
    /// first run pending, which makes every unset toggle read OFF until it is answered.
    static func resolveAtLaunch(defaults: UserDefaults = TowerPreferences.shared, storeHasRows: Bool) -> LaunchDecision {
        if defaults.bool(forKey: ProviderToggles.setupCompletedKey) { return .done }
        if defaults.bool(forKey: ProviderToggles.setupPendingKey) { return .show }
        if storeHasRows {
            defaults.set(true, forKey: ProviderToggles.setupCompletedKey)
            return .done
        }
        defaults.set(true, forKey: ProviderToggles.setupPendingKey)
        return .show
    }

    /// "Start watching": every toggle is written explicitly, then the run is over.
    static func startWatching(_ c: SetupChoices, defaults: UserDefaults = TowerPreferences.shared) {
        for p in WatchedProvider.allCases { ProviderToggles.set(p, c.watch[p] ?? false, defaults: defaults) }
        defaults.set(c.alerts.fiveHour, forKey: AlertSettings.fiveHourKey)
        defaults.set(c.alerts.weekly, forKey: AlertSettings.weeklyKey)
        defaults.set(c.alerts.fable, forKey: AlertSettings.fableKey)
        defaults.set(c.alerts.notify, forKey: AlertSettings.notifyKey)
        defaults.set(c.mcp, forKey: MCPAccess.enabledKey)
        finish(defaults)
    }

    /// "Skip, set up later": nothing is watched, and the panel says how to open Settings.
    static func skip(defaults: UserDefaults = TowerPreferences.shared) {
        for p in WatchedProvider.allCases { ProviderToggles.set(p, false, defaults: defaults) }
        defaults.set(false, forKey: MCPAccess.enabledKey)
        finish(defaults)
    }

    private static func finish(_ defaults: UserDefaults) {
        defaults.set(false, forKey: ProviderToggles.setupPendingKey)
        defaults.set(true, forKey: ProviderToggles.setupCompletedKey)
    }

    /// True when the user skipped and turned nothing on, so the panel shows `skippedLine`.
    static func watchesNothing(defaults: UserDefaults = TowerPreferences.shared) -> Bool {
        defaults.bool(forKey: ProviderToggles.setupCompletedKey)
            && WatchedProvider.allCases.allSatisfy { !ProviderToggles.isEnabled($0, defaults: defaults) }
    }
}

/// Forget one Claude seat, through the same path `tower_config_set retiredAccounts` and the
/// refresh's `forgetRetired` use: retire the address, then drop its Tower Keychain item.
enum SeatForget {
    static func forget(_ email: String, store: Store = .shared, vault: ClaudeSeatVault = .shared) -> String? {
        var retired = store.retiredEmails
        retired.insert(email.lowercased())
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            try enc.encode(retired.sorted()).write(to: store.retiredFile, options: .atomic)
        } catch {
            return error.localizedDescription
        }
        return vault.forgetRetired([email.lowercased()])
    }
}

/// The two lines Settings ▸ Agents copies, verbatim from docs/playbooks/mcp.md and setup.md.
enum MCPConfigLines {
    static let link = "ln -sf ~/Applications/Tower.app/Contents/MacOS/Tower ~/.local/bin/tower"
    static let add = "claude mcp add --scope user tower -- ~/.local/bin/tower mcp"
    static var both: String { link + "\n" + add }
}

/// Opens the first run on a fresh install's first launch, and Settings from the menu.
@MainActor
final class SetupWindows {
    static let shared = SetupWindows()
    private var window: NSWindow?

    func openFirstRunIfNeeded(model: LimitsModel) {
        let decision = FirstRun.resolveAtLaunch(storeHasRows: !Store.shared.load().isEmpty)
        guard decision == .show else { return }
        let detection = ProviderDetection.detect(claudeSeats: { ProviderDetection.claudeSeatCount() })
        show(title: "Tower · set up", FirstRunView(detection: detection, onDone: { [weak self] in
            self?.window?.close()
            Task { await model.refresh() }
        }))
    }

    func openSettings(model: LimitsModel) {
        show(title: "Tower · Settings", SettingsView(model: model))
    }

    private func show<V: View>(title: String, _ view: V) {
        let host = NSHostingController(rootView: view)
        let w = window ?? NSWindow(contentViewController: host)
        w.contentViewController = host
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
