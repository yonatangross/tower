import Foundation
import XCTest
@testable import Tower

final class MoveFirstSurfaceTests: XCTestCase {
    func testWarningNamesIdleSessionsInPanelTerminalAndMCP() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let active = AccountSnapshot(email: "fay@example.com", nickname: "fay", plan: "max",
                                     fiveHourPct: 90, fiveHourResetsAt: now.addingTimeInterval(3600),
                                     weeklyPct: 40, weeklyResetsAt: now.addingTimeInterval(86400),
                                     capturedAt: now)
        var sessions = AgentSummary()
        sessions.interactive = [
            AgentInfo(kind: "interactive", status: "busy", sessionId: "build-id", name: "build",
                      accountEmail: active.email),
            AgentInfo(kind: "interactive", status: "idle", sessionId: "review-id", name: "review",
                      accountEmail: active.email),
        ]
        let blast = try XCTUnwrap(BlastRadius.evaluate(active: active, sessions: sessions, now: now))
        let line = try XCTUnwrap(blast.moveFirstLine)
        XCTAssertTrue(CLI.fleetLines(blast: blast, machine: nil).contains("  " + line))
        let wire = TowerMCPService.blastRadiusJSON(blast)
        XCTAssertEqual(wire["moveFirstLine"].stringValue, line)
        XCTAssertEqual(wire["moveFirst"].arrayValue?.first?["id"].stringValue, "review-id")
        XCTAssertEqual(wire["moveFirst"].arrayValue?.first?["busy"].boolValue, false)
        XCTAssertTrue(JSONSchemaCheck.validate(wire, against: TowerMCPService.blastRadiusSchema).isEmpty)
    }
}
