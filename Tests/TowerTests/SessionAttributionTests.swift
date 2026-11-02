import Foundation
import XCTest
@testable import Tower

final class SessionAttributionTests: XCTestCase {
    func testTwoSessionsOnDifferentAccountsInOneDirectoryStaySeparate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-session-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var rows: [[String: Any]] = []
        for name in ["first", "second"] {
            let config = root.appendingPathComponent(".claude")
            let project = config.appendingPathComponent("projects/project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config.appendingPathComponent("accounts"),
                                                    withIntermediateDirectories: true)
            let oauth: [String: Any] = ["oauthAccount": [
                "accountUuid": "uuid-\(name)", "emailAddress": "\(name)@example.com"
            ]]
            try JSONSerialization.data(withJSONObject: oauth)
                .write(to: config.appendingPathComponent("accounts/\(name).json"))
            try JSONSerialization.data(withJSONObject: oauth)
                .write(to: root.appendingPathComponent(".claude.json"))
            let bridge: [String: Any] = ["type": "bridge-session", "ownerAccountUuid": "uuid-\(name)"]
            try JSONSerialization.data(withJSONObject: bridge)
                .write(to: project.appendingPathComponent("\(name).jsonl"))
            rows.append(["kind": "interactive", "status": "busy", "cwd": "/project",
                         "sessionId": name])
        }
        let summary = try XCTUnwrap(AgentProbe.summarize(JSONSerialization.data(withJSONObject: rows),
                                                       home: root))
        XCTAssertEqual(summary.groups.count, 2, "Sessions spending different accounts must not collapse")
        XCTAssertEqual(Set(summary.groups.compactMap(\.accountEmail)),
                       ["first@example.com", "second@example.com"])
        XCTAssertEqual(Set(summary.groups.map(\.id)).count, 2)
        XCTAssertEqual(summary.groups.map(\.label), ["project", "project"])
    }

    /// Sessions group on their stable session id and LABEL on the /rename name:
    /// two sessions that chose the same name are still two rows, in one directory
    /// or across directories, and the account split is never lost. The name is
    /// what the operator sees in `claude agents`.
    func testNamedSessionsLabelByNameAndNeverMerge() throws {
        let fixture = try Fixture()
        var a = fixture.row
        a["name"] = "deep-dive"; a["cwd"] = "/one"; a["sessionId"] = "s1"
        var b = fixture.row
        b["name"] = "deep-dive"; b["cwd"] = "/two"; b["sessionId"] = "s2"
        var c = fixture.row
        c["cwd"] = "/one"; c["sessionId"] = "s3"
        let summary = try fixture.summary(rows: [a, b, c])
        XCTAssertEqual(summary.groups.count, 3, "one row per session id")
        let named = summary.groups.filter { $0.sessionName == "deep-dive" }
        XCTAssertEqual(named.count, 2, "a shared name never merges distinct sessions")
        XCTAssertEqual(Set(named.map(\.label)), ["deep-dive"])
        XCTAssertTrue(named.allSatisfy { $0.count == 1 })
        XCTAssertEqual(summary.groups.first { $0.sessionName == nil }?.label, "one",
                       "the unnamed session labels on its directory")

        var d = fixture.row
        d["name"] = "other"; d["cwd"] = "/one"; d["sessionId"] = "s4"
        let two = try fixture.summary(rows: [a, d])
        XCTAssertEqual(two.groups.count, 2, "different names in one directory stay apart")
        XCTAssertEqual(Set(two.groups.map(\.label)), ["deep-dive", "other"])
    }

    func testDefaultConfigSwitchDoesNotRelabelAnExistingSession() throws {
        let fixture = try Fixture()
        try fixture.writeConfig(email: "user-e@example.com", owner: "session-owner",
                                at: fixture.configRoot.appendingPathComponent("accounts/old.json"))
        try fixture.writeConfig(email: "user-a@example.com", owner: "active-owner")
        try fixture.writeTranscript(bridge("session-owner"))
        let first = try fixture.summary()
        XCTAssertEqual(first.groups.first?.accountEmail, "user-e@example.com")
        XCTAssertEqual(first.groups.first?.accountLabel, "ben")

        try fixture.writeConfig(email: "third@example.com", owner: "third-owner")
        XCTAssertEqual(try fixture.summary().groups, first.groups,
                       "Changing the configured account must not change session attribution")
    }

    func testUnknownIdentityNeverBorrowsTheConfiguredAccountOrShowsRoom() throws {
        let scenarios = ["missing transcript", "no bridge", "unmapped owner", "missing owner",
                         "conflicting owners", "conflicting emails", "missing oauth", "empty email",
                         "malformed transcript", "invalid session ID"]
        for scenario in scenarios {
            let fixture = try Fixture()
            try fixture.writeConfig(email: "configured@example.com", owner: "configured-owner")
            try fixture.writeTranscript(bridge("configured-owner"))
            var row = fixture.row
            switch scenario {
            case "missing transcript": try FileManager.default.removeItem(at: fixture.transcript)
            case "no bridge": try fixture.writeTranscript("{\"type\":\"user\"}")
            case "unmapped owner": try fixture.writeTranscript(bridge("unmapped-owner"))
            case "missing owner": try fixture.writeTranscript("{\"type\":\"bridge-session\"}")
            case "conflicting owners":
                try fixture.writeTranscript(bridge("configured-owner") + "\n" + bridge("other-owner"))
            case "conflicting emails":
                try fixture.writeConfig(email: "other@example.com", owner: "configured-owner",
                                        at: fixture.configRoot.appendingPathComponent("accounts/conflict.json"))
            case "missing oauth": try Data("{}".utf8).write(to: fixture.config)
            case "empty email": try fixture.writeConfig(email: " ", owner: "configured-owner")
            case "malformed transcript": try fixture.writeTranscript("{\"type\":\"bridge-session\"")
            case "invalid session ID": row["sessionId"] = "../session"
            default: XCTFail("Unhandled fixture")
            }
            // Even a payload naming the configured account must not bypass resolution.
            row["accountEmail"] = "configured@example.com"
            let summary = try fixture.summary(rows: [row])
            let group = try XCTUnwrap(summary.groups.first)
            XCTAssertNil(group.accountEmail, scenario)
            XCTAssertEqual(group.accountLabel, "account unknown", scenario)
            XCTAssertFalse(group.accountLabel.contains("%"), scenario)
        }
    }

    func testMissingSessionIDNeverBorrowsTheConfiguredAccount() throws {
        let fixture = try Fixture()
        try fixture.writeConfig(email: "configured@example.com", owner: "configured-owner")
        try fixture.writeTranscript(bridge("configured-owner"))
        var row = fixture.row
        row.removeValue(forKey: "sessionId")
        let summary = try fixture.summary(rows: [row])
        XCTAssertEqual(summary.groups.first?.accountLabel, "account unknown")
    }

    func testTranscriptQuotaResetAttributesEachSessionWithoutBridgeOwnership() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeQuotaCache([
            "fay@example.com": snapshot(email: "fay@example.com", reset: reset),
            "other@example.com": snapshot(email: "other@example.com", reset: reset.addingTimeInterval(3_600)),
        ])
        try fixture.writeTranscript("{\"type\":\"assistant\",\"quotaLimits\":{\"resetsAt\":2000010800000}}")

        let group = try XCTUnwrap(fixture.summary().groups.first)
        XCTAssertEqual(group.accountEmail, "fay@example.com")
        XCTAssertEqual(group.accountLabel, "fay")
        XCTAssertEqual(try fixture.summary().interactive.first?.accountEvidence, "inferred from transcript reset")
    }

    func testMostRecentTranscriptQuotaResetWinsAfterALoginChange() throws {
        let fixture = try Fixture()
        let oldReset = Date(timeIntervalSince1970: 2_000_007_200)
        let currentReset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeQuotaCache([
            "old@example.com": snapshot(email: "old@example.com", reset: oldReset),
            "current@example.com": snapshot(email: "current@example.com", reset: currentReset),
        ])
        try fixture.writeTranscript("{\"quotaLimits\":{\"resetsAt\":2000007200}}\n{\"quotaLimits\":{\"resetsAt\":2000010800000}}")

        XCTAssertEqual(try fixture.summary().groups.first?.accountEmail, "current@example.com")
    }

    func testQuotaResetCollisionStaysUnknown() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeQuotaCache([
            "one@example.com": snapshot(email: "one@example.com", reset: reset),
            "two@example.com": snapshot(email: "two@example.com", reset: reset),
        ])
        try fixture.writeTranscript("{\"quotaLimits\":{\"resetsAt\":2000010800}}")

        XCTAssertEqual(try fixture.summary().groups.first?.accountLabel, "account unknown")
    }

    func testCurrentTranscriptResetOverridesBridgeOwnerFromBeforeLogin() throws {
        let fixture = try Fixture()
        let currentReset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeConfig(email: "old@example.com", owner: "old-owner")
        try fixture.writeQuotaCache([
            "current@example.com": snapshot(email: "current@example.com", reset: currentReset),
        ])
        try fixture.writeTranscript(bridge("old-owner")
            + "\n{\"quotaLimits\":{\"resetsAt\":2000010800}}")

        let session = try XCTUnwrap(fixture.summary().interactive.first)
        XCTAssertEqual(session.accountEmail, "current@example.com")
        XCTAssertEqual(session.accountEvidence, "inferred from transcript reset")
    }

    func testAmbiguousCurrentResetDoesNotFallBackToStaleBridgeOwner() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeConfig(email: "old@example.com", owner: "old-owner")
        try fixture.writeQuotaCache([
            "one@example.com": snapshot(email: "one@example.com", reset: reset),
            "two@example.com": snapshot(email: "two@example.com", reset: reset),
        ])
        try fixture.writeTranscript(bridge("old-owner")
            + "\n{\"quotaLimits\":{\"resetsAt\":2000010800}}")

        let session = try XCTUnwrap(fixture.summary().interactive.first)
        XCTAssertNil(session.accountEmail)
        XCTAssertNil(session.accountEvidence)
    }

    func testNewerUnusableQuotaRecordDoesNotReuseOlderResetOrBridgeOwner() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeConfig(email: "old@example.com", owner: "old-owner")
        try fixture.writeQuotaCache([
            "current@example.com": snapshot(email: "current@example.com", reset: reset),
        ])
        try fixture.writeTranscript(bridge("old-owner")
            + "\n{\"quotaLimits\":{\"resetsAt\":2000010800}}"
            + "\n{\"quotaLimits\":{}}")

        let session = try XCTUnwrap(fixture.summary().interactive.first)
        XCTAssertNil(session.accountEmail)
        XCTAssertNil(session.accountEvidence)
    }

    func testSessionConfigDirectoryScopesTranscriptAndQuotaCache() throws {
        let fixture = try Fixture()
        let config = fixture.home.appendingPathComponent("custom-claude")
        let transcript = config.appendingPathComponent("projects/project/session.jsonl")
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"quotaLimits\":{\"resetsAt\":2000010800}}".utf8).write(to: transcript)
        try JSONEncoder().encode([
            "custom@example.com": snapshot(email: "custom@example.com", reset: reset),
        ]).write(to: config.appendingPathComponent("quota-cache.json"))
        try fixture.writeQuotaCache([
            "wrong-default@example.com": snapshot(email: "wrong-default@example.com", reset: reset),
        ])
        var row = fixture.row
        row["configDir"] = config.path

        let session = try XCTUnwrap(fixture.summary(rows: [row]).interactive.first)
        XCTAssertEqual(session.accountEmail, "custom@example.com")
        XCTAssertEqual(session.accountEvidence, "inferred from transcript reset")
    }

    func testKnownAndUnknownSessionsInOneDirectoryStaySeparate() throws {
        let fixture = try Fixture()
        try fixture.writeConfig(email: "account@example.com", owner: "owner")
        try fixture.writeTranscript(bridge("owner"))
        var unknown = fixture.row
        unknown["sessionId"] = "missing-session"
        let summary = try fixture.summary(rows: [fixture.row, fixture.row, unknown])
        XCTAssertEqual(summary.groups.count, 2)
        XCTAssertEqual(summary.groups.first(where: { $0.accountEmail != nil })?.count, 2)
        XCTAssertEqual(summary.groups.first(where: { $0.accountEmail == nil })?.count, 1)
    }

    func testTranscriptStreamingKeepsOwnershipAcrossChunkBoundaries() throws {
        let fixture = try Fixture()
        try fixture.writeConfig(email: "account@example.com", owner: "owner")
        let padding = String(repeating: "{\"type\":\"user\"}\n", count: 5000)
        try fixture.writeTranscript(padding + bridge("owner"))
        XCTAssertEqual(try fixture.summary().groups.first?.accountEmail, "account@example.com")
    }

    /// Measured on 2.1.281: a rejected request writes
    /// `{"resetsAt":1790478000,"rateLimitType":"seven_day",...}`. That reset is a weekly
    /// anchor and must never be compared with a five hour reset.
    func testSevenDayTranscriptRecordMatchesTheWeeklyResetOnly() throws {
        let fixture = try Fixture()
        let weekly = Date(timeIntervalSince1970: 2_000_300_000)
        try fixture.writeQuotaCache([
            "weekly@example.com": snapshot(email: "weekly@example.com",
                                           reset: Date(timeIntervalSince1970: 2_000_010_800), weekly: weekly),
            // Its five hour reset equals the weekly anchor: a type blind match picks it.
            "decoy@example.com": snapshot(email: "decoy@example.com", reset: weekly,
                                          weekly: Date(timeIntervalSince1970: 2_000_600_000)),
        ])
        try fixture.writeTranscript("{\"quotaLimits\":{\"status\":\"rejected\",\"resetsAt\":2000300000,"
            + "\"rateLimitType\":\"seven_day\",\"overageStatus\":\"rejected\"}}")

        let session = try XCTUnwrap(fixture.summary().interactive.first)
        XCTAssertEqual(session.accountEmail, "weekly@example.com")
        XCTAssertEqual(session.accountEvidence, "inferred from transcript reset")
    }

    func testFiveHourTranscriptRecordTypeMatchesTheFiveHourReset() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeQuotaCache([
            "fay@example.com": snapshot(email: "fay@example.com", reset: reset),
            "decoy@example.com": snapshot(email: "decoy@example.com", reset: reset.addingTimeInterval(3_600),
                                          weekly: reset),
        ])
        try fixture.writeTranscript("{\"quotaLimits\":{\"resetsAt\":2000010800,\"rateLimitType\":\"five_hour\"}}")
        XCTAssertEqual(try fixture.summary().groups.first?.accountEmail, "fay@example.com")
    }

    func testUnknownTranscriptRateLimitTypeIsUnusableAndNeverFallsBack() throws {
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        for type in ["\"seven_day_opus\"", "\"\"", "7"] {
            let fixture = try Fixture()
            try fixture.writeConfig(email: "old@example.com", owner: "old-owner")
            try fixture.writeQuotaCache([
                "fay@example.com": snapshot(email: "fay@example.com", reset: reset, weekly: reset),
            ])
            try fixture.writeTranscript(bridge("old-owner")
                + "\n{\"quotaLimits\":{\"resetsAt\":2000010800,\"rateLimitType\":\(type)}}")
            let session = try XCTUnwrap(fixture.summary().interactive.first, type)
            XCTAssertNil(session.accountEmail, type)
            XCTAssertNil(session.accountEvidence, type)
        }
    }

    /// Claude Code 2.1.283 transcripts carry neither quotaLimits nor bridge-session
    /// records, so the statusline's per-session anchor is the source that attributes.
    func testStatuslineAnchorAttributesASessionWhoseTranscriptHasNoQuotaRecord() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeQuotaCache([
            "fay@example.com": snapshot(email: "fay@example.com", reset: reset),
            "other@example.com": snapshot(email: "other@example.com", reset: reset.addingTimeInterval(3_600)),
        ])
        try fixture.writeTranscript("{\"type\":\"user\"}\n{\"type\":\"custom-title\"}")
        try fixture.writeAnchor("2000010800|2000097200|1790000000\n")

        let session = try XCTUnwrap(fixture.summary().interactive.first)
        XCTAssertEqual(session.accountEmail, "fay@example.com")
        XCTAssertEqual(session.accountEvidence, "inferred from statusline reset")
        XCTAssertEqual(try fixture.summary().groups.first?.accountLabel, "fay")

        try FileManager.default.removeItem(at: fixture.transcript)
        XCTAssertEqual(try fixture.summary().groups.first?.accountEmail, "fay@example.com",
                       "the anchor is keyed by session id and needs no transcript")
    }

    func testStatuslineAnchorKeepsTheNinetySecondTolerance() throws {
        let fixture = try Fixture()
        try fixture.writeQuotaCache([
            "fay@example.com": snapshot(email: "fay@example.com", reset: Date(timeIntervalSince1970: 2_000_010_800)),
        ])
        try fixture.writeAnchor("2000010845||1790000000")
        XCTAssertEqual(try fixture.summary().groups.first?.accountEmail, "fay@example.com")
        try fixture.writeAnchor("2000011100||1790000000")
        XCTAssertNil(try fixture.summary().groups.first?.accountEmail)
    }

    /// Mirrors the statusline: the weekly reset narrows a five hour tie when both sides have one.
    func testStatuslineAnchorWeeklyResetSeparatesASharedFiveHourReset() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeQuotaCache([
            "one@example.com": snapshot(email: "one@example.com", reset: reset,
                                        weekly: Date(timeIntervalSince1970: 2_000_300_000)),
            "two@example.com": snapshot(email: "two@example.com", reset: reset,
                                        weekly: Date(timeIntervalSince1970: 2_000_500_000)),
        ])
        try fixture.writeAnchor("2000010800|2000500000|1790000000")
        XCTAssertEqual(try fixture.summary().groups.first?.accountEmail, "two@example.com")

        try fixture.writeAnchor("2000010800||1790000000")
        XCTAssertNil(try fixture.summary().groups.first?.accountEmail,
                     "without a weekly reset the shared five hour reset stays ambiguous")
    }

    func testStatuslineAnchorOverridesStaleBridgeOwner() throws {
        let fixture = try Fixture()
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try fixture.writeConfig(email: "old@example.com", owner: "old-owner")
        try fixture.writeQuotaCache([
            "current@example.com": snapshot(email: "current@example.com", reset: reset),
        ])
        try fixture.writeTranscript(bridge("old-owner"))
        try fixture.writeAnchor("2000010800||1790000000")

        let session = try XCTUnwrap(fixture.summary().interactive.first)
        XCTAssertEqual(session.accountEmail, "current@example.com")
        XCTAssertEqual(session.accountEvidence, "inferred from statusline reset")
    }

    /// A present anchor that cannot name exactly one account is unknown. It never falls
    /// back to an older transcript reset or bridge owner, and never to the active login.
    func testUnusableOrAmbiguousStatuslineAnchorNeverFallsBack() throws {
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        for (scenario, record) in [("ambiguous", "2000010800||1"), ("unmatched", "1900000000||1"),
                                   ("malformed", "garbage"), ("empty", ""), ("negative", "-5||1"),
                                   ("bad weekly", "2000010800|soon|1")] {
            let fixture = try Fixture()
            try fixture.writeConfig(email: "configured@example.com", owner: "configured-owner")
            try fixture.writeQuotaCache([
                "one@example.com": snapshot(email: "one@example.com", reset: reset),
                "two@example.com": snapshot(email: "two@example.com", reset: reset),
                "configured@example.com": snapshot(email: "configured@example.com",
                                                   reset: reset.addingTimeInterval(7_200)),
            ])
            try fixture.writeTranscript(bridge("configured-owner")
                + "\n{\"quotaLimits\":{\"resetsAt\":2000018000}}")
            try fixture.writeAnchor(record)
            let session = try XCTUnwrap(fixture.summary().interactive.first, scenario)
            XCTAssertNil(session.accountEmail, scenario)
            XCTAssertNil(session.accountEvidence, scenario)
        }
    }

    func testSessionConfigDirectoryScopesTheStatuslineAnchor() throws {
        let fixture = try Fixture()
        let config = fixture.home.appendingPathComponent("custom-claude")
        let reset = Date(timeIntervalSince1970: 2_000_010_800)
        try FileManager.default.createDirectory(at: config.appendingPathComponent("session-anchors"),
                                                withIntermediateDirectories: true)
        try Data("2000010800||1".utf8)
            .write(to: config.appendingPathComponent("session-anchors/session"))
        try JSONEncoder().encode([
            "custom@example.com": snapshot(email: "custom@example.com", reset: reset),
        ]).write(to: config.appendingPathComponent("quota-cache.json"))
        try fixture.writeQuotaCache([
            "wrong-default@example.com": snapshot(email: "wrong-default@example.com", reset: reset),
        ])
        var row = fixture.row
        row["configDir"] = config.path

        XCTAssertEqual(try fixture.summary(rows: [row]).groups.first?.accountEmail, "custom@example.com")
    }

    @MainActor
    func testRecommendationNamesTheCredentialSlot() async {
        let label = RecommendBanner.stayLabel
        XCTAssertEqual(label, "keychain holds")
    }

    private func bridge(_ owner: String) -> String {
        "{\"type\":\"bridge-session\",\"ownerAccountUuid\":\"\(owner)\"}"
    }

    private func snapshot(email: String, reset: Date, weekly: Date? = nil) -> AccountSnapshot {
        AccountSnapshot(email: email, nickname: Nickname.derive(from: email), plan: "max",
                        fiveHourPct: 20, fiveHourResetsAt: reset, weeklyPct: 30,
                        weeklyResetsAt: weekly ?? reset.addingTimeInterval(86_400),
                        capturedAt: reset.addingTimeInterval(-60))
    }

    private final class Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-session-tests-\(UUID().uuidString)")
        var configRoot: URL { home.appendingPathComponent(".claude") }
        var config: URL { home.appendingPathComponent(".claude.json") }
        var transcript: URL { configRoot.appendingPathComponent("projects/project/session.jsonl") }
        var row: [String: Any] {
            ["kind": "interactive", "status": "busy", "cwd": "/project", "sessionId": "session"]
        }

        init() throws {
            try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: configRoot.appendingPathComponent("accounts"),
                                                    withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        func writeConfig(email: String, owner: String, at url: URL? = nil) throws {
            let value = ["oauthAccount": ["emailAddress": email, "accountUuid": owner]]
            try JSONSerialization.data(withJSONObject: value).write(to: url ?? config)
        }

        func writeTranscript(_ text: String) throws {
            try Data(text.utf8).write(to: transcript)
        }

        func writeAnchor(_ record: String, session: String = "session") throws {
            let directory = configRoot.appendingPathComponent("session-anchors")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(record.utf8).write(to: directory.appendingPathComponent(session))
        }

        func writeQuotaCache(_ snapshots: [String: AccountSnapshot]) throws {
            try JSONEncoder().encode(snapshots).write(to: configRoot.appendingPathComponent("quota-cache.json"))
        }

        func summary(rows: [[String: Any]]? = nil) throws -> AgentSummary {
            try XCTUnwrap(AgentProbe.summarize(JSONSerialization.data(withJSONObject: rows ?? [row]),
                                              home: home))
        }
    }
}
