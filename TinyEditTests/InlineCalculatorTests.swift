import XCTest
@testable import TinyEdit

final class InlineCalculatorTests: XCTestCase {
    /// Ghosts that would be wrong or intrusive; the help examples (`InlineCalculationHelpTests`) cover the functions.
    func testProposals() {
        let rows: [(String, String?)] = [
            ("1+2*3", " = 7"),
            ("0.1 + 0.2", " = 0.3"),
            ("1/3", " ≈ 0.333333333333"),
            ("1/0", nil),
            ("（１＋２）×３", " = 9"),
            ("2^100", " = 1267650600228229401496703205376"),
            ("1 + 1 =", " 2"),
            ("1 + 1 = 2", nil),
            ("2 + 2 = 2", " → 4"),
            // Not arithmetic: dates, phone numbers, versions, assignments, lone values.
            ("2024-01-02", nil),
            ("2024/1/2", nil),
            ("010-12345678", nil),
            ("123-456-7890", nil),
            ("1.2.3", nil),
            ("a = 1 + 1", nil),
            ("50%", nil),
            ("5!=120", nil),
            ("100-20", " = 80"),
        ]
        for (line, ghost) in rows {
            XCTAssertEqual(InlineCalculator.proposal(forLine: line)?.ghost, ghost, line)
        }
    }

    func testAdoptionEdits() {
        let fresh = InlineCalculator.proposal(forLine: "1 + 1")
        XCTAssertEqual(fresh?.edit, .append(" = 2"))

        let glued = InlineCalculator.proposal(forLine: "1+1=")
        XCTAssertEqual(glued?.edit, .append("2"))

        let spaced = InlineCalculator.proposal(forLine: "1 + 1 =")
        XCTAssertEqual(spaced?.edit, .append(" 2"))

        let mismatch = InlineCalculator.proposal(forLine: "2 + 2 = 2")
        XCTAssertEqual(mismatch?.edit, .replace(NSRange(location: 6, length: 3), "= 4"))

        let tight = InlineCalculator.proposal(forLine: "2+2=2")
        XCTAssertEqual(tight?.edit, .replace(NSRange(location: 3, length: 2), "=4"))

        let approx = InlineCalculator.proposal(forLine: "1/3=0.5")
        XCTAssertEqual(approx?.edit, .replace(NSRange(location: 3, length: 4), "≈0.333333333333"))
    }
}
