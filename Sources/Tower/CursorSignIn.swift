import CryptoKit
import Foundation
import LocalAuthentication
import Security

// MARK: - Tower's own Cursor sign-in
//
// Since 2026-10-31 the Cursor app stores an opaque, 603 character value in
// `cursorAuth/accessToken`, byte-identical to its refresh token. Sent as a bearer to the
// usage route it answers 401, and re-signing in Cursor writes the same shape again. So
// Tower stops borrowing the Cursor app's sign-in entirely and keeps its own: a browser
// sign-in with PKCE that hands Tower a JWT, stored in a Tower-owned Keychain item.
// Nothing here reads a token out of the Cursor app, writes to its database, or trades its
// credential, so Tower can never sign anyone out of the Cursor app.
//
// The flow is the one OpenUsage uses (robinebers/openusage, MIT, CursorUsageClient.swift
// and DeviceProviderLogins.swift): open cursor.com/loginDeepControl with a PKCE challenge
// and a uuid, then poll api2.cursor.sh/auth/poll until it answers the token pair. The
// access token is a 60 day JWT; it is renewed at api2.cursor.sh/oauth/token about a week
// before it expires, and that reply carries a new access token that also serves as the
// next refresh token. The OAuth client id below is OpenUsage's public one.

/// The HTTP seam, so every test runs against invented replies and no test ever reaches
/// Cursor. nil means the request never got an answer.
protocol CursorHTTP: Sendable {
    func send(_ request: URLRequest) async -> (status: Int, body: Data)?
}

struct URLSessionCursorHTTP: CursorHTTP {
    func send(_ request: URLRequest) async -> (status: Int, body: Data)? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}

enum CursorSignIn {
    static let authorizeBase = "https://cursor.com/loginDeepControl"
    static let pollBase = "https://api2.cursor.sh/auth/poll"
    static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    /// OpenUsage's public OAuth client id for this flow (MIT, credited above).
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    static let pollInterval: TimeInterval = 2
    static let pollTimeout: TimeInterval = 300
    /// Renew this long before the JWT's `exp`, so a Mac that is off around expiry still
    /// keeps the sign-in alive.
    static let renewLead: TimeInterval = 7 * 86_400

    struct PKCE: Equatable {
        let verifier: String
        let challenge: String
    }

    /// The token pair Tower keeps. Never logged, never shown, never sent anywhere but
    /// Cursor's own API.
    struct Tokens: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// S256: base64url(SHA-256(verifier)), no padding.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A PKCE pair from the given random bytes; tests pass fixed bytes.
    static func pkce(random: [UInt8]) -> PKCE {
        let verifier = base64URL(Data(random))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// A fresh PKCE pair, or nil when the system random source fails: a verifier made of
    /// zero bytes would be guessable, so a failed draw never becomes a sign-in.
    static func newPKCE(fill: (inout [UInt8]) -> OSStatus = { bytes in
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    }) -> PKCE? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard fill(&bytes) == errSecSuccess else { return nil }
        return pkce(random: bytes)
    }

    static func authorizeURL(challenge: String, uuid: String) -> URL {
        var components = URLComponents(string: authorizeBase)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli"),
        ]
        return components.url!
    }

    static func pollRequest(uuid: String, verifier: String) -> URLRequest {
        var components = URLComponents(string: pollBase)!
        components.queryItems = [
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "verifier", value: verifier),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        return request
    }

    enum PollStep: Equatable {
        case pending
        case complete(Tokens)
        case failed(String)
    }

    /// 404 and 202 mean the person has not finished in the browser yet. A 200 must carry
    /// both tokens; anything else is a failed sign-in, never a silent wait.
    static func pollStep(status: Int, body: Data) -> PollStep {
        if status == 404 || status == 202 { return .pending }
        guard (200..<300).contains(status) else { return .failed("Cursor sign-in failed (HTTP \(status)).") }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: body),
              !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty
        else { return .failed("Cursor sign-in answered without a token pair.") }
        return .complete(tokens)
    }

    enum SignInResult: Equatable {
        case signedIn(Tokens)
        case failed(String)
        case timedOut
    }

    static func poll(uuid: String, verifier: String, http: any CursorHTTP,
                     now: @escaping @Sendable () -> Date = Date.init,
                     sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in
                         try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                     },
                     interval: TimeInterval = pollInterval,
                     timeout: TimeInterval = pollTimeout) async -> SignInResult {
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            if let reply = await http.send(pollRequest(uuid: uuid, verifier: verifier)) {
                switch pollStep(status: reply.status, body: reply.body) {
                case .complete(let tokens): return .signedIn(tokens)
                case .failed(let why): return .failed(why)
                case .pending: break
                }
            }
            await sleep(interval)
        }
        return .timedOut
    }

    /// The JWT's `exp`, or nil when the token is not a JWT or carries none.
    static func expiry(of token: String) -> Date? {
        guard let claims = CodexAuth.decodeJWTPayload(token) else { return nil }
        if let n = claims["exp"] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }

    static func needsRenewal(_ tokens: Tokens, now: Date) -> Bool {
        guard let exp = expiry(of: tokens.accessToken) else { return false }
        return exp.addingTimeInterval(-renewLead) <= now
    }

    static func renewRequest(refreshToken: String) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let body = ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    enum RenewResult: Equatable {
        case renewed(Tokens)
        /// Cursor answered `shouldLogout`: the session is over and Tower must connect again.
        case loggedOut
        case failed
    }

    /// Cursor answers a renewal with `access_token` and no refresh token; the new JWT is
    /// also the next refresh token. `shouldLogout` ends Tower's sign-in.
    static func renewResult(status: Int, body: Data) -> RenewResult {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if json?["shouldLogout"] as? Bool == true { return .loggedOut }
        guard (200..<300).contains(status),
              let access = json?["access_token"] as? String, !access.isEmpty else { return .failed }
        let refresh = (json?["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? access
        return .renewed(Tokens(accessToken: access, refreshToken: refresh))
    }
}

// MARK: - Where Tower keeps its own Cursor tokens

protocol CursorTokenStore: Sendable {
    func load() -> CursorSignIn.Tokens?
    @discardableResult func save(_ tokens: CursorSignIn.Tokens) -> Bool
    func clear()
}

/// For tests and demos: holds the pair in memory only.
final class MemoryCursorTokenStore: CursorTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: CursorSignIn.Tokens?
    init(_ tokens: CursorSignIn.Tokens? = nil) { self.tokens = tokens }
    func load() -> CursorSignIn.Tokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    func save(_ tokens: CursorSignIn.Tokens) -> Bool {
        lock.lock(); defer { lock.unlock() }; self.tokens = tokens; return true
    }
    func clear() { lock.lock(); defer { lock.unlock() }; tokens = nil }
}

/// One Tower-owned generic password item. Reads never raise a Keychain dialog (an
/// LAContext with interactionNotAllowed), so a refresh can never prompt; the item is
/// written by Tower itself, so Tower is on its access list from the start.
struct KeychainCursorTokenStore: CursorTokenStore {
    static let shared = KeychainCursorTokenStore()
    static let service = "ai.yonyon.tower.cursor-signin"
    static let account = "cursor"

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() -> CursorSignIn.Tokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = gate.withDialogsOff { ops.read(query, &item) }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CursorSignIn.Tokens.self, from: data)
    }

    /// The Keychain calls `save` makes, injectable so a test can record them. There is no
    /// update call on purpose: writing into an item that already exists would trust its
    /// access list, and another app could have created that item first (item squatting)
    /// to read the token Tower puts in it.
    struct Ops: @unchecked Sendable {
        var delete: ([String: Any]) -> OSStatus
        var add: ([String: Any]) -> OSStatus
        var makeAccess: () -> SecAccess?
        var read: ([String: Any], UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = { query, out in
            SecItemCopyMatching(query as CFDictionary, out)
        }

        static let live = Ops(
            delete: { SecItemDelete($0 as CFDictionary) },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            makeAccess: {
                if case .success(let access) = TowerSeatKeychainAccess.make(descriptor: "Tower Cursor sign-in") {
                    return access
                }
                return nil
            })
    }

    var ops: Ops = .live
    /// Every call on this item runs with Keychain dialogs off, inside the same window as a
    /// seat Re-trust (KeychainDialogGate). The LAContext on `load` alone does not stop a
    /// legacy keychain dialog.
    var gate: KeychainDialogGate = .shared

    /// Delete any item under this name, whoever made it, then add a fresh one whose access
    /// list trusts Tower only. No Tower access list (a bare development binary) fails
    /// closed: nothing is written.
    func save(_ tokens: CursorSignIn.Tokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens),
              let access = ops.makeAccess() else { return false }
        return gate.withDialogsOff {
            let deleted = ops.delete(baseQuery())
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return false }
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Tower Cursor sign-in"
            add[kSecAttrAccess as String] = access
            return ops.add(add) == errSecSuccess
        }
    }

    func clear() {
        _ = gate.withDialogsOff { ops.delete(baseQuery()) }
    }
}

// MARK: - Test doubles (selftest and XCTest; nothing here reaches the network)

/// Answers requests from a script, in order, and records each one. nil in the script
/// means "no answer" (a dropped connection).
final class ScriptedCursorHTTP: CursorHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(status: Int, body: Data)?]
    private var log: [URLRequest] = []

    init(_ replies: [(Int, String)?]) {
        self.replies = replies.map { $0.map { (status: $0.0, body: Data($0.1.utf8)) } }
    }

    func send(_ request: URLRequest) async -> (status: Int, body: Data)? {
        lock.lock(); defer { lock.unlock() }
        log.append(request)
        return replies.isEmpty ? nil : replies.removeFirst()
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
}

/// Runs an async operation to completion from synchronous code (the selftest). Only for
/// operations that do not need the main actor.
enum AsyncBlock {
    private final class Box<V>: @unchecked Sendable { var value: V? }

    static func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

/// An unsigned test JWT with the given claims: header.payload.signature.
enum FakeJWT {
    static func make(_ claims: [String: Any]) -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
        return "eyJhbGciOiJub25lIn0." + CursorSignIn.base64URL(payload) + ".sig"
    }
}
