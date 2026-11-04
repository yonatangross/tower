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

    /// `TOWER_PANELSHOT_SCALE=3 tower panelshot out.png` rasterizes the same vector panel
    /// at 3 pixels per point, for video frames that a 2x screen capture would blur when
    /// scaled up. Unset keeps the screen's own backing scale, as before.
    nonisolated static let scaleEnvKey = "TOWER_PANELSHOT_SCALE"
    nonisolated static let scaleRange = 1...4

    /// nil = unset (the screen's backing scale). A value that is not a whole number in
    /// `scaleRange` is an error, never a silent fallback to 1x or 2x.
    nonisolated static func requestedScale(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<Int?, ScaleError> {
        guard let raw = env[scaleEnvKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return .success(nil) }
        guard let value = Int(raw), scaleRange.contains(value) else { return .failure(ScaleError(raw: raw)) }
        return .success(value)
    }

    struct ScaleError: Error, Equatable {
        let raw: String
        var message: String {
            "panelshot: \(PanelShot.scaleEnvKey)=\(raw) is not a whole number from "
                + "\(PanelShot.scaleRange.lowerBound) to \(PanelShot.scaleRange.upperBound)"
        }
    }

    /// A bitmap of `bounds` points at exactly `scale` pixels per point. `size` stays in
    /// points, so cacheDisplay draws the vector content at the higher density instead of
    /// stretching a 1x image onto a larger canvas.
    nonisolated static func bitmap(for bounds: NSRect, scale: Int) -> NSBitmapImageRep? {
        guard bounds.width > 0, bounds.height > 0, scaleRange.contains(scale) else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * CGFloat(scale)).rounded()),
            pixelsHigh: Int((bounds.height * CGFloat(scale)).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = bounds.size
        return rep
    }

    static func run(to url: URL) async -> Int32 {
        let scale: Int?
        switch requestedScale() {
        case .success(let value): scale = value
        case .failure(let error):
            print(error.message)
            return 2
        }
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
        // A demo shot never runs it: SESSIONS stays "not read yet" instead of real sessions.
        if CommandLine.arguments.contains("sessions"), DemoMode.runsLiveSessionProbe() {
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

        let made = scale.map { bitmap(for: view.bounds, scale: $0) }
            ?? view.bitmapImageRepForCachingDisplay(in: view.bounds)
        guard let rep = made else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:])
        else { return 1 }
        do {
            try png.write(to: url)
            print("wrote \(url.path) (\(Int(size.width))x\(Int(size.height)) pt, "
                  + "\(rep.pixelsWide)x\(rep.pixelsHigh) px)")
            return 0
        } catch {
            print("panelshot failed: \(error)")
            return 1
        }
    }
}
