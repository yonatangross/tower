import Foundation
import XCTest
@testable import Tower

/// 2026-11-12: a lane's tokens, minutes and quota burn lived in four places and were lost
/// when the lane closed. These tests pin the record Tower writes at close. The line shapes
/// below are copied from a real Claude Code transcript (one API message is written on
/// several lines; the last carries the final counts).
final class LaneCostTests: XCTestCase {
    private func t(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_794_500_000 + minutes * 60) }

    private func iso(_ minutes: Double) -> String {
        ISO8601DateFormatter().string(from: t(minutes))
    }

    private func assistant(id: String, model: String = "claude-opus-5-5", at: Double,
                           input: Int = 3, output: Int, cacheRead: Int = 100, cacheWrite: Int = 10) -> String {
        """
        {"type":"assistant","timestamp":"\(iso(at))","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)}}}
        """
    }

    private func request(effort: String, at: Double) -> String {
        """
        {"type":"api-request","timestamp":"\(iso(at))","params":{"model":"claude-opus-5-5","output_config":{"effort":"\(effort)"}}}
        """
    }

    private var transcript: [String] {
        [
            #"{"type":"custom-title","customTitle":"tower-cost-1","sessionId":"abc"}"#,
            #"{"type":"session-owner","accountUuid":"acct-1","sessionId":"abc"}"#,
            request(effort: "high", at: 0),
            assistant(id: "m1", at: 1, output: 5),
            assistant(id: "m1", at: 1, output: 12),          // same message again, final count
            request(effort: "high", at: 2),
            assistant(id: "m2", model: "claude-sonnet-5-5", at: 3, output: 40),
            request(effort: "medium", at: 4),
            assistant(id: "m3", model: "<synthetic>", at: 5, output: 999),
            "not json at all",
            assistant(id: "m4", at: 70, output: 8),
        ]
    }

    // MARK: transcript

    func testEachApiMessageCountsOnceAtItsFinalCount() {
        let s = LaneCost.summarize(lines: transcript)
        XCTAssertEqual(s.tokens.output, 12 + 40 + 8, "m1 once at 12, not 5 + 12")
        XCTAssertEqual(s.tokens.input, 3 * 3)
        XCTAssertEqual(s.tokens.cacheRead, 100 * 3)
        XCTAssertEqual(s.tokens.cacheWrite, 10 * 3)
        XCTAssertEqual(s.apiMessages, 3, "the synthetic message is not an API call")
        XCTAssertEqual(s.messages.count, 3)
    }

    func testModelSplitIgnoresTheSyntheticModelAndEffortCountsRequests() {
        let s = LaneCost.summarize(lines: transcript)
        XCTAssertEqual(s.outputByModel, ["claude-opus-5-5": 12 + 8, "claude-sonnet-5-5": 40])
        XCTAssertEqual(s.requestsByEffort, ["high": 2, "medium": 1])
    }

    func testTitleAccountAndSpanComeFromTheTranscript() {
        let s = LaneCost.summarize(lines: transcript)
        XCTAssertEqual(s.title, "tower-cost-1")
        XCTAssertEqual(s.accountUuid, "acct-1")
        XCTAssertEqual(s.first, t(0))
        XCTAssertEqual(s.last, t(70))
    }

    func testAnEmptyTranscriptReadsNothingRatherThanZeroes() {
        let s = LaneCost.summarize(lines: ["not json"])
        XCTAssertNil(s.first)
        XCTAssertNil(s.title)
        XCTAssertEqual(s.apiMessages, 0)
    }

    func testActiveMinutesCountOnlyGapsOfTenMinutesOrLess() throws {
        // 0, 5, 10, then an hour of silence, then 70 and 72: 10 + 2 active, 60 idle.
        let active = try XCTUnwrap(LaneCost.activeMinutes(stamps: [t(0), t(5), t(10), t(70), t(72)]))
        XCTAssertEqual(active, 12, accuracy: 0.001)
        XCTAssertNil(LaneCost.activeMinutes(stamps: [t(0)]), "one stamp has no span")
    }

    // MARK: quota

    func testQuotaTakesTheNearestSampleToEachEndWithinTolerance() throws {
        let samples = [
            LaneCost.PaceSample(at: t(-4), weekly: 40, fiveHour: 10),
            LaneCost.PaceSample(at: t(30), weekly: 50, fiveHour: 30),
            LaneCost.PaceSample(at: t(61), weekly: 58, fiveHour: 55),
        ]
        let r = LaneCost.quota(samples: samples, start: t(0), end: t(60))
        let q = try XCTUnwrap(r.quota)
        XCTAssertEqual(q.weeklyStart, 40)
        XCTAssertEqual(q.weeklyEnd, 58)
        XCTAssertEqual(q.fiveHourStart, 10)
        XCTAssertEqual(q.fiveHourEnd, 55)
        XCTAssertTrue(r.unread.isEmpty)
    }

    func testNoSampleNearTheStartLeavesTheStartNilWithAReason() {
        let samples = [LaneCost.PaceSample(at: t(120), weekly: 70, fiveHour: nil)]
        let r = LaneCost.quota(samples: samples, start: t(0), end: t(121))
        XCTAssertNil(r.quota?.weeklyStart, "a sample two hours late is not the start reading")
        XCTAssertEqual(r.quota?.weeklyEnd, 70)
        XCTAssertNotNil(r.unread["quota_weekly_start"])
        XCTAssertNil(r.unread["quota_weekly_end"])
        XCTAssertNotNil(r.unread["quota_five_hour_end"], "that sample carries no five-hour reading")
    }

    func testNoSamplesAtAllIsNilWithAReasonAndNeverZero() {
        let r = LaneCost.quota(samples: [], start: t(0), end: t(60))
        XCTAssertNil(r.quota)
        XCTAssertNotNil(r.unread["quota"])
    }

    func testShareIsLaneOverAccountAndNilWhenItCannotBeRight() {
        XCTAssertEqual(try XCTUnwrap(LaneCost.share(laneOutput: 100, accountOutput: 400)), 0.25, accuracy: 0.0001)
        XCTAssertNil(LaneCost.share(laneOutput: 100, accountOutput: 0))
        XCTAssertNil(LaneCost.share(laneOutput: 500, accountOutput: 400), "a lane cannot exceed its account")
        XCTAssertNil(LaneCost.share(laneOutput: 0, accountOutput: 400), "no output is not a 0 % share")
    }

    // MARK: closing

    private func live(_ id: String?, interactive: Bool = true, lane: String = "lane") -> LaneCost.Live {
        LaneCost.Live(sessionId: id, interactive: interactive, lane: lane, repo: "repo", cwd: "/x/\(lane)", accountSeat: nil)
    }

    func testASessionThatLeavesTheListIsClosedAndOneThatStaysIsNot() {
        let a = live("a", lane: "lane-a"), b = live("b", lane: "lane-b")
        let bg = live("c", interactive: false), noId = live(nil)
        XCTAssertEqual(LaneCost.closed(previous: [a, b, bg, noId], current: [b]).map(\.sessionId), ["a"])
        XCTAssertEqual(LaneCost.closed(previous: [a, b], current: []).compactMap(\.sessionId).sorted(), ["a", "b"])
        XCTAssertTrue(LaneCost.closed(previous: [a, b], current: [a, b]).isEmpty)
        XCTAssertTrue(LaneCost.closed(previous: [], current: [a]).isEmpty, "a new session is not a close")
    }

    // MARK: record

    private func agent() -> LaneCost.Live {
        LaneCost.Live(sessionId: "sess-1234567890", interactive: true, lane: "tower-cost-1", repo: "tower",
                      cwd: "/work/tower", accountSeat: "user-a")
    }

    func testTheRecordCarriesWhatWasMeasuredAndNamesWhatWasNot() throws {
        let s = LaneCost.summarize(lines: transcript)
        let samples = [LaneCost.PaceSample(at: t(0), weekly: 40, fiveHour: nil)]
        let r = LaneCost.makeRecord(live: agent(), summary: s, samples: samples,
                                    accountOutputInWindow: 4000, now: t(80))
        XCTAssertEqual(r.lane, "tower-cost-1")
        XCTAssertEqual(r.session, "sess-1234567890")
        XCTAssertEqual(r.repo, "tower")
        XCTAssertEqual(r.tokens?.output, 12 + 40 + 8)
        XCTAssertEqual(r.model, ["claude-opus-5-5": 20, "claude-sonnet-5-5": 40])
        XCTAssertEqual(r.wallMin ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(r.activeMin ?? 0, 5, accuracy: 0.001, "the 65 minute gap before the last stamp is idle")
        XCTAssertEqual(r.accountUuid, "acct-1")
        XCTAssertEqual(r.accountSeat, "user-a")
        XCTAssertEqual(r.quota?.weeklyStart, 40)
        XCTAssertNil(r.quota?.weeklyEnd)
        XCTAssertNotNil(r.unread["quota_weekly_end"])
        XCTAssertTrue(r.quotaShareCalculated, "the share is always flagged as calculated")
        XCTAssertEqual(try XCTUnwrap(r.quotaShare), Double(12 + 40 + 8) / 4000, accuracy: 0.0001)
        XCTAssertNil(r.outcome)
        XCTAssertNotNil(r.unread["outcome"], "a lane closes before anyone knows how it ended")
    }

    func testWithoutAnAccountTotalTheShareIsNilWithAReasonNotZero() {
        let r = LaneCost.makeRecord(live: agent(), summary: LaneCost.summarize(lines: transcript),
                                    samples: [], accountOutputInWindow: nil, now: t(80))
        XCTAssertNil(r.quotaShare)
        XCTAssertNotNil(r.unread["quota_share"])
        XCTAssertNil(r.quota)
        XCTAssertNotNil(r.unread["quota"])
    }

    func testATranscriptThatCannotBeReadGivesNilTokensWithAReason() {
        let r = LaneCost.makeRecord(live: agent(), summary: LaneCost.summarize(lines: []),
                                    samples: [], accountOutputInWindow: nil, now: t(80))
        XCTAssertNil(r.tokens)
        XCTAssertNil(r.wallMin)
        XCTAssertNotNil(r.unread["tokens"])
        XCTAssertNotNil(r.unread["minutes"])
    }

    // MARK: ledger

    private func tempLedger() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-cost-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("2026-11.jsonl")
    }

    private func record(_ session: String, lane: String = "lane") -> LaneCost.Record {
        LaneCost.Record(lane: lane, session: session, writtenAt: "2026-11-12T20:00:00Z")
    }

    func testTheLedgerAppendsOneJsonLinePerRecordAndNeverRewritesEarlierBytes() throws {
        let url = tempLedger()
        try LaneCost.append(record("s1"), to: url)
        let first = try Data(contentsOf: url)
        try LaneCost.append(record("s2"), to: url)
        let all = try Data(contentsOf: url)
        XCTAssertTrue(all.starts(with: first), "append only: the first line is byte-identical")
        let lines = String(decoding: all, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for l in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(l.utf8)))
        }
        XCTAssertTrue(lines[0].contains("\"quota_share_calculated\":true"), "snake_case keys, flag present")
        XCTAssertTrue(lines[0].contains("\"written_at\""))
    }

    func testTheLatestLineForASessionWins() throws {
        let url = tempLedger()
        try LaneCost.append(record("s1", lane: "old"), to: url)
        try LaneCost.append(record("s2"), to: url)
        try LaneCost.append(record("s1", lane: "new"), to: url)
        let latest = LaneCost.latest(in: url)
        XCTAssertEqual(latest.count, 2)
        XCTAssertEqual(latest.first(where: { $0.session == "s1" })?.lane, "new")
    }

    func testAMissingLedgerReadsAsEmpty() {
        XCTAssertTrue(LaneCost.latest(in: tempLedger()).isEmpty)
    }

    func testSettingAnOutcomeAppendsALineAndLeavesTheFirstAlone() throws {
        let url = tempLedger()
        var r = record("sess-1234567890")
        r.unread["outcome"] = "not known at close"
        try LaneCost.append(r, to: url)
        let before = try Data(contentsOf: url)
        let updated = try XCTUnwrap(LaneCost.setOutcome(session: "sess-12345", outcome: "merged", pr: "tower#53",
                                                        source: "gh pr view", in: url, now: t(0)))
        XCTAssertEqual(updated.outcome, "merged")
        XCTAssertEqual(updated.pr, "tower#53")
        XCTAssertNil(updated.unread["outcome"], "a known outcome drops its unread reason")
        let after = try Data(contentsOf: url)
        XCTAssertTrue(after.starts(with: before))
        XCTAssertEqual(LaneCost.latest(in: url).first?.outcome, "merged")
        XCTAssertEqual(String(decoding: after, as: UTF8.self).split(separator: "\n").count, 2)
    }

    func testAnUnknownSessionOrAnUnknownOutcomeChangesNothing() throws {
        let url = tempLedger()
        try LaneCost.append(record("sess-1234567890"), to: url)
        let before = try Data(contentsOf: url)
        XCTAssertNil(try LaneCost.setOutcome(session: "nope-nope", outcome: "merged", pr: nil,
                                             source: "x", in: url, now: t(0)))
        XCTAssertThrowsError(try LaneCost.setOutcome(session: "sess-1234567890", outcome: "great", pr: nil,
                                                     source: "x", in: url, now: t(0)))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAShortPrefixThatMatchesTwoSessionsIsRefused() throws {
        let url = tempLedger()
        try LaneCost.append(record("sess-aaaa-1"), to: url)
        try LaneCost.append(record("sess-aaaa-2"), to: url)
        XCTAssertNil(try LaneCost.setOutcome(session: "sess-aaaa", outcome: "merged", pr: nil,
                                             source: "x", in: url, now: t(0)), "ambiguous prefix")
    }

    func testEveryApprovedOutcomeIsAccepted() {
        XCTAssertEqual(LaneCost.outcomes, ["merged", "land", "open", "pending", "handoff", "hold", "dropped"])
    }
}
