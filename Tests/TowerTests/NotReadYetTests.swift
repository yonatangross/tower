import XCTest
@testable import Tower

/// Before the first refresh (launch, and every panelshot) nothing was attempted, so
/// the panel must not report a failed probe, a failed kernel read or zero sessions.
/// Found in a dev panelshot on 2026-09-27: "session probe unavailable", "load could
/// not be read" and "SESSIONS · 0" on a panel that had never probed anything.
final class NotReadYetTests: XCTestCase {

    func testFleetLinesBeforeTheFirstRefreshSayNotReadYet() {
        XCTAssertEqual(CLI.fleetLines(blast: nil, machine: nil, read: .notYet), [
            "  ❔ Blast radius: not read yet",
            "  ❔ Machine: load not read yet",
        ])
    }

    func testAFailedProbeStillSaysSo() {
        XCTAssertEqual(CLI.fleetLines(blast: nil, machine: nil, read: .done(sessions: false)), [
            "  ❔ Blast radius: session probe unavailable",
            "  ❔ Machine: load could not be read",
        ])
    }

    /// Sessions answered but there is no active Claude login: the probe is not the
    /// reason the blast radius is unknown, so the line must not blame it.
    func testNoActiveLoginIsNotBlamedOnTheProbe() {
        XCTAssertEqual(CLI.fleetLines(blast: nil, machine: nil, read: .done(sessions: true)).first,
                       "  ❔ Blast radius: no active Claude login to measure")
    }

    func testUnknownSessionCountIsAQuestionMarkNotZero() {
        XCTAssertEqual(SessionsBoard.heading(nil), "SESSIONS · ?")
        XCTAssertEqual(SessionsBoard.heading(AgentSummary()), "SESSIONS · 0")
    }

    func testSessionsLineBeforeAndAfterTheFirstProbe() {
        XCTAssertEqual(SessionsBoard.missingLine(probed: false), "not read yet")
        XCTAssertEqual(SessionsBoard.missingLine(probed: true), "session probe unavailable")
    }
}
