import Foundation
import XCTest
@testable import Tower

/// The TypeSafe (Jev) lane shows ONE fact: a credit balance the user entered, labelled as
/// entered, with the amber and red thresholds applied. TypeSafe publishes no billing or
/// usage endpoint, so there is nothing to fetch and no capture time anywhere. Nothing ships
/// by default: with no entry there is no row. Every figure here is invented.
final class TypeSafeBalanceTests: XCTestCase {
    /// The traffic light applies to the entered balance, strictly UNDER the lines the
    /// issue pins: exactly 10.00 is still green and exactly 5.00 is still amber.
    func testBalanceLevelBoundary() {
        XCTAssertEqual(TypeSafe.balanceLevel(4.99), .red)
        XCTAssertEqual(TypeSafe.balanceLevel(5.00), .amber)
        XCTAssertEqual(TypeSafe.balanceLevel(9.99), .amber)
        XCTAssertEqual(TypeSafe.balanceLevel(10.00), .green)
        XCTAssertEqual(TypeSafe.balanceLevel(0), .red)
        XCTAssertEqual(TypeSafe.balanceLevel(12.00), .green)
    }

    /// With no entry there is no figure, no row, no hint, and MCP says entered false.
    func testNoEntryMeansNoRow() {
        let (defaults, suite) = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let now = Self.day("2026-09-20")
        XCTAssertNil(TypeSafe.entry(defaults: defaults))
        XCTAssertFalse(TypeSafe.isEntered(defaults: defaults))
        XCTAssertEqual(CLI.typeSafeStatusRowLines(now: now, defaults: defaults), [])
        XCTAssertNil(TypeSafe.reenterHint(now: now, defaults: defaults))
        let json = TowerMCPService.typesafeJSON(now: now, defaults: defaults)
        XCTAssertEqual(json["entered"], .bool(false))
        XCTAssertEqual(json["balanceUSD"], .null)
        XCTAssertEqual(json["level"], .null)
        XCTAssertEqual(json["reenter"], .null)
    }

    /// The entered figure carries its age and greys out past three days: a week-old number
    /// must read as stale, not as a live reading.
    func testEnteredBalanceAgesAndMarksStaleAfterThreeDays() {
        let (defaults, suite) = Self.entered(12.00, on: "2026-09-18")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TypeSafe.balanceAgeDays(now: Self.day("2026-09-18"), defaults: defaults), 0)
        XCTAssertEqual(TypeSafe.balanceAgeDays(now: Self.day("2026-09-21"), defaults: defaults), 3)
        XCTAssertFalse(TypeSafe.balanceIsStale(now: Self.day("2026-09-21"), defaults: defaults), "day three is still fresh")
        XCTAssertTrue(TypeSafe.balanceIsStale(now: Self.day("2026-09-22"), defaults: defaults), "day four is stale")
        XCTAssertEqual(
            TypeSafe.statusRowText(now: Self.day("2026-09-19"), defaults: defaults),
            "balance $12.00 (entered 09-18 · 1d ago), not live")
        XCTAssertEqual(
            TypeSafe.statusRowText(now: Self.day("2026-09-23"), defaults: defaults),
            "balance $12.00 (entered 09-18 · 5d ago), stale, not live")
        XCTAssertEqual(TypeSafe.enteredLabel(now: Self.day("2026-09-19"), defaults: defaults), "entered 09-18 · 1d ago")
    }

    /// Days count by calendar midnights, not 86,400-second spans: an instant still on
    /// the third calendar day is day three even at 23:59, and one instant into the
    /// fourth day is day four. A DST 23- or 25-hour day cannot shift the count.
    func testAgeCountsCalendarDaysNotSeconds() {
        let (defaults, suite) = Self.entered(12.00, on: "2026-09-18")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let late = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 0, of: Self.day("2026-09-21"))!
        XCTAssertEqual(TypeSafe.balanceAgeDays(now: late, defaults: defaults), 3, "still the third calendar day")
        XCTAssertFalse(TypeSafe.balanceIsStale(now: late, defaults: defaults))
        let early = Calendar.current.date(
            bySettingHour: 0, minute: 1, second: 0, of: Self.day("2026-09-22"))!
        XCTAssertEqual(TypeSafe.balanceAgeDays(now: early, defaults: defaults), 4, "the fourth midnight starts day four")
        XCTAssertTrue(TypeSafe.balanceIsStale(now: early, defaults: defaults))
    }

    /// Money text for the row is plain cents formatting.
    func testMoneyShape() {
        XCTAssertEqual(TypeSafe.money(0), "$0.00")
        XCTAssertEqual(TypeSafe.money(12), "$12.00")
        XCTAssertEqual(TypeSafe.money(9.99), "$9.99")
    }

    /// The `tower status` row shape, pinned exactly: the entered balance and its not-live
    /// qualifier, and never a quota window.
    func testStatusRowTextShape() {
        let (defaults, suite) = Self.entered(12.00, on: "2026-09-18")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let lines = CLI.typeSafeStatusRowLines(now: Self.day("2026-09-20"), defaults: defaults)
        XCTAssertEqual(lines, [
            "  typesafe    BALANCE",
            "      balance $12.00 (entered 09-18 · 2d ago), not live",
        ])
        XCTAssertFalse(lines.joined(separator: "\n").contains("7d"))
    }

    /// A stale figure is actionable: nothing can fetch the balance, so every surface names
    /// the one fix, a re-entry through `tower_config_set typesafe.balanceUSD`. A fresh
    /// figure carries no hint.
    func testStaleFigureNamesHowToReenter() {
        let (defaults, suite) = Self.entered(12.00, on: "2026-09-18")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        XCTAssertNil(TypeSafe.reenterHint(now: Self.day("2026-09-20"), defaults: defaults))
        let hint = TypeSafe.reenterHint(now: Self.day("2026-09-27"), defaults: defaults)
        XCTAssertEqual(hint, "read TypeSafe console Billing, then tower_config_set typesafe.balanceUSD <usd>")
        XCTAssertEqual(
            CLI.typeSafeStatusRowLines(now: Self.day("2026-09-27"), defaults: defaults),
            [
                "  typesafe    BALANCE",
                "      balance $12.00 (entered 09-18 · 9d ago), stale, not live",
                "      read TypeSafe console Billing, then tower_config_set typesafe.balanceUSD <usd>",
            ])
        let json = TowerMCPService.typesafeJSON(now: Self.day("2026-09-27"), defaults: defaults)
        XCTAssertEqual(json["entered"], .bool(true))
        XCTAssertEqual(json["stale"], .bool(true))
        XCTAssertEqual(json["reenter"], .string(hint))
    }

    /// A re-entry replaces the previous figure, is dated the day it was made, and turns the
    /// row fresh again; clearing it hides the row.
    func testReentryReplacesTheFigureAndClearHidesTheRow() {
        let (defaults, suite) = Self.entered(12.00, on: "2026-09-18")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let now = Self.day("2026-09-27")
        let entered = TypeSafe.enter(7.5, now: now, defaults: defaults)
        XCTAssertEqual(entered, TypeSafe.Entry(usd: 7.5, asOf: "2026-09-27"))
        XCTAssertEqual(TypeSafe.entry(defaults: defaults), entered)
        XCTAssertFalse(TypeSafe.balanceIsStale(now: now, defaults: defaults))
        XCTAssertNil(TypeSafe.reenterHint(now: now, defaults: defaults))
        XCTAssertEqual(
            TypeSafe.statusRowText(now: now, defaults: defaults),
            "balance $7.50 (entered 09-27 · 0d ago), not live")
        let json = TowerMCPService.typesafeJSON(now: now, defaults: defaults)
        XCTAssertEqual(json["balanceUSD"], .number(7.5))
        XCTAssertEqual(json["level"], .string("amber"))
        XCTAssertEqual(json["reenter"], .null)

        TypeSafe.clearEntry(defaults: defaults)
        XCTAssertNil(TypeSafe.entry(defaults: defaults))
        XCTAssertEqual(CLI.typeSafeStatusRowLines(now: now, defaults: defaults), [])
    }

    /// A balance with no as-of day cannot say how old it is, so it does not count as an
    /// entry: the row stays hidden.
    func testBalanceWithoutAnAsOfDayIsNoEntry() {
        let (defaults, suite) = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(3.0, forKey: TypeSafe.balanceKey)
        XCTAssertNil(TypeSafe.entry(defaults: defaults))
    }

    private static func suite() -> (UserDefaults, String) {
        let name = "tower-typesafe-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private static func entered(_ usd: Double, on day: String) -> (UserDefaults, String) {
        let (defaults, name) = suite()
        TypeSafe.enter(usd, now: Self.day(day), defaults: defaults)
        return (defaults, name)
    }

    private static func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
}
