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

        var snap = AccountSnapshot(email: "user-d@example.com", nickname: "eve", plan: "pro")
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

    /// Session files are shared by every login, so another account's rollout must not
    /// overwrite the quota this seat last read with an attributed answer.
    func testADiskSessionFromAnotherAccountNeverOverwritesTheSeat() throws {
        let home = try FakeCodexHome(email: "a@example.test")
        defer { home.remove() }
        try home.rollout(minutesAgo: 1, now: now, lines: [
            #"{"type":"turn_context","payload":{"turn_id":"t","model":"gpt-6-luna"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":71,"window_minutes":10080,"resets_at":1790412485},"plan_type":"pro"}}}"#,
        ])
        let store = Store(dir: home.root.appendingPathComponent("support"),
                          mirror: home.root.appendingPathComponent("claude/quota-cache.json"), now: { self.now })
        let key = AccountSnapshot.storeKey(email: "a@example.test", provider: .codex)
        var row = AccountSnapshot(email: "a@example.test", nickname: "a", plan: "pro")
        row.provider = .codex
        row.weeklyPct = 10
        row.model = "gpt-6-sol"
        row.capturedAt = now.addingTimeInterval(-3_600)
        var accounts = [key: row]
        XCTAssertNil(store.seedCodexAccount(into: &accounts, live: nil, home: home.root))
        XCTAssertEqual(accounts[key]?.weeklyPct, 10)
        XCTAssertEqual(accounts[key]?.capturedAt, row.capturedAt)
        XCTAssertEqual(accounts[key]?.model, "gpt-6-sol")
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
        store.seedCodexAccount(into: &accounts, live: (live, "user-d@example.com"), home: home.root)
        let row = try XCTUnwrap(accounts.values.first { $0.kind == .codex })
        XCTAssertEqual(row.weeklyPct, 72, "the CLI's answer, not the two-hour-old rollout")
        XCTAssertEqual(row.capturedAt, now)
        XCTAssertEqual(row.model, "gpt-6-luna", "the model the newest session ran, not the config default")

        var diskOnly: [String: AccountSnapshot] = [:]
        store.seedCodexAccount(into: &diskOnly, live: nil, home: home.root)
        XCTAssertNil(diskOnly.values.first?.weeklyPct, "an unattributed rollout is not a reading")
        XCTAssertNil(diskOnly.values.first?.capturedAt)
    }

    /// The login changes after the fold: the observed seat stays the one the answer updated.
    func testTheObservedCodexSeatIsTheOneTheLiveAnswerFoldedInto() throws {
        let first = try FakeCodexHome(email: "first@example.test")
        let second = try FakeCodexHome(email: "second@example.test")
        defer { first.remove(); second.remove() }
        let store = Store(dir: first.root.appendingPathComponent("support"),
                          mirror: first.root.appendingPathComponent("claude/quota-cache.json"), now: { self.now })
        let live = try XCTUnwrap(CodexLive.parse(line: Data(liveAnswer.utf8), now: now))
        let firstKey = AccountSnapshot.storeKey(email: "first@example.test", provider: .codex)
        let secondKey = AccountSnapshot.storeKey(email: "second@example.test", provider: .codex)

        var accounts: [String: AccountSnapshot] = [:]
        let folded = store.seedCodexAccount(into: &accounts, live: (live, "first@example.test"), home: first.root)
        XCTAssertEqual(folded, firstKey)
        XCTAssertEqual(CodexAuth.identity(home: second.root)?.email, "second@example.test")
        let observed = Refresher.observedKeys(
            claudeEmails: [], cursor: .unavailable, cursorKey: nil, openRouter: .unavailable,
            codexKey: folded, lanes: [:], saveError: nil)
        XCTAssertTrue(observed.contains(firstKey))
        XCTAssertFalse(observed.contains(secondKey), "the login now held was not the one read")

        var diskOnly: [String: AccountSnapshot] = [:]
        XCTAssertNil(store.seedCodexAccount(into: &diskOnly, live: nil, home: first.root),
                     "a disk fallback is not a read of this cycle")
    }

    /// The login switches between asking the CLI and folding its answer.
    func testALoginSwitchBetweenFetchAndFoldWritesNothing() throws {
        let second = try FakeCodexHome(email: "second@example.test")
        defer { second.remove() }
        let store = Store(dir: second.root.appendingPathComponent("support"),
                          mirror: second.root.appendingPathComponent("claude/quota-cache.json"), now: { self.now })
        let live = try XCTUnwrap(CodexLive.parse(line: Data(liveAnswer.utf8), now: now))
        let firstKey = AccountSnapshot.storeKey(email: "first@example.test", provider: .codex)
        let secondKey = AccountSnapshot.storeKey(email: "second@example.test", provider: .codex)
        var old = AccountSnapshot(email: "second@example.test", nickname: "second", plan: "pro")
        old.provider = .codex
        old.weeklyPct = 10
        old.capturedAt = now.addingTimeInterval(-60)
        var accounts = [secondKey: old]

        let folded = store.seedCodexAccount(into: &accounts, live: (live, "first@example.test"), home: second.root)
        XCTAssertNil(folded)
        XCTAssertEqual(accounts[secondKey]?.weeklyPct, 10, "the first login's numbers never reach the second row")
        XCTAssertEqual(accounts[secondKey]?.capturedAt, old.capturedAt)
        XCTAssertNil(accounts[firstKey])

        let observed = Refresher.observedKeys(
            claudeEmails: [], cursor: .unavailable, cursorKey: nil, openRouter: .unavailable,
            codexKey: folded, lanes: [:], saveError: nil)
        XCTAssertFalse(observed.contains(firstKey))
        XCTAssertFalse(observed.contains(secondKey))
        XCTAssertNotNil(ProviderCoverage.notCapturedReason(
            wanted: old, after: accounts[secondKey], observed: observed.contains(secondKey), now: now))
    }

    private func ownerLine(_ id: Int, _ email: String) -> Data {
        Data(#"{"id":\#(id),"result":{"account":{"type":"chatgpt","email":"\#(email)","planType":"pro"}}}"#.utf8)
    }

    /// The login goes A, B, A while the CLI answers: B's numbers must never land on A.
    func testAnAnswerFromAnotherOwnerNeverLandsOnTheSeatHeldAtFold() throws {
        let holder = try FakeCodexHome(email: "a@example.test")
        defer { holder.remove() }
        let store = Store(dir: holder.root.appendingPathComponent("support"),
                          mirror: holder.root.appendingPathComponent("claude/quota-cache.json"), now: { self.now })
        var collector = CodexLive.AnswerCollector()
        XCTAssertEqual(collector.add(line: ownerLine(CodexLive.ownerBeforeID, "b@example.test"), now: now),
                       CodexLive.rateLimitsRequest, "the quota is asked only after the owner answered")
        XCTAssertEqual(collector.add(line: Data(liveAnswer.utf8), now: now),
                       CodexLive.ownerAfterRequest, "the second owner read is asked only after the quota")
        XCTAssertNil(collector.add(line: ownerLine(CodexLive.ownerAfterID, "b@example.test"), now: now))
        XCTAssertTrue(collector.isDone)
        let answer = try XCTUnwrap(collector.answer)
        XCTAssertEqual(answer.owner, "b@example.test")

        let key = AccountSnapshot.storeKey(email: "a@example.test", provider: .codex)
        var row = AccountSnapshot(email: "a@example.test", nickname: "a", plan: "pro")
        row.provider = .codex
        row.weeklyPct = 10
        row.capturedAt = now.addingTimeInterval(-60)
        var accounts = [key: row]
        let folded = store.seedCodexAccount(into: &accounts, live: (answer.reading, answer.owner),
                                            home: holder.root)
        XCTAssertNil(folded)
        XCTAssertEqual(accounts[key]?.weeklyPct, 10, "B's 72 % must not reach A's row")
        XCTAssertEqual(accounts[key]?.capturedAt, row.capturedAt)
        let observed = Refresher.observedKeys(
            claudeEmails: [], cursor: .unavailable, cursorKey: nil, openRouter: .unavailable,
            codexKey: folded, lanes: [:], saveError: nil)
        XCTAssertFalse(observed.contains(key))
    }

    func testAnAnswerNeedsOneOwnerOnBothSides() {
        var moved = CodexLive.AnswerCollector()
        moved.add(line: ownerLine(CodexLive.ownerBeforeID, "a@example.test"), now: now)
        moved.add(line: Data(liveAnswer.utf8), now: now)
        moved.add(line: ownerLine(CodexLive.ownerAfterID, "b@example.test"), now: now)
        XCTAssertTrue(moved.isDone)
        XCTAssertNil(moved.answer, "the owner changed around the read")

        var unnamed = CodexLive.AnswerCollector()
        unnamed.add(line: Data(#"{"id":3,"error":{"code":-32601,"message":"unknown method"}}"#.utf8), now: now)
        XCTAssertTrue(unnamed.isDone, "a CLI that cannot name its account stops the read at once")
        XCTAssertNil(unnamed.answer)
    }

    func testRepliesOutOfOrderGiveNoAnswer() {
        var quotaFirst = CodexLive.AnswerCollector()
        XCTAssertNil(quotaFirst.add(line: Data(liveAnswer.utf8), now: now))
        XCTAssertTrue(quotaFirst.isDone)
        XCTAssertNil(quotaFirst.answer, "a quota with no owner read before it")

        var ownerTwice = CodexLive.AnswerCollector()
        ownerTwice.add(line: ownerLine(CodexLive.ownerBeforeID, "a@example.test"), now: now)
        XCTAssertNil(ownerTwice.add(line: ownerLine(CodexLive.ownerAfterID, "a@example.test"), now: now))
        XCTAssertTrue(ownerTwice.isDone)
        XCTAssertNil(ownerTwice.answer, "both owner reads came before the quota")
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

        init(email: String = "user-d@example.com") throws {
            let codex = root.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at: codex.appendingPathComponent("sessions/2026/09/22"),
                                                    withIntermediateDirectories: true)
            // id_token payload: {"email":"<email>","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}
            let payload = #"{"email":"\#(email)","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
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
