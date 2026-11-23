import Foundation
import AppKit

// The one single-instance gate, before NSApplication exists. A LIVE other Tower (by pid, so a
// dead Launch Services record of a build that has exited never counts) is asked
// to show its panel and brought forward; this launch then exits without a menu bar item.
func enforceSingleInstance() {
    guard let other = MainActor.assumeIsolated({ SingleInstance.otherLiveInstance() }) else { return }
    DistributedNotificationCenter.default().postNotificationName(
        SingleInstance.showPanelNotification, object: nil, userInfo: nil, deliverImmediately: true)
    // activate() without options is the macOS 14+ replacement for activateIgnoringOtherApps
    NSRunningApplication(processIdentifier: other)?.activate()
    exit(0)
}

// First, before anything can open the store: a dev copy never shares the installed Tower's.
DevCopyIsolation.apply()

// `tower status`            -> one-shot text table, no GUI.
// `tower selftest`          -> pure-logic checks, no network, no GUI.
// `tower mcp`               -> stdio MCP server, no GUI (docs/mcp-surface.md).
// `tower mcp --self-test`   -> list the tools and read one account, then exit.
// no args                   -> menubar app.
let args = Set(CommandLine.arguments.dropFirst())
// The one mode that runs, decided once. The demo gate below and the dispatch after it
// both read this value, so the gate always judges the verb that actually runs.
let verb = DemoMode.dispatched(args: args)

// Before any Keychain call in any mode (app, CLI, MCP): no dialog unless the operator's
// Re-trust opens one (KeychainDialogGate, measured 2026-11-04).
KeychainDialogGate.shared.closeForProcess()

if verb == .selftest {
    exit(CLI.selftest())
}

// TOWER_DEMO=1 promises no real credential is read. Only the MCP server and panelshot
// are wired for it (TowerMCPService.Environment.demo, the cached panel); status, rotate,
// login-item and the app read the Keychain or the network directly, so they refuse
// instead of quietly running live. TOWER_DEMO without TOWER_SUPPORT_DIR refuses too.
if ProcessInfo.processInfo.environment["TOWER_DEMO"] == "1" {
    if DemoMode.isMisconfigured() {
        FileHandle.standardError.write(Data("TOWER_DEMO=1 needs TOWER_SUPPORT_DIR pointing at a demo store\n".utf8))
        exit(2)
    }
    if let why = DemoMode.refusal(args: args) {
        FileHandle.standardError.write(Data((why + "\n").utf8))
        exit(2)
    }
}

// Every mode below reads the store or the settings, so a pre-v0.1 install is carried
// over first. A no-op once done.
LegacyInstallMigration.runAtLaunch()

switch verb {
case .selftest:
    exit(CLI.selftest())

case .mcp:
    // A first Keychain read can raise the dialog, exactly as `tower status` can, so the
    // server never reads a token until a tool that needs one is called.
    let service = TowerMCPService(env: .live())
    if args.contains("--self-test") {
        exit(MCPSelfTest.run(service))
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        let server = MCPServer(service: service, send: { MCPStdio.write($0) })
        let watcher = MCPQuotaWatcher(service: service, server: server)
        watcher.start()
        await MCPStdio.serve(server)
        watcher.stop()
        sem.signal()
    }
    sem.wait()
    exit(0)

case .rotate:
    exit(CLI.rotate())

case .retrust:
    // The one read that may show the Keychain dialog, started from a terminal or an agent.
    // macOS asks Always Allow once per seat; the user answers it.
    let report = CLI.retrustReport(ClaudeSeatVault.shared.retrust())
    report.lines.forEach { print($0) }
    exit(report.code)

case .loginItem:
    if args.contains("on") || args.contains("off") {
        if let err = LaunchAtLogin.set(args.contains("on")) {
            print("failed: \(err)")
            exit(1)
        }
    }
    print("start at login: \(LaunchAtLogin.isEnabled ? "ENABLED" : "disabled")")
    exit(0)

case .status:
    let sem = DispatchSemaphore(value: 0)
    Task {
        await CLI.run()
        sem.signal()
    }
    sem.wait()
    exit(0)

case .panelshot:
    let out = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".png") })
        ?? "/tmp/tower-panel.png"
    // The renderer must live on the main actor, so block on the run loop rather
    // than a semaphore, which would deadlock it.
    var code: Int32 = 1
    var done = false
    Task { @MainActor in
        code = await PanelShot.run(to: URL(fileURLWithPath: out))
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(code)

case .dashboardFeed:
    // The dashboard page's feed as JSON (reads the store only, no Keychain).
    var feedDone = false
    Task {
        let feed = await DashboardFeed.build(service: TowerMCPService(env: .live()))
        print(String(decoding: feed.encoded(pretty: true), as: UTF8.self))
        feedDone = true
    }
    while !feedDone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)

case .dashboardShot:
    // The real web view rendered offscreen, for compares. `dial` picks the dial surface.
    let dashOut = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".png") })
        ?? "/tmp/tower-dashboard.png"
    var dashCode: Int32 = 1
    var dashDone = false
    Task { @MainActor in
        dashCode = await DashboardShot.run(to: URL(fileURLWithPath: dashOut),
                                           surface: args.contains("dial") ? "dial" : "dash")
        dashDone = true
    }
    while !dashDone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(dashCode)

case .app:
    enforceSingleInstance()
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
