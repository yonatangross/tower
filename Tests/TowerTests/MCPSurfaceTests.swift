import Foundation
import XCTest
@testable import Tower

/// A whole Tower in a temp directory: five accounts across every provider, a
/// retained seat in a mock Keychain, fixture lanes and sessions, and a private
/// UserDefaults suite. Every read and write tool runs against it, no network, no
/// real Keychain.
struct MCPFixture {
    let dir: URL
    let store: Store
    let keychain = MockSeatKeychain()
    let vault: ClaudeSeatVault
    let defaults: UserDefaults
    let suite: String
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    static let activeEmail = "user-a@example.com"
    static let staleEmail = "user-e@example.com"
    static let retainedEmail = "user-f@example.com"

    /// A shared mutable flag the vault's retention closures read and write.
    final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }
    let retentionFlag = Flag(true)

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tower-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "tower-mcp-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = Store(dir: dir.appendingPathComponent("support"), mirror: dir.appendingPathComponent("claude/quota-cache.json"), now: { Date(timeIntervalSince1970: 2_000_000_000) })
        let flag = retentionFlag
        vault = keychain.vault(in: dir, enabled: { flag.on }, setEnabled: { flag.on = $0 })
        try seed()
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func seed() throws {
        let upcoming5h = now.addingTimeInterval(3 * 3600)
        let upcoming7d = now.addingTimeInterval(5 * 86_400)
        var active = AccountSnapshot(email: Self.activeEmail, nickname: "cal", plan: "max", tier: "default_claude_max_20x")
        active.fiveHourPct = 11
        active.fiveHourResetsAt = upcoming5h
        active.weeklyPct = 8
        active.weeklyResetsAt = upcoming7d
        active.scoped = [ScopedLimit(label: "Fable", percent: 100, resetsAt: upcoming7d)]
        active.capturedAt = now.addingTimeInterval(-60)
        active.notified = [Thresholds.key("7d", upcoming7d): 80]

        var stale = AccountSnapshot(email: Self.staleEmail, nickname: "ben", plan: "max")
        stale.fiveHourPct = 91
        stale.fiveHourResetsAt = upcoming5h
        stale.weeklyPct = 40
        stale.weeklyResetsAt = upcoming7d
        stale.capturedAt = now.addingTimeInterval(-4 * 3600)
        stale.crossing = "red"
        stale.lastError = "needs login"

        var retained = AccountSnapshot(email: Self.retainedEmail, nickname: "fay", plan: "max")
        retained.fiveHourPct = 96
        retained.fiveHourResetsAt = upcoming5h
        retained.weeklyPct = 30
        retained.weeklyResetsAt = upcoming7d
        retained.capturedAt = now.addingTimeInterval(-120)

        var codex = AccountSnapshot(email: "user-c@example.com", nickname: "eve", plan: "pro")
        codex.provider = .codex
        codex.weeklyPct = 70
        codex.weeklyResetsAt = upcoming7d
        codex.capturedAt = now.addingTimeInterval(-30)

        var cursor = AccountSnapshot(email: Self.staleEmail, nickname: "ben", plan: "ultra")
        cursor.provider = .cursor
        cursor.weeklyPct = 80
        cursor.weeklyResetsAt = now.addingTimeInterval(20 * 86_400)
        cursor.scoped = [
            ScopedLimit(label: "Cursor Models", percent: 70, resetsAt: cursor.weeklyResetsAt),
            ScopedLimit(label: "Other Models", percent: 80, resetsAt: cursor.weeklyResetsAt),
        ]
        cursor.capturedAt = now.addingTimeInterval(-30)

        var openRouter = AccountSnapshot(email: OpenRouter.storeEmail, nickname: "openrouter", plan: "balance")
        OpenRouter.apply(OpenRouter.Budget(spent: 17.5, limit: 50), to: &openRouter, now: now.addingTimeInterval(-30))

        let never = AccountSnapshot(email: "user-d@example.com", nickname: "ana", plan: "?")

        let rows = [active, stale, retained, codex, cursor, openRouter, never]
        let map = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        if let error = store.save(map) { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }

        // One retained seat, expiring inside the lead so it is due; the active login
        // stays Claude Code's.
        let seat = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "seat-token", subscriptionType: "max",
            rateLimitTier: nil, expiresAt: now.addingTimeInterval(10 * 60), emailHint: Self.retainedEmail)
        let error = vault.captureVerifiedLogin(seat, email: Self.retainedEmail, observation: vault.beginObservation(), now: now)
        if let error { throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
    }

    func activeCredential() -> ClaudeCredential {
        ClaudeCredential(
            service: Keychain.defaultService, accessToken: "active-token", subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x", expiresAt: now.addingTimeInterval(3600),
            emailHint: Self.activeEmail)
    }

    func lanes() -> [Provider: AgentLane.Outcome] {
        [
            .devin: .ok(AgentLane.Reading(
                provider: .devin, configModel: "claude-opus", lastDispatch: .init(model: "claude-opus", at: now.addingTimeInterval(-3600)),
                lastLimitHit: .init(at: now.addingTimeInterval(-7200), summary: "daily quota exhausted", message: "Your daily usage quota has been exhausted"),
                usage: .quota(.init(plan: "team", dailyRemainingPct: 40, weeklyRemainingPct: 70, dailyResetsAt: now.addingTimeInterval(3600), weeklyResetsAt: nil, fetchedAt: now.addingTimeInterval(-600))))),
            .muse: .ok(AgentLane.Reading(provider: .muse, configModel: nil, lastDispatch: nil, lastLimitHit: nil)),
            .cursor: .unavailable("could not read ~/.cursor/cli-config.json"),
            .agy: .notConfigured,
        ]
    }

    func sessions() -> AgentSummary {
        var s = AgentSummary()
        s.interactive = [
            AgentInfo(kind: "interactive", status: "busy", cwd: "/a/platform"),
            AgentInfo(kind: "interactive", status: "idle", cwd: "/a/platform"),
            AgentInfo(kind: "interactive", status: "idle", cwd: "/a/core"),
        ]
        s.backgroundCount = 2
        return s
    }

    func refreshResult() -> RefreshResult {
        RefreshResult(
            accounts: store.load(), activeEmail: Self.activeEmail, outcome: .ok(email: Self.activeEmail),
            openRouterOutcome: .ok(OpenRouter.Budget(spent: 17.5, limit: 50)), openRouterFoldCommitted: true,
            cursorKey: AccountSnapshot.storeKey(email: Self.staleEmail, provider: .cursor))
    }

    func environment(
        launchAtLogin: Bool = false,
        verifiedActiveEmail: String?? = nil
    ) -> TowerMCPService.Environment {
        // The record the env closure reports is also persisted, bound to the live
        // credential's token, the way a real refresh writes it. An explicit nil
        // stub means Tower never verified: remove any record an earlier env on
        // this shared store seeded, so the surface is genuinely blind.
        if let verified = verifiedActiveEmail ?? Self.activeEmail {
            store.recordVerifiedActiveSeatUnlocked(
                verified, token: activeCredential().accessToken, now: now)
        } else {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent("support/active-seat.json"))
        }
        let flag = Flag(launchAtLogin)
        return TowerMCPService.Environment(
            store: store,
            now: { self.now },
            verifiedActiveEmail: { verifiedActiveEmail ?? Self.activeEmail },
            switchProfiles: { [Self.activeEmail: ChromeProfileHint(displayName: "CAL", chooserEmail: nil),
                               Self.retainedEmail: ChromeProfileHint(displayName: "FAY", chooserEmail: nil),
                               Self.staleEmail: ChromeProfileHint(displayName: "BEN", chooserEmail: Self.staleEmail)] },
            lanes: { self.lanes() },
            sessions: { self.sessions() },
            refresh: { self.refreshResult() },
            activeCredential: { self.activeCredential() },
            vault: vault,
            defaults: defaults,
            launchAtLogin: { flag.on },
            setLaunchAtLogin: { flag.on = $0; return nil },
            openRouterKeyFingerprint: { "9f3c" },
            executable: nil,
            mirrorPath: dir.appendingPathComponent("claude/quota-cache.json"),
            supportDirectory: dir.appendingPathComponent("support"),
            buildVersion: "test")
    }
}

final class MCPSurfaceTests: XCTestCase {
    private var fixture: MCPFixture!
    private var service: TowerMCPService!

    override func setUpWithError() throws {
        fixture = try MCPFixture()
        service = TowerMCPService(env: fixture.environment())
    }

    override func tearDown() {
        fixture.tearDown()
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func call(_ name: String, _ args: JSON = [:]) async throws -> MCPToolResult {
        try await service.callTool(name, arguments: args)
    }

    private func spec(_ name: String) -> MCPToolSpec {
        TowerMCPService.tools.first { $0.name == name }!
    }

    // MARK: Surface enumeration

    /// Every verb main.swift dispatches has a tool, and the map names no verb that
    /// main.swift does not have. Walked from the source so a new verb fails here.
    func testEveryCLIVerbHasATool() throws {
        // The dispatch lives in DemoMode.dispatched (main.swift switches on its result), so
        // the verbs come from DemoMode.Verb; each CLI word must dispatch to its own verb.
        let cliVerbs = DemoMode.Verb.allCases.filter { $0 != .app }
        for verb in cliVerbs {
            XCTAssertEqual(DemoMode.dispatched(args: [verb.rawValue]), verb, "`tower \(verb.rawValue)` does not dispatch to itself")
        }
        XCTAssertEqual(DemoMode.dispatched(args: []), .app)
        let realVerbs = Set(cliVerbs.map(\.rawValue))
        XCTAssertEqual(realVerbs, ["status", "selftest", "rotate", "login-item", "panelshot", "mcp"])
        let toolNames = Set(TowerMCPService.tools.map(\.name))
        for verb in realVerbs {
            let tool = try XCTUnwrap(TowerMCPService.verbToTool[verb], "verb \(verb) has no tool")
            XCTAssertTrue(toolNames.contains(tool), "verb \(verb) maps to unknown tool \(tool)")
        }
        XCTAssertEqual(Set(TowerMCPService.verbToTool.keys), realVerbs)
    }

    /// docs/mcp-surface.md has one row per tool, resource and prompt, and names no
    /// tool the server does not list.
    func testEveryToolResourceAndPromptHasARowInTheSurfaceDoc() throws {
        let doc = try String(contentsOf: Self.repoRoot.appendingPathComponent("docs/mcp-surface.md"), encoding: .utf8)
        for tool in TowerMCPService.tools {
            XCTAssertTrue(doc.contains("| `\(tool.name)` |"), "no row for \(tool.name)")
        }
        let re = try NSRegularExpression(pattern: #"\| `(tower_[a-z_]+)` \|"#)
        let documented = Set(re.matches(in: doc, range: NSRange(doc.startIndex..., in: doc)).compactMap {
            Range($0.range(at: 1), in: doc).map { String(doc[$0]) }
        })
        XCTAssertEqual(documented, Set(TowerMCPService.tools.map(\.name)))
        for prompt in TowerMCPService.prompts {
            XCTAssertTrue(doc.contains("| `\(prompt.name)` |"), "no row for prompt \(prompt.name)")
        }
        for uri in [TowerMCPService.quotaCacheURI, TowerMCPService.configURI, TowerMCPService.surfaceURI, TowerMCPService.accountURIPrefix + "{id}"] {
            XCTAssertTrue(doc.contains("| `\(uri)` |"), "no row for resource \(uri)")
        }
    }

    func testToolSpecsAreWellFormed() {
        let names = TowerMCPService.tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate tool names")
        for tool in TowerMCPService.tools {
            XCTAssertFalse(tool.title.isEmpty, tool.name)
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            XCTAssertEqual(tool.inputSchema["type"], "object", "\(tool.name) input")
            XCTAssertEqual(tool.outputSchema["type"], "object", "\(tool.name) output")
            XCTAssertNotNil(tool.outputSchema["required"].arrayValue, "\(tool.name) output has no required list")
            XCTAssertNotNil(tool.outputSchema["properties"].objectValue, "\(tool.name) output has no properties")
            let json = tool.json
            for key in ["name", "title", "description", "inputSchema", "outputSchema", "annotations"] {
                XCTAssertFalse(json[key].isNull, "\(tool.name).\(key)")
            }
            for hint in ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"] {
                XCTAssertNotNil(json["annotations"][hint].boolValue, "\(tool.name) \(hint)")
            }
        }
    }

    /// The reads say so and the writes say so: annotations are the contract a client
    /// uses to decide whether to ask before calling.
    func testAnnotationsSeparateReadsFromWrites() {
        let writes: Set<String> = ["tower_refresh", "tower_forget_seats", "tower_config_set", "tower_alert_ack"]
        for tool in TowerMCPService.tools {
            if writes.contains(tool.name) {
                XCTAssertFalse(tool.annotations.readOnlyHint, tool.name)
            } else {
                XCTAssertTrue(tool.annotations.readOnlyHint, tool.name)
                XCTAssertFalse(tool.annotations.destructiveHint, tool.name)
                XCTAssertTrue(tool.annotations.idempotentHint, tool.name)
            }
        }
        XCTAssertTrue(spec("tower_forget_seats").annotations.destructiveHint)
        XCTAssertTrue(spec("tower_refresh").annotations.openWorldHint)
        XCTAssertFalse(spec("tower_refresh").annotations.idempotentHint)
        XCTAssertFalse(spec("tower_alert_ack").annotations.destructiveHint)
        XCTAssertTrue(spec("tower_alert_ack").annotations.idempotentHint)
    }

    // MARK: Every read tool's structured output matches its schema

    func testReadToolsValidateAgainstTheirOutputSchemas() async throws {
        let reads: [(String, JSON)] = [
            ("tower_status", [:]), ("tower_accounts", [:]), ("tower_accounts", ["provider": "cursor"]),
            ("tower_account", ["account": "cal"]), ("tower_room", [:]), ("tower_room", ["minimumRoom": 50]),
            ("tower_advice", [:]), ("tower_rotate", [:]), ("tower_resets", [:]), ("tower_alerts", [:]),
            ("tower_freshness", [:]), ("tower_seats", [:]), ("tower_lanes", [:]), ("tower_sessions", [:]),
            ("tower_openrouter_history", [:]), ("tower_config_get", [:]),
        ]
        for (name, args) in reads {
            let result = try await call(name, args)
            XCTAssertFalse(result.isError, "\(name) \(args.text): \(result.content)")
            let structured = try XCTUnwrap(result.structuredContent, name)
            let violations = JSONSchemaCheck.validate(structured, against: spec(name).outputSchema)
            XCTAssertTrue(violations.isEmpty, "\(name): \(violations.map(\.description))")
            XCTAssertFalse(result.content.isEmpty, "\(name) has no text summary")
            // The structured payload must survive the wire byte for byte.
            let roundTrip = try JSON.parse(structured.encoded())
            XCTAssertEqual(roundTrip, structured, name)
        }
    }

    // MARK: Account shaping

    /// The fixture's Devin refusal is two hours old, and the status the CLI fetched ten
    /// minutes ago still shows 40 % left, so the lane is not refused now and says so.
    func testLanesMarkWhetherTheNewestRefusalIsCurrent() async throws {
        let lanes = try await call("tower_lanes", [:]).structuredContent!
        let devin = try XCTUnwrap(lanes["lanes"].arrayValue?.first { $0["provider"] == "devin" })
        XCTAssertEqual(devin["lastLimitHit"]["summary"], "daily quota exhausted")
        XCTAssertEqual(devin["lastLimitHit"]["current"], false)
    }

    func testAccountJSONCarriesTowersDerivations() async throws {
        let live = try await call("tower_account", ["account": "cal"]).structuredContent!
        XCTAssertEqual(live["isActive"], true)
        XCTAssertEqual(live["worstTrust"], "live")
        XCTAssertEqual(live["recommendable"], true)
        XCTAssertEqual(live["roomPct"], 89)
        XCTAssertEqual(live["usedPct"], 11)
        XCTAssertEqual(live["trustedUsedPct"], 11)
        XCTAssertEqual(live["trustedHeadroomPct"], 11, "one-release alias of trustedUsedPct")
        // Fable at 100 binds the presentation but leaves Opus and Sonnet usable.
        XCTAssertEqual(live["binding"]["limit"], "Fable")
        XCTAssertEqual(live["binding"]["usableFor"], "Opus / Sonnet")
        XCTAssertEqual(live["exhaustedScoped"], ["Fable"])
        XCTAssertEqual(live["windows"].arrayValue?.map { $0["name"] }, ["5h", "7d", "Fable"])
        XCTAssertEqual(live["resting"], .null)
        XCTAssertEqual(live["notified"].objectValue?.count, 1)

        let stale = try await call("tower_account", ["account": "ben"]).structuredContent!
        XCTAssertEqual(stale["provider"], "claude", "a bare nickname prefers the Claude row")
        XCTAssertEqual(stale["worstTrust"], "stale")
        XCTAssertEqual(stale["needsLogin"], true)
        XCTAssertEqual(stale["crossing"], "red")
        XCTAssertEqual(stale["resting"]["kind"], "stale")
        XCTAssertEqual(stale["resting"]["timeGated"], false)

        let cursor = try await call("tower_account", ["account": "cursor:ben"]).structuredContent!
        XCTAssertEqual(cursor["provider"], "cursor")
        XCTAssertEqual(cursor["windows"].arrayValue?.map { $0["name"] }, ["Cursor Models", "Other Models"])
        XCTAssertEqual(cursor["binding"]["limit"], "month")

        let codex = try await call("tower_account", ["account": "codex:user-c@example.com"]).structuredContent!
        XCTAssertEqual(codex["windows"].arrayValue?.map { $0["name"] }, ["7d"])

        let money = try await call("tower_account", ["account": "openrouter"]).structuredContent!
        XCTAssertEqual(money["balanceUSD"], 32.5)
        XCTAssertEqual(money["windows"], [])
        XCTAssertEqual(money["resting"], .null)

        let never = try await call("tower_account", ["account": "ana"]).structuredContent!
        XCTAssertEqual(never["resting"]["kind"], "neverCaptured")

        let missing = try await call("tower_account", ["account": "nobody"])
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.structuredContent?["error"]["code"], "UnknownAccount")
    }

    func testRoomRanksLiveFirstAndFiltersByMinimum() async throws {
        let room = try await call("tower_room").structuredContent!
        XCTAssertEqual(room["recommended"], "cal")
        XCTAssertEqual(room["active"].arrayValue?.map { $0["nickname"] }, ["cal", "eve", "ben"])
        XCTAssertEqual(room["resting"].arrayValue?.map { $0["nickname"] }, ["ben", "ana", "fay"])
        XCTAssertEqual(room["resting"][2]["resting"]["kind"], "capped")
        XCTAssertEqual(room["resting"][2]["resting"]["timeGated"], true)
        let strict = try await call("tower_room", ["minimumRoom": 50]).structuredContent!
        XCTAssertEqual(strict["active"].arrayValue?.map { $0["nickname"] }, ["cal"])
        XCTAssertTrue(strict["readySummary"].stringValue!.hasPrefix("3 of 6 ready · next "), strict["readySummary"].text)
    }

    func testAdviceStaysOnTheActiveSeat() async throws {
        let advice = try await call("tower_advice").structuredContent!
        XCTAssertEqual(advice["kind"], "stay")
        XCTAssertEqual(advice["nickname"], "cal")
        XCTAssertEqual(advice["next"], "fay", "the runner up is the capped seat that reopens, in Tower's own words")
        XCTAssertEqual(advice["command"], .null)
    }

    /// Without a Tower-verified active identity the advice must not dress a guess up as
    /// "switch to the best seat": the roomiest seat is named for information, the kind
    /// says the active seat is unknown.
    func testAdviceReportsActiveUnknownWhenIdentityIsUnverified() async throws {
        let blind = TowerMCPService(env: fixture.environment(verifiedActiveEmail: .some(nil)))
        let result = try await blind.callTool("tower_advice", arguments: [:])
        let advice = result.structuredContent!
        guard case .text(let summary)? = result.content.first else { return XCTFail("no summary") }
        XCTAssertTrue(summary.hasPrefix("no verified active seat; most room: cal ("), summary)
        XCTAssertEqual(advice["kind"], "activeUnknown")
        XCTAssertEqual(advice["nickname"], "cal")
        XCTAssertEqual(advice["percentUsed"], .null)
        XCTAssertNotEqual(advice["roomPct"], .null)
        XCTAssertTrue(JSONSchemaCheck.validate(advice, against: spec("tower_advice").outputSchema).isEmpty)
    }

    /// tower_status reports the verified identity, never a ~/.claude.json rumour: nil
    /// verified means null activeEmail even though the credential carries a hint.
    func testStatusReportsNullActiveEmailWhenIdentityIsUnverified() async throws {
        let blind = TowerMCPService(env: fixture.environment(verifiedActiveEmail: .some(nil)))
        let status = try await blind.callTool("tower_status", arguments: [:]).structuredContent!
        XCTAssertEqual(status["activeEmail"], .null)
        XCTAssertEqual(status["activeEmailVerifiedAt"], .null)
        let room = try await blind.callTool("tower_room", arguments: [:]).structuredContent!
        XCTAssertEqual(room["activeEmail"], .null)
        XCTAssertTrue(room["active"].arrayValue!.allSatisfy { $0["isActive"] == false })
    }

    func testAlertsReportAnnouncedPendingAndStanding() async throws {
        let alerts = try await call("tower_alerts").structuredContent!
        XCTAssertEqual(alerts["levels"], [80, 95, 100])
        let byNick = Dictionary(uniqueKeysWithValues: alerts["accounts"].arrayValue!.map { ($0["id"].stringValue!, $0) })
        let active = byNick[MCPFixture.activeEmail]!
        XCTAssertEqual(active["announced"][0]["window"], "7d")
        XCTAssertEqual(active["announced"][0]["level"], 80)
        XCTAssertEqual(active["railMarks"]["5h"], ["amber", "red"])
        XCTAssertEqual(active["railMarks"]["7d"], ["red"])
        // fay sits at 96 on 5h: 80 and 95 both pending, reported as the 95 level.
        let retained = byNick[MCPFixture.retainedEmail]!
        XCTAssertEqual(retained["pending"].arrayValue?.count, 1)
        XCTAssertEqual(retained["pending"][0]["level"], 95)
        XCTAssertEqual(byNick[MCPFixture.staleEmail]!["crossing"], "red")
        // Reporting pending alerts must not consume them.
        let again = try await call("tower_alerts").structuredContent!
        XCTAssertEqual(again["accounts"], alerts["accounts"])
    }

    func testSeatsReportRetentionWithoutTokens() async throws {
        let result = try await call("tower_seats")
        let seats = result.structuredContent!
        XCTAssertEqual(seats["retentionEnabled"], true)
        XCTAssertEqual(seats["active"]["email"], .string(MCPFixture.activeEmail))
        XCTAssertEqual(seats["retained"].arrayValue?.count, 1)
        XCTAssertEqual(seats["retained"][0]["email"], .string(MCPFixture.retainedEmail))
        XCTAssertEqual(seats["retained"][0]["expired"], false)
        XCTAssertTrue(seats["retained"][0]["decision"].isNull, "no renewal decision exists")
        XCTAssertTrue(seats["retained"][0]["hasRefreshToken"].isNull, "no refresh token is held")
        XCTAssertFalse(seats.text.contains("seat-token"))
        XCTAssertFalse(seats.text.contains("seat-refresh"))
        XCTAssertFalse(seats.text.contains("active-token"))
    }

    func testResolveAcceptsEveryReferenceShape() {
        let map = fixture.store.load()
        XCTAssertEqual(TowerMCPService.resolve("cal", in: map)?.email, MCPFixture.activeEmail)
        XCTAssertEqual(TowerMCPService.resolve("CAL", in: map)?.email, MCPFixture.activeEmail)
        XCTAssertEqual(TowerMCPService.resolve(MCPFixture.activeEmail, in: map)?.nickname, "cal")
        XCTAssertEqual(TowerMCPService.resolve("codex:user-c@example.com", in: map)?.kind, .codex)
        XCTAssertEqual(TowerMCPService.resolve("codex:eve", in: map)?.kind, .codex)
        XCTAssertEqual(TowerMCPService.resolve("cursor:ben", in: map)?.kind, .cursor)
        XCTAssertEqual(TowerMCPService.resolve("ben", in: map)?.kind, .claude)
        XCTAssertNil(TowerMCPService.resolve("ghost", in: map))
    }

    // MARK: Resources and prompts

    func testResourcesListReadAndTemplate() async throws {
        let list = service.listResources()
        XCTAssertEqual(list.prefix(3).map(\.uri), [TowerMCPService.quotaCacheURI, TowerMCPService.configURI, TowerMCPService.surfaceURI])
        XCTAssertEqual(list.count, 3 + fixture.store.load().count)
        XCTAssertEqual(service.listResourceTemplates().first?.uriTemplate, "tower://accounts/{id}")

        let cache = try await service.readResource(TowerMCPService.quotaCacheURI)
        let parsed = try JSON.parse(Data(cache[0].text.utf8))
        XCTAssertEqual(parsed.objectValue?.count, fixture.store.load().count, "the mirror carries every row")
        let mirrorBytes = try Data(contentsOf: fixture.dir.appendingPathComponent("claude/quota-cache.json"))
        XCTAssertEqual(cache[0].text, String(decoding: mirrorBytes, as: UTF8.self), "byte identical to the mirror")

        let one = try await service.readResource(TowerMCPService.accountURIPrefix + MCPFixture.activeEmail)
        let oneParsed = try JSON.parse(Data(one[0].text.utf8))
        XCTAssertEqual(oneParsed["nickname"], "cal")

        let surface = try await service.readResource(TowerMCPService.surfaceURI)
        for tool in TowerMCPService.tools { XCTAssertTrue(surface[0].text.contains("`\(tool.name)`")) }

        do {
            _ = try await service.readResource("tower://accounts/nobody")
            XCTFail("unknown account must throw")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, MCPError.resourceNotFound)
        }
    }

    func testPromptsEmbedTheToolsTheyCite() async throws {
        XCTAssertEqual(service.listPrompts().map(\.name), ["pick_account_for_lane", "promote_room_check", "rotation_brief"])
        let pick = try await service.getPrompt("pick_account_for_lane", arguments: ["lane_class": "claude", "minimum_room": "50"])
        XCTAssertEqual(pick.messages.count, 1)
        XCTAssertTrue(pick.messages[0].text.contains("\"recommended\" : \"cal\""))
        XCTAssertTrue(pick.messages[0].text.contains("minimumRoom 50"))
        let promote = try await service.getPrompt("promote_room_check", arguments: [:])
        XCTAssertTrue(promote.messages[0].text.contains("tower_alerts:"))
        XCTAssertTrue(promote.messages[0].text.contains("\"redMark\" : 90"))
        let brief = try await service.getPrompt("rotation_brief", arguments: [:])
        XCTAssertTrue(brief.messages[0].text.contains("MANUAL LOGIN PLAN"))
        do {
            _ = try await service.getPrompt("pick_account_for_lane", arguments: [:])
            XCTFail("lane_class is required")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, MCPError.invalidParams)
        }
        XCTAssertEqual(service.complete(refType: "ref/prompt", refName: "pick_account_for_lane", argument: "lane_class", value: "c"), ["claude", "codex", "cursor"])
        XCTAssertEqual(service.complete(refType: "ref/resource", refName: "tower://accounts/{id}", argument: "id", value: "codex:"), ["codex:user-c@example.com"])
    }

    // MARK: Write preconditions

    /// The public build never renews a token: there is no renew tool to call.
    func testThereIsNoRenewTool() {
        XCTAssertFalse(TowerMCPService.tools.contains { $0.name == "tower_renew" })
    }

    func testAlertAckWritesTheSameBookkeepingEvaluateWould() async throws {
        let unknownAccount = try await call("tower_alert_ack", ["account": "ghost", "window": "5h", "level": 80])
        XCTAssertEqual(unknownAccount.structuredContent?["error"]["code"], "UnknownAccount")
        let badLevel = try await call("tower_alert_ack", ["account": "cal", "window": "5h", "level": 90])
        XCTAssertEqual(badLevel.structuredContent?["error"]["code"], "BadLevel")
        let codexHasNo5h = try await call("tower_alert_ack", ["account": "codex:eve", "window": "5h", "level": 80])
        XCTAssertEqual(codexHasNo5h.structuredContent?["error"]["code"], "UnknownWindow")
        let cursorSaysMonth = try await call("tower_alert_ack", ["account": "cursor:ben", "window": "7d", "level": 80])
        XCTAssertEqual(cursorSaysMonth.structuredContent?["error"]["code"], "UnknownWindow")
        let noReset = try await call("tower_alert_ack", ["account": "ana", "window": "5h", "level": 80])
        XCTAssertEqual(noReset.structuredContent?["error"]["code"], "NoResetTime")

        let ack = try await call("tower_alert_ack", ["account": "fay", "window": "5h", "level": 95])
        XCTAssertFalse(ack.isError, "\(ack.content)")
        XCTAssertEqual(ack.structuredContent?["previous"], 0)
        XCTAssertEqual(ack.structuredContent?["level"], 95)
        let key = ack.structuredContent!["key"].stringValue!
        XCTAssertEqual(fixture.store.load()[MCPFixture.retainedEmail]?.notified[key], 95)
        // The app's evaluate now stays silent for that window, which is the whole point.
        var row = fixture.store.load()[MCPFixture.retainedEmail]!
        XCTAssertTrue(Thresholds.evaluate(&row, now: fixture.now).isEmpty)
        // A lower ack never lowers the recorded level.
        let lower = try await call("tower_alert_ack", ["account": "fay", "window": "5h", "level": 80])
        XCTAssertEqual(lower.structuredContent?["level"], 95)
        XCTAssertEqual(lower.structuredContent?["previous"], 95)
    }

    func testConfigSetHonoursEachKeyAndRefusesTheRest() async throws {
        let unknown = try await call("tower_config_set", ["key": "nope", "value": true])
        XCTAssertEqual(unknown.structuredContent?["error"]["code"], "UnknownKey")
        let bad = try await call("tower_config_set", ["key": "launchAtLogin", "value": "yes"])
        XCTAssertEqual(bad.structuredContent?["error"]["code"], "BadValue")

        let login = try await call("tower_config_set", ["key": "launchAtLogin", "value": true])
        XCTAssertEqual(login.structuredContent?["value"], true)
        XCTAssertEqual(login.structuredContent?["previous"], false)
        let config = try await call("tower_config_get").structuredContent!
        XCTAssertEqual(config["settings"]["launchAtLogin"], true)

        let budget = try await call("tower_config_set", ["key": "openrouter.monthlyBudgetUSD", "value": 25])
        XCTAssertEqual(budget.structuredContent?["value"], 25)
        XCTAssertEqual(fixture.defaults.double(forKey: OpenRouter.budgetKey), 25)
        let negative = try await call("tower_config_set", ["key": "openrouter.monthlyBudgetUSD", "value": -1])
        XCTAssertEqual(negative.structuredContent?["error"]["code"], "BadValue")
        let cleared = try await call("tower_config_set", ["key": "openrouter.monthlyBudgetUSD", "value": .null])
        XCTAssertEqual(cleared.structuredContent?["previous"], 25)
        XCTAssertNil(fixture.defaults.object(forKey: OpenRouter.budgetKey))

        // The Jev balance has no endpoint; a re-entry is dated by the tool, and the
        // status and config reads carry it at once.
        let jev = try await call("tower_config_set", ["key": "typesafe.balanceUSD", "value": 12.5])
        XCTAssertEqual(jev.structuredContent?["value"], 12.5)
        XCTAssertEqual(jev.structuredContent?["previous"], .null, "nothing ships by default")
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let asOf = day.string(from: fixture.now)
        XCTAssertEqual(jev.structuredContent?["asOf"], .string(asOf))
        XCTAssertEqual(TypeSafe.entry(defaults: fixture.defaults), TypeSafe.Entry(usd: 12.5, asOf: asOf))
        let jevConfig = try await call("tower_config_get").structuredContent!
        XCTAssertEqual(jevConfig["typesafe"]["balanceUSD"], 12.5)
        XCTAssertEqual(jevConfig["typesafe"]["stale"], false)
        XCTAssertEqual(jevConfig["typesafe"]["reenter"], .null)
        let jevNegative = try await call("tower_config_set", ["key": "typesafe.balanceUSD", "value": -1])
        XCTAssertEqual(jevNegative.structuredContent?["error"]["code"], "BadValue")
        let jevCleared = try await call("tower_config_set", ["key": "typesafe.balanceUSD", "value": .null])
        XCTAssertEqual(jevCleared.structuredContent?["previous"], 12.5)
        XCTAssertNil(fixture.defaults.object(forKey: TypeSafe.balanceKey))
        XCTAssertNil(fixture.defaults.object(forKey: TypeSafe.balanceAsOfKey))

        // Clef is Cloudflare's decision model (not TypeSafe's): its own key, its own day,
        // reported beside Jev under `models` with its vendor, never written into Jev's keys.
        // cloudflare.clef.balanceUSD is the key; typesafe.clef.balanceUSD stays an alias.
        let clef = try await call("tower_config_set", ["key": "cloudflare.clef.balanceUSD", "value": 8])
        XCTAssertEqual(clef.structuredContent?["value"], 8)
        XCTAssertEqual(clef.structuredContent?["previous"], .null)
        XCTAssertEqual(clef.structuredContent?["asOf"], .string(asOf))
        XCTAssertEqual(TypeSafe.entry(model: .clef, defaults: fixture.defaults), TypeSafe.Entry(usd: 8, asOf: asOf))
        XCTAssertNil(fixture.defaults.object(forKey: TypeSafe.balanceKey))
        let clefConfig = try await call("tower_config_get").structuredContent!
        XCTAssertEqual(clefConfig["typesafe"]["entered"], false)
        XCTAssertEqual(clefConfig["typesafe"]["models"]["clef"]["balanceUSD"], 8)
        XCTAssertEqual(clefConfig["typesafe"]["models"]["clef"]["level"], "amber")
        XCTAssertEqual(clefConfig["typesafe"]["models"]["clef"]["vendor"], "Cloudflare")
        XCTAssertEqual(clefConfig["typesafe"]["models"]["jev"]["vendor"], "TypeSafe")
        let clefStatus = try await call("tower_status").structuredContent!
        XCTAssertEqual(clefStatus["typesafe"]["models"]["clef"]["entered"], true)
        XCTAssertEqual(clefStatus["typesafe"]["models"]["jev"]["entered"], false)
        let clefNegative = try await call("tower_config_set", ["key": "cloudflare.clef.balanceUSD", "value": -1])
        XCTAssertEqual(clefNegative.structuredContent?["error"]["code"], "BadValue")
        let clefCleared = try await call("tower_config_set", ["key": "typesafe.clef.balanceUSD", "value": .null])
        XCTAssertEqual(clefCleared.structuredContent?["previous"], 8)
        XCTAssertNil(fixture.defaults.object(forKey: TypeSafe.Model.clef.balanceKey))
        XCTAssertNil(fixture.defaults.object(forKey: TypeSafe.Model.clef.balanceAsOfKey))

        let retired = try await call("tower_config_set", ["key": "retiredAccounts", "value": ["old@example.com"]])
        XCTAssertEqual(retired.structuredContent?["value"], ["old@example.com"])
        XCTAssertEqual(fixture.store.retiredEmails, ["old@example.com"])
        // A retired address never re-enters the roster through the known list.
        let known = try await call("tower_config_set", ["key": "knownAccounts", "value": ["new@example.com", "old@example.com"]])
        XCTAssertEqual(known.structuredContent?["value"], ["new@example.com"])
        XCTAssertEqual(service.knownAccounts(), ["new@example.com"])
        let notEmail = try await call("tower_config_set", ["key": "knownAccounts", "value": ["nope"]])
        XCTAssertEqual(notEmail.structuredContent?["error"]["code"], "BadValue")
    }

    func testRetentionOffDeletesEveryOwnedSeatFirst() async throws {
        XCTAssertEqual(fixture.keychain.ownedItemCount, 1)
        let off = try await call("tower_config_set", ["key": "retainClaudeSeats", "value": false])
        XCTAssertFalse(off.isError, "\(off.content)")
        XCTAssertEqual(off.structuredContent?["value"], false)
        XCTAssertEqual(fixture.keychain.ownedItemCount, 0)
        XCTAssertFalse(fixture.retentionFlag.on)
        let on = try await call("tower_config_set", ["key": "retainClaudeSeats", "value": true])
        XCTAssertEqual(on.structuredContent?["value"], true)
        XCTAssertTrue(fixture.retentionFlag.on)

        // A Keychain failure leaves the switch on, the panel's rule.
        try seedRetainedSeat()
        fixture.keychain.removeError = "Keychain remove failed (-25293)"
        let stuck = try await call("tower_config_set", ["key": "retainClaudeSeats", "value": false])
        XCTAssertEqual(stuck.structuredContent?["error"]["code"], "KeychainRefused")
        XCTAssertTrue(fixture.retentionFlag.on)
        fixture.keychain.removeError = nil
    }

    private func seedRetainedSeat() throws {
        let seat = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "seat-token-4", subscriptionType: "max",
            rateLimitTier: nil, expiresAt: fixture.now.addingTimeInterval(600), emailHint: MCPFixture.retainedEmail)
        if let error = fixture.vault.captureVerifiedLogin(seat, email: MCPFixture.retainedEmail, observation: fixture.vault.beginObservation(), now: fixture.now) {
            throw NSError(domain: "fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    func testForgetSeatsRemovesOwnedItemsAndKeepsRetentionOn() async throws {
        XCTAssertEqual(fixture.keychain.ownedItemCount, 1)
        let forget = try await call("tower_forget_seats")
        XCTAssertEqual(forget.structuredContent?["forgotten"], true)
        XCTAssertEqual(fixture.keychain.ownedItemCount, 0)
        XCTAssertTrue(fixture.retentionFlag.on)
        try seedRetainedSeat()
        fixture.keychain.removeError = "Keychain remove failed (-25308)"
        let refused = try await call("tower_forget_seats")
        XCTAssertEqual(refused.structuredContent?["error"]["code"], "KeychainRefused")
    }

    func testRefreshRefusesAnUnpollableSeatAndReportsTheCycle() async throws {
        let unknown = try await call("tower_refresh", ["account": "ghost"])
        XCTAssertEqual(unknown.structuredContent?["error"]["code"], "UnknownAccount")
        // ben is stale, not the active login, and Tower holds no seat item for it.
        let unpollable = try await call("tower_refresh", ["account": "ben"])
        XCTAssertEqual(unpollable.structuredContent?["error"]["code"], "NotPollable")

        let all = try await call("tower_refresh")
        XCTAssertFalse(all.isError)
        let payload = all.structuredContent!
        XCTAssertTrue(JSONSchemaCheck.validate(payload, against: spec("tower_refresh").outputSchema).isEmpty,
                      "\(JSONSchemaCheck.validate(payload, against: spec("tower_refresh").outputSchema))")
        XCTAssertEqual(payload["outcome"], "ok")
        XCTAssertEqual(payload["openRouter"], "ok")
        XCTAssertEqual(payload["accounts"].arrayValue?.count, fixture.store.load().count)
        // fay at 96 on 5h would announce 95, ben 91 on 5h and Cursor at 80 would announce
        // 80; the app keeps every one of those announcements.
        XCTAssertEqual(payload["pendingAlerts"].arrayValue?.count, 3)
        XCTAssertTrue(payload["pendingAlerts"].arrayValue!.contains { $0["nickname"] == "fay" && $0["window"] == "5h" })
        XCTAssertEqual(fixture.store.load()[MCPFixture.retainedEmail]?.notified.count, 0, "refresh must not consume the bookkeeping")

        let retainedOnly = try await call("tower_refresh", ["account": "fay"])
        XCTAssertFalse(retainedOnly.isError, "a readable retained seat is pollable")
        XCTAssertEqual(retainedOnly.structuredContent?["accounts"].arrayValue?.map { $0["nickname"] }, ["fay"])
        let activeOnly = try await call("tower_refresh", ["account": "cal"])
        XCTAssertFalse(activeOnly.isError)
        let cursorRow = try await call("tower_refresh", ["account": "cursor:ben"])
        XCTAssertFalse(cursorRow.isError, "non Claude rows always refresh in a cycle")
    }
}
