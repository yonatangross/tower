import Foundation
import CryptoKit

// MARK: - Provider

/// Where a row's numbers come from. The three differ in ways the UI must respect, so this
/// is not cosmetic tagging:
///
/// - `claude` has a 5h window AND a 7d window, polled from an OAuth-authenticated endpoint.
/// - `codex` on the ChatGPT plans reports ONE 7d window. Verified 2026-08-03 against every
///   `rate_limits` payload on disk: 74 of 74 had `secondary == nil`. Drawing a 5h meter for
///   it would invent a limit with no reading behind it.
/// - `cursor` reports TWO independently-enforced pools (Cursor Models and Other Models) per
///   billing cycle. They share a reset date but never a percentage or money denominator.
/// - `openrouter` is money, not a resetting quota. It does not refill on a clock and running
///   out is a hard stop, so it is never ranked alongside the other two.
/// - `typesafe` is a prepaid credit balance entered by hand. TypeSafe publishes no billing
///   or usage endpoint, so there is nothing to fetch and nothing to rank on.
/// - `muse`, `devin` and `agy` are agent lanes whose usage their CLIs do NOT write anywhere
///   this app can read. See `AgentLane`: they show what is observable (model pin, last
///   dispatch, last limit hit) and never a percentage, so they are never ranked either.
/// - `pi` is an agent lane that DOES record its spend: every assistant turn in its session
///   logs carries a USD cost. See `PiLane`: its row is money (month and today), compared with
///   the OpenRouter balance when Pi runs on OpenRouter, so it is never ranked as a quota.
enum Provider: String, Codable, CaseIterable {
    case claude, codex, cursor, openrouter, typesafe, muse, devin, agy, pi

    /// Only Claude publishes a short rolling window. Gating the meter on this is what keeps
    /// idea 3 ("hide windows that do not exist") honest as providers are added.
    var hasFiveHourWindow: Bool { self == .claude }

    /// The lanes whose rows carry a short and a weekly window under names the row itself
    /// holds (`scoped` labels), not under 5h and 7d. Cursor is not one: its row is the
    /// provider row above, with its own pools.
    var isAgentLane: Bool { self == .muse || self == .devin || self == .agy }

    /// Whether a row competes for "which account do I use next". Money does not: spending
    /// OpenRouter credit is a different decision from spending a quota that refills itself.
    /// An agent lane does not either: with no usage reading there is nothing to rank on.
    var isRankable: Bool {
        switch self {
        case .claude, .codex, .cursor:              return true
        case .openrouter, .typesafe, .muse, .devin, .agy, .pi:  return false
        }
    }

    /// What the primary window's meter is called.
    ///
    /// Every provider's main reading is stored in `weeklyPct`, because that is the field the
    /// trust, effective, ranking and threshold machinery already reads. The NAME is not
    /// shared: Claude and Codex really do report seven days, Cursor reports a billing month.
    /// Printing "7d" beside a monthly number understates the wait by three quarters, and the
    /// whole point of the row is to answer "how long until this lane is usable again".
    var primaryWindowLabel: String {
        switch self {
        case .claude, .codex, .openrouter: return "7d"
        // Pi's row sums a calendar month of session costs.
        case .cursor, .pi:                 return "month"
        // No window on this lane is ever published, so the label never reaches a claim:
        // weeklyPct stays nil and the threshold machinery never reads it.
        case .typesafe:                    return "day"
        // Devin's own error names the window ("Your daily usage quota has been exhausted").
        // Muse and agy never state theirs, so the label says so instead of guessing one.
        case .devin:                       return "day"
        case .muse, .agy:                  return "window"
        }
    }

    var label: String {
        switch self {
        case .claude:     return "Claude Code"
        case .codex:      return "Codex"
        case .cursor:     return "Cursor"
        case .openrouter: return "OpenRouter"
        case .typesafe:   return "TypeSafe"
        case .muse:       return "Muse"
        case .devin:      return "Devin"
        case .agy:        return "Antigravity"
        case .pi:         return "Pi"
        }
    }
}

// MARK: - Codex identity

/// The Codex account's email and plan, read from the id_token in ~/.codex/auth.json.
///
/// This is a plain JWT: header.payload.signature, base64url. We read the payload's public
/// claims only and never send the token anywhere, so no signature check is needed or wanted.
enum CodexAuth {
    struct Identity {
        let email: String
        let plan: String
    }

    static func identity(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Identity? {
        let path = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String
        else { return nil }
        guard let claims = decodeJWTPayload(idToken),
              let email = claims["email"] as? String, !email.isEmpty
        else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let plan = (auth?["chatgpt_plan_type"] as? String) ?? "?"
        return Identity(email: email, plan: plan)
    }

    static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url drops the padding that Foundation's decoder requires.
        if b64.count % 4 != 0 { b64 += String(repeating: "=", count: 4 - b64.count % 4) }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Codex usage

/// Codex usage WITHOUT an API call.
///
/// The Codex CLI writes its live rate-limit state into every session rollout file, so the
/// numbers are already on disk. That is strictly better than polling: no token to expire, no
/// endpoint to rate-limit, and nothing that could disturb a running Codex session. The Claude
/// side has no such luxury, which is why only this provider gets to be lazy.
enum CodexReader {
    struct Window: Decodable {
        let used_percent: Double?
        let window_minutes: Int?
        /// UNIX EPOCH SECONDS, unlike Claude's ISO-8601 string. Do not route this through
        /// DateParse: it would return nil and the window would silently lose its reset time.
        let resets_at: Double?

        var resetDate: Date? { resets_at.map { Date(timeIntervalSince1970: $0) } }
    }

    struct Credits: Decodable {
        let has_credits: Bool?
        let unlimited: Bool?
        let balance: String?
    }

    struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
        let plan_type: String?
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable { let rate_limits: RateLimits? }
        let payload: Payload?
    }

    /// The error the CLI writes when the plan's quota is spent.
    ///
    /// This is a DIFFERENT SHAPE from `rate_limits`, and that is the whole problem it exists
    /// to solve. An exhausted turn fails before any usage payload is produced, so it emits
    /// `event_msg.payload.error` with `codex_error_info == "usage_limit_exceeded"` and NO
    /// `rate_limits` anywhere in the file. A reader that only knows about `rate_limits`
    /// therefore sees nothing at all and reports the account as unmeasured, which the UI
    /// renders identically to "healthy, just not polled yet".
    ///
    /// Measured 2026-08-16: codex was hard-limited until Aug 20 while Tower's row said
    /// "1 available · 7d ?" and the mirrored cache entry carried no usage fields whatsoever.
    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            struct Err: Decodable {
                let message: String?
                let codex_error_info: String?
            }
            let error: Err?
        }
        let payload: Payload?
    }

    /// A quota exhaustion observed on disk.
    struct Exhaustion {
        /// When the plan says it reopens, parsed out of the human-readable message.
        /// nil when the message carried no date we could read: the exhaustion is still
        /// real and must still be reported, just without a reopening time.
        let resetsAt: Date?
        let message: String
    }

    struct Reading {
        let limits: RateLimits?
        /// Set when the newest signal on disk is an exhaustion rather than a usage payload.
        let exhaustion: Exhaustion?
        /// When this reading was produced, taken from the session file's mtime.
        let capturedAt: Date

        init(limits: RateLimits? = nil, exhaustion: Exhaustion? = nil, capturedAt: Date) {
            self.limits = limits
            self.exhaustion = exhaustion
            self.capturedAt = capturedAt
        }
    }

    /// Newest usable reading across recent session files.
    ///
    /// Scans newest-first and stops at the first file that yields a payload, because not every
    /// session carries one (22 of 96 did not, measured 2026-08-03). Bounded by `maxFiles` so a
    /// long-lived sessions directory cannot turn a menubar refresh into a full disk walk.
    ///
    /// Within one file the exhaustion is checked FIRST. A session that ran normally and then
    /// hit the wall contains both signals, and the wall is the later, current one; returning
    /// its earlier `rate_limits` would report the usage that existed just before the account
    /// stopped working.
    static func latest(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        maxFiles: Int = 8
    ) -> Reading? {
        let root = home.appendingPathComponent(".codex/sessions")
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var candidates: [(URL, Date)] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((url, mtime))
        }
        candidates.sort { $0.1 > $1.1 }

        for (url, mtime) in candidates.prefix(maxFiles) {
            if let limit = lastUsageLimit(in: url) {
                return Reading(exhaustion: limit, capturedAt: mtime)
            }
            if let limits = lastRateLimits(in: url) {
                return Reading(limits: limits, capturedAt: mtime)
            }
        }
        return nil
    }

    /// Last `usage_limit_exceeded` error in one file, scanned from the END like the usage
    /// payload, and for the same reason: the final occurrence is the current state.
    static func lastUsageLimit(in url: URL) -> Exhaustion? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("usage_limit_exceeded") else { continue }
            guard let data = line.data(using: .utf8),
                  let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
                  let err = env.payload?.error,
                  err.codex_error_info == "usage_limit_exceeded"
            else { continue }
            let message = err.message ?? "usage limit exceeded"
            return Exhaustion(resetsAt: reopening(in: message), message: message)
        }
        return nil
    }

    /// Parse the reopening moment out of a message like
    /// "You've hit your usage limit. ... try again at Aug 20th, 2026 8:12 AM."
    ///
    /// The date is prose, not a field, so this is best-effort BY DESIGN: a nil return means
    /// "exhausted, reopening time unknown", never "not exhausted". The caller must keep the
    /// exhaustion either way.
    static func reopening(in message: String, now: Date = Date()) -> Date? {
        // "Aug 20th, 2026 8:12 AM" — capture the ordinal so it can be stripped for parsing.
        let pattern = #"([A-Z][a-z]{2,8})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?:\s+(\d{1,2}):(\d{2})\s*([AaPp][Mm]))?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
        else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: message) else { return nil }
            return String(message[r])
        }
        guard let month = group(1), let day = group(2), let year = group(3) else { return nil }
        let hasTime = group(4) != nil
        let normalized = hasTime
            ? "\(month) \(day), \(year) \(group(4)!):\(group(5)!) \(group(6)!.uppercased())"
            : "\(month) \(day), \(year)"

        let fmt = DateFormatter()
        // The message is generated in en_US regardless of the machine's locale; parsing it
        // with the user's locale would fail on any non-English system.
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = hasTime ? "MMM d, yyyy h:mm a" : "MMM d, yyyy"
        return fmt.date(from: normalized)
    }

    /// Last `rate_limits` payload in one file. Scans from the END: a session appends as it
    /// runs, so the final occurrence is the current one and the earlier ones are history.
    static func lastRateLimits(in url: URL) -> RateLimits? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let env = try? JSONDecoder().decode(Envelope.self, from: data),
                  let limits = env.payload?.rate_limits
            else { continue }
            return limits
        }
        return nil
    }

    /// Fold a reading into a snapshot. The 7d window lands in `weeklyPct`/`weeklyResetsAt`
    /// so every existing consumer (trust, effective, ranked, thresholds) works unchanged.
    /// `fiveHourPct` is deliberately left nil, and `Provider.hasFiveHourWindow` stops the UI
    /// from drawing a meter for it.
    ///
    /// An exhaustion is folded in as `weeklyPct = 100`, which is the honest translation: the
    /// window IS spent. Writing the number rather than leaving it nil is what makes the row
    /// resting instead of "available", and routing the reopening time through
    /// `weeklyResetsAt` means the existing reset-aware machinery (`effective`, `reopening`)
    /// clears it automatically once the date passes, with no special case anywhere else.
    static func apply(_ reading: Reading, to snap: inout AccountSnapshot) {
        snap.provider = .codex
        snap.fiveHourPct = nil
        snap.fiveHourResetsAt = nil
        snap.capturedAt = reading.capturedAt

        if let out = reading.exhaustion {
            snap.weeklyPct = 100
            snap.weeklyResetsAt = out.resetsAt
            snap.lastError = out.message
            // A spent plan says nothing about prepaid credit, and stale credit next to an
            // exhausted window reads as "still usable". Drop it rather than assert it.
            snap.creditBalance = nil
            return
        }

        guard let limits = reading.limits else { return }
        let w = limits.primary
        snap.plan = limits.plan_type ?? snap.plan
        snap.weeklyPct = w?.used_percent
        snap.weeklyResetsAt = w?.resetDate
        snap.lastError = nil
        if let c = limits.credits, c.has_credits == true {
            snap.creditBalance = c.unlimited == true ? "unlimited" : c.balance
        } else {
            snap.creditBalance = nil
        }
    }

    /// Which reading a refresh folds. The live answer is the plan's state now; a disk
    /// reading is only as new as the last rollout, so it serves only when the CLI could
    /// not be asked. A disk exhaustion NEWER than the live answer cannot exist (live is
    /// taken at fold time), so there is no case where disk should override it.
    static func preferred(live: Reading?, disk: @autoclosure () -> Reading?) -> Reading? {
        live ?? disk()
    }

    /// The model the newest session ran, from its last `turn_context` record. Rollouts
    /// name the model per turn, so this is what a seat actually ran, which can differ from
    /// the config default (measured 2026-09-22: config said gpt-6-astra while the newest
    /// sessions ran gpt-6-luna). Scans from the end for the same reason as the usage read.
    static func lastModel(in url: URL) -> String? {
        guard let marker = AgentLane.lastLine(containing: "\"turn_context\"", in: url),
              let data = String(marker).data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["type"] as? String == "turn_context",
              let payload = row["payload"] as? [String: Any],
              let model = payload["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    /// Newest session's model across the most recent rollout files, then the config
    /// default, then nil.
    static func currentModel(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             maxFiles: Int = 8) -> String? {
        let root = home.appendingPathComponent(".codex/sessions")
        let fm = FileManager.default
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                      options: [.skipsHiddenFiles]) {
            var files: [(URL, Date)] = []
            for case let url as URL in walker where url.pathExtension == "jsonl"
                && url.lastPathComponent.hasPrefix("rollout-") {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                files.append((url, m))
            }
            for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(maxFiles) {
                if let model = lastModel(in: url) { return model }
            }
        }
        guard let toml = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"),
                                     encoding: .utf8) else { return nil }
        return configModel(toml: toml)
    }

    /// Top-level `model = "..."` in config.toml. A key inside a `[table]` is a profile or
    /// provider setting, not the default, so the scan stops at the first table header.
    static func configModel(toml: String) -> String? {
        for raw in toml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("model"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

// MARK: - Codex live usage

/// Codex usage asked of the Codex CLI itself, so the row is live even when no session ran.
///
/// The disk reader only advances when a Codex session writes a rollout, so an idle hour
/// reads as "stale" (measured 2026-09-22: the Codex row said "stale 2h" across a 18:48 to
/// 20:46 gap with no rollout written). `codex app-server` answers `account/rateLimits/read`
/// over stdio with the plan's current windows: verified live 2026-09-22 on codex-cli
/// 0.155.1, it returned 72 % used where the newest rollout said 71 %. Tower never touches
/// the ChatGPT token; the CLI does the call with its own login, as its TUI does for /status.
enum CodexLive {
    /// A login-item app has no shell PATH, so the installers' locations are checked.
    static func binary(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        [home.appendingPathComponent(".local/bin/codex"),
         URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
         URL(fileURLWithPath: "/usr/local/bin/codex")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The three messages one read needs: the handshake, its notification, the request.
    static let requestID = 2
    static let requests: [String] = [
        #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tower","version":"1"}}}"#,
        #"{"method":"initialized"}"#,
        #"{"id":2,"method":"account/rateLimits/read","params":null}"#,
    ]

    private struct Response: Decodable {
        struct Result: Decodable {
            struct Limits: Decodable {
                struct Window: Decodable {
                    let usedPercent: Double?
                    let windowDurationMins: Int?
                    let resetsAt: Double?
                }
                struct Credits: Decodable {
                    let hasCredits: Bool?
                    let unlimited: Bool?
                    let balance: String?
                }
                let primary: Window?
                let secondary: Window?
                let credits: Credits?
                let planType: String?
                let rateLimitReachedType: String?
            }
            let rateLimits: Limits?
        }
        let id: Int?
        let result: Result?
    }

    /// One app-server line into a reading, or nil when it is not the answer to our request
    /// or carries no windows. Pure, fixture-tested.
    static func parse(line: Data, now: Date) -> CodexReader.Reading? {
        guard let r = try? JSONDecoder().decode(Response.self, from: line),
              r.id == requestID, let l = r.result?.rateLimits else { return nil }
        func window(_ w: Response.Result.Limits.Window?) -> CodexReader.Window? {
            w.map { CodexReader.Window(used_percent: $0.usedPercent,
                                       window_minutes: $0.windowDurationMins,
                                       resets_at: $0.resetsAt) }
        }
        let limits = CodexReader.RateLimits(
            primary: window(l.primary), secondary: window(l.secondary),
            credits: l.credits.map { CodexReader.Credits(has_credits: $0.hasCredits,
                                                         unlimited: $0.unlimited,
                                                         balance: $0.balance) },
            plan_type: l.planType)
        guard limits.primary?.used_percent != nil else { return nil }
        // A named refusal is the plan saying "spent", whatever the percent rounds to.
        if let reached = l.rateLimitReachedType, !reached.isEmpty {
            // Reopens when the full window does: the latest reset among windows at 100 %,
            // else the primary window's.
            let full = [limits.primary, limits.secondary].compactMap { $0 }
                .filter { ($0.used_percent ?? 0) >= 100 }.compactMap(\.resetDate)
            return CodexReader.Reading(
                exhaustion: CodexReader.Exhaustion(resetsAt: full.max() ?? limits.primary?.resetDate,
                                                   message: "Codex \(reached.replacingOccurrences(of: "_", with: " "))"),
                capturedAt: now)
        }
        return CodexReader.Reading(limits: limits, capturedAt: now)
    }

    /// Spawns `codex app-server`, asks once, and stops it. nil on any failure (no binary,
    /// timeout, not signed in, unparseable): the caller falls back to the disk reader, so
    /// a broken CLI costs freshness, never a wrong number. Blocking; call off the main actor.
    /// Eight seconds: the probe runs beside the Cursor fetch (15 s), so a hung CLI must
    /// never become the slowest part of a refresh.
    static func fetch(timeout: TimeInterval = 8, now: @escaping () -> Date = Date.init) -> CodexReader.Reading? {
        guard let bin = binary() else { return nil }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        defer { if p.isRunning { p.terminate() } }
        let payload = requests.joined(separator: "\n") + "\n"
        // The throwing API: a child that exited early surfaces as an error, not an
        // Objective-C exception out of the legacy `write(_:)`.
        guard (try? input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))) != nil else { return nil }

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reading: CodexReader.Reading?
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); defer { lock.unlock() }
            guard reading == nil else { return }
            if chunk.isEmpty { done.signal(); handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<nl])
                buffer.removeSubrange(...nl)
                if let r = parse(line: line, now: now()) {
                    reading = r
                    handle.readabilityHandler = nil
                    done.signal()
                    return
                }
            }
        }
        _ = done.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        lock.lock(); defer { lock.unlock() }
        return reading
    }
}

// MARK: - OpenRouter budget

/// OpenRouter spend against a self-declared monthly budget.
///
/// ⚠️ UNVERIFIED WIRE SHAPE. There is no OpenRouter key on this machine (checked env,
/// ~/.zshrc, ~/.claude/settings.json and ~/.codex/config.toml on 2026-08-03), so the response
/// decoding below has never been exercised against a live response. Every failure path
/// therefore returns nil rather than a zero, and the UI hides the section entirely when it
/// gets nil. The app must never draw a $0.00 budget that is really "we could not ask".
enum OpenRouter {
    static let endpoint = "https://openrouter.ai/api/v1/credits"
    /// Stable local identity for the one balance-backed provider row. This is not an account
    /// email; it is a schema key that lets the shared quota cache carry money alongside the
    /// account-based providers without colliding with one of them.
    static let storeEmail = "openrouter@local"

    /// OPTIONAL self-imposed cap, overriding the account's own credit ceiling. Unset is the
    /// normal case: the API reports the real ceiling and guessing one is worse than reading it.
    static let budgetKey = "openrouter.monthlyBudgetUSD"

    struct Credits: Decodable {
        struct Data: Decodable {
            let total_credits: Double?
            let total_usage: Double?
        }
        let data: Data?
    }

    /// A pay-as-you-go BALANCE. OpenRouter's own dashboard leads with exactly one number,
    /// "TOTAL AVAILABLE $<usd>", and so should this.
    ///
    /// `limit` is NOT a budget: it is cumulative lifetime top-ups (for example $25 + $25), so
    /// "62% used" measures nothing an operator can act on. The actionable quantity is what
    /// is LEFT, and the alarm has to fire when that runs low, not when spend runs high.
    struct Budget: Equatable {
        let spent: Double
        let limit: Double

        /// The headline. Matches the dashboard's TOTAL AVAILABLE.
        var available: Double { max(limit - spent, 0) }
        /// Fraction of top-ups still unspent. Low is bad, which is the inverse of a quota.
        var availablePct: Double { limit > 0 ? max(available / limit * 100, 0) : 0 }

        var remaining: Double { available }
        var pct: Double { limit > 0 ? min(spent / limit * 100, 100) : 0 }
    }

    /// Applies only a successfully observed balance. Keeping the timestamp here makes the
    /// two facts inseparable: a row with a cash value but no capture time is worse than no
    /// row because downstream freshness gates cannot tell whether it is usable evidence.
    static func apply(_ budget: Budget, to snap: inout AccountSnapshot, now: Date = Date()) {
        snap.provider = .openrouter
        snap.plan = "balance"
        snap.tier = nil
        snap.fiveHourPct = nil
        snap.fiveHourResetsAt = nil
        snap.weeklyPct = nil
        snap.weeklyResetsAt = nil
        snap.scoped = []
        snap.creditBalance = nil
        snap.balanceUSD = budget.available
        snap.availablePct = budget.availablePct
        snap.capturedAt = now
        snap.lastError = nil
    }

    /// The row error a refused key leaves in the store. One spelling, shared by the writer
    /// and `persistedOutcome`, so the panel can tell a refusal from a network miss on reload.
    static func refusedError(_ code: Int) -> String {
        "OpenRouter key refused (HTTP \(code))."
    }

    static let unreadableError =
        "could not read OpenRouter balance (network, or the response did not parse)"

    static func refusedCode(_ error: String) -> Int? {
        let head = "OpenRouter key refused (HTTP ", tail = ")."
        guard error.hasPrefix(head), error.hasSuffix(tail) else { return nil }
        return Int(error.dropFirst(head.count).dropLast(tail.count))
    }

    /// The panel outcome the persisted row already proves, for a panel that has not polled
    /// yet (launch, and every panelshot). Before this the panel started at `.notConfigured`
    /// and hid the section until a live poll, so a 401 row sitting in the store rendered as
    /// no OpenRouter at all: the silent refusal `Outcome` exists to prevent.
    ///
    /// No key is read here. A refusal carries no fingerprint; the next poll fills it in.
    static func persistedOutcome(from accounts: [AccountSnapshot],
                                 lastSuccessAt: Date?) -> Outcome {
        guard let row = accounts.first(where: {
            $0.kind == .openrouter && $0.email == storeEmail
        }) else { return .notConfigured }
        if let error = row.lastError {
            if let code = refusedCode(error) {
                return .rejected(code, keyFingerprint: nil, lastSuccessAt: lastSuccessAt)
            }
            return .unavailable
        }
        guard let available = row.balanceUSD else { return .unavailable }
        // The store keeps what is left and its share of top-ups, so the top-up total is
        // recoverable exactly. A zero share means nothing is left (or nothing was added).
        let pct = row.availablePct ?? 0
        let limit = pct > 0 ? available * 100 / pct : available
        return .ok(Budget(spent: max(limit - available, 0), limit: limit))
    }

    /// Local observations of the *balance* returned by OpenRouter. The credits endpoint has
    /// no historical-series API, so a chart must be built from values we actually observed;
    /// it must never invent a smooth spend curve from one reading.
    enum History {
        struct Sample: Codable, Equatable {
            let capturedAt: Date
            let available: Double
            let spent: Double
            let totalCredits: Double
        }

        /// The facts needed to describe a balance change without inventing data between
        /// observations. `previous` is intentionally the immediately preceding sample:
        /// the panel's change label must not compare the current balance to an arbitrary
        /// bucket or a made-up candle open.
        struct Trend: Equatable {
            let first: Sample
            let previous: Sample
            let latest: Sample
            let minimum: Double
            let maximum: Double

            var changeSincePrevious: Double { latest.available - previous.available }
            var changeSpan: TimeInterval {
                latest.capturedAt.timeIntervalSince(previous.capturedAt)
            }
            var observedSpan: TimeInterval {
                latest.capturedAt.timeIntervalSince(first.capturedAt)
            }

            /// A fraction of a cent is noise once the UI rounds balances to cents. Do not
            /// draw a chart that looks meaningful when every observed point is effectively flat.
            var hasMeaningfulChange: Bool {
                maximum - minimum >= 0.005
            }
        }

        private static let key = "openrouter.balanceHistory.v1"
        private static let retention: TimeInterval = 30 * 86_400
        private static let minSpacing: TimeInterval = 60

        static func load(defaults: UserDefaults = TowerPreferences.shared) -> [Sample] {
            guard let data = defaults.data(forKey: key),
                  let samples = try? JSONDecoder().decode([Sample].self, from: data)
            else { return [] }
            return samples.sorted { $0.capturedAt < $1.capturedAt }
        }

        @discardableResult
        static func record(_ budget: Budget, now: Date = Date(),
                           defaults: UserDefaults = TowerPreferences.shared) -> [Sample] {
            var samples = load(defaults: defaults)
            let next = Sample(capturedAt: now, available: budget.available,
                              spent: budget.spent, totalCredits: budget.limit)
            if let last = samples.last, now.timeIntervalSince(last.capturedAt) < minSpacing {
                samples[samples.count - 1] = next
            } else {
                samples.append(next)
            }
            samples.removeAll { now.timeIntervalSince($0.capturedAt) > retention }
            if let data = try? JSONEncoder().encode(samples) { defaults.set(data, forKey: key) }
            return samples
        }

        /// A trend based solely on exact, timestamped observations. This deliberately
        /// avoids OHLC aggregation: samples record point-in-time balances, not intraperiod
        /// high/low values, so a candle would make a stronger claim than the data supports.
        static func trend(_ samples: [Sample]) -> Trend? {
            let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
            guard let first = sorted.first, sorted.count >= 2,
                  let previous = sorted.dropLast().last, let latest = sorted.last
            else { return nil }
            let values = sorted.map(\.available)
            return Trend(first: first, previous: previous, latest: latest,
                         minimum: values.min() ?? first.available,
                         maximum: values.max() ?? first.available)
        }
    }

    /// Where the OpenRouter key comes from. Both settings are optional; with neither,
    /// the MONEY section reports OpenRouter as not configured and stays hidden.
    ///
    /// - `openRouterKeyCommand` (a string array in Tower's settings domain): an executable
    ///   and its arguments, run without a shell, whose stdout is the key. Use it for a
    ///   password manager read. When it is set it is the only source: an exported copy
    ///   of an old key must never override the manager after a rotation.
    /// - `OPENROUTER_API_KEY` in the environment, used only when no command is set. A GUI
    ///   app sees it only through `launchctl setenv`.
    /// - `openRouterKeyCacheFile` (string): a file the key command caches into. On a 401
    ///   Tower deletes it once and reads again, so a rotated key is picked up. Without it
    ///   a 401 is reported as a refusal straight away.
    ///
    /// Tower never persists the key itself.
    struct KeySource: Equatable {
        var command: [String]?
        var cacheFile: String?
        var environmentKey: String?

        static let commandPreference = "openRouterKeyCommand"
        static let cacheFilePreference = "openRouterKeyCacheFile"
        static let environmentVariable = "OPENROUTER_API_KEY"

        static func current(defaults: UserDefaults = TowerPreferences.shared,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> KeySource {
            let command = defaults.stringArray(forKey: commandPreference).flatMap { $0.isEmpty ? nil : $0 }
            let cache = defaults.string(forKey: cacheFilePreference).flatMap { $0.isEmpty ? nil : $0 }
            let envKey = env[environmentVariable].flatMap { $0.isEmpty ? nil : $0 }
            return KeySource(command: command, cacheFile: cache, environmentKey: envKey)
        }

        var isConfigured: Bool { command != nil || environmentKey != nil }

        /// What `tower mcp` reports about the source, without the key or the command's
        /// arguments (they can name a vault item).
        var kind: String {
            if command != nil { return "command" }
            if environmentKey != nil { return "environment" }
            return "none"
        }
    }

    static func clearKeyCache(source: KeySource = .current(),
                              fileManager: FileManager = .default) -> Bool {
        guard let path = source.cacheFile else { return false }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return true
        } catch {
            return false
        }
    }

    /// Read the key on each poll from the configured source (see `KeySource`).
    static func apiKey(source: KeySource = .current(),
                       run: ([String]) -> String? = runKeyCommand) -> String? {
        let raw: String?
        if let command = source.command {
            raw = run(command)
        } else {
            raw = source.environmentKey
        }
        guard let value = raw else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func runKeyCommand(_ argv: [String]) -> String? {
        guard let executable = argv.first, !executable.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (executable as NSString).expandingTildeInPath)
        process.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + (environment["PATH"] ?? "")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func monthlyBudget() -> Double? {
        let v = TowerPreferences.shared.double(forKey: budgetKey)
        return v > 0 ? v : nil
    }

    /// Key for last successful fetch timestamp.
    ///
    /// A single global slot, not keyed to the key: after a rotation the new key inherits
    /// the old key's last success. That is the intended signal for this panel, where the
    /// point of the timestamp is to show the section worked before the key was refused.
    static let lastSuccessKey = "openrouter.lastSuccessAt"

    /// Returns the timestamp of the most recent successful balance fetch, if any.
    static func lastSuccessTime(defaults: UserDefaults = TowerPreferences.shared) -> Date? {
        guard defaults.object(forKey: lastSuccessKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: lastSuccessKey))
    }

    /// Records a successful balance fetch.
    static func recordSuccess(now: Date = Date(), defaults: UserDefaults = TowerPreferences.shared) {
        defaults.set(now.timeIntervalSince1970, forKey: lastSuccessKey)
    }

    /// Returns the last 4 characters of the API key for identification, or nil if unavailable.
    ///
    /// The tail, not the head: every OpenRouter key starts with the constant "sk-or-v1-",
    /// so any prefix is identical for all keys and identifies nothing. The 4-character
    /// tail is the 1Password convention for naming keys.
    static func keyFingerprint() -> String? {
        guard let key = apiKey(), key.count >= 4 else { return nil }
        return String(key.suffix(4))
    }

    /// What asking the API actually produced.
    ///
    /// The first version returned `Budget?` and hid the section on nil, which collapsed two
    /// opposite situations into one silence: "you do not use OpenRouter" and "your key is
    /// being refused". The operator's key was rotated in 1Password four hours after it was
    /// copied into the Keychain, and the panel simply stopped showing the section. He found
    /// out by opening the dashboard himself, which is the definition of a silent failure.
    ///
    /// Hiding is correct for `notConfigured` and wrong for everything else.
    enum Outcome: Equatable {
        /// No key anywhere. The section hides; this user does not use OpenRouter.
        case notConfigured
        /// A key exists and the API refused it (401/403). LOUD: it is broken, not absent.
        /// Includes key fingerprint (last 4 chars) and last-success time if known.
        case rejected(Int, keyFingerprint: String?, lastSuccessAt: Date?)
        /// A key exists but the answer did not arrive or did not parse. Quietly present.
        case unavailable
        case ok(Budget)
    }

    /// Verified live 2026-08-03: HTTP 200, `{"data":{"total_credits":<usd>,
    /// "total_usage":<usd>}}`. This is a PREPAID BALANCE, not a monthly spend budget.
    ///
    /// The account publishes its own ceiling, so read it rather than guess; the manual
    /// `monthlyBudgetUSD` key stays as an override for a self-imposed cap.
    static func fetch(
        isConfigured: @escaping () -> Bool = { KeySource.current().isConfigured },
        readKey: @escaping () -> String? = { apiKey() },
        clearCache: @escaping () -> Bool = { clearKeyCache() },
        request: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) async -> Outcome {
        // No source at all means this user does not use OpenRouter: hide the section.
        // A configured source that yields nothing is a failure and stays visible.
        guard isConfigured() else { return .notConfigured }
        guard let key = readKey(), let url = URL(string: endpoint) else { return .unavailable }
        let fingerprint = Self.fingerprint(for: key)
        let lastSuccess = lastSuccessTime()
        guard let (data, response) = try? await request(Self.request(for: key, url: url)),
              let http = response as? HTTPURLResponse
        else { return .unavailable }

        if http.statusCode == 401 {
            guard clearCache(), let refreshedKey = readKey() else {
                return .rejected(401, keyFingerprint: fingerprint, lastSuccessAt: lastSuccess)
            }
            guard let (refreshedData, refreshedResponse) = try? await request(
                Self.request(for: refreshedKey, url: url)
            ), let refreshedHTTP = refreshedResponse as? HTTPURLResponse
            else { return .unavailable }
            return outcome(
                data: refreshedData,
                http: refreshedHTTP,
                fingerprint: Self.fingerprint(for: refreshedKey),
                lastSuccess: lastSuccess
            )
        }

        return outcome(data: data, http: http, fingerprint: fingerprint, lastSuccess: lastSuccess)
    }

    private static func request(for key: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(UsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    private static func fingerprint(for key: String) -> String? {
        key.count >= 4 ? String(key.suffix(4)) : nil
    }

    private static func outcome(
        data: Data,
        http: HTTPURLResponse,
        fingerprint: String?,
        lastSuccess: Date?
    ) -> Outcome {
        if http.statusCode == 401 || http.statusCode == 403 {
            return .rejected(http.statusCode, keyFingerprint: fingerprint, lastSuccessAt: lastSuccess)
        }
        guard (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Credits.self, from: data),
              let used = decoded.data?.total_usage,
              let limit = monthlyBudget() ?? decoded.data?.total_credits
        else { return .unavailable }
        recordSuccess()
        return .ok(Budget(spent: used, limit: limit))
    }
}

// MARK: - TypeSafe balance

/// TypeSafe decision-model prepaid credit balances (Jev and Clef), entered by hand.
///
/// There is nothing to fetch here. TypeSafe's public API exposes no billing or usage
/// endpoint (api.typesafe.ai/openapi.json v0.2.0 declares exactly POST /v1/systemone and
/// GET /v1/models), and the console's own usage and balance reads answer only a browser
/// session, which Tower deliberately does not hold. So each model row ships ONE fact: the
/// operator-entered balance, labelled as entered every time it renders. It has no capture
/// time anywhere on purpose, because nothing was observed, and it is never ranked.
///
/// TypeSafe ships two decision models, so the money section shows them as one group: a
/// row per model, each with its own entered figure and as-of day. Every function takes a
/// `model` that defaults to `.jev`, so the callers written when Jev was the only row keep
/// their meaning unchanged.
enum TypeSafe {
    /// Stable local identity for the row, exactly like `OpenRouter.storeEmail`: not an
    /// account email, a schema key that names this lane without colliding with an
    /// account-based provider.
    static let storeEmail = "typesafe@local"

    /// NOT LIVE, and it must never look like it is: no endpoint publishes the balance, so
    /// the figure is entered by hand and goes stale between entries. Nothing ships by
    /// default: with no entry the row is hidden. The traffic light below (amber under
    /// USD 10, red under USD 5) is applied to the entered figure.

    /// The decision models TypeSafe sells credits for. Order is the panel order.
    enum Model: String, CaseIterable, Sendable {
        case jev, clef

        /// The product name, for labels a person reads ("Jev credits").
        var name: String {
            switch self {
            case .jev: return "Jev"
            case .clef: return "Clef"
            }
        }

        /// Who makes the model. Jev is TypeSafe's; Clef is Cloudflare's (Workers AI,
        /// Jev-API compatible, launched 2026-10-01), so no label may file it under TypeSafe.
        var vendor: String {
            switch self {
            case .jev: return "TypeSafe"
            case .clef: return "Cloudflare"
            }
        }

        /// Where a person reads the balance to re-enter it.
        var billingSource: String {
            switch self {
            case .jev: return "TypeSafe console Billing"
            case .clef: return "the Cloudflare dashboard (Workers AI)"
            }
        }

        /// The `tower_config_set` key a person types. Clef's names its vendor; the storage
        /// pair below keeps its first names, so an entry made before this still shows.
        var configKey: String {
            switch self {
            case .jev: return "typesafe.balanceUSD"
            case .clef: return "cloudflare.clef.balanceUSD"
            }
        }

        /// Earlier config keys that still set this model, so a script or prompt written
        /// against v0.1.0 keeps working.
        var legacyConfigKeys: [String] {
            switch self {
            case .jev: return []
            case .clef: return ["typesafe.clef.balanceUSD"]
            }
        }

        /// The model a config key sets, the current key or an alias; nil for any other key.
        static func forConfigKey(_ key: String) -> Model? {
            allCases.first { $0.configKey == key || $0.legacyConfigKeys.contains(key) }
        }


        /// Where the entered figure lives. Jev keeps the keys it had before Clef existed,
        /// so an entry made then still shows; Clef gets its own namespaced pair.
        var balanceKey: String {
            switch self {
            case .jev: return "typesafe.balanceUSD"
            case .clef: return "typesafe.clef.balanceUSD"
            }
        }

        var balanceAsOfKey: String {
            switch self {
            case .jev: return "typesafe.balanceAsOf"
            case .clef: return "typesafe.clef.balanceAsOf"
            }
        }
    }

    /// Where a re-entered Jev figure lives, so topping up does not mean editing source and
    /// reinstalling. `tower_config_set typesafe.balanceUSD` writes both keys together;
    /// the as-of day is the day of entry, never a guess. Clef's pair is on `Model`.
    static let balanceKey = Model.jev.balanceKey
    static let balanceAsOfKey = Model.jev.balanceAsOfKey

    /// One entered figure and the day it was read off the console.
    struct Entry: Equatable {
        let usd: Double
        let asOf: String
    }

    /// The figure every surface renders, or nil when none was entered. A half-written pair
    /// (a balance without its day) counts as no entry, because a figure with no as-of date
    /// cannot say how old it is.
    static func entry(model: Model = .jev, defaults: UserDefaults = TowerPreferences.shared) -> Entry? {
        guard defaults.object(forKey: model.balanceKey) != nil,
              let asOf = defaults.string(forKey: model.balanceAsOfKey) else { return nil }
        return Entry(usd: defaults.double(forKey: model.balanceKey), asOf: asOf)
    }

    /// Whether a model's row exists at all: only after a balance was entered.
    static func isEntered(model: Model = .jev, defaults: UserDefaults = TowerPreferences.shared) -> Bool {
        entry(model: model, defaults: defaults) != nil
    }

    /// The models with an entered figure, in panel order. Empty means the whole TypeSafe
    /// group is hidden, exactly as the single Jev row was before.
    static func enteredModels(defaults: UserDefaults = TowerPreferences.shared) -> [Model] {
        Model.allCases.filter { isEntered(model: $0, defaults: defaults) }
    }

    /// Records a figure read off the console now, dated today in local time.
    @discardableResult
    static func enter(_ usd: Double, model: Model = .jev, now: Date = Date(),
                      defaults: UserDefaults = TowerPreferences.shared) -> Entry {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let entry = Entry(usd: usd, asOf: f.string(from: now))
        defaults.set(entry.usd, forKey: model.balanceKey)
        defaults.set(entry.asOf, forKey: model.balanceAsOfKey)
        return entry
    }

    /// Drops the operator entry; the row hides again.
    static func clearEntry(model: Model = .jev, defaults: UserDefaults = TowerPreferences.shared) {
        defaults.removeObject(forKey: model.balanceKey)
        defaults.removeObject(forKey: model.balanceAsOfKey)
    }

    /// What to do about a stale figure, or nil while it is fresh. Nothing can fetch the
    /// balance, so the only fix is a new entry, and the row names exactly how to make one.
    static func reenterHint(model: Model = .jev, now: Date = Date(),
                            defaults: UserDefaults = TowerPreferences.shared) -> String? {
        guard isEntered(model: model, defaults: defaults),
              balanceIsStale(model: model, now: now, defaults: defaults) else { return nil }
        return "read \(model.billingSource), then tower_config_set \(model.configKey) <usd>"
    }

    /// Traffic-light vocabulary on the entered balance. Strictly UNDER the lines: exactly
    /// 10.00 is still green and exactly 5.00 is still amber, pinned by tests at the
    /// boundary the same way the pct thresholds are.
    enum BalanceLevel: Equatable {
        case green, amber, red
    }

    static func balanceLevel(_ usd: Double) -> BalanceLevel {
        if usd < 5 { return .red }
        if usd < 10 { return .amber }
        return .green
    }

    /// Money text for the row.
    static func money(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// The entered Jev balance as one labelled string: the figure and the as-of date. No
    /// capture time is attached anywhere, on purpose: there is no observation behind it.
    static var balanceText: String {
        guard let e = entry() else { return "not entered" }
        return "\(money(e.usd)) (operator-entered \(e.asOf))"
    }

    /// The full row fact for `tower status`: the balance text with the as-of date AND
    /// its age plus the not-live qualifier; a stale figure says so rather than borrowing
    /// the confidence of a fresh entry.
    static func statusRowText(model: Model = .jev, now: Date = Date(),
                              defaults: UserDefaults = TowerPreferences.shared) -> String {
        guard let usd = entry(model: model, defaults: defaults)?.usd else {
            return "no balance entered (tower_config_set \(model.configKey) <usd>)"
        }
        let staleMark = balanceIsStale(model: model, now: now, defaults: defaults) ? ", stale" : ""
        return "balance \(money(usd)) (\(enteredLabel(model: model, now: now, defaults: defaults)))\(staleMark), not live"
    }

    /// Days since the entered figure was read off the console. nil when the
    /// as-of string cannot be parsed, which the row treats as stale too.
    static func balanceAgeDays(model: Model = .jev, now: Date = Date(),
                               defaults: UserDefaults = TowerPreferences.shared) -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let asOf = entry(model: model, defaults: defaults)?.asOf,
              let entered = f.date(from: asOf) else { return nil }
        // Calendar days, not 86,400 s spans: a DST transition makes a day 23 or
        // 25 hours and an absolute-time division under-counts by one.
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: entered),
                                      to: cal.startOfDay(for: now)).day
        return max(0, days ?? 0)
    }

    /// An entered figure decays: past three days it is too old to plan against
    /// and the row greys out. An unparseable as-of date is stale by definition.
    static func balanceIsStale(model: Model = .jev, now: Date = Date(),
                               defaults: UserDefaults = TowerPreferences.shared) -> Bool {
        balanceAgeDays(model: model, now: now, defaults: defaults).map { $0 > 3 } ?? true
    }

    /// The panel's words for a stale entry. The exact command (`reenterHint`) is for the CLI,
    /// MCP and the row's tooltip; the panel text names the action only. Both models are
    /// topped up on the same Billing page, so the words are shared.
    static let panelReenterAction = "re-enter from\nTypeSafe Billing"

    /// "entered 12d ago", the panel's short form of `enteredLabel`.
    static func enteredAgeLabel(model: Model = .jev, now: Date = Date(),
                                defaults: UserDefaults = TowerPreferences.shared) -> String {
        guard let days = balanceAgeDays(model: model, now: now, defaults: defaults) else { return "entered, undated" }
        return days == 0 ? "entered today" : "entered \(days)d ago"
    }

    /// "entered 09-18 · 5d ago": the as-of date plus its age, every render.
    static func enteredLabel(model: Model = .jev, now: Date = Date(),
                             defaults: UserDefaults = TowerPreferences.shared) -> String {
        guard let raw = entry(model: model, defaults: defaults)?.asOf else { return "not entered" }
        let short = raw.count >= 10 ? String(raw.dropFirst(5)) : raw
        guard let days = balanceAgeDays(model: model, now: now, defaults: defaults) else { return "entered \(short) · undated" }
        return "entered \(short) · \(days)d ago"
    }
}

// MARK: - Cursor identity

/// The Cursor account's email, plan and session token, read from Cursor's OWN state, so
/// nothing has to be pasted anywhere and nothing can silently go stale behind the operator.
///
/// Cursor is an Electron app and keeps its auth in a plain, UNENCRYPTED SQLite key/value
/// table at `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`:
///
///   cursorAuth/accessToken            a WorkOS session JWT
///   cursorAuth/cachedEmail            the signed-in address
///   cursorAuth/stripeMembershipType   "pro" | "free" | ...
///   cursorAuth/stripeSubscriptionStatus
///
/// The obvious other candidate, `~/Library/Application Support/Cursor/Cookies`, is the
/// Chromium cookie store: every value there is AES-GCM sealed against a key in the login
/// Keychain, and reading it means decrypting someone else's cookie jar. The vscdb path
/// needs no decryption and no Keychain prompt, so it is both simpler and less invasive.
///
/// Shells out to `/usr/bin/sqlite3 -readonly` for the same reason `Keychain` shells out to
/// `/usr/bin/security`: it is already on every Mac, it handles the WAL journal correctly on
/// a database Cursor is actively writing, and it keeps a C SQLite dependency out of the
/// package. Measured 2026-08-18 against a live 47 MB `state.vscdb` while Cursor was running:
/// 5 ms, no lock contention.
enum CursorAuth {
    struct Identity {
        let email: String
        /// "pro", "free", ... straight from the row. Never guessed.
        let plan: String
        let subscriptionStatus: String?
        /// The WorkOS session JWT. Never logged, never persisted by this app.
        let accessToken: String
        /// The JWT's `sub`, e.g. "google-oauth2|user_01J8…". Half of the session cookie.
        /// When the token is opaque this is `cursorAuth/stripeMembershipAuthId` instead.
        let subject: String
        /// True when `accessToken` is not a JWT. Measured 2026-10-31: Cursor now stores a
        /// 603 char token with no dots. The old cookie route answers 401 for it, so a
        /// refusal must say the format changed instead of blaming an expired session.
        var opaqueToken: Bool = false
    }

    static func stateDB(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// One value out of `ItemTable`. Returns nil for a missing row, an unreadable database,
    /// or no Cursor install at all. All three mean the same thing here: this machine has no
    /// Cursor lane, which is a normal state and not an error.
    static func read(_ key: String, db: URL) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // -readonly so a poll can never write, migrate or lock the database Cursor is using.
        p.arguments = ["-readonly", db.path,
                       "select value from ItemTable where key='\(key)' limit 1;"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func identity(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> Identity? {
        let db = stateDB(home: home)
        guard let token = read("cursorAuth/accessToken", db: db) else { return nil }
        // A JWT names its own subject. An opaque token does not, so fall back to the
        // membership auth id the same db stores. Returning nil here for an opaque token is
        // what hid the 2026-10-23 format change: the row aged with no error at all.
        let claims = CodexAuth.decodeJWTPayload(token)
        let opaque = claims == nil
        let claimed = (claims?["sub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let subject = claimed ?? read("cursorAuth/stripeMembershipAuthId", db: db),
              !subject.isEmpty
        else { return nil }
        // The cached email can lag a re-login, so the subject is what identifies the row and
        // the email is only a label. Falling back to the subject keeps the row addressable
        // rather than dropping it for want of a display string.
        let email = read("cursorAuth/cachedEmail", db: db) ?? subject
        return Identity(
            email: email,
            plan: read("cursorAuth/stripeMembershipType", db: db) ?? "?",
            subscriptionStatus: read("cursorAuth/stripeSubscriptionStatus", db: db),
            accessToken: token,
            subject: subject,
            opaqueToken: opaque)
    }

    /// The dashboard's session cookie: `<url-encoded sub>::<jwt>`.
    ///
    /// Verified live 2026-08-18 against cursor.com: this exact composition authenticates
    /// `/api/auth/me`, `/api/usage` and the `/api/dashboard/*` routes. The separator is a
    /// literal "::" percent-encoded as %3A%3A, which is why it is built by hand rather than
    /// by percent-encoding the whole string.
    static func sessionCookie(_ id: Identity) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let sub = id.subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? id.subject
        return "WorkosCursorSessionToken=\(sub)%3A%3A\(id.accessToken)"
    }
}

// MARK: - Cursor usage pools

/// Cursor's two included-usage pools for the current billing cycle.
///
/// ⚠️ UNDOCUMENTED ENDPOINTS, same risk class as `api.anthropic.com/api/oauth/usage` that
/// this app already depends on. This is the route Cursor's own usage dashboard calls; it
/// can change or vanish on any Cursor release. Every failure path below therefore returns a
/// non-`ok` outcome rather than a zero, because a zero bar and "we could not ask" must
/// never render the same way.
///
/// Wire shape VERIFIED LIVE 2026-09-19 against an Ultra account (values invented):
///
///   GET /api/usage-summary
///   {
///     "billingCycleEnd":"2026-10-01T00:00:00.000Z",
///     "membershipType":"ultra",
///     "individualUsage":{"plan":{
///       "autoPercentUsed":41.5,
///       "apiPercentUsed":12.25
///     },"onDemand":{"enabled":false}}
///   }
///
/// `autoPercentUsed` is Cursor Models and `apiPercentUsed` is Other Models. They are
/// separate pools and must stay separate in the row. In particular,
/// `get-aggregated-usage-events.totalCostCents` is the sum of model-rate costs in cents,
/// not a billing charge or either pool's percentage. Dividing it by a plan price produced
/// false readings such as "$2059.10 of $200 used" and 1029.55%.
enum CursorUsage {
    static let host = "https://cursor.com"

    struct Reading: Equatable {
        let email: String
        let plan: String
        /// The two dashboard pool readings. They are usage percentages, never money.
        let cursorModelsPct: Double?
        let otherModelsPct: Double?
        /// When the dashboard says the current billing cycle rolls over.
        let periodResetsAt: Date?

        /// The ranker has one primary field. It can safely rank a Cursor seat only if both
        /// independently-enforced pools were read, and then the tighter pool wins.
        var bindingPct: Double? {
            guard let cursorModelsPct = Self.validPct(cursorModelsPct),
                  let otherModelsPct = Self.validPct(otherModelsPct) else { return nil }
            return max(cursorModelsPct, otherModelsPct)
        }

        var validCursorModelsPct: Double? { Self.validPct(cursorModelsPct) }
        var validOtherModelsPct: Double? { Self.validPct(otherModelsPct) }

        private static func validPct(_ value: Double?) -> Double? {
            guard let value, value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }
    }

    /// Mirrors `OpenRouter.Outcome` deliberately: the panel already knows how to tell
    /// "absent" from "refused" from "unreachable", and a second vocabulary for the same
    /// three states would be a second thing to keep straight.
    enum Outcome: Equatable {
        /// No Cursor install, or nobody signed in. The section hides.
        case notConfigured
        /// Cursor is installed and signed in, but the session token was refused. LOUD: this
        /// is the cookie-expiry case, and it must never look like absence or like zero spend.
        case rejected(Int)
        /// Signed in, but the answer did not arrive or did not parse.
        case unavailable
        /// Cursor's state holds a login but Tower could not build an identity from it (an
        /// opaque token and no stored subject, so no honest session cookie). Its own case,
        /// NOT `.notConfigured`: that one means "no Cursor lane here" and the store leaves
        /// the row alone, which is how a stale row aged with no error. This one makes the
        /// store write the reason onto the existing row.
        case identityUnreadable(String)
        case ok(Reading)
    }

    /// True when Cursor's state db holds a login token at all, readable or not.
    static func loginPresent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        CursorAuth.read("cursorAuth/accessToken", db: CursorAuth.stateDB(home: home)) != nil
    }

    static let identityUnreadableReason =
        "Cursor is installed and signed in, but Tower cannot build a session from its stored login: "
        + "the token is not a JWT and no membership auth id is stored. Usage is unreadable."

    /// The reason text a refused read leaves on the row. An opaque token is sent as a
    /// bearer to the editor's own route (`fetchBearer`), which accepts that shape, so a
    /// refusal there means the session itself was refused. The text still names the token
    /// kind so a refusal is never mistaken for the old cookie-route format problem.
    static func refusedError(code: Int, opaqueToken: Bool) -> String {
        if opaqueToken {
            return "Cursor session refused (HTTP \(code)) on the editor usage route; the stored "
                + "token is not a JWT. Sign in again in Cursor to refresh it."
        }
        return "Cursor session refused (HTTP \(code)). "
            + "Sign in again in Cursor to refresh it."
    }

    private static func request(_ path: String, cookie: String, body: [String: Any]?)
        -> URLRequest? {
        guard let url = URL(string: host + path) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(UsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let body else { return req }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without this the route answers 403 "Invalid origin for state-changing request",
        // even though every call here is a read. See the type comment.
        req.setValue(host, forHTTPHeaderField: "Origin")
        req.setValue(host + "/dashboard", forHTTPHeaderField: "Referer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Body, or the outcome that explains why there is none.
    ///
    /// Not `Result<Data, Outcome>`: that needs `Outcome: Error`, and `Outcome` is a
    /// UI-facing state (it includes `.ok`), not an error type. Bending it into `Error`
    /// conformance to satisfy `Result` would misdescribe what it is.
    private enum Fetched {
        case body(Data)
        case failed(Outcome)
    }

    /// A refusal is the one case that must never look like absence, so it is reported
    /// separately from every other non-200.
    private static func send(_ req: URLRequest) async -> Fetched {
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return .failed(.unavailable) }
        // 307 is what an unauthenticated call gets: the dashboard bounces it to the login
        // page. Treated as a refusal, because that is exactly what it is.
        if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 307 {
            return .failed(.rejected(http.statusCode))
        }
        guard (200..<300).contains(http.statusCode) else { return .failed(.unavailable) }
        return .body(data)
    }

    struct Summary: Decodable {
        struct IndividualUsage: Decodable {
            struct Plan: Decodable {
                let autoPercentUsed: Double?
                let apiPercentUsed: Double?
            }
            let plan: Plan?
        }

        let billingCycleEnd: String?
        let membershipType: String?
        let individualUsage: IndividualUsage?
    }

    static func fetch(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      now: Date = Date()) async -> Outcome {
        guard let id = CursorAuth.identity(home: home) else {
            // A login that exists but cannot be turned into an identity is a failure to
            // read, not the absence of Cursor.
            return loginPresent(home: home) ? .identityUnreadable(identityUnreadableReason)
                                            : .notConfigured
        }
        if id.opaqueToken { return await fetchBearer(id, now: now) }
        let cookie = CursorAuth.sessionCookie(id)

        guard let usageReq = request("/api/usage-summary", cookie: cookie, body: nil)
        else { return .unavailable }

        let data: Data
        switch await send(usageReq) {
        case .failed(let outcome): return outcome
        case .body(let d): data = d
        }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            return .unavailable
        }
        let plan = summary.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dashboardPlan = plan.flatMap { $0.isEmpty ? nil : $0 } ?? id.plan
        let reset = DateParse.parse(summary.billingCycleEnd).flatMap { $0 > now ? $0 : nil }
        return .ok(Reading(email: id.email, plan: dashboardPlan,
                           cursorModelsPct: summary.individualUsage?.plan?.autoPercentUsed,
                           otherModelsPct: summary.individualUsage?.plan?.apiPercentUsed,
                           periodResetsAt: reset))
    }

    // MARK: Bearer route (opaque token)

    /// The route the Cursor editor itself calls for the current period. Since 2026-10-23
    /// Cursor stores an opaque access token that the dashboard cookie route refuses; the
    /// editor sends that same token as a bearer to this Connect RPC.
    ///
    /// ⚠️ UNDOCUMENTED, same risk class as the dashboard route. Measured 2026-11-03 with no
    /// credentials: POST answers 401 `ERROR_NOT_LOGGED_IN` (the route exists; a missing one
    /// answers 404). The authenticated reply shape is NOT yet verified, so `parseBearer`
    /// reads the pool percentages from the top level or from `planUsage`, and an unknown
    /// shape is logged (keys only) and reported as unavailable, never as zero.
    static let bearerURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    static func bearerRequest(token: String) -> URLRequest {
        var req = URLRequest(url: bearerURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(UsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.httpBody = Data("{}".utf8)
        return req
    }

    struct BearerReading: Equatable {
        let plan: String?
        let cursorModelsPct: Double?
        let otherModelsPct: Double?
        let periodResetsAt: Date?
    }

    /// Reads a GetCurrentPeriodUsage reply. Returns nil when neither pool percentage is
    /// present anywhere it looks, so the caller can log the shape instead of rendering 0 %.
    static func parseBearer(_ data: Data) -> BearerReading? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let plan = top["planUsage"] as? [String: Any]
        func number(_ key: String) -> Double? {
            for source in [plan, top] {
                if let n = source?[key] as? NSNumber { return n.doubleValue }
                if let s = source?[key] as? String, let d = Double(s) { return d }
            }
            return nil
        }
        let auto = number("autoPercentUsed")
        let api = number("apiPercentUsed")
        guard auto != nil || api != nil else { return nil }
        let membership = (top["membershipType"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return BearerReading(plan: membership, cursorModelsPct: auto, otherModelsPct: api,
                             periodResetsAt: cycleDate(top["billingCycleEnd"]))
    }

    /// Connect encodes int64 as a JSON string, so the cycle end can arrive as ISO text,
    /// epoch milliseconds in a string, or a bare number.
    static func cycleDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            if let ms = Double(s) { return Date(timeIntervalSince1970: ms / 1000) }
            return DateParse.parse(s)
        }
        if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        return nil
    }

    static func fetchBearer(_ id: CursorAuth.Identity, now: Date) async -> Outcome {
        let data: Data
        switch await send(bearerRequest(token: id.accessToken)) {
        case .failed(let outcome): return outcome
        case .body(let d): data = d
        }
        guard let parsed = parseBearer(data) else {
            if let shape = UsageShape.describe(data) {
                UsageShape.logger.notice(
                    "cursor bearer reply without pool percentages: \(shape, privacy: .public)")
            }
            return .unavailable
        }
        let reset = parsed.periodResetsAt.flatMap { $0 > now ? $0 : nil }
        return .ok(Reading(email: id.email, plan: parsed.plan ?? id.plan,
                           cursorModelsPct: parsed.cursorModelsPct,
                           otherModelsPct: parsed.otherModelsPct,
                           periodResetsAt: reset))
    }

    /// Fold a reading into a snapshot, the way `CodexReader.apply` does.
    ///
    /// The percentage lands in `weeklyPct` because that is the field every existing
    /// consumer already reads: trust, effective, ranking, resting and thresholds all work
    /// unchanged. Cursor's row renders the named scopes directly, while `weeklyPct` stays
    /// the conservative aggregate for ranking. `fiveHourPct` stays nil because Cursor has
    /// no five-hour window.
    ///
    static func apply(_ reading: Reading, to snap: inout AccountSnapshot, now: Date = Date()) {
        snap.provider = .cursor
        snap.plan = reading.plan
        snap.fiveHourPct = nil
        snap.fiveHourResetsAt = nil
        snap.weeklyPct = reading.bindingPct
        snap.weeklyResetsAt = reading.periodResetsAt
        snap.scoped = [
            ScopedLimit(label: "Cursor Models", percent: reading.validCursorModelsPct,
                        resetsAt: reading.periodResetsAt),
            ScopedLimit(label: "Other Models", percent: reading.validOtherModelsPct,
                        resetsAt: reading.periodResetsAt)
        ]
        snap.capturedAt = now
        snap.lastError = reading.bindingPct == nil
            ? "Cursor did not return two valid dashboard pool percentages"
            : nil
        // Model-rate costs are neither billable spend nor a usage-pool balance. Do not
        // preserve the old synthetic dollars when a fresh dashboard reading arrives.
        snap.creditBalance = nil
    }
}

// MARK: - Cursor pool meaning

/// What the two Cursor pools MEAN to a lane, as opposed to what the dashboard calls them.
///
/// Operator report 2026-09-22 (not re-measured here): the pool that sits at 97 to 100 %
/// is the METERED one, "Other Models" (`apiPercentUsed`), which is where Opus runs.
/// Cursor Auto is unmetered and keeps running when that pool is full. The dashboard names
/// ("Cursor Models", "Other Models") hid that, and conductors twice read a full metered
/// pool as a dead Cursor seat. The stored labels stay the dashboard's, since the mirror
/// and the store key on them; only what a person reads changes.
enum CursorPool {
    static let autoLabel = "Cursor Models"
    static let meteredLabel = "Other Models"

    /// What the panel and the CLI print for a stored pool label.
    static func displayLabel(_ stored: String) -> String {
        switch stored {
        case autoLabel: return "Auto unmetered"
        case meteredLabel: return "Opus metered"
        default: return stored
        }
    }

    /// The seat board's stacked meter has a five character label column at the panel v2
    /// type size; the pool keeps its lane meaning there as "Auto" and "Opus", and the row's
    /// tooltip carries `displayLabel`.
    static func boardLabel(_ stored: String) -> String {
        switch stored {
        case autoLabel: return "Auto"
        case meteredLabel: return "Opus"
        default: return stored
        }
    }

    /// A pool's stored, reset-aware reading, live or not. For the resting reason, which
    /// describes rows of any age; presence claims use `meteredPct` instead.
    static func poolPct(_ snap: AccountSnapshot, _ label: String, now: Date = Date()) -> Double? {
        guard snap.kind == .cursor, let pool = snap.scoped.first(where: { $0.label == label })
        else { return nil }
        return AccountSnapshot.effective(pct: pool.percent, resetsAt: pool.resetsAt, now: now).pct
    }

    /// Whether the Auto pool is below the cap. Unknown counts as open: the operator's
    /// word is that Auto is unmetered, and only a measured full Auto pool overrides it.
    static func autoOpen(_ snap: AccountSnapshot, now: Date = Date()) -> Bool {
        (poolPct(snap, autoLabel, now: now) ?? 0) < AccountSnapshot.cappedPct
    }

    /// The metered pool's live, reset-aware reading, nil when not live.
    static func meteredPct(_ snap: AccountSnapshot, now: Date = Date()) -> Double? {
        guard snap.kind == .cursor,
              let pool = snap.scoped.first(where: { $0.label == meteredLabel }),
              AccountSnapshot.trust(pct: pool.percent, resetsAt: pool.resetsAt,
                                    capturedAt: snap.capturedAt, now: now) == .live
        else { return nil }
        return AccountSnapshot.effective(pct: pool.percent, resetsAt: pool.resetsAt, now: now).pct
    }

    /// Whether Opus (and every other metered model) is being refused on this seat.
    static func opusRefused(_ snap: AccountSnapshot, now: Date = Date()) -> Bool {
        (meteredPct(snap, now: now) ?? 0) >= AccountSnapshot.cappedPct
    }

    /// Cursor answers a lane that asks for a metered model on a full pool with
    /// "switch to a different model to continue with Opus". That refusal is not written
    /// anywhere on disk (searched ~/.cursor including 931 chat stores touched 2026-09-22,
    /// Cursor's logs or a dispatch ledger), so Tower flags it from the measured pool instead:
    /// the lane is told before it hits the wall, and told that Auto still runs.
    static func laneFlag(_ snap: AccountSnapshot?, laneModel: String?,
                         now: Date = Date()) -> String? {
        guard let snap, opusRefused(snap, now: now) else { return nil }
        let pct = Int((meteredPct(snap, now: now) ?? 100).rounded())
        let pinnedAuto = laneModel?.lowercased() == "auto"
        let head = "Opus pool at \(pct) %: lanes asking for Opus get "
            + "\"switch to a different model to continue with Opus\""
        guard autoOpen(snap, now: now) else { return head + "; the Auto pool is full too" }
        return pinnedAuto ? head + "; this lane runs Auto, which is unmetered"
                          : head + "; run them on Auto, which is unmetered"
    }
}

// MARK: - Agent lanes (Muse, Devin, Antigravity)

/// Rows for the three agent CLIs whose usage is NOT exposed anywhere this app can read.
///
/// Measured 2026-09-16 on a development machine, read-only, before a line of this existed:
///
///   devin 3000.10.27  The TUI's "% remaining" banner is fetched by a GetUserStatus call (the
///                     string and the RPC name are both in the binary) and is never written
///                     to disk. What IS on disk is a `QuotaExhausted(message=...)` line in
///                     ~/.local/share/devin/cli/logs whenever a call is refused.
///   muse 1.3.0        No usage or stats command. Its local tracing log records the terminal
///                     state of every model stream, including `reason="rate_limited"
///                     http_status=429` (a small share of terminal events in one sample).
///   agy 1.2.4         Has `/usage` and `/quota` in the TUI, backed by a
///                     RetrieveUserQuotaSummary call, but its logs record only
///                     "doRefreshQuota: starting reload", never a value.
///
/// So these rows show what IS observable, under a header that says "usage not exposed": the
/// model pin, the last ledger dispatch (optional), and the last limit refusal where the tool records one.
/// They never carry a percentage. They are also never written into the shared quota store: a
/// row with no usage evidence in `quota-cache.json` would read as headroom to the dispatcher
/// that routes on that file, which is the exact false signal this app exists to prevent.
///
/// Everything here is a bounded file read. No process is spawned and nothing touches the
/// network, so a refresh can neither disturb a running agent nor spend its quota.
enum AgentLane {
    /// Display order in the panel. cursor is in here for its CLI lane (the agent the
    /// dispatch ledgers record as kind "cursor"); the Cursor IDE's subscription spend is
    /// a separate provider row above, so the panel shows both sides of the same seat.
    /// Pi is last: it is the one lane whose row is money rather than a quota.
    static let lanes: [Provider] = [.muse, .devin, .cursor, .agy, .pi]

    /// How far back the Devin log scan reaches: seven days. The quota window the refusal
    /// names is one day, so anything older cannot be the present state, and the log
    /// directory keeps every past session's file, so a count bound (the four newest
    /// mtimes of 250 files) silently skipped logs that carried the only refusal.
    static let logScanWindow: TimeInterval = 7 * 86400

    /// What a lane's own files can answer about its usage, without spending anything
    /// to ask. The seat's own numbers go in the section body; this is the summary.
    enum UsageRead: Equatable {
        /// The tool records its own quota on disk and Tower read it.
        case quota(Quota)
        /// A usage surface exists but nothing readable answers it today.
        case notReadable(String)
        /// The tool does not expose usage at all.
        case notExposed
        /// The tool records what it spent (Pi's per-turn USD cost), summed by `PiLane`.
        case spend(PiLane.Spend)
    }

    /// A lane's usage as the tool itself recorded it. Percents are REMAINING, the way
    /// the CLIs print them ("50% remaining"), not the used percents the provider rows
    /// draw. `fetchedAt` is when the tool last refreshed its own status, so the panel
    /// can say how old the number is instead of dressing it as live.
    struct Quota: Equatable {
        let plan: String?
        let dailyRemainingPct: Double?
        let weeklyRemainingPct: Double?
        let dailyResetsAt: Date?
        let weeklyResetsAt: Date?
        let fetchedAt: Date?
        /// What the SHORT window is called. Devin's refusal names a daily window, Muse's
        /// output just says "window"; neither is a 5h window, so the name travels with the
        /// numbers instead of being guessed by whoever reads them.
        var shortLabel: String = "Daily"
        /// How Tower got the numbers: "live" (asked the tool just now, `muse usage`) or
        /// "cache" (the tool's own cached status, aged by `fetchedAt`).
        var source: String = "cache"

        /// The tighter of the two windows, for the header. Nil when neither is known.
        var bindingRemainingPct: Double? {
            [dailyRemainingPct, weeklyRemainingPct].compactMap { $0 }.min()
        }
    }

    /// The section header for lanes that read nothing. Stated, never left for the
    /// reader to notice.
    static let headerDetail = "usage not exposed"

    /// Per-reading header detail: a real quota earns its tightest remaining percent.
    static func headerDetail(_ r: Reading) -> String {
        switch r.usage {
        case .quota(let q):
            let plan = q.plan.map { "\($0) · " } ?? ""
            if let pct = q.bindingRemainingPct {
                return "\(plan)\(Int(pct.rounded()))% left"
            }
            return "\(plan)usage on file"
        case .notReadable: return "usage not readable"
        case .notExposed: return headerDetail
        case .spend(let s): return "\(PiLane.money(s.monthUSD)) this month"
        }
    }

    /// The body line for the usage reading, or nil when the lane exposes nothing and
    /// the header already says so. A `notReadable` always carries its reason: the
    /// panel's standing rule is "not readable, reason", never a fake number.
    static func usageLine(_ r: Reading) -> String? {
        switch r.usage {
        case .notExposed: return nil
        case .notReadable(let why): return "not readable: \(why)"
        case .spend(let s): return PiLane.spendLine(s)
        case .quota(let q):
            var parts: [String] = []
            if let d = q.dailyRemainingPct {
                parts.append("daily \(Int(d.rounded()))% left"
                    + (q.dailyResetsAt.map { ", resets \(CLI.clock($0))" } ?? ""))
            }
            if let w = q.weeklyRemainingPct {
                parts.append("weekly \(Int(w.rounded()))% left"
                    + (q.weeklyResetsAt.map { ", resets \(CLI.clock($0))" } ?? ""))
            }
            if parts.isEmpty { return nil }
            return parts.joined(separator: " · ")
        }
    }

    /// A second usage line for a stale status, so a quota the CLI fetched hours ago is
    /// labelled as such rather than posed as live. Fresh statuses get no extra text.
    static func usageAgeLine(_ r: Reading, now: Date) -> String? {
        guard case .quota(let q) = r.usage, let fetched = q.fetchedAt,
              now.timeIntervalSince(fetched) > 3600 else { return nil }
        return "status fetched \(CLI.age(fetched, now: now))"
    }

    struct Dispatch: Equatable {
        let model: String?
        let at: Date
    }

    struct LimitHit: Equatable {
        let at: Date
        /// Short, panel-sized: "daily quota exhausted", "rate limited (HTTP 429)".
        let summary: String
        /// What the tool itself wrote, for the tooltip.
        let message: String
    }

    struct Reading: Equatable {
        let provider: Provider
        /// The model the tool's own config selects, nil when the config names none.
        let configModel: String?
        /// Newest ledger dispatch of this lane, nil when no ledger recorded one.
        let lastDispatch: Dispatch?
        /// Newest limit refusal the tool recorded, nil when none was seen.
        let lastLimitHit: LimitHit?
        /// What the lane's own files could say about its usage.
        let usage: UsageRead

        init(provider: Provider, configModel: String?, lastDispatch: Dispatch?,
             lastLimitHit: LimitHit?, usage: UsageRead = .notExposed) {
            self.provider = provider
            self.configModel = configModel
            self.lastDispatch = lastDispatch
            self.lastLimitHit = lastLimitHit
            self.usage = usage
        }

        /// The ledger's dispatch pin wins over the config default: it is the model a dispatched
        /// worker actually ran on, and dispatch is how these lanes get used here.
        var modelPin: String? { lastDispatch?.model ?? configModel }
    }

    /// Mirrors the Cursor and OpenRouter outcomes, minus `rejected`: nothing here asks a
    /// server, so nothing can be refused.
    enum Outcome: Equatable {
        /// The CLI is not installed. The section hides.
        case notConfigured
        /// Installed, but its config file exists and did not parse. Shown, never hidden.
        case unavailable(String)
        case ok(Reading)
    }

    // MARK: Where each lane lives

    /// The installers put all three here. PATH is not consulted on purpose: a login-item app
    /// does not inherit the shell's PATH, so `which` would disagree with the terminal.
    static func binary(_ lane: Provider, home: URL) -> URL {
        home.appendingPathComponent(".local/bin/\(lane.rawValue)")
    }

    static func configFile(_ lane: Provider, home: URL) -> URL? {
        switch lane {
        case .devin:  return home.appendingPathComponent(".config/devin/config.json")
        case .muse:   return home.appendingPathComponent(".config/muse/settings.json")
        case .cursor: return home.appendingPathComponent(".cursor/cli-config.json")
        // ~/.gemini/antigravity-cli/settings.json holds only trusted workspaces. agy has no
        // model default on disk; its pin comes from the dispatch ledger alone.
        default:      return nil
        }
    }

    /// The `kind` a dispatch ledger records for each lane. agy is recorded as "gemini":
    /// dispatchers that launch it prefer the agy binary over the OSS Gemini CLI.
    static func ledgerKind(_ lane: Provider) -> String {
        lane == .agy ? "gemini" : lane.rawValue
    }

    /// Settings key for the optional dispatch ledger directory.
    static let dispatchLedgerDirectoryKey = "dispatchLedgerDirectory"

    /// Optional integration: a directory holding `dispatch-worktrees.jsonl` and
    /// `lanes.jsonl`, the ledgers a dispatcher (for example a herdr plugin) writes when it
    /// opens an agent lane. Tower only reads them. Named by `TOWER_DISPATCH_LEDGER_DIR`,
    /// herdr's own `HERDR_PLUGIN_STATE_DIR`, or the `dispatchLedgerDirectory` setting, in
    /// that order. With none set there is no ledger and the lane rows say so; Tower never
    /// guesses a path.
    static func dispatchLedgerDirectory(home: URL, env: [String: String],
                                        defaults: UserDefaults = TowerPreferences.shared) -> URL? {
        for key in ["TOWER_DISPATCH_LEDGER_DIR", "HERDR_PLUGIN_STATE_DIR"] {
            if let dir = env[key], !dir.isEmpty {
                return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            }
        }
        if let dir = defaults.string(forKey: dispatchLedgerDirectoryKey), !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return nil
    }

    // MARK: Parsers (pure, fixture-tested)

    struct ConfigUnreadable: Error {}

    /// The model a lane's own config selects. Throws only when the file is not a JSON
    /// object at all; a valid file that names no model is a normal nil.
    static func configModel(_ lane: Provider, data: Data) throws -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ConfigUnreadable() }
        let raw: Any?
        switch lane {
        case .devin:  raw = (root["agent"] as? [String: Any])?["model"]
        case .muse:   raw = root["model"]
        case .cursor: raw = (root["model"] as? [String: Any])?["displayModelId"]
        default:      raw = nil
        }
        guard let model = raw as? String, !model.isEmpty else { return nil }
        return model
    }

    /// Newest dispatch per `kind` from a dispatcher's `dispatch-worktrees.jsonl`.
    ///
    /// Line by line and lenient: the ledger is append-only and best-effort on the writer's
    /// side, so one torn line must cost that line and not the lane.
    static func newestDispatches(ledger: String) -> [String: Dispatch] {
        var newest: [String: Dispatch] = [:]
        for line in ledger.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = row["kind"] as? String,
                  let created = row["created_at"] as? Double
            else { continue }
            let model = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let at = Date(timeIntervalSince1970: created)
            if let seen = newest[kind], seen.at >= at { continue }
            newest[kind] = Dispatch(model: model, at: at)
        }
        return newest
    }

    /// Newest lane entry per `kind` from a dispatcher's `lanes.jsonl`.
    ///
    /// Not every dispatch lands in `dispatch-worktrees.jsonl`: lanes the conveyor opens
    /// for the devin harness are recorded here instead, which is exactly why the Devin
    /// row used to read "no dispatch recorded" on a day seven devin lanes ran.
    /// The shape differs (`lane` not `worktree`, ISO `opened_at` not epoch `created_at`),
    /// so it gets its own parse; a torn line costs that line, same as the other ledger.
    static func newestLaneEntries(ledger: String) -> [String: Dispatch] {
        var newest: [String: Dispatch] = [:]
        for line in ledger.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = row["kind"] as? String,
                  let opened = row["opened_at"] as? String,
                  let at = DateParse.parse(opened)
            else { continue }
            // A closed lane is still a dispatch that happened; `closed_at` is ignored on
            // purpose, the line asks when the lane last STARTED, not when it last ended.
            let model = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let seen = newest[kind], seen.at >= at { continue }
            newest[kind] = Dispatch(model: model, at: at)
        }
        return newest
    }

    /// One decoded protobuf field. `varint` and `bytes` cover the wire types Tower
    /// needs; fixed32/64 payloads arrive as `bytes` too and are simply not read here.
    struct ProtoField {
        let number: Int
        let varint: UInt64?
        let bytes: Data?
    }

    /// The top-level fields of one protobuf message. Just enough wire format to walk to
    /// the few numbers Devin caches; pulling in a protobuf dependency for that is out of
    /// proportion. A field the reader cannot step over ends the parse early rather than
    /// failing the whole message: a field added by a newer CLI must not blank the lane.
    static func protoFields(_ data: Data) -> [ProtoField] {
        var fields: [ProtoField] = []
        var i = data.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]
                i = data.index(after: i)
                value |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
                guard shift < 64 else { return nil }
            }
            return nil
        }
        while i < data.endIndex {
            guard let tag = varint() else { break }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let v = varint() else { return fields }
                fields.append(ProtoField(number: number, varint: v, bytes: nil))
            case 2:
                guard let len = varint(), data.distance(from: i, to: data.endIndex) >= Int(len)
                else { return fields }
                let end = data.index(i, offsetBy: Int(len))
                fields.append(ProtoField(number: number, varint: nil, bytes: data[i..<end]))
                i = end
            case 1, 5:
                let width = tag & 7 == 1 ? 8 : 4
                guard data.distance(from: i, to: data.endIndex) >= width else { return fields }
                let end = data.index(i, offsetBy: width)
                fields.append(ProtoField(number: number, varint: nil, bytes: data[i..<end]))
                i = end
            default:
                return fields
            }
        }
        return fields
    }

    /// Devin's GetUserStatus answer, which its CLI writes to
    /// `~/.cache/devin/cli/user_status.<identity>.bin` on every session start and on
    /// each user_status_refresh. The file is JSON: `payload` is base64 protobuf and
    /// `fetched_at_secs` says when the CLI last refreshed it. Field numbers verified
    /// read-only 2026-09-17 against the shipped binary (exa.seat_management_pb):
    /// response field 13 is plan_status; inside it 1 is plan info (field 2 the plan
    /// name), 14 the daily remaining percent, 15 the weekly, 17 and 18 the two reset
    /// unix stamps. Percents outside 0...100 mean the schema moved, so they are
    /// dropped rather than shown.
    static func devinUserStatus(data: Data) -> Quota? {
        struct Envelope: Decodable {
            let fetched_at_secs: Double?
            let payload: String
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = Data(base64Encoded: env.payload),
              let statusBytes = protoFields(payload).last(where: { $0.number == 13 })?.bytes
        else { return nil }
        let status = protoFields(statusBytes)
        func pct(_ n: Int) -> Double? {
            guard let v = status.last(where: { $0.number == n })?.varint, v <= 100
            else { return nil }
            return Double(v)
        }
        func stamp(_ n: Int) -> Date? {
            status.last(where: { $0.number == n })?.varint
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        }
        let plan = status.last(where: { $0.number == 1 })?.bytes
            .flatMap { protoFields($0).last(where: { $0.number == 2 })?.bytes }
            .flatMap { String(data: $0, encoding: .utf8) }
        let daily = pct(14), weekly = pct(15)
        guard daily != nil || weekly != nil else { return nil }
        return Quota(plan: plan, dailyRemainingPct: daily, weeklyRemainingPct: weekly,
                     dailyResetsAt: stamp(17), weeklyResetsAt: stamp(18),
                     fetchedAt: env.fetched_at_secs.flatMap {
                         $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
    }

    /// The newest file under `dir` whose name starts with `prefix` and ends with
    /// `suffix`, by modification time. Same bounded-read rule as the log scans.
    static func newestFile(in dir: URL, prefix: String, suffix: String) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .map { dir.appendingPathComponent($0) }
            .max { a, b in
                (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                    < (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
            }
    }

    /// Newest `QuotaExhausted` refusal in a Devin log.
    ///
    /// Real line, 2026-09-15:
    ///   2026-09-15T14:43:07.856767Z  WARN agent_ext::title: Title generation failed:
    ///   QuotaExhausted(message=Your daily usage quota has been exhausted. Visit ... (trace ID: ...))
    ///
    /// Devin logs refusals and not successes, so "the newest refusal" is all a log can say.
    /// The row prints its age and lets the reader weigh it against a daily reset.
    static func devinQuotaExhaustion(log: String) -> LimitHit? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let open = line.range(of: "QuotaExhausted(message=") else { continue }
            guard let stamp = line.split(separator: " ", maxSplits: 1).first,
                  let at = DateParse.parse(String(stamp))
            else { continue }
            var message = String(line[open.upperBound...])
            if let trace = message.range(of: " (trace ID:") {
                message = String(message[..<trace.lowerBound])
            } else if message.hasSuffix(")") {
                message.removeLast()
            }
            let summary = message.localizedCaseInsensitiveContains("daily")
                ? "daily quota exhausted" : "quota exhausted"
            return LimitHit(at: at, summary: summary, message: message)
        }
        return nil
    }

    /// The CURRENT rate-limit state from a Muse tracing log, or nil when it is not limited.
    ///
    /// Muse logs every stream's terminal state, successes included, so unlike Devin the log
    /// can say whether a refusal is still the present. Only the NEWEST terminal event counts:
    /// a 429 that a later stream got past is history (Muse retries up to `max_attempts=10`),
    /// and surfacing it would flag a lane that is working.
    ///
    /// Real line, 2026-09-16:
    ///   2026-09-16T07:01:17.807381Z INFO tbh.local.provider ... event="provider_stream.terminal"
    ///   provider="meta" terminal="failed" reason="rate_limited" attempt=1 max_attempts=10
    ///   has_http_status=true http_status=429 ...
    ///
    /// Returns `.some(nil)` when the log has a terminal event and it is not a limit, and nil
    /// when the log has no terminal event at all, so the caller knows to look at an older file.
    static func museRateLimit(log: String) -> LimitHit?? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("event=\"provider_stream.terminal\"") else { continue }
            guard field("reason", in: line) == "rate_limited",
                  let stamp = line.split(separator: " ", maxSplits: 1).first,
                  let at = DateParse.parse(String(stamp))
            else { return .some(nil) }
            let status = field("http_status", in: line).flatMap { $0 == "0" ? nil : $0 }
            let summary = status.map { "rate limited (HTTP \($0))" } ?? "rate limited"
            return .some(LimitHit(at: at, summary: summary,
                                  message: "Muse model stream failed: \(summary)"))
        }
        return nil
    }

    /// `name=value` or `name="value"` out of a key/value log line.
    static func field(_ name: String, in line: Substring) -> String? {
        let pattern = "(?:^|\\s)\(NSRegularExpression.escapedPattern(for: name))=(\"[^\"]*\"|\\S+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let s = String(line)
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // MARK: Panel text (pure, so the wording is tested rather than eyeballed)

    static func modelLine(_ r: Reading) -> String {
        if case .spend(let s) = r.usage { return PiLane.modelLine(s) }
        return r.modelPin.map { "model \($0)" } ?? "no model pinned"
    }

    static func dispatchLine(_ r: Reading, now: Date) -> String {
        // Pi's own log says when it last ran, which beats any ledger.
        if case .spend(let s) = r.usage {
            return s.newest.map { "last turn \(CLI.age($0, now: now))" } ?? "no turn this month"
        }
        guard let d = r.lastDispatch else { return "no dispatch recorded" }
        return "last dispatch \(CLI.age(d.at, now: now))"
    }

    static func limitLine(_ hit: LimitHit, now: Date) -> String {
        "\(hit.summary) \(CLI.age(hit.at, now: now))"
    }

    /// A refusal that no longer describes the lane, kept as history so the reader still
    /// learns the lane was refused, without an orange flag that reads as "refused now".
    /// The lane's meters for the panel's braille line, as USED percents (the CLIs print
    /// remaining): Devin's day and week from its own status, the Cursor CLI lane's Auto and
    /// Opus pools from the Cursor seat. Empty when the lane exposes nothing to draw.
    /// `age` is nil only while the reading is live; a stale meter draws dimmed beside its
    /// age so it never passes for a current figure (review of #126).
    struct Meter: Equatable {
        let label: String
        let usedPct: Double
        var age: String? = nil
    }

    static func meters(_ r: Reading, cursorSeat: AccountSnapshot?, now: Date) -> [Meter] {
        switch r.provider {
        case .cursor:
            guard let seat = cursorSeat else { return [] }
            let age = seat.worstTrust(now: now) == .live ? nil : CLI.age(seat.capturedAt, now: now)
            return [(CursorPool.autoLabel, "Auto"), (CursorPool.meteredLabel, "Opus")]
                .compactMap { stored, label in
                    CursorPool.poolPct(seat, stored, now: now)
                        .map { Meter(label: label, usedPct: $0, age: age) }
                }
        default:
            guard case .quota(let q) = r.usage else { return [] }
            // The same line the usage text uses: a status older than an hour is old.
            let age = q.fetchedAt.flatMap { fetched in
                now.timeIntervalSince(fetched) > 3600 ? CLI.age(fetched, now: now) : nil
            } ?? (q.fetchedAt == nil ? "age unknown" : nil)
            return [("day", q.dailyRemainingPct), ("week", q.weeklyRemainingPct)]
                .compactMap { label, remaining in
                    remaining.map { Meter(label: label, usedPct: max(0, 100 - $0), age: age) }
                }
        }
    }

    static func pastLimitLine(_ hit: LimitHit, now: Date) -> String {
        "earlier: \(limitLine(hit, now: now))"
    }

    /// How long a past refusal stays on the panel as dim history. Past a day it no longer
    /// helps anyone choose a lane, and "earlier: rate limited (HTTP 429) 3d ago" read as a
    /// live problem (bug d, 2026-09-30). The CLI and MCP keep reporting the record.
    static let historyHorizon: TimeInterval = 86_400

    /// Whether the panel shows `pastLimitLine` for a refusal that is no longer current.
    static func showsPastLimit(_ hit: LimitHit, now: Date) -> Bool {
        now.timeIntervalSince(hit.at) < historyHorizon
    }

    // MARK: Is a recorded refusal still the present?

    /// How long a refusal counts as the present when the lane publishes no reset of its
    /// own. Muse is that lane. Measured 2026-09-27 over every Muse tracing log on this
    /// machine (564 terminal stream events, 27 of them HTTP 429, in 8 per-session
    /// bursts): every burst that saw a later stream was cleared by that stream, and the
    /// longest run of 429s with no success between spanned 52 minutes. Two hours covers
    /// that with room. Past it, the newest event says the lane went quiet while
    /// throttled, which is history, not the state a dispatch would meet now.
    static let throttleHorizon: TimeInterval = 2 * 3600

    /// Devin's refusal names a daily quota, so without a status to place it, a day is
    /// the longest it can describe the present.
    static let dailyHorizon: TimeInterval = 86_400

    /// Whether the newest recorded refusal still describes the lane now.
    ///
    /// The lane's own reset wins when the lane reports one. Devin's cached status
    /// carries the next daily reset, so its current window started one day before that:
    /// a refusal inside that window is current until the reset passes, a refusal from
    /// before it belongs to a window that already reset, and a status the CLI fetched
    /// AFTER the refusal that still shows room overrides the refusal outright. A lane
    /// with no reset of its own falls back to a fixed horizon (`throttleHorizon`, or a
    /// day for Devin's daily quota).
    static func limitIsCurrent(_ r: Reading, now: Date) -> Bool {
        guard let hit = r.lastLimitHit else { return false }
        if case .quota(let q) = r.usage {
            if let fetched = q.fetchedAt, fetched > hit.at,
               let left = q.bindingRemainingPct, left > 0 {
                return false
            }
            if let reset = q.dailyResetsAt {
                let windowStart = reset.addingTimeInterval(-dailyHorizon)
                if hit.at < windowStart { return false }
                if hit.at < reset { return now < reset }
                // The refusal is newer than the window the status knows; age decides.
            }
        }
        let horizon = r.provider == .devin ? dailyHorizon : throttleHorizon
        return now.timeIntervalSince(hit.at) < horizon
    }

    // MARK: The Cursor lane reads its seat

    /// The Cursor CLI lane spends the same seat the Cursor row measures, so its usage is
    /// that seat's two pools, named by what they mean to a lane (Auto unmetered, Opus
    /// metered). Used percents, the way the seat row draws them. A capture older than
    /// the freshness TTL says how old it is instead of passing as live. Nil when no
    /// Cursor seat or no pool is on file.
    static func cursorSeatLine(_ seat: AccountSnapshot?, now: Date) -> String? {
        guard let seat, seat.kind == .cursor else { return nil }
        let pools = [CursorPool.autoLabel, CursorPool.meteredLabel].compactMap { label -> String? in
            CursorPool.poolPct(seat, label, now: now)
                // Truncated like the seat row's meter text, so the two never disagree.
                .map { "\(CursorPool.displayLabel(label)) \(Int($0))%" }
        }
        guard !pools.isEmpty else { return nil }
        var line = "seat \(seat.nickname): \(pools.joined(separator: " · ")) used"
        if AccountSnapshot.trust(pct: 0, resetsAt: nil, capturedAt: seat.capturedAt, now: now) != .live {
            line += ", read \(CLI.age(seat.capturedAt, now: now))"
        }
        return line
    }

    /// The usage line with the Cursor seat folded in: the Cursor lane shows the seat's
    /// pools when a seat is on file, and says why not when none is. Every other lane
    /// reads exactly as `usageLine(_:)`.
    static func usageLine(_ r: Reading, cursorSeat: AccountSnapshot?, now: Date) -> String? {
        guard r.provider == .cursor, case .notReadable = r.usage else { return usageLine(r) }
        return cursorSeatLine(cursorSeat, now: now)
            ?? "not readable: agent quota lives in-session and no Cursor seat is on file"
    }

    /// The header detail with the Cursor seat folded in, same rule as the usage line.
    static func headerDetail(_ r: Reading, cursorSeat: AccountSnapshot?, now: Date) -> String {
        guard r.provider == .cursor, case .notReadable = r.usage,
              let line = cursorSeatLine(cursorSeat, now: now) else { return headerDetail(r) }
        return line
    }

    // MARK: Reading from disk

    /// Matching files in `dir`, newest mtime first. `since` keeps only files modified at
    /// or after that instant; `limit` caps the count when given. Both optional, so one
    /// helper serves "newest few" (Muse) and "everything still current" (Devin).
    static func logFiles(in dir: URL, prefix: String,
                         since: Date? = nil, limit: Int? = nil) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var found = names
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log" }
            .map { url -> (URL, Date) in
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, m)
            }
            .sorted { $0.1 > $1.1 }
        if let since { found = found.filter { $0.1 >= since } }
        if let limit { found = Array(found.prefix(limit)) }
        return found.map(\.0)
    }

    /// The last line of a file that contains `marker`, found by searching the mapped bytes
    /// backwards.
    ///
    /// Not a fixed-size tail. The first version read the last 1 MB and missed the newest
    /// Devin refusal on the operator's machine: it sat 9 MB up a 10 MB log that a live session
    /// was still appending to, so the busiest file was exactly the one a tail under-reports.
    /// Mapping the file costs no copy, and a backwards byte search stops at the first match.
    static func lastLine(containing marker: String, in url: URL) -> Substring? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let hit = data.range(of: Data(marker.utf8), options: .backwards)
        else { return nil }
        let newline = UInt8(ascii: "\n")
        let start = data[..<hit.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
        let end = data[hit.upperBound...].firstIndex(of: newline) ?? data.endIndex
        return Substring(String(decoding: data[start..<end], as: UTF8.self))
    }

    // MARK: Muse, the one lane that answers a read command

    /// Runs `muse usage --json` and returns what it printed. Injected so tests never spawn.
    typealias MuseRunner = (_ binary: URL) -> Data?

    /// `muse usage` is documented as "show your subscription allowance (no model turn)": it
    /// spends nothing. Measured 2026-10-31 from a Claude Code pane, it prints one JSON
    /// object. Its wrapper script also tries to write a `.muse-update-checked-at.tmp` stamp
    /// beside the binary on every run; that is Muse's own update check, not a vendor write,
    /// and a denied write does not change the answer.
    ///
    /// Bounded: eight seconds, then the process is terminated and the lane reads "did not
    /// answer", never a number. stderr is discarded, stdout carries the JSON or the
    /// reason text.
    static func runMuseUsage(binary: URL) -> Data? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["usage", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + (environment["PATH"] ?? "")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return box.data.isEmpty ? nil : box.data
    }

    /// Decode `muse usage --json`. Wire shape VERIFIED LIVE 2026-10-31:
    /// `{"schemaVersion":1,"allowance":{"tier":"...","window":{"usedPercent":0,
    /// "resetsAtMs":...},"weekly":{"usedPercent":1,"resetsAtMs":...},"asOfMs":...,
    /// "source":"mint"},"reason":null,"hint":null}`. Muse reports percent USED; `Quota`
    /// stores REMAINING (the way the CLIs print), so this converts once, here.
    static func museUsage(data: Data) -> UsageRead {
        struct Envelope: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let resetsAtMs: Double?
            }
            struct Allowance: Decodable {
                let tier: String?
                let window: Window?
                let weekly: Window?
                let asOfMs: Double?
            }
            let allowance: Allowance?
            let reason: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            let text = String(decoding: data.prefix(400), as: UTF8.self).lowercased()
            return .notReadable(text.contains("not logged in")
                ? "Muse is not logged in, so `muse usage` cannot answer. Run `muse login` in a terminal."
                : "`muse usage --json` answered something this build cannot decode")
        }
        guard let allowance = envelope.allowance else {
            return .notReadable(envelope.reason.map { "`muse usage` said: \($0)" }
                ?? "`muse usage --json` returned no allowance")
        }
        func remaining(_ window: Envelope.Window?) -> Double? {
            guard let used = window?.usedPercent, used.isFinite, (0...100).contains(used)
            else { return nil }
            return 100 - used
        }
        func reset(_ window: Envelope.Window?) -> Date? {
            window?.resetsAtMs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }
        let short = remaining(allowance.window), long = remaining(allowance.weekly)
        guard short != nil || long != nil else {
            return .notReadable("`muse usage --json` carried no usable percentage")
        }
        return .quota(Quota(
            plan: allowance.tier, dailyRemainingPct: short, weeklyRemainingPct: long,
            dailyResetsAt: reset(allowance.window), weeklyResetsAt: reset(allowance.weekly),
            // asOfMs <= 0 is absent, the same rule resetsAtMs already follows.
            fetchedAt: allowance.asOfMs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil },
            shortLabel: "Window", source: "live"))
    }

    static func read(_ lane: Provider,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     env: [String: String] = ProcessInfo.processInfo.environment,
                     museRunner: MuseRunner? = nil) -> Outcome {
        // Pi is found by its data directory, not a binary: it installs through a package
        // manager whose bin path a login item cannot predict, and its logs are what the
        // row reads anyway.
        if lane == .pi { return PiLane.read(home: home, env: env) }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binary(lane, home: home).path) else {
            return .notConfigured
        }

        var configModel: String?
        if let cfg = configFile(lane, home: home), fm.fileExists(atPath: cfg.path) {
            do {
                configModel = try Self.configModel(lane, data: try Data(contentsOf: cfg))
            } catch {
                return .unavailable("could not read ~/\(cfg.path.dropFirst(home.path.count + 1))")
            }
        }

        let ledgerDir = dispatchLedgerDirectory(home: home, env: env)
        // Two ledgers record a dispatch: worktree dispatches in dispatch-worktrees.jsonl
        // and conveyor-opened lanes in lanes.jsonl. Neither is complete alone (devin lanes
        // only ever reach the second), so the newest of both wins.
        let worktreeDispatch = ledgerDir.flatMap { dir in (try? String(
            contentsOf: dir.appendingPathComponent("dispatch-worktrees.jsonl"),
            encoding: .utf8)).flatMap { newestDispatches(ledger: $0)[ledgerKind(lane)] } }
        let laneDispatch = ledgerDir.flatMap { dir in (try? String(
            contentsOf: dir.appendingPathComponent("lanes.jsonl"),
            encoding: .utf8)).flatMap { newestLaneEntries(ledger: $0)[ledgerKind(lane)] } }
        let dispatch = [worktreeDispatch, laneDispatch].compactMap { $0 }.max { $0.at < $1.at }

        let usage: UsageRead
        switch lane {
        case .devin:
            // GetUserStatus is the seat's own record of its quota, cached by the CLI
            // itself. One file read, no spawn, no token touched.
            let cacheDir = home.appendingPathComponent(".cache/devin/cli")
            if let file = newestFile(in: cacheDir, prefix: "user_status.", suffix: ".bin"),
               let data = try? Data(contentsOf: file) {
                usage = devinUserStatus(data: data).map(UsageRead.quota)
                    ?? .notReadable("the user status cache did not decode")
            } else {
                usage = .notReadable("no user status cache on disk")
            }
        case .muse:
            // Only a caller that passes a runner spawns anything. Every other read of this
            // lane stays a file read and keeps saying "not exposed", so the panel hydration,
            // panelshot and tests never start a process.
            if let run = museRunner {
                if let data = run(binary(.muse, home: home)) {
                    usage = museUsage(data: data)
                } else {
                    usage = .notReadable("`muse usage --json` did not answer (timed out, or no output)")
                }
            } else {
                usage = .notExposed
            }
        case .cursor:
            // cursor-agent has a /usage surface backed by api2 RPCs, but it only answers
            // inside a live session and writes nothing readable to disk. The same seat's
            // subscription spend is on the Cursor provider row, so the lane says where
            // the number lives rather than posing one.
            usage = .notReadable("agent quota lives in-session; the Cursor row reports the same seat")
        default:
            usage = .notExposed
        }

        var hit: LimitHit?
        switch lane {
        case .devin:
            let logs = home.appendingPathComponent(".local/share/devin/cli/logs")
            // Several sessions log in parallel, so the newest refusal can sit in any of
            // them. The directory keeps every past session's log and only grows (250
            // files here), so the bound is time, not a count: scan every log touched in
            // the last seven days, far wider than the one day window the refusal names,
            // and take the newest refusal across the whole set. A refusal older than
            // that cannot be the present state of a daily quota.
            hit = logFiles(in: logs, prefix: "devin_",
                           since: Date().addingTimeInterval(-Self.logScanWindow))
                .compactMap { lastLine(containing: "QuotaExhausted(message=", in: $0) }
                .compactMap { devinQuotaExhaustion(log: String($0)) }
                .max { $0.at < $1.at }
        case .muse:
            let logs = home.appendingPathComponent(".local/share/muse/local-tracing/bootstrap")
            for url in logFiles(in: logs, prefix: "cli-", limit: 3) {
                guard let line = lastLine(containing: "event=\"provider_stream.terminal\"", in: url),
                      let state = museRateLimit(log: String(line))
                else { continue }
                hit = state
                break
            }
        default:
            hit = nil
        }

        return .ok(Reading(provider: lane, configModel: configModel,
                           lastDispatch: dispatch, lastLimitHit: hit, usage: usage))
    }

    static func readAll(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        env: [String: String] = ProcessInfo.processInfo.environment,
                        museRunner: MuseRunner? = nil)
        -> [Provider: Outcome] {
        Dictionary(uniqueKeysWithValues: lanes.map {
            ($0, read($0, home: home, env: env, museRunner: museRunner))
        })
    }

    // MARK: Mirror rows

    /// The lanes that get a row in the shared quota store and its mirror. Cursor is not
    /// here: its CLI lane is the same seat as the Cursor provider row.
    static let mirrorLanes: [Provider] = [.muse, .devin, .agy]

    static func mirrorEmail(_ lane: Provider) -> String { "\(lane.rawValue)@local" }

    /// The quota a lane may publish, or nil. A row is written to the mirror ONLY when it has
    /// a real observation time from the tool (`fetchedAt`) and at least one valid percent.
    /// Platform's Tower snapshot model requires `capturedAt` on every row and validates the
    /// whole file at once, so a single row without one turns every account unknown
    /// (Opus review of #134, apps/api/app/services/factory/sessions.py). An unreadable
    /// lane therefore has NO row: it stays in `tower_lanes` over MCP with its reason, and a
    /// row it had before is removed so an older capture cannot outlive a failed read.
    static func publishableQuota(_ outcome: Outcome) -> Quota? {
        guard case .ok(let reading) = outcome, case .quota(let quota) = reading.usage,
              let observed = quota.fetchedAt,
              // `capturedAt` is stored as seconds since 2001-01-01. A zero or pre-2001 tool
              // time encodes negative, and platform requires capturedAt >= 0 on every row,
              // so it would reject the whole mirror. Such a time is "no time".
              observed.timeIntervalSinceReferenceDate.isFinite,
              observed.timeIntervalSinceReferenceDate >= 0,
              quota.dailyRemainingPct != nil || quota.weeklyRemainingPct != nil
        else { return nil }
        return quota
    }

    /// Fold a lane's own quota into a row. Percent USED, like every other row; the tool
    /// reports REMAINING, so this is the one place it is converted. The short window goes
    /// in `fiveHourPct` and the weekly window in `weeklyPct`, each with its own reset, so
    /// `max(fiveHourPct, weeklyPct)` is the binding window for any reader. The named
    /// windows are repeated in `scoped` because `fiveHourPct` alone cannot say that Devin's
    /// is a day and Muse's just "window". `capturedAt` is when the TOOL observed the
    /// numbers (Devin's cache fetch time, Muse's `asOfMs`), not when Tower looked, so an
    /// old Devin cache reads as old. `readAt` is when Tower looked.
    static func apply(_ quota: Quota, observedAt observed: Date,
                      to snap: inout AccountSnapshot, now: Date) {
        func used(_ remaining: Double?) -> Double? {
            remaining.map { max(0, min(100, 100 - $0)) }
        }
        snap.plan = quota.plan ?? "lane"
        snap.fiveHourPct = used(quota.dailyRemainingPct)
        snap.fiveHourResetsAt = quota.dailyResetsAt
        snap.weeklyPct = used(quota.weeklyRemainingPct)
        snap.weeklyResetsAt = quota.weeklyResetsAt
        var scoped: [ScopedLimit] = []
        if let pct = snap.fiveHourPct {
            scoped.append(ScopedLimit(label: quota.shortLabel, percent: pct,
                                      resetsAt: quota.dailyResetsAt))
        }
        if let pct = snap.weeklyPct {
            scoped.append(ScopedLimit(label: "Weekly", percent: pct,
                                      resetsAt: quota.weeklyResetsAt))
        }
        snap.scoped = scoped
        snap.capturedAt = observed
        snap.source = quota.source
        snap.readAt = now
        snap.lastError = nil
    }
}
