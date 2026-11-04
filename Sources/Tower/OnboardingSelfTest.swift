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

    /// Counts what the MCP server pushes on its own (notifications).
    final class PushRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [JSON] = []
        func record(_ m: JSON) { lock.lock(); messages.append(m); lock.unlock() }
        func clear() { lock.lock(); messages.removeAll(); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
    }

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

        // 5a. While the first run is still pending nothing is watched, so MCP is off too,
        // even with mcp.enabled never written (unset otherwise reads ON for upgrades).
        let (pendingDefaults, pendingID) = suite("mcp-pending")
        defer { UserDefaults.standard.removePersistentDomain(forName: pendingID) }
        pendingDefaults.set(true, forKey: ProviderToggles.setupPendingKey)
        let pendingOff = !MCPAccess.isEnabled(defaults: pendingDefaults)
        pendingDefaults.set(false, forKey: ProviderToggles.setupPendingKey)
        check("mcp: OFF while the first run is pending, ON after it with mcp.enabled unset",
              pendingOff && MCPAccess.isEnabled(defaults: pendingDefaults), "")

        // 5. MCP off: every tool refuses with one structured error, no crash.
        let mcpDir = FileManager.default.temporaryDirectory.appendingPathComponent("tower-selftest-mcp-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mcpDir) }
        var env = TowerMCPService.Environment.demo(supportDirectory: mcpDir)
        let (mcpDefaults, mcpID) = suite("mcp")
        defer { UserDefaults.standard.removePersistentDomain(forName: mcpID) }
        env.defaults = mcpDefaults
        let service = TowerMCPService(env: env)
        // Turned off the way the panel does it: a direct write, never through MCP.
        mcpDefaults.set(false, forKey: MCPAccess.enabledKey)
        let refused = blocking { (try? await service.callTool("tower_status", arguments: [:])) ?? .refused("threw", "threw") }
        check("mcp: OFF refuses every tool with MCPDisabled and says where to turn it on",
              refused.isError
                  && refused.structuredContent?["error"]["code"] == .string(MCPAccess.refusalCode)
                  && MCPAccess.refusalMessage.contains("Settings"), "\(refused.content)")

        // Security 1: the gate sits at the protocol dispatch, so every data method refuses,
        // not only tools/call. initialize and server/discover answer and say MCP is off.
        let pushed = PushRecorder()
        let server = MCPServer(service: service, send: { pushed.record($0) })
        let uri = service.listResources().first?.uri ?? "tower://status"
        let prompt = service.listPrompts().first?.name ?? "rotate"
        let modernMeta: JSON = [MCPServer.metaVersion: .string(MCPServer.latestProtocolVersion),
                                MCPServer.metaClientCapabilities: [:]]
        func request(_ method: String, _ params: JSON = [:], modern: Bool = false) -> JSON {
            var p = params.objectValue ?? [:]
            if modern { p["_meta"] = modernMeta }
            let message: JSON = ["jsonrpc": "2.0", "id": 7, "method": .string(method), "params": .object(p)]
            return blocking { await server.handle(message) ?? .null }
        }
        func isDisabled(_ r: JSON) -> Bool {
            r["error"]["data"]["code"] == .string(MCPAccess.refusalCode)
                && (r["error"]["message"].stringValue ?? "").contains("Settings")
        }
        let dataMethods: [(String, JSON, Bool)] = [
            ("tools/list", [:], false), ("tools/call", ["name": "tower_status"], false),
            ("resources/list", [:], false), ("resources/templates/list", [:], false),
            ("resources/read", ["uri": .string(uri)], false), ("resources/subscribe", ["uri": .string(uri)], false),
            ("prompts/list", [:], false), ("prompts/get", ["name": .string(prompt)], false),
            ("completion/complete", ["ref": ["type": "ref/prompt", "name": .string(prompt)],
                                     "argument": ["name": "x", "value": ""]], false),
            ("ping", [:], false), ("logging/setLevel", ["level": "debug"], false),
            ("tools/list", [:], true), ("resources/read", ["uri": .string(uri)], true),
            ("subscriptions/listen", ["notifications": ["resourcesListChanged": true]], true),
        ]
        let leaked = dataMethods.filter { !isDisabled(request($0.0, $0.1, modern: $0.2)) }.map { "\($0.0)\($0.2 ? " (modern)" : "")" }
        check("mcp: OFF refuses every data method at the protocol layer with MCPDisabled",
              leaked.isEmpty, "answered: \(leaked)")
        let hello = request("initialize", ["protocolVersion": "2025-11-25"])
        let discover = request("server/discover", [:], modern: true)
        check("mcp: OFF still answers initialize and server/discover, saying MCP is off",
              (hello["result"]["instructions"].stringValue ?? "").contains(MCPAccess.refusalMessage)
                  && (discover["result"]["instructions"].stringValue ?? "").contains(MCPAccess.refusalMessage), "")
        pushed.clear()
        blocking { await server.resourceListChanged(); await server.resourcesUpdated([uri]) }
        check("mcp: OFF pushes no resource notifications", pushed.count == 0, "\(pushed.count)")

        mcpDefaults.set(true, forKey: MCPAccess.enabledKey)
        let stillRefused = dataMethods.filter { isDisabled(request($0.0, $0.1, modern: $0.2)) }.map(\.0)
        let listed = request("tools/list")["result"]["tools"].arrayValue?.isEmpty == false
            && request("resources/list")["result"]["resources"].arrayValue != nil
            && request("prompts/list")["result"]["prompts"].arrayValue != nil
            && request("resources/read", ["uri": .string(uri)])["result"]["contents"].arrayValue != nil
        check("mcp: ON answers every data method again", stillRefused.isEmpty && listed, "refused: \(stillRefused)")
        let cleanHello = request("initialize", ["protocolVersion": "2025-11-25"])
        check("mcp: ON initialize no longer says MCP is off",
              !(cleanHello["result"]["instructions"].stringValue ?? "").contains(MCPAccess.refusalMessage), "")
        let allowed = blocking { (try? await service.callTool("tower_config_get", arguments: [:])) ?? .refused("threw", "threw") }
        check("mcp: ON answers again, and tower_config_get carries the watch settings",
              !allowed.isError && allowed.structuredContent?["settings"]["watch"]["mcpEnabled"] == .bool(true), "")

        // Security 2: an agent cannot change the user's consent settings. Every consent key
        // is refused by tower_config_set with UserConsentRequired and stays as stored.
        let consentProbes: [(String, JSON)] = WatchedProvider.allCases.map { ($0.defaultsKey, .bool(false)) }
            + [(MCPAccess.enabledKey, .bool(false)), (AlertSettings.notifyKey, .bool(false)),
               (AlertSettings.fiveHourKey, .number(60)), (AlertSettings.weeklyKey, .number(60)),
               (AlertSettings.fableKey, .number(60))]
        for p in WatchedProvider.allCases { ProviderToggles.set(p, true, defaults: mcpDefaults) }
        mcpDefaults.set(true, forKey: AlertSettings.notifyKey)
        for k in [AlertSettings.fiveHourKey, AlertSettings.weeklyKey, AlertSettings.fableKey] { mcpDefaults.set(85.0, forKey: k) }
        let before = SettingsConfig.json(defaults: mcpDefaults)
        var writable: [String] = []
        for (key, value) in consentProbes {
            let r = service.configSet(key: key, value: value)
            let refusedRight = r.isError
                && r.structuredContent?["error"]["code"] == .string(SettingsConfig.consentRefusalCode)
                && r.content == [.text("\(SettingsConfig.consentRefusalCode): \(key) is the user's choice: change this in Tower Settings")]
            if !refusedRight { writable.append(key) }
        }
        check("config: tower_config_set refuses every consent key with UserConsentRequired",
              writable.isEmpty && consentProbes.count == WatchedProvider.allCases.count + 5, "accepted: \(writable)")
        check("config: a refused consent write leaves every stored value unchanged",
              SettingsConfig.json(defaults: mcpDefaults) == before && MCPAccess.isEnabled(defaults: mcpDefaults), "")
        let listedKeys = Set((allowed.structuredContent?["settings"]["watch"]["providers"].objectValue ?? [:]).keys)
        check("config: tower_config_get still lists every consent setting",
              listedKeys == Set(WatchedProvider.allCases.map(\.rawValue))
                  && !allowed.structuredContent!["settings"]["watch"]["alerts"]["notify"].isNull, "\(listedKeys)")
        // The panel's own setters (Settings ▸ Providers, Alerts) still write.
        ProviderToggles.set(.codex, false, defaults: mcpDefaults)
        AlertSettings.write(AlertSettings.weeklyKey, 70, defaults: mcpDefaults)
        check("config: the panel's own setters still write the consent settings",
              !ProviderToggles.isEnabled(.codex, defaults: mcpDefaults)
                  && AlertSettings.current(defaults: mcpDefaults).weekly == 70, "")
        check("config: the watch settings validate against their schema",
              JSONSchemaCheck.validate(SettingsConfig.json(defaults: mcpDefaults), against: SettingsConfig.schema).isEmpty, "")
        check("config: Copy config holds the two documented lines",
              MCPConfigLines.both == "ln -sf ~/Applications/Tower.app/Contents/MacOS/Tower ~/.local/bin/tower\n"
                  + "claude mcp add --scope user tower -- ~/.local/bin/tower mcp", "")
    }
}
