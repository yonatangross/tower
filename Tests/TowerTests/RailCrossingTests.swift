import Foundation
import XCTest
@testable import Tower

/// The quota rail: amber and red marks on the row's two meters, one toast per account
/// crossing (never per tick), and the standing crossing written to the mirror as the
/// account's `crossing` field so a lane launcher can refuse an open above amber. These tests
/// drive the machine the way a poll cycle does: one account, one evaluate per capture.
final class RailCrossingTests: XCTestCase {
    /// A live account: captured now, both windows reset far in the future, so every
    /// reading is inside the freshness TTL and allowed to announce.
    private func liveAccount(nickname: String = "a", now: Date) -> AccountSnapshot {
        var snap = AccountSnapshot(email: "\(nickname)@example.com", nickname: nickname,
                                   plan: "max", capturedAt: now)
        snap.fiveHourResetsAt = now.addingTimeInterval(3_600)
        snap.weeklyResetsAt = now.addingTimeInterval(86_400)
        return snap
    }

    private func level(_ snap: AccountSnapshot) -> Rail.Level {
        Rail.Level(field: snap.crossing)
    }

    /// One poll cycle: set the 5h reading, run the machine, collect what it announced.
    private func tick(_ snap: inout AccountSnapshot, _ pct: Double, now: Date,
                      into toasts: inout [RailCrossing]) {
        snap.fiveHourPct = pct
        if let crossing = Rail.evaluate(&snap, now: now) { toasts.append(crossing) }
    }

    /// The acceptance drive: 70 to 95 through the machine is exactly two toasts, amber
    /// then red, and the field carries amber then red. Ticking inside a band, either
    /// band, adds no toast.
    func testDriveFromSeventyToNinetyFiveEmitsAmberThenRedExactlyOnce() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snap = liveAccount(now: now)
        var toasts: [RailCrossing] = []

        for pct in [70.0, 83.0, 84.0, 86.0] {
            tick(&snap, pct, now: now, into: &toasts)
        }
        XCTAssertEqual(toasts.map(\.level), [.amber])
        XCTAssertEqual(level(snap), .amber)

        for pct in [91.0, 93.0, 95.0] {
            tick(&snap, pct, now: now, into: &toasts)
        }
        XCTAssertEqual(toasts.map(\.level), [.amber, .red])
        XCTAssertEqual(toasts.map(\.pct), [83, 91])
        XCTAssertEqual(level(snap), .red)
    }

    /// Dropping back below 80 clears the flag, is silent, and a later re-crossing
    /// toasts again: the crossing belongs to the climb, not to the account forever.
    func testDropBelowEightyClearsTheFlagAndARecrossingToastsAgain() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snap = liveAccount(now: now)
        var toasts: [RailCrossing] = []
        tick(&snap, 83, now: now, into: &toasts)
        XCTAssertEqual(toasts.count, 1)

        tick(&snap, 70, now: now, into: &toasts)
        XCTAssertEqual(toasts.count, 1, "a drop back below the mark is silent")
        XCTAssertNil(snap.crossing, "the flag clears with the drop")

        tick(&snap, 83, now: now, into: &toasts)
        XCTAssertEqual(toasts.count, 2, "a later re-crossing toasts again")
        XCTAssertEqual(toasts.map(\.level), [.amber, .amber])
        XCTAssertEqual(level(snap), .amber)
    }

    /// Below 80 with no crossing: no toast, and the field never appears.
    func testBelowEightyProducesNoToastAndNoCacheFlag() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snap = liveAccount(now: now)
        for pct in [0.0, 40.0, 70.0, 79.9] {
            snap.fiveHourPct = pct
            snap.weeklyPct = pct
            XCTAssertNil(Rail.evaluate(&snap, now: now))
            XCTAssertNil(snap.crossing, "no flag at \(pct)")
        }
    }

    /// Pinned boundaries on the 5h meter: the marks are inclusive, so 80.0 is the first
    /// amber reading and 90.0 the first red, both through `level` and through the
    /// machine from a clean slate.
    func testFiveHourBoundaries() {
        XCTAssertEqual(Rail.level(fiveHour: 79.9, weekly: nil), .none)
        XCTAssertEqual(Rail.level(fiveHour: 80.0, weekly: nil), .amber)
        XCTAssertEqual(Rail.level(fiveHour: 89.9, weekly: nil), .amber)
        XCTAssertEqual(Rail.level(fiveHour: 90.0, weekly: nil), .red)
        XCTAssertEqual(Rail.level(fiveHour: 100, weekly: nil), .red)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for (pct, want) in [(79.9, Rail.Level.none), (80.0, .amber),
                            (89.9, .amber), (90.0, .red)] {
            var snap = liveAccount(now: now)
            snap.fiveHourPct = pct
            let toast = Rail.evaluate(&snap, now: now)
            // No toast for none: the compare is against nil, not against .some(.none).
            let expected: Rail.Level? = want == .none ? nil : want
            XCTAssertEqual(toast?.level, expected, "\(pct)")
            XCTAssertEqual(level(snap), want, "\(pct)")
            XCTAssertEqual(toast != nil, want != .none, "\(pct) announces exactly when it crosses")
        }
    }

    /// The 7d meter carries only the red mark: the whole amber band crosses nothing
    /// there, 90.0 is red.
    func testWeeklyBoundaries() {
        XCTAssertEqual(Rail.level(fiveHour: nil, weekly: 80.0), .none)
        XCTAssertEqual(Rail.level(fiveHour: nil, weekly: 89.9), .none)
        XCTAssertEqual(Rail.level(fiveHour: nil, weekly: 90.0), .red)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snap = liveAccount(now: now)
        snap.weeklyPct = 89.9
        XCTAssertNil(Rail.evaluate(&snap, now: now))
        XCTAssertNil(snap.crossing)

        snap = liveAccount(now: now)
        snap.weeklyPct = 90.0
        let toast = Rail.evaluate(&snap, now: now)
        XCTAssertNotNil(toast, "the 7d red mark announces")
        XCTAssertEqual(toast?.pct, 90.0)
        XCTAssertEqual(snap.crossing, "red")
    }

    /// The crossing field rides the existing store and mirror unchanged: same file, same
    /// shapes, key omitted below 80 and valued amber then red as the account climbs.
    func testCrossingRidesTheMirrorRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { now })

        var climber = liveAccount(now: now)
        climber.fiveHourPct = 83
        XCTAssertNotNil(Rail.evaluate(&climber, now: now))
        var below = liveAccount(nickname: "b", now: now)
        below.fiveHourPct = 40

        let key = AccountSnapshot.storeKey(email: "a@example.com", provider: .claude)
        let belowKey = AccountSnapshot.storeKey(email: "b@example.com", provider: .claude)
        // The mirror is read once per save and asserted from memory, so the throwing
        // file reads never sit inside an assert.
        func mirrorRows() throws -> [String: [String: Any]] {
            let data = try Data(contentsOf: mirror)
            return try XCTUnwrap(JSONSerialization.jsonObject(
                with: data) as? [String: [String: Any]])
        }

        XCTAssertNil(store.save([key: climber, belowKey: below]))
        let diskOne = try Data(contentsOf: dir.appendingPathComponent("accounts.json"))
        let mirroredOne = try Data(contentsOf: mirror)
        XCTAssertEqual(diskOne, mirroredOne)
        var rows = try mirrorRows()
        XCTAssertEqual(rows[key]?["crossing"] as? String, "amber")
        XCTAssertFalse(rows[belowKey]?.keys.contains("crossing") ?? false, "absent below 80")

        climber.fiveHourPct = 91
        XCTAssertNotNil(Rail.evaluate(&climber, now: now))
        XCTAssertNil(store.save([key: climber, belowKey: below]))
        rows = try mirrorRows()
        XCTAssertEqual(rows[key]?["crossing"] as? String, "red")

        // Decoded straight off the mirror the field round-trips, and a row written
        // before the rail existed decodes with no flag.
        let decoded = try JSONDecoder().decode(
            [String: AccountSnapshot].self, from: try Data(contentsOf: mirror))
        XCTAssertEqual(decoded[key]?.crossing, "red")
        XCTAssertNil(decoded[belowKey]?.crossing)
        // scoped and notified are non-Optional with defaults, and Swift's synthesized
        // decoder only falls back for Optionals: every row the store ever wrote carries
        // them, so the legacy fixture does too.
        let legacyJSON = "{\"legacy\":{\"email\":\"l@example.com\",\"nickname\":\"l\"," +
            "\"plan\":\"max\",\"fiveHourPct\":85,\"scoped\":[],\"notified\":{}}}"
        let legacy = try JSONDecoder().decode(
            [String: AccountSnapshot].self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy["legacy"]?.crossing)

        // Cleared is absent again, not an empty string.
        climber.fiveHourPct = 70
        _ = Rail.evaluate(&climber, now: now)
        XCTAssertNil(store.save([key: climber, belowKey: below]))
        rows = try mirrorRows()
        XCTAssertFalse(rows[key]?.keys.contains("crossing") ?? false)
    }

    /// The first pass after an update back-fills standing bands from stored rows. A
    /// stale row writes its flag so the cache is protected immediately, but it never
    /// presents an old number as a fresh crossing: no toast.
    func testStaleRowWritesFlagSilently() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snap = liveAccount(now: now)
        snap.fiveHourPct = 91
        snap.capturedAt = now.addingTimeInterval(-3_600)
        XCTAssertNil(Rail.evaluate(&snap, now: now), "a stale reading never announces")
        XCTAssertEqual(snap.crossing, "red")

        // Once captured again, still no second toast while red stands.
        snap.capturedAt = now
        XCTAssertNil(Rail.evaluate(&snap, now: now))
        XCTAssertEqual(snap.crossing, "red")
    }

    /// The crossing state is per account: two accounts crossing produce two toasts, and
    /// one account's standing flag never silences the other.
    func testCrossingsArePerAccount() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var first = liveAccount(nickname: "a1", now: now)
        var second = liveAccount(nickname: "a2", now: now)
        first.fiveHourPct = 83
        second.fiveHourPct = 83
        let t1 = Rail.evaluate(&first, now: now)
        let t2 = Rail.evaluate(&second, now: now)
        XCTAssertEqual(t1?.nickname, "a1")
        XCTAssertEqual(t2?.nickname, "a2")
        XCTAssertNotEqual(t1, t2)
    }

    /// One capture that clears both marks at once announces the level the account is
    /// actually standing on: one red toast, not a replayed amber plus red.
    func testSingleTickJumpAnnouncesOnlyTheLevelReached() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snap = liveAccount(now: now)
        snap.fiveHourPct = 95
        let toast = Rail.evaluate(&snap, now: now)
        XCTAssertNotNil(toast, "one red toast, not a replayed amber plus red")
        XCTAssertEqual(toast?.pct, 95)
        XCTAssertEqual(snap.crossing, "red")
    }

    /// A window that ends drops the flag through the same `effective` arithmetic every
    /// mirror consumer applies, and a fall from red to amber (one window ended, the
    /// other still in the amber band) rewrites the field silently.
    func testWindowResetClearsTheFlagAndRedToAmberIsSilent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snap = liveAccount(now: now)
        snap.fiveHourPct = 91
        XCTAssertNotNil(Rail.evaluate(&snap, now: now))
        XCTAssertEqual(snap.crossing, "red")

        snap.fiveHourResetsAt = now.addingTimeInterval(-60)
        XCTAssertNil(Rail.evaluate(&snap, now: now), "a window that ended clears the flag")
        XCTAssertNil(snap.crossing)

        var week = liveAccount(now: now)
        week.fiveHourPct = 83
        week.weeklyPct = 92
        XCTAssertNotNil(Rail.evaluate(&week, now: now))
        XCTAssertEqual(week.crossing, "red")
        week.weeklyResetsAt = now.addingTimeInterval(-60)
        XCTAssertNil(Rail.evaluate(&week, now: now), "red falling to amber is silent")
        XCTAssertEqual(week.crossing, "amber")
    }

    /// The toast wording, exactly the shape the issue pins.
    func testToastWording() {
        let amber = RailCrossing(nickname: "A", level: .amber, pct: 83)
        XCTAssertEqual("\(amber.toastTitle): \(amber.toastBody)",
                       "account A at 83 %: no new stations on A, rotation brief due at 90 %")
        let red = RailCrossing(nickname: "A", level: .red, pct: 91)
        XCTAssertEqual("\(red.toastTitle): \(red.toastBody)",
                       "account A at 91 %: no new stations on A, rotation brief due")
    }

    /// Marks as fractions of the rail: amber and red on the 5h meter, red only on the
    /// 7d meter. The view maps the level to system colors, which adapt to light and
    /// dark; the tick is drawn taller than the bar so it stays legible over a fill of
    /// the same hue.
    func testMarkPositionsPerMeter() {
        XCTAssertEqual(Rail.amberMark, 80)
        XCTAssertEqual(Rail.redMark, 90)
        XCTAssertEqual(Rail.marks(fiveHour: true).map(\.position),
                       [Rail.amberMark / 100, Rail.redMark / 100])
        XCTAssertEqual(Rail.marks(fiveHour: true).map(\.level), [.amber, .red])
        XCTAssertEqual(Rail.marks(fiveHour: false).map(\.position), [Rail.redMark / 100])
        XCTAssertEqual(Rail.marks(fiveHour: false).map(\.level), [.red])
    }
}
