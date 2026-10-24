import XCTest
@testable import TinyEdit

final class JSONFormatterTests: XCTestCase {
    func fmt(_ s: String, _ sel: NSRange? = nil) -> JSONFormatResult { JSONFormatter.format(text: s, selection: sel) }

    func testPrettyPreservesKeyOrderDuplicatesAndLexemes() {
        guard case .formatted(let out, _) = fmt(#"{"b":1.0,"a":1e2,"b":[true,null,{}],"s":"\u00e9"}"#) else { return XCTFail() }
        XCTAssertEqual(out, """
        {
          "b": 1.0,
          "a": 1e2,
          "b": [
            true,
            null,
            {}
          ],
          "s": "\\u00e9"
        }
        """)
    }

    func testDeepNestingDoesNotCrash() {
        let deep = String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)
        if case .invalid = fmt(deep) {} else { XCTFail() }
    }
}
