import Foundation

// MARK: - Pi (the `pi` coding agent)

/// Pi's own spend, summed from the session logs Pi writes, beside the OpenRouter balance
/// Tower already reads.
///
/// Unlike the other agent lanes, Pi records what every assistant turn cost. Measured on
/// pi-coding-agent 1.5.0 (its `SessionEntryBase` and `AssistantMessage` type declarations):
///
///   <root>/settings.json                     `defaultProvider`, `defaultModel`
///   <root>/sessions/<project>/<session>.jsonl one JSON object per line. Entries carry
///                                             `id` and `timestamp` (an ISO 8601 string).
///                                             `type: "message"` entries hold `message`,
///                                             and an assistant message carries `provider`,
///                                             `model`, `usage.cost.total` in USD and its own
///                                             `timestamp` in epoch milliseconds.
///   <root>/auth.json                          secrets. Never opened, not even to list keys.
///
/// The entry's ISO `timestamp` places a turn in the month; the message's epoch ms value
/// is the fallback for an entry that lacks it, and either field is accepted in either
/// form so a format change costs precision rather than the row.
///
/// Bounded like every lane read: only session files modified this calendar month, at most
/// `maxFiles` of them, at most the last `maxFileBytes` of each, streamed in chunks and
/// parsed line by line. No process, no network, and nothing here runs on the main actor
/// (the refresh reads lanes on a detached utility task).
enum PiLane {
    /// Root override, so tests and demos never touch the operator's real Pi directory.
    static let rootEnvKey = "TOWER_PI_DIR"

    /// A session that grows past this keeps only its newest bytes in the read. Recent
    /// turns sit at the end of an append-only log, so a tail under-reports old turns of a
    /// giant session instead of stalling the refresh; the row says when that happened.
    static let maxFileBytes = 64 * 1024 * 1024
    /// Newest first, so a month with an unusual number of sessions still sums the recent ones.
    static let maxFiles = 2000
    static let chunkBytes = 1024 * 1024

    static func root(home: URL, env: [String: String]) -> URL {
        if let dir = env[rootEnvKey], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".pi/agent")
    }

    // MARK: What the row carries

    struct Spend: Equatable {
        /// `defaultProvider` from settings.json, nil when the file names none.
        var provider: String?
        /// `defaultModel` from settings.json.
        var model: String?
        /// USD this calendar month and today, local time.
        var monthUSD: Double = 0
        var todayUSD: Double = 0
        /// Assistant turns counted this month, after deduplication.
        var messages: Int = 0
        /// Session files read (modified this month).
        var files: Int = 0
        /// Lines that were not JSON or carried no usable cost. Counted, never fatal.
        var skippedLines: Int = 0
        /// Files read only in part because they passed `maxFileBytes`, plus files past
        /// `maxFiles` that were not read at all. Non-zero means the sums are a floor.
        var partialFiles: Int = 0
        /// Newest counted turn.
        var newest: Date?
    }

    /// How Pi's month compares with the OpenRouter balance. Pi spends OpenRouter credit only
    /// when its default provider is openrouter; otherwise the comparison would be invented.
    enum Share: Equatable {
        /// `pct` is Pi's month spend over the OpenRouter limit (lifetime top-ups);
        /// `leftUSD` is that limit minus everything spent on the key.
        case openRouter(pct: Double, leftUSD: Double, limitUSD: Double)
        /// Spend only, with the reason no share is drawn.
        case spendOnly(String)
    }

    static func share(_ s: Spend, openRouter: OpenRouter.Outcome) -> Share {
        guard let provider = s.provider else {
            return .spendOnly("settings.json names no default provider")
        }
        guard provider == "openrouter" else {
            return .spendOnly("Pi runs on \(provider), not OpenRouter")
        }
        switch openRouter {
        case .notConfigured:
            return .spendOnly("no OpenRouter key in Tower")
        case .rejected(let code, _, _):
            return .spendOnly("OpenRouter refused the key (HTTP \(code))")
        case .unavailable:
            return .spendOnly("OpenRouter balance not readable")
        case .ok(let budget):
            guard budget.limit > 0 else { return .spendOnly("OpenRouter reports no credit added") }
            return .openRouter(pct: s.monthUSD / budget.limit * 100,
                               leftUSD: budget.available, limitUSD: budget.limit)
        }
    }

    static func money(_ usd: Double) -> String { "$" + String(format: "%.2f", usd) }

    /// "$12.34 this month · $1.20 today", plus a floor marker when a read was partial.
    static func spendLine(_ s: Spend) -> String {
        "\(money(s.monthUSD)) this month · \(money(s.todayUSD)) today"
            + (s.partialFiles > 0 ? " · at least (\(s.partialFiles) file(s) read in part)" : "")
    }

    /// "7% of OpenRouter budget · $88.10 left", or the reason there is no share.
    static func shareLine(_ share: Share) -> String {
        switch share {
        case .openRouter(let pct, let left, _):
            return "\(percent(pct)) of OpenRouter budget · \(money(left)) left"
        case .spendOnly(let why):
            return "spend only: \(why)"
        }
    }

    /// A share under one percent is still spend, so it prints "<1%" rather than "0%".
    static func percent(_ pct: Double) -> String {
        pct > 0 && pct < 1 ? "<1%" : "\(Int(pct.rounded()))%"
    }

    /// "openrouter · some/model", the identity half of the row.
    static func modelLine(_ s: Spend) -> String {
        switch (s.provider, s.model) {
        case let (p?, m?): return "\(p) · \(m)"
        case let (p?, nil): return p
        case let (nil, m?): return "model \(m)"
        default: return "no default model"
        }
    }

    // MARK: Parsing (pure, fixture tested)

    struct SettingsUnreadable: Error {}

    /// `defaultProvider` and `defaultModel`. Throws only when the file is not a JSON object.
    static func settings(data: Data) throws -> (provider: String?, model: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SettingsUnreadable() }
        func text(_ key: String) -> String? {
            (root[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return (text("defaultProvider"), text("defaultModel"))
    }

    /// A timestamp as Pi writes it (ISO 8601 string) or as epoch milliseconds. Seconds are
    /// accepted too: a value under 1e11 cannot be a millisecond time after 1973.
    static func date(_ raw: Any?) -> Date? {
        if let s = raw as? String { return DateParse.parse(s) }
        if let n = raw as? Double, n.isFinite, n > 0 {
            return Date(timeIntervalSince1970: n < 1e11 ? n : n / 1000)
        }
        return nil
    }

    /// Sums assistant turn costs into a month and a day. One instance spans every file of a
    /// read, so an entry copied into a second session file (a fork carries its parent's
    /// history) is counted once.
    struct Tally {
        let monthStart: Date
        let dayStart: Date
        let now: Date
        private(set) var spend = Spend()
        private var seen = Set<String>()

        init(now: Date, calendar: Calendar = .current) {
            self.now = now
            monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
            dayStart = calendar.startOfDay(for: now)
        }

        /// The cheap check before JSON parsing: a tool result line can be megabytes, and
        /// only assistant turns carry a cost.
        private static let markers = [Data("\"assistant\"".utf8), Data("\"cost\"".utf8)]

        mutating func add(line: Data, fallbackKey: String) {
            guard !line.isEmpty, line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D })
            else { return }
            guard Self.markers.allSatisfy({ line.range(of: $0) != nil }) else { return }
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { spend.skippedLines += 1; return }
            guard entry["type"] as? String == "message",
                  let message = entry["message"] as? [String: Any],
                  message["role"] as? String == "assistant"
            else { return }
            guard let usage = message["usage"] as? [String: Any],
                  let cost = usage["cost"] as? [String: Any],
                  let total = (cost["total"] as? Double), total.isFinite, total >= 0,
                  let at = PiLane.date(entry["timestamp"]) ?? PiLane.date(message["timestamp"])
            else { spend.skippedLines += 1; return }
            guard at >= monthStart else { return }
            let key = (entry["id"] as? String) ?? (message["responseId"] as? String) ?? fallbackKey
            guard seen.insert(key).inserted else { return }
            spend.monthUSD += total
            if at >= dayStart { spend.todayUSD += total }
            spend.messages += 1
            if spend.newest.map({ at > $0 }) ?? true { spend.newest = at }
        }

        /// Feeds a whole text, for tests and small inputs.
        mutating func add(text: String, file: String = "fixture") {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                add(line: Data(line.utf8), fallbackKey: "\(file):\(i)")
            }
        }

        mutating func markFile(partial: Bool) {
            spend.files += 1
            if partial { spend.partialFiles += 1 }
        }

        mutating func markUnread(_ count: Int) { spend.partialFiles += count }
    }

    // MARK: Reading from disk

    /// Session files under `sessions/<project>/`, modified at or after `since`, newest first.
    /// `confined` (a demo) skips any project or file whose real path leaves the root, so
    /// a symlink below the root cannot pull in files from elsewhere.
    static func sessionFiles(root: URL, since: Date, confined: Bool = false) -> [URL] {
        let fm = FileManager.default
        let inside = insideCheck(root: root, confined: confined)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let projects = try? fm.contentsOfDirectory(
            at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        for project in projects {
            guard inside(project), (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(
                      at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for file in files where file.pathExtension == "jsonl" && inside(file) {
                let m = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if m >= since { found.append((file, m)) }
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Always true unless confined; then true only for paths whose real path is under the
    /// root's real path.
    static func insideCheck(root: URL, confined: Bool) -> (URL) -> Bool {
        guard confined else { return { _ in true } }
        guard let realRoot = DemoMode.realPath(root.path) else { return { _ in false } }
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        return { url in DemoMode.realPath(url.path).map { $0.hasPrefix(prefix) } ?? false }
    }

    /// Streams one file's lines into the tally, reading at most the last `maxBytes`.
    /// Returns false when the file could not be opened.
    @discardableResult
    static func stream(_ url: URL, into tally: inout Tally, maxBytes: Int = maxFileBytes) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let partial = size > UInt64(maxBytes)
        let start = partial ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return false }
        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        // A tail starts mid line; that first fragment is not an entry.
        var dropFirst = partial
        var index = 0
        while let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: newline) {
                let line = buffer[buffer.startIndex..<nl]
                if dropFirst { dropFirst = false } else {
                    tally.add(line: Data(line), fallbackKey: "\(url.path):\(index)")
                }
                index += 1
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        // The last line of a log being appended to may still be torn; JSON parsing decides.
        if !buffer.isEmpty, !dropFirst {
            tally.add(line: buffer, fallbackKey: "\(url.path):\(index)")
        }
        tally.markFile(partial: partial)
        return true
    }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     env: [String: String] = ProcessInfo.processInfo.environment,
                     now: Date = Date(),
                     calendar: Calendar = .current,
                     confineToRoot: Bool = false) -> AgentLane.Outcome {
        let root = root(home: home, env: env)
        let inside = insideCheck(root: root, confined: confineToRoot)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue
        else { return .notConfigured }

        var provider: String?
        var model: String?
        let settingsURL = root.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path), inside(settingsURL) {
            do {
                (provider, model) = try settings(data: try Data(contentsOf: settingsURL))
            } catch {
                return .unavailable("could not read Pi's settings.json")
            }
        }

        var tally = Tally(now: now, calendar: calendar)
        let files = sessionFiles(root: root, since: tally.monthStart, confined: confineToRoot)
        for url in files.prefix(maxFiles) { stream(url, into: &tally) }
        tally.markUnread(max(files.count - maxFiles, 0))
        var spend = tally.spend
        spend.provider = provider
        spend.model = model
        return .ok(AgentLane.Reading(provider: .pi, configModel: model, lastDispatch: nil,
                                     lastLimitHit: nil, usage: .spend(spend)))
    }

    /// The `tower status` block. Hidden when Pi is not installed, like the panel row.
    static func statusLines(_ outcome: AgentLane.Outcome?, openRouter: OpenRouter.Outcome) -> [String] {
        switch outcome ?? .notConfigured {
        case .notConfigured:
            return []
        case .unavailable(let why):
            return ["  " + CLI.pad("pi", 12) + "SPEND", "      ? " + why]
        case .ok(let r):
            guard case .spend(let s) = r.usage else { return [] }
            return ["  " + CLI.pad("pi", 12) + CLI.pad(modelLine(s), 36) + "SPEND",
                    "      " + spendLine(s),
                    "      " + shareLine(share(s, openRouter: openRouter))]
        }
    }
}
