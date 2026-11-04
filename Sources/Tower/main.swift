import Foundation
import AppKit

// Single-instance guard: if another Tower is running, activate it and exit.
func enforceSingleInstance() {
    let bundleID = ProductIdentity.bundleIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    guard let first = others.first else { return }
    // activate() without options is the macOS 14+ replacement for activateIgnoringOtherApps
    first.activate()
    exit(0)
}

// `tower status`            -> one-shot text table, no GUI.
// `tower selftest`          -> pure-logic checks, no network, no GUI.
// `tower mcp`               -> stdio MCP server, no GUI (docs/mcp-surface.md).
// `tower mcp --self-test`   -> list the tools and read one account, then exit.
// no args                   -> menubar app.
let args = Set(CommandLine.arguments.dropFirst())
// The one mode that runs, decided once. The demo gate below and the dispatch after it
// both read this value, so the gate always judges the verb that actually runs.
let verb = DemoMode.dispatched(args: args)

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

case .app:
    enforceSingleInstance()
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
