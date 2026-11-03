import XCTest
@testable import Tower

/// An opaque Cursor token is sent as a bearer to the editor's GetCurrentPeriodUsage route
/// instead of the dashboard cookie route that refuses it. The authenticated reply shape is
/// not yet measured, so the parser must read the pools where they plausibly sit and must
/// return nil (never zero) for any other shape. Fake values only.
final class CursorBearerRouteTests: XCTestCase {
    func testRequestIsAConnectPostWithTheBearerToken() {
        let req = CursorUsage.bearerRequest(token: "cur_fake")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.host, "api2.cursor.sh")
        XCTAssertEqual(req.url?.path, "/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer cur_fake")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"), "the bearer route sends no cookie")
        XCTAssertEqual(req.httpBody, Data("{}".utf8))
    }

    func testPoolsUnderPlanUsageWithStringMillisCycleEnd() throws {
        let json = #"{"billingCycleEnd":"2000000000000","planUsage":{"autoPercentUsed":12.5,"apiPercentUsed":97}}"#
        let r = try XCTUnwrap(CursorUsage.parseBearer(Data(json.utf8)))
        XCTAssertEqual(r.cursorModelsPct, 12.5)
        XCTAssertEqual(r.otherModelsPct, 97)
        XCTAssertEqual(r.periodResetsAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(r.plan)
    }

    func testPoolsAtTopLevelWithIsoCycleEndAndPlan() throws {
        let json = #"{"billingCycleEnd":"2026-11-23T17:36:41.000Z","membershipType":"ultra","autoPercentUsed":"40","apiPercentUsed":100}"#
        let r = try XCTUnwrap(CursorUsage.parseBearer(Data(json.utf8)))
        XCTAssertEqual(r.cursorModelsPct, 40)
        XCTAssertEqual(r.otherModelsPct, 100)
        XCTAssertEqual(r.plan, "ultra")
        XCTAssertNotNil(r.periodResetsAt)
    }

    func testUnknownShapeIsNilNotZero() {
        XCTAssertNil(CursorUsage.parseBearer(Data(#"{"planUsage":{"totalSpend":3}}"#.utf8)))
        XCTAssertNil(CursorUsage.parseBearer(Data(#"[]"#.utf8)))
        XCTAssertNil(CursorUsage.parseBearer(Data("not json".utf8)))
    }

    func testCycleDateAcceptsNumberMillis() {
        XCTAssertEqual(CursorUsage.cycleDate(NSNumber(value: 2_000_000_000_000.0)),
                       Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(CursorUsage.cycleDate(nil))
    }
}
