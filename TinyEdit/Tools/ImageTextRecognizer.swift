import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text in pictures with Vision, on this Mac. Nothing is uploaded. macOS 26 uses the document
/// reader when opted in; otherwise all versions use the line recognizer. Both feed `ImageTextLayout`.
enum ImageTextRecognizer {
    enum Failure: Error { case unreadableImage }

    /// Longer sides are scaled down to this before recognition.
    static let maxPixelSize = 8192

    /// Each picture in order, separated by a blank line. `languageCorrection` is off for code, where it
    /// "fixes" identifiers into words.
    static func recognize(_ images: [Data], languageCorrection: Bool, indent: IndentStyle, tabWidth: Int, recognizeDocumentTables: Bool = false) async throws -> String {
        var texts: [String] = []
        for data in images {
            try Task.checkCancellation()
            let page = try await read(data, languageCorrection: languageCorrection, recognizeDocumentTables: recognizeDocumentTables)
            let text = ImageTextLayout.text(lines: page.lines, tables: page.tables, indent: indent, tabWidth: tabWidth)
            if !text.isEmpty { texts.append(text) }
        }
        try Task.checkCancellation()
        return texts.joined(separator: "\n\n")
    }

    private static func read(_ data: Data, languageCorrection: Bool, recognizeDocumentTables: Bool) async throws
        -> (lines: [ImageTextLayout.Line], tables: [ImageTextLayout.Table]) {
        guard let image = decode(data) else { throw Failure.unreadableImage }
        let size = CGSize(width: image.width, height: image.height)
        if #available(macOS 26, *), recognizeDocumentTables {
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.useLanguageCorrection = languageCorrection
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            request.textRecognitionOptions.recognitionLanguages = languages(supported: request.supportedRecognitionLanguages)
            guard let document = try await request.perform(on: image).first?.document else { return ([], []) }
            let lines = document.text.lines.map {
                ImageTextLayout.Line(text: $0.transcript, rect: $0.boundingBox.toImageCoordinates(size, origin: .upperLeft))
            }
            let tables = document.tables.map { table in
                ImageTextLayout.Table(rows: table.rows.map { $0.map(\.content.text.transcript) },
                                      rect: table.boundingRegion.boundingBox.toImageCoordinates(size, origin: .upperLeft))
            }
            return (lines, tables)
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages(supported: request.supportedRecognitionLanguages)
        let lines = try await request.perform(on: image).compactMap { observation in
            observation.topCandidates(1).first.map {
                ImageTextLayout.Line(text: $0.string, rect: observation.boundingBox.toImageCoordinates(size, origin: .upperLeft))
            }
        }
        return (lines, [])
    }

    /// Upright (EXIF orientation applied) and no larger than `maxPixelSize`. Nil when ImageIO cannot read it.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The user's languages that Vision reads, then Simplified and Traditional Chinese and English.
    static func languages(preferred: [String] = Locale.preferredLanguages, supported: [Locale.Language]) -> [Locale.Language] {
        var out: [Locale.Language] = []
        for identifier in preferred + ["zh-Hans", "zh-Hant", "en-US"] {
            let wanted = Locale.Language(identifier: identifier)
            guard let match = supported.first(where: { sameLanguage($0, wanted) }), !out.contains(match) else { continue }
            out.append(match)
        }
        return out
    }

    /// Same language and script: zh-Hans-CN matches zh-Hans but not zh-Hant; en-GB matches en-US.
    private static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let code = a.languageCode, code == b.languageCode else { return false }
        return Locale.Language(identifier: a.maximalIdentifier).script == Locale.Language(identifier: b.maximalIdentifier).script
    }
}
