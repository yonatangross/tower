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

        // b88 HOLD on #20: the live lane reader read every lane and filtered after, so Muse
        // OFF still spawned `muse usage`; tower_lanes over MCP ignored the toggles.
        let laneHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-lanes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: laneHome) }
        let fakeMuse = AgentLane.binary(.muse, home: laneHome)
        try? FileManager.default.createDirectory(at: fakeMuse.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fakeMuse.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        var museRuns = 0
        let devinOnly = AgentLane.readAll(home: laneHome, env: [:],
                                          museRunner: { _ in museRuns += 1; return nil }, only: [.devin])
        check("lanes: Muse OFF never runs muse usage, even with another lane ON",
              museRuns == 0 && Set(devinOnly.keys) == [.devin], "muse runs \(museRuns), read \(devinOnly.keys)")
        let (laneDefaults, laneID) = suite("mcp-lanes")
        defer { UserDefaults.standard.removePersistentDomain(forName: laneID) }
        laneDefaults.set(false, forKey: ProviderToggles.setupPendingKey)
        for p in WatchedProvider.allCases { ProviderToggles.set(p, p == .devin, defaults: laneDefaults) }
        var mcpEnv = TowerMCPService.Environment.demo(supportDirectory: laneHome)
        mcpEnv.defaults = laneDefaults
        mcpEnv.lanes = { Dictionary(uniqueKeysWithValues: AgentLane.lanes.map { ($0, AgentLane.Outcome.notConfigured) }) }
        let mcpListed = TowerMCPService(env: mcpEnv).lanes().structuredContent?["lanes"]
        let listedProviders: [String] = {
            guard case .array(let rows)? = mcpListed else { return [] }
            return rows.compactMap { if case .string(let s) = $0["provider"] { return s } else { return nil } }
        }()
        var panelshotAsked: [Set<Provider>] = []
        _ = PanelShotHydration.liveLanes(gate: { ProviderGate(enabled: [.devin]) },
                                         read: { panelshotAsked.append($0); return [:] })
        check("panelshot reads only the lanes that are ON",
              panelshotAsked == [[.devin]], "\(panelshotAsked)")
        check("tower_lanes lists only the lanes that are ON",
              listedProviders == [Provider.devin.rawValue], "\(listedProviders)")

        // b88 should-fix on #26: the MCP read tools returned stored rows of OFF providers.
        let offDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-off-rows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: offDir) }
        var claudeSeat = AccountSnapshot(email: "cc@example.com", nickname: "cc", plan: "max")
        claudeSeat.weeklyPct = 10
        var codexSeat = AccountSnapshot(email: "cx@example.com", nickname: "cx", plan: "pro")
        codexSeat.provider = .codex
        codexSeat.weeklyPct = 20
        _ = Store(dir: offDir).save(["cc@example.com": claudeSeat, "codex:cx@example.com": codexSeat])
        let (offDefaults, offID) = suite("off-rows")
        defer { UserDefaults.standard.removePersistentDomain(forName: offID) }
        offDefaults.set(false, forKey: ProviderToggles.setupPendingKey)
        for p in WatchedProvider.allCases { ProviderToggles.set(p, p != .codex, defaults: offDefaults) }
        var offEnv = TowerMCPService.Environment.demo(supportDirectory: offDir)
        offEnv.defaults = offDefaults
        let offService = TowerMCPService(env: offEnv)
        let offReads = [offService.status(), offService.accounts(provider: nil),
                        offService.account("cx"), offService.resets(), offService.freshness()]
        let offLeaked = offReads.filter { "\($0.content) \(String(describing: $0.structuredContent))".contains("cx@example.com") }
        let claudeShown = "\(offService.accounts(provider: nil).structuredContent.map { "\($0)" } ?? "")".contains("cc@example.com")
        // b87 on #31: the tower://quota-cache resource is filtered on read; the file on disk
        // stays whole for the hooks.
        let cacheText = offService.quotaCacheText()
        let fileText = (try? String(contentsOf: offDir.appendingPathComponent("accounts.json"), encoding: .utf8)) ?? ""
        check("tower://quota-cache hides OFF rows from agents, the file keeps them for hooks",
              !cacheText.contains("cx@example.com") && cacheText.contains("cc@example.com")
                  && fileText.contains("cx@example.com"), cacheText)
        check("MCP reads never return the stored rows of a provider that is OFF",
              offLeaked.isEmpty && claudeShown, "leaked in \(offLeaked.count) of \(offReads.count), claude shown \(claudeShown)")

        // Security review of #31: fail closed. The quota-cache resource keeps only rows it
        // knows are visible, even rows the store does not hold; an unparsable file is {}.
        if let stored = try? Data(contentsOf: offDir.appendingPathComponent("accounts.json")),
           var object = (try? JSONSerialization.jsonObject(with: stored)) as? [String: Any],
           var extra = object["codex:cx@example.com"] as? [String: Any] {
            extra["email"] = "zz@example.com"
            object["codex:zz@example.com"] = extra
            if let mirror = try? JSONSerialization.data(withJSONObject: object) {
                try? mirror.write(to: offDir.appendingPathComponent("quota-cache.json"))
            }
        }
        let allowText = offService.quotaCacheText()
        check("tower://quota-cache drops a row the store does not hold when its provider is OFF",
              !allowText.contains("zz@example.com") && !allowText.contains("cx@example.com")
                  && allowText.contains("cc@example.com"), allowText)
        try? Data("not json".utf8).write(to: offDir.appendingPathComponent("quota-cache.json"))
        check("tower://quota-cache answers {} when the file cannot be read as JSON",
              offService.quotaCacheText() == "{}", offService.quotaCacheText())
        try? FileManager.default.removeItem(at: offDir.appendingPathComponent("quota-cache.json"))

        // Claude OFF: no Claude identity, seat or session reaches an agent.
        let (noClaude, noClaudeID) = suite("claude-off")
        defer { UserDefaults.standard.removePersistentDomain(forName: noClaudeID) }
        noClaude.set(false, forKey: ProviderToggles.setupPendingKey)
        for p in WatchedProvider.allCases { ProviderToggles.set(p, p != .claude, defaults: noClaude) }
        var claudeOffEnv = TowerMCPService.Environment.demo(supportDirectory: offDir)
        claudeOffEnv.defaults = noClaude
        let offStore = claudeOffEnv.store
        claudeOffEnv.refresh = {
            RefreshResult(accounts: offStore.load(), activeEmail: "cc@example.com", outcome: .ok(email: "cc@example.com"),
                          openRouterOutcome: .notConfigured, openRouterFoldCommitted: false)
        }
        let claudeOff = TowerMCPService(env: claudeOffEnv)
        let refreshed = blocking { await claudeOff.refresh(account: nil) }
        check("tower_refresh never names the active login of a provider that is OFF",
              refreshed.structuredContent?["activeEmail"] == .null
                  && !"\(refreshed.content) \(String(describing: refreshed.structuredContent))".contains("cc@example.com"),
              "\(String(describing: refreshed.structuredContent?["activeEmail"]))")
        let seatsOff = claudeOff.seats()
        check("tower_seats refuses while Claude Code is OFF",
              seatsOff.structuredContent?["error"]["code"] == "ProviderOff", "\(seatsOff.content)")
        let sessionsOff = blocking { await claudeOff.sessions() }
        check("tower_sessions reports nothing while Claude Code is OFF",
              sessionsOff.structuredContent?["available"] == false, "\(sessionsOff.content)")

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

        visibilitySweep(check)
    }
}

// MARK: - Every MCP read path against every provider toggle (b90 HOLD on #41)

extension OnboardingSelfTest {
    /// One unique marker per provider, seeded where that provider's data lives. With every
    /// provider ON each marker must appear somewhere (so the sweep can see it at all); with
    /// one provider OFF none of its markers may appear in any tool, resource, prompt or
    /// listing. New tools are covered automatically: the sweep walks `TowerMCPService.tools`.
    static func visibilitySweep(_ check: (String, Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func row(_ email: String, _ nick: String, _ provider: Provider?) -> AccountSnapshot {
            var a = AccountSnapshot(email: email, nickname: nick, plan: "pro")
            a.provider = provider
            a.weeklyPct = 30
            a.capturedAt = Date().addingTimeInterval(-60)
            return a
        }
        _ = Store(dir: dir).save([
            "m-claude@marker.test": row("m-claude@marker.test", "mclaude", nil),
            "codex:m-codex@marker.test": row("m-codex@marker.test", "mcodex", .codex),
            "cursor:m-cursor@marker.test": row("m-cursor@marker.test", "mcursor", .cursor),
            "openrouter:m-openrouter@marker.test": row("m-openrouter@marker.test", "mopenrouter", .openrouter),
            "muse:m-muse@marker.test": row("m-muse@marker.test", "mmuse", .muse),
            "devin:m-devin@marker.test": row("m-devin@marker.test", "mdevin", .devin),
        ])
        try? Data(#"["m-known@marker.test"]"#.utf8).write(to: dir.appendingPathComponent("known-accounts.json"))
        try? Data(#"["m-retired@marker.test"]"#.utf8).write(to: dir.appendingPathComponent("retired-accounts.json"))

        let markers: [WatchedProvider: [String]] = [
            .claude: ["m-claude@marker.test", "m-known@marker.test", "m-retired@marker.test"],
            .codex: ["m-codex@marker.test"],
            .cursor: ["m-cursor@marker.test"],
            .openrouter: ["m-openrouter@marker.test", "77.75"],
            .jev: ["61.25"],
            .clef: ["93.5"],
            .muse: ["m-muse@marker.test"],
            .devin: ["m-devin@marker.test"],
        ]

        func everything(off: WatchedProvider?) -> String {
            let (defaults, id) = suite("sweep")
            defer { UserDefaults.standard.removePersistentDomain(forName: id) }
            defaults.set(false, forKey: ProviderToggles.setupPendingKey)
            for p in WatchedProvider.allCases { ProviderToggles.set(p, p != off, defaults: defaults) }
            OpenRouter.History.record(OpenRouter.Budget(spent: 10, limit: 87.75), defaults: defaults)
            for (model, usd) in [(TypeSafe.Model.jev, 61.25), (.clef, 93.5)] {
                defaults.set(usd, forKey: model.balanceKey)
                defaults.set("2026-11-04", forKey: model.balanceAsOfKey)
            }
            var env = TowerMCPService.Environment.demo(supportDirectory: dir)
            env.defaults = defaults
            let store = env.store
            env.refresh = {
                RefreshResult(accounts: store.load(), activeEmail: "m-claude@marker.test",
                              outcome: .ok(email: "m-claude@marker.test"),
                              openRouterOutcome: .notConfigured, openRouterFoldCommitted: false)
            }
            let service = TowerMCPService(env: env, retrustCooldown: RetrustCooldown())
            return blocking {
                var out = ""
                func add(_ r: MCPToolResult?) {
                    guard let r else { return }
                    out += "\(r.content) \(String(describing: r.structuredContent))\n"
                }
                // Both spawn a child Tower process (tower_selftest would run this sweep again).
                let skipped: Set<String> = ["tower_selftest", "tower_panelshot"]
                for spec in TowerMCPService.tools where spec.annotations.readOnlyHint && !skipped.contains(spec.name) {
                    add(try? await service.callTool(spec.name, arguments: [:]))
                }
                for nick in ["mclaude", "mcodex", "mcursor", "mopenrouter"] {
                    add(try? await service.callTool("tower_account", arguments: ["account": .string(nick)]))
                }
                add(try? await service.callTool("tower_refresh", arguments: [:]))
                let resources = service.listResources()
                out += "\(resources)\n"
                for r in resources {
                    for c in (try? await service.readResource(r.uri)) ?? [] { out += "\(c)\n" }
                }
                for p in service.listPrompts() {
                    if let got = try? await service.getPrompt(p.name, arguments: [:]) { out += "\(got)\n" }
                }
                return out
            }
        }

        let allOn = everything(off: nil)
        let unseen = markers.values.flatMap { $0 }.filter { !allOn.contains($0) }
        check("sweep: with every provider ON, each provider's marker is visible somewhere",
              unseen.isEmpty, "never seen: \(unseen)")
        for (provider, own) in markers.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let text = everything(off: provider)
            let leaked = own.filter { text.contains($0) }
            check("sweep: with \(provider.rawValue) OFF, no MCP tool, resource or prompt shows its data",
                  leaked.isEmpty, "leaked: \(leaked)")
        }
    }
}
