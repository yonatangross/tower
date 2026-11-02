import Foundation
import XCTest
@testable import Tower

/// A stub service so the JSON-RPC layer is tested on its own: one tool, one resource,
/// one prompt, and a record of what it was asked.
final class StubMCPService: MCPService, @unchecked Sendable {
    var serverName: String { "stub" }
    var serverVersion: String { "0" }
    var instructions: String { "stub instructions" }
    var calls: [(String, JSON)] = []

    func listTools() -> [MCPToolSpec] {
        [MCPToolSpec(
            name: "echo", title: "Echo", description: "echoes",
            inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]],
            outputSchema: ["type": "object", "required": ["text"], "properties": ["text": ["type": "string"]]],
            annotations: .read)]
    }

    func callTool(_ name: String, arguments: JSON) async throws -> MCPToolResult {
        calls.append((name, arguments))
        if arguments["text"] == "refuse" { return .refused("Nope", "refused on purpose") }
        return .ok("echoed", ["text": arguments["text"]])
    }

    func listResources() -> [MCPResourceSpec] {
        [MCPResourceSpec(uri: "stub://one", name: "one", title: "One", description: "", mimeType: "text/plain")]
    }

    func listResourceTemplates() -> [MCPResourceTemplate] { [] }

    func readResource(_ uri: String) async throws -> [MCPResourceContent] {
        guard uri == "stub://one" else { throw MCPError.notFound("no \(uri)") }
        return [MCPResourceContent(uri: uri, mimeType: "text/plain", text: "hello")]
    }

    func listPrompts() -> [MCPPromptSpec] {
        [MCPPromptSpec(name: "greet", title: "Greet", description: "", arguments: [.init(name: "who", description: "", required: true)])]
    }

    func getPrompt(_ name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        MCPPromptResult(description: "greeting", messages: [("user", "hello \(arguments["who"] ?? "?")")])
    }

    func complete(refType: String, refName: String, argument: String, value: String) -> [String] {
        ["alpha", "beta"].filter { $0.hasPrefix(value) }
    }
}

final class MCPProtocolTests: XCTestCase {
    private var stub: StubMCPService!
    private var sent: [JSON] = []
    private var server: MCPServer!

    override func setUp() {
        stub = StubMCPService()
        let box = SentBox()
        sentBox = box
        server = MCPServer(service: stub, send: { box.append($0) })
    }

    private final class SentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [JSON] = []
        func append(_ j: JSON) { lock.lock(); items.append(j); lock.unlock() }
        var all: [JSON] { lock.lock(); defer { lock.unlock() }; return items }
    }
    private var sentBox: SentBox!

    private func request(_ id: Int, _ method: String, _ params: JSON = .null) async -> JSON {
        var msg: [String: JSON] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
        if !params.isNull { msg["params"] = params }
        return await server.handle(.object(msg)) ?? .null
    }

    func testInitializeNegotiatesTheProtocolVersion() async {
        let echoed = await request(1, "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "0"]])
        XCTAssertEqual(echoed["result"]["protocolVersion"], "2025-03-26", "a supported older version is echoed")
        let unknown = await request(2, "initialize", ["protocolVersion": "2099-01-01", "capabilities": [:]])
        XCTAssertEqual(unknown["result"]["protocolVersion"], .string(MCPServer.latestLegacyProtocolVersion), "an unknown version gets the newest legacy revision")
        XCTAssertEqual(unknown["result"]["capabilities"]["resources"]["subscribe"], true)
        XCTAssertEqual(unknown["result"]["capabilities"]["resources"]["listChanged"], true)
        XCTAssertFalse(unknown["result"]["capabilities"]["tools"].isNull)
        XCTAssertFalse(unknown["result"]["capabilities"]["prompts"].isNull)
        XCTAssertEqual(unknown["result"]["serverInfo"]["name"], "stub")
        XCTAssertEqual(unknown["result"]["instructions"], "stub instructions")
        XCTAssertEqual(unknown["id"], 2)
        XCTAssertEqual(unknown["jsonrpc"], "2.0")
    }

    func testNotificationsGetNoReplyAndMarkInitialized() async {
        let initialized = await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(initialized)
        let flag = await server.initialized
        XCTAssertTrue(flag)
        let ping = await request(3, "ping")
        XCTAssertEqual(ping["result"], [:])
    }

    func testMalformedRequestsAreProtocolErrors() async {
        let batch = await server.handle(.array([["jsonrpc": "2.0", "id": 1, "method": "ping"]]))
        XCTAssertEqual(batch?["error"]["code"], .int(MCPError.invalidRequest))
        let noVersion = await server.handle(["id": 4, "method": "ping"])
        XCTAssertEqual(noVersion?["error"]["code"], .int(MCPError.invalidRequest))
        let unknown = await request(5, "nope")
        XCTAssertEqual(unknown["error"]["code"], .int(MCPError.methodNotFound))
        let noName = await request(6, "tools/call", [:])
        XCTAssertEqual(noName["error"]["code"], .int(MCPError.invalidParams))
        let unknownTool = await request(7, "tools/call", ["name": "ghost"])
        XCTAssertEqual(unknownTool["error"]["code"], .int(MCPError.invalidParams))
        let badArgs = await request(8, "tools/call", ["name": "echo", "arguments": "text"])
        XCTAssertEqual(badArgs["error"]["code"], .int(MCPError.invalidParams))
        XCTAssertTrue(stub.calls.isEmpty, "nothing malformed reached the service")
    }

    func testToolCallsCarryStructuredContentAndToolErrorsAreResults() async {
        let list = await request(9, "tools/list")
        XCTAssertEqual(list["result"]["tools"][0]["name"], "echo")
        XCTAssertEqual(list["result"]["tools"][0]["annotations"]["readOnlyHint"], true)
        XCTAssertFalse(list["result"]["tools"][0]["outputSchema"].isNull)

        let ok = await request(10, "tools/call", ["name": "echo", "arguments": ["text": "hi"]])
        XCTAssertEqual(ok["result"]["isError"], false)
        XCTAssertEqual(ok["result"]["structuredContent"]["text"], "hi")
        XCTAssertEqual(ok["result"]["content"][0]["type"], "text")
        XCTAssertEqual(ok["result"]["content"][0]["text"], "echoed")

        let noArgs = await request(11, "tools/call", ["name": "echo"])
        XCTAssertEqual(noArgs["result"]["isError"], false, "missing arguments defaults to an empty object")

        let refused = await request(12, "tools/call", ["name": "echo", "arguments": ["text": "refuse"]])
        XCTAssertTrue(refused["error"].isNull, "a tool refusal is a result, not a protocol error")
        XCTAssertEqual(refused["result"]["isError"], true)
        XCTAssertEqual(refused["result"]["structuredContent"]["error"]["code"], "Nope")
        XCTAssertEqual(refused["result"]["content"][0]["text"], "Nope: refused on purpose")
    }

    func testResourcesSubscribeAndNotify() async {
        // A legacy session: list_changed is only emitted once the handshake selected it.
        _ = await request(12, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])
        let list = await request(13, "resources/list")
        XCTAssertEqual(list["result"]["resources"][0]["uri"], "stub://one")
        let read = await request(14, "resources/read", ["uri": "stub://one"])
        XCTAssertEqual(read["result"]["contents"][0]["text"], "hello")
        let missing = await request(15, "resources/read", ["uri": "stub://two"])
        XCTAssertEqual(missing["error"]["code"], .int(MCPError.resourceNotFound))

        let badSubscribe = await request(16, "resources/subscribe", ["uri": "stub://two"])
        XCTAssertEqual(badSubscribe["error"]["code"], .int(MCPError.resourceNotFound), "cannot subscribe to what does not exist")
        let subscribe = await request(17, "resources/subscribe", ["uri": "stub://one"])
        XCTAssertEqual(subscribe["result"], [:])

        await server.resourcesUpdated(["stub://one", "stub://other"])
        await server.resourceListChanged()
        let all = sentBox.all
        XCTAssertEqual(all.count, 2, "\(all)")
        XCTAssertEqual(all[0]["method"], "notifications/resources/updated")
        XCTAssertEqual(all[0]["params"]["uri"], "stub://one")
        XCTAssertEqual(all[1]["method"], "notifications/resources/list_changed")

        _ = await request(18, "resources/unsubscribe", ["uri": "stub://one"])
        await server.resourcesUpdated(["stub://one"])
        XCTAssertEqual(sentBox.all.count, 2, "nothing after unsubscribe")
    }

    func testPromptsLoggingAndCompletion() async {
        let prompts = await request(19, "prompts/list")
        XCTAssertEqual(prompts["result"]["prompts"][0]["arguments"][0]["required"], true)
        let get = await request(20, "prompts/get", ["name": "greet", "arguments": ["who": "tower"]])
        XCTAssertEqual(get["result"]["messages"][0]["content"]["text"], "hello tower")
        XCTAssertEqual(get["result"]["messages"][0]["role"], "user")

        _ = await request(21, "logging/setLevel", ["level": "warning"])
        await server.log("info", "quiet")
        await server.log("error", "loud")
        let all = sentBox.all
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0]["params"]["level"], "error")
        XCTAssertEqual(all[0]["params"]["data"], "loud")

        let complete = await request(22, "completion/complete", [
            "ref": ["type": "ref/prompt", "name": "greet"], "argument": ["name": "who", "value": "al"],
        ])
        XCTAssertEqual(complete["result"]["completion"]["values"], ["alpha"])
        XCTAssertEqual(complete["result"]["completion"]["hasMore"], false)
    }

    func testJSONRoundTripsAndKeepsBooleansApartFromNumbers() throws {
        let value: JSON = ["b": true, "n": 1, "f": 1.5, "s": "x", "a": [.null, 2], "o": ["k": false]]
        let parsed = try JSON.parse(value.encoded())
        XCTAssertEqual(parsed, value)
        XCTAssertEqual(parsed["b"].boolValue, true)
        XCTAssertNil(parsed["b"].doubleValue)
        XCTAssertEqual(parsed["n"].intValue, 1)
        XCTAssertNil(parsed["f"].intValue)
        XCTAssertEqual(value.text, #"{"a":[null,2],"b":true,"f":1.5,"n":1,"o":{"k":false},"s":"x"}"#)
    }

    func testSchemaCheckCatchesTheMistakesItExistsFor() {
        let schema: JSON = [
            "type": "object", "required": ["a", "b"],
            "properties": ["a": ["type": "integer"], "b": ["type": ["string", "null"]], "c": ["type": "string", "enum": ["x"]],
                           "list": ["type": "array", "items": ["type": "number"]]],
        ]
        XCTAssertTrue(JSONSchemaCheck.validate(["a": 1, "b": .null, "c": "x", "list": [1, 2]], against: schema).isEmpty)
        let bad = JSONSchemaCheck.validate(["a": 1.5, "c": "y", "list": ["no"]], against: schema)
        XCTAssertEqual(Set(bad.map(\.path)), ["$.a", "$", "$.c", "$.list[0]"])
    }

    // MARK: 2026-07-28, the modern era

    private func modern(_ id: Int, _ method: String, _ params: [String: JSON] = [:], version: String = "2026-07-28",
                        capabilities: JSON = [:]) async -> JSON {
        var p = params
        var meta: [String: JSON] = [MCPServer.metaVersion: .string(version), MCPServer.metaClientInfo: ["name": "t", "version": "0"]]
        if !capabilities.isNull { meta[MCPServer.metaClientCapabilities] = capabilities }
        p["_meta"] = .object(meta)
        return await server.handle(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(p)]) ?? .null
    }

    func testDiscoverAndPerRequestVersioning() async {
        let discover = await modern(1, "server/discover")
        XCTAssertEqual(discover["result"]["resultType"], "complete")
        XCTAssertEqual(discover["result"]["supportedVersions"], ["2026-07-28"])
        XCTAssertEqual(discover["result"]["_meta"][MCPServer.metaServerInfo]["name"], "stub")
        XCTAssertEqual(discover["result"]["instructions"], "stub instructions")
        XCTAssertEqual(discover["result"]["cacheScope"], "private")
        XCTAssertNotNil(discover["result"]["ttlMs"].intValue)
        XCTAssertTrue(discover["result"]["capabilities"]["logging"].isNull, "logging is deprecated in 2026-07-28")

        let unsupported = await modern(2, "tools/list", version: "2031-01-01")
        XCTAssertEqual(unsupported["error"]["code"], .int(MCPError.unsupportedProtocolVersion))
        XCTAssertEqual(unsupported["error"]["data"]["supported"], ["2026-07-28"])
        XCTAssertEqual(unsupported["error"]["data"]["requested"], "2031-01-01")

        let noCapabilities = await modern(3, "tools/list", capabilities: .null)
        XCTAssertEqual(noCapabilities["error"]["code"], .int(MCPError.invalidParams), "clientCapabilities is required on every request")

        let legacyMethod = await modern(4, "ping")
        XCTAssertEqual(legacyMethod["error"]["code"], .int(MCPError.methodNotFound), "ping was removed in 2026-07-28")
        let initialize = await modern(5, "initialize")
        XCTAssertEqual(initialize["error"]["code"], .int(MCPError.methodNotFound))

        // The stdio era probe from a legacy-only client shape: no _meta, so the
        // server names the fix instead of a bare method not found.
        let probe = await request(6, "server/discover", [:])
        XCTAssertEqual(probe["error"]["code"], .int(MCPError.invalidParams))
        XCTAssertTrue(probe["error"]["message"].stringValue!.contains("initialize"))
    }

    func testModernResultsCarryResultTypeCachingAndServerInfo() async {
        let tools = await modern(7, "tools/list")
        XCTAssertEqual(tools["result"]["resultType"], "complete")
        XCTAssertEqual(tools["result"]["cacheScope"], "private")
        XCTAssertEqual(tools["result"]["ttlMs"], 3_600_000)
        XCTAssertEqual(tools["result"]["tools"][0]["name"], "echo")
        XCTAssertEqual(tools["result"]["_meta"][MCPServer.metaServerInfo]["version"], "0")

        let call = await modern(8, "tools/call", ["name": "echo", "arguments": ["text": "hi"]])
        XCTAssertEqual(call["result"]["resultType"], "complete")
        XCTAssertEqual(call["result"]["structuredContent"]["text"], "hi")
        XCTAssertEqual(call["result"]["isError"], false)
        XCTAssertTrue(call["result"]["ttlMs"].isNull, "a tool call is not cacheable")

        let read = await modern(9, "resources/read", ["uri": "stub://one"])
        XCTAssertEqual(read["result"]["contents"][0]["text"], "hello")
        XCTAssertEqual(read["result"]["ttlMs"], 5_000)
        let missing = await modern(10, "resources/read", ["uri": "stub://two"])
        XCTAssertEqual(missing["error"]["code"], .int(MCPError.invalidParams), "resource not found is -32602 from 2026-07-28")
        let legacyMissing = await request(11, "resources/read", ["uri": "stub://two"])
        XCTAssertEqual(legacyMissing["error"]["code"], .int(MCPError.resourceNotFound), "and stays -32002 for a legacy client")

        let prompt = await modern(12, "prompts/get", ["name": "greet", "arguments": ["who": "x"]])
        XCTAssertEqual(prompt["result"]["messages"][0]["content"]["text"], "hello x")
        XCTAssertEqual(prompt["result"]["resultType"], "complete")
    }

    func testSubscriptionsListenAcknowledgesTagsAndCloses() async {
        let deferred = await modern(20, "subscriptions/listen", [
            "notifications": ["resourcesListChanged": true, "resourceSubscriptions": ["stub://one"], "toolsListChanged": true],
        ])
        XCTAssertEqual(deferred, .null, "the listen response is deferred until the stream closes")
        let ack = sentBox.all
        XCTAssertEqual(ack.count, 1)
        XCTAssertEqual(ack[0]["method"], "notifications/subscriptions/acknowledged")
        XCTAssertEqual(ack[0]["params"]["_meta"][MCPServer.metaSubscriptionID], 20)
        XCTAssertEqual(ack[0]["params"]["notifications"]["resourceSubscriptions"], ["stub://one"])
        XCTAssertEqual(ack[0]["params"]["notifications"]["resourcesListChanged"], true)
        XCTAssertTrue(ack[0]["params"]["notifications"]["toolsListChanged"].isNull, "the catalogue never changes, so the type is not honoured")

        await server.resourcesUpdated(["stub://one", "stub://other"])
        await server.resourceListChanged()
        var all = sentBox.all
        XCTAssertEqual(all.count, 3, "\(all)")
        XCTAssertEqual(all[1]["method"], "notifications/resources/updated")
        XCTAssertEqual(all[1]["params"]["uri"], "stub://one")
        XCTAssertEqual(all[1]["params"]["_meta"][MCPServer.metaSubscriptionID], 20)
        XCTAssertEqual(all[2]["method"], "notifications/resources/list_changed")
        XCTAssertEqual(all[2]["params"]["_meta"][MCPServer.metaSubscriptionID], 20)

        // A second stream on another id is demultiplexed by its own id.
        _ = await modern(21, "subscriptions/listen", ["notifications": ["resourceSubscriptions": ["stub://one"]]])
        await server.resourcesUpdated(["stub://one"])
        all = sentBox.all
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(Set(all.suffix(2).map { $0["params"]["_meta"][MCPServer.metaSubscriptionID] }), [20, 21])

        // Cancellation ends a stream silently.
        _ = await server.handle(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 21]])
        await server.resourcesUpdated(["stub://one"])
        all = sentBox.all
        XCTAssertEqual(all.count, 7)
        XCTAssertEqual(all[6]["params"]["_meta"][MCPServer.metaSubscriptionID], 20)

        // Shutdown answers the deferred request so the client knows it closed cleanly.
        await server.shutdown()
        all = sentBox.all
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(all[7]["id"], 20)
        XCTAssertEqual(all[7]["result"]["resultType"], "complete")
        XCTAssertEqual(all[7]["result"]["_meta"][MCPServer.metaSubscriptionID], 20)
        await server.resourcesUpdated(["stub://one"])
        XCTAssertEqual(sentBox.all.count, 8, "nothing after closure")
    }
}
