import Foundation
import os

/// #58: a remembered seat used to die with its access token, about 11 hours after login,
/// because Tower kept the token it knew would expire and never presented the refresh token
/// beside it. This is the renewal step the refresh loop runs before that expiry, plus the
/// one retry it gets when the usage endpoint refuses a token early.
///
/// Endpoint, body and client id are what Claude Code 2.1.274 itself sends (read from the
/// installed binary on 2026-09-17): `POST https://platform.claude.com/v1/oauth/token` with a
/// JSON body `{grant_type: "refresh_token", refresh_token, client_id, scope}`; the answer
/// carries `access_token`, `expires_in` and usually a new `refresh_token`.
///
/// The one seat Tower never renews is the active login. Claude Code renews that pair
/// itself, and Tower captures each renewed pair on the next verified poll; presenting the
/// same refresh token from two processes could rotate it out from under the CLI. Everything
/// the CLI no longer holds is Tower's to keep alive.
enum ClaudeSeatRenewal {
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Renew this long before the access token expires. The poll runs every 300 s, so a 30
    /// minute lead gives about six cycles for a renewal to land before the seat would read
    /// needs login; a single failed attempt costs nothing while the current token still works.
    static let lead: TimeInterval = 30 * 60

    static let logger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "renewal")

    enum Decision: Equatable {
        /// The CLI credential, or a foreign item: not Tower's to renew.
        case notRetained
        /// The seat the CLI currently holds; Claude Code renews it.
        case activeSeat
        /// Tower could not verify which seat the CLI holds, so every retained seat
        /// may be it. Failing closed here is what keeps an unreadable default item
        /// from letting Tower rotate the refresh token under the live session.
        case possiblyActive
        /// A retained seat with nothing to present.
        case noRefreshToken
        /// Renewable, but its access token is good for longer than the lead.
        case fresh
        /// Renewable and inside the lead, or already expired.
        case due
    }

    /// Whether this credential may be renewed at all, ignoring the clock. Used for the
    /// retry after a 401, where the server has already decided the token is not good.
    static func canAttempt(_ credential: ClaudeCredential, activeEmail: String?) -> Bool {
        switch decision(for: credential, activeEmail: activeEmail, now: .distantPast) {
        case .fresh, .due: return true
        case .notRetained, .activeSeat, .possiblyActive, .noRefreshToken: return false
        }
    }

    /// `activeEmail` is the VERIFIED active login, not the credential's own hint. nil
    /// means Tower could not establish the active seat at all, which is a refusal, not
    /// a pass: nil used to let every seat renew, including the live one.
    static func decision(for credential: ClaudeCredential, activeEmail: String?, now: Date) -> Decision {
        guard credential.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix) else { return .notRetained }
        if let activeEmail, credential.emailHint == activeEmail { return .activeSeat }
        guard activeEmail != nil else { return .possiblyActive }
        guard credential.canRenew else { return .noRefreshToken }
        guard let expiresAt = credential.expiresAt else { return .due }
        return expiresAt.addingTimeInterval(-lead) <= now ? .due : .fresh
    }

    /// The server refused the refresh token itself: HTTP 400 whose OAuth `error` field is
    /// `invalid_grant` (RFC 6749 section 5.2), or 401. The token is dead; presenting it
    /// again every five minutes would only add noise. Any other 400 is a request problem or
    /// a server-side hiccup, not a verdict on the token, so it stays Unavailable: one bad
    /// answer must not drop every seat's refresh token and recreate #58 across the fleet.
    struct Rejected: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { "token renewal refused: \(message)" }
    }

    /// Anything else: offline, a 5xx, a malformed answer. The token may still be good, so the
    /// next cycle tries again.
    struct Unavailable: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { "token renewal failed: \(message)" }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let scope: String?
    }

    private struct TokenError: Decodable {
        let error: String?
    }

    /// One renewal request. Pure over `post`, so a test can answer it without a network; the
    /// production closure is `URLSession.shared.data(for:)`.
    static func renew(
        _ credential: ClaudeCredential,
        now: Date = Date(),
        post: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async throws -> ClaudeCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw Rejected(message: "no refresh token")
        }
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if !credential.scopes.isEmpty { body["scope"] = credential.scopes.joined(separator: " ") }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await post(request)
        } catch {
            throw Unavailable(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Unavailable(message: "no HTTP response")
        }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw Rejected(message: "HTTP 401")
        case 400:
            let code = (try? JSONDecoder().decode(TokenError.self, from: data))?.error ?? "no error code"
            if code == "invalid_grant" { throw Rejected(message: code) }
            throw Unavailable(message: "HTTP 400 \(code)")
        default: throw Unavailable(message: "HTTP \(http.statusCode)")
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty, token.expires_in > 0
        else { throw Unavailable(message: "malformed token response") }
        let scopes = token.scope.map { $0.split(separator: " ").map(String.init) } ?? []
        return ClaudeCredential(
            service: credential.service, accessToken: token.access_token,
            subscriptionType: credential.subscriptionType, rateLimitTier: credential.rateLimitTier,
            expiresAt: now.addingTimeInterval(token.expires_in), emailHint: credential.emailHint,
            // A server that does not rotate the refresh token keeps the old one valid.
            refreshToken: token.refresh_token ?? refreshToken,
            scopes: scopes.isEmpty ? credential.scopes : scopes)
    }

    /// The production renewal closure for ClaudeRoster.collect: renew, persist the new pair
    /// into the vault, and on a refusal drop the dead refresh token so the loop stops asking.
    /// Every outcome is one line in the unified log (category `renewal`), never a token.
    static func renewer(
        vault: ClaudeSeatVault,
        now: @escaping () -> Date = { Date() },
        post: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) -> (ClaudeCredential) async throws -> ClaudeCredential {
        { credential in
            let seat = credential.emailHint ?? credential.service
            do {
                let renewed = try await renew(credential, now: now(), post: post)
                if let error = vault.storeRenewedSeat(renewed, replacing: credential.accessToken) {
                    logger.error("renewed \(seat, privacy: .public) but could not store it: \(error, privacy: .public)")
                    throw Unavailable(message: error)
                }
                let expiresIn = Int((renewed.expiresAt ?? now()).timeIntervalSince(now()))
                logger.notice("renewed seat \(seat, privacy: .public), next expiry in \(expiresIn, privacy: .public)s")
                return renewed
            } catch let refusal as Rejected {
                if let error = vault.dropRefreshToken(for: credential) {
                    logger.error("seat \(seat, privacy: .public) refresh token refused and could not be dropped: \(error, privacy: .public)")
                } else {
                    logger.error("seat \(seat, privacy: .public) refresh token refused (\(refusal.message, privacy: .public)), dropped; sign in again")
                }
                throw refusal
            } catch {
                logger.notice("seat \(seat, privacy: .public) renewal failed, will retry: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }
}
