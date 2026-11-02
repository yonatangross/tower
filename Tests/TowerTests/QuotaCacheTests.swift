import Foundation
import XCTest
@testable import Tower

final class QuotaCacheTests: XCTestCase {
    func testExpiryBoundariesAreNormalizedInModelAndBothFiles() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { now })
        var rows: [String: AccountSnapshot] = [:]
        for (name, offset) in [("past", -1.0), ("boundary", 0.0), ("future", 1.0)] {
            rows[name] = AccountSnapshot(
                email: name, nickname: name, plan: "max", fiveHourPct: 100,
                fiveHourResetsAt: now.addingTimeInterval(offset), weeklyPct: 83,
                weeklyResetsAt: now.addingTimeInterval(offset), capturedAt: now.addingTimeInterval(-80_000))
        }
        rows["mixed"] = AccountSnapshot(
            email: "mixed", nickname: "mixed", plan: "max", fiveHourPct: 100,
            fiveHourResetsAt: now.addingTimeInterval(-1), weeklyPct: 71,
            weeklyResetsAt: now.addingTimeInterval(1))
        rows["unknown"] = AccountSnapshot(email: "unknown", nickname: "unknown", plan: "?")
        rows["no-reset"] = AccountSnapshot(
            email: "no-reset", nickname: "no-reset", plan: "max", fiveHourPct: 28, weeklyPct: 37)
        rows["mixed"]?.scoped = [
            ScopedLimit(label: "past", percent: 95, resetsAt: now.addingTimeInterval(-1)),
            ScopedLimit(label: "future", percent: 45, resetsAt: now.addingTimeInterval(1))
        ]

        XCTAssertNil(store.save(rows))
        let disk = try Data(contentsOf: dir.appendingPathComponent("accounts.json"))
        XCTAssertEqual(disk, try Data(contentsOf: mirror))
        let written = try JSONDecoder().decode([String: AccountSnapshot].self, from: disk)
        for observed in [written, store.load(), store.mutate { _ in }.accounts] {
            for name in ["past", "boundary"] {
                XCTAssertEqual(observed[name]?.fiveHourPct, 0)
                XCTAssertEqual(observed[name]?.weeklyPct, 0)
                XCTAssertEqual(observed[name]?.capturedAt, rows[name]?.capturedAt)
                XCTAssertEqual(observed[name]?.fiveHourResetsAt, rows[name]?.fiveHourResetsAt)
                XCTAssertEqual(observed[name]?.weeklyResetsAt, rows[name]?.weeklyResetsAt)
            }
            XCTAssertEqual(observed["future"]?.fiveHourPct, 100)
            XCTAssertEqual(observed["future"]?.weeklyPct, 83)
            XCTAssertEqual(observed["mixed"]?.fiveHourPct, 0)
            XCTAssertEqual(observed["mixed"]?.weeklyPct, 71)
            XCTAssertEqual(observed["mixed"]?.scoped.map(\.percent), [0, 45])
            XCTAssertNil(observed["unknown"]?.fiveHourPct)
            XCTAssertNil(observed["unknown"]?.weeklyPct)
            XCTAssertEqual(observed["no-reset"]?.fiveHourPct, 28)
            XCTAssertEqual(observed["no-reset"]?.weeklyPct, 37)
        }
    }

    func testLoadingLegacySnapshotAndMutatingNewCaptureBothExpireWindows() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { now })
        let expired = AccountSnapshot(
            email: "rested", nickname: "rested", plan: "max", fiveHourPct: 100,
            fiveHourResetsAt: now.addingTimeInterval(-3600), weeklyPct: 83,
            weeklyResetsAt: now.addingTimeInterval(-3600), capturedAt: now.addingTimeInterval(-80_000))
        let file = dir.appendingPathComponent("accounts.json")
        try JSONEncoder().encode(["rested": expired]).write(to: file)
        XCTAssertEqual(store.load()["rested"]?.fiveHourPct, 0)
        XCTAssertEqual(store.load()["rested"]?.weeklyPct, 0)

        let result = store.mutate { $0["rested"] = expired }
        XCTAssertNil(result.saveError)
        XCTAssertEqual(result.accounts["rested"]?.fiveHourPct, 0)
        XCTAssertEqual(result.accounts["rested"]?.weeklyPct, 0)
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(bytes, try Data(contentsOf: mirror))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]])
        XCTAssertEqual(json["rested"]?["fiveHourPct"] as? Double, 0)
        XCTAssertEqual(json["rested"]?["weeklyPct"] as? Double, 0)
        // Mirrors the room calculation used by downstream consumers, without UI helpers.
        let row = try XCTUnwrap(json["rested"])
        XCTAssertEqual(100 - max(try XCTUnwrap(row["fiveHourPct"] as? Double),
                                 try XCTUnwrap(row["weeklyPct"] as? Double)), 100)
    }
}
