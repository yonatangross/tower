import Foundation
import XCTest
@testable import Tower

/// The recorder turns "a session left the `claude agents` list" into one ledger line, reading
/// that session's real transcript shape and the account's quota samples. Nothing here reads
/// the real home directory: every path is a temp directory.
final class LaneCostRecorderTests: XCTestCase {
    private let base = 1_794_500_000.0
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: base + minutes * 60) }
    private func iso(_ minutes: Double) -> String { ISO8601DateFormatter().string(from: at(minutes)) }

    private func home() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("lc-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        return h
    }

    private func line(_ id: String, minutes: Double, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(iso(minutes))","message":{"id":"\(id)","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":\(output),"cache_read_input_tokens":50,"cache_creation_input_tokens":5}}}
        """
    }

    /// Writes ~/.claude/projects/<dir>/<session>.jsonl and returns its URL.
    @discardableResult
    private func transcript(home: URL, dir: String = "-work-lane", session: String, account: String,
                            title: String = "lane-x", lines: [String]) throws -> URL {
        let d = home.appendingPathComponent(".claude/projects/\(dir)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let head = [
            "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"\(session)\"}",
            "{\"type\":\"session-owner\",\"accountUuid\":\"\(account)\",\"sessionId\":\"\(session)\"}",
        ]
        let url = d.appendingPathComponent("\(session).jsonl")
        try (head + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func live(_ id: String, cwd: String = "/work/lane", lane: String = "lane-x") -> LaneCost.Live {
        LaneCost.Live(sessionId: id, interactive: true, lane: lane, repo: "lane", cwd: cwd,
                      accountSeat: "seat-a", accountEmail: "user-a@example.com")
    }

    private func env(_ h: URL, now: Double = 200) -> LaneCostRecorder.Environment {
        LaneCostRecorder.Environment(home: h, supportDir: h.appendingPathComponent("support", isDirectory: true), now: at(now))
    }

    private func ledger(_ h: URL, now: Double = 200) -> URL { LaneCost.ledgerURL(now: at(now), home: h) }

    // MARK: finding things

    func testTheTranscriptIsFoundByTheCwdDerivedFolderThenByScanning() throws {
        let h = try home()
        let exact = try transcript(home: h, dir: "-work-lane", session: "s-exact", account: "u1", lines: [])
        let elsewhere = try transcript(home: h, dir: "-other-place", session: "s-scan", account: "u1", lines: [])
        XCTAssertEqual(LaneCostRecorder.transcriptURL(live: live("s-exact"), home: h)?.path, exact.path)
        XCTAssertEqual(LaneCostRecorder.transcriptURL(live: live("s-scan"), home: h)?.path, elsewhere.path)
        XCTAssertNil(LaneCostRecorder.transcriptURL(live: live("s-missing"), home: h))
    }

    func testTheCwdFolderNameReplacesSlashesAndDots() {
        XCTAssertEqual(LaneCostRecorder.projectFolder(cwd: "/Users/a/.floor/desks/x-1"), "-Users-a--floor-desks-x-1")
    }

    func testPaceSamplesAreReadForTheAccountAndAnUnknownAccountReadsEmpty() throws {
        let h = try home()
        let support = env(h).supportDir
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let json = """
        {"user-a@example.com":[{"at":\(base),"weekly":40,"fiveHour":10,"weeklyResetsAt":1},{"at":\(base + 300),"weekly":41}],"user-b@example.com":[]}
        """
        try json.write(to: support.appendingPathComponent("pace.json"), atomically: true, encoding: .utf8)
        let s = LaneCostRecorder.paceSamples(supportDir: support, email: "user-a@example.com")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.first, LaneCost.PaceSample(at: at(0), weekly: 40, fiveHour: 10))
        XCTAssertNil(s.last?.fiveHour)
        XCTAssertTrue(LaneCostRecorder.paceSamples(supportDir: support, email: "nobody@example.com").isEmpty)
        XCTAssertTrue(LaneCostRecorder.paceSamples(supportDir: support, email: nil).isEmpty)
    }

    func testAccountOutputSumsOnlyThisAccountsMessagesInsideTheWindow() throws {
        let h = try home()
        try transcript(home: h, session: "lane", account: "u1", lines: [line("a", minutes: 1, output: 100), line("b", minutes: 50, output: 5)])
        try transcript(home: h, dir: "-p2", session: "peer", account: "u1", lines: [line("c", minutes: 2, output: 300)])
        try transcript(home: h, dir: "-p3", session: "stranger", account: "u2", lines: [line("d", minutes: 3, output: 9999)])
        let total = LaneCostRecorder.accountOutput(uuid: "u1", from: at(0), to: at(10), home: h)
        XCTAssertEqual(total, 400, "u1 inside the window: 100 + 300; the message at minute 50 and the other account are out")
        XCTAssertNil(LaneCostRecorder.accountOutput(uuid: nil, from: at(0), to: at(10), home: h))
    }

    // MARK: recording

    func testAClosedSessionWritesOneRecordFromItsTranscriptAndTheAccountsQuota() throws {
        let h = try home()
        try transcript(home: h, session: "s-1", account: "u1", title: "tower-cost-1",
                       lines: [line("a", minutes: 1, output: 100), line("b", minutes: 5, output: 60)])
        try transcript(home: h, dir: "-p2", session: "peer", account: "u1", lines: [line("c", minutes: 2, output: 340)])
        let e = env(h)
        try FileManager.default.createDirectory(at: e.supportDir, withIntermediateDirectories: true)
        try "{\"user-a@example.com\":[{\"at\":\(base + 60),\"weekly\":40},{\"at\":\(base + 300),\"weekly\":43}]}"
            .write(to: e.supportDir.appendingPathComponent("pace.json"), atomically: true, encoding: .utf8)

        let written = LaneCostRecorder.recordClosed(previous: [live("s-1"), live("s-2")], current: [live("s-2")], env: e)

        XCTAssertEqual(written.count, 1)
        let r = try XCTUnwrap(LaneCost.latest(in: ledger(h)).first)
        XCTAssertEqual(r.session, "s-1")
        XCTAssertEqual(r.tokens?.output, 160)
        XCTAssertEqual(r.accountUuid, "u1")
        XCTAssertEqual(r.quota?.weeklyStart, 40)
        XCTAssertEqual(r.quota?.weeklyEnd, 43)
        XCTAssertEqual(try XCTUnwrap(r.quotaShare), 160.0 / 500.0, accuracy: 0.0001, "160 of the account's 500 in the window")
        XCTAssertTrue(r.quotaShareCalculated)
        XCTAssertNil(r.outcome)
    }

    func testTheSameCloseIsNotWrittenTwice() throws {
        let h = try home()
        try transcript(home: h, session: "s-1", account: "u1", lines: [line("a", minutes: 1, output: 10), line("b", minutes: 5, output: 10)])
        let e = env(h)
        LaneCostRecorder.recordClosed(previous: [live("s-1")], current: [], env: e)
        LaneCostRecorder.recordClosed(previous: [live("s-1")], current: [], env: e)
        let text = try String(contentsOf: ledger(h), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
    }

    func testASessionThatIsStillListedWritesNothing() throws {
        let h = try home()
        try transcript(home: h, session: "s-1", account: "u1", lines: [line("a", minutes: 1, output: 10)])
        XCTAssertTrue(LaneCostRecorder.recordClosed(previous: [live("s-1")], current: [live("s-1")], env: env(h)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger(h).path))
    }

    func testAProbeThatLosesMostOfTheListIsNotFourClosedLanes() throws {
        let h = try home()
        let four = ["a", "b", "c", "d"].map { live($0) }
        for s in ["a", "b", "c", "d"] {
            try transcript(home: h, dir: "-p-\(s)", session: s, account: "u1", lines: [line("m\(s)", minutes: 1, output: 10)])
        }
        XCTAssertTrue(LaneCostRecorder.recordClosed(previous: four, current: [], env: env(h)).isEmpty,
                      "an empty list after four sessions is a failed probe, not four closes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger(h).path))
        XCTAssertEqual(LaneCostRecorder.recordClosed(previous: four, current: Array(four.dropFirst()), env: env(h)).count, 1,
                       "one of four leaving is a close")
    }

    func testAClosedSessionWithoutATranscriptStillGetsARecordThatSaysWhatIsMissing() throws {
        let h = try home()
        LaneCostRecorder.recordClosed(previous: [live("ghost")], current: [], env: env(h))
        let r = try XCTUnwrap(LaneCost.latest(in: ledger(h)).first)
        XCTAssertNil(r.tokens)
        XCTAssertNotNil(r.unread["tokens"])
        XCTAssertNotNil(r.unread["outcome"])
    }
}
