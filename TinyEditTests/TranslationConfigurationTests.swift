import XCTest
@testable import TinyEdit

final class TranslationConfigurationTests: XCTestCase {
    private func preferences() -> TranslationPreferences {
        var p = TranslationPreferences()
        p.engine = .custom; p.model = "test-model"
        p.endpoint = "https://fixture.invalid/success"
        return p
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testConnectionProbeUsesCurrentModelAndFlagsButNoPersonalInstructions() throws {
        var p = preferences(); p.thinking = .off; p.thinkingFormat = .deepSeek
        p.extraInstructions = "Private terminology that must not enter the test."
        let request = try ModelTranslation.connectionTestRequest(preferences: p, key: "dummy-key")
        let json = try body(request)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(request.url?.absoluteString, p.endpoint)
        XCTAssertEqual(request.timeoutInterval, ModelTranslation.probeTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-key")
        XCTAssertEqual(json["model"] as? String, p.model)
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(messages[1]["content"], "Hello")
        XCTAssertFalse(messages.contains { ($0["content"] ?? "").contains(p.extraInstructions) })
    }

    func testSavedMaskNeverBecomesAStoredOrSentCredential() throws {
        var draft = TranslationCredentialDraft()
        draft.hasSavedKey = true
        XCTAssertTrue(draft.showsSavedMask)
        XCTAssertEqual(draft.value, "")
        var writes: [String] = []
        try draft.persist { writes.append($0) }
        XCTAssertEqual(writes, [])
        XCTAssertEqual(try draft.keyForRequest { "saved-secret" }, "saved-secret")
        draft.edit("replacement-secret")
        XCTAssertFalse(draft.showsSavedMask)
        XCTAssertEqual(try draft.keyForRequest { XCTFail("Edited draft must not read old credential"); return "old" }, "replacement-secret")
        try draft.persist { writes.append($0) }
        draft.didSave()
        XCTAssertEqual(writes, ["replacement-secret"])
        XCTAssertTrue(draft.showsSavedMask)
        XCTAssertEqual(draft.value, "")
    }
}
