import XCTest
import AppKit
@testable import Tower

/// The popover type scale: approved 2026-09-29 as 13/12/11 with 16 headers, raised 2026-09-30
/// (panel v2) to body 18, small 16, minimum 15, headers 22 semibold, with the folds that keep
/// the larger type from growing the panel past the screen.
final class PopoverTypeScaleTests: XCTestCase {
    func testTheDefaultTextSizeRendersTheApprovedScale() {
        XCTAssertEqual(TowerType.size(.body, textSize: .m), 18, accuracy: 0.0001)
        XCTAssertEqual(TowerType.size(.small, textSize: .m), 16, accuracy: 0.0001)
        XCTAssertEqual(TowerType.size(.minimum, textSize: .m), 15, accuracy: 0.0001)
        XCTAssertEqual(TowerType.size(.header, textSize: .m), 22, accuracy: 0.0001)
    }

    func testNoTextSizeGoesUnderTheMinimum() {
        for textSize in TowerTextSize.allCases {
            for role in TowerType.Role.allCases {
                XCTAssertGreaterThanOrEqual(TowerType.size(role, textSize: textSize), 15,
                                            "\(role) at \(textSize) is under the 15 pt floor")
            }
        }
    }

    func testRolesStayOrderedAndLargerSizesGrow() {
        for textSize in TowerTextSize.allCases {
            let sizes = [TowerType.Role.minimum, .small, .body, .header]
                .map { TowerType.size($0, textSize: textSize) }
            XCTAssertEqual(sizes, sizes.sorted(), "roles out of order at \(textSize)")
        }
        let body = TowerTextSize.allCases.map { TowerType.size(.body, textSize: $0) }
        XCTAssertEqual(body, body.sorted())
    }

    func testDesignSizeIsInTheUnitColumnWidthsAreWrittenIn() {
        // A layout unit scales by the stored factor and the panel v2 layout scale; the
        // default factor must land on the approved point size.
        XCTAssertEqual(TowerTextSize.pt(TowerType.designSize(.body)) / TowerTextSize.current
                       * TowerTextSize.fallback.factor, 18, accuracy: 0.0001)
        XCTAssertEqual(TowerType.layoutScale, 18.0 / 13.0, accuracy: 0.0001)
    }

    /// The whole point of the scale is that no view names a point size. A new
    /// `.system(size:)` in the UI files would quietly reopen the "super small" report.
    func testNoViewHardcodesAPointSize() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Tower")
        for name in ["AppUI.swift", "DenseOpsUI.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(".system(size:") {
                // The two icon monograms scale with their tile, not with the type scale.
                XCTAssertTrue(line.contains("TowerTextSize.pt(size)"),
                              "\(name):\(index + 1) hardcodes a font size: \(line)")
            }
        }
    }

    // MARK: Folds

    func testOnlyAPurelyStaleSeatFolds() {
        XCTAssertFalse(SeatBoard.isFolded(nil))
        XCTAssertTrue(SeatBoard.isFolded(.stale(3 * 86_400)))
        XCTAssertTrue(SeatBoard.isFolded(.neverCaptured))
        // A ceiling is information (its reopening clock), so a capped seat stays listed,
        // stale or not.
        XCTAssertFalse(SeatBoard.isFolded(.capped(100)))
        XCTAssertFalse(SeatBoard.isFolded(.meteredCapped(100)))
        XCTAssertFalse(SeatBoard.isFolded(.cappedAndStale(100, 3 * 86_400)))
    }

    func testFoldLinesNameTheCountAndTheState() {
        XCTAssertEqual(SeatBoard.staleLine(count: 2, open: false), "+ 2 stale")
        XCTAssertEqual(SeatBoard.staleLine(count: 2, open: true), "- 2 stale")
        XCTAssertEqual(SessionsBoard.idleLine(count: 3, open: false), "+ 3 idle")
        XCTAssertEqual(SessionsBoard.idleLine(count: 3, open: true), "- 3 idle")
    }

    func testJevFoldsToOneLineThatStillSaysLowOrStale() {
        XCTAssertEqual(JevRow.stateWord(level: .green, stale: false), "ok")
        XCTAssertEqual(JevRow.stateWord(level: .amber, stale: false), "watch")
        XCTAssertEqual(JevRow.stateWord(level: .red, stale: false), "low")
        // An old figure is not trusted with a colour, whatever it says.
        XCTAssertEqual(JevRow.stateWord(level: .red, stale: true), "stale")
    }

    func testSessionsHeadingCountsBusyAndIdle() {
        XCTAssertNil(SessionsBoard.busyIdleLine(nil))
        XCTAssertEqual(SessionsBoard.busyIdleLine(AgentSummary()), "0 busy · 0 idle")
    }

    // MARK: Contrast

    /// Secondary text was the system grey. It must stay clearly under primary text and
    /// readable: at least 7:1 against the dark panel background and against the light one.
    func testSecondaryTextClearsContrastOnBothAppearances() throws {
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        func contrast(_ a: Double, _ b: Double) -> Double {
            (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        // Label colour is white in dark and black in light; TowerType.secondary is that at
        // its opacity. Blend over the window background of each appearance.
        let alpha = TowerType.secondaryOpacity
        for (label, background) in [(1.0, 0.14), (0.0, 0.93)] {
            let blended = alpha * label + (1 - alpha) * background
            XCTAssertGreaterThanOrEqual(contrast(luminance(blended, blended, blended),
                                                 luminance(background, background, background)), 7)
        }
    }
}
