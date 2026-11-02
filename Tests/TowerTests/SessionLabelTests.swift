import Foundation
import XCTest
@testable import Tower

/// Raw `claude agents --json` names measured on the floor 2026-09-27, against the house
/// convention: a session is named by its lane slug, no emoji, no branch.
final class SessionLabelTests: XCTestCase {
    private let platform = "/Users/op/coding/acme/platform/.worktrees"

    func testSummaryTitleDropsTheEmojiAndTheBranchTail() {
        XCTAssertEqual(SessionLabel.derive(name: "🚪 merge-desk-10 resume and coordinate · feat/merge-desk-9 ·",
                                           cwd: "\(platform)/merge-desk-9"),
                       "merge-desk-10 resume and coordinate")
    }

    func testLaneWithABranchTailKeepsTheLane() {
        XCTAssertEqual(SessionLabel.derive(name: "reviewer-infra-35-desk · docs/2026-09-27-infra35",
                                           cwd: "\(platform)/reviewer-infra-35-desk"),
                       "reviewer-infra-35-desk")
    }

    func testWorktreeHookTitleFallsBackToTheWorktreeLane() {
        XCTAssertEqual(SessionLabel.derive(name: "chore/dsp-5846-ork-plugin-eval · wt",
                                           cwd: "/Users/op/coding/acme/orchestkit/.worktrees/5846-ork-plugin-eval"),
                       "5846-ork-plugin-eval")
        XCTAssertEqual(SessionLabel.derive(name: "feat/tower-dev · wt",
                                           cwd: "/Users/op/coding/acme/tower/.worktrees/tower-dev"),
                       "tower-dev")
    }

    func testWorktreeHookTitleOnASlashlessBranchStillFallsBack() {
        XCTAssertEqual(SessionLabel.derive(name: "main · wt", cwd: "/r/.worktrees/hotfix-lane"), "hotfix-lane")
    }

    func testWorktreeLaneReadsTheDirectoryUnderWorktreesNotADeeperOne() {
        XCTAssertEqual(SessionLabel.derive(name: "feat/x · wt", cwd: "/r/.worktrees/lane-a/apps/web"), "lane-a")
    }

    func testPlainLaneNamesAreUnchanged() {
        for lane in ["hq-cli-2", "e2e-tests", "floor-board", "conductor64", "content-2-desk"] {
            XCTAssertEqual(SessionLabel.derive(name: lane, cwd: "\(platform)/\(lane)"), lane)
        }
    }

    func testDigitsAndHashAreNotStrippedAsEmoji() {
        XCTAssertEqual(SessionLabel.derive(name: "64-conductor", cwd: nil), "64-conductor")
        XCTAssertEqual(SessionLabel.derive(name: "#1527 lane", cwd: nil), "#1527 lane")
    }

    func testABranchWithNoDirectoryKeepsTheBranchRatherThanNothing() {
        XCTAssertEqual(SessionLabel.derive(name: "feat/x · wt", cwd: nil), "feat/x")
        XCTAssertNil(SessionLabel.derive(name: "🚪", cwd: nil))
        XCTAssertNil(SessionLabel.derive(name: nil, cwd: "/r/lane"))
    }

    /// Rows label on the derived lane, keep one row per session id, and keep the raw
    /// name for the tooltip and the MCP `name` field.
    func testGroupsLabelOnTheLaneAndKeepTheRawName() throws {
        let rows: [[String: Any]] = [
            ["kind": "interactive", "status": "busy", "sessionId": "a",
             "name": "🚪 merge-desk-10 resume and coordinate · feat/merge-desk-9 ·",
             "cwd": "\(platform)/merge-desk-9"],
            ["kind": "interactive", "status": "idle", "sessionId": "b",
             "name": "reviewer-infra-35-desk · docs/2026-09-27-infra35",
             "cwd": "\(platform)/reviewer-infra-35-desk"],
            ["kind": "interactive", "status": "idle", "sessionId": "c",
             "name": "feat/tower-dev · wt", "cwd": "/Users/op/coding/acme/tower/.worktrees/tower-dev"],
            ["kind": "interactive", "status": "idle", "sessionId": "d",
             "name": "hq-cli-2", "cwd": "\(platform)/hq-cli-2"],
        ]
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-session-label-\(UUID().uuidString)")
        let summary = try XCTUnwrap(AgentProbe.summarize(JSONSerialization.data(withJSONObject: rows),
                                                       home: home))
        let byName = Dictionary(uniqueKeysWithValues: summary.groups.map { ($0.sessionName ?? "", $0) })
        XCTAssertEqual(summary.groups.count, 4)
        XCTAssertEqual(byName["feat/tower-dev · wt"]?.label, "tower-dev")
        XCTAssertEqual(byName["feat/tower-dev · wt"]?.rawName, "feat/tower-dev · wt")
        XCTAssertEqual(byName["reviewer-infra-35-desk · docs/2026-09-27-infra35"]?.label, "reviewer-infra-35-desk")
        XCTAssertEqual(byName["hq-cli-2"]?.label, "hq-cli-2")
        XCTAssertEqual(summary.groups.first?.label, "merge-desk-10 resume and coordinate", "busy first")
        XCTAssertFalse(summary.groups.contains { $0.label.contains("·") || $0.label.contains("/") })
        XCTAssertEqual(summary.interactive.first { $0.sessionId == "c" }?.displayName, "tower-dev")
    }

    func testTwoSessionsDerivingTheSameLaneStayTwoRows() throws {
        let rows: [[String: Any]] = [
            ["kind": "interactive", "status": "idle", "sessionId": "a", "name": "feat/x · wt", "cwd": "/r/.worktrees/lane"],
            ["kind": "interactive", "status": "idle", "sessionId": "b", "name": "lane", "cwd": "/r/.worktrees/lane"],
        ]
        let summary = try XCTUnwrap(AgentProbe.summarize(JSONSerialization.data(withJSONObject: rows),
                                                       home: FileManager.default.temporaryDirectory))
        XCTAssertEqual(summary.groups.map(\.label), ["lane", "lane"])
    }
}
