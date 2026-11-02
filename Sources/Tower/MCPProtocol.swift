import Foundation

// MARK: - Wire types
//
// The MCP specification (revision 2025-06-18) over JSON-RPC 2.0. Shapes mirror the
// official Swift SDK's types by name (Tool, Tool.Annotations, CallTool.Result,
// Resource, Prompt) so a later swap to the SDK is a rename, not a redesign. The SDK
// itself is not linked: at 0.12.1 it pulls swift-nio and an unpinned branch of
// swift-docc-plugin into a package that has no dependencies today, and it cannot
// be linked by the CLT shim runner this repo tests with. docs/mcp-surface.md
// carries the reasoning under "Sources".

/// A tool as advertised by `tools/list`.
struct MCPToolSpec: Equatable, Sendable {
    struct Annotations: Equatable, Sendable {
        var title: String?
        var readOnlyHint: Bool
        var destructiveHint: Bool
        var idempotentHint: Bool
        var openWorldHint: Bool

        /// The spec defaults: a tool is assumed to write, destructively, non
        /// idempotently, against an open world. Reads override every one of them.
        static let read = Annotations(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

        var json: JSON {
            [
                "title": .string(title),
                "readOnlyHint": .bool(readOnlyHint),
                "destructiveHint": .bool(destructiveHint),
                "idempotentHint": .bool(idempotentHint),
                "openWorldHint": .bool(openWorldHint),
            ]
        }
    }

    let name: String
    let title: String
    let description: String
    let inputSchema: JSON
    let outputSchema: JSON
    let annotations: Annotations

    var json: JSON {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "outputSchema": outputSchema,
            "annotations": annotations.json,
        ]
    }
}

/// What `tools/call` returns. A refused write is a result with `isError`, never a
/// JSON-RPC error: the spec reserves protocol errors for malformed requests, and a
/// client that cannot read a tool error as data cannot read the reason either.
struct MCPToolResult: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case text(String)
        case image(base64: String, mimeType: String)

        var json: JSON {
            switch self {
            case .text(let t): return ["type": "text", "text": .string(t)]
            case .image(let data, let mime):
                return ["type": "image", "data": .string(data), "mimeType": .string(mime)]
            }
        }
    }

    var content: [Content]
    var structuredContent: JSON?
    var isError: Bool

    init(content: [Content], structuredContent: JSON? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    /// The normal shape: a one line summary a human can read, and the structured
    /// payload a conductor parses. Both carry the same facts.
    static func ok(_ summary: String, _ structured: JSON) -> MCPToolResult {
        MCPToolResult(content: [.text(summary)], structuredContent: structured)
    }

    /// A named refusal: the code leads the text and sits in `structuredContent.error`.
    static func refused(_ code: String, _ message: String, extra: [String: JSON] = [:]) -> MCPToolResult {
        var error: [String: JSON] = ["code": .string(code), "message": .string(message)]
        for (k, v) in extra { error[k] = v }
        return MCPToolResult(
            content: [.text("\(code): \(message)")],
            structuredContent: ["error": .object(error)],
            isError: true)
    }

    var json: JSON {
        var out: [String: JSON] = [
            "content": .array(content.map(\.json)),
            "isError": .bool(isError),
        ]
        if let structuredContent { out["structuredContent"] = structuredContent }
        return .object(out)
    }
}

struct MCPResourceSpec: Equatable, Sendable {
    let uri: String
    let name: String
    let title: String
    let description: String
    let mimeType: String

    var json: JSON {
        [
            "uri": .string(uri), "name": .string(name), "title": .string(title),
            "description": .string(description), "mimeType": .string(mimeType),
        ]
    }
}

struct MCPResourceTemplate: Equatable, Sendable {
    let uriTemplate: String
    let name: String
    let title: String
    let description: String
    let mimeType: String

    var json: JSON {
        [
            "uriTemplate": .string(uriTemplate), "name": .string(name), "title": .string(title),
            "description": .string(description), "mimeType": .string(mimeType),
        ]
    }
}

struct MCPResourceContent: Equatable, Sendable {
    let uri: String
    let mimeType: String
    let text: String

    var json: JSON { ["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)] }
}

struct MCPPromptSpec: Equatable, Sendable {
    struct Argument: Equatable, Sendable {
        let name: String
        let description: String
        let required: Bool
        var json: JSON {
            ["name": .string(name), "description": .string(description), "required": .bool(required)]
        }
    }

    let name: String
    let title: String
    let description: String
    let arguments: [Argument]

    var json: JSON {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "arguments": .array(arguments.map(\.json)),
        ]
    }
}

struct MCPPromptResult: Equatable, Sendable {
    let description: String
    /// (role, text) pairs; every message here is text.
    let messages: [(role: String, text: String)]

    static func == (a: MCPPromptResult, b: MCPPromptResult) -> Bool {
        a.description == b.description
            && a.messages.map { "\($0.role):\($0.text)" } == b.messages.map { "\($0.role):\($0.text)" }
    }

    var json: JSON {
        [
            "description": .string(description),
            "messages": .array(messages.map {
                ["role": .string($0.role), "content": ["type": "text", "text": .string($0.text)]]
            }),
        ]
    }
}

/// A JSON-RPC level failure. Only malformed or unknown requests reach here; a tool's
/// own refusal travels as an `MCPToolResult` with `isError`.
struct MCPError: Error, Equatable, Sendable {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// Unknown resource URI: `-32002` through 2025-11-25, `-32602` from 2026-07-28 on.
    /// The service throws this code; the server rewrites it for a modern request.
    static let resourceNotFound = -32002
    /// 2026-07-28 reserved codes.
    static let unsupportedProtocolVersion = -32022

    let code: Int
    let message: String
    var data: JSON = .null

    static func invalidParams(_ m: String) -> MCPError { MCPError(code: invalidParams, message: m) }
    static func notFound(_ m: String) -> MCPError { MCPError(code: resourceNotFound, message: m) }
}

/// What a server exposes. `TowerMCPService` is the one implementation; the protocol
/// exists so the JSON-RPC layer is testable with a stub and so the surface is one
/// type a test can walk.
protocol MCPService: Sendable {
    var serverName: String { get }
    var serverVersion: String { get }
    var instructions: String { get }

    func listTools() -> [MCPToolSpec]
    func callTool(_ name: String, arguments: JSON) async throws -> MCPToolResult
    func listResources() -> [MCPResourceSpec]
    func listResourceTemplates() -> [MCPResourceTemplate]
    func readResource(_ uri: String) async throws -> [MCPResourceContent]
    func listPrompts() -> [MCPPromptSpec]
    func getPrompt(_ name: String, arguments: [String: String]) async throws -> MCPPromptResult
    /// Completion candidates for a prompt argument or a resource template variable.
    func complete(refType: String, refName: String, argument: String, value: String) -> [String]
}

// MARK: - Server

/// One MCP server over one transport, dual era (spec 2026-07-28, "Versioning and
/// Compatibility"):
///
/// - A request carrying `_meta["io.modelcontextprotocol/protocolVersion"]` is modern
///   (2026-07-28): served statelessly, every result stamped `resultType` and the
///   server identity, list results carrying `ttlMs` and `cacheScope`, subscriptions
///   through `subscriptions/listen`, an unknown resource `-32602`, an unsupported
///   version `-32022` with the supported list.
/// - An `initialize` request selects the legacy handshake (2025-11-25 and earlier)
///   for the life of the process: `ping`, `logging/setLevel`, `resources/subscribe`,
///   an unknown resource `-32002`.
///
/// Writing is funnelled through `send` so notifications raised by the watcher and
/// responses raised by request tasks never interleave on the pipe.
actor MCPServer {
    /// Modern versions, newest first. `supportedVersions` in `server/discover`.
    static let modernProtocolVersions = ["2026-07-28"]
    /// Legacy versions, newest first. An `initialize` naming one of these is echoed;
    /// any other value is answered with the newest legacy version.
    static let legacyProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var latestProtocolVersion: String { modernProtocolVersions[0] }
    static var latestLegacyProtocolVersion: String { legacyProtocolVersions[0] }
    /// The reserved `_meta` keys, spelled once.
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaClientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"
    static let metaSubscriptionID = "io.modelcontextprotocol/subscriptionId"

    /// What one `subscriptions/listen` asked for, keyed by its request id.
    struct ListenSubscription: Equatable {
        var resourcesListChanged: Bool
        var resourceSubscriptions: [String]
    }

    let service: any MCPService
    private let send: @Sendable (JSON) -> Void
    private(set) var initialized = false
    private(set) var negotiatedVersion: String?
    /// Legacy `resources/subscribe` URIs.
    private(set) var subscriptions: Set<String> = []
    /// Modern `subscriptions/listen` streams, keyed by the JSON-RPC id that opened them.
    private(set) var listeners: [JSON: ListenSubscription] = [:]
    private(set) var logLevel = "info"

    init(service: any MCPService, send: @escaping @Sendable (JSON) -> Void) {
        self.service = service
        self.send = send
    }

    var legacyCapabilities: JSON {
        [
            "tools": ["listChanged": false],
            "resources": ["subscribe": true, "listChanged": true],
            "prompts": ["listChanged": false],
            "logging": [:],
            "completions": [:],
        ]
    }

    /// Modern capabilities: no logging (deprecated in 2026-07-28, stderr is the sink),
    /// subscriptions through `subscriptions/listen`.
    var modernCapabilities: JSON {
        [
            "tools": ["listChanged": false],
            "resources": ["subscribe": true, "listChanged": true],
            "prompts": ["listChanged": false],
            "completions": [:],
        ]
    }

    var serverInfo: JSON {
        ["name": .string(service.serverName), "version": .string(service.serverVersion)]
    }

    /// Handles one inbound message. Returns the response to write, or nil for a
    /// notification (which has no id and gets no reply) and for a modern
    /// `subscriptions/listen`, whose response is deferred until the stream closes.
    func handle(_ message: JSON) async -> JSON? {
        guard case .object = message else {
            return Self.errorResponse(id: .null, MCPError(
                code: MCPError.invalidRequest,
                message: "expected a JSON object; JSON-RPC batches were removed in 2025-06-18"))
        }
        let id = message["id"]
        let isNotification = message["id"].isNull && message["method"].stringValue?.hasPrefix("notifications/") == true
        guard message["jsonrpc"] == "2.0", let method = message["method"].stringValue else {
            if isNotification { return nil }
            return Self.errorResponse(id: id, MCPError(code: MCPError.invalidRequest, message: "missing jsonrpc 2.0 or method"))
        }
        let params = message["params"]
        if isNotification {
            handleNotification(method, params: params)
            return nil
        }
        let meta = params["_meta"]
        if !meta[Self.metaVersion].isNull {
            return await handleModern(id: id, method: method, params: params, meta: meta)
        }
        do {
            let result = try await dispatchLegacy(method, params: params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as MCPError {
            return Self.errorResponse(id: id, error)
        } catch {
            return Self.errorResponse(id: id, MCPError(code: MCPError.internalError, message: String(describing: error)))
        }
    }

    static func errorResponse(id: JSON, _ error: MCPError) -> JSON {
        var body: [String: JSON] = ["code": .int(error.code), "message": .string(error.message)]
        if !error.data.isNull { body["data"] = error.data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(body)]
    }

    private func handleNotification(_ method: String, params: JSON) {
        switch method {
        case "notifications/initialized":
            initialized = true
        case "notifications/cancelled":
            // A cancelled `subscriptions/listen` ends silently: no response, no
            // further messages for it (stdio binding, "Cancellation").
            let requestId = params["requestId"]
            listeners.removeValue(forKey: requestId)
        default:
            break
        }
    }

    // MARK: Modern era (2026-07-28)

    private func handleModern(id: JSON, method: String, params: JSON, meta: JSON) async -> JSON? {
        let requested = meta[Self.metaVersion].stringValue ?? ""
        guard Self.modernProtocolVersions.contains(requested) else {
            return Self.errorResponse(id: id, MCPError(
                code: MCPError.unsupportedProtocolVersion, message: "Unsupported protocol version",
                data: ["supported": .array(Self.modernProtocolVersions.map { .string($0) }), "requested": .string(requested)]))
        }
        guard case .object = meta[Self.metaClientCapabilities] else {
            return Self.errorResponse(id: id, MCPError.invalidParams(
                "_meta is missing the required key \(Self.metaClientCapabilities)"))
        }
        if method == "subscriptions/listen" {
            listen(id: id, params: params)
            return nil
        }
        do {
            var result = try await dispatchModern(method, params: params)
            result["resultType"] = "complete"
            var resultMeta = result["_meta"]?.objectValue ?? [:]
            resultMeta[Self.metaServerInfo] = serverInfo
            result["_meta"] = .object(resultMeta)
            return ["jsonrpc": "2.0", "id": id, "result": .object(result)]
        } catch var error as MCPError {
            if error.code == MCPError.resourceNotFound { error = MCPError(code: MCPError.invalidParams, message: error.message) }
            return Self.errorResponse(id: id, error)
        } catch {
            return Self.errorResponse(id: id, MCPError(code: MCPError.internalError, message: String(describing: error)))
        }
    }

    /// `ttlMs` and `cacheScope`, required on every cacheable result. The catalogue is
    /// static for the life of the binary; the account list and the cache change with
    /// every poll, so they advertise short lives.
    private static func cacheable(_ result: [String: JSON], ttlMs: Int) -> [String: JSON] {
        var out = result
        out["ttlMs"] = .int(ttlMs)
        out["cacheScope"] = "private"
        return out
    }

    private func dispatchModern(_ method: String, params: JSON) async throws -> [String: JSON] {
        switch method {
        case "server/discover":
            return Self.cacheable([
                "supportedVersions": .array(Self.modernProtocolVersions.map { .string($0) }),
                "capabilities": modernCapabilities,
                "instructions": .string(service.instructions),
            ], ttlMs: 3_600_000)
        case "tools/list":
            return Self.cacheable(["tools": .array(service.listTools().map(\.json))], ttlMs: 3_600_000)
        case "tools/call":
            return try await callTool(params).json.objectValue ?? [:]
        case "resources/list":
            return Self.cacheable(["resources": .array(service.listResources().map(\.json))], ttlMs: 60_000)
        case "resources/templates/list":
            return Self.cacheable(["resourceTemplates": .array(service.listResourceTemplates().map(\.json))], ttlMs: 3_600_000)
        case "resources/read":
            guard let uri = params["uri"].stringValue else { throw MCPError.invalidParams("uri is required") }
            return Self.cacheable(["contents": .array(try await service.readResource(uri).map(\.json))], ttlMs: 5_000)
        case "prompts/list":
            return Self.cacheable(["prompts": .array(service.listPrompts().map(\.json))], ttlMs: 3_600_000)
        case "prompts/get":
            return try await getPrompt(params).json.objectValue ?? [:]
        case "completion/complete":
            return complete(params)
        case "initialize", "ping", "logging/setLevel", "resources/subscribe", "resources/unsubscribe":
            throw MCPError(code: MCPError.methodNotFound,
                           message: "\(method) is a legacy method; 2026-07-28 removed it (use server/discover and subscriptions/listen)")
        default:
            throw MCPError(code: MCPError.methodNotFound, message: "method not found: \(method)")
        }
    }

    /// Opens a modern notification stream: acknowledge first, with the subset honoured
    /// (resource list changes and resource updates; the tool and prompt catalogues
    /// never change, so those types are omitted from the acknowledgement).
    private func listen(id: JSON, params: JSON) {
        let wanted = params["notifications"]
        let subscription = ListenSubscription(
            resourcesListChanged: wanted["resourcesListChanged"].boolValue ?? false,
            resourceSubscriptions: wanted["resourceSubscriptions"].arrayValue?.compactMap(\.stringValue) ?? [])
        listeners[id] = subscription
        var honoured: [String: JSON] = [:]
        if subscription.resourcesListChanged { honoured["resourcesListChanged"] = true }
        if !subscription.resourceSubscriptions.isEmpty {
            honoured["resourceSubscriptions"] = .array(subscription.resourceSubscriptions.map { .string($0) })
        }
        send(["jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
              "params": ["_meta": [Self.metaSubscriptionID: id], "notifications": .object(honoured)]])
    }

    /// Graceful closure on shutdown: every open stream gets its deferred response.
    func shutdown() {
        for id in listeners.keys.sorted(by: { $0.text < $1.text }) {
            send(["jsonrpc": "2.0", "id": id, "result": ["resultType": "complete", "_meta": [Self.metaSubscriptionID: id]]])
        }
        listeners.removeAll()
    }

    // MARK: Legacy era (initialize handshake)

    private func dispatchLegacy(_ method: String, params: JSON) async throws -> JSON {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"].stringValue ?? ""
            let version = Self.legacyProtocolVersions.contains(requested) ? requested : Self.latestLegacyProtocolVersion
            negotiatedVersion = version
            return [
                "protocolVersion": .string(version),
                "capabilities": legacyCapabilities,
                "serverInfo": serverInfo,
                "instructions": .string(service.instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(service.listTools().map(\.json))]
        case "tools/call":
            return try await callTool(params).json
        case "resources/list":
            return ["resources": .array(service.listResources().map(\.json))]
        case "resources/templates/list":
            return ["resourceTemplates": .array(service.listResourceTemplates().map(\.json))]
        case "resources/read":
            guard let uri = params["uri"].stringValue else { throw MCPError.invalidParams("uri is required") }
            return ["contents": .array(try await service.readResource(uri).map(\.json))]
        case "resources/subscribe":
            guard let uri = params["uri"].stringValue else { throw MCPError.invalidParams("uri is required") }
            // Subscribing to an unknown resource is refused up front, so a client does
            // not wait forever on a URI that can never change.
            _ = try await service.readResource(uri)
            subscriptions.insert(uri)
            return [:]
        case "resources/unsubscribe":
            guard let uri = params["uri"].stringValue else { throw MCPError.invalidParams("uri is required") }
            subscriptions.remove(uri)
            return [:]
        case "prompts/list":
            return ["prompts": .array(service.listPrompts().map(\.json))]
        case "prompts/get":
            return try await getPrompt(params).json
        case "logging/setLevel":
            guard let level = params["level"].stringValue else { throw MCPError.invalidParams("level is required") }
            logLevel = level
            return [:]
        case "completion/complete":
            return .object(complete(params))
        case "server/discover", "subscriptions/listen":
            // A modern method without modern `_meta`: name the fix rather than a bare
            // method not found, since this is the stdio era probe.
            throw MCPError.invalidParams(
                "\(method) needs _meta.\(Self.metaVersion) (2026-07-28); this server also answers the legacy initialize handshake")
        default:
            throw MCPError(code: MCPError.methodNotFound, message: "method not found: \(method)")
        }
    }

    // MARK: Shared by both eras

    private func callTool(_ params: JSON) async throws -> MCPToolResult {
        guard let name = params["name"].stringValue else { throw MCPError.invalidParams("name is required") }
        guard service.listTools().contains(where: { $0.name == name }) else {
            throw MCPError.invalidParams("unknown tool \(name)")
        }
        let arguments = params["arguments"].isNull ? JSON.object([:]) : params["arguments"]
        guard case .object = arguments else { throw MCPError.invalidParams("arguments must be an object") }
        return try await service.callTool(name, arguments: arguments)
    }

    private func getPrompt(_ params: JSON) async throws -> MCPPromptResult {
        guard let name = params["name"].stringValue else { throw MCPError.invalidParams("name is required") }
        let args = (params["arguments"].objectValue ?? [:]).compactMapValues(\.stringValue)
        return try await service.getPrompt(name, arguments: args)
    }

    private func complete(_ params: JSON) -> [String: JSON] {
        let ref = params["ref"]
        let refType = ref["type"].stringValue ?? ""
        let refName = ref["name"].stringValue ?? ref["uri"].stringValue ?? ""
        let argument = params["argument"]["name"].stringValue ?? ""
        let value = params["argument"]["value"].stringValue ?? ""
        let values = service.complete(refType: refType, refName: refName, argument: argument, value: value)
        return ["completion": [
            "values": .array(values.prefix(100).map { .string($0) }),
            "total": .int(values.count),
            "hasMore": .bool(values.count > 100),
        ]]
    }

    // MARK: Outbound notifications

    /// `notifications/resources/updated` to every legacy subscriber of the URI and to
    /// every modern stream that listed it, the latter tagged with its subscription id.
    func resourcesUpdated(_ uris: [String]) {
        for uri in uris {
            if subscriptions.contains(uri) {
                send(["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": .string(uri)]])
            }
            for (id, listener) in listeners where listener.resourceSubscriptions.contains(uri) {
                send(["jsonrpc": "2.0", "method": "notifications/resources/updated",
                      "params": ["_meta": [Self.metaSubscriptionID: id], "uri": .string(uri)]])
            }
        }
    }

    func resourceListChanged() {
        if negotiatedVersion != nil {
            send(["jsonrpc": "2.0", "method": "notifications/resources/list_changed"])
        }
        for (id, listener) in listeners where listener.resourcesListChanged {
            send(["jsonrpc": "2.0", "method": "notifications/resources/list_changed",
                  "params": ["_meta": [Self.metaSubscriptionID: id]]])
        }
    }

    /// Legacy `notifications/message`, gated by the level the client asked for. Modern
    /// requests never receive one: 2026-07-28 deprecates logging and names stderr.
    func log(_ level: String, _ data: JSON) {
        let order = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
        guard let want = order.firstIndex(of: logLevel), let have = order.firstIndex(of: level), have >= want else { return }
        send(["jsonrpc": "2.0", "method": "notifications/message",
              "params": ["level": .string(level), "logger": "tower", "data": data]])
    }
}

// MARK: - Stdio transport

/// Newline delimited JSON-RPC on stdin and stdout, the stdio transport the spec
/// describes. stdout carries nothing but messages; every diagnostic goes to stderr,
/// because one stray `print` on stdout corrupts the stream for the client.
enum MCPStdio {
    private static let writeLock = NSLock()

    static func write(_ message: JSON) {
        var data = message.encoded()
        data.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        FileHandle.standardOutput.write(data)
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Reads stdin until EOF, handing each line to the server. Returns when the client
    /// closes the pipe. Each request runs in its own task so a slow refresh cannot
    /// block a ping; responses may therefore arrive out of order, which JSON-RPC allows.
    static func serve(_ server: MCPServer) async {
        let lines = AsyncStream<Data> { continuation in
            let thread = Thread {
                let input = FileHandle.standardInput
                var pending = Data()
                while true {
                    let chunk = input.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<newline]
                        continuation.yield(Data(line))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                if !pending.isEmpty { continuation.yield(pending) }
                continuation.finish()
            }
            thread.name = "mcp-stdin"
            thread.start()
        }
        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                let trimmed = line.filter { $0 != 0x0D && $0 != 0x20 && $0 != 0x09 }
                if trimmed.isEmpty { continue }
                group.addTask {
                    let message: JSON
                    do {
                        message = try JSON.parse(line)
                    } catch {
                        write(MCPServer.errorResponse(id: .null, MCPError(code: MCPError.parseError, message: "parse error")))
                        return
                    }
                    if let response = await server.handle(message) { write(response) }
                }
            }
            await group.waitForAll()
        }
        // stdin closed: close every modern stream gracefully before exiting.
        await server.shutdown()
    }
}
