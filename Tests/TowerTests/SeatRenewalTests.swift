import Foundation
import XCTest
@testable import Tower

/// #58: a remembered seat read needs login about 11 hours after login because its access
/// token was kept until it expired and never renewed. These tests fake an expiring token
/// and prove the seat stays logged in: renewed ahead of expiry, renewed once after a 401,
/// never renewed when it is the CLI's active login, and dropped cleanly when the server
/// refuses the refresh token.
final class SeatRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func login(_ email: String, token: String, refresh: String? = nil,
                       expiresIn: TimeInterval = 3600) -> ClaudeCredential {
        ClaudeCredential(service: Keychain.defaultService, accessToken: token,
                         subscriptionType: "max", rateLimitTier: nil,
                         expiresAt: now.addingTimeInterval(expiresIn), emailHint: email,
                         refreshToken: refresh ?? "refresh-\(token)", scopes: ["user:profile"])
    }

    private func seat(_ email: String, token: String, refresh: String? = "refresh",
                      expiresAt: Date) -> ClaudeCredential {
        ClaudeCredential(service: ClaudeSeatVault.service(for: email), accessToken: token,
                         subscriptionType: "max", rateLimitTier: nil,
                         expiresAt: expiresAt, emailHint: email,
                         refreshToken: refresh, scopes: ["user:profile"])
    }

    private func usage(_ pct: Double = 21) -> UsageResponse {
        UsageResponse(five_hour: UsageWindow(utilization: pct, resets_at: nil),
                      seven_day: UsageWindow(utilization: pct, resets_at: nil),
                      seven_day_opus: nil, seven_day_sonnet: nil, limits: nil)
    }

    private func reading(_ email: String) -> ClaudeFetch {
        ClaudeFetch(email: email, usage: usage())
    }

    private func unauthorized() -> Error {
        NSError(domain: "UsageAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "HTTP 401"])
    }

    /// A renewal closure that answers like the token endpoint and stores the result the way
    /// the production renewer does, so the vault write path is exercised without a network.
    private func fakeRenewer(vault: ClaudeSeatVault, clock: @escaping () -> Date,
                             calls: @escaping (ClaudeCredential) -> Void = { _ in })
        -> (ClaudeCredential) async throws -> ClaudeCredential {
        { credential in
            calls(credential)
            guard let refresh = credential.refreshToken else { throw ClaudeSeatRenewal.Rejected(message: "none") }
            let renewed = ClaudeCredential(
                service: credential.service, accessToken: credential.accessToken + "-renewed",
                subscriptionType: credential.subscriptionType, rateLimitTier: credential.rateLimitTier,
                expiresAt: clock().addingTimeInterval(8 * 3600), emailHint: credential.emailHint,
                refreshToken: refresh + "-rotated", scopes: credential.scopes)
            if let error = vault.storeRenewedSeat(renewed, replacing: credential.accessToken) {
                throw ClaudeSeatRenewal.Unavailable(message: error)
            }
            return renewed
        }
    }

    // MARK: the issue itself

    /// The operator signs into seat one, then switches to seat two. Eleven hours later seat
    /// one's access token is about to expire. The remembered seat is renewed before that
    /// moment and keeps reading live, on that poll and on the poll after the old expiry.
    func testRememberedSeatIsRenewedBeforeExpiryAndStaysLoggedIn() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        let one = login("one@example.test", token: "one-1", expiresIn: 11 * 3600)
        let captured = await Refresher.refreshLoggedInAccount(
            one, store: store, vault: vault,
            profile: { _ in "one@example.test" }, usage: { _ in self.usage() }, clock: { self.now })
        XCTAssertNil(captured.saveError)
        XCTAssertEqual(keychain.ownedItemCount, 1, "seat one remembered")

        // Ten minutes before seat one expires, with seat two now the CLI's login.
        var clock = now.addingTimeInterval(11 * 3600 - 10 * 60)
        let two = login("two@example.test", token: "two-1", expiresIn: 24 * 3600)
        var renewed: [String] = []
        var fetched: [String] = []
        let result = await Refresher.refreshLoggedInAccount(
            two, store: store, vault: vault,
            profile: { token in fetched.append(token); return token.hasPrefix("two") ? "two@example.test" : "one@example.test" },
            usage: { _ in self.usage() }, clock: { clock },
            renew: fakeRenewer(vault: vault, clock: { clock }, calls: { renewed.append($0.accessToken) }))
        XCTAssertEqual(renewed, ["one-1"], "seat one renewed once, seat two left to the CLI")
        XCTAssertEqual(fetched, ["two-1", "one-1-renewed"], "the renewed token is the one fetched")
        let row = try XCTUnwrap(result.accounts["one@example.test"])
        XCTAssertNil(row.lastError, "remembered seat stays logged in")
        XCTAssertFalse(row.needsLogin)
        XCTAssertEqual(row.capturedAt, clock)
        XCTAssertTrue(row.isRecommendable(now: clock), "renewed seat can rank")

        // The Keychain item now holds the new pair; a fresh launch reads it back.
        let record = try XCTUnwrap(keychain.items.first { $0.account == "one@example.test" })
        let payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: record.data, format: nil) as? [String: Any])
        XCTAssertEqual(payload["accessToken"] as? String, "one-1-renewed", "renewed access token stored")
        XCTAssertEqual(payload["refreshToken"] as? String, "refresh-one-1-rotated", "rotated refresh token stored")
        let relaunch = keychain.vault(in: dir).credentials(active: nil)
        XCTAssertEqual(relaunch.filter { $0.emailHint == "one@example.test" }.map(\.accessToken), ["one-1-renewed"])

        // Past the original expiry: nothing is due, and the seat is still live.
        clock = now.addingTimeInterval(11 * 3600 + 60)
        fetched.removeAll()
        let later = await Refresher.refreshLoggedInAccount(
            two, store: store, vault: vault,
            profile: { token in fetched.append(token); return token.hasPrefix("two") ? "two@example.test" : "one@example.test" },
            usage: { _ in self.usage() }, clock: { clock },
            renew: { credential in XCTFail("no renewal due for \(credential.accessToken)"); throw ClaudeSeatRenewal.Unavailable(message: "unexpected") })
        XCTAssertEqual(fetched, ["two-1", "one-1-renewed"])
        XCTAssertNil(later.accounts["one@example.test"]?.lastError, "seat stays logged in past the old expiry")
    }

    /// Tower was asleep across the expiry (or the lead was missed): an already expired
    /// remembered seat is renewed and fetched on the same poll instead of reading needs login.
    func testExpiredRememberedSeatIsRenewedOnTheSamePoll() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        XCTAssertNil(vault.captureVerifiedLogin(
            login("one@example.test", token: "one-1", expiresIn: 1), email: "one@example.test",
            observation: vault.beginObservation(), now: now))
        let clock = now.addingTimeInterval(3 * 3600)
        var renewals = 0
        // Seat two is the CLI's live login, so seat one is provably renewable.
        let result = await Refresher.refreshLoggedInAccount(
            login("two@example.test", token: "two-1", expiresIn: 24 * 3600), store: store, vault: vault,
            profile: { token in token.hasPrefix("two") ? "two@example.test" : "one@example.test" },
            usage: { _ in self.usage() }, clock: { clock },
            renew: fakeRenewer(vault: vault, clock: { clock }, calls: { _ in renewals += 1 }))
        XCTAssertEqual(renewals, 1)
        XCTAssertNil(result.accounts["one@example.test"]?.lastError, "expired seat renewed, not needs login")
        XCTAssertEqual(result.accounts["one@example.test"]?.capturedAt, clock)
        XCTAssertEqual(result.verifiedActiveEmail, "two@example.test")
    }

    /// The server can refuse a token Tower still thinks is valid. That earns exactly one
    /// renewal and one more fetch; a second refusal is a real needs login.
    func testRefusedTokenIsRenewedOnceAndFetchedAgain() async throws {
        let store = Store(dir: dir, now: { self.now })
        let cli = login("cli@example.test", token: "cli-1")
        let stale = seat("one@example.test", token: "stale", expiresAt: now.addingTimeInterval(5 * 3600))
        var fetched: [String] = []
        var renewals = 0
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [stale, cli] },
            fetch: { credential in
                fetched.append(credential.accessToken)
                if credential.service == Keychain.defaultService {
                    return self.reading("cli@example.test")
                }
                guard credential.accessToken == "fresh" else { throw ClaudeCredentialExpired() }
                return self.reading("one@example.test")
            },
            now: now,
            renew: { credential in
                renewals += 1
                return self.seat("one@example.test", token: "fresh", refresh: "refresh-2",
                                 expiresAt: self.now.addingTimeInterval(8 * 3600))
            })
        XCTAssertEqual(fetched, ["cli-1", "stale", "fresh"], "one retry with the renewed token")
        XCTAssertEqual(renewals, 1)
        XCTAssertNil(result.accounts["one@example.test"]?.lastError, "seat stays logged in after the retry")

        // Refused twice: the renewal is not repeated within the cycle.
        fetched.removeAll()
        renewals = 0
        let twice = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [stale, cli] },
            fetch: { credential in
                fetched.append(credential.accessToken)
                if credential.service == Keychain.defaultService {
                    return self.reading("cli@example.test")
                }
                throw ClaudeCredentialExpired()
            },
            now: now,
            renew: { _ in
                renewals += 1
                return self.seat("one@example.test", token: "fresh", expiresAt: self.now.addingTimeInterval(8 * 3600))
            })
        XCTAssertEqual(fetched, ["cli-1", "stale", "fresh"], "second refusal is not retried again")
        XCTAssertEqual(renewals, 1, "renewed once per seat per cycle")
        XCTAssertEqual(twice.accounts["one@example.test"]?.lastError, "needs login")
    }

    /// The active login belongs to Claude Code. Its retained copy, even an older one about
    /// to expire, is never presented to the token endpoint by Tower.
    func testActiveSeatIsNeverRenewedByTower() async throws {
        let store = Store(dir: dir, now: { self.now })
        let cli = login("one@example.test", token: "cli-new", expiresIn: 8 * 3600)
        let olderCopy = seat("one@example.test", token: "cli-old", expiresAt: now.addingTimeInterval(60))
        let other = seat("two@example.test", token: "two-old", expiresAt: now.addingTimeInterval(60))
        var renewed: [String] = []
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [olderCopy, other, cli] },
            fetch: { credential in self.reading(credential.emailHint!) },
            now: now,
            renew: { credential in
                renewed.append(credential.emailHint ?? "?")
                return self.seat(credential.emailHint!, token: credential.accessToken + "-renewed",
                                 expiresAt: self.now.addingTimeInterval(8 * 3600))
            })
        XCTAssertEqual(renewed, ["two@example.test"], "active seat belongs to the CLI")
        XCTAssertNil(result.accounts["one@example.test"]?.lastError)
        XCTAssertNil(result.accounts["two@example.test"]?.lastError)

        XCTAssertEqual(ClaudeSeatRenewal.decision(for: cli, activeEmail: "one@example.test", now: now), .notRetained)
        XCTAssertEqual(ClaudeSeatRenewal.decision(for: olderCopy, activeEmail: "one@example.test", now: now), .activeSeat)
        // nil active means UNKNOWN, not absent: every retained seat may be the live one.
        XCTAssertEqual(ClaudeSeatRenewal.decision(for: olderCopy, activeEmail: nil, now: now), .possiblyActive)
        XCTAssertEqual(ClaudeSeatRenewal.decision(
            for: seat("two@example.test", token: "t", refresh: nil, expiresAt: now), activeEmail: nil, now: now), .possiblyActive)
        XCTAssertEqual(ClaudeSeatRenewal.decision(
            for: seat("two@example.test", token: "t", refresh: nil, expiresAt: now), activeEmail: "one@example.test", now: now), .noRefreshToken)
        let fresh = seat("two@example.test", token: "t", expiresAt: now.addingTimeInterval(ClaudeSeatRenewal.lead + 1))
        XCTAssertEqual(ClaudeSeatRenewal.decision(for: fresh, activeEmail: nil, now: now), .possiblyActive)
        XCTAssertEqual(ClaudeSeatRenewal.decision(for: fresh, activeEmail: "one@example.test", now: now), .fresh)
        XCTAssertEqual(ClaudeSeatRenewal.decision(for: fresh, activeEmail: "one@example.test", now: now.addingTimeInterval(1)), .due)
        XCTAssertFalse(ClaudeSeatRenewal.canAttempt(olderCopy, activeEmail: "one@example.test"))
        XCTAssertFalse(ClaudeSeatRenewal.canAttempt(fresh, activeEmail: nil), "unknown active fails closed")
        XCTAssertTrue(ClaudeSeatRenewal.canAttempt(fresh, activeEmail: "one@example.test"))
    }

    /// A profile-step failure carries NO email: the credential's ~/.claude.json hint is
    /// not identity, and promoting it would let a wrong hint plus one transient failure
    /// mark a stranger's seat as verified and renew under the live session.
    func testProfileStepFailureCarriesNoEmailAndFailsRenewalClosed() async throws {
        let cli = login("hint@example.test", token: "cli-1")
        do {
            _ = try await Refresher.fetchClaude(
                cli,
                profile: { _ in throw ClaudeSeatVaultError("boom") },
                usage: { _ in self.usage() },
                onVerified: { _, _ in }, clock: { self.now })
            XCTFail("a failed profile fetch must throw")
        } catch let error as ClaudeFetchFailure {
            XCTAssertNil(error.email, "an unverified hint is not identity")
            XCTAssertTrue(error.message.contains("profile fetch:"), "the step is named")
        }

        let due = seat("two@example.test", token: "two-1", expiresAt: now.addingTimeInterval(10 * 60))
        var renewals = 0
        let result = await Refresher.refreshClaudeRoster(
            store: Store(dir: dir, now: { self.now }),
            credentials: { [due, cli] },
            fetch: { credential in
                if credential.service == Keychain.defaultService {
                    throw ClaudeFetchFailure(email: nil, message: "profile fetch: boom")
                }
                return self.reading(credential.emailHint!)
            },
            now: now,
            renew: { _ in
                renewals += 1
                throw ClaudeSeatRenewal.Unavailable(message: "must not be presented")
            })
        XCTAssertNil(result.verifiedActiveEmail, "a failed profile fetch verifies nothing")
        XCTAssertEqual(renewals, 0, "unknown active seat fails closed on every retained seat")
        XCTAssertEqual(ClaudeSeatRenewal.decision(for: due, activeEmail: nil, now: now), .possiblyActive)
    }

    /// The bug this guard exists for: Tower could not verify which seat the CLI holds, so
    /// EVERY retained seat may be the live login. No renewal is attempted at all, and an
    /// already expired seat reads needs login rather than silently decaying the fleet.
    func testUnknownActiveSeatFailsClosedOnEveryRetainedSeat() async throws {
        let store = Store(dir: dir, now: { self.now })
        let due = seat("one@example.test", token: "one-1", expiresAt: now.addingTimeInterval(10 * 60))
        var renewals = 0
        let refused: (ClaudeCredential) async throws -> ClaudeCredential = { _ in
            renewals += 1
            throw ClaudeSeatRenewal.Unavailable(message: "must not be presented")
        }
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [due] },
            fetch: { _ in self.reading("one@example.test") },
            now: now, renew: refused)
        XCTAssertEqual(renewals, 0, "a retained seat is not renewed while the active seat is unknown")
        XCTAssertNil(result.verifiedActiveEmail)
        XCTAssertNil(result.accounts["one@example.test"]?.lastError)

        let gone = seat("two@example.test", token: "two-1", expiresAt: now.addingTimeInterval(-1))
        let expired = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [gone] },
            fetch: { _ in XCTFail("an expired seat with unknown active is not fetched"); throw ClaudeCredentialExpired() },
            now: now, renew: refused)
        XCTAssertEqual(renewals, 0, "the expired seat is not renewed either")
        XCTAssertEqual(expired.accounts["two@example.test"]?.lastError, "needs login")
    }

    /// A renewal that fails while the current token still works is not fatal: the poll
    /// fetches with the token it has and the row says nothing; the next poll tries again.
    /// Once the token has expired, the row reads needs login and names the reason.
    func testFailedRenewalKeepsTheWorkingTokenAndNamesItselfOnceExpired() async throws {
        let store = Store(dir: dir, now: { self.now })
        let cli = login("cli@example.test", token: "cli-1")
        let due = seat("one@example.test", token: "still-good", expiresAt: now.addingTimeInterval(10 * 60))
        var fetched: [String] = []
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [due, cli] },
            fetch: { credential in
                fetched.append(credential.accessToken)
                return self.reading(credential.emailHint!)
            },
            now: now,
            renew: { _ in throw ClaudeSeatRenewal.Unavailable(message: "HTTP 503") })
        XCTAssertEqual(fetched, ["cli-1", "still-good"], "working token still fetched after a failed renewal")
        XCTAssertNil(result.accounts["one@example.test"]?.lastError)

        let gone = seat("one@example.test", token: "dead", expiresAt: now.addingTimeInterval(-1))
        let expired = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [gone, cli] },
            fetch: { credential in
                if credential.service == Keychain.defaultService {
                    return self.reading("cli@example.test")
                }
                XCTFail("expired token must not be fetched")
                throw ClaudeCredentialExpired()
            },
            now: now,
            renew: { _ in throw ClaudeSeatRenewal.Rejected(message: "HTTP 400") })
        let row = try XCTUnwrap(expired.accounts["one@example.test"])
        XCTAssertEqual(row.lastError, "needs login: token renewal refused: HTTP 400")
        XCTAssertTrue(row.needsLogin, "refused seat still cannot rank")
    }

    /// The production renewer against a refusing token endpoint: the dead refresh token is
    /// dropped from the Keychain item so the next poll does not present it again, and the
    /// seat reads needs login until a fresh login of that seat rewrites the item.
    func testRefusedRefreshTokenIsDroppedAndNotPresentedAgain() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        XCTAssertNil(vault.captureVerifiedLogin(
            login("one@example.test", token: "one-1", expiresIn: 1), email: "one@example.test",
            observation: vault.beginObservation(), now: now))
        let clock = now.addingTimeInterval(2)
        var posts = 0
        let renewer = ClaudeSeatRenewal.renewer(vault: vault, now: { clock }, post: { request in
            posts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":"invalid_grant"}"#.utf8), response)
        })
        // Seat two is the CLI's live login, so seat one is provably renewable.
        let live = login("two@example.test", token: "two-1")
        let first = await Refresher.refreshLoggedInAccount(
            live, store: store, vault: vault,
            profile: { _ in "two@example.test" },
            usage: { _ in self.usage() }, clock: { clock }, renew: renewer)
        XCTAssertEqual(posts, 1, "refresh token presented once")
        XCTAssertEqual(first.accounts["one@example.test"]?.lastError, "needs login: token renewal refused: invalid_grant")
        let record = try XCTUnwrap(keychain.items.first { $0.account == "one@example.test" })
        let payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: record.data, format: nil) as? [String: Any])
        XCTAssertNil(payload["refreshToken"], "refused refresh token dropped from the item")
        XCTAssertEqual(payload["accessToken"] as? String, "one-1", "access token left in place")

        let second = await Refresher.refreshLoggedInAccount(
            live, store: store, vault: vault,
            profile: { _ in "two@example.test" },
            usage: { _ in self.usage() }, clock: { clock }, renew: renewer)
        XCTAssertEqual(posts, 1, "dropped refresh token is not presented again")
        XCTAssertEqual(second.accounts["one@example.test"]?.lastError, "needs login")

        // A fresh login of that seat rewrites the item with a new pair, which renews again.
        XCTAssertNil(vault.captureVerifiedLogin(
            login("one@example.test", token: "one-2", refresh: "refresh-2", expiresIn: 3600),
            email: "one@example.test", observation: vault.beginObservation(), now: clock))
        XCTAssertEqual(vault.credentials(active: nil).first { $0.emailHint == "one@example.test" }?.refreshToken, "refresh-2")
    }

    /// A 400 that is not `invalid_grant` (a malformed request, a server-side hiccup) is not a
    /// verdict on the token: the production renewer keeps the refresh token and presents it
    /// again next poll. Dropping it here would recreate #58 across every seat from one bad answer.
    func testNonInvalidGrant400KeepsTheRefreshTokenForTheNextPoll() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        XCTAssertNil(vault.captureVerifiedLogin(
            login("one@example.test", token: "one-1", expiresIn: 1), email: "one@example.test",
            observation: vault.beginObservation(), now: now))
        let clock = now.addingTimeInterval(2)
        var posts = 0
        let renewer = ClaudeSeatRenewal.renewer(vault: vault, now: { clock }, post: { request in
            posts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":"invalid_request"}"#.utf8), response)
        })
        // Seat two is the CLI's live login, so seat one is provably renewable.
        let live = login("two@example.test", token: "two-1")
        for cycle in 1...2 {
            let result = await Refresher.refreshLoggedInAccount(
                live, store: store, vault: vault,
                profile: { _ in "two@example.test" },
                usage: { _ in self.usage() }, clock: { clock }, renew: renewer)
            XCTAssertEqual(posts, cycle, "refresh token presented again on cycle \(cycle)")
            XCTAssertEqual(result.accounts["one@example.test"]?.lastError,
                           "needs login: token renewal failed: HTTP 400 invalid_request")
        }
        XCTAssertEqual(vault.credentials(active: nil).first { $0.emailHint == "one@example.test" }?.refreshToken, "refresh-one-1",
                       "non-invalid_grant 400 keeps the refresh token")
    }

    /// A renewal that lands after the seat was forgotten, or after a newer login of that seat
    /// was captured, must not write: no item is brought back, no fresher pair overwritten.
    func testRenewalWriteRespectsForgetAndANewerLogin() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let old = login("one@example.test", token: "one-1", expiresIn: 60)
        XCTAssertNil(vault.captureVerifiedLogin(old, email: "one@example.test",
                                                observation: vault.beginObservation(), now: now))
        let renewed = seat("one@example.test", token: "one-1-renewed", expiresAt: now.addingTimeInterval(8 * 3600))

        XCTAssertNil(vault.captureVerifiedLogin(
            login("one@example.test", token: "one-2", expiresIn: 3600), email: "one@example.test",
            observation: vault.beginObservation(), now: now))
        XCTAssertNil(vault.storeRenewedSeat(renewed, replacing: "one-1"))
        XCTAssertEqual(vault.credentials(active: nil).map(\.accessToken), ["one-2"], "newer login not overwritten")

        XCTAssertNil(vault.forgetAll())
        XCTAssertNil(vault.storeRenewedSeat(
            seat("one@example.test", token: "one-2-renewed", expiresAt: now.addingTimeInterval(8 * 3600)),
            replacing: "one-2"))
        XCTAssertEqual(keychain.ownedItemCount, 0, "forgotten seat not brought back by a late renewal")

        let disabled = keychain.vault(in: dir, enabled: { false })
        XCTAssertNil(disabled.storeRenewedSeat(renewed, replacing: "one-1"))
        XCTAssertEqual(keychain.ownedItemCount, 0, "retention off writes nothing")
    }

    // MARK: the request itself

    /// The request is shaped exactly like Claude Code's own renewal (2.1.274): JSON body,
    /// refresh_token grant, the CLI client id, the seat's scopes. The answer's expiry is
    /// relative, and a server that does not rotate the refresh token leaves the old one valid.
    func testRenewRequestMatchesClaudeCodeAndParsesTheAnswer() async throws {
        let credential = seat("one@example.test", token: "old-access", refresh: "old-refresh",
                              expiresAt: now.addingTimeInterval(60))
        var captured: URLRequest?
        let renewed = try await ClaudeSeatRenewal.renew(credential, now: now) { request in
            captured = request
            let body = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"scope":"user:profile user:inference"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url, URL(string: "https://platform.claude.com/v1/oauth/token"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, [
            "grant_type": "refresh_token", "refresh_token": "old-refresh",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "scope": "user:profile",
        ])
        XCTAssertEqual(renewed.accessToken, "new-access")
        XCTAssertEqual(renewed.refreshToken, "new-refresh")
        XCTAssertEqual(renewed.expiresAt, now.addingTimeInterval(28800))
        XCTAssertEqual(renewed.scopes, ["user:profile", "user:inference"])
        XCTAssertEqual(renewed.service, credential.service)
        XCTAssertEqual(renewed.emailHint, "one@example.test")

        let kept = try await ClaudeSeatRenewal.renew(credential, now: now) { request in
            (Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(kept.refreshToken, "old-refresh", "unrotated refresh token kept")
        XCTAssertEqual(kept.scopes, ["user:profile"], "scopes kept when the answer omits them")

        func status(_ code: Int, body: String = "") async -> Error? {
            do {
                _ = try await ClaudeSeatRenewal.renew(credential, now: now) { request in
                    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
                }
                return nil
            } catch {
                return error
            }
        }
        // Only the OAuth verdict on the token itself is a refusal (RFC 6749 section 5.2).
        let deadToken = await status(400, body: #"{"error":"invalid_grant","error_description":"expired"}"#)
        let refused401 = await status(401)
        let badRequest = await status(400, body: #"{"error":"invalid_request"}"#)
        let bare400 = await status(400)
        let outage = await status(503)
        let malformed = await status(200)
        XCTAssertEqual(deadToken as? ClaudeSeatRenewal.Rejected, .init(message: "invalid_grant"))
        XCTAssertEqual(refused401 as? ClaudeSeatRenewal.Rejected, .init(message: "HTTP 401"))
        XCTAssertEqual(badRequest as? ClaudeSeatRenewal.Unavailable, .init(message: "HTTP 400 invalid_request"),
                       "a 400 that is not invalid_grant keeps the token")
        XCTAssertEqual(bare400 as? ClaudeSeatRenewal.Unavailable, .init(message: "HTTP 400 no error code"))
        XCTAssertEqual(outage as? ClaudeSeatRenewal.Unavailable, .init(message: "HTTP 503"))
        XCTAssertEqual(malformed as? ClaudeSeatRenewal.Unavailable, .init(message: "malformed token response"))
        do {
            _ = try await ClaudeSeatRenewal.renew(credential, now: now) { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("offline must throw")
        } catch {
            XCTAssertTrue(error is ClaudeSeatRenewal.Unavailable, "offline is retryable, not a refusal")
        }
        let none = seat("one@example.test", token: "t", refresh: nil, expiresAt: now)
        do {
            _ = try await ClaudeSeatRenewal.renew(none, now: now) { _ in XCTFail("no request without a refresh token"); throw URLError(.cancelled) }
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is ClaudeSeatRenewal.Rejected)
        }
    }

    /// The CLI credential parser carries the refresh token and scopes into the credential,
    /// from the item shape Claude Code writes (keys verified on the live item, 2026-09-17).
    func testKeychainParserCarriesTheRefreshTokenIntoTheCredential() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":2000000000000,"refreshTokenExpiresAt":2002000000000,"scopes":["user:profile","user:inference"],"subscriptionType":"max","rateLimitTier":"fixture-tier"}}"#
        let credential = try XCTUnwrap(Keychain.credential(
            from: Data(json.utf8), service: Keychain.defaultService, emailHint: "one@example.test"))
        XCTAssertEqual(credential.accessToken, "a")
        XCTAssertEqual(credential.refreshToken, "r")
        XCTAssertEqual(credential.scopes, ["user:profile", "user:inference"])
        XCTAssertEqual(credential.expiresAt, now)
        XCTAssertEqual(credential.rateLimitTier, "fixture-tier")
        XCTAssertTrue(credential.canRenew)

        let bare = try XCTUnwrap(Keychain.credential(
            from: Data(#"{"claudeAiOauth":{"accessToken":"a","expiresAt":2000000000000}}"#.utf8),
            service: Keychain.defaultService, emailHint: nil))
        XCTAssertNil(bare.refreshToken)
        XCTAssertEqual(bare.scopes, [])
        XCTAssertFalse(bare.canRenew)
    }
}
