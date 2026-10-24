import XCTest
import AppKit
@testable import TinyEdit

final class MarkdownImageTests: XCTestCase {
    private func paragraph(_ source: String) throws -> AttributedString {
        let nodes = try MarkdownDocument.parse(source)
        guard case .paragraph(let text) = nodes.first else { XCTFail("No paragraph: \(nodes)"); return AttributedString() }
        return text
    }

    func testCodeAndUnknownHTMLAreNeverInterpreted() throws {
        let inline = try paragraph("`<img src='a.png'>` &lt;img src='b.png'&gt;")
        XCTAssertFalse(inline.runs.contains { $0.imageURL != nil })
        let nodes = try MarkdownDocument.parse("```html\n<img src='a.png'>\n<br>\n```\n\n<script>alert(1)</script>")
        guard case .codeBlock(_, let code) = nodes.first else { return XCTFail() }
        XCTAssertEqual(code, "<img src='a.png'>\n<br>")
        XCTAssertEqual(nodes.last, .html("<script>alert(1)</script>"))
    }

    @MainActor func testImagesFitTableColumnWithoutStretching() {
        let image = CGSize(width: 2200, height: 1440)
        let size = MarkdownImageView.fit(image, dimensions: .init(width: 560), available: 240)
        XCTAssertEqual(size.width, 240)
        XCTAssertEqual(size.height, 1440 * 240 / 2200, accuracy: 0.001)
        let heightBound = MarkdownImageView.fit(image, dimensions: .init(height: 100), available: 560)
        XCTAssertEqual(heightBound.height, 100)
        let small = MarkdownImageView.fit(CGSize(width: 40, height: 20), dimensions: .init(height: 100), available: 560)
        XCTAssertEqual(small, CGSize(width: 200, height: 100))
    }
}
