import XCTest
@testable import TinyEdit

final class InlineCalculationHelpTests: XCTestCase {
    func testEveryExampleHasAResult() {
        let rows = InlineCalculationReference.groups.flatMap(\.rows)
        XCTAssertEqual(Set(rows.map(\.example)).count, rows.count)
        for row in rows {
            XCTAssertNotNil(row.result, row.example)
        }
        XCTAssertEqual(rows.first { $0.example == "2^10" }?.result, "= 1024")
        XCTAssertEqual(rows.first { $0.example == "sin(30°)" }?.result, "≈ 0.5")
    }
}
