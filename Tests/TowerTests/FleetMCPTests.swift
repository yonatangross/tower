import Foundation
import XCTest
@testable import Tower

/// The lanes read Tower over MCP, so every improvement has to reach them there too:
/// machine room beside seat room, the blast radius beside the sessions, the model per
/// seat, and the Cursor Opus flag on the lane.
final class FleetMCPTests: XCTestCase {
    private var fixture: MCPFixture!

    override func setUpWithError() throws { fixture = try MCPFixture() }
    override func tearDown() { fixture.tearDown() }

    private func service(machine: MachineLoad?) -> TowerMCPService {
        var env = fixture.environment()
        env.machine = { machine }
        return TowerMCPService(env: env)
    }

    private func overloaded() -> MachineLoad {
        MachineLoad(load1: 180, compressorBytes: 14 * 1_073_741_824, swapUsedBytes: 0, swapTotalBytes: 0,
                    physicalBytes: 64 * 1_073_741_824, sampledAt: fixture.now)
    }

    func testRoomCarriesMachineRoomInTheGatesTerms() async throws {
        let result = try await service(machine: overloaded()).callTool("tower_room", arguments: [:])
        let room = try XCTUnwrap(result.structuredContent)
        XCTAssertEqual(room["machineRoom"].boolValue, false, "load1 180 is over the gate's 120")
        XCTAssertEqual(room["machine"]["level"].stringValue, "red")
        XCTAssertEqual(room["machine"]["refusal"].stringValue, "load1 180 over 120")
        XCTAssertEqual(room["machine"]["gate"]["load1"].doubleValue, 120)
        let violations = JSONSchemaCheck.validate(room, against: TowerMCPService.tools.first { $0.name == "tower_room" }!.outputSchema)
        XCTAssertTrue(violations.isEmpty, "\(violations)")

        let unread = try await service(machine: nil).callTool("tower_room", arguments: [:]).structuredContent
        XCTAssertEqual(unread?["machineRoom"], .null, "an unread machine is unknown, never room")
    }

    func testSessionsCarryTheBlastRadius() async throws {
        let result = try await service(machine: nil).callTool("tower_sessions", arguments: [:])
        let sessions = try XCTUnwrap(result.structuredContent)
        let blast = sessions["blastRadius"]
        XCTAssertEqual(blast["nickname"].stringValue, "cal")
        XCTAssertEqual(blast["riders"].intValue, 0, "no session has measured ownership")
        XCTAssertEqual(blast["unknown"].intValue, 5, "three interactive plus two background")
        XCTAssertEqual(blast["level"].stringValue, "clear", "the level follows the live usage, not unknown ownership")
        XCTAssertEqual(blast["warnAt"].doubleValue, 85)
        XCTAssertEqual(blast["line"].stringValue, "0 confirmed, 5 unknown sessions on cal at 11 %")
        let violations = JSONSchemaCheck.validate(sessions, against: TowerMCPService.tools.first { $0.name == "tower_sessions" }!.outputSchema)
        XCTAssertTrue(violations.isEmpty, "\(violations)")
    }

    func testAccountsCarryTheModelAndTheCursorPoolMeaning() async throws {
        var map = fixture.store.load()
        let codexKey = try XCTUnwrap(map.values.first { $0.kind == .codex }?.id)
        map[codexKey]?.model = "gpt-6-luna"
        var seat = try XCTUnwrap(map.values.first { $0.kind == .cursor })
        seat.scoped = [
            ScopedLimit(label: "Cursor Models", percent: 73, resetsAt: seat.weeklyResetsAt),
            ScopedLimit(label: "Other Models", percent: 100, resetsAt: seat.weeklyResetsAt),
        ]
        seat.weeklyPct = 100
        map[seat.id] = seat
        XCTAssertNil(fixture.store.save(map))

        let svc = service(machine: nil)
        let codex = try await svc.callTool("tower_account", arguments: ["account": "codex:eve"]).structuredContent
        XCTAssertEqual(codex?["model"].stringValue, "gpt-6-luna")

        let cursor = try await svc.callTool("tower_account", arguments: ["account": "cursor:ben"]).structuredContent
        XCTAssertEqual(cursor?["resting"]["kind"].stringValue, "meteredCapped")
        XCTAssertEqual(cursor?["resting"]["reason"].stringValue, "Opus pool capped 100% · Auto unmetered")
        XCTAssertEqual(cursor?["binding"]["usableFor"].stringValue, "Auto")
    }

    func testClaudeModelIsStampedOnTheActiveLoginOnly() {
        var accounts: [String: AccountSnapshot] = [
            "a@x": AccountSnapshot(email: "a@x", nickname: "a", plan: "max"),
            "b@x": AccountSnapshot(email: "b@x", nickname: "b", plan: "max", model: "stale-model"),
        ]
        var codex = AccountSnapshot(email: "a@x", nickname: "a", plan: "pro", model: "gpt-6-luna")
        codex.provider = .codex
        accounts["codex:a@x"] = codex
        ClaudeModelSetting.stamp(&accounts, activeEmail: "a@x", model: "opus[1m]")
        XCTAssertEqual(accounts["a@x"]?.model, "opus[1m]")
        XCTAssertNil(accounts["b@x"]?.model, "an inactive seat runs nothing until switched into")
        XCTAssertEqual(accounts["codex:a@x"]?.model, "gpt-6-luna", "Codex keeps its own model")
    }
}
