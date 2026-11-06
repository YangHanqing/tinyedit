import Foundation

enum TextEncoding: String, Codable, Sendable, CaseIterable {
    /// Raw values are stored in the session manifest: add cases, never rename them.
    case utf8, utf8BOM, utf16LE, utf16BE, gb18030

    var statusLabel: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 BOM"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .gb18030: "GB18030"
        }
    }

    /// Status-bar menu title. GB18030 is a superset of GBK and GB2312, so it reads and writes both.
    var menuLabel: String {
        switch self {
        case .utf8BOM: String(localized: "UTF-8 with BOM")
        case .gb18030: "GB18030 (GBK, GB2312)"
        default: statusLabel
        }
    }

    /// What "Reopen with Encoding" offers: the encodings that can be read from bytes without a BOM.
    /// UTF-16 is honored only with a BOM, which detection already finds.
    static let reopenChoices: [TextEncoding] = [.utf8, .gb18030]

    struct DecodeError: Error, Equatable {}

    private static let gb18030Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// Fixed detection order: BOM, then strict UTF-8, then GB18030. UTF-16 is honored only with a BOM.
    /// GB18030 is the one fallback, not a guess among many; text with a NUL is treated as binary there.
    /// Returned text keeps its original line endings.
    static func decode(_ data: Data) throws -> (text: String, encoding: TextEncoding) {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let s = String(data: data.dropFirst(3), encoding: .utf8) else { throw DecodeError() }
            return (s, .utf8BOM)
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { throw DecodeError() } // UTF-32 LE
        if bytes.starts(with: [0xFF, 0xFE]) {
            guard let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else { throw DecodeError() }
            return (s, .utf16LE)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            guard let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else { throw DecodeError() }
            return (s, .utf16BE)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        guard let s = decodeGB18030(data), !s.utf8.contains(0) else { throw DecodeError() }
        return (s, .gb18030)
    }

    /// GB18030 text only when it encodes back to the same bytes. Some bytes decode but do not round-trip
    /// (a lone 0x80, Windows-1252's euro sign, reads as € and is written back as A2 E3), so saving such a
    /// file, even unedited, would change bytes the user never touched. Those files are not opened.
    private static func decodeGB18030(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: gb18030Encoding), s.data(using: gb18030Encoding) == data else { return nil }
        return s
    }

    /// Decodes as the encoding the user picked. A UTF-8 BOM is a fact of the bytes, so either UTF-8
    /// case reads both and reports which one the file is. UTF-16 still needs its BOM.
    static func decode(_ data: Data, as encoding: TextEncoding) throws -> (text: String, encoding: TextEncoding) {
        switch encoding {
        case .utf8, .utf8BOM:
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                guard let s = String(data: data.dropFirst(3), encoding: .utf8) else { throw DecodeError() }
                return (s, .utf8BOM)
            }
            guard let s = String(data: data, encoding: .utf8) else { throw DecodeError() }
            return (s, .utf8)
        case .gb18030:
            guard let s = decodeGB18030(data) else { throw DecodeError() }
            return (s, .gb18030)
        case .utf16LE, .utf16BE:
            let result = try decode(data)
            guard result.encoding == encoding else { throw DecodeError() }
            return result
        }
    }

    func encode(_ text: String) throws -> Data {
        switch self {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LE:
            guard let d = text.data(using: .utf16LittleEndian) else { throw EncodeError() }
            return Data([0xFF, 0xFE]) + d
        case .utf16BE:
            guard let d = text.data(using: .utf16BigEndian) else { throw EncodeError() }
            return Data([0xFE, 0xFF]) + d
        case .gb18030:
            guard let d = text.data(using: Self.gb18030Encoding) else { throw EncodeError() }
            return d
        }
    }

    struct EncodeError: Error, Equatable {}
}
