import Foundation

/// Selftest rows for the first run and Settings (approved-design/onboarding-mockup.txt).
/// Every row uses its own throwaway defaults suite and invented paths: no real setting,
/// store, token or Keychain item is touched.
enum OnboardingSelfTest {
    /// Records every path detection asks about. It has no read call, like the real probe.
    final class RecordingProbe: PathProbe {
        var asked: [String] = []
        let present: Set<String>
        init(present: Set<String>) { self.present = present }
        func exists(_ path: String) -> Bool { asked.append(path); return present.contains(path) }
    }

    /// Counts every reader call, so an OFF provider can be proved to get zero.
    final class ReaderSpy: @unchecked Sendable {
        var cursor = 0, openRouter = 0, codex = 0, laneCalls = 0
        var lanesAsked: Set<Provider> = []
        var readers: ProviderReaders {
            ProviderReaders(
                cursor: { self.cursor += 1; return .notConfigured },
                openRouter: { self.openRouter += 1; return .notConfigured },
                codex: { self.codex += 1; return nil },
                lanes: { allowed in self.laneCalls += 1; self.lanesAsked = allowed; return [:] })
        }
    }

    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = await work(); done.signal() }
        done.wait()
        return box.value!
    }

    private static func suite(_ name: String) -> (UserDefaults, String) {
        let id = "tower-selftest-onboarding-\(name)-\(UUID().uuidString)"
        return (UserDefaults(suiteName: id)!, id)
    }

    static func run(_ check: (String, Bool, String) -> Void) {
        // 1. Detection asks only whether named paths exist; it never names a token file.
        let home = "/tmp/tower-selftest-home"
        let probe = RecordingProbe(present: ["\(home)/.codex", "\(home)/.local/bin/muse", "/Applications/Cursor.app"])
        let keychainBefore = KeychainCallCounter.shared.total
        let found = ProviderDetection.detect(probe: probe, home: home, claudeSeats: { 3 })
        let tokenish = probe.asked.filter { path in
            ["auth.json", "state.vscdb", ".credentials", "user_status", "Keychain", "settings.json", "accounts.json"]
                .contains { path.contains($0) }
        }
        check("first run: detection opens no token file, only asks whether named paths exist",
              tokenish.isEmpty && !probe.asked.isEmpty, "asked \(tokenish)")
        check("first run: detection makes no Keychain call",
              KeychainCallCounter.shared.total == keychainBefore, "")
        check("first run: detection finds Codex, Muse, Cursor and 3 Claude seats, and nothing it was not shown",
              found.found == [.codex, .muse, .cursor, .claude] && found.claudeSeats == 3, "\(found.found)")

        // 2. A provider is read only while its toggle is on: an OFF reader gets zero calls.
        let none = ReaderSpy()
        _ = blocking { await none.readers.probe(.none) }
        check("refresh: every provider OFF calls no reader at all",
              none.cursor == 0 && none.openRouter == 0 && none.codex == 0 && none.laneCalls == 0,
              "cursor \(none.cursor) openRouter \(none.openRouter) codex \(none.codex) lanes \(none.laneCalls)")
        let museOnly = ReaderSpy()
        _ = blocking { await museOnly.readers.probe(ProviderGate(enabled: [.muse])) }
        check("refresh: only Muse ON reads only the Muse lane",
              museOnly.cursor == 0 && museOnly.openRouter == 0 && museOnly.codex == 0
                  && museOnly.laneCalls == 1 && museOnly.lanesAsked == [.muse], "\(museOnly.lanesAsked)")
        let everything = ReaderSpy()
        _ = blocking { await everything.readers.probe(.all) }
        check("refresh: everything ON calls every reader once",
              everything.cursor == 1 && everything.openRouter == 1 && everything.codex == 1 && everything.laneCalls == 1, "")

        // 3 and 6. First launch: pending until answered, nothing read before Start watching,
        // and it opens once.
        let (fresh, freshID) = suite("fresh")
        defer { UserDefaults.standard.removePersistentDomain(forName: freshID) }
        let first = FirstRun.resolveAtLaunch(defaults: fresh, storeHasRows: false)
        check("first run: a fresh install shows the first run and reads nothing before it is answered",
              first == .show && ProviderGate.current(defaults: fresh) == .none, "\(ProviderGate.current(defaults: fresh))")
        let choices = SetupChoices.prefilled(found)
        check("first run: detection pre-fills ON what it found, Cursor waits for Connect, money and MCP stay OFF",
              choices.watch[.codex] == true && choices.watch[.muse] == true && choices.watch[.claude] == true
                  && choices.watch[.cursor] == false && choices.watch[.devin] == false
                  && choices.watch[.openrouter] == false && choices.mcp == false, "\(choices.watch)")
        FirstRun.startWatching(choices, defaults: fresh)
        check("first run: Start watching turns on exactly the chosen providers",
              ProviderGate.current(defaults: fresh).enabled == [.claude, .codex, .muse]
                  && !MCPAccess.isEnabled(defaults: fresh), "\(ProviderGate.current(defaults: fresh).enabled)")
        check("first run: opens once, never again unasked",
              FirstRun.resolveAtLaunch(defaults: fresh, storeHasRows: false) == .done, "")
        let (upgrade, upgradeID) = suite("upgrade")
        defer { UserDefaults.standard.removePersistentDomain(forName: upgradeID) }
        check("first run: an upgrade with store rows skips it and keeps every provider on",
              FirstRun.resolveAtLaunch(defaults: upgrade, storeHasRows: true) == .done
                  && ProviderGate.current(defaults: upgrade) == .all && MCPAccess.isEnabled(defaults: upgrade), "")
        let (skipped, skippedID) = suite("skip")
        defer { UserDefaults.standard.removePersistentDomain(forName: skippedID) }
        _ = FirstRun.resolveAtLaunch(defaults: skipped, storeHasRows: false)
        FirstRun.skip(defaults: skipped)
        check("first run: Skip leaves everything off and the panel says how to open Settings",
              ProviderGate.current(defaults: skipped) == .none && FirstRun.watchesNothing(defaults: skipped)
                  && FirstRun.skippedLine.contains("Settings"), "")

        // 7. The closing line, word for word from the approved mockup.
        check("first run: ends with the approved closing line",
              FirstRun.closingLine == "You can change any of this later: menu ▸ Settings…", FirstRun.closingLine)

        // 2b. OFF also leaves the panel at once.
        var codexRow = AccountSnapshot(email: "work@example.com", nickname: "work", plan: "pro")
        codexRow.provider = .codex
        let claudeRow = AccountSnapshot(email: "side@example.com", nickname: "side", plan: "max")
        check("settings: an OFF provider's rows leave the panel",
              ProviderToggles.visible([codexRow, claudeRow], defaults: skipped).isEmpty
                  && ProviderToggles.visible([codexRow, claudeRow], defaults: fresh).count == 2, "")

        // 4. Alerts: approved defaults 80 / 90 / 90; 95 and 100 always fire.
        check("alerts: defaults are 5h 80 %, 7d 90 %, Fable 90 %, notify on",
              AlertSettings.current(defaults: upgrade) == AlertSettings.defaults
                  && AlertSettings.defaults == AlertSettings(fiveHour: 80, weekly: 90, fable: 90, notify: true), "")
        var seat = AccountSnapshot(email: "a@example.com", nickname: "a", plan: "max")
        seat.weeklyResetsAt = Date().addingTimeInterval(3_600)
        seat.weeklyPct = 85
        let quiet = Thresholds.evaluate(&seat, settings: .defaults)
        seat.weeklyPct = 91
        let loud = Thresholds.evaluate(&seat, settings: .defaults)
        check("alerts: 7d warns at its own 90 %, not at 80", quiet.isEmpty && loud.count == 1, "\(quiet.count) \(loud.count)")
        var fable = AccountSnapshot(email: "f@example.com", nickname: "f", plan: "max")
        fable.scoped = [ScopedLimit(label: "Fable", percent: 92, resetsAt: Date().addingTimeInterval(3_600))]
        check("alerts: Fable warns at its own level", Thresholds.evaluate(&fable, settings: .defaults).map(\.window) == ["Fable"], "")

        // 5. MCP off: every tool refuses with one structured error, no crash.
        let mcpDir = FileManager.default.temporaryDirectory.appendingPathComponent("tower-selftest-mcp-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mcpDir) }
        var env = TowerMCPService.Environment.demo(supportDirectory: mcpDir)
        let (mcpDefaults, mcpID) = suite("mcp")
        defer { UserDefaults.standard.removePersistentDomain(forName: mcpID) }
        env.defaults = mcpDefaults
        let service = TowerMCPService(env: env)
        let offSet = service.configSet(key: MCPAccess.enabledKey, value: .bool(false))
        let refused = blocking { (try? await service.callTool("tower_status", arguments: [:])) ?? .refused("threw", "threw") }
        check("mcp: OFF refuses every tool with MCPDisabled and says where to turn it on",
              offSet.isError == false && refused.isError
                  && refused.structuredContent?["error"]["code"] == .string(MCPAccess.refusalCode)
                  && MCPAccess.refusalMessage.contains("Settings"), "\(refused.content)")
        mcpDefaults.set(true, forKey: MCPAccess.enabledKey)
        let allowed = blocking { (try? await service.callTool("tower_config_get", arguments: [:])) ?? .refused("threw", "threw") }
        check("mcp: ON answers again, and tower_config_get carries the watch settings",
              !allowed.isError && allowed.structuredContent?["settings"]["watch"]["mcpEnabled"] == .bool(true), "")

        // 8 and 9. The settings keys work over MCP in demo mode and validate against the schema.
        let setProvider = service.configSet(key: WatchedProvider.codex.defaultsKey, value: .bool(false))
        let badWarn = service.configSet(key: AlertSettings.weeklyKey, value: .number(99))
        check("config: a provider toggle and an alert level are settable; an out-of-range level is refused",
              !setProvider.isError && !ProviderToggles.isEnabled(.codex, defaults: mcpDefaults) && badWarn.isError, "")
        check("config: the watch settings validate against their schema",
              JSONSchemaCheck.validate(SettingsConfig.json(defaults: mcpDefaults), against: SettingsConfig.schema).isEmpty, "")
        check("config: Copy config holds the two documented lines",
              MCPConfigLines.both == "ln -sf ~/Applications/Tower.app/Contents/MacOS/Tower ~/.local/bin/tower\n"
                  + "claude mcp add --scope user tower -- ~/.local/bin/tower mcp", "")
    }
}
