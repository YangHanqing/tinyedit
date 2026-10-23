import UniformTypeIdentifiers
import XCTest
@testable import TinyEdit

/// Settings ▸ Default App lists only types Launch Services can assign, and TinyEdit declares
/// every one of them, so Change All on an example file always offers TinyEdit.
final class DefaultAppTests: XCTestCase {
    func testEveryFormatResolvesToADeclaredTextType() {
        let formats = DefaultAppFormat.all
        XCTAssertEqual(formats.count, 13, "a listed extension no longer has a system type")
        XCTAssertEqual(Set(formats.map(\.id)).count, formats.count)
        for format in formats {
            XCTAssertFalse(format.type.isDynamic, format.id)
            XCTAssertTrue(format.type.conforms(to: .text), format.id)
            XCTAssertTrue(format.extensions.hasPrefix("."), format.id)
        }
        XCTAssertEqual(formats.first?.type, .plainText)
    }

    func testInfoPlistClaimsEveryFormat() throws {
        let documentTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let claimed = documentTypes
            .filter { $0["CFBundleTypeRole"] as? String == "Editor" }
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .compactMap(UTType.init)
        for format in DefaultAppFormat.all {
            XCTAssertTrue(claimed.contains { format.type.conforms(to: $0) }, format.id)
        }
    }

    @MainActor
    func testRefreshReadsAHandlerForPlainText() {
        let model = DefaultAppModel()
        model.refresh()
        // Every Mac has at least TextEdit for plain text.
        XCTAssertNotNil(model.handlers[UTType.plainText.identifier])
        XCTAssertEqual(model.pendingFormats.count + model.formats.filter(model.opensWithTinyEdit).count, model.formats.count)
    }

    /// Change All in Finder applies to the example's type, so it must be the format's own.
    @MainActor
    func testExampleFileHasTheFormatsType() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = DefaultAppModel(examples: folder)
        for format in model.formats {
            let url = try model.exampleFile(for: format)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), format.id)
            XCTAssertEqual(try Data(contentsOf: url), Data(format.sample.utf8), format.id)
            XCTAssertEqual(UTType(filenameExtension: url.pathExtension), format.type, format.id)
            XCTAssertEqual(try model.exampleFile(for: format), url)
        }
    }

    /// Earlier versions wrote empty examples, which macOS can report as damaged; they are refilled.
    @MainActor
    func testExampleFileReplacesAnEmptyOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = DefaultAppModel(examples: folder)
        let format = try XCTUnwrap(model.formats.first)
        let url = try model.exampleFile(for: format)
        try Data().write(to: url)
        _ = try model.exampleFile(for: format)
        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
    }
}
