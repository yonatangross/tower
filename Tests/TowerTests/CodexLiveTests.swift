import Foundation
import XCTest
@testable import Tower

/// 2026-09-22: the Codex row read "stale 2h" whenever no Codex session had written a
/// rollout (18:48 to 20:46 had none), and it never said which model a seat ran while
/// gpt-6-sol and gpt-6-luna shipped the same day.
final class CodexLiveTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// The exact shape `codex app-server` returned live on 2026-09-22 (codex-cli 0.155.1),
    /// reset credits trimmed.
    private let liveAnswer = #"{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":72,"windowDurationMins":10080,"resetsAt":1790412485},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"pro","rateLimitReachedType":null}}}"#

    func testLiveAnswerParsesIntoAFreshReading() throws {
        let reading = try XCTUnwrap(CodexLive.parse(line: Data(liveAnswer.utf8), now: now))
        XCTAssertEqual(reading.capturedAt, now, "a live answer is a capture taken now, not a file mtime")
        XCTAssertNil(reading.exhaustion)
        let limits = try XCTUnwrap(reading.limits)
        XCTAssertEqual(limits.primary?.used_percent, 72)
        XCTAssertEqual(limits.primary?.window_minutes, 10080)
        XCTAssertEqual(limits.primary?.resetDate, Date(timeIntervalSince1970: 1_790_412_485))
        XCTAssertEqual(limits.plan_type, "pro")

        var snap = AccountSnapshot(email: "user-c@example.com", nickname: "eve", plan: "pro")
        CodexReader.apply(reading, to: &snap)
        XCTAssertEqual(snap.weeklyPct, 72)
        XCTAssertEqual(snap.worstTrust(now: now), .live, "the row is live without any rollout written")
    }

    func testOtherMessagesAndEmptyAnswersAreIgnored() {
        let handshake = #"{"id":1,"result":{"userAgent":"tower/0.155.1","codexHome":"/x"}}"#
        XCTAssertNil(CodexLive.parse(line: Data(handshake.utf8), now: now))
        let notification = #"{"method":"account/rateLimits/updated","params":{}}"#
        XCTAssertNil(CodexLive.parse(line: Data(notification.utf8), now: now))
        let noWindow = #"{"id":2,"result":{"rateLimits":{"primary":null,"planType":"pro"}}}"#
        XCTAssertNil(CodexLive.parse(line: Data(noWindow.utf8), now: now),
                     "no window is no reading, never a zero")
        XCTAssertNil(CodexLive.parse(line: Data("not json".utf8), now: now))
    }

    func testANamedRefusalIsAnExhaustion() throws {
        let reached = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":1790412485},"planType":"pro","rateLimitReachedType":"rate_limit_reached"}}}"#
        let reading = try XCTUnwrap(CodexLive.parse(line: Data(reached.utf8), now: now))
        let out = try XCTUnwrap(reading.exhaustion)
        XCTAssertEqual(out.resetsAt, Date(timeIntervalSince1970: 1_790_412_485))
        XCTAssertEqual(out.message, "Codex rate limit reached")
    }

    func testARefusalReopensWhenTheFullWindowDoes() throws {
        let secondaryFull = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1790000000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1790412485},"planType":"pro","rateLimitReachedType":"rate_limit_reached"}}}"#
        let reading = try XCTUnwrap(CodexLive.parse(line: Data(secondaryFull.utf8), now: now))
        XCTAssertEqual(reading.exhaustion?.resetsAt, Date(timeIntervalSince1970: 1_790_412_485),
                       "the window that is full decides the reopening, not the primary")
    }

    func testLiveWinsOverDiskAndDiskIsTheFallback() {
        let disk = CodexReader.Reading(limits: nil, capturedAt: now.addingTimeInterval(-2 * 3600))
        let live = CodexReader.Reading(limits: nil, capturedAt: now)
        XCTAssertEqual(CodexReader.preferred(live: live, disk: disk)?.capturedAt, now)
        XCTAssertEqual(CodexReader.preferred(live: nil, disk: disk)?.capturedAt, disk.capturedAt)
        XCTAssertNil(CodexReader.preferred(live: nil, disk: nil))
        var diskRead = false
        _ = CodexReader.preferred(live: live, disk: { diskRead = true; return disk }())
        XCTAssertFalse(diskRead, "the rollout walk is skipped when the CLI answered")
    }

    func testSeedFoldsTheLiveReadingAndTheModel() throws {
        let home = try FakeCodexHome()
        defer { home.remove() }
        // An old rollout at 71 %, two hours before `now`, running gpt-6-luna.
        try home.rollout(minutesAgo: 120, now: now, lines: [
            #"{"type":"turn_context","payload":{"turn_id":"t","model":"gpt-6-luna"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":71,"window_minutes":10080,"resets_at":1790412485},"plan_type":"pro"}}}"#,
        ])
        try home.config(#"model_reasoning_effort = "medium"\#nmodel = "gpt-6-astra"\#n[profiles.x]\#nmodel = "o3"\#n"#)
        let store = Store(dir: home.root.appendingPathComponent("support"),
                          mirror: home.root.appendingPathComponent("claude/quota-cache.json"), now: { self.now })
        let live = try XCTUnwrap(CodexLive.parse(line: Data(liveAnswer.utf8), now: now))

        var accounts: [String: AccountSnapshot] = [:]
        store.seedCodexAccount(into: &accounts, live: live, home: home.root)
        let row = try XCTUnwrap(accounts.values.first { $0.kind == .codex })
        XCTAssertEqual(row.weeklyPct, 72, "the CLI's answer, not the two-hour-old rollout")
        XCTAssertEqual(row.capturedAt, now)
        XCTAssertEqual(row.model, "gpt-6-luna", "the model the newest session ran, not the config default")

        var diskOnly: [String: AccountSnapshot] = [:]
        store.seedCodexAccount(into: &diskOnly, live: nil, home: home.root)
        XCTAssertEqual(diskOnly.values.first?.weeklyPct, 71, "disk still serves when the CLI cannot be asked")
    }

    func testConfigModelReadsOnlyTheTopLevelKey() {
        XCTAssertEqual(CodexReader.configModel(toml: "model_reasoning_effort = \"medium\"\nmodel = \"gpt-6-astra\"\n"),
                       "gpt-6-astra")
        XCTAssertNil(CodexReader.configModel(toml: "[profiles.fast]\nmodel = \"o3\"\n"),
                     "a profile's model is not the default")
        XCTAssertNil(CodexReader.configModel(toml: "model_provider = \"openai\"\n"))
    }

    /// A throwaway ~ with .codex/auth.json, sessions and config.toml.
    private struct FakeCodexHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tower-codex-\(UUID().uuidString)")

        init() throws {
            let codex = root.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at: codex.appendingPathComponent("sessions/2026/09/22"),
                                                    withIntermediateDirectories: true)
            // id_token payload: {"email":"user-c@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}
            let payload = #"{"email":"user-c@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
            let b64 = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let auth = #"{"tokens":{"id_token":"e30.\#(b64).sig"}}"#
            try Data(auth.utf8).write(to: codex.appendingPathComponent("auth.json"))
        }

        func rollout(minutesAgo: Double, now: Date, lines: [String]) throws {
            let url = root.appendingPathComponent(".codex/sessions/2026/09/22/rollout-2026-09-22T18-46-21-a.jsonl")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
        }

        func config(_ toml: String) throws {
            try Data(toml.utf8).write(to: root.appendingPathComponent(".codex/config.toml"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
