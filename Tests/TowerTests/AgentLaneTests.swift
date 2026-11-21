import XCTest
import Foundation
@testable import Tower

/// Fixtures follow the exact text shapes devin 3000.10.27, muse 1.3.0, agy 1.2.4 and a dispatcher's
/// dispatch ledger write. Identifiers (trace ids, repos, branches, lane ids, build paths) are
/// invented; the fields the parsers read keep their real format.
final class AgentLaneTests: XCTestCase {
    // MARK: Fixtures

    /// ~/.config/devin/config.json, reduced to the keys that carry no secret.
    static let devinConfig = """
    {"version":1,"theme_mode":"dark","shell":{"setup_complete":true},
     "agent":{"model":"swe-2-high","preferred_family_models":{"swe-2":"swe-2-high"}}}
    """

    /// ~/.config/muse/settings.json without the mcpServers block (it holds auth headers).
    static let museSettings = """
    {"schema_version":1,"provider":"meta","model":"muse-spark-1.3-contributor","reasoning_effort":"medium"}
    """

    /// ~/.local/share/devin/cli/logs/devin_*.log. Two refusals and two ordinary lines.
    static let devinLog = """
    2026-09-15T14:43:07.856767Z  WARN agent_ext::title: Title generation failed: QuotaExhausted(message=Your daily usage quota has been exhausted. Visit https://app.devin.ai/settings/usage to purchase on-demand usage or turn on auto-reload. (trace ID: 0a0a0a0a1891d331b83f240f6da6ec57))
    2026-09-15T14:56:58.055039Z  INFO chisel: elapsed_since_main_ms=6 logging initialized
    2026-09-15T18:19:43.627602Z  WARN agent_ext::title: Title generation failed: QuotaExhausted(message=Your daily usage quota has been exhausted. Visit https://app.devin.ai/settings/usage to purchase on-demand usage or turn on auto-reload. (trace ID: 0b0b0b0ba0763d32ec07a599d0dbfbbd))
    2026-09-15T14:56:58.055122Z  INFO init_cli: chisel: version=3000.10.27 commit=bcbe88c7 os=macos arch=aarch64 binary=devin startup
    """

    /// An older refusal from a different day, for newest-across-files assertions.
    static let devinOlderRefusal = "2026-09-14T10:00:00.000000Z  WARN agent_ext::title: Title generation failed: QuotaExhausted(message=Your daily usage quota has been exhausted. Visit https://app.devin.ai/settings/usage to purchase on-demand usage or turn on auto-reload. (trace ID: 44443333222211114444333322221111))"

    static let museSuccess = #"2026-09-16T07:01:10.097797Z INFO tbh.local.provider src/crates/plugins/meta-model-provider/src/meta/provider/status_summaries/local_tracing.rs:49 event="provider_stream.terminal" provider="meta" terminal="success" reason="completed" attempt=1 max_attempts=10 has_http_status=false http_status=0 request_id_state="present" request_id="26408a93-d17d-4506-a498-e8f6bd3acdc0" trace_id_state="absent" trace_id="" bytes_read=7288 wire_events_seen=10 has_time_to_first_event=true time_to_first_event_ms=0 eof=false eof_buffer_len=0"#

    static let museRateLimited = #"2026-09-16T07:01:17.807381Z INFO tbh.local.provider src/crates/plugins/meta-model-provider/src/meta/provider/status_summaries/local_tracing.rs:49 event="provider_stream.terminal" provider="meta" terminal="failed" reason="rate_limited" attempt=1 max_attempts=10 has_http_status=true http_status=429 request_id_state="present" request_id="e06577a2-5ffe-4b7e-ac40-6616a88b1c25" trace_id_state="absent" trace_id="" bytes_read=0 wire_events_seen=0 has_time_to_first_event=false time_to_first_event_ms=0 eof=false eof_buffer_len=0"#

    static let museCancelled = #"2026-09-09T18:10:26.647980Z INFO tbh.local.provider src/crates/model/src/meta/provider/status_summaries/local_tracing.rs:49 event="provider_stream.terminal" provider="meta" terminal="cancelled" reason="cancelled" attempt=1 max_attempts=10 has_http_status=false http_status=0 request_id_state="present" request_id="b170c0f7-d4b5-406e-bf49-3aedda5c061a" trace_id_state="absent" trace_id="" bytes_read=87719 wire_events_seen=3 has_time_to_first_event=true time_to_first_event_ms=3 eof=false eof_buffer_len=0"#

    static let museOtherEvent = #"2026-09-16T06:55:27.644294Z INFO tbh.local.security src/crates/config/src/trust/diagnostic.rs:16 event="trust.resolve" outcome="trusted" source="run_flag" duration_ms=0"#

    /// dispatch-worktrees.jsonl rows with repo_path, worktree, pane and workspace
    /// dropped. One torn line is appended the way an interrupted writer leaves it.
    static let ledger = """
    {"repo": "example-repo", "branch": "dsp/10001-task-1", "agent": "task-24", "kind": "muse", "model": "muse-spark-1.3", "created_at": 1789541736.861883}
    {"repo": "example-repo", "branch": "dsp/10002-task-2", "agent": "task-11", "kind": "muse", "model": "muse-spark-1.3", "created_at": 1789540023.106627}
    {"repo": "demo-app", "branch": "dsp/10003-task-3", "agent": "task-52", "kind": "gemini", "model": "gemini-3.8-flash-medium", "created_at": 1789545272.941458}
    {"repo": "demo-app", "branch": "dsp/10004-task-4", "agent": "task-98", "kind": "gemini", "model": "gemini-3.8-flash-medium", "created_at": 1789544018.409413}
    {"repo": "demo-app", "branch": "dsp/10005-task-5", "agent": "task-34", "kind": "pi", "model": "z-ai/glm-5.3-flash", "max_tokens": 65536, "thinking": "", "created_at": 1789545745.089964}
    {"repo": "demo-app", "branch": "dsp/10006-task-6
    """

    /// lanes.jsonl rows in the shape written on 2026-09-17. This is where the conveyor
    /// writes dispatches it opens as lanes (all of today's devin ones, for a start), so
    /// dispatch-worktrees.jsonl never sees them. One torn line ends the file.
    static let lanesLedger = """
    {"lane": "00000001-0000-4000-8000-000000000001", "branch": "lane-00000001-10001", "kind": "devin", "model": "swe-2-high", "opened_at": "2026-09-17T14:02:01Z", "closed_at": "2026-09-17T14:47:03Z"}
    {"lane": "00000002-0000-4000-8000-000000000002", "branch": "lane-00000002-10002", "kind": "devin", "model": "swe-2-high", "opened_at": "2026-09-17T20:51:28Z"}
    {"lane": "00000003-0000-4000-8000-000000000003", "branch": "lane-00000003-10003", "kind": "muse", "model": "", "opened_at": "2026-09-16T09:12:44Z"}
    {"lane": "00000004-0000-4000-8000-000000000004", "branch": "lane-00000004-10004", "kind": "cursor", "model": "", "opened_at": "2026-09-17T22:20:15Z", "closed_at": "2026-09-17T23:01:40Z"}
    {"lane": "00000005-0000-4000-80
    """

    /// ~/.cursor/cli-config.json, reduced to the keys that carry no secret.
    static let cursorConfig = """
    {"model": {"modelId": "default", "displayModelId": "auto", "displayName": "Auto", "displayNameShort": "Auto"}}
    """

    // MARK: Devin usage cache

    static let dailyReset: TimeInterval = 1789801200
    static let weeklyReset: TimeInterval = 1790200800
    static let statusFetched: TimeInterval = 1789776000

    /// A varint encoder for building the wire fixture. The point of the fixture is that
    /// the parser reads REAL protobuf bytes, not a shortcut the test and parser share.
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v > 0 { b |= 0x80 }
            out.append(b)
        } while v > 0
        return out
    }

    static func protoVarint(_ n: Int, _ v: UInt64) -> [UInt8] {
        varint(UInt64(n << 3)) + varint(v)
    }

    static func protoBytes(_ n: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    /// A user_status.<hash>.bin as devin 3000.10.31 writes it: JSON envelope around a
    /// base64 GetUserStatusResponse. plan_status (field 13) carries plan info (1.2 the
    /// plan name), daily remaining percent (14), weekly (15), and the two resets (17/18).
    static func devinStatusJSON(daily: UInt64? = 100, weekly: UInt64? = 50,
                                plan: String? = "Pro") -> Data {
        var status: [UInt8] = []
        if let plan {
            status += protoBytes(1, protoBytes(2, Array(plan.utf8)))
        }
        if let daily { status += protoVarint(14, daily) }
        if let weekly { status += protoVarint(15, weekly) }
        status += protoVarint(17, UInt64(dailyReset))
        status += protoVarint(18, UInt64(weeklyReset))
        let response = protoBytes(13, status)
        let json = """
        {"version":1,"fetched_at_secs":\(statusFetched),\
        "payload":"\(Data(response).base64EncodedString())"}
        """
        return Data(json.utf8)
    }

    // MARK: Provider

    func testLanesAreNeverRankedAndHaveNoFiveHourWindow() {
        for lane in AgentLane.lanes where lane != .cursor {
            XCTAssertFalse(lane.isRankable, "\(lane) has no usage reading to rank on")
            XCTAssertFalse(lane.hasFiveHourWindow)
        }
        XCTAssertEqual(Provider.agy.label, "Antigravity")
        XCTAssertEqual(Provider.devin.primaryWindowLabel, "day")
        // cursor is both a lane (its CLI dispatches as kind "cursor") and a quota
        // provider (the IDE subscription row), so the blanket lane assertion above
        // skips exactly it.
        XCTAssertTrue(Provider.cursor.isRankable)
        XCTAssertFalse(Provider.openrouter.isRankable)
    }

    // MARK: Config model

    func testDevinConfigNamesItsModel() throws {
        XCTAssertEqual(try AgentLane.configModel(.devin, data: Data(Self.devinConfig.utf8)),
                       "swe-2-high")
    }

    func testMuseSettingsNameItsModel() throws {
        XCTAssertEqual(try AgentLane.configModel(.muse, data: Data(Self.museSettings.utf8)),
                       "muse-spark-1.3-contributor")
    }

    func testConfigWithoutModelIsNilNotAnError() throws {
        XCTAssertNil(try AgentLane.configModel(.devin, data: Data(#"{"version":1}"#.utf8)))
    }

    func testConfigThatIsNotJSONThrows() {
        XCTAssertThrowsError(try AgentLane.configModel(.muse, data: Data("model = x".utf8)))
    }

    // MARK: Ledger

    func testLedgerKeepsNewestDispatchPerKindAndSkipsTornLine() {
        let newest = AgentLane.newestDispatches(ledger: Self.ledger)
        XCTAssertEqual(newest["muse"],
                       .init(model: "muse-spark-1.3",
                             at: Date(timeIntervalSince1970: 1789541736.861883)))
        XCTAssertEqual(newest["gemini"]?.at, Date(timeIntervalSince1970: 1789545272.941458))
        XCTAssertEqual(newest["pi"]?.model, "z-ai/glm-5.3-flash")
        XCTAssertNil(newest["devin"], "the worktree ledger has never seen a devin lane")
        XCTAssertEqual(AgentLane.ledgerKind(.agy), "gemini")
        XCTAssertEqual(AgentLane.ledgerKind(.muse), "muse")
        XCTAssertEqual(AgentLane.ledgerKind(.cursor), "cursor")
    }

    /// The missing half of dispatch attribution: conveyor-opened lanes live in
    /// lanes.jsonl with ISO `opened_at`, and devin lanes land only there.
    func testLanesLedgerKeepsNewestPerKindAndSkipsTornLine() {
        let newest = AgentLane.newestLaneEntries(ledger: Self.lanesLedger)
        XCTAssertEqual(newest["devin"]?.at, DateParse.parse("2026-09-17T20:51:28Z"))
        XCTAssertEqual(newest["devin"]?.model, "swe-2-high")
        XCTAssertEqual(newest["cursor"]?.at, DateParse.parse("2026-09-17T22:20:15Z"),
                       "a closed lane is still a dispatch that happened")
        XCTAssertNil(newest["cursor"]?.model, "an empty model field is no pin")
        XCTAssertEqual(newest["muse"]?.at, DateParse.parse("2026-09-16T09:12:44Z"))
        XCTAssertNil(newest["gemini"])
    }

    /// End to end: a home whose worktree ledger is empty for devin but whose lanes
    /// ledger has today's lanes must still report a dispatch. Before the merge this
    /// read as "no dispatch recorded" while seven devin lanes were running.
    func testDevinDispatchIsReadFromTheLanesLedger() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/devin", in: home, executable: true)
        try write(Self.ledger,
                  "ledgers/dispatch-worktrees.jsonl",
                  in: home)
        try write(Self.lanesLedger,
                  "ledgers/lanes.jsonl", in: home)

        guard case .ok(let devin) = AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("devin should read")
        }
        XCTAssertEqual(devin.lastDispatch?.at, DateParse.parse("2026-09-17T20:51:28Z"))
        XCTAssertEqual(devin.modelPin, "swe-2-high")
    }

    /// A cursor lane reads its model pin from cli-config.json and its dispatch from
    /// whichever ledger saw it last.
    func testCursorLaneReadsConfigModelAndLanesLedgerDispatch() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/cursor", in: home, executable: true)
        try write(Self.cursorConfig, ".cursor/cli-config.json", in: home)
        try write(Self.lanesLedger,
                  "ledgers/lanes.jsonl", in: home)

        guard case .ok(let cursor) = AgentLane.read(.cursor, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("cursor should read")
        }
        XCTAssertEqual(cursor.configModel, "auto")
        XCTAssertEqual(cursor.lastDispatch?.at, DateParse.parse("2026-09-17T22:20:15Z"))
        guard case .notReadable(let why) = cursor.usage else {
            return XCTFail("cursor-agent quota is not on disk, the lane must say so")
        }
        XCTAssertTrue(why.contains("Cursor row"), "the reason points at where the number lives")
    }

    /// When both ledgers know a kind, the newest timestamp wins regardless of which
    /// file carried it.
    func testNewestOfBothLedgersWins() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/muse", in: home, executable: true)
        try write(Self.ledger,
                  "ledgers/dispatch-worktrees.jsonl",
                  in: home)
        try write(Self.lanesLedger,
                  "ledgers/lanes.jsonl", in: home)

        guard case .ok(let muse) = AgentLane.read(.muse, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("muse should read")
        }
        // The worktree ledger's muse row (created_at 1789541736 = 2026-09-15) is newer
        // than the lanes ledger's muse row (2026-09-16T09:12:44Z is OLDER in wall clock
        // terms only if the epochs disagree; assert the max wins either way).
        XCTAssertEqual(muse.lastDispatch?.at,
                       max(Date(timeIntervalSince1970: 1789541736.861883),
                           DateParse.parse("2026-09-16T09:12:44Z")!))
    }

    // MARK: Devin usage cache

    /// The parser reads real wire bytes all the way down: plan name, both remaining
    /// percents, both resets, and the envelope's own fetch stamp.
    func testDevinUserStatusReadsPlanQuotaAndResets() throws {
        let q = try XCTUnwrap(AgentLane.devinUserStatus(data: Self.devinStatusJSON()))
        XCTAssertEqual(q.plan, "Pro")
        XCTAssertEqual(q.dailyRemainingPct, 100)
        XCTAssertEqual(q.weeklyRemainingPct, 50)
        XCTAssertEqual(q.dailyResetsAt, Date(timeIntervalSince1970: Self.dailyReset))
        XCTAssertEqual(q.weeklyResetsAt, Date(timeIntervalSince1970: Self.weeklyReset))
        XCTAssertEqual(q.fetchedAt, Date(timeIntervalSince1970: Self.statusFetched))
        XCTAssertEqual(q.bindingRemainingPct, 50, "the weekly window is the tighter one")
    }

    func testDevinUserStatusRejectsGarbage() {
        XCTAssertNil(AgentLane.devinUserStatus(data: Data("not json".utf8)))
        XCTAssertNil(AgentLane.devinUserStatus(data: Data(#"{"payload":"!!!"}"#.utf8)))
        // A valid envelope whose payload names no quota is nothing, not a zero.
        XCTAssertNil(AgentLane.devinUserStatus(
            data: Self.devinStatusJSON(daily: nil, weekly: nil)))
    }

    /// A percent above 100 means the schema moved. The field is dropped rather than
    /// rendered, and the surviving window still reads.
    func testDevinUserStatusDropsImpossiblePercents() throws {
        let q = try XCTUnwrap(AgentLane.devinUserStatus(
            data: Self.devinStatusJSON(daily: 250, weekly: 50)))
        XCTAssertNil(q.dailyRemainingPct)
        XCTAssertEqual(q.weeklyRemainingPct, 50)
    }

    /// End to end: the lane reads the newest user_status cache and reports the seat's
    /// own numbers, plan and resets included.
    func testDevinLaneReadsItsCachedQuota() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/devin", in: home, executable: true)
        try write(String(data: Self.devinStatusJSON(), encoding: .utf8)!,
                  ".cache/devin/cli/user_status.aaaaaaaa.bin", in: home)

        guard case .ok(let devin) = AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("devin should read")
        }
        guard case .quota(let q) = devin.usage else {
            return XCTFail("a fresh user status cache must read as quota, got \(devin.usage)")
        }
        XCTAssertEqual(q.weeklyRemainingPct, 50)
        XCTAssertEqual(AgentLane.headerDetail(devin), "Pro · 50% left")
        let daily = CLI.clock(Date(timeIntervalSince1970: Self.dailyReset))
        let weekly = CLI.clock(Date(timeIntervalSince1970: Self.weeklyReset))
        XCTAssertEqual(AgentLane.usageLine(devin),
                       "daily 100% left, resets \(daily) · weekly 50% left, resets \(weekly)")
    }

    func testDevinLaneWithoutStatusCacheIsNotReadable() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/devin", in: home, executable: true)
        guard case .ok(let devin) = AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("devin should read")
        }
        XCTAssertEqual(devin.usage, .notReadable("no user status cache on disk"))
        XCTAssertEqual(AgentLane.headerDetail(devin), "usage not readable")
        XCTAssertEqual(AgentLane.usageLine(devin), "not readable: no user status cache on disk")
    }

    /// A cache the CLI fetched hours ago is labelled with its age rather than posed
    /// as live.
    func testStaleStatusEarnsAnAgeLine() throws {
        let reading = AgentLane.Reading(
            provider: .devin, configModel: nil, lastDispatch: nil, lastLimitHit: nil,
            usage: .quota(AgentLane.Quota(
                plan: "Pro", dailyRemainingPct: 100, weeklyRemainingPct: 50,
                dailyResetsAt: nil, weeklyResetsAt: nil,
                fetchedAt: Date(timeIntervalSince1970: Self.statusFetched))))
        let now = Date(timeIntervalSince1970: Self.statusFetched + 3 * 3600)
        XCTAssertEqual(AgentLane.usageAgeLine(reading, now: now), "status fetched 3h ago")
        let fresh = Date(timeIntervalSince1970: Self.statusFetched + 10 * 60)
        XCTAssertNil(AgentLane.usageAgeLine(reading, now: fresh))
    }

    // MARK: Devin log

    func testDevinNewestQuotaRefusalIsTheLastOneInTheFile() throws {
        let hit = try XCTUnwrap(AgentLane.devinQuotaExhaustion(log: Self.devinLog))
        XCTAssertEqual(hit.at, DateParse.parse("2026-09-15T18:19:43.627602Z"))
        XCTAssertEqual(hit.summary, "daily quota exhausted")
        XCTAssertTrue(hit.message.hasPrefix("Your daily usage quota has been exhausted."))
        XCTAssertFalse(hit.message.contains("trace ID"), "the trace id is not for the panel")
    }

    func testDevinLogWithoutRefusalHasNoHit() {
        let clean = Self.devinLog.split(separator: "\n")
            .filter { !$0.contains("QuotaExhausted") }.joined(separator: "\n")
        XCTAssertNil(AgentLane.devinQuotaExhaustion(log: clean))
    }

    // MARK: Muse log

    func testMuseNewestTerminalRateLimitedIsAHit() throws {
        let log = [Self.museOtherEvent, Self.museSuccess, Self.museRateLimited]
            .joined(separator: "\n")
        let state = try XCTUnwrap(AgentLane.museRateLimit(log: log), "log has terminal events")
        let hit = try XCTUnwrap(state)
        XCTAssertEqual(hit.at, DateParse.parse("2026-09-16T07:01:17.807381Z"))
        XCTAssertEqual(hit.summary, "rate limited (HTTP 429)")
    }

    func testMuseStreamThatSucceededAfterA429IsNotLimited() throws {
        let log = [Self.museRateLimited, Self.museSuccess, Self.museOtherEvent]
            .joined(separator: "\n")
        let state = try XCTUnwrap(AgentLane.museRateLimit(log: log))
        XCTAssertNil(state, "a 429 a later stream got past is history, not the present")
    }

    func testMuseCancelledStreamIsNotALimit() throws {
        let state = try XCTUnwrap(AgentLane.museRateLimit(log: Self.museCancelled))
        XCTAssertNil(state, "an operator interrupt is not a quota refusal")
    }

    func testMuseLogWithNoTerminalEventDefersToAnOlderFile() {
        XCTAssertNil(AgentLane.museRateLimit(log: Self.museOtherEvent))
    }

    func testFieldReadsQuotedAndBareValues() {
        let line = Substring(Self.museRateLimited)
        XCTAssertEqual(AgentLane.field("reason", in: line), "rate_limited")
        XCTAssertEqual(AgentLane.field("http_status", in: line), "429")
        // `has_http_status` must not satisfy a lookup for `http_status`.
        XCTAssertEqual(AgentLane.field("has_http_status", in: line), "true")
    }

    // MARK: Panel text

    func testPanelLinesNeverInventAPercentage() {
        let now = Date(timeIntervalSince1970: 1789545272.941458 + 2 * 3600)
        let dispatched = AgentLane.Reading(
            provider: .agy, configModel: nil,
            lastDispatch: .init(model: "gemini-3.8-flash-medium",
                                at: Date(timeIntervalSince1970: 1789545272.941458)),
            lastLimitHit: nil)
        XCTAssertEqual(AgentLane.modelLine(dispatched), "model gemini-3.8-flash-medium")
        XCTAssertEqual(AgentLane.dispatchLine(dispatched, now: now), "last dispatch 2h ago")

        let neverDispatched = AgentLane.Reading(
            provider: .devin, configModel: "swe-2-high", lastDispatch: nil, lastLimitHit: nil)
        XCTAssertEqual(AgentLane.modelLine(neverDispatched), "model swe-2-high")
        XCTAssertEqual(AgentLane.dispatchLine(neverDispatched, now: now),
                       "no dispatch recorded")

        let bare = AgentLane.Reading(provider: .agy, configModel: nil,
                                     lastDispatch: nil, lastLimitHit: nil)
        XCTAssertEqual(AgentLane.modelLine(bare), "no model pinned")

        let hit = AgentLane.LimitHit(at: now.addingTimeInterval(-5 * 3600),
                                     summary: "daily quota exhausted", message: "")
        XCTAssertEqual(AgentLane.limitLine(hit, now: now), "daily quota exhausted 5h ago")

        for line in [AgentLane.headerDetail, AgentLane.modelLine(dispatched),
                     AgentLane.dispatchLine(dispatched, now: now),
                     AgentLane.limitLine(hit, now: now)] {
            XCTAssertFalse(line.contains("%"), "no lane line may carry a percent: \(line)")
        }
        XCTAssertEqual(AgentLane.headerDetail, "usage not exposed")
    }

    func testDispatchPinWinsOverConfigDefault() {
        let r = AgentLane.Reading(
            provider: .muse, configModel: "muse-spark-1.3-contributor",
            lastDispatch: .init(model: "muse-spark-1.3", at: Date()), lastLimitHit: nil)
        XCTAssertEqual(r.modelPin, "muse-spark-1.3")
    }

    // MARK: Reading a home directory

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func write(_ text: String, _ rel: String, in home: URL, executable: Bool = false) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func testUninstalledLaneHides() throws {
        let home = try makeHome()
        XCTAssertEqual(AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)), .notConfigured)
        XCTAssertEqual(AgentLane.readAll(home: home, env: [:]).count, 5)
        XCTAssertEqual(AgentLane.readAll(home: home, env: [:])[.pi], .notConfigured)
    }

    func testFullHomeReadsEveryObservableSignal() throws {
        let home = try makeHome()
        for lane in AgentLane.lanes {
            try write("#!/bin/sh\n", ".local/bin/\(lane.rawValue)", in: home, executable: true)
        }
        try write(Self.devinConfig, ".config/devin/config.json", in: home)
        try write(Self.museSettings, ".config/muse/settings.json", in: home)
        try write(Self.ledger, "ledgers/dispatch-worktrees.jsonl",
                  in: home)
        try write(Self.devinLog, ".local/share/devin/cli/logs/devin_20260915-211423_17388.log",
                  in: home)
        try write([Self.museSuccess, Self.museRateLimited].joined(separator: "\n"),
                  ".local/share/muse/local-tracing/bootstrap/cli-7f127d7a.log", in: home)

        guard case .ok(let devin) = AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("devin should read")
        }
        XCTAssertEqual(devin.modelPin, "swe-2-high")
        XCTAssertNil(devin.lastDispatch)
        XCTAssertEqual(devin.lastLimitHit?.summary, "daily quota exhausted")

        guard case .ok(let muse) = AgentLane.read(.muse, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("muse should read")
        }
        XCTAssertEqual(muse.configModel, "muse-spark-1.3-contributor")
        XCTAssertEqual(muse.modelPin, "muse-spark-1.3")
        XCTAssertEqual(muse.lastLimitHit?.summary, "rate limited (HTTP 429)")

        guard case .ok(let agy) = AgentLane.read(.agy, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("agy should read")
        }
        XCTAssertEqual(agy.modelPin, "gemini-3.8-flash-medium")
        XCTAssertNil(agy.lastLimitHit, "agy writes no quota value anywhere on disk")
    }

    /// The fixtures' ledgers live in `<home>/ledgers`, named the way a user names them.
    static func ledgerEnv(_ home: URL) -> [String: String] {
        ["TOWER_DISPATCH_LEDGER_DIR": home.appendingPathComponent("ledgers").path]
    }

    /// The dispatch ledger is an optional integration: with no directory named, Tower reads
    /// none, even when a dispatcher's state happens to sit at some well-known path.
    func testNoLedgerDirectoryMeansNoDispatchAndNoGuessedPath() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/agy", in: home, executable: true)
        try write(Self.ledger, ".config/herdr/plugins/some-plugin/.state/dispatch-worktrees.jsonl", in: home)
        let suite = "tower-ledger-\(UUID().uuidString)"
        let empty = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { empty.removePersistentDomain(forName: suite) }
        XCTAssertNil(AgentLane.dispatchLedgerDirectory(home: home, env: [:], defaults: empty))
        guard case .ok(let agy) = AgentLane.read(.agy, home: home, env: [:]) else {
            return XCTFail("agy should read")
        }
        XCTAssertNil(agy.lastDispatch)
    }

    func testLedgerDirectoryPrecedence() throws {
        let home = try makeHome()
        let suite = "tower-ledger-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/from/setting", forKey: AgentLane.dispatchLedgerDirectoryKey)
        XCTAssertEqual(AgentLane.dispatchLedgerDirectory(home: home, env: [:], defaults: defaults)?.path,
                       "/from/setting")
        XCTAssertEqual(AgentLane.dispatchLedgerDirectory(
            home: home, env: ["HERDR_PLUGIN_STATE_DIR": "/from/herdr"], defaults: defaults)?.path,
            "/from/herdr")
        XCTAssertEqual(AgentLane.dispatchLedgerDirectory(
            home: home, env: ["HERDR_PLUGIN_STATE_DIR": "/from/herdr", "TOWER_DISPATCH_LEDGER_DIR": "/from/tower"],
            defaults: defaults)?.path, "/from/tower")
    }

    func testHerdrStateDirOverrideIsHonoured() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/agy", in: home, executable: true)
        try write(Self.ledger, "elsewhere/dispatch-worktrees.jsonl", in: home)
        let env = ["HERDR_PLUGIN_STATE_DIR": home.appendingPathComponent("elsewhere").path]
        guard case .ok(let agy) = AgentLane.read(.agy, home: home, env: env) else {
            return XCTFail("agy should read")
        }
        XCTAssertNotNil(agy.lastDispatch)
    }

    func testBrokenConfigIsLoudNotHidden() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/muse", in: home, executable: true)
        try write("{not json", ".config/muse/settings.json", in: home)
        XCTAssertEqual(AgentLane.read(.muse, home: home, env: Self.ledgerEnv(home)),
                       .unavailable("could not read ~/.config/muse/settings.json"))
    }

    /// The regression that replaced a 1 MB tail: the newest refusal far up a large live log.
    func testNewestRefusalIsFoundFarFromTheEndOfALargeLog() throws {
        let home = try makeHome()
        let filler = String(repeating: "2026-09-16T08:00:00.000000Z  INFO chisel: tick\n",
                            count: 60_000)  // about 2.8 MB after the refusal
        try write(Self.devinLog + "\n" + filler, "big.log", in: home)
        let line = try XCTUnwrap(AgentLane.lastLine(containing: "QuotaExhausted(message=",
                                                    in: home.appendingPathComponent("big.log")))
        let hit = try XCTUnwrap(AgentLane.devinQuotaExhaustion(log: String(line)))
        XCTAssertEqual(hit.at, DateParse.parse("2026-09-15T18:19:43.627602Z"))
        XCTAssertFalse(line.contains("\n"))
    }

    func testLastLineHandlesMarkerOnFirstAndLastLine() throws {
        let home = try makeHome()
        try write(Self.museRateLimited, "one.log", in: home)
        let url = home.appendingPathComponent("one.log")
        XCTAssertEqual(AgentLane.lastLine(containing: "provider_stream.terminal", in: url).map(String.init),
                       Self.museRateLimited)
        XCTAssertNil(AgentLane.lastLine(containing: "QuotaExhausted", in: url))
    }

    // MARK: Devin log window

    private func setMtime(_ date: Date, ofRelative rel: String, in home: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: home.appendingPathComponent(rel).path)
    }

    /// The regression behind the seven day window: the log directory keeps every past
    /// session's file (250 of them on the operator's machine), and the old four-newest
    /// cap meant a refusal outside those four mtimes was invisible. All five quiet logs
    /// here are newer than the one carrying the refusal, and every file is inside the
    /// window, so the refusal must still be read.
    func testRefusalOutsideTheNewestFewLogsIsStillFound() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/devin", in: home, executable: true)
        let now = Date()
        for i in 0..<5 {
            let rel = ".local/share/devin/cli/logs/devin_2026091\(i)-211423_1738\(i).log"
            try write("2026-09-16T08:00:00.000000Z  INFO chisel: tick\n", rel, in: home)
            try setMtime(now.addingTimeInterval(TimeInterval(-(i + 1)) * 60),
                         ofRelative: rel, in: home)
        }
        let refused = ".local/share/devin/cli/logs/devin_20260915-211423_17388.log"
        try write(Self.devinLog, refused, in: home)
        try setMtime(now.addingTimeInterval(-6 * 60), ofRelative: refused, in: home)

        guard case .ok(let devin) = AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("devin should read")
        }
        XCTAssertEqual(devin.lastLimitHit?.at, DateParse.parse("2026-09-15T18:19:43.627602Z"))
    }

    /// Newest is by the refusal's own timestamp, not by which file was touched last.
    func testNewestRefusalWinsAcrossFilesRegardlessOfMtime() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/devin", in: home, executable: true)
        let now = Date()
        let touchedLast = ".local/share/devin/cli/logs/devin_a.log"
        try write(Self.devinOlderRefusal, touchedLast, in: home)
        try setMtime(now.addingTimeInterval(-2 * 60), ofRelative: touchedLast, in: home)
        let refusedEarlier = ".local/share/devin/cli/logs/devin_b.log"
        try write(Self.devinLog, refusedEarlier, in: home)
        try setMtime(now.addingTimeInterval(-2 * 86400), ofRelative: refusedEarlier, in: home)

        guard case .ok(let devin) = AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("devin should read")
        }
        XCTAssertEqual(devin.lastLimitHit?.at, DateParse.parse("2026-09-15T18:19:43.627602Z"))
    }

    /// The window bound: a refusal in a log untouched for eight days is not the present
    /// state of a daily quota, so it is not surfaced.
    func testRefusalInALogOutsideTheSevenDayWindowIsIgnored() throws {
        let home = try makeHome()
        try write("#!/bin/sh\n", ".local/bin/devin", in: home, executable: true)
        let stale = ".local/share/devin/cli/logs/devin_20260908-211423_17388.log"
        try write(Self.devinLog, stale, in: home)
        try setMtime(Date().addingTimeInterval(-8 * 86400), ofRelative: stale, in: home)
        try write("2026-09-16T08:00:00.000000Z  INFO chisel: tick\n",
                  ".local/share/devin/cli/logs/devin_fresh.log", in: home)

        guard case .ok(let devin) = AgentLane.read(.devin, home: home, env: Self.ledgerEnv(home)) else {
            return XCTFail("devin should read")
        }
        XCTAssertNil(devin.lastLimitHit)
    }
}
