import AppKit

/// Why the panel closed. One type for every close path, so Esc, a click in another app
/// and the panel losing focus cannot drift apart again (2026-10-31, panel stuck open).
enum PanelDismissal: Equatable {
    case escape
    case lostFocus
    case outsideClick
}

/// The menubar panel. It owns its close decisions and reports them through `onDismiss`;
/// AppDelegate only orders the window out. Kept free of SwiftUI so a test can build one.
final class StatusPanel: NSPanel {
    /// Called once per close request. The receiver hides the panel.
    var onDismiss: ((PanelDismissal) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// True while orderOut runs: hiding the key window makes AppKit call resignKey, and
    /// that is the close already in progress, not a second one.
    private var ordering = false

    /// Esc is caught here, before the hosted SwiftUI view sees it. Relying on the
    /// responder chain reaching cancelOperation failed: a first responder that takes the
    /// key ends the chain and the panel stayed open.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
            onDismiss?(.escape)
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?(.escape)
    }

    /// A click in another app, on the desktop or in another app's menu takes key from
    /// the panel. That is the outside click, delivered by AppKit itself, so it needs no
    /// global event monitor and works when the app was never activated.
    override func resignKey() {
        super.resignKey()
        guard isVisible, !ordering else { return }
        onDismiss?(.lostFocus)
    }

    override func orderOut(_ sender: Any?) {
        ordering = true
        defer { ordering = false }
        super.orderOut(sender)
    }

    static let escapeKeyCode: UInt16 = 53
}

/// A click on the menubar item that lands right after the panel closed itself on focus
/// loss is the same gesture: it must not reopen the panel it just closed.
struct PanelReopenGuard {
    static let window: TimeInterval = 0.35
    private(set) var lastFocusLossHide: Date?

    /// Only a focus loss arms the guard: Esc and the outside click monitor are not
    /// followed by a click on the menubar item.
    mutating func noteHidden(_ reason: PanelDismissal?, at now: Date) {
        lastFocusLossHide = reason == .lostFocus ? now : nil
    }

    func clickShouldOpen(at now: Date) -> Bool {
        guard let hidden = lastFocusLossHide else { return true }
        return now.timeIntervalSince(hidden) >= Self.window
    }
}

/// How much of the screen the panel may take. Pure arithmetic so tests can pin it.
enum PanelHeight {
    /// The whole panel, header and footer included, stays within this share of the
    /// screen's visible height. The #121 cap was "everything but the chrome", which let
    /// the panel reach from the menubar to the Dock (operator report, 2026-10-31).
    static let screenShare: CGFloat = 0.75

    /// Room left for the scrolling boards: the panel's share of the screen minus the
    /// header, the footer and the gap under the menubar, all of which grow with the text
    /// size. 240 points is the floor on a screen too short for any cap.
    static func boardsCap(visibleHeight: CGFloat, textFactor: CGFloat,
                          chrome: CGFloat = PanelDensity.full.chrome) -> CGFloat {
        max(240, visibleHeight * screenShare - chrome * textFactor)
    }
}

/// Full shows the settings rows under the boards; compact folds them away and keeps
/// every data row. Compact changes layout only, never what is read.
enum PanelDensity: String {
    case full
    case compact

    /// Points the header and footer take at text factor 1, used by the height cap.
    var chrome: CGFloat {
        switch self {
        case .full: return 300
        // Header, one footer row and the menubar gap; the settings block is folded.
        case .compact: return 170
        }
    }

    /// Start at login, Remember Claude seats, Text size and the key hints. Errors from
    /// those settings still show in compact: an error is data, the switch is not.
    var showsSettings: Bool { self == .full }

    static let preferenceKey = "panelDensity"
    /// `panelshot` and a dev run can pick a density without touching the stored setting.
    static let environmentKey = "TOWER_PANEL_DENSITY"

    static func stored(defaults: UserDefaults,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> PanelDensity {
        if let forced = environment[environmentKey].flatMap({ PanelDensity(rawValue: $0.lowercased()) }) {
            return forced
        }
        return defaults.string(forKey: preferenceKey).flatMap(PanelDensity.init(rawValue:)) ?? .full
    }
}
