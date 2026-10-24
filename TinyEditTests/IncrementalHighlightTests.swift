import XCTest
import AppKit
@testable import TinyEdit

/// Incremental repainting against a real layout manager: after any edits, the colors on screen must be
/// exactly what painting every span afresh gives.
@MainActor
final class IncrementalHighlightTests: XCTestCase {
    private var window: NSWindow!
    private let host = EditorTextHost()
    private var controller: HighlightController!

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        controller = HighlightController(host: host)
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
    }

    private func attributes(_ key: NSAttributedString.Key, in store: BufferTextStore) -> [NSColor?] {
        let cs = store.contentStorage
        var out = [NSColor?](repeating: nil, count: store.length)
        host.layoutManager.enumerateRenderingAttributes(from: cs.documentRange.location, reverse: false) { _, attrs, range in
            guard let color = attrs[key] as? NSColor else { return true }
            let a = cs.offset(from: cs.documentRange.location, to: range.location)
            let b = cs.offset(from: cs.documentRange.location, to: range.endLocation)
            for i in max(a, 0)..<min(b, out.count) { out[i] = color }
            return true
        }
        return out
    }

    private func expected(_ store: BufferTextStore, _ language: EditorLanguage) -> [NSColor?] {
        var out = [NSColor?](repeating: nil, count: store.length)
        for span in SyntaxHighlighter.spans(language: language, text: store.logicalString(), limit: nil) {
            for i in span.range.location..<min(NSMaxRange(span.range), out.count) { out[i] = span.kind.color }
        }
        return out
    }

    /// Schedules a pass and waits for the colors to settle on `expected`.
    private func settle(_ store: BufferTextStore, _ language: EditorLanguage, file: StaticString = #filePath, line: UInt = #line) async {
        let want = expected(store, language)
        controller.schedule(store: store, language: language, delay: .zero)
        let start = ContinuousClock.now
        while attributes(.foregroundColor, in: store) != want, ContinuousClock.now - start < .seconds(2) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let got = attributes(.foregroundColor, in: store)
        let first = got.indices.first { $0 >= want.count || got[$0] != want[$0] } ?? (got.count == want.count ? nil : got.count)
        XCTAssertNil(first, "colors differ from offset \(first ?? -1) in \(store.logicalString().debugDescription)", file: file, line: line)
    }

    private let source = """
    // header comment
    const a = "one", b = 'two'; /* block */
    function f(x) { return x + 42 * 3.5; }
    let s = `tpl ${a}`; if (true) { f(null) }
    # Title
    - [ ] task with `code` and **bold**
    """

    private func fuzz(_ language: EditorLanguage, seed: UInt64) async {
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: source, settings: settings)
        host.activate(store, settings: settings)
        await settle(store, language)
        var rng = SplitMix(seed: seed)
        let snippets = ["\"", "'", "/*", "*/", "//", "\n", "x", "42", " ", "true", "`", "# ", "- [x] ", "**"]
        for round in 0..<40 {
            for _ in 0...Int(rng.next() % 3) {
                let length = store.length
                let at = Int(rng.next() % UInt64(length + 1))
                switch rng.next() % 3 {
                case 0:
                    store.textStorage.replaceCharacters(in: NSRange(location: at, length: 0),
                                                        with: snippets[Int(rng.next() % UInt64(snippets.count))])
                case 1:
                    let n = min(Int(rng.next() % 12), length - at)
                    store.textStorage.replaceCharacters(in: NSRange(location: at, length: n), with: "")
                default:
                    let n = min(Int(rng.next() % 4) + 1, length - at)
                    store.textStorage.replaceCharacters(in: NSRange(location: at, length: n),
                                                        with: String(repeating: "z", count: n))
                }
            }
            await settle(store, language)
            if testRun?.failureCount ?? 0 > 0 { return XCTFail("\(language) round \(round)") }
        }
    }

    func testIncrementalColorsMatchAFullRepaint() async {
        await fuzz(.javascript, seed: 1)
        await fuzz(.markdown, seed: 2)
        await fuzz(.json, seed: 3)
    }

}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
