import Foundation
import XCTest
@testable import Tower

/// A private lane (personal-lane-privacy) is never read by another session's tooling. The
/// first cut of the recorder scanned every transcript of the account and recorded every
/// lane that closed, private ones included (pre-read HOLD, 2026-11-12). These tests pin the
/// filter: a private lane's transcript is not opened, is not in any total, and gets no record.
final class LaneCostPrivacyTests: XCTestCase {
    private let base = 1_794_500_000.0
    private func at(_ m: Double) -> Date { Date(timeIntervalSince1970: base + m * 60) }
    private func iso(_ m: Double) -> String { ISO8601DateFormatter().string(from: at(m)) }

    private func home() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("lc-priv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        return h
    }

    private func msg(_ id: String, _ m: Double, _ out: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(iso(m))","message":{"id":"\(id)","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":\(out),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    @discardableResult
    private func transcript(_ h: URL, dir: String, session: String, account: String = "u1", lines: [String]) throws -> URL {
        let d = h.appendingPathComponent(".claude/projects/\(dir)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let head = "{\"type\":\"session-owner\",\"accountUuid\":\"\(account)\",\"sessionId\":\"\(session)\"}"
        let url = d.appendingPathComponent("\(session).jsonl")
        try ([head] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let privateDir = "/Users/someone/.floor/desks/personal-desk"
    private var policy: PrivateLanes { PrivateLanes(folders: [privateDir]) }
    private var privateSlug: String { LaneCostRecorder.projectFolder(cwd: privateDir) }

    private func live(_ id: String, cwd: String?) -> LaneCost.Live {
        LaneCost.Live(sessionId: id, interactive: true, lane: "lane", repo: "r", cwd: cwd, accountSeat: nil,
                      accountEmail: "user-a@example.com")
    }

    private func env(_ h: URL, _ p: PrivateLanes?) -> LaneCostRecorder.Environment {
        LaneCostRecorder.Environment(home: h, supportDir: h.appendingPathComponent("support"), now: at(200), privateLanes: p)
    }

    // MARK: the policy file

    func testThePolicyFileIsReadAndTildeIsTheReadersHome() throws {
        let h = try home()
        let f = h.appendingPathComponent("private-lanes.json")
        try #"{"_comment":"x","private_lanes":["~/.floor/desks/personal-desk","/abs/elsewhere"],"store_hosts":["a.example"]}"#
            .write(to: f, atomically: true, encoding: .utf8)
        let p = try XCTUnwrap(PrivateLanes.load(from: f, home: URL(fileURLWithPath: "/Users/x")))
        XCTAssertEqual(p.folders, ["/Users/x/.floor/desks/personal-desk", "/abs/elsewhere"])
    }

    func testAnUnreadableOrMalformedPolicyIsNilSoTheCallerFailsClosed() throws {
        let h = try home()
        XCTAssertNil(PrivateLanes.load(from: h.appendingPathComponent("missing.json"), home: h))
        let bad = h.appendingPathComponent("bad.json")
        try "not json".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertNil(PrivateLanes.load(from: bad, home: h))
        let wrong = h.appendingPathComponent("wrong.json")
        try #"{"private_lanes":"~/x"}"#.write(to: wrong, atomically: true, encoding: .utf8)
        XCTAssertNil(PrivateLanes.load(from: wrong, home: h), "a list that is not a list is unreadable, not empty")
        let empty = h.appendingPathComponent("empty.json")
        try #"{"private_lanes":[]}"#.write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertEqual(PrivateLanes.load(from: empty, home: h)?.folders, [], "an empty list is a valid policy")
    }

    func testACwdAtOrUnderAPrivateFolderIsPrivateAndASiblingIsNot() {
        XCTAssertTrue(policy.isPrivate(cwd: privateDir))
        XCTAssertTrue(policy.isPrivate(cwd: privateDir + "/sub/dir"))
        XCTAssertFalse(policy.isPrivate(cwd: privateDir + "-2"), "a sibling that only shares a name prefix")
        XCTAssertFalse(policy.isPrivate(cwd: "/Users/someone/.floor/desks/tower-cost-1"))
        XCTAssertTrue(policy.isPrivate(cwd: nil), "a session with no cwd cannot be shown to be public")
    }

    func testAProjectFolderThatIsThePrivateSlugOrBelowItIsPrivate() {
        XCTAssertTrue(policy.isPrivate(projectFolder: privateSlug))
        XCTAssertTrue(policy.isPrivate(projectFolder: privateSlug + "-sub-dir"))
        XCTAssertFalse(policy.isPrivate(projectFolder: "-Users-someone--floor-desks-tower-cost-1"))
    }

    // MARK: what is read

    func testAPrivateLanesTranscriptDoesNotChangeTheAccountTotal() throws {
        let h = try home()
        try transcript(h, dir: "-work-lane", session: "pub", lines: [msg("a", 1, 100)])
        try transcript(h, dir: privateSlug, session: "priv", lines: [msg("b", 2, 7000)])
        let filtered = LaneCostRecorder.accountOutput(uuid: "u1", from: at(0), to: at(10), home: h, privateLanes: policy)
        let open = LaneCostRecorder.accountOutput(uuid: "u1", from: at(0), to: at(10), home: h, privateLanes: PrivateLanes(folders: []))
        XCTAssertEqual(filtered, 100, "the private lane's 7000 is not in the account total")
        XCTAssertEqual(open, 7100, "control: with no policy the same transcript is counted, so the filter is what excludes it")
    }

    func testAPrivateTranscriptIsNotFoundByTheSessionScan() throws {
        let h = try home()
        try transcript(h, dir: privateSlug, session: "priv", lines: [msg("b", 2, 7000)])
        XCTAssertNil(LaneCostRecorder.transcriptURL(live: live("priv", cwd: "/work/lane"), home: h, privateLanes: policy))
        XCTAssertNotNil(LaneCostRecorder.transcriptURL(live: live("priv", cwd: "/work/lane"), home: h,
                                                       privateLanes: PrivateLanes(folders: [])), "control")
    }

    // MARK: what is written

    func testAClosedPrivateLaneWritesNothingAndAPublicOneStillDoes() throws {
        let h = try home()
        try transcript(h, dir: privateSlug, session: "priv", lines: [msg("a", 1, 10), msg("b", 5, 10)])
        try transcript(h, dir: "-work-lane", session: "pub", lines: [msg("c", 1, 10), msg("d", 5, 10)])
        let e = env(h, policy)
        XCTAssertTrue(LaneCostRecorder.recordClosed(previous: [live("priv", cwd: privateDir)], current: [], env: e).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LaneCost.ledgerURL(now: at(200), home: h).path))
        XCTAssertEqual(LaneCostRecorder.recordClosed(previous: [live("pub", cwd: "/work/lane")], current: [], env: e).count, 1)
        let lines = try String(contentsOf: LaneCost.ledgerURL(now: at(200), home: h), encoding: .utf8)
        XCTAssertFalse(lines.contains("priv"), "no trace of the private session in the ledger")
    }

    func testAPrivateLaneThatLeavesWithPublicOnesIsStillSkipped() throws {
        let h = try home()
        try transcript(h, dir: privateSlug, session: "priv", lines: [msg("a", 1, 10), msg("b", 5, 10)])
        try transcript(h, dir: "-work-lane", session: "pub", lines: [msg("c", 1, 10), msg("d", 5, 10)])
        let written = LaneCostRecorder.recordClosed(
            previous: [live("priv", cwd: privateDir), live("pub", cwd: "/work/lane")], current: [], env: env(h, policy))
        XCTAssertEqual(written.map(\.session), ["pub"])
    }

    func testAnUnreadablePolicyWritesNothingAtAll() throws {
        let h = try home()
        try transcript(h, dir: "-work-lane", session: "pub", lines: [msg("c", 1, 10), msg("d", 5, 10)])
        XCTAssertTrue(LaneCostRecorder.recordClosed(previous: [live("pub", cwd: "/work/lane")], current: [], env: env(h, nil)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LaneCost.ledgerURL(now: at(200), home: h).path))
    }

    // MARK: a missing policy is loud, never a quiet nothing

    func testTheReadbackSaysMissingUnreadableOrOkAsThreeDifferentThings() throws {
        let h = try home()
        let f = h.appendingPathComponent("private-lanes.json")
        XCTAssertEqual(PrivateLanes.readback(from: f, home: h), .missing(f.path))
        try "{ not json".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(PrivateLanes.readback(from: f, home: h), .unreadable(f.path))
        try #"{"private_lanes":["/a/b"]}"#.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(PrivateLanes.readback(from: f, home: h), .ok(PrivateLanes(folders: ["/a/b"])))
    }

    func testClosedLanesThatAreNotRecordedBecauseThePolicyIsMissingLeaveANote() throws {
        let h = try home()
        try transcript(h, dir: "-work-lane", session: "pub-session-1", lines: [msg("c", 1, 10), msg("d", 5, 10)])
        var e = env(h, nil)
        e.policyPath = "/x/.floor/private-lanes.json"
        XCTAssertTrue(LaneCostRecorder.recordClosed(previous: [live("pub-session-1", cwd: "/work/lane")], current: [], env: e).isEmpty)
        let log = try String(contentsOf: h.appendingPathComponent(".floor/lane-cost/refused.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("1 closed lane"), log)
        XCTAssertTrue(log.contains("/x/.floor/private-lanes.json"), "the note names the file that is missing")
        XCTAssertTrue(log.contains("install-private-lanes.sh"), "and the step that fixes it")
        XCTAssertFalse(log.contains("pub-session-1") || log.contains("work/lane"), "no lane or session name leaks into the note")
    }

    func testNoNoteWhenNothingClosedOrWhenThePolicyIsThere() throws {
        let h = try home()
        try transcript(h, dir: "-work-lane", session: "pub", lines: [msg("c", 1, 10), msg("d", 5, 10)])
        LaneCostRecorder.recordClosed(previous: [live("pub", cwd: "/work/lane")], current: [live("pub", cwd: "/work/lane")], env: env(h, nil))
        LaneCostRecorder.recordClosed(previous: [live("pub", cwd: "/work/lane")], current: [], env: env(h, policy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.appendingPathComponent(".floor/lane-cost/refused.log").path))
    }

    // MARK: a lane under another config root has no honest share

    private func configRootTranscript(_ root: URL, session: String, lines: [String]) throws {
        let d = root.appendingPathComponent("projects/-work-lane", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let head = "{\"type\":\"session-owner\",\"accountUuid\":\"u1\",\"sessionId\":\"\(session)\"}"
        try ([head] + lines).joined(separator: "\n").appending("\n")
            .write(to: d.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
    }

    func testALaneUnderAnotherConfigRootGetsNoShareAndTheReasonSaysWhy() throws {
        let h = try home()
        let cfg = h.appendingPathComponent("other-config", isDirectory: true)
        try configRootTranscript(cfg, session: "lane-in-cfg", lines: [msg("a", 1, 100), msg("b", 5, 100)])
        // the same account has other work under ~/.claude: the total the share divides by would not include the lane
        try transcript(h, dir: "-p2", session: "peer", lines: [msg("c", 2, 900)])
        var l = live("lane-in-cfg", cwd: "/work/lane")
        l.configDir = cfg.path
        let written = LaneCostRecorder.recordClosed(previous: [l], current: [], env: env(h, PrivateLanes(folders: [])))
        let r = try XCTUnwrap(written.first)
        XCTAssertEqual(r.tokens?.output, 200, "the lane's own transcript is found under its config root")
        XCTAssertNil(r.quotaShare, "200 of a 900 total that does not contain the lane is not a share")
        XCTAssertTrue(r.unread["quota_share"]?.contains("config") == true, r.unread["quota_share"] ?? "no reason")
    }

    func testALaneUnderTheDefaultRootStillGetsItsShare() throws {
        let h = try home()
        try transcript(h, dir: "-work-lane", session: "lane-default", lines: [msg("a", 1, 100), msg("b", 5, 100)])
        try transcript(h, dir: "-p2", session: "peer", lines: [msg("c", 2, 300)])
        var l = live("lane-default", cwd: "/work/lane")
        l.configDir = h.appendingPathComponent(".claude").path
        let r = try XCTUnwrap(LaneCostRecorder.recordClosed(previous: [l], current: [], env: env(h, PrivateLanes(folders: []))).first)
        XCTAssertEqual(try XCTUnwrap(r.quotaShare), 200.0 / 500.0, accuracy: 0.0001, "control: the default root is inside the total")
    }

    func testThePolicyFileThatTowerReadsIsTheFloorsOwnCopy() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(LaneCostWiring.policyURL(home: home).path, "/Users/x/.floor/private-lanes.json")
    }
}
