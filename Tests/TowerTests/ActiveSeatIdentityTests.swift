import Foundation
import XCTest
@testable import Tower

/// The persisted verified-seat record is a memory of a previous login, not live
/// identity. These pin which refresh outcomes may reuse it for advice and which
/// must leave the active seat unknown.
final class ActiveSeatIdentityTests: XCTestCase {
    /// After .noCredential there is no live login at all. Reusing the persisted
    /// record would name a seat that is not active, so advise must reach
    /// .activeUnknown and name the roomiest seat for information only.
    func testNoCredentialCycleLeavesTheActiveSeatUnknown() {
        let email = LimitsModel.activeEmail(
            after: .noCredential(detail: nil), cycle: nil, persisted: "stale@example.test")
        XCTAssertNil(email, "a record from a previous login is not this session's seat")

        var seat = AccountSnapshot(email: "roomy@example.test", nickname: "roomy", plan: "max")
        seat.fiveHourPct = 10
        seat.weeklyPct = 10
        seat.capturedAt = Date()
        let advice = AccountSnapshot.advise(activeEmail: email, accounts: [seat], now: Date())
        guard case .activeUnknown = advice else {
            XCTFail("noCredential must not advise from a stale record, got \(advice)")
            return
        }
    }

    func testFailedPollKeepsThePersistedIdentityAndOkUsesTheCycle() {
        XCTAssertEqual(
            LimitsModel.activeEmail(after: .failed("boom"), cycle: nil, persisted: "a@b"), "a@b",
            "a failed poll must not blank the last verified identity")
        XCTAssertEqual(
            LimitsModel.activeEmail(after: .ok(email: "a@b"), cycle: "a@b", persisted: nil), "a@b")
    }

    /// The record speaks only for the token it was verified from: another token,
    /// an aged-out verification, or a disputing hint all fail to bind.
    func testVerifiedRecordBindsOnlyToTheTokenItWasVerifiedFrom() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let live = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "live-token",
            subscriptionType: "max", rateLimitTier: nil,
            expiresAt: now.addingTimeInterval(3600), emailHint: "a@b")
        let bound = VerifiedActiveSeat(
            email: "a@b", verifiedAt: now, tokenDigest: VerifiedActiveSeat.digest(of: "live-token"))
        XCTAssertTrue(bound.binds(to: live, now: now))

        let otherToken = VerifiedActiveSeat(
            email: "a@b", verifiedAt: now, tokenDigest: VerifiedActiveSeat.digest(of: "old-token"))
        XCTAssertFalse(otherToken.binds(to: live, now: now), "a previous login's record is stale")

        let aged = VerifiedActiveSeat(
            email: "a@b", verifiedAt: now.addingTimeInterval(-VerifiedActiveSeat.maxAge - 60),
            tokenDigest: VerifiedActiveSeat.digest(of: "live-token"))
        XCTAssertFalse(aged.binds(to: live, now: now), "older than one token lifetime")

        let disputed = ClaudeCredential(
            service: live.service, accessToken: live.accessToken,
            subscriptionType: live.subscriptionType, rateLimitTier: live.rateLimitTier,
            expiresAt: live.expiresAt, emailHint: "other@example.test")
        XCTAssertFalse(bound.binds(to: disputed, now: now), "a hint that disagrees is drift")

        let legacy = VerifiedActiveSeat(email: "a@b", verifiedAt: now, tokenDigest: "")
        XCTAssertFalse(legacy.binds(to: live, now: now), "a pre-binding record never binds")
    }
}
