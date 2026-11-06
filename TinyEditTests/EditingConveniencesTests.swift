import AppKit
import XCTest
@testable import TinyEdit

/// Smart Return indent, wrapping a selection, whole-line copy, Go to Matching Bracket, case tools and the
/// selection's number sum.
final class EditingConveniencesTests: XCTestCase {
    private func smart(_ text: String, caret: Int? = nil, _ language: EditorLanguage = .swift,
                       style: IndentStyle = .spaces(4)) -> (String, Int)? {
        let ns = text as NSString
        let at = caret ?? ns.length
        guard let change = IndentEditing.smartNewline(in: ns, selection: NSRange(location: at, length: 0),
                                                      language: language, style: style) else { return nil }
        let out = NSMutableString(string: text)
        for e in change.edits.reversed() { out.replaceCharacters(in: e.range, with: e.string) }
        return (out as String, change.selection.location)
    }

    func testSmartNewlineIndentsAfterOpeners() throws {
        XCTAssertEqual(smart("  if x {")?.0, "  if x {\n      ")
        XCTAssertEqual(smart("let a = [")?.0, "let a = [\n    ")
        XCTAssertEqual(smart("f(", style: .tabs)?.0, "f(\n\t")
        XCTAssertEqual(smart("if x {   ")?.0, "if x {\n    ", "blanks before the caret go")
        XCTAssertEqual(smart("if x { // why")?.0, "if x { // why\n    ", "a trailing comment is ignored")
        XCTAssertEqual(smart("def f():", .python)?.0, "def f():\n    ")
        XCTAssertEqual(smart("key:", .yaml, style: .spaces(2))?.0, "key:\n  ")
        XCTAssertNil(smart("a = 1"))
        XCTAssertNil(smart("label:"), "a colon only opens a block in Python and YAML")
        XCTAssertNil(smart("let s = \"{"), "inside a string")
        XCTAssertNil(smart("## {", .markdown))
        XCTAssertNil(smart("{", .plain))
        XCTAssertEqual(smart("fn f<'a>(x: &'a str) {", .rust)?.0, "fn f<'a>(x: &'a str) {\n    ")
    }

    func testSmartNewlineSplitsAPair() throws {
        let (text, caret) = try XCTUnwrap(smart("  f({})", caret: 5))
        XCTAssertEqual(text, "  f({\n      \n  })")
        XCTAssertEqual(caret, ("  f({\n      " as NSString).length)
        XCTAssertEqual(smart("[ ]", caret: 1)?.0, "[\n    \n]")
        XCTAssertEqual(smart("{x}", caret: 1)?.0, "{\n    x}", "only a closer right after the caret splits")
    }

    @MainActor
    func testReturnUsesTheBufferLanguage() {
        let host = EditorTextHost()
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "if x {}", settings: settings)
        host.activate(store, settings: settings)
        host.textView.bufferLanguage = { .javascript }
        host.textView.setSelectedRange(NSRange(location: 6, length: 0))
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "if x {\n    \n}")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 11, length: 0))
        host.textView.undo(nil)
        XCTAssertEqual(store.logicalString(), "if x {}")
    }

    @MainActor
    func testWrapSelection() {
        let host = EditorTextHost()
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "say hi now", settings: settings)
        host.activate(store, settings: settings)
        let tv = host.textView
        tv.setSelectedRange(NSRange(location: 4, length: 2))
        XCTAssertTrue(tv.wrapSelection(with: "\""))
        XCTAssertEqual(store.logicalString(), "say \"hi\" now")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 2))
        XCTAssertTrue(tv.wrapSelection(with: "("))
        XCTAssertEqual(store.logicalString(), "say \"(hi)\" now")
        XCTAssertFalse(tv.wrapSelection(with: "x"))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(tv.wrapSelection(with: "("), "no selection types the bracket")
        tv.undo(nil)   // both wraps ran in one event, so they share its undo group
        XCTAssertEqual(store.logicalString(), "say hi now")
    }

    @MainActor
    func testWholeLineCopyAndPaste() {
        let host = EditorTextHost()
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "one\ntwo", settings: settings)
        host.activate(store, settings: settings)
        let tv = host.textView
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(tv.copyWholeLine(to: pb))
        XCTAssertEqual(pb.string(forType: .string), "two\n", "the last line gets a newline")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(tv.pasteWholeLine(from: pb))
        XCTAssertEqual(store.logicalString(), "two\none\ntwo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0), "the caret moves down with its line")
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertFalse(tv.pasteWholeLine(from: pb), "over a selection it pastes as text")
        pb.clearContents()
        pb.setString("plain\n", forType: .string)
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertFalse(tv.pasteWholeLine(from: pb), "only a whole-line copy pastes above")
    }

    func testMatchingBracketJump() {
        let text = "a(b[c]d)e" as NSString
        XCTAssertEqual(BracketMatcher.jumpTarget(in: text, caret: 2), 8, "after ( → past )")
        XCTAssertEqual(BracketMatcher.jumpTarget(in: text, caret: 8), 1, "after ) → before (")
        XCTAssertEqual(BracketMatcher.jumpTarget(in: text, caret: 5), 3, "next to ] → before [")
        XCTAssertEqual(BracketMatcher.jumpTarget(in: text, caret: 7), 1, "inside → the enclosing opener")
        XCTAssertNil(BracketMatcher.jumpTarget(in: "abc", caret: 1))
    }

    func testCaseTools() throws {
        func run(_ tool: TextTool, _ s: String) throws -> String { try TextTransform.apply(tool, to: s) }
        XCTAssertEqual(try run(.camelCase, "user_name"), "userName")
        XCTAssertEqual(try run(.camelCase, "HTTPServer error"), "httpServerError")
        XCTAssertEqual(try run(.pascalCase, "user-name"), "UserName")
        XCTAssertEqual(try run(.snakeCase, "userName\n  parseJSONValue"), "user_name\n  parse_json_value")
        XCTAssertEqual(try run(.constantCase, "maxRetry2Count"), "MAX_RETRY2_COUNT")
        XCTAssertEqual(try run(.kebabCase, "Font Size"), "font-size")
        XCTAssertEqual(try run(.uppercase, "abc"), "ABC")
        XCTAssertEqual(try run(.lowercase, "ABC"), "abc")
        XCTAssertEqual(try run(.titleCase, "hello wide world"), "Hello Wide World")
        XCTAssertEqual(TextTool.camelCase.group, .textCase)
    }

    func testNumberSum() throws {
        let column = try XCTUnwrap(NumberSum(["12\n3.5\n-1,000\n"]))
        XCTAssertEqual(column.count, 3)
        XCTAssertEqual(column.plainSum, "-984.5")
        XCTAssertEqual(NumberSum(["1,2,3"])?.sum, 6)
        XCTAssertEqual(NumberSum(["$10 | 20% | ¥5"])?.sum, 35)
        XCTAssertEqual(NumberSum(["0.1", "0.2"])?.plainSum, "0.3", "exact decimals, several ranges")
        XCTAssertNil(NumberSum(["42"]), "one number is not a sum")
        XCTAssertNil(NumberSum(["took 12 ms, then 30"]), "words mean it is not a list of numbers")
        XCTAssertNil(NumberSum(["2026-11-07 12:30"]))
        XCTAssertNil(NumberSum(["1.2.3 4"]))
        XCTAssertNil(SelectionStats(["hello"]).numbers)
        XCTAssertNotNil(SelectionStats(["1 2"]).numbers)
    }
}
