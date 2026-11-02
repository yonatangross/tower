import Foundation
import XCTest
@testable import Tower

/// #108: the login keychain can hold more than one `Claude Code-credentials`
/// item; a session started without $USER once wrote a tokenless "unknown" stub
/// beside the real login. Selection must go by the bound account, never by
/// whichever item `security` happens to return first.
final class KeychainItemSelectionTests: XCTestCase {
    private let service = Keychain.defaultService
    private let stale = Date(timeIntervalSince1970: 1_700_000_000)
    private let fresh = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two items sharing the default service: the newer one is the tokenless
    /// "unknown" stub, the older one is the login the seat is bound to.
    private var twoItems: [Keychain.ItemRef] {
        [Keychain.ItemRef(account: "unknown", modifiedAt: fresh),
         Keychain.ItemRef(account: "selftest-user", modifiedAt: stale)]
    }

    private var reads: [String: Data] {
        ["unknown": Data("{}".utf8),
         "selftest-user": credentialJSON("live-token")]
    }

    private func credentialJSON(_ token: String) -> Data {
        Data("""
        {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":1999999999000,"subscriptionType":"max"}}
        """.utf8)
    }

    func testOrderedItemRefsAsksTheBoundAccountFirst() {
        let ordered = Keychain.orderedItemRefs(twoItems, preferredAccount: "selftest-user")
        XCTAssertEqual(ordered.map(\.account), ["selftest-user", "unknown"],
                       "the bound account is asked first even though the stub is newer")
    }

    func testOrderedItemRefsWithoutAPreferenceTriesNewestFirst() {
        let ordered = Keychain.orderedItemRefs(twoItems, preferredAccount: nil)
        XCTAssertEqual(ordered.map(\.account), ["unknown", "selftest-user"])
    }

    /// The regression from #108: whichever item sorts first can be the tokenless
    /// stub. Reading by account returns the live login instead of reporting no
    /// credential.
    func testFirstCredentialReadsTheBoundAccountNotTheFirstMatch() {
        var tried: [String] = []
        let credential = Keychain.firstCredential(
            refs: twoItems, preferredAccount: "selftest-user",
            read: { tried.append($0); return reads[$0] },
            service: service, emailHint: nil)
        XCTAssertEqual(credential?.accessToken, "live-token")
        XCTAssertEqual(tried, ["selftest-user"], "the stub is never asked once the bound item answers")
    }

    /// With no bound account known, the newest-first fallback still cannot settle
    /// on the stub: an item with no access token never parses to a credential.
    func testFirstCredentialFallbackSkipsTheTokenlessStub() {
        var tried: [String] = []
        let credential = Keychain.firstCredential(
            refs: twoItems, preferredAccount: nil,
            read: { tried.append($0); return reads[$0] },
            service: service, emailHint: nil)
        XCTAssertEqual(tried, ["unknown", "selftest-user"], "newest first, stub skipped by the parse")
        XCTAssertEqual(credential?.accessToken, "live-token")
    }

    func testFirstCredentialReturnsNilWhenEveryItemIsATokenlessStub() {
        let credential = Keychain.firstCredential(
            refs: twoItems, preferredAccount: nil,
            read: { _ in Data("{}".utf8) },
            service: service, emailHint: nil)
        XCTAssertNil(credential)
    }

    /// The dump-listing fixture the fallback parses: two items on the default
    /// service plus one on another service it must not pick up.
    func testParseItemRefsFindsBothItemsOnTheDefaultService() {
        let dump = """
        keychain: "/Users/selftest/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "svce"<blob>="Claude Code-credentials"
            "acct"<blob>="unknown"
            "mdat"<timedate>=0x0000  "2026-09-21 22:03:54 +0000"
        class: "genp"
        attributes:
            "svce"<blob>="Claude Code-credentials"
            "acct"<blob>="selftest-user"
            "mdat"<timedate>=0x0000  "2026-09-23 08:59:03 +0000"
        class: "genp"
        attributes:
            "svce"<blob>="openrouter-api-key"
            "acct"<blob>="other"
            "mdat"<timedate>=0x0000  "2026-09-23 09:00:00 +0000"
        """
        let refs = Keychain.parseItemRefs(dump, service: service)
        XCTAssertEqual(refs.map(\.account), ["unknown", "selftest-user"])
        XCTAssertEqual(refs.map(\.modifiedAt),
                       [parseDay("2026-09-21 22:03:54 +0000"), parseDay("2026-09-23 08:59:03 +0000")])
    }

    func testCredentialServiceUsesCurrentConfigDirectoryHash() {
        let service = Keychain.credentialService(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/tower-claude-e\u{301}"])
        XCTAssertEqual(service, "Claude Code-credentials-7e9d779b")
    }

    func testFreshScopedLoginReadsItsAccountAndNeverAnotherSeatsService() {
        let expected = "Claude Code-credentials-7e9d779b"
        var calls: [String] = []
        let credential = Keychain.activeOAuth(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/tower-claude-e\u{301}"],
            read: { service, account in
                calls.append(service)
                guard service == expected, account == Keychain.loginAccountName else { return nil }
                return self.credentialJSON("fixture-scoped-login")
            }, list: { _ in [] })
        XCTAssertEqual(credential?.accessToken, "fixture-scoped-login")
        XCTAssertEqual(calls, [expected])
    }

    func testFreshDefaultLoginSkipsTheTokenlessFirstMatch() {
        let credential = Keychain.activeOAuth(environment: [:], read: { service, account in
            guard service == Keychain.defaultService else { return nil }
            return account == Keychain.loginAccountName ? self.credentialJSON("fixture-fresh-login") : Data("{}".utf8)
        }, list: { _ in self.twoItems })
        XCTAssertEqual(credential?.accessToken, "fixture-fresh-login")
    }

    func testSecureStorageConfigDirectoryOverridesClaudeConfigDirectory() {
        let service = Keychain.credentialService(environment: [
            "CLAUDE_CONFIG_DIR": "/tmp/other-seat",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/tower-claude-e\u{301}",
        ])
        XCTAssertEqual(service, "Claude Code-credentials-7e9d779b")
    }

    func testEmptySecureStorageConfigDirectoryUsesUnscopedService() {
        let service = Keychain.credentialService(environment: [
            "CLAUDE_CONFIG_DIR": "/tmp/other-seat",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "",
        ])
        XCTAssertEqual(service, Keychain.defaultService)
    }

    func testProfileURLFollowsClaudeConfigDirectory() {
        let home = URL(fileURLWithPath: "/tmp/tower-home")
        let url = Keychain.profileURL(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/tower-current-seat"], home: home)
        XCTAssertEqual(url.path, "/tmp/tower-current-seat/.claude.json")
    }

    func testScopedItemParserRejectsAnotherConfigDirectoryService() {
        let current = "Claude Code-credentials-7e9d779b"
        let dump = """
        keychain: "/Users/selftest/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "svce"<blob>="Claude Code-credentials-deadbeef"
            "acct"<blob>="other-seat"
            "mdat"<timedate>=0x0000  "2026-09-26 18:00:00 +0000"
        class: "genp"
        attributes:
            "svce"<blob>="Claude Code-credentials-7e9d779b"
            "acct"<blob>="current-seat"
            "mdat"<timedate>=0x0000  "2026-09-26 17:00:00 +0000"
        """
        let refs = Keychain.parseItemRefs(dump, service: current)
        XCTAssertEqual(refs.map(\.service), [current])
        XCTAssertEqual(refs.map(\.account), ["current-seat"])
    }

    /// When no item parses, the error names how many the keychain held and which
    /// accounts were tried, instead of a bare "no credential".
    func testNoCredentialDetailNamesEveryItemTheListingFound() {
        let scan = Keychain.ActiveItemScan(
            itemAccounts: ["unknown", "selftest-user"], resolvedAccount: nil)
        let detail = Keychain.noCredentialDetail(scan)
        XCTAssertEqual(detail,
                       "2 items for Claude Code-credentials, accts: unknown, selftest-user; none parses to a credential")
        let text = RefreshOutcome.noCredential(detail: detail).errorText
        XCTAssertTrue(text?.contains("2 items for Claude Code-credentials") == true)
        XCTAssertTrue(text?.contains("seat numbers are live") == true)
    }

    func testNoCredentialDetailIsNilWhenTheListingWasEmptyOrResolved() {
        XCTAssertNil(Keychain.noCredentialDetail(
            Keychain.ActiveItemScan(itemAccounts: [], resolvedAccount: nil)))
        XCTAssertNil(Keychain.noCredentialDetail(
            Keychain.ActiveItemScan(itemAccounts: ["selftest-user"], resolvedAccount: "selftest-user")))
        XCTAssertEqual(
            Keychain.noCredentialDetail(
                Keychain.ActiveItemScan(itemAccounts: ["unknown"], resolvedAccount: nil)),
            "1 item for Claude Code-credentials, acct: unknown; does not parse to a credential")
    }

    func testNoCredentialWithoutDetailKeepsThePlainText() {
        let outcome = RefreshOutcome.noCredential(detail: nil)
        XCTAssertFalse(outcome.isOK)
        XCTAssertEqual(outcome.errorText,
                       "active login unreadable in the keychain; seat numbers are live")
    }

    private func parseDay(_ s: String) -> Date? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return day.date(from: s)
    }
}
