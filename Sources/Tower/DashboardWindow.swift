import AppKit
import Combine
import OSLog
import WebKit

/// The full dashboard: a WKWebView hosting the approved page (Resources/Dashboard/index.html),
/// fed by DashboardFeed. It loads nothing but that page: a non persistent data store, content
/// rules that block every network scheme, and a navigation delegate that accepts only the page.
@MainActor
final class DashboardController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    /// The page itself, the approved size.
    static let size = NSSize(width: 1080, height: 780)
    /// The native footer under the page: the way back to the classic panel, and Quit.
    static let footerHeight: CGFloat = 30
    /// What the panel is sized to: the page plus the footer.
    static let panelSize = NSSize(width: size.width, height: size.height + footerHeight)
    static let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "dashboard")

    private let service: TowerMCPService
    private var webView: WKWebView!
    private var loaded = false
    private var pending: JSON?
    private var changes: AnyCancellable?
    private var rebuild: Task<Void, Never>?
    /// Wired by the app: the footer's switch and Quit buttons.
    var onSwitch: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Wired by the app: what the page's two buttons do. Nothing is wired in a screenshot run.
    var onAction: ((DashboardBridge.Action) -> Void)?
    private var footer: NSView?

    init(service: TowerMCPService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = false
        // The page's only way to ask Swift for anything: one word from DashboardBridge.Action.
        config.userContentController.add(WeakScriptHandler(self), name: DashboardBridge.handlerName)
        let web = WKWebView(frame: NSRect(x: 0, y: Self.footerHeight, width: Self.size.width, height: Self.size.height),
                            configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        webView = web

        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.addSubview(web)
        container.addSubview(makeFooter())
        view = container
        preferredContentSize = Self.panelSize
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "tower-dashboard-offline", encodedContentRuleList: DashboardFeed.contentRules
        ) { [weak self] list, error in
            MainActor.assumeIsolated {
                // Fail closed: without the rules that block every network scheme the page does
                // not load at all (review b114 on #152; the CSP alone would have held).
                guard let list else {
                    DashboardController.log.error("content rules failed to compile: \(String(describing: error), privacy: .public)")
                    self?.loadNotice("The dashboard could not start its offline rules, so it did not load. Use the Classic panel button below.")
                    return
                }
                config.userContentController.add(list)
                self?.loadPage()
            }
        }
    }

    /// The native strip under the page. The page is the approved design and has no way to
    /// leave itself, so the way back lives here, always visible.
    private func makeFooter() -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: Self.size.width, height: Self.footerHeight))
        footer = bar
        bar.autoresizingMask = [.width]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor

        func button(_ title: String, _ action: Selector, x: CGFloat? = nil, trailing: CGFloat? = nil) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .inline
            b.controlSize = .small
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1),
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ])
            b.sizeToFit()
            var f = b.frame
            f.origin.y = (Self.footerHeight - f.height) / 2
            if let x { f.origin.x = x }
            if let trailing { f.origin.x = Self.size.width - trailing - f.width; b.autoresizingMask = [.minXMargin] }
            b.frame = f
            return b
        }
        let switchLabel = PanelSurface.dashboard.switchLabel
        let switcher = button("◂ \(switchLabel)", #selector(switchClicked), x: 16)
        switcher.setAccessibilityLabel("Open the \(switchLabel)")
        switcher.toolTip = "Open the classic panel from the menu bar instead. Right click the menu bar item for the same switch."
        let quit = button("Quit", #selector(quitClicked), trailing: 16)
        bar.addSubview(switcher)
        bar.addSubview(quit)
        return bar
    }

    @objc private func switchClicked() { onSwitch?() }
    @objc private func quitClicked() { onQuit?() }

    private func loadPage() {
        guard let html = DashboardFeed.bundledPage() else {
            loadNotice("This Tower build has no dashboard page. Use the Classic panel button below.")
            return
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// A plain notice in place of the page. Static text only; no feed, no script.
    private func loadNotice(_ text: String) {
        webView.loadHTMLString("<body style=\"font:15px -apple-system;color:#ccc;background:#111;padding:40px\">\(text)</body>", baseURL: nil)
    }

    /// Rebuild the feed now and whenever the model changes (debounced one second).
    func start() {
        guard changes == nil else { scheduleRebuild(after: 0); return }
        changes = LimitsModel.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild(after: 1) }
        scheduleRebuild(after: 0)
    }

    /// Stop rebuilding the feed: called when the panel hides or the surface changes. A later
    /// `start()` resumes with a fresh build.
    func stop() {
        changes?.cancel()
        changes = nil
        rebuild?.cancel()
        rebuild = nil
    }

    private func scheduleRebuild(after seconds: Double) {
        rebuild?.cancel()
        let service = self.service
        rebuild = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            guard !Task.isCancelled else { return }
            let probe = DashboardFeed.SessionsProbe()
            var feed = await DashboardFeed.build(
                service: service, notice: LimitsModel.shared.seatRetentionError,
                sessionDeadline: DashboardFeed.firstPaintDeadline, probe: probe)
            guard !Task.isCancelled else { return }
            if case .object(var o) = feed { o["icons"] = DashboardFeed.icons(); feed = .object(o) }
            self?.push(feed)
            // The first feed did not wait for the slow session probe: follow with the full one,
            // which awaits the same running probe instead of starting another.
            guard feed["sessionsDeferred"].boolValue == true else { return }
            var full = await DashboardFeed.build(service: service, notice: LimitsModel.shared.seatRetentionError, sessionDeadline: nil, probe: probe)
            guard !Task.isCancelled else { return }
            if case .object(var o) = full { o["icons"] = DashboardFeed.icons(); full = .object(o) }
            self?.push(full)
        }
    }

    func push(_ feed: JSON) {
        guard loaded else { pending = feed; return }
        webView.evaluateJavaScript("window.towerUpdate(\(DashboardFeed.jsLiteral(feed)));1") { _, error in
            if let error { DashboardController.log.error("dashboard update failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let action = DashboardBridge.Action(body: message.body) else {
            DashboardController.log.error("dashboard ignored a message outside the closed list")
            return
        }
        onAction?(action)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(DashboardFeed.NavigationPolicy.allows(action.request.url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let pending { self.pending = nil; push(pending) }
    }

    /// One offscreen render for the compare step: `tower dashboardshot out.png [dial]`.
    func snapshot(surface: String, to url: URL) async -> Int32 {
        for _ in 0..<200 where !loaded { try? await Task.sleep(nanoseconds: 50_000_000) }
        let feed = await DashboardFeed.build(service: service, sessionDeadline: nil)
        var full = feed
        if case .object(var o) = feed { o["icons"] = DashboardFeed.icons(); full = .object(o) }
        push(full)
        // An offscreen window stalls CSS animation; a still frame shows the final state.
        _ = try? await webView.evaluateJavaScript("document.head.insertAdjacentHTML('beforeend','<style>*{animation:none!important;transition:none!important}</style>');window.towerSurface('\(surface == "dial" ? "dial" : "dash")');document.querySelectorAll('[data-count]').forEach(e=>{e.textContent=(e.dataset.pre||'')+e.dataset.count+(e.dataset.suf||'')});1")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let image = try? await webView.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: url); print("wrote \(url.path)") } catch { print("write failed: \(error)"); return 1 }
        // The panel as the operator sees it: the page with the native footer under it.
        if let footer, let barRep = footer.bitmapImageRepForCachingDisplay(in: footer.bounds) {
            footer.cacheDisplay(in: footer.bounds, to: barRep)
            let size = Self.panelSize
            let whole = NSImage(size: size)
            whole.lockFocus()
            image.draw(in: NSRect(x: 0, y: Self.footerHeight, width: size.width, height: Self.size.height))
            NSImage(size: footer.bounds.size, flipped: false) { _ in barRep.draw(); return true }
                .draw(in: NSRect(x: 0, y: 0, width: size.width, height: Self.footerHeight))
            whole.unlockFocus()
            if let t = whole.tiffRepresentation, let r = NSBitmapImageRep(data: t),
               let p = r.representation(using: .png, properties: [:]) {
                let withFooter = url.deletingPathExtension().appendingPathExtension("panel.png")
                do { try p.write(to: withFooter); print("wrote \(withFooter.path)") } catch { print("write failed: \(error)") }
            }
        }
        return 0
    }
}

/// WKUserContentController retains its handlers, so a handler that is the controller itself would
/// keep the controller alive. This forwards to it weakly.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension DashboardFeed {
    /// Provider marks as data URLs, only when the bundle carries them (TOWER_BRAND_MARKS=local).
    /// Keys follow the page's icon names. An absent mark draws the page's monogram.
    static func icons(bundle: Bundle? = nil) -> JSON {
        guard let dir = (bundle ?? resourceBundle()).resourceURL?.appendingPathComponent("BrandMarks") else { return .object([:]) }
        var out: [String: JSON] = [:]
        for name in ["claude", "chatgpt", "cursor", "devin", "antigravity"] {
            let data = (try? Data(contentsOf: dir.appendingPathComponent("\(name)@2x.png")))
                ?? (try? Data(contentsOf: dir.appendingPathComponent("\(name).png")))
            if let data {
                out[name] = .string("data:image/png;base64," + data.base64EncodedString())
            }
        }
        return .object(out)
    }
}

enum DashboardShot {
    @MainActor
    static func run(to url: URL, surface: String) async -> Int32 {
        let controller = DashboardController(service: TowerMCPService(env: .live()))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: DashboardController.panelSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderBack(nil)
        let code = await controller.snapshot(surface: surface, to: url)
        window.orderOut(nil)
        return code
    }
}
