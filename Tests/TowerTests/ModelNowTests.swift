import Foundation
import XCTest
@testable import Tower

/// The model pin is frozen at launch or config write time, so a mid-session
/// /model makes it lie. `modelNow` is the live evidence that corrects it, and
/// `modelNowSource` says how strong that evidence is.
final class ModelNowTests: XCTestCase {

    // MARK: AgentLane.modelNow, the lane-row reader

    func testCursorSelectionHistoryLastEntryWins() {
        let data = Data(#"{"model":{"displayModelId":"auto"},"modelSelectionHistory":["default","composer-2.5","grok-4.7"]}"#.utf8)
        let now = AgentLane.modelNow(.cursor, data: data)
        XCTAssertEqual(now?.model, "grok-4.7")
        XCTAssertEqual(now?.source, "selection")
    }

    func testCursorEmptyOrMissingHistoryIsNil() {
        XCTAssertNil(AgentLane.modelNow(.cursor,
            data: Data(#"{"modelSelectionHistory":[]}"#.utf8)))
        XCTAssertNil(AgentLane.modelNow(.cursor,
            data: Data(#"{"model":{"displayModelId":"auto"}}"#.utf8)))
    }

    func testCursorHistorySkipsEmptyTailEntries() {
        let data = Data(#"{"modelSelectionHistory":["default","claude-sonnet-5-5",""]}"#.utf8)
        XCTAssertEqual(AgentLane.modelNow(.cursor, data: data)?.model, "claude-sonnet-5-5")
    }

    func testDevinAndMuseConfigIsLabelledConfig() {
        let devin = Data(#"{"agent":{"model":"swe-2-high"}}"#.utf8)
        let devinNow = AgentLane.modelNow(.devin, data: devin)
        XCTAssertEqual(devinNow?.model, "swe-2-high")
        XCTAssertEqual(devinNow?.source, "config")

        let muse = Data(#"{"model":"muse-spark-1.3"}"#.utf8)
        XCTAssertEqual(AgentLane.modelNow(.muse, data: muse)?.source, "config")
    }

    func testAgyHasNoReadableSource() {
        // ~/.gemini is operator-auth territory: no model record may be read,
        // so the field is nil and the row never poses a number it cannot prove.
        XCTAssertNil(AgentLane.modelNow(.agy, data: Data(#"{"model":"x"}"#.utf8)))
        XCTAssertNil(AgentLane.modelNow(.agy, data: nil))
    }

    func testUnreadableConfigIsNil() {
        XCTAssertNil(AgentLane.modelNow(.devin, data: Data("not json".utf8)))
        XCTAssertNil(AgentLane.modelNow(.devin, data: nil))
    }

    // MARK: SessionModelResolver, the per-session transcript reader

    func testNewestAssistantModelWinsAcrossAMidSessionSwitch() throws {
        let fixture = try Fixture()
        try fixture.writeTranscript(
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5"}}"# + "\n"
            + #"{"type":"user","message":{"role":"user"}}"# + "\n"
            + #"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#)
        XCTAssertEqual(try fixture.modelNow(), "claude-opus-5-5",
                       "the switch record is the truth, not the launch pin")
    }

    func testSpacedJsonAssistantRecordReads() throws {
        let fixture = try Fixture()
        try fixture.writeTranscript(#"{"type": "assistant", "message": {"model": "claude-haiku-5-5"}}"#)
        XCTAssertEqual(try fixture.modelNow(), "claude-haiku-5-5")
    }

    func testNoTranscriptIsNilNotAGuess() throws {
        let fixture = try Fixture()
        XCTAssertNil(try fixture.modelNow())
    }

    func testTranscriptWithoutAssistantRecordsIsNil() throws {
        let fixture = try Fixture()
        try fixture.writeTranscript(#"{"type":"user"}"# + "\n" + #"{"type":"system"}"#)
        XCTAssertNil(try fixture.modelNow())
    }

    func testAssistantRecordWithoutModelIsNil() throws {
        let fixture = try Fixture()
        try fixture.writeTranscript(#"{"type":"assistant","message":{"role":"assistant"}}"#)
        XCTAssertNil(try fixture.modelNow())
    }

    /// Sessions under CLAUDE_CONFIG_DIR resolve against their own root, the
    /// same scoping the account resolver applies.
    func testConfigDirScopesTheTranscript() throws {
        let fixture = try Fixture()
        let custom = fixture.home.appendingPathComponent("custom-claude")
        let transcript = custom.appendingPathComponent("projects/project/session.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#.utf8)
            .write(to: transcript)
        var row = fixture.row
        row["configDir"] = custom.path
        XCTAssertEqual(try fixture.modelNow(row: row), "claude-opus-5-5")
    }

    private final class Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-modelnow-tests-\(UUID().uuidString)")
        var transcript: URL {
            home.appendingPathComponent(".claude/projects/project/session.jsonl")
        }
        var row: [String: Any] {
            ["kind": "interactive", "status": "busy", "cwd": "/project", "sessionId": "session"]
        }

        init() throws {
            try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        func writeTranscript(_ text: String) throws {
            try Data(text.utf8).write(to: transcript)
        }

        func modelNow(row: [String: Any]? = nil) throws -> String? {
            let summary = try XCTUnwrap(AgentProbe.summarize(
                JSONSerialization.data(withJSONObject: [row ?? self.row]), home: home))
            return summary.interactive.first?.modelNow
        }
    }
}
