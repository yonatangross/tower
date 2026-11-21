import AppKit
import XCTest
@testable import Tower

/// The panel got stuck open (operator report, 2026-10-31): Esc and a click elsewhere did
/// not close it, and it was too tall. These drive a real StatusPanel through AppKit's own
/// event entry point, and every close test has a control that must keep the panel open.
@MainActor
final class PanelDismissTests: XCTestCase {
    private func makePanel() -> (StatusPanel, Box) {
        let panel = StatusPanel(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 120),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // The hosted SwiftUI view is the first responder in the app; an NSView that
        // swallows keys stands in for it, so the test cannot pass through a default beep.
        let sink = KeySink(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        panel.contentView = sink
        panel.makeFirstResponder(sink)
        let box = Box()
        panel.onDismiss = { [weak panel] reason in
            box.reasons.append(reason)
            panel?.orderOut(nil)
        }
        return (panel, box)
    }

    private func key(_ code: UInt16, _ chars: String, in panel: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    // MARK: Esc

    func testEscapeClosesThePanelEvenWhenTheContentEatsKeys() {
        let (panel, box) = makePanel()
        panel.sendEvent(key(53, "\u{1b}", in: panel))
        XCTAssertEqual(box.reasons, [.escape])
    }

    func testOtherKeysKeepThePanelOpen() {
        let (panel, box) = makePanel()
        panel.sendEvent(key(0, "a", in: panel))
        panel.sendEvent(key(36, "\r", in: panel))
        XCTAssertEqual(box.reasons, [])
    }

    // MARK: Click elsewhere, which AppKit delivers as the panel losing key

    func testLosingFocusClosesTheVisiblePanel() {
        let (panel, box) = makePanel()
        panel.orderFrontRegardless()
        XCTAssertTrue(panel.isVisible, "precondition: a panel that never showed proves nothing")
        panel.resignKey()
        XCTAssertEqual(box.reasons, [.lostFocus])
        XCTAssertFalse(panel.isVisible)
    }

    func testAHiddenPanelLosingFocusReportsNothing() {
        let (panel, box) = makePanel()
        panel.resignKey()
        XCTAssertEqual(box.reasons, [])
    }

    func testFocusLossAfterEscapeDoesNotReportASecondClose() {
        // Covers a resignKey that arrives after the close. The re-entrant resignKey that
        // AppKit sends from inside orderOut of the KEY window (StatusPanel.ordering) needs
        // a key panel, which a test process cannot get without taking focus, so that
        // guard is defensive and unexercised here.
        let (panel, box) = makePanel()
        panel.orderFrontRegardless()
        panel.sendEvent(key(53, "\u{1b}", in: panel))
        panel.resignKey()
        XCTAssertEqual(box.reasons, [.escape])
    }

    // MARK: The click on the menubar item that caused the focus loss

    func testTheClickThatTookFocusDoesNotReopen() {
        var guardState = PanelReopenGuard()
        let t = Date(timeIntervalSince1970: 1_000)
        guardState.noteHidden(.lostFocus, at: t)
        XCTAssertFalse(guardState.clickShouldOpen(at: t.addingTimeInterval(0.1)))
        XCTAssertTrue(guardState.clickShouldOpen(at: t.addingTimeInterval(0.5)))
    }

    func testEscapeAndOutsideClickDoNotArmTheGuard() {
        var guardState = PanelReopenGuard()
        let t = Date(timeIntervalSince1970: 1_000)
        guardState.noteHidden(.escape, at: t)
        XCTAssertTrue(guardState.clickShouldOpen(at: t.addingTimeInterval(0.1)))
        guardState.noteHidden(.outsideClick, at: t)
        XCTAssertTrue(guardState.clickShouldOpen(at: t.addingTimeInterval(0.1)))
    }

    // MARK: Height

    func testThePanelNeverTakesMoreThanThreeQuartersOfTheScreen() {
        for visible in [600.0, 800.0, 1_000.0, 1_400.0] as [CGFloat] {
            for factor in [1.0, 1.25, 1.5] as [CGFloat] {
                for density in [PanelDensity.full, .compact] {
                    let boards = PanelHeight.boardsCap(
                        visibleHeight: visible, textFactor: factor, chrome: density.chrome)
                    let panel = boards + density.chrome * factor
                    // The 240 point floor wins only on screens too short for any cap.
                    if boards > 240 {
                        XCTAssertLessThanOrEqual(panel, visible * 0.75 + 0.5,
                            "visible \(visible) factor \(factor) \(density)")
                    }
                }
            }
        }
    }

    func testCompactFoldsTheSettingsAndLeavesMoreRoomForData() {
        XCTAssertTrue(PanelDensity.full.showsSettings)
        XCTAssertFalse(PanelDensity.compact.showsSettings)
        XCTAssertLessThan(PanelDensity.compact.chrome, PanelDensity.full.chrome)
        XCTAssertGreaterThan(
            PanelHeight.boardsCap(visibleHeight: 1_000, textFactor: 1, chrome: PanelDensity.compact.chrome),
            PanelHeight.boardsCap(visibleHeight: 1_000, textFactor: 1, chrome: PanelDensity.full.chrome))
    }
}

extension PanelDismissTests {
    func testDensityDefaultsToFullAndTheEnvironmentWins() {
        let suite = "tower.test.density.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PanelDensity.stored(defaults: defaults, environment: [:]), .full)
        defaults.set("compact", forKey: PanelDensity.preferenceKey)
        XCTAssertEqual(PanelDensity.stored(defaults: defaults, environment: [:]), .compact)
        XCTAssertEqual(PanelDensity.stored(
            defaults: defaults, environment: [PanelDensity.environmentKey: "FULL"]), .full)
        defaults.set("tiny", forKey: PanelDensity.preferenceKey)
        XCTAssertEqual(PanelDensity.stored(defaults: defaults, environment: [:]), .full)
    }
}

private final class Box { var reasons: [PanelDismissal] = [] }

private final class KeySink: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
}
