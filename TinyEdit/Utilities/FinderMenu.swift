import Foundation

/// The link between Finder's “New Text File with TinyEdit” (the `TinyEditFinder` extension) and the app:
/// `<scheme>://new-text-file?dir=<absolute folder path>`. The scheme is the `TinyEditURLScheme` Info.plist value
/// (`tinyedit`, `tinyedit-debug` in Debug), the same in the app and the extension. Opening the link only adds an
/// Untitled tab whose first Save starts in that folder; it never writes a file, so any app or page may open it.
enum FinderMenu {
    static let action = "new-text-file"

    static var scheme: String? { Bundle.main.object(forInfoDictionaryKey: "TinyEditURLScheme") as? String }

    static func link(directory: URL, scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.queryItems = [URLQueryItem(name: "dir", value: directory.path)]
        return components.url
    }

    /// The folder a link asks for; nil for any other URL or a path that is not absolute.
    static func directory(from url: URL, scheme: String? = FinderMenu.scheme) -> URL? {
        guard let scheme, url.scheme?.lowercased() == scheme.lowercased(), url.host == action,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "dir" })?.value,
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
