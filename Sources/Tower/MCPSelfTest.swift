import Foundation

/// `tower mcp --self-test`: the floor's MCP preflight for this server. It drives the
/// same handler the stdio loop uses (initialize, tools/list, one account read, one
/// resource read) in process and prints one line per step, so a station can tell a
/// broken server from a broken lane before the brief goes out. No Keychain, no
/// network: the reads it makes are the store only.
enum MCPSelfTest {
    static func run(_ service: TowerMCPService) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        Task {
            code = await check(service)
            sem.signal()
        }
        sem.wait()
        return code
    }

    private static func check(_ service: TowerMCPService) async -> Int32 {
        var failures = 0
        func step(_ name: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "  ok   " : "  FAIL ") + name + (detail.isEmpty ? "" : ": " + detail))
            if !ok { failures += 1 }
        }
        let server = MCPServer(service: service, send: { _ in })

        let initialize = await server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": .string(MCPServer.latestLegacyProtocolVersion), "capabilities": [:],
                       "clientInfo": ["name": "tower-self-test", "version": "0"]],
        ])
        let version = initialize?["result"]["protocolVersion"].stringValue
        step("initialize (legacy handshake)", version == MCPServer.latestLegacyProtocolVersion, "protocolVersion \(version ?? "missing")")

        let discover = await server.handle([
            "jsonrpc": "2.0", "id": 10, "method": "server/discover",
            "params": ["_meta": [MCPServer.metaVersion: .string(MCPServer.latestProtocolVersion), MCPServer.metaClientCapabilities: [:]]],
        ])
        let supported = discover?["result"]["supportedVersions"].arrayValue?.compactMap(\.stringValue) ?? []
        step("server/discover (2026-07-28)", supported == MCPServer.modernProtocolVersions && discover?["result"]["resultType"] == "complete",
             "supportedVersions \(supported)")

        let tools = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let toolNames = tools?["result"]["tools"].arrayValue?.compactMap { $0["name"].stringValue } ?? []
        step("tools/list", toolNames.count == TowerMCPService.tools.count, "\(toolNames.count) tools")
        for name in toolNames { print("         " + name) }

        let accounts = await server.handle([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "tower_accounts", "arguments": [:]],
        ])
        let rows = accounts?["result"]["structuredContent"]["accounts"].arrayValue ?? []
        let schema = TowerMCPService.tools.first { $0.name == "tower_accounts" }?.outputSchema ?? .null
        let violations = JSONSchemaCheck.validate(accounts?["result"]["structuredContent"] ?? .null, against: schema)
        step("tower_accounts", accounts?["result"]["isError"] == .bool(false) && violations.isEmpty,
             "\(rows.count) row(s)" + (violations.isEmpty ? "" : "; schema: \(violations.map(\.description).joined(separator: ", "))"))
        if let first = rows.first {
            let room = first["roomPct"].doubleValue.map { "\(Int($0.rounded()))% room" } ?? "room unknown"
            step("one account", true, "\(first["nickname"].stringValue ?? "?") (\(first["provider"].stringValue ?? "?")): \(room), \(first["worstTrust"].stringValue ?? "?")")
        } else {
            step("one account", true, "store is empty; nothing captured yet")
        }

        let resource = await server.handle([
            "jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": .string(TowerMCPService.quotaCacheURI)],
        ])
        let body = resource?["result"]["contents"][0]["text"].stringValue ?? ""
        let parses = (try? JSON.parse(Data(body.utf8))) != nil
        step("resources/read quota-cache", parses, "\(body.utf8.count) bytes")

        let prompts = await server.handle(["jsonrpc": "2.0", "id": 5, "method": "prompts/list"])
        let promptCount = prompts?["result"]["prompts"].arrayValue?.count ?? 0
        step("prompts/list", promptCount == TowerMCPService.prompts.count, "\(promptCount) prompts")

        print(failures == 0 ? "  tower mcp self-test passed" : "  tower mcp self-test: \(failures) step(s) failed")
        return failures == 0 ? 0 : 1
    }
}
