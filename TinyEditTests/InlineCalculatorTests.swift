import XCTest
@testable import TinyEdit

final class InlineCalculatorTests: XCTestCase {
    func testProposals() {
        let rows: [(String, String?)] = [
            ("1 + 1", " = 2"),
            ("1+1", " = 2"),
            ("1+2*3", " = 7"),
            ("(1+2)*3", " = 9"),
            ("8/2*2", " = 8"),
            ("8/2/2", " = 2"),
            ("1+2*3+4", " = 11"),
            ("-3+5", " = 2"),
            ("-(2+3)*4", " = -20"),
            ("+2*-3", " = -6"),
            ("1++2", " = 3"),
            ("1--2", " = 3"),
            ("0.1+0.2", " = 0.3"),
            ("0.1 + 0.2", " = 0.3"),
            ("1/2", " = 0.5"),
            ("1/4", " = 0.25"),
            ("1/5", " = 0.2"),
            ("1/8", " = 0.125"),
            ("10/4", " = 2.5"),
            ("4/2", " = 2"),
            ("1/3*3", " = 1"),
            ("1/3", " ≈ 0.333333333333"),
            ("2/3", " ≈ 0.666666666667"),
            ("-8/3", " ≈ -2.66666666667"),
            ("1/300", " ≈ 0.00333333333333"),
            ("1/6", " ≈ 0.166666666667"),
            ("1/0", nil),
            ("99999999999999999999 * 99999999999999999999", " ≈ 1e40"),
            ("0/0", nil),
            ("1/(1-1)", nil),
            ("１＋１", " = 2"),
            ("（１＋２）×３", " = 9"),
            ("2×3", " = 6"),
            ("10÷4", " = 2.5"),
            ("1 + 1 =", " 2"),
            ("1+1=", "2"),
            ("1 + 1 = ", "2"),
            ("1/3 =", " 0.333333333333"),
            ("1 + 1 = 2", nil),
            ("1+1=2", nil),
            ("1 + 1 = 2.0", nil),
            ("1+1=+2", nil),
            ("１＋１＝２", nil),
            ("1/3 ≈ 0.333333333333", nil),
            ("1/3 = 0.333333333333", nil),
            ("2 + 2 = 2", " → 4"),
            ("2+2=2", " → 4"),
            ("1/3 ≈ 0.3", " → 0.333333333333"),
            ("1", nil),
            ("+2", nil),
            ("(1)", nil),
            ("-(1)", nil),
            ("hello", nil),
            ("a = 1 + 1", nil),
            ("1 + x", nil),
            ("50%", nil),
            ("$5+1", nil),
            ("1+", nil),
            ("(1+2", nil),
            ("1+*", nil),
            ("2024-01-02", nil),
            ("2024/1/2", nil),
            ("2024 - 01 - 02", nil),
            ("2024-01-02 + 1", nil),
            ("1-2-3", " = -4"),
            ("1.2.3", nil),
            ("010-12345678", nil),
            ("555-1234", nil),
            ("021-12345678", nil),
            ("123-456-7890", nil),
            ("010+1", nil),
            ("100-20", " = 80"),
            ("1000-2000", " = -1000"),
            ("1-2", " = -1"),
            ("", nil),
            ("   ", nil),
        ]
        for (line, ghost) in rows {
            XCTAssertEqual(InlineCalculator.proposal(forLine: line)?.ghost, ghost, line)
        }
    }

    func testOperationsAndFunctions() {
        let rows: [(String, String?)] = [
            ("2^10", " = 1024"),
            ("2**10", " = 1024"),
            ("2^-1", " = 0.5"),
            ("-2^2", " = -4"),
            ("(-2)^2", " = 4"),
            ("2^3^2", " = 512"),
            ("2*3^2", " = 18"),
            ("0^-1", nil),
            ("4^0.5", " = 2"),
            ("8^(2/3)", " = 4"),
            ("2^0.5", " ≈ 1.41421356237"),
            ("(-8)^0.5", nil),
            ("2^200", " ≈ 1.60693804426e60"),
            ("2^100", " = 1267650600228229401496703205376"),
            ("sqrt(144)", " = 12"),
            ("SQRT(144)", " = 12"),
            ("√144", " = 12"),
            ("sqrt(2)", " ≈ 1.41421356237"),
            ("sqrt(1/4)", " = 0.5"),
            ("sqrt(-1)", nil),
            ("sqrt(2)^2-2", " ≈ 0"),
            ("cbrt(27)", " = 3"),
            ("cbrt(-27)", " = -3"),
            ("root(16,4)", " = 2"),
            ("root(16, 4)", " = 2"),
            ("root(-16,4)", nil),
            ("200*15%", " = 30"),
            ("200+15%", " = 200.15"),
            ("50%", nil),
            ("mod(10,3)", " = 1"),
            ("mod(-7,3)", " = 2"),
            ("mod(7,-3)", " = -2"),
            ("mod(5.5,2)", " = 1.5"),
            ("mod(1,0)", nil),
            ("abs(-10)", " = 10"),
            ("abs(3-5)*2", " = 4"),
            ("max(10,20,30)", " = 30"),
            ("min(10,20,30)", " = 10"),
            ("max(1)", " = 1"),
            ("avg(10,20,30)", " = 20"),
            ("avg(1,2)", " = 1.5"),
            ("avg(1,1,2)", " ≈ 1.33333333333"),
            ("max()", nil),
            ("max(10，20)", " = 20"),
            ("round(3.14159,2)", " = 3.14"),
            ("round(2.5)", " = 3"),
            ("round(-2.5)", " = -3"),
            ("round(1234,-2)", " = 1200"),
            ("round(sqrt(2),3)", " ≈ 1.414"),
            ("floor(3.8)", " = 3"),
            ("floor(-3.2)", " = -4"),
            ("ceil(3.2)", " = 4"),
            ("ceil(-3.8)", " = -3"),
            ("5!", " = 120"),
            ("0!", " = 1"),
            ("3!+1", " = 7"),
            ("33!", " = 8683317618811886495518194401280000000"),
            ("34!", " ≈ 2.9523279904e38"),
            ("2.5!", nil),
            ("(-1)!", nil),
            ("171!", nil),
            ("5 != 3", nil),
            ("5!=120", nil),
            ("log10(100)", " = 2"),
            ("log(1000)", " = 3"),
            ("log2(8)", " = 3"),
            ("log(8,2)", " = 3"),
            ("log(2)", " ≈ 0.301029995664"),
            ("log(0)", nil),
            ("log(8,1)", nil),
            ("ln(10)", " ≈ 2.30258509299"),
            ("ln(e)", " ≈ 1"),
            ("exp(1)", " ≈ 2.71828182846"),
            ("sin(30°)", " ≈ 0.5"),
            ("sin(pi)", " ≈ 0"),
            ("cos(π)", " ≈ -1"),
            ("cos(90°)", " ≈ 0"),
            ("tan(45°)", " ≈ 1"),
            ("tan(90°)", nil),
            ("asin(1)", " ≈ 1.57079632679"),
            ("asin(2)", nil),
            ("acos(1)", " ≈ 0"),
            ("atan(1)*4", " ≈ 3.14159265359"),
            ("2*pi", " ≈ 6.28318530718"),
            ("pi", nil),
            ("e", nil),
            ("30°", nil),
            ("1e3+1", " = 1001"),
            ("2.5e-3*2", " = 0.005"),
            ("1e-9*1", " = 0.000000001"),
            ("2e", nil),
            ("2pi", nil),
            ("foo(1)", nil),
            ("sin 1", nil),
            ("max(1,2", nil),
            ("1,2+3", nil),
            ("２＾３", " = 8"),
            ("ｓｑｒｔ（４）", " = 2"),
            ("1+1 = 2", nil),
            ("2^200 ≈ 1.60693804426e60", nil),
            ("2^200 = 1e60", " → 1.60693804426e60"),
            ("sqrt(2) =", " 1.41421356237"),
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

    func testLimits() {
        XCTAssertEqual(InlineCalculator.proposal(forLine: "1+1" + String(repeating: " ", count: 197))?.ghost, "= 2")
        XCTAssertNil(InlineCalculator.proposal(forLine: "1+1" + String(repeating: " ", count: 198)))

        let ok = String(repeating: "(", count: 32) + "1+2" + String(repeating: ")", count: 32)
        XCTAssertEqual(InlineCalculator.proposal(forLine: ok)?.ghost, " = 3")
        let deep = String(repeating: "(", count: 33) + "1+2" + String(repeating: ")", count: 33)
        XCTAssertNil(InlineCalculator.proposal(forLine: deep))
    }

    func testEligibility() {
        let plain = InlineCalculator.Context(mode: .plainText, language: .plain)
        let mdMode = InlineCalculator.Context(mode: .plainTextAndMarkdown, language: .markdown)
        let lines = ["1 + 1", "```", "1 + 1", "```", "`1 + 1`", "~~~", "1 + 1", "~~~", "1 + 1"]
        let text = lines.joined(separator: "\n") as NSString
        let starts = lines.indices.map { i in lines[..<i].reduce(0) { $0 + $1.utf16.count + 1 } }
        let allowed = starts.map { InlineCalculator.isEligible(mdMode, text: text, index: $0) }
        XCTAssertEqual(allowed, [true, false, false, false, false, false, false, false, true])
        XCTAssertTrue(InlineCalculator.isEligible(plain, text: "1 + 1" as NSString, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .plainText, language: .markdown), text: text, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .plainText, language: .swift), text: "1 + 1" as NSString, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .plainTextAndMarkdown, language: .python), text: "1 + 1" as NSString, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .off, language: .plain), text: "1 + 1" as NSString, index: 0))
    }
}
