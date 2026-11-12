import Darwin
import Foundation

// MARK: - Per-lane cost record

/// One appended line per closed lane in `~/.floor/lane-cost/YYYY-MM.jsonl`: what the
/// lane cost (tokens, minutes, quota) beside how it ended. A number nobody measured is
/// nil, and `unread` says why; the calculated quota share carries a flag that says so.
enum LaneCost {
    struct Tokens: Codable, Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
    }

    struct Quota: Codable, Equatable {
        var weeklyStart: Double?
        var weeklyEnd: Double?
        var fiveHourStart: Double?
        var fiveHourEnd: Double?
    }

    static let outcomes: Set<String> = ["merged", "land", "open", "pending", "handoff", "hold", "dropped"]

    struct Record: Codable, Equatable {
        var lane: String
        var session: String
        var repo: String?
        /// Output tokens by model: a lane that switched models splits its cost.
        var model: [String: Int] = [:]
        /// API requests by effort level.
        var effort: [String: Int] = [:]
        var start: String?
        var end: String?
        var wallMin: Double?
        var activeMin: Double?
        var tokens: Tokens?
        var accountUuid: String?
        var accountSeat: String?
        var quota: Quota?
        /// The lane's output tokens over the account's output tokens in the lane's window.
        /// CALCULATED, never measured: `quotaShareCalculated` is always true beside it.
        var quotaShare: Double?
        var quotaShareCalculated = true
        var outcome: String?
        var pr: String?
        var outcomeSource: String?
        /// Field name to the reason it is nil.
        var unread: [String: String] = [:]
        var writtenAt: String
    }

    /// What one transcript says, before it is turned into a record.
    struct TranscriptSummary: Equatable {
        var title: String?
        var accountUuid: String?
        var first: Date?
        var last: Date?
        var tokens = Tokens()
        var outputByModel: [String: Int] = [:]
        var requestsByEffort: [String: Int] = [:]
        /// Every assistant message once: its time and output tokens, for windowed sums.
        var messages: [Message] = []
        var apiMessages = 0
        /// Every timestamp in the transcript, for active minutes.
        var stamps: [Date] = []
        struct Message: Equatable { var at: Date; var output: Int }
    }

    struct PaceSample: Equatable {
        var at: Date
        var weekly: Double?
        var fiveHour: Double?
    }

    /// One live session as Tower sees it in the `claude agents` list, reduced to what the
    /// record needs (the app builds it from an `AgentInfo`; see LaneCostWiring.swift).
    struct Live: Equatable {
        var sessionId: String?
        var interactive: Bool
        var lane: String
        var repo: String
        var cwd: String?
        var accountSeat: String?
        var accountEmail: String? = nil
        /// The session's Claude config root when it is not `~/.claude`.
        var configDir: String? = nil
    }

    /// An active gap is a pause of at most this long between two transcript stamps.
    static let activeGap: TimeInterval = 600
}

// MARK: - Reading a transcript

extension LaneCost {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseStamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    static func stampString(_ d: Date) -> String { isoPlain.string(from: d) }

    /// Reads Claude Code transcript lines (one JSON object per line). A line that is not
    /// JSON is skipped. One API message is written on several lines; the last line for an
    /// id carries the final counts, so each id counts once. The `<synthetic>` model is
    /// Claude Code's own placeholder, not an API call, and is skipped.
    static func summarize(lines: [String]) -> TranscriptSummary {
        var s = TranscriptSummary()
        struct Seen { var model: String; var input: Int; var output: Int; var cacheRead: Int; var cacheWrite: Int; var at: Date? }
        var byId: [String: Seen] = [:]
        var order: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let at = (obj["timestamp"] as? String).flatMap(parseStamp)
            if let at {
                s.stamps.append(at)
                if s.first == nil || at < s.first! { s.first = at }
                if s.last == nil || at > s.last! { s.last = at }
            }
            switch obj["type"] as? String {
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.isEmpty { s.title = t }
            case "session-owner":
                if s.accountUuid == nil { s.accountUuid = obj["accountUuid"] as? String }
            case "api-request":
                if let params = obj["params"] as? [String: Any],
                   let config = params["output_config"] as? [String: Any],
                   let effort = config["effort"] as? String {
                    s.requestsByEffort[effort, default: 0] += 1
                }
            case "assistant":
                guard let m = obj["message"] as? [String: Any], let id = m["id"] as? String,
                      let model = m["model"] as? String, model != "<synthetic>" else { continue }
                let u = m["usage"] as? [String: Any] ?? [:]
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                if byId[id] == nil { order.append(id) }
                byId[id] = Seen(model: model, input: n("input_tokens"), output: n("output_tokens"),
                                cacheRead: n("cache_read_input_tokens"),
                                cacheWrite: n("cache_creation_input_tokens"), at: at)
            default:
                break
            }
        }
        for id in order {
            guard let m = byId[id] else { continue }
            s.tokens.input += m.input
            s.tokens.output += m.output
            s.tokens.cacheRead += m.cacheRead
            s.tokens.cacheWrite += m.cacheWrite
            s.outputByModel[m.model, default: 0] += m.output
            if let at = m.at { s.messages.append(TranscriptSummary.Message(at: at, output: m.output)) }
        }
        s.apiMessages = order.count
        return s
    }

    static func summarize(url: URL) -> TranscriptSummary {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return TranscriptSummary() }
        return summarize(lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// Minutes of work: the sum of gaps between neighbouring stamps that are at most
    /// `activeGap` long. A lane open overnight is not a lane worked overnight. nil when
    /// there are fewer than two stamps.
    static func activeMinutes(stamps: [Date]) -> Double? {
        guard stamps.count >= 2 else { return nil }
        let sorted = stamps.sorted()
        var seconds = 0.0
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.timeIntervalSince(a)
            if gap <= activeGap { seconds += gap }
        }
        return seconds / 60
    }
}

// MARK: - Quota, share, closing

extension LaneCost {
    /// The account's meter readings nearest each end of the lane's window. A reading further
    /// than `tolerance` from the end it stands for is not that end's reading: nil, with the
    /// reason under `unread`, never a stretched value.
    static func quota(samples: [PaceSample], start: Date, end: Date,
                      tolerance: TimeInterval = 600) -> (quota: Quota?, unread: [String: String]) {
        func nearest(_ at: Date, _ pick: (PaceSample) -> Double?) -> Double? {
            samples.filter { pick($0) != nil && abs($0.at.timeIntervalSince(at)) <= tolerance }
                .min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }
                .flatMap(pick)
        }
        var q = Quota(weeklyStart: nearest(start) { $0.weekly }, weeklyEnd: nearest(end) { $0.weekly },
                      fiveHourStart: nearest(start) { $0.fiveHour }, fiveHourEnd: nearest(end) { $0.fiveHour })
        let fields: [(String, Double?)] = [
            ("quota_weekly_start", q.weeklyStart), ("quota_weekly_end", q.weeklyEnd),
            ("quota_five_hour_start", q.fiveHourStart), ("quota_five_hour_end", q.fiveHourEnd),
        ]
        if fields.allSatisfy({ $0.1 == nil }) {
            q = Quota()
            let why = samples.isEmpty ? "no quota samples on disk" : "no quota sample within \(Int(tolerance / 60)) minutes of either end"
            return (nil, ["quota": why])
        }
        var unread: [String: String] = [:]
        for (name, value) in fields where value == nil {
            unread[name] = "no sample with this reading within \(Int(tolerance / 60)) minutes"
        }
        return (q, unread)
    }

    /// The lane's output tokens over the account's output tokens in the same window.
    /// CALCULATED, not measured. nil when it cannot be right: no account total, no lane
    /// output, or a lane larger than its account.
    static func share(laneOutput: Int, accountOutput: Int) -> Double? {
        guard accountOutput > 0, laneOutput > 0, laneOutput <= accountOutput else { return nil }
        return Double(laneOutput) / Double(accountOutput)
    }

    /// Interactive sessions that were in the previous list and are gone from the current one.
    static func closed(previous: [Live], current: [Live]) -> [Live] {
        let now = Set(current.compactMap(\.sessionId))
        return previous.filter { $0.interactive && $0.sessionId != nil && !now.contains($0.sessionId!) }
    }

    static func makeRecord(live: Live, summary: TranscriptSummary, samples: [PaceSample],
                           accountOutputInWindow: Int?, now: Date) -> Record {
        var r = Record(lane: live.lane, session: live.sessionId ?? "unknown", writtenAt: stampString(now))
        r.repo = live.repo
        r.accountSeat = live.accountSeat
        r.accountUuid = summary.accountUuid
        r.model = summary.outputByModel
        r.effort = summary.requestsByEffort
        if summary.apiMessages > 0 {
            r.tokens = summary.tokens
        } else {
            r.unread["tokens"] = "no readable assistant messages in the transcript"
        }
        if let first = summary.first, let last = summary.last, last > first {
            r.start = stampString(first)
            r.end = stampString(last)
            r.wallMin = last.timeIntervalSince(first) / 60
            r.activeMin = activeMinutes(stamps: summary.stamps)
            let q = quota(samples: samples, start: first, end: last)
            r.quota = q.quota
            r.unread.merge(q.unread) { a, _ in a }
        } else {
            r.unread["minutes"] = "the transcript has no time span"
            r.unread["quota"] = "no time span to read the quota against"
        }
        if let total = accountOutputInWindow {
            r.quotaShare = share(laneOutput: summary.tokens.output, accountOutput: total)
            if r.quotaShare == nil { r.unread["quota_share"] = "not computable from the lane and account output" }
        } else {
            r.unread["quota_share"] = "the account's output in the window was not read"
        }
        r.unread["outcome"] = "not known at close"
        return r
    }
}

// MARK: - The ledger

extension LaneCost {
    enum LedgerError: Error, Equatable { case unknownOutcome(String) }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// `<home>/.floor/lane-cost/YYYY-MM.jsonl`: one file a month, append only.
    static func ledgerURL(now: Date, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        let name = String(format: "%04d-%02d.jsonl", c.year ?? 0, c.month ?? 0)
        return home.appendingPathComponent(".floor/lane-cost", isDirectory: true).appendingPathComponent(name)
    }

    /// One JSON line, written with O_APPEND in a single write so a reader never sees half a
    /// line and an earlier line is never touched.
    static func append(_ record: Record, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try encoder().encode(record)
        data.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The newest line per session (a later line, such as an outcome, replaces an earlier
    /// one). A line that does not decode is skipped. A missing file reads as empty.
    static func latest(in url: URL) -> [Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        var bySession: [String: Record] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let r = try? d.decode(Record.self, from: Data(line.utf8)) else { continue }
            if bySession[r.session] == nil { order.append(r.session) }
            bySession[r.session] = r
        }
        return order.compactMap { bySession[$0] }
    }

    /// Appends the lane's outcome as a new line. `session` is the full id or a prefix of at
    /// least 8 characters that names exactly one lane; anything else returns nil and writes
    /// nothing. An outcome outside `outcomes` throws.
    @discardableResult
    static func setOutcome(session: String, outcome: String, pr: String?, source: String,
                           in url: URL, now: Date) throws -> Record? {
        guard outcomes.contains(outcome) else { throw LedgerError.unknownOutcome(outcome) }
        let all = latest(in: url)
        let exact = all.filter { $0.session == session }
        let hits = exact.isEmpty && session.count >= 8 ? all.filter { $0.session.hasPrefix(session) } : exact
        guard hits.count == 1, var r = hits.first else { return nil }
        r.outcome = outcome
        r.pr = pr
        r.outcomeSource = source
        r.unread.removeValue(forKey: "outcome")
        r.writtenAt = stampString(now)
        try append(r, to: url)
        return r
    }
}
