import Foundation
import XCTest
@testable import Tower

/// 2026-09-22: the Cursor row at 97 to 100 % was the METERED pool that Opus spends, while
/// Cursor Auto is unmetered. The row said "capped 100%" under dashboard names ("Cursor
/// Models", "Other Models"), and conductors twice read the seat as dead.
final class CursorPoolMeaningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func cursor(auto: Double?, metered: Double?, capturedAgo: TimeInterval = 30) -> AccountSnapshot {
        let reading = CursorUsage.Reading(email: "user-e@example.com", plan: "ultra",
                                          cursorModelsPct: auto, otherModelsPct: metered,
                                          periodResetsAt: now.addingTimeInterval(86_400))
        var snap = AccountSnapshot(email: reading.email, nickname: "ben", plan: "ultra")
        CursorUsage.apply(reading, to: &snap, now: now.addingTimeInterval(-capturedAgo))
        return snap
    }

    func testAFullMeteredPoolRestsAsOpusOnlyNotAsADeadSeat() throws {
        let seat = cursor(auto: 73, metered: 100)
        let split = AccountSnapshot.partition([seat], now: now)
        let reason = try XCTUnwrap(split.resting.first?.1)
        XCTAssertEqual(reason, .meteredCapped(100))
        XCTAssertEqual(reason.text, "Opus pool capped 100% · Auto unmetered")
        XCTAssertTrue(reason.isCapped)
        XCTAssertTrue(reason.isTimeGated, "the metered pool refills on the billing clock")
        XCTAssertEqual(seat.bindingUsableFor(now: now), "Auto")
    }

    func testTheCLINamesWhatEachPoolMeans() {
        let lines = CLI.statusRowLines(cursor(auto: 73, metered: 80), activeEmail: nil, refreshError: nil, now: now)
        XCTAssertTrue(lines.contains { $0.contains("Auto unmetered") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("Opus metered") }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("Other Models") }, "the dashboard name hid the meter")
    }

    func testStoredLabelsStayTheDashboards() {
        // The mirror and the store key pools by label; only the words a person reads move.
        let seat = cursor(auto: 1, metered: 2)
        XCTAssertEqual(seat.scoped.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(CursorPool.displayLabel("Cursor Models"), "Auto unmetered")
        XCTAssertEqual(CursorPool.displayLabel("Other Models"), "Opus metered")
        XCTAssertEqual(CursorPool.displayLabel("Fable"), "Fable")
    }

    func testLaneFlagFiresOnlyWhenTheMeteredPoolIsFullAndLive() throws {
        let full = cursor(auto: 73, metered: 97)
        let autoLane = try XCTUnwrap(CursorPool.laneFlag(full, laneModel: "auto", now: now))
        XCTAssertEqual(autoLane, "Opus pool at 97 %: lanes asking for Opus get \"switch to a different model to continue with Opus\"; this lane runs Auto, which is unmetered")
        let opusLane = try XCTUnwrap(CursorPool.laneFlag(full, laneModel: "claude-opus-5-5", now: now))
        XCTAssertTrue(opusLane.hasSuffix("run them on Auto, which is unmetered"))

        XCTAssertNil(CursorPool.laneFlag(cursor(auto: 99, metered: 60), laneModel: "auto", now: now),
                     "the Auto pool filling is not an Opus refusal")
        XCTAssertNil(CursorPool.laneFlag(cursor(auto: 10, metered: 100, capturedAgo: 3600), laneModel: "auto", now: now),
                     "a stale reading is not a present refusal")
        XCTAssertNil(CursorPool.laneFlag(nil, laneModel: "auto", now: now))
    }

    func testAnOlderReadingKeepsItsMeaningInsteadOfFlippingToCapped() {
        // Review finding: the live-only reader made a 20 minute old row fall back to "capped".
        let aging = cursor(auto: 73, metered: 100, capturedAgo: 20 * 60)
        XCTAssertEqual(aging.restingReason(now: now), .meteredCapped(100))
    }

    func testBothPoolsFullIsAPlainCap() throws {
        // Auto is unmetered by report, but a measured full Auto pool wins over the report.
        let full = cursor(auto: 100, metered: 100)
        XCTAssertEqual(full.restingReason(now: now), .capped(100))
        XCTAssertEqual(full.bindingUsableFor(now: now), "none")
        let flag = try XCTUnwrap(CursorPool.laneFlag(full, laneModel: "auto", now: now))
        XCTAssertTrue(flag.hasSuffix("; the Auto pool is full too"), flag)
    }

    func testAClaudeFableCapStillReadsAsBefore() {
        // The Cursor wording must not leak onto other providers.
        var claude = AccountSnapshot(email: "a@example.com", nickname: "a", plan: "max")
        claude.fiveHourPct = 20
        claude.fiveHourResetsAt = now.addingTimeInterval(3600)
        claude.weeklyPct = 97
        claude.weeklyResetsAt = now.addingTimeInterval(86_400)
        claude.capturedAt = now.addingTimeInterval(-30)
        XCTAssertEqual(claude.restingReason(now: now), .capped(97))
        XCTAssertEqual(claude.bindingUsableFor(now: now), "none")
    }
}
