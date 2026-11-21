import Foundation

/// The full dashboard (round 5 pick, 2026-11-06) is a web view hosting the approved page.
/// Everything it shows comes from this feed: the same ten read tools `tower mcp` answers,
/// merged into one JSON and pushed into the page with `window.towerUpdate(feed)`.
///
/// No network: the feed never calls a write or refresh tool (the app's own poll refreshes),
/// and the web view refuses every navigation and subresource except the page itself.
/// No email reaches the page; the scrub runs on every string in the feed.
enum DashboardFeed {
    /// Feed key and the MCP tool behind it. Reads only.
    static let tools: [(key: String, tool: String)] = [
        ("status", "tower_status"), ("accounts", "tower_accounts"), ("resets", "tower_resets"),
        ("room", "tower_room"), ("sessions", "tower_sessions"), ("lanes", "tower_lanes"),
        ("alerts", "tower_alerts"), ("freshness", "tower_freshness"), ("advice", "tower_advice"),
        ("openrouterHistory", "tower_openrouter_history"),
    ]
    static var toolKeys: [String] { tools.map(\.key) }
    static var toolNames: [String] { tools.map(\.tool) }

    /// The page inside the repo; build-app.sh copies Resources/Dashboard into the bundle.
    static let pageRepoPath = "Resources/Dashboard/index.html"

    /// The bundle that carries the resources. `Bundle.main` has no Info.plist when Tower is
    /// started through the PATH symlink (`tower dashboardshot`), so this resolves the
    /// enclosing app bundle the way every other lookup does (ProductIdentity.runningBundle).
    /// `executablePath` names the binary to resolve from; tests pass a symlink.
    static func resourceBundle(executablePath: String? = nil) -> Bundle {
        if let executablePath, let app = ProductIdentity.enclosingAppBundle(executablePath: executablePath) { return app }
        return ProductIdentity.runningBundle() ?? .main
    }

    /// The page the app loads, or nil when the bundle was built without it.
    static func bundledPage(bundle: Bundle? = nil, executablePath: String? = nil) -> String? {
        let resolved = bundle ?? resourceBundle(executablePath: executablePath)
        guard let url = resolved.resourceURL?.appendingPathComponent("Dashboard/index.html") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// How long the panel's first paint waits for the session probe before it shows the
    /// sessions as unavailable and a full feed follows.
    static let firstPaintDeadline: TimeInterval = 2.5

    /// The most OpenRouter samples the page receives; the spark line needs shape, not every poll.
    static let maxHistorySamples = 400

    /// `notice` is the line the last operator action left (a Re-trust that failed or left seats
    /// unreadable); the classic panel shows it, so the dashboard must too.
    ///
    /// The session probe is the slow tool (about 10 s with 28 live sessions). It starts at the
    /// top, beside the fast ones. By default (`nil`) the feed waits for all of it, which is what
    /// a one-shot caller such as `tower dashboard-feed` needs. Only the panel's first paint
    /// passes `firstPaintDeadline`: past it the sessions read as unavailable and
    /// `sessionsDeferred` is true, so the caller follows with a full feed (`nil` deadline).
    /// Before this the first paint waited on the probe and the panel sat on "Waiting for
    /// Tower's first read" for as long as it ran.
    ///
    /// `probe` carries the running session probe from the first build of one open to the full
    /// one that follows it, so a slow open runs the CLI probe once, not twice. Pass the same
    /// holder to both; a fresh holder per open, never kept across opens (it would serve an old
    /// answer).
    static func build(
        service: TowerMCPService, notice: String? = nil, sessionDeadline: TimeInterval? = nil,
        probe: SessionsProbe = SessionsProbe()
    ) async -> JSON {
        var out: [String: JSON] = [:]
        let started = Date()
        let sessionsProbe = probe.current { Task { await service.sessions().structuredContent ?? .null } }
        out["status"] = service.status().structuredContent ?? .null
        let accounts = service.accounts(provider: nil).structuredContent ?? .null
        out["accounts"] = accounts
        out["resets"] = service.resets().structuredContent ?? .null
        out["room"] = service.room(provider: nil, minimumRoom: nil).structuredContent ?? .null
        out["lanes"] = service.lanes().structuredContent ?? .null
        var sessionsDeferred = false
        var sessions: JSON
        if let sessionDeadline {
            let left = max(0.05, sessionDeadline - Date().timeIntervalSince(started))
            if let answered = await within(left, { await sessionsProbe.value }) {
                sessions = answered
            } else {
                // Not answered yet: say so, never "zero sessions". A full feed follows.
                sessionsDeferred = true
                sessions = unavailableSessions(now: service.env.now())
            }
        } else {
            sessions = await sessionsProbe.value
        }
        out["sessions"] = nameSessionOwners(sessions, accounts: accounts)
        out["sessionsDeferred"] = .bool(sessionsDeferred)
        out["alerts"] = service.alerts().structuredContent ?? .null
        out["freshness"] = service.freshness().structuredContent ?? .null
        out["advice"] = service.advice().structuredContent ?? .null
        out["openrouterHistory"] = thinHistory(service.openRouterHistory().structuredContent ?? .null)
        out["generatedAt"] = .date(service.env.now())
        // Tower's own cap (AccountSnapshot.cappedPct): the page classifies a seat as full from
        // this, never from a threshold of its own.
        out["cappedPct"] = .number(AccountSnapshot.cappedPct)
        out["notice"] = notice.map { .string($0) } ?? .null
        return scrub(.object(out))
    }

    /// The same shape `tower_sessions` answers when the probe is unavailable, which the page
    /// already draws as "sessions unavailable".
    static func unavailableSessions(now: Date) -> JSON {
        [
            "generatedAt": .date(now), "available": false, "interactive": [], "groups": [], "backgroundCount": 0,
            "blastRadius": .null,
        ]
    }

    /// The operation's answer, or nil when `seconds` pass first. The operation is not
    /// cancelled: a slow probe keeps running and the caller moves on without waiting for it
    /// (a task group would wait for it to finish, which is the bug).
    static func within(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> JSON) async -> JSON? {
        await withCheckedContinuation { (continuation: CheckedContinuation<JSON?, Never>) in
            let gate = OnceGate()
            Task {
                let value = await operation()
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// The session probe of one dashboard open. `current` starts it on first use and hands the
    /// same task to every later build, whether it has finished or not.
    final class SessionsProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<JSON, Never>?
        func current(start: () -> Task<JSON, Never>) -> Task<JSON, Never> {
            lock.lock(); defer { lock.unlock() }
            if let task { return task }
            let started = start()
            task = started
            return started
        }
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    /// Each session row's owner as a seat nickname (`accountNickname`), resolved while the
    /// email is still readable: the scrub turns every address into "seat", after which the page
    /// could only match the first seat.
    static func nameSessionOwners(_ sessions: JSON, accounts: JSON) -> JSON {
        var byEmail: [String: String] = [:]
        for row in accounts["accounts"].arrayValue ?? [] where row["provider"].stringValue == "claude" {
            if let e = row["email"].stringValue?.lowercased(), let n = row["nickname"].stringValue { byEmail[e] = n }
        }
        func name(_ list: JSON) -> JSON {
            guard let rows = list.arrayValue else { return list }
            return .array(rows.map { row in
                guard case .object(var o) = row else { return row }
                o["accountNickname"] = row["accountEmail"].stringValue.flatMap { byEmail[$0.lowercased()] }.map(JSON.string) ?? .null
                return .object(o)
            })
        }
        guard case .object(var o) = sessions else { return sessions }
        if let v = o["interactive"] { o["interactive"] = name(v) }
        if let v = o["groups"] { o["groups"] = name(v) }
        return .object(o)
    }

    /// Keeps the first and last sample and an even spread between them.
    static func thinHistory(_ history: JSON) -> JSON {
        guard case .object(var o) = history, let samples = o["samples"]?.arrayValue,
              samples.count > maxHistorySamples else { return history }
        let step = Double(samples.count - 1) / Double(maxHistorySamples - 1)
        o["samples"] = .array((0..<maxHistorySamples).map { samples[Int((Double($0) * step).rounded())] })
        return .object(o)
    }

    private static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#)

    /// Every string in the tree with emails replaced by "seat". Object keys are scrubbed too:
    /// store keys such as `codex:a@b.io` would otherwise carry the address.
    static func scrub(_ value: JSON) -> JSON {
        switch value {
        case .string(let s): return .string(scrubText(s))
        case .array(let a): return .array(a.map(scrub))
        case .object(let o):
            var clean: [String: JSON] = [:]
            for (k, v) in o { clean[scrubText(k)] = scrub(v) }
            return .object(clean)
        default: return value
        }
    }

    static func scrubText(_ s: String) -> String {
        guard s.contains("@") else { return s }
        return email.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "seat")
    }

    /// The feed as a JavaScript expression: valid JSON with `</` and the two line separators
    /// escaped, so it can sit inside a script element or an evaluateJavaScript call.
    static func jsLiteral(_ value: JSON) -> String {
        String(decoding: value.encoded(), as: UTF8.self)
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// The only navigation the web view accepts is the page itself, loaded from a string.
    enum NavigationPolicy {
        static func allows(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.absoluteString == "about:blank"
        }
    }

    /// WKContentRuleList source: block every load that could leave the process.
    static let contentRules = #"""
    [
     {"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}
    ]
    """#
}

/// The page can ask Swift for two things and nothing else: Re-trust the remembered seats (one
/// approval for all of them), and refresh now. The page posts one word; anything outside this
/// closed list is dropped. A login is a terminal command and never a button here.
enum DashboardBridge {
    /// The name the page posts to: `window.webkit.messageHandlers.tower`.
    static let handlerName = "tower"

    enum Action: String, Equatable {
        case retrust, refresh

        init?(word: String) { self.init(rawValue: word) }

        init?(body: Any) {
            guard let word = body as? String else { return nil }
            self.init(word: word)
        }
    }
}

/// What a click on the menu bar item opens. The dashboard is the default (round 5 pick);
/// the classic SwiftUI panel stays one setting away.
enum PanelSurface: String, CaseIterable, Sendable {
    case dashboard, classic

    static let defaultsKey = "panel.surface"

    static func current(defaults: UserDefaults = TowerPreferences.shared) -> PanelSurface {
        defaults.string(forKey: defaultsKey).flatMap(PanelSurface.init(rawValue:)) ?? .dashboard
    }

    static func set(_ surface: PanelSurface, defaults: UserDefaults = TowerPreferences.shared) {
        defaults.set(surface.rawValue, forKey: defaultsKey)
    }

    /// What applying the stored surface means for the panel and for the model.
    struct Decision: Equatable {
        /// The panel's content must be replaced.
        var swapContent: Bool
        /// The surface the published model preference takes. Always the stored one: an
        /// external change (tower_config_set) must not leave the model, and so the visible
        /// switch and the picker, on the surface that was shown before.
        var publish: PanelSurface
    }

    static func decide(shown: PanelSurface?, stored: PanelSurface) -> Decision {
        Decision(swapContent: shown != stored, publish: stored)
    }

    /// The surface a "switch" control moves to.
    var other: PanelSurface { self == .dashboard ? .classic : .dashboard }

    /// The label of the control, shown ON this surface, that moves to the other one: the
    /// dashboard shows "Classic panel", the classic panel shows "Dashboard". It already names
    /// the destination, so a caller passes its CURRENT surface here, never `.other` (review on #152).
    var switchLabel: String { self == .dashboard ? "Classic panel" : "Dashboard" }

    /// What the visible switch shows and where it goes, for one surface. Every call site
    /// (footer, classic button, context menu) uses this pair.
    var switchControl: (label: String, destination: PanelSurface) { (switchLabel, other) }

    /// The context menu's row for the switch.
    var switchMenuTitle: String { "Open the \(switchLabel)" }
}
