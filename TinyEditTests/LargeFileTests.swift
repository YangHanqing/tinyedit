import XCTest
@testable import TinyEdit

/// The large-file engine on real files: rows, edits written by the streaming save, Replace All into a new file,
/// find around edits, and an append. A wrong offset here would corrupt the user's file on Save.
final class LargeFileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LargeFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func file(_ bytes: Data, _ name: String = "f.log") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func indexed(_ url: URL, _ encoding: TextEncoding) throws -> (LargeFileSource, LargeFileIndex) {
        let source = try LargeFileSource(url: url)
        let index = LargeFileIndex(encoding: encoding)
        index.scan(source: source, isCancelled: { false }) { _ in }
        return (source, index)
    }

    private func save(_ source: LargeFileSource, _ edits: LargeFileEdits, _ encoding: TextEncoding,
                      lineBreak: String = "\n", replacement: LargeFileReplacement? = nil) throws -> Data {
        let out = dir.appendingPathComponent("out-\(UUID().uuidString)")
        try LargeFileWriter.write(source: source, size: source.size, edits: edits, encoding: encoding, lineBreak: lineBreak,
                                  replacement: replacement, to: out, isCancelled: { false }, progress: { _ in })
        return try Data(contentsOf: out)
    }

    private func edit(_ row: Int, _ index: LargeFileIndex, _ source: LargeFileSource, _ lines: [String]) -> LargeFileEdit {
        let r = index.row(row, source: source)!
        return LargeFileEdit(row: row, start: r.start, contentEnd: r.contentEnd, end: r.end,
                             hash: ContentHash.sha256Hex(source.readDirect(offset: r.start, count: r.end - r.start)), lines: lines)
    }

    func testRowsLinesAndLongLinePieces() throws {
        let long = String(repeating: "é", count: 20_000)   // 40,000 UTF-8 bytes: three pieces
        let url = try file(Data("a\r\nbb\n\(long)\nlast\n".utf8))
        let (source, index) = try indexed(url, .utf8)
        let p = index.progress
        XCTAssertTrue(p.complete)
        XCTAssertEqual(p.lines, 5)   // the empty line after the final break counts, as in the editor
        XCTAssertEqual(p.rows, 7)
        let rows = index.rows(0..<p.rows, source: source)
        XCTAssertEqual(rows.map(\.line), [1, 2, 3, 3, 3, 4, 5])
        XCTAssertEqual(rows.map(\.startsLine), [true, true, true, false, false, true, true])
        XCTAssertEqual(rows[0].end - rows[0].contentEnd, 2)   // CRLF belongs to the line ending
        let pieces = rows[2...4].map { LargeFileText.decode(source.readDirect(offset: $0.start, count: $0.contentEnd - $0.start), .utf8) }
        XCTAssertEqual(pieces.joined(), long)                // never cut inside a character
        XCTAssertEqual(index.row(forLine: 4, source: source), 5)
        XCTAssertEqual(index.row(containing: rows[3].start + 5, source: source), 3)

        // A block of rows that ends inside one long line still has all its rows when read again.
        let minified = String(repeating: "{\"k\":1},", count: 600_000)   // about 5 MB in one line
        let (s2, i2) = try indexed(try file(Data(minified.utf8), "min.json"), .utf8)
        let all = i2.rows(0..<i2.progress.rows, source: s2)
        XCTAssertEqual(all.count, i2.progress.rows)
        XCTAssertEqual(all.reduce(0) { $0 + $1.contentEnd - $1.start }, minified.utf8.count)
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    func testEditsAreWrittenAroundUntouchedBytes() throws {
        let url = try file(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        let (source, index) = try indexed(url, .utf8)
        var edits = LargeFileEdits()
        edits.apply([edit(1, index, source, ["TWO", "2"]), edit(2, index, source, []), edit(3, index, source, ["4"])])
        XCTAssertEqual(edits.displayCount(baseRows: 4), 4)
        XCTAssertEqual((0..<4).map { edits.locate($0).row }, [0, 1, 1, 3])
        let saved = try save(source, edits, .utf8, lineBreak: "\r\n")
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), "one\r\nTWO\r\n2\r\n4")
        XCTAssertTrue(edits.matches(source: source, index: index))
        let restored = LargeFileEdits.fromSnapshot(edits.snapshotText())
        XCTAssertEqual(restored, edits)
    }

    func testUTF16AndGB18030KeepTheirEncoding() throws {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for (encoding, data) in [(TextEncoding.utf16LE, Data([0xFF, 0xFE]) + "甲\n乙\n丙".data(using: .utf16LittleEndian)!),
                                 (.gb18030, "甲\n乙\n丙".data(using: gb)!)] {
            let url = try file(data, "\(encoding).txt")
            let source = try LargeFileSource(url: url)
            XCTAssertEqual(LargeFileText.detectEncoding(source: source), encoding)
            let (s, index) = try indexed(url, encoding)
            XCTAssertEqual(index.progress.rows, 3)
            var edits = LargeFileEdits()
            edits.apply([edit(1, index, s, ["丁"])])
            let expected = encoding == .utf16LE ? Data([0xFF, 0xFE]) + "甲\n丁\n丙".data(using: .utf16LittleEndian)! : "甲\n丁\n丙".data(using: gb)!
            XCTAssertEqual(try save(s, edits, encoding), expected, "\(encoding)")
        }
    }

    /// Past one 4 MB chunk, so a match can straddle two reads.
    func testReplaceAllIntoANewFileAndCount() throws {
        var text = ""
        while text.utf8.count < 9 * 1_048_576 { text += "INFO request ok id=\(text.utf8.count)\nERROR failed\n" }
        let url = try file(Data(text.utf8))
        let source = try LargeFileSource(url: url)
        let q = try XCTUnwrap(LargeFileQuery("error", caseSensitive: false, encoding: .utf8))
        var count = 0
        LargeFileSearch.forEachMatch(in: source, q, start: 0, end: source.size, isCancelled: { false }) { _ in count += 1; return true }
        let expected = text.components(separatedBy: "ERROR").count - 1
        XCTAssertEqual(count, expected)
        let saved = try save(source, LargeFileEdits(), .utf8,
                             replacement: LargeFileReplacement(query: q, bytes: Data("WARN".utf8)))
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), text.replacingOccurrences(of: "ERROR", with: "WARN"))
    }

    func testFindSkipsEditedBytesAndFindsEditedLines() throws {
        let url = try file(Data("alpha\nneedle one\nbeta\nneedle two\n".utf8))
        let (source, index) = try indexed(url, .utf8)
        var edits = LargeFileEdits()
        edits.apply([edit(1, index, source, ["gone"]), edit(2, index, source, ["x", "a needle here"])])
        let q = try XCTUnwrap(LargeFileQuery("needle", caseSensitive: true, encoding: .utf8))
        let finder = LargeFileFinder(source: source, index: index, edits: edits, query: q, encoding: .utf8,
                                     end: source.size, bom: 0, baseRows: index.progress.rows)
        let first = try XCTUnwrap(finder.forward(display: 0, column: 0))
        XCTAssertEqual(first.0, 3)   // "a needle here", the second line of the edit of row 2
        XCTAssertEqual(first.1, NSRange(location: 2, length: 6))
        let second = try XCTUnwrap(finder.forward(display: 3, column: 8))
        XCTAssertEqual(second.0, 4)  // "needle two"
        XCTAssertEqual(finder.backward(display: 3, column: 0)?.0, nil)
    }

    func testRegexFindsRowsAcrossBatchesAndEditsAndReplacesWithGroups() throws {
        // More rows than one batch, a multibyte prefix (UTF-16 columns), and two edits.
        let text = (0..<5000).map { "é id=\($0) ok" }.joined(separator: "\n") + "\n"
        let url = try file(Data(text.utf8))
        let (source, index) = try indexed(url, .utf8)
        var edits = LargeFileEdits()
        edits.apply([edit(10, index, source, ["é id=x ok"]), edit(4500, index, source, ["é id=4500 ok", "é id=9999 ok"])])
        let q = try XCTUnwrap(LargeFileQuery(#"id=(\d*)5 ok$"#, caseSensitive: true, regex: true, encoding: .utf8))
        let scanner = LargeFileRegexScanner(source: source, index: index, edits: edits, regex: try XCTUnwrap(q.regex),
                                            encoding: .utf8, displayRows: edits.displayCount(baseRows: index.progress.rows))
        var hits: [(row: Int, count: Int)] = []
        scanner.forEach(isCancelled: { false }) { hits.append(($0, $1)); return true }
        XCTAssertEqual(hits.reduce(0) { $0 + $1.count }, 500)   // ids ending in 5; the edits' lines are searched where they sit
        XCTAssertEqual(scanner.forward(display: 0, column: 0)?.1, NSRange(location: 2, length: 7))   // "é " is two UTF-16 units
        XCTAssertEqual(scanner.forward(display: 4096, column: 0)?.0, 4105)   // across the batch boundary
        XCTAssertEqual(scanner.backward(display: 4105, column: 0)?.0, 4095)
        XCTAssertNil(LargeFileQuery("([", caseSensitive: true, regex: true, encoding: .utf8))

        let row = index.row(15, source: source)!
        let line = LargeFileText.decode(source.readDirect(offset: row.start, count: row.contentEnd - row.start), .utf8)
        XCTAssertEqual(q.replacing(in: line, with: "n=$1"), "é n=1")
        edits.apply([LargeFileEdit(row: 15, start: row.start, contentEnd: row.contentEnd, end: row.end,
                                   hash: ContentHash.sha256Hex(source.readDirect(offset: row.start, count: row.end - row.start)),
                                   lines: [q.replacing(in: line, with: "n=$1")])])
        let saved = String(decoding: try save(source, edits, .utf8), as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(Array(saved[14...16]), ["é id=14 ok", "é n=1", "é id=16 ok"])
    }

    func testAppendExtendsTheIndex() throws {
        let url = try file(Data("a\nb".utf8))
        let (source, index) = try indexed(url, .utf8)
        XCTAssertEqual(index.progress.rows, 2)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c\nd\n".utf8))
        try handle.close()
        index.reopenTail()
        index.scan(source: source, isCancelled: { false }) { _ in }
        let rows = index.rows(0..<index.progress.rows, source: source)
        XCTAssertEqual(rows.map { LargeFileText.decode(source.readDirect(offset: $0.start, count: $0.contentEnd - $0.start), .utf8) },
                       ["a", "bc", "d", ""])
    }

    /// Truncated and written again (`>`, copytruncate) to more than before: not an append, and Save refuses to
    /// splice the edits into bytes they were not made on. The line ending counts every line, not the first ones.
    @MainActor
    func testRewriteInPlaceThatGrowsIsNotAnAppend() async throws {
        let first = String(repeating: "x", count: 1_200_000)   // longer than 64 rows of 16 KB
        let url = try file(Data("\(first)\r\nalpha\r\nbeta\r\n".utf8))
        let doc = LargeFileDocument(id: UUID(), encoding: .utf8)
        doc.attach(try LargeFileSource(url: url), encoding: .utf8)
        while !doc.progress.complete { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(doc.lineEnding, .crlf)
        let row = doc.baseRows - 3   // "alpha"
        XCTAssertTrue(doc.replaceRows(row...row, with: "ALPHA", actionName: "Edit"))

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(String(repeating: "y", count: 1_300_000).utf8))
        try handle.close()
        XCTAssertEqual(doc.diskChange(at: url.path), .conflict(canSaveAs: false))
        let result = await doc.save(to: url, overwrite: true, presenter: nil)
        XCTAssertEqual(result.failure, .editsNoLongerMatch)
        XCTAssertEqual(try Data(contentsOf: url).count, 1_300_000)   // untouched
    }

    func testGB18030LongLineIsCutBetweenCharacters() throws {
        let gb = LargeFileText.gb18030
        let long = String(repeating: "汉字𠀀", count: 9_000)   // 2-, 2- and 4-byte characters, no ASCII
        let (source, index) = try indexed(try file(long.data(using: gb)!, "gb.txt"), .gb18030)
        let pieces = index.rows(0..<index.progress.rows, source: source)
            .map { LargeFileText.decode(source.readDirect(offset: $0.start, count: $0.contentEnd - $0.start), .gb18030) }
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertFalse(pieces.contains { $0.contains("\u{FFFD}") })
        XCTAssertEqual(pieces.joined(), long)
    }

    /// GB18030 trail bytes can be ASCII (說 is D5 66, "f"; 😀 is 94 39 FC 36): literal text is searched decoded,
    /// so nothing matches inside a character, and the replacement stays literal.
    func testGB18030LiteralQueryNeverMatchesInsideACharacter() throws {
        let text = "說時點😀\nf r 6 $1\n"
        let (source, index) = try indexed(try file(text.data(using: LargeFileText.gb18030)!, "gb.txt"), .gb18030)
        let q = try XCTUnwrap(LargeFileQuery("f", caseSensitive: true, encoding: .gb18030))
        let scanner = LargeFileRegexScanner(source: source, index: index, edits: LargeFileEdits(), regex: try XCTUnwrap(q.regex),
                                            encoding: .gb18030, displayRows: index.progress.rows)
        var hits: [Int] = []
        scanner.forEach(isCancelled: { false }) { row, _ in hits.append(row); return true }
        XCTAssertEqual(hits, [1])
        XCTAssertEqual(q.replacing(in: "f r", with: "$1\\"), "$1\\ r")
        XCTAssertFalse(q.isRegex)
    }

    func testRegexSearchOfATruncatedFileDoesNotCrash() throws {
        let url = try file(Data((0..<3000).map { "line \($0)" }.joined(separator: "\n").utf8))
        let (source, index) = try indexed(url, .utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 100)
        try handle.close()
        let q = try XCTUnwrap(LargeFileQuery(#"line \d+"#, caseSensitive: true, regex: true, encoding: .utf8))
        let scanner = LargeFileRegexScanner(source: source, index: index, edits: LargeFileEdits(), regex: try XCTUnwrap(q.regex),
                                            encoding: .utf8, displayRows: index.progress.rows)
        var count = 0
        scanner.forEach(isCancelled: { false }) { _, _ in count += 1; return true }
        XCTAssertLessThan(count, 3000)
    }

    /// Long rows: batches are cut by bytes, not only rows, and a batch reports a count per row, never one entry
    /// per match (`.` over a 2 GB file would otherwise collect billions of ranges). Every match counts once.
    func testRegexCountsEveryMatchOnceAcrossByteSizedBatches() throws {
        let url = try file(Data(Array(repeating: String(repeating: "x", count: 10_000), count: 400).joined(separator: "\n").utf8))
        let (source, index) = try indexed(url, .utf8)
        let q = try XCTUnwrap(LargeFileQuery(".", caseSensitive: true, regex: true, encoding: .utf8))
        let scanner = LargeFileRegexScanner(source: source, index: index, edits: LargeFileEdits(), regex: try XCTUnwrap(q.regex),
                                            encoding: .utf8, displayRows: index.progress.rows)
        var total = 0, rows = 0
        scanner.forEach(isCancelled: { false }) { _, count in total += count; rows += 1; return true }
        XCTAssertEqual(total, 4_000_000)
        XCTAssertEqual(rows, 400)
        XCTAssertEqual(scanner.forward(display: 399, column: 9_999)?.1, NSRange(location: 9_999, length: 1))
    }

    /// An edit can't be taken while a reload reads the file again: the reload would drop it, with its undo.
    @MainActor
    func testNoEditWhileReloading() async throws {
        let url = try file(Data("a\nb\nc\n".utf8))
        let doc = LargeFileDocument(id: UUID(), encoding: .utf8)
        doc.attach(try LargeFileSource(url: url), encoding: .utf8)
        while !doc.progress.complete { try await Task.sleep(for: .milliseconds(10)) }
        let reload = Task { await doc.reload(url) }
        for _ in 0..<1000 where !doc.isReloading { await Task.yield() }
        XCTAssertTrue(doc.isReloading)
        XCTAssertFalse(doc.replaceRows(1...1, with: "B", actionName: "Edit"))
        let reloaded = await reload.value
        XCTAssertTrue(reloaded)
        XCTAssertFalse(doc.hasEdits)
        XCTAssertFalse(doc.isReloading)
    }

    /// Overwrite (or Save As onto the file) replaces the version there when the save started, not lines a log
    /// writer added while the new version was being written.
    func testInstallRefusesAFileThatChangedDuringTheWrite() throws {
        let url = try file(Data("one\n".utf8))
        let expected = try XCTUnwrap(LargeFileFingerprint.of(path: url.path))
        let tmp = try file(Data("ONE\n".utf8), "new.tmp")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()
        XCTAssertThrowsError(try LargeFileWriter.install(tmp, at: url, expected: expected, presenter: nil)) {
            XCTAssertEqual($0 as? LargeFileSaveError, .externalChange)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
        let now = try XCTUnwrap(LargeFileFingerprint.of(path: url.path))
        XCTAssertNoThrow(try LargeFileWriter.install(tmp, at: url, expected: now, presenter: nil))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ONE\n")
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}
