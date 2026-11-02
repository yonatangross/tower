import Foundation
import XCTest
@testable import Tower

/// Issue #103: `effective()` has three states (unmeasured, measured, zero because the window
/// reset) and the files other tools read must carry all three. A derived zero is written with
/// `fiveHourReset` / `weeklyReset` / scoped `reset` set to true; a measured value, including a
/// measured zero, carries no such key; an unmeasured window carries neither pct nor flag.
/// Every assertion reads the mirror bytes, because that is what the quota-guard hook reads.
final class ResetFlagSerializationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func row(_ nick: String, five: Double?, fiveReset: TimeInterval?,
                     weekly: Double?, weeklyReset: TimeInterval?) -> AccountSnapshot {
        AccountSnapshot(
            email: "\(nick)@example.test", nickname: nick, plan: "max",
            fiveHourPct: five, fiveHourResetsAt: fiveReset.map { now.addingTimeInterval($0) },
            weeklyPct: weekly, weeklyResetsAt: weeklyReset.map { now.addingTimeInterval($0) },
            capturedAt: now.addingTimeInterval(-600))
    }

    private func tempStore(clock: @escaping () -> Date) -> (Store, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        return (Store(dir: dir, mirror: mirror, now: clock), dir, mirror)
    }

    private func mirrorRows(_ mirror: URL) throws -> [String: [String: Any]] {
        let bytes = try Data(contentsOf: mirror)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]])
    }

    func testDerivedZeroIsFlaggedAndMeasuredValueIsNot() throws {
        let (store, dir, mirror) = tempStore { self.now }
        defer { try? FileManager.default.removeItem(at: dir) }
        let expired = row("expired", five: 90, fiveReset: -60, weekly: 30, weeklyReset: 3 * 86_400)

        XCTAssertNil(store.save([expired.email: expired]))
        let rows = try mirrorRows(mirror)
        let written = try XCTUnwrap(rows[expired.email])
        XCTAssertEqual(written["fiveHourPct"] as? Double, 0)
        XCTAssertEqual(written["fiveHourReset"] as? Bool, true)
        XCTAssertEqual(written["weeklyPct"] as? Double, 30)
        XCTAssertNil(written["weeklyReset"], "a measured 30 is not derived")

        let authoritative = try Data(contentsOf: dir.appendingPathComponent("accounts.json"))
        let mirrored = try Data(contentsOf: mirror)
        XCTAssertEqual(authoritative, mirrored, "both files carry the flag")
    }

    func testWeeklyDerivedZeroIsFlagged() throws {
        let (store, dir, mirror) = tempStore { self.now }
        defer { try? FileManager.default.removeItem(at: dir) }
        let expired = row("weekly", five: 20, fiveReset: 3_600, weekly: 90, weeklyReset: -60)

        XCTAssertNil(store.save([expired.email: expired]))
        let written = try XCTUnwrap(try mirrorRows(mirror)[expired.email])
        XCTAssertEqual(written["weeklyPct"] as? Double, 0)
        XCTAssertEqual(written["weeklyReset"] as? Bool, true)
        XCTAssertEqual(written["fiveHourPct"] as? Double, 20)
        XCTAssertNil(written["fiveHourReset"])
    }

    /// The two zeros the issue says a consumer cannot tell apart by inference: a measured 0
    /// with a future reset, and a measured 0 whose API reply had a null resets_at.
    func testMeasuredZeroCarriesNoFlagWithOrWithoutResetsAt() throws {
        let (store, dir, mirror) = tempStore { self.now }
        defer { try? FileManager.default.removeItem(at: dir) }
        let upcoming = row("upcoming", five: 0, fiveReset: 3_600, weekly: 0, weeklyReset: 86_400)
        let noReset = row("noreset", five: 0, fiveReset: nil, weekly: 0, weeklyReset: nil)

        XCTAssertNil(store.save([upcoming.email: upcoming, noReset.email: noReset]))
        let rows = try mirrorRows(mirror)
        for email in [upcoming.email, noReset.email] {
            let written = try XCTUnwrap(rows[email])
            XCTAssertEqual(written["fiveHourPct"] as? Double, 0)
            XCTAssertEqual(written["weeklyPct"] as? Double, 0)
            XCTAssertNil(written["fiveHourReset"], "\(email) 5h is a reading")
            XCTAssertNil(written["weeklyReset"], "\(email) weekly is a reading")
        }
    }

    /// An unmeasured window stays absent after its reset passes: no pct, no flag.
    func testUnmeasuredWindowStaysAbsentAfterReset() throws {
        let (store, dir, mirror) = tempStore { self.now }
        defer { try? FileManager.default.removeItem(at: dir) }
        let unmeasured = row("unmeasured", five: nil, fiveReset: -60, weekly: nil, weeklyReset: -60)

        XCTAssertNil(store.save([unmeasured.email: unmeasured]))
        let written = try XCTUnwrap(try mirrorRows(mirror)[unmeasured.email])
        XCTAssertNil(written["fiveHourPct"])
        XCTAssertNil(written["fiveHourReset"])
        XCTAssertNil(written["weeklyPct"])
        XCTAssertNil(written["weeklyReset"])
    }

    /// The refresh fold writes the new reading into the existing row. The flag must not
    /// survive it: a fresh 12 is a measurement, whatever the previous save said.
    func testFreshCaptureFoldedIntoFlaggedRowClearsTheFlag() throws {
        var clock = now
        let (store, dir, mirror) = tempStore { clock }
        defer { try? FileManager.default.removeItem(at: dir) }
        let expired = row("fold", five: 90, fiveReset: -60, weekly: 30, weeklyReset: 3 * 86_400)
        XCTAssertNil(store.save([expired.email: expired]))
        let flagged = try XCTUnwrap(store.load()[expired.email])
        XCTAssertEqual(flagged.fiveHourReset, true, "the flag survives a read-back")

        clock = now.addingTimeInterval(120)
        let result = store.mutate { rows in
            rows[expired.email]?.fiveHourPct = 12
            rows[expired.email]?.fiveHourResetsAt = clock.addingTimeInterval(5 * 3_600)
            rows[expired.email]?.capturedAt = clock
        }
        XCTAssertNil(result.saveError)
        XCTAssertNil(result.accounts[expired.email]?.fiveHourReset)
        let written = try XCTUnwrap(try mirrorRows(mirror)[expired.email])
        XCTAssertEqual(written["fiveHourPct"] as? Double, 12)
        XCTAssertNil(written["fiveHourReset"])
    }

    /// Rows written before #103 carry no flag. They decode, and a derived zero among them
    /// gains the flag on the next save because the flag is recomputed, not remembered.
    func testLegacyRowWithoutFlagDecodesAndHealsOnSave() throws {
        let (store, dir, mirror) = tempStore { self.now }
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = row("legacy", five: 0, fiveReset: -60, weekly: 10, weeklyReset: 86_400)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "fiveHourReset")
        let legacyBytes = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AccountSnapshot.self, from: legacyBytes)
        XCTAssertNil(decoded.fiveHourReset)

        XCTAssertNil(store.save([decoded.email: decoded]))
        let written = try XCTUnwrap(try mirrorRows(mirror)[decoded.email])
        XCTAssertEqual(written["fiveHourReset"] as? Bool, true)
    }

    func testScopedLimitFlagsDerivedZeroAndKeepsUnmeasuredAbsent() throws {
        let (store, dir, mirror) = tempStore { self.now }
        defer { try? FileManager.default.removeItem(at: dir) }
        var seat = row("scoped", five: 10, fiveReset: 3_600, weekly: 10, weeklyReset: 86_400)
        seat.scoped = [
            ScopedLimit(label: "Fable", percent: 80, resetsAt: now.addingTimeInterval(-60)),
            ScopedLimit(label: "Opus", percent: 40, resetsAt: now.addingTimeInterval(3_600)),
            ScopedLimit(label: "Withheld", percent: nil, resetsAt: now.addingTimeInterval(-60)),
        ]

        XCTAssertNil(store.save([seat.email: seat]))
        let written = try XCTUnwrap(try mirrorRows(mirror)[seat.email])
        let scoped = try XCTUnwrap(written["scoped"] as? [[String: Any]])
        let byLabel = Dictionary(uniqueKeysWithValues: scoped.compactMap { entry in
            (entry["label"] as? String).map { ($0, entry) }
        })
        let fable = try XCTUnwrap(byLabel["Fable"])
        XCTAssertEqual(fable["percent"] as? Double, 0)
        XCTAssertEqual(fable["reset"] as? Bool, true)
        let opus = try XCTUnwrap(byLabel["Opus"])
        XCTAssertEqual(opus["percent"] as? Double, 40)
        XCTAssertNil(opus["reset"])
        let withheld = try XCTUnwrap(byLabel["Withheld"])
        XCTAssertNil(withheld["percent"], "a reset does not turn unmeasured into 0")
        XCTAssertNil(withheld["reset"])
    }
}
