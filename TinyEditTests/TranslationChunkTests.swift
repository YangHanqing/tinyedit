import XCTest
@testable import TinyEdit

final class TranslationChunkTests: XCTestCase {
    func testReconstructionPreservesParagraphsWhitespaceAndFences() {
        let text = "  Hello world!\nwrapped line.\n\n\t\n```swift\nlet x = 1\n```\n\nSecond paragraph.\n"
        let segments = TranslationPlan.make(text, limit: 20)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        XCTAssertTrue(segments.contains { !$0.needsTranslation && $0.text == "```swift\nlet x = 1\n```\n" })
        XCTAssertFalse(segments.filter(\.needsTranslation).contains { $0.text.contains("let x") })
        XCTAssertTrue(segments.filter(\.needsTranslation).allSatisfy { $0.text.utf16.count <= 20 })
    }

    func testLongAndUnclosedCodeFencesAreNeverSent() {
        for text in ["~~~python\n" + String(repeating: "print(1)\n", count: 1000) + "~~~~\n",
                     "```\nNever closed\n\nStill code"] {
            let segments = TranslationPlan.make(text, limit: 20)
            XCTAssertEqual(segments.map(\.text).joined(), text)
            XCTAssertFalse(segments.contains(where: \.needsTranslation))
        }
    }

    func testHTTPErrorsShowTheServiceMessageWithTheKeyMasked() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-secret-123.\n See docs.","code":"invalid_api_key"}}"#.utf8)
        XCTAssertThrowsError(try ModelTranslation.decode(body, status: 401, key: "sk-secret-123")) { error in
            guard case .http(401, let detail)? = error as? TranslationFailure else { return XCTFail("\(error)") }
            XCTAssertEqual(detail, "Incorrect API key provided: ••••. See docs.")
            XCTAssertFalse(error.localizedDescription.contains("sk-secret-123"))
            XCTAssertTrue(error.localizedDescription.contains("••••"))
        }
        XCTAssertThrowsError(try ModelTranslation.decode(Data("<html>Bad Gateway</html>".utf8), status: 502)) { error in
            guard case .http(502, nil)? = error as? TranslationFailure else { return XCTFail("\(error)") }
        }
        let long = ModelTranslation.displayedMessage(String(repeating: "a", count: 400), key: "")
        XCTAssertEqual(long?.count, 301)
        XCTAssertNil(ModelTranslation.displayedMessage(" \n ", key: ""))
    }
}

@MainActor
final class TranslationRunTests: XCTestCase {

}
