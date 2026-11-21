import Foundation
import XCTest
@testable import Tower

/// Starts the real binary as `tower mcp` over stdio against a throwaway store
/// (`TOWER_SUPPORT_DIR`, `CLAUDE_CONFIG_DIR`), then speaks the protocol the way a
/// client does: initialize, tools/list, one read tool, one resource, one
/// subscription that must fire when the mirror is rewritten. No Keychain, no
/// network: the tools it calls read the store only.
final class MCPIntegrationTests: XCTestCase {
    private var dir: URL!
    private var process: Process!
    private var stdin: Pipe!
    private var stdout: Pipe!
    private var stderr: Pipe!
    /// stdout is drained on a thread so a wait can time out instead of blocking on a
    /// read that never returns.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func popLine() -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard let newline = data.firstIndex(of: 0x0A) else { return nil }
            let line = Data(data[data.startIndex..<newline])
            data.removeSubrange(data.startIndex...newline)
            return line
        }
    }
    private let inbox = Inbox()

    /// The built product beside the test bundle, the SwiftPM layout `swift test` uses.
    private var towerBinary: URL {
        if let override = ProcessInfo.processInfo.environment["TOWER_TEST_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let bundle = Bundle(for: MCPIntegrationTests.self)
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Tower")
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tower-mcp-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(dir: dir.appendingPathComponent("support"), mirror: dir.appendingPathComponent("claude/quota-cache.json"))
        var live = AccountSnapshot(email: "user-a@example.com", nickname: "cal", plan: "max")
        live.fiveHourPct = 14
        live.fiveHourResetsAt = Date().addingTimeInterval(3600)
        live.weeklyPct = 3
        live.weeklyResetsAt = Date().addingTimeInterval(86_400)
        live.capturedAt = Date()
        var codex = AccountSnapshot(email: "user-c@example.com", nickname: "eve", plan: "pro")
        codex.provider = .codex
        codex.weeklyPct = 70
        codex.weeklyResetsAt = Date().addingTimeInterval(86_400)
        codex.capturedAt = Date()
        XCTAssertNil(store.save([live.id: live, codex.id: codex]))

        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: towerBinary.path),
                          "no Tower product beside the test bundle at \(towerBinary.path)")
        process = Process()
        process.executableURL = towerBinary
        process.arguments = ["mcp"]
        var env = ProcessInfo.processInfo.environment
        env["TOWER_SUPPORT_DIR"] = dir.appendingPathComponent("support").path
        env["CLAUDE_CONFIG_DIR"] = dir.appendingPathComponent("claude").path
        process.environment = env
        stdin = Pipe()
        stdout = Pipe()
        stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let handle = stdout.fileHandleForReading
        let inbox = self.inbox
        Thread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                inbox.append(chunk)
            }
        }.start()
    }

    override func tearDownWithError() throws {
        if process?.isRunning == true {
            try? stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func send(_ message: JSON) {
        var data = message.encoded()
        data.append(0x0A)
        stdin.fileHandleForWriting.write(data)
    }

    /// The next complete line from the server, within `timeout` seconds.
    private func receive(timeout: TimeInterval = 20) throws -> JSON {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = inbox.popLine() { return try JSON.parse(line) }
            usleep(20_000)
        }
        struct Timeout: Error {}
        XCTFail("timed out waiting for the server after \(timeout)s")
        throw Timeout()
    }

    /// Reads until the response with `id` arrives; notifications seen meanwhile are
    /// returned as well so a test can assert on them.
    private func response(id: Int, timeout: TimeInterval = 20) throws -> (JSON, [JSON]) {
        var notifications: [JSON] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try receive(timeout: max(1, deadline.timeIntervalSinceNow))
            if message["id"] == .int(id) { return (message, notifications) }
            if message["id"].isNull { notifications.append(message) }
        }
        XCTFail("no response for id \(id)")
        return (.null, notifications)
    }

    func testStdioSessionEndToEnd() throws {
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "xctest", "version": "0"]]])
        let (initialize, _) = try response(id: 1)
        XCTAssertEqual(initialize["result"]["protocolVersion"], "2025-06-18")
        XCTAssertEqual(initialize["result"]["serverInfo"]["name"], "tower")
        XCTAssertEqual(initialize["result"]["capabilities"]["resources"]["subscribe"], true)
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let (tools, _) = try response(id: 2)
        let names = tools["result"]["tools"].arrayValue?.compactMap { $0["name"].stringValue } ?? []
        XCTAssertEqual(Set(names), Set(TowerMCPService.tools.map(\.name)))
        for tool in tools["result"]["tools"].arrayValue ?? [] {
            XCTAssertNotNil(tool["annotations"]["readOnlyHint"].boolValue, tool["name"].text)
            XCTAssertEqual(tool["outputSchema"]["type"], "object", tool["name"].text)
        }

        send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "tower_accounts", "arguments": [:]]])
        let (accounts, _) = try response(id: 3)
        XCTAssertEqual(accounts["result"]["isError"], false, accounts.text)
        let rows = accounts["result"]["structuredContent"]["accounts"].arrayValue ?? []
        XCTAssertEqual(rows.count, 2, accounts.text)
        let live = try XCTUnwrap(rows.first { $0["nickname"] == "cal" })
        XCTAssertEqual(live["worstTrust"], "live")
        XCTAssertEqual(live["roomPct"], 86)
        XCTAssertEqual(live["windows"].arrayValue?.map { $0["name"] }, ["5h", "7d"])
        let schema = TowerMCPService.tools.first { $0.name == "tower_accounts" }!.outputSchema
        XCTAssertTrue(JSONSchemaCheck.validate(accounts["result"]["structuredContent"], against: schema).isEmpty)

        send(["jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": .string(TowerMCPService.quotaCacheURI)]])
        let (cache, _) = try response(id: 4)
        let body = try JSON.parse(Data((cache["result"]["contents"][0]["text"].stringValue ?? "").utf8))
        XCTAssertEqual(body["user-a@example.com"]["nickname"], "cal")
        XCTAssertEqual(body["codex:user-c@example.com"]["provider"], "codex")
        XCTAssertEqual(cache["result"]["contents"][0]["mimeType"], "application/json")

        // Subscribe, rewrite the store (which rewrites the mirror), expect the update.
        send(["jsonrpc": "2.0", "id": 5, "method": "resources/subscribe", "params": ["uri": .string(TowerMCPService.quotaCacheURI)]])
        let (subscribed, _) = try response(id: 5)
        XCTAssertEqual(subscribed["result"], [:])
        let store = Store(dir: dir.appendingPathComponent("support"), mirror: dir.appendingPathComponent("claude/quota-cache.json"))
        var changed = store.load()
        changed["user-a@example.com"]?.fiveHourPct = 55
        XCTAssertNil(store.save(changed))
        let updated = try receive(timeout: 15)
        XCTAssertEqual(updated["method"], "notifications/resources/updated", updated.text)
        XCTAssertEqual(updated["params"]["uri"], .string(TowerMCPService.quotaCacheURI))

        send(["jsonrpc": "2.0", "id": 6, "method": "ping"])
        let (pong, _) = try response(id: 6)
        XCTAssertEqual(pong["result"], [:])

        try stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(process.isRunning, "the server exits when the client closes stdin")
        XCTAssertEqual(process.terminationStatus, 0)
        let noise = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(noise.isEmpty, "stderr should be quiet for a store only session: \(noise)")
    }

    /// The same binary, driven the 2026-07-28 way: discover, per request `_meta`,
    /// a `subscriptions/listen` stream that fires on a store save and closes
    /// gracefully when stdin closes.
    func testModernStdioSessionEndToEnd() throws {
        let meta: JSON = [MCPServer.metaVersion: "2026-07-28", MCPServer.metaClientCapabilities: [:],
                          MCPServer.metaClientInfo: ["name": "xctest", "version": "0"]]
        send(["jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": ["_meta": meta]])
        let (discover, _) = try response(id: 1)
        XCTAssertEqual(discover["result"]["supportedVersions"], ["2026-07-28"], discover.text)
        XCTAssertEqual(discover["result"]["resultType"], "complete")
        XCTAssertEqual(discover["result"]["_meta"][MCPServer.metaServerInfo]["name"], "tower")

        send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["_meta": meta, "name": "tower_room", "arguments": [:]]])
        let (room, _) = try response(id: 2)
        XCTAssertEqual(room["result"]["resultType"], "complete", room.text)
        XCTAssertEqual(room["result"]["structuredContent"]["recommended"], "cal")

        send(["jsonrpc": "2.0", "id": 3, "method": "subscriptions/listen",
              "params": ["_meta": meta, "notifications": ["resourceSubscriptions": [.string(TowerMCPService.quotaCacheURI)]]]])
        let ack = try receive()
        XCTAssertEqual(ack["method"], "notifications/subscriptions/acknowledged", ack.text)
        XCTAssertEqual(ack["params"]["_meta"][MCPServer.metaSubscriptionID], 3)

        let store = Store(dir: dir.appendingPathComponent("support"), mirror: dir.appendingPathComponent("claude/quota-cache.json"))
        var changed = store.load()
        changed["user-a@example.com"]?.weeklyPct = 44
        XCTAssertNil(store.save(changed))
        let updated = try receive(timeout: 15)
        XCTAssertEqual(updated["method"], "notifications/resources/updated", updated.text)
        XCTAssertEqual(updated["params"]["_meta"][MCPServer.metaSubscriptionID], 3)
        XCTAssertEqual(updated["params"]["uri"], .string(TowerMCPService.quotaCacheURI))

        try stdin.fileHandleForWriting.close()
        let closure = try receive(timeout: 10)
        XCTAssertEqual(closure["id"], 3, "the deferred listen response closes the stream: \(closure.text)")
        XCTAssertEqual(closure["result"]["resultType"], "complete")
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(process.isRunning)
    }
}
