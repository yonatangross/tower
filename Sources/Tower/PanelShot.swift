import SwiftUI
import AppKit

/// `tower panelshot out.png` renders the real panel offscreen so the layout can
/// be checked without Accessibility permission on the live menubar instance.
/// It renders only persisted data and never reads credentials or refreshes live
/// providers, stores, history, or notifications.
@MainActor
enum PanelShot {
    /// A shot owns its disclosure state, so `panelshot expand` cannot change
    /// the running panel's remembered sections.
    static func makeModel(
        expandedWriter: @escaping (Set<String>) -> Void = { _ in }
    ) -> LimitsModel {
        LimitsModel(expanded: [], persistExpanded: false, expandedWriter: expandedWriter)
    }

    /// Prepares the exact content that the offscreen renderer mounts. Keeping
    /// it cached here prevents the view's normal on-appear refresh.
    static func makeContent(
        model: LimitsModel,
        cachedHydration: () -> Void
    ) -> MenuContent {
        cachedHydration()
        return MenuContent(model: model, refreshMode: .cached)
    }

    static func run(to url: URL) async -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Offscreen views get no appearance from a window, so name one: without
        // it, labelColor text rasterizes dark-on-dark and looks absent.
        let light = CommandLine.arguments.contains("light")
        let dark = light ? "aqua" : "darkAqua"
        app.appearance = NSAppearance(named: NSAppearance.Name(rawValue: dark))

        let model = makeModel()
        let content = makeContent(
            model: model, cachedHydration: { model.hydrateForPanelShot() })

        // `panelshot expand` pre-opens the first ready seat row so the detail
        // grid is part of the render.
        if CommandLine.arguments.contains("expand"),
           let first = AccountSnapshot.partition(
               model.accounts, rule: .either, now: Date()).active.first {
            model.expanded.insert("seat.\(first.id)")
        }

        // `panelshot sessions` runs the session probe the panel runs (`claude agents --json`
        // and the per-session transcript and anchor reads, no credential), so the SESSIONS
        // section can be checked in a render instead of reading "not read yet".
        if CommandLine.arguments.contains("sessions") {
            model.agents = await AgentProbe.fetch()
            model.probed = true
        }

        // `panelshot unfold` opens the folds (stale seats, each TypeSafe credit row, idle
        // sessions) so the render shows what the folded lines hide.
        if CommandLine.arguments.contains("unfold") {
            model.expanded.formUnion([SeatBoard.staleDisclosureID, "sessions.idle"]
                                     + TypeSafe.Model.allCases.map(MoneyBoard.disclosureID))
        }

        let hosting = NSHostingController(
            rootView: content
                .frame(width: TowerTextSize.pt(TowerType.panelWidth))
                .preferredColorScheme(light ? .light : .dark)
                .background(Color(nsColor: .windowBackgroundColor)))
        let view = hosting.view
        var size = view.fittingSize
        if size.height <= 0 { size = NSSize(width: TowerTextSize.pt(TowerType.panelWidth), height: 600) }

        // A bare view inherits no appearance reliably; a borderless, unordered
        // window gives the subtree real appearance plumbing to resolve
        // semantic colors against.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: TowerTextSize.pt(TowerType.panelWidth), height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: NSAppearance.Name(rawValue: dark))
        window.contentView = view
        window.layoutIfNeeded()

        // Give SwiftUI a moment to commit the layout before rasterizing.
        try? await Task.sleep(nanoseconds: 300_000_000)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:])
        else { return 1 }
        do {
            try png.write(to: url)
            print("wrote \(url.path) (\(Int(size.width))x\(Int(size.height)))")
            return 0
        } catch {
            print("panelshot failed: \(error)")
            return 1
        }
    }
}
