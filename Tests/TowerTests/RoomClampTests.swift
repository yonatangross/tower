import Foundation
import XCTest
@testable import Tower

final class RoomClampTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func seat(_ nickname: String, used: Double?) -> AccountSnapshot {
        var row = AccountSnapshot(
            email: "\(nickname)@example.test", nickname: nickname, plan: "max")
        row.fiveHourPct = used
        row.weeklyPct = used
        row.fiveHourResetsAt = now.addingTimeInterval(3_600)
        row.weeklyResetsAt = now.addingTimeInterval(86_400)
        row.capturedAt = now.addingTimeInterval(-60)
        return row
    }

    func testRoomPctClampsAndIdentifiesOverCapUsage() {
        let overCap = seat("over", used: 433)
        let ordinary = seat("ordinary", used: 28)
        let capped = seat("capped", used: 100)
        let unknown = seat("unknown", used: nil)

        XCTAssertEqual(overCap.roomPct(now: now), 0)
        XCTAssertTrue(overCap.isOverCap(now: now))
        XCTAssertEqual(ordinary.roomPct(now: now), 72)
        XCTAssertFalse(ordinary.isOverCap(now: now))
        XCTAssertEqual(capped.roomPct(now: now), 0)
        XCTAssertFalse(capped.isOverCap(now: now))
        XCTAssertNil(unknown.roomPct(now: now))
    }

    func testRotateSeatLineClampsOverCapUsageAndExplainsIt() {
        let overCap = seat("over", used: 433)
        let line = CLI.rotateSeatLine(
            for: overCap,
            chromeProfile: ChromeProfileHint(displayName: "Over Profile", chooserEmail: overCap.email),
            now: now)

        XCTAssertFalse(line.range(of: #"-\d"#, options: .regularExpression) != nil)
        XCTAssertTrue(line.contains("0%"))
        XCTAssertTrue(line.contains("over cap (433% used)"))
    }

    func testRotateReportRendersRoomForActiveSeat() {
        let ordinary = seat("ordinary", used: 28)
        let report = CLI.rotateReport(accounts: [ordinary], switchProfiles: [
            ordinary.email: ChromeProfileHint(displayName: "Ordinary Profile", chooserEmail: ordinary.email),
        ], now: now)

        XCTAssertTrue(report.lines.contains { $0.contains("72%") })
    }

    @MainActor
    func testAccountRowAddsOverCapSuffixToRoomSummary() {
        let row = AccountRow(account: seat("panel", used: 457), isActive: false, headerError: nil, now: now)

        XCTAssertEqual(row.availableSummary(), "0% room, over cap (457% used)")
    }
}
