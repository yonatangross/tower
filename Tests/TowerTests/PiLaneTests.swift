import XCTest
import Foundation
@testable import Tower

/// Fixtures follow the entry shape pi-coding-agent 1.5.0 writes: `type`, `id`, `timestamp`
/// (ISO string) on the entry, and `role`, `provider`, `model`, `usage.cost.total` and an epoch
/// millisecond `timestamp` on an assistant message. Every model name, path and cost is
/// invented. Each test writes under its own temp root through `TOWER_PI_DIR`, so the real
/// Pi directory is never read.
final class PiLaneTests: XCTestCase {
    /// UTC, so month and day edges hold on any machine.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let now = DateParse.parse("2026-11-04T12:00:00Z")!

    static func turn(_ id: String, _ at: String, _ usd: Double, role: String = "assistant") -> String {
        #"{"type":"message","id":"\#(id)","parentId":null,"timestamp":"\#(at)","message":{"role":"\#(role)","provider":"openrouter","model":"vendor/model-x","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":15,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":\#(usd),"totalFromProvider":\#(usd)}},"timestamp":1}}"#
    }

    func tally(_ lines: [String]) -> PiLane.Spend {
        var t = PiLane.Tally(now: Self.now, calendar: Self.utc)
        t.add(text: lines.joined(separator: "\n"))
        return t.spend
    }

    // MARK: Parser

    func testSumsMonthAndToday() {
        let s = tally([
            Self.turn("a", "2026-11-04T08:00:00.000Z", 1.50),
            Self.turn("b", "2026-11-04T00:00:00.000Z", 0.25),
            Self.turn("c", "2026-11-01T00:00:00.000Z", 3.00),
        ])
        XCTAssertEqual(s.monthUSD, 4.75, accuracy: 1e-9)
        XCTAssertEqual(s.todayUSD, 1.75, accuracy: 1e-9)
        XCTAssertEqual(s.messages, 3)
        XCTAssertEqual(s.newest, DateParse.parse("2026-11-04T08:00:00Z"))
    }

    func testOtherMonthsAreExcluded() {
        let s = tally([
            Self.turn("old", "2026-10-31T23:59:59.000Z", 50),
            Self.turn("older", "2025-11-04T10:00:00.000Z", 50),
            Self.turn("new", "2026-11-02T10:00:00.000Z", 2),
        ])
        XCTAssertEqual(s.monthUSD, 2, accuracy: 1e-9)
        XCTAssertEqual(s.messages, 1)
    }

    func testMalformedLinesAreSkippedAndCounted() {
        let s = tally([
            "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"usage\":{\"cost\":",
            "not json at all \"assistant\" \"cost\"",
            Self.turn("ok", "2026-11-03T10:00:00.000Z", 1),
            "",
        ])
        XCTAssertEqual(s.monthUSD, 1, accuracy: 1e-9)
        XCTAssertEqual(s.skippedLines, 2)
    }

    func testOnlyAssistantTurnsCountAndEachEntryOnce() {
        let s = tally([
            Self.turn("u", "2026-11-03T10:00:00.000Z", 7, role: "user"),
            Self.turn("dup", "2026-11-03T10:00:00.000Z", 1),
            Self.turn("dup", "2026-11-03T10:00:00.000Z", 1),
        ])
        XCTAssertEqual(s.monthUSD, 1, accuracy: 1e-9)
        XCTAssertEqual(s.messages, 1)
    }

    func testEpochMillisecondTimestampIsAccepted() {
        let ms = Int(DateParse.parse("2026-11-04T06:00:00Z")!.timeIntervalSince1970 * 1000)
        let line = #"{"type":"message","id":"e","message":{"role":"assistant","usage":{"cost":{"total":0.5}},"timestamp":\#(ms)}}"#
        let s = tally([line])
        XCTAssertEqual(s.todayUSD, 0.5, accuracy: 1e-9)
    }

    // MARK: Share arithmetic

    func testShareOfOpenRouterBudget() {
        var s = PiLane.Spend(provider: "openrouter", model: "vendor/model-x")
        s.monthUSD = 5
        let share = PiLane.share(s, openRouter: .ok(OpenRouter.Budget(spent: 60, limit: 100)))
        XCTAssertEqual(share, .openRouter(pct: 5, leftUSD: 40, limitUSD: 100))
        XCTAssertEqual(PiLane.shareLine(share), "5% of OpenRouter budget · $40.00 left")
    }

    func testShareUnderOnePercentIsNotZero() {
        var s = PiLane.Spend(provider: "openrouter")
        s.monthUSD = 0.2
        let share = PiLane.share(s, openRouter: .ok(OpenRouter.Budget(spent: 1, limit: 100)))
        XCTAssertTrue(PiLane.shareLine(share).hasPrefix("<1% of OpenRouter budget"))
    }

    func testNoOpenRouterMeansSpendOnlyWithAReason() {
        let s = PiLane.Spend(provider: "openrouter")
        XCTAssertEqual(PiLane.share(s, openRouter: .notConfigured), .spendOnly("no OpenRouter key in Tower"))
        XCTAssertEqual(PiLane.share(s, openRouter: .unavailable), .spendOnly("OpenRouter balance not readable"))
        XCTAssertEqual(PiLane.share(s, openRouter: .rejected(401, keyFingerprint: nil, lastSuccessAt: nil)),
                       .spendOnly("OpenRouter refused the key (HTTP 401)"))
        XCTAssertEqual(PiLane.share(PiLane.Spend(provider: "anthropic"),
                                    openRouter: .ok(OpenRouter.Budget(spent: 1, limit: 10))),
                       .spendOnly("Pi runs on anthropic, not OpenRouter"))
        XCTAssertEqual(PiLane.share(PiLane.Spend(), openRouter: .notConfigured),
                       .spendOnly("settings.json names no default provider"))
    }

    // MARK: Disk

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-pi-\(UUID().uuidString)/agent")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func write(_ root: URL, _ rel: String, _ text: String, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func testMissingDirectoryHidesTheRow() throws {
        let root = try makeRoot().appendingPathComponent("absent")
        XCTAssertEqual(PiLane.read(env: [PiLane.rootEnvKey: root.path], now: Self.now, calendar: Self.utc),
                       .notConfigured)
    }

    func testReadsSettingsAndSessionsAcrossFiles() throws {
        let root = try makeRoot()
        try write(root, "settings.json", #"{"defaultProvider":"openrouter","defaultModel":"vendor/model-x"}"#)
        try write(root, "sessions/--proj-a--/one.jsonl",
                  [Self.turn("1", "2026-11-04T09:00:00.000Z", 1),
                   Self.turn("2", "2026-11-02T09:00:00.000Z", 2)].joined(separator: "\n") + "\n",
                  modified: Self.now)
        // A fork carries its parent's entries: the copy of entry 2 counts once.
        try write(root, "sessions/--proj-b--/fork.jsonl",
                  Self.turn("2", "2026-11-02T09:00:00.000Z", 2) + "\n", modified: Self.now)
        // Last modified in October: never opened.
        try write(root, "sessions/--proj-a--/old.jsonl",
                  Self.turn("x", "2026-11-03T09:00:00.000Z", 99) + "\n",
                  modified: DateParse.parse("2026-10-20T00:00:00Z"))
        // Pi's secrets file: present, and must never matter.
        try write(root, "auth.json", "{}")

        guard case .ok(let r) = PiLane.read(env: [PiLane.rootEnvKey: root.path],
                                            now: Self.now, calendar: Self.utc),
              case .spend(let s) = r.usage else { return XCTFail("expected a spend reading") }
        XCTAssertEqual(r.provider, .pi)
        XCTAssertEqual(s.provider, "openrouter")
        XCTAssertEqual(s.model, "vendor/model-x")
        XCTAssertEqual(s.monthUSD, 3, accuracy: 1e-9)
        XCTAssertEqual(s.todayUSD, 1, accuracy: 1e-9)
        XCTAssertEqual(s.files, 2)
        XCTAssertEqual(AgentLane.modelLine(r), "openrouter · vendor/model-x")
        XCTAssertEqual(AgentLane.usageLine(r), "$3.00 this month · $1.00 today")
    }

    func testOversizedFileIsReadAsATailAndMarkedPartial() throws {
        let root = try makeRoot()
        let filler = String(repeating: "x", count: 400)
        let late = Self.turn("late", "2026-11-04T09:00:00.000Z", 1)
        let text = [Self.turn("early", "2026-11-01T09:00:00.000Z", 5), "{\"pad\":\"\(filler)\"}",
                    late].joined(separator: "\n") + "\n"
        try write(root, "sessions/p/s.jsonl", text, modified: Self.now)
        var t = PiLane.Tally(now: Self.now, calendar: Self.utc)
        // The tail starts inside the pad line, so the early turn is out of the read.
        PiLane.stream(root.appendingPathComponent("sessions/p/s.jsonl"), into: &t,
                      maxBytes: late.utf8.count + 100)
        XCTAssertEqual(t.spend.monthUSD, 1, accuracy: 1e-9)
        XCTAssertEqual(t.spend.partialFiles, 1)
        XCTAssertTrue(PiLane.spendLine(t.spend).contains("at least"))
    }

    func testUnreadableSettingsIsShownNotHidden() throws {
        let root = try makeRoot()
        try write(root, "settings.json", "not json")
        guard case .unavailable = PiLane.read(env: [PiLane.rootEnvKey: root.path], now: Self.now)
        else { return XCTFail("expected unavailable") }
    }

    func testStatusLinesCarryTheShare() {
        var s = PiLane.Spend(provider: "openrouter", model: "vendor/model-x")
        s.monthUSD = 10
        s.todayUSD = 1
        let reading = AgentLane.Reading(provider: .pi, configModel: s.model, lastDispatch: nil,
                                        lastLimitHit: nil, usage: .spend(s))
        let lines = PiLane.statusLines(.ok(reading), openRouter: .ok(OpenRouter.Budget(spent: 30, limit: 50)))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains("$10.00 this month · $1.00 today"))
        XCTAssertTrue(lines[2].contains("20% of OpenRouter budget · $20.00 left"))
        XCTAssertEqual(PiLane.statusLines(.notConfigured, openRouter: .notConfigured), [])
    }
}
