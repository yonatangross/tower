import Foundation

/// A JSON value the MCP layer can build, compare and serialise without `Any`.
///
/// Foundation's `JSONSerialization` hands back `Any` trees that Swift 6 cannot send
/// across actors and that tests cannot compare. This enum is the one shape every tool
/// result, schema, resource body and prompt message passes through, so a test can
/// assert on structure and the transport can encode it deterministically.
indirect enum JSON: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Building

    static func int(_ v: Int) -> JSON { .number(Double(v)) }

    /// Optional convenience: nil becomes JSON null rather than a missing key, so a
    /// consumer reading the schema sees every declared field every time.
    static func string(_ v: String?) -> JSON { v.map { .string($0) } ?? .null }
    static func number(_ v: Double?) -> JSON { v.map { .number($0) } ?? .null }
    static func bool(_ v: Bool?) -> JSON { v.map { .bool($0) } ?? .null }
    static func date(_ d: Date?) -> JSON { d.map { .string(Self.iso.string(from: $0)) } ?? .null }

    /// ISO 8601 with fractional seconds, UTC. One formatter, one wire shape.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Reading

    var isNull: Bool { if case .null = self { return true }; return false }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < 9e15 else { return nil }
        return Int(n)
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSON]? { if case .object(let o) = self { return o }; return nil }

    subscript(key: String) -> JSON {
        guard case .object(let o) = self else { return .null }
        return o[key] ?? .null
    }

    subscript(index: Int) -> JSON {
        guard case .array(let a) = self, a.indices.contains(index) else { return .null }
        return a[index]
    }

    // MARK: Foundation bridge

    /// From a `JSONSerialization` tree. Unknown leaves (which Foundation never
    /// produces) become null rather than trapping.
    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let b as Bool where Self.isBoolNumber(any): self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    /// NSNumber carries both booleans and numbers; `true` must not read as 1.
    private static func isBoolNumber(_ any: Any) -> Bool {
        guard let n = any as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            // Integral values serialise without a fractional part so a consumer that
            // declares `integer` in a schema reads `70`, not `70.0`.
            if n.rounded() == n, abs(n) < 9e15 { return Int(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    static func parse(_ data: Data) throws -> JSON {
        JSON(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Compact by default; sorted keys always, so two encodings of one value are
    /// byte identical and a test can compare them.
    func encoded(pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        // A JSON enum can only hold serialisable leaves, so this cannot throw.
        return (try? JSONSerialization.data(withJSONObject: anyValue, options: options)) ?? Data()
    }

    var text: String { String(decoding: encoded(), as: UTF8.self) }
    var prettyText: String { String(decoding: encoded(pretty: true), as: UTF8.self) }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// The handful of JSON Schema checks the tests and the server apply to their own
/// payloads: type, required keys, enum, and nested properties and items. This is not
/// a full validator; it is enough to prove every `structuredContent` a tool returns
/// matches the `outputSchema` it advertised, which is the contract a conductor reads.
enum JSONSchemaCheck {
    struct Failure: Error, CustomStringConvertible {
        let path: String
        let reason: String
        var description: String { "\(path): \(reason)" }
    }

    static func validate(_ value: JSON, against schema: JSON, path: String = "$") -> [Failure] {
        var out: [Failure] = []
        if let types = schema["type"].arrayValue?.compactMap(\.stringValue), !types.isEmpty {
            if !types.contains(where: { matches(value, type: $0) }) {
                out.append(Failure(path: path, reason: "expected one of \(types)"))
                return out
            }
        } else if let type = schema["type"].stringValue {
            if !matches(value, type: type) {
                out.append(Failure(path: path, reason: "expected \(type), got \(kind(of: value))"))
                return out
            }
        }
        if let allowed = schema["enum"].arrayValue, !allowed.contains(value) {
            out.append(Failure(path: path, reason: "not in enum"))
        }
        if case .object(let o) = value {
            for key in schema["required"].arrayValue?.compactMap(\.stringValue) ?? [] where o[key] == nil {
                out.append(Failure(path: path, reason: "missing required key \(key)"))
            }
            if let props = schema["properties"].objectValue {
                for (key, sub) in props {
                    if let v = o[key] { out += validate(v, against: sub, path: "\(path).\(key)") }
                }
                if schema["additionalProperties"] == .bool(false) {
                    for key in o.keys where props[key] == nil {
                        out.append(Failure(path: path, reason: "unexpected key \(key)"))
                    }
                }
            }
        }
        if case .array(let a) = value, !schema["items"].isNull {
            for (i, item) in a.enumerated() {
                out += validate(item, against: schema["items"], path: "\(path)[\(i)]")
            }
        }
        return out
    }

    private static func matches(_ value: JSON, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string),
             ("array", .array), ("object", .object), ("number", .number):
            return true
        case ("integer", .number(let n)):
            return n.rounded() == n
        default:
            return false
        }
    }

    private static func kind(of value: JSON) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
