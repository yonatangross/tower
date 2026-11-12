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
    }

    /// An active gap is a pause of at most this long between two transcript stamps.
    static let activeGap: TimeInterval = 600
}

// RED STUB: bodies are placeholders so the tests compile and fail on their assertions.
extension LaneCost {
    static func summarize(lines: [String]) -> TranscriptSummary { TranscriptSummary() }

    static func activeMinutes(stamps: [Date]) -> Double? { nil }

    static func quota(samples: [PaceSample], start: Date, end: Date,
                      tolerance: TimeInterval = 600) -> (quota: Quota?, unread: [String: String]) {
        (nil, [:])
    }

    static func share(laneOutput: Int, accountOutput: Int) -> Double? { nil }

    static func closed(previous: [Live], current: [Live]) -> [Live] { [] }

    static func makeRecord(live: Live, summary: TranscriptSummary, samples: [PaceSample],
                           accountOutputInWindow: Int?, now: Date) -> Record {
        Record(lane: "", session: "", writtenAt: "")
    }

    static func append(_ record: Record, to url: URL) throws {}

    static func latest(in url: URL) -> [Record] { [] }

    static func setOutcome(session: String, outcome: String, pr: String?, source: String,
                           in url: URL, now: Date) throws -> Record? { nil }
}
