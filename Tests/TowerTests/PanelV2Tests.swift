import Foundation
import XCTest
@testable import Tower

/// Panel v2, approved 2026-09-30 (docs/approved-design/panel-v2): braille meters in the
/// status line's style, stacked pools, and the bugs the operator's screenshot showed.
final class PanelV2Tests: XCTestCase {
    // MARK: Braille meter, cell for cell with statusline-command.sh

    func testStepsMatchTheStatusLine() {
        XCTAssertEqual(BrailleMeterMath.text(percent: 54, cells: 5), "⣿⣿⣶⣀⣀")
        XCTAssertEqual(BrailleMeterMath.text(percent: 86, cells: 6), "⣿⣿⣿⣿⣿⣄")
        XCTAssertEqual(BrailleMeterMath.text(percent: 0, cells: 3), "⣀⣀⣀")
        XCTAssertEqual(BrailleMeterMath.text(percent: 100, cells: 3), "⣿⣿⣿")
        XCTAssertEqual(BrailleMeterMath.text(percent: 140, cells: 2), "⣿⣿")
        XCTAssertEqual(BrailleMeterMath.text(percent: -3, cells: 2), "⣀⣀")
        XCTAssertEqual(BrailleMeterMath.steps(percent: 50, cells: 0), [])
    }

    func testDotMasksAreTheGlyphsCodePoints() {
        for (mask, glyph) in zip(BrailleMeterMath.masks, BrailleMeterMath.glyphs) {
            XCTAssertEqual(Character(UnicodeScalar(0x2800 + UInt32(mask))!), glyph)
        }
    }

    func testLevelUsesTheStatusLineQuotaThresholds() {
        XCTAssertEqual(BrailleMeterMath.level(usedPercent: 59), .ok)
        XCTAssertEqual(BrailleMeterMath.level(usedPercent: 60), .watch)
        XCTAssertEqual(BrailleMeterMath.level(usedPercent: 84), .watch)
        XCTAssertEqual(BrailleMeterMath.level(usedPercent: 85), .high)
    }

    func testGradientRunsGreenToRedAcrossTheCells() {
        XCTAssertEqual(BrailleMeterMath.gradient(cell: 0, of: 6), .init(r: 74, g: 222, b: 128))
        XCTAssertEqual(BrailleMeterMath.gradient(cell: 5, of: 6), .init(r: 248, g: 113, b: 113))
        // Cell 3 of 6 sits at 58 percent, between the green and amber anchors.
        XCTAssertEqual(BrailleMeterMath.gradient(cell: 3, of: 6), .init(r: 237, g: 206, b: 29))
    }

    // MARK: Bug e, the stacked labels fit

    func testStackedPoolLabelsAndPercentFitTheMeterColumn() {
        XCTAssertTrue(SegmentedMeter.labelsFit())
        XCTAssertEqual(SegmentedMeter.displayLabel("Fable used"), "Fable")
        XCTAssertEqual(SegmentedMeter.displayLabel(CursorPool.autoLabel), "Auto")
        XCTAssertEqual(SegmentedMeter.displayLabel(CursorPool.meteredLabel), "Opus")
    }

    // MARK: Bug c, no tool call in the panel text

    func testTheJevActionNamesNoToolCall() {
        XCTAssertFalse(TypeSafe.panelReenterAction.contains("tower_config_set"))
        XCTAssertTrue(TypeSafe.panelReenterAction.contains("TypeSafe Billing"))
    }

    // MARK: Bug a, sessions say their account or why they cannot

    private func session(_ id: String, _ email: String?) -> AgentInfo {
        AgentInfo(kind: "interactive", status: "busy", cwd: "/p/\(id)", sessionId: id,
                  accountEmail: email)
    }

    func testTallyCountsSessionsPerAccount() {
        var summary = AgentSummary()
        summary.interactive = [session("a", "dee@x.com"), session("b", "dee@x.com"),
                               session("c", "ben@x.com"), session("d", nil)]
        summary.anchorsPublished = true
        XCTAssertEqual(summary.accountTally,
                       "\(Nickname.derive(from: "dee@x.com")) 2 · \(Nickname.derive(from: "ben@x.com")) 1 · ? 1")
        XCTAssertNil(summary.unattributedReason, "One resolved session means rows speak for themselves")
    }

    func testNoAnchorsSaysWhyOnceWithTheInstaller() {
        var summary = AgentSummary()
        summary.interactive = (0..<13).map { session("s\($0)", nil) }
        summary.anchorsPublished = false
        XCTAssertNil(summary.accountTally)
        XCTAssertEqual(summary.unattributedReason,
                       "accounts unknown: the statusline does not publish session anchors · run "
                       + "scripts/install-statusline-anchor.sh --apply")
        summary.anchorsPublished = true
        XCTAssertEqual(summary.unattributedReason,
                       "accounts unknown: no session's reset matches a remembered seat")
        XCTAssertNil(AgentSummary().unattributedReason, "No sessions, nothing to explain")
    }

    func testProbeReportsWhetherAnchorsArePublished() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-anchor-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        let rows = try JSONSerialization.data(withJSONObject: [
            ["kind": "interactive", "status": "busy", "cwd": "/p", "sessionId": "s1"]
        ])
        XCTAssertEqual(AgentProbe.summarize(rows, home: root)?.anchorsPublished, false)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/session-anchors"), withIntermediateDirectories: true)
        XCTAssertEqual(AgentProbe.summarize(rows, home: root)?.anchorsPublished, true)
    }

    // MARK: Lane meters, as the approved mockup draws them

    func testDevinLaneMetersAreUsedPercents() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reading = AgentLane.Reading(
            provider: .devin, configModel: "swe-2-high", lastDispatch: nil, lastLimitHit: nil,
            usage: .quota(.init(plan: "Pro", dailyRemainingPct: 100, weeklyRemainingPct: 96,
                                dailyResetsAt: nil, weeklyResetsAt: nil, fetchedAt: now)))
        XCTAssertEqual(AgentLane.meters(reading, cursorSeat: nil, now: now),
                       [.init(label: "day", usedPct: 0), .init(label: "week", usedPct: 4)],
                       "A status fetched now is live: no age, full colour")
        let old = AgentLane.Reading(
            provider: .devin, configModel: "swe-2-high", lastDispatch: nil, lastLimitHit: nil,
            usage: .quota(.init(plan: "Pro", dailyRemainingPct: 100, weeklyRemainingPct: 96,
                                dailyResetsAt: nil, weeklyResetsAt: nil,
                                fetchedAt: now.addingTimeInterval(-3 * 3600))))
        let stale = AgentLane.meters(old, cursorSeat: nil, now: now)
        XCTAssertEqual(stale.map(\.usedPct), [0, 4])
        XCTAssertTrue(stale.allSatisfy { $0.age != nil }, "A three hour old status draws dimmed with its age")
        let muse = AgentLane.Reading(provider: .muse, configModel: nil, lastDispatch: nil,
                                     lastLimitHit: nil)
        XCTAssertEqual(AgentLane.meters(muse, cursorSeat: nil, now: now), [])
    }

    func testAnchorsAreFoundUnderTheSessionsOwnConfigRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-anchor-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let custom = root.appendingPathComponent("custom-config")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: custom.appendingPathComponent("session-anchors"),
                                                withIntermediateDirectories: true)
        let session = AgentInfo(kind: "interactive", status: "busy", cwd: "/p", sessionId: "s1",
                                configDir: custom.path)
        XCTAssertTrue(AgentProbe.anchorsPublished(for: [session], home: home),
                      "A CLAUDE_CONFIG_DIR session publishes its anchors under its own root")
        let plain = AgentInfo(kind: "interactive", status: "busy", cwd: "/p", sessionId: "s2")
        XCTAssertFalse(AgentProbe.anchorsPublished(for: [plain], home: home))
    }
}
