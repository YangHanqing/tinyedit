import AppKit
import UniformTypeIdentifiers

/// What a paste holds, for reading text out of pictures. File references come first: a screenshot tool may put
/// the file, its path and its pixels on the pasteboard together, and Finder adds the file's icon as a TIFF,
/// so pixels are read only when there is no file and no text.
enum PastedImage {
    enum Content: Equatable {
        /// File references (`public.file-url`), images or not.
        case files([URL])
        /// Pixels with no text and no file reference beside them.
        case image(Data)
        /// Text or anything else: AppKit's own paste.
        case other
    }

    static let maxBytes = FileLoader.maxOpenBytes
    static let maxImages = 20

    /// Preferred first. Screenshots are PNG; TIFF is what most apps add beside their own format.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.bmp.identifier),
    ]

    static func content(of pasteboard: NSPasteboard) -> Content {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return .files(urls) }
        if pasteboard.types?.contains(.string) == true { return .other }
        guard let type = pasteboard.availableType(from: imageTypes), let data = pasteboard.data(forType: type),
              !data.isEmpty else { return .other }
        return .image(data)
    }

    /// Inspect advertised types only: menu validation must not load or recognize image bytes.
    static func canPaste(_ pasteboard: NSPasteboard, recognizeImages: Bool) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return recognizeImages && pasteboard.availableType(from: imageTypes) != nil
    }

    /// A picture ImageIO can read. SVG is text and opens as a tab.
    static func isImageFile(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// The files' bytes, read now: a screenshot tool's temporary file may be gone later. Files that cannot be
    /// read or are over `maxBytes` are left out.
    static func read(_ urls: [URL]) -> [Data] {
        urls.prefix(maxImages).compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes else { return nil }
            return try? Data(contentsOf: url)
        }
    }
}
