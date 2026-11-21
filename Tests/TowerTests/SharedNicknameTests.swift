import XCTest
@testable import Tower

/// One email can hold a Claude seat and a Codex seat, and both derive the same nickname (observed live
/// 2026-11-01: "eve" twice in the RESTING list, the Claude max seat and the Codex pro seat, with nothing
/// telling them apart). A list that mixes providers names the product beside a nickname that another row
/// in the same list shares, and only then.
final class SharedNicknameTests: XCTestCase {
    private func seat(_ nick: String, _ provider: Provider?) -> AccountSnapshot {
        var row = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
        row.provider = provider
        return row
    }

    func testASharedNicknameCarriesItsProduct() {
        let claude = seat("eve", nil)
        let codex = seat("eve", .codex)
        let rows = [claude, codex, seat("account-b", nil)]
        XCTAssertEqual(AccountSnapshot.listName(claude, among: rows), "eve · claude")
        XCTAssertEqual(AccountSnapshot.listName(codex, among: rows), "eve · codex")
    }

    func testAUniqueNicknameStaysBare() {
        let rows = [seat("eve", nil), seat("eve", .codex), seat("account-b", nil)]
        XCTAssertEqual(AccountSnapshot.listName(rows[2], among: rows), "account-b")
        XCTAssertEqual(AccountSnapshot.listName(seat("ana", nil), among: [seat("ana", nil)]), "ana")
    }

    func testTheSameSeatTwiceIsNotADuplicate() {
        let one = seat("eve", nil)
        XCTAssertEqual(AccountSnapshot.listName(one, among: [one, one]), "eve",
                       "a row compared with itself is one seat, not a shared name")
    }
}
