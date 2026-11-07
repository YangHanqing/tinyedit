import XCTest
@testable import TinyEdit

final class EncodingTests: XCTestCase {
    func roundTrip(_ enc: TextEncoding) throws {
        let text = "héllo 你好 😀\n"
        let (decoded, detected) = try TextEncoding.decode(try enc.encode(text))
        XCTAssertEqual(decoded, text)
        XCTAssertEqual(detected, enc)
        XCTAssertFalse(decoded.contains("\u{FEFF}"))
    }
    func testRoundTrips() throws {
        try roundTrip(.utf8); try roundTrip(.utf8BOM); try roundTrip(.utf16LE); try roundTrip(.utf16BE)
        try roundTrip(.gb18030)
    }

    private static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))

    func testGBKAndGB2312BytesOpenAsGB18030AndSaveUnchanged() throws {
        let text = "中文测试，GBK 编码\n"
        let gbk = try XCTUnwrap(text.data(using: Self.gbk))
        let (decoded, detected) = try TextEncoding.decode(gbk)
        XCTAssertEqual(decoded, text)
        XCTAssertEqual(detected, .gb18030)
        XCTAssertEqual(try TextEncoding.gb18030.encode(decoded), gbk)
    }

    func testGB18030FallbackRejectsNULs() {
        // Valid GB18030 pairs, but a NUL: binary, not text.
        XCTAssertThrowsError(try TextEncoding.decode(Data([0xD6, 0xD0, 0x00, 0xCE, 0xC4])))
    }

    func testGB18030RejectsBytesThatWouldNotSaveBackUnchanged() {
        // Windows-1252 "Price €1": 0x80 reads as € but is written back as A2 E3, so a save would change the file.
        let bytes = Data("Price ".utf8) + Data([0x80]) + Data("1".utf8)
        XCTAssertThrowsError(try TextEncoding.decode(bytes))
        XCTAssertThrowsError(try TextEncoding.decode(bytes, as: .gb18030))
    }

    func testUTF8BytesStayUTF8EvenThoughGB18030CouldReadThem() throws {
        XCTAssertEqual(try TextEncoding.decode(Data("你好".utf8)).encoding, .utf8)
        XCTAssertEqual(try TextEncoding.decode(Data("你好".utf8), as: .gb18030).encoding, .gb18030)
    }

    func testDecodeAsUTF8ReportsTheBOMFromTheBytes() throws {
        XCTAssertEqual(try TextEncoding.decode(Data([0xEF, 0xBB, 0xBF, 0x41]), as: .utf8).encoding, .utf8BOM)
        XCTAssertEqual(try TextEncoding.decode(Data([0x41]), as: .utf8BOM).encoding, .utf8)
        XCTAssertThrowsError(try TextEncoding.decode(Data("中".data(using: Self.gbk)!), as: .utf8))
        XCTAssertThrowsError(try TextEncoding.decode(Data([0x41, 0x00]), as: .utf16LE)) // UTF-16 needs its BOM
    }

    func testPreferKeepsTheBufferEncodingAndFallsBackToDetection() throws {
        let utf8 = Data("你好".utf8)
        XCTAssertEqual(try FileLoader.make(from: utf8, decoding: .prefer(.gb18030)).encoding, .gb18030)
        let gbk = try XCTUnwrap("你好".data(using: Self.gbk))
        XCTAssertEqual(try FileLoader.make(from: gbk, decoding: .prefer(.utf8)).encoding, .gb18030)
        XCTAssertThrowsError(try FileLoader.make(from: gbk, decoding: .force(.utf8)))
    }
    func testBOMFollowedByGarbageRejected() {
        XCTAssertThrowsError(try TextEncoding.decode(Data([0xEF, 0xBB, 0xBF, 0xC3, 0x28])))
    }
    func testUTF32LEBOMRejected() {
        XCTAssertThrowsError(try TextEncoding.decode(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])))
    }

    /// The beginning of a file too large to open decodes as the whole file would: a cut inside a character
    /// must not turn UTF-8 into GB18030 mojibake or lose the encoding.
    func testHeadOfALargeFileIsAPrefixInTheFilesEncoding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("head-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = String(repeating: "héllo 你好 😀 中文\n", count: 50)
        let oneLine = String(repeating: "你好😀é", count: 50)
        for enc in TextEncoding.allCases {
            for text in [lines, oneLine] {
                let data = try enc.encode(text)
                try data.write(to: url)
                for cut in (data.count - 9)...(data.count - 1) {
                    let head = try FileLoader.loadHead(of: url, maxBytes: cut)
                    XCTAssertEqual(head.encoding, enc, "\(enc) cut at \(cut)")
                    XCTAssertTrue(text.hasPrefix(head.logicalLF), "\(enc) cut at \(cut)")
                    XCTAssertGreaterThan(head.logicalLF.count, text.count * 3 / 4, "\(enc) cut at \(cut)")
                    if text == lines { XCTAssertTrue(head.logicalLF.hasSuffix("\n"), "\(enc) cut at \(cut)") }
                }
            }
        }
    }
}
