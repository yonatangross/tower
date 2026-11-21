import Foundation
import XCTest
@testable import Tower

final class MCPChildProcessTests: XCTestCase {
    func testDrainsBothStreamsBeforeWaitingForExit() async throws {
        // Each stream exceeds pipe capacity. Sequential draining also deadlocks here.
        let result = await TowerMCPService.runChild(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2; exit 7"],
            timeout: 5)
        let completed = try XCTUnwrap(result)
        XCTAssertEqual(completed.status, 7)
        XCTAssertEqual(completed.stdout.utf8.count, 1048576)
        XCTAssertEqual(completed.stderr.utf8.count, 1048576)
    }

    func testTimeoutAndLaunchFailureReturnNoResult() async {
        let timedOut = await TowerMCPService.runChild(
            URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.1)
        XCTAssertNil(timedOut)
        let missing = await TowerMCPService.runChild(
            URL(fileURLWithPath: "/nonexistent/tower-child"), [], timeout: 1)
        XCTAssertNil(missing)
    }
}
