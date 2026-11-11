import AppKit
import XCTest
@testable import TinyEdit

@MainActor
final class ImagePasteTests: XCTestCase {
    func testScreenshotEnablesEveryPasteCommand() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.setData(Data([1, 2, 3]), forType: .png)
        pb.setData(Data([4, 5, 6]), forType: .tiff)
        XCTAssertEqual(PastedImage.content(of: pb), .image(Data([1, 2, 3])))
        XCTAssertTrue(PastedImage.canPaste(pb, recognizeImages: true))
        XCTAssertFalse(PastedImage.canPaste(pb, recognizeImages: false))

        let view = EditorTextView()
        view.isRichText = false
        view.canPasteboard = { _ in PastedImage.canPaste(pb, recognizeImages: true) }
        for action in [#selector(NSTextView.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)),
                       #selector(NSTextView.pasteAsRichText(_:))] {
            let item = NSMenuItem(title: "Paste", action: action, keyEquivalent: "")
            view.isEditable = true
            XCTAssertTrue(view.validateUserInterfaceItem(item))
            view.isEditable = false
            XCTAssertFalse(view.validateUserInterfaceItem(item))
        }
    }

    func testFilesRemainPasteableWhenImageRecognitionIsOff() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/example.md")
        pb.writeObjects([url as NSURL])
        XCTAssertTrue(PastedImage.canPaste(pb, recognizeImages: false))
        XCTAssertEqual(PastedImage.content(of: pb), .files([url]))
    }

    func testPNGRecognitionProducesText() async throws {
        let image = NSImage(size: NSSize(width: 600, height: 120))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 120).fill()
        ("TinyEdit OCR 12345" as NSString).draw(at: NSPoint(x: 30, y: 40), withAttributes: [
            .font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let text = try await ImageTextRecognizer.recognize([png], languageCorrection: false,
                                                          indent: .spaces(4), tabWidth: 4)
        XCTAssertTrue(text.contains("12345"), text)
    }
}
