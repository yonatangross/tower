import XCTest
@testable import Tower

/// A usage reply's shape is logged when it carries no `five_hour` window, so the next capture
/// shows where the 5h window really is (2026-11-02, three max seats). The shape must name keys
/// and the categorical labels of `limits[]`, and never a value.
final class UsageShapeTests: XCTestCase {
    private let reply = Data(#"""
    {"seven_day":{"utilization":5.0,"resets_at":"2026-11-09T08:00:00Z"},
     "extra_usage":null,
     "limits":[
       {"kind":"weekly_scoped","group":"model","percent":41,"resets_at":"2026-11-09T08:00:00Z",
        "scope":{"model":{"display_name":"Fable"}}},
       {"kind":"rolling_window","group":"session","percent":37,"resets_at":"2026-11-02T19:30:00Z"}
     ]}
    """#.utf8)

    func testTheShapeNamesKeysAndLimitLabels() throws {
        let shape = try XCTUnwrap(UsageShape.describe(reply))
        XCTAssertEqual(shape,
                       "keys=extra_usage,limits,seven_day; limits=[weekly_scoped/model{group,kind,percent,resets_at,scope}, rolling_window/session{group,kind,percent,resets_at}]")
    }

    func testTheShapeCarriesNoValue() throws {
        let shape = try XCTUnwrap(UsageShape.describe(reply))
        for value in ["5.0", "41", "37", "2026", "Fable", "19:30"] {
            XCTAssertFalse(shape.contains(value), "the shape leaked \(value)")
        }
    }

    func testALongOrOddLabelIsCutAndNonStringLabelsAreNamedByType() throws {
        let odd = Data(#"{"limits":[{"kind":42,"group":"\#(String(repeating: "g", count: 80))"}, "x"]}"#.utf8)
        let shape = try XCTUnwrap(UsageShape.describe(odd))
        XCTAssertEqual(shape, "keys=limits; limits=[<number>/\(String(repeating: "g", count: 32)){group,kind}, <not an object>]")
    }

    func testNotJSONOrNotAnObjectHasNoShape() {
        XCTAssertNil(UsageShape.describe(Data("not json".utf8)))
        XCTAssertNil(UsageShape.describe(Data("[1,2]".utf8)))
    }
}
