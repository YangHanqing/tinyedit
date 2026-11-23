import Foundation

/// What came back for a sent `CurlCommand`.
struct CurlResponse: Sendable {
    var status: Int
    /// Sorted by name: `HTTPURLResponse` does not keep the order they arrived in.
    var headers: [CurlCommand.Header]
    var body: Data
    var mimeType: String?
    var textEncodingName: String?
    var elapsed: Duration
}

enum CurlFailure: Error, Equatable {
    case network(URLError.Code)
    case tooLarge
    case other
}

/// The response body as the card and a new tab show it.
enum CurlResponseBody: Equatable, Sendable {
    case empty
    case binary(mimeType: String?)
    /// Line breaks folded to LF; JSON pretty-printed.
    case text(String, language: EditorLanguage?)
}

/// Sends a `CurlCommand` with URLSession, in the app. Ephemeral: no cookie store, no cache, nothing written; only the
/// cookies and credentials the command itself carries are sent. Redirects are followed only with `-L`, as in curl.
enum CurlRunner {
    /// Time without any data before giving up; `-m` limits the whole request instead.
    static let idleTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 300
    /// Same cap as opening a file.
    static let maxResponseBytes = FileLoader.maxOpenBytes

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    static func request(for command: CurlCommand) -> URLRequest {
        var request = URLRequest(url: command.url)
        request.httpMethod = command.method
        request.httpShouldHandleCookies = false
        if let maxTime = command.maxTime { request.timeoutInterval = maxTime }
        for header in command.headers {
            if let existing = request.value(forHTTPHeaderField: header.name), !existing.isEmpty {
                // Repeated headers go out as one comma-separated field; cookies join with `; `.
                let separator = header.name.caseInsensitiveCompare("Cookie") == .orderedSame ? "; " : ", "
                request.setValue(existing + separator + header.value, forHTTPHeaderField: header.name)
            } else {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            }
        }
        request.httpBody = command.body
        return request
    }

    /// Throws `CancellationError` when the task is cancelled, otherwise `CurlFailure`.
    static func send(_ command: CurlCommand, configuration: URLSessionConfiguration = makeConfiguration()) async throws -> CurlResponse {
        if let maxTime = command.maxTime { configuration.timeoutIntervalForResource = maxTime }
        let session = URLSession(configuration: configuration,
                                 delegate: RedirectPolicy(follow: command.followRedirects, originURL: command.url),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (bytes, response) = try await session.bytes(for: request(for: command))
            guard let http = response as? HTTPURLResponse else { throw CurlFailure.other }
            if http.expectedContentLength > Int64(maxResponseBytes) { throw CurlFailure.tooLarge }
            var body: [UInt8] = []
            if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxResponseBytes { throw CurlFailure.tooLarge }
            }
            let headers = http.allHeaderFields.compactMap { key, value -> CurlCommand.Header? in
                guard let name = key as? String else { return nil }
                return CurlCommand.Header(name: name, value: "\(value)")
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return CurlResponse(status: http.statusCode, headers: headers, body: Data(body), mimeType: http.mimeType,
                                textEncodingName: http.textEncodingName, elapsed: clock.now - start)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw CurlFailure.network(error.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as CurlFailure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CurlFailure.other
        }
    }

    // MARK: Body

    private static let binaryTypes = ["image/", "audio/", "video/", "font/", "application/octet-stream", "application/pdf",
                                      "application/zip", "application/gzip", "application/x-", "application/wasm",
                                      "application/vnd.", "application/protobuf", "application/x-protobuf"]
    /// `application/x-www-form-urlencoded` and `application/x-ndjson` are text despite the `x-` prefix.
    private static let textTypes = ["application/x-www-form-urlencoded", "application/x-ndjson", "application/x-javascript",
                                    "application/x-yaml", "application/x-sh", "application/vnd.api+json"]

    static func body(of response: CurlResponse) -> CurlResponseBody {
        guard !response.body.isEmpty else { return .empty }
        let mime = response.mimeType?.lowercased() ?? ""
        let isText = textTypes.contains(mime) || mime.hasSuffix("+json") || mime.hasSuffix("+xml")
        if !isText, binaryTypes.contains(where: { mime.hasPrefix($0) }) { return .binary(mimeType: response.mimeType) }
        let utf16 = response.textEncodingName?.lowercased().hasPrefix("utf-16") == true
            || response.body.starts(with: [0xFF, 0xFE]) || response.body.starts(with: [0xFE, 0xFF])
        if !utf16, response.body.contains(0) { return .binary(mimeType: response.mimeType) }
        guard let decoded = decode(response.body, charset: response.textEncodingName) else {
            return .binary(mimeType: response.mimeType)
        }
        var text = LineEnding.normalizeToLF(decoded)
        let language = language(mime: mime, text: text)
        if language == .json, case .formatted(let out, _) = JSONFormatter.format(text: text, selection: nil) { text = out }
        return .text(text, language: language)
    }

    /// The charset the server named, else the same detection as opening a file (UTF-8, then GB18030).
    private static func decode(_ data: Data, charset: String?) -> String? {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) {
                    return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
                }
            }
        }
        return try? TextEncoding.decode(data).text
    }

    private static func language(mime: String, text: String) -> EditorLanguage? {
        if mime.contains("json") { return .json }
        if mime.contains("html") { return .html }
        if mime.contains("xml") { return .xml }
        if mime.contains("css") { return .css }
        if mime.contains("javascript") || mime.contains("ecmascript") { return .javascript }
        if mime.contains("yaml") { return .yaml }
        if mime.contains("markdown") { return .markdown }
        let sample = String(text.prefix(ContentLanguageDetector.sampleLimit))
        return ContentLanguageDetector.detect(sample, isComplete: sample.count == text.count)
    }

    /// "OK", "Not Found": the reason phrase for the common codes, else nothing.
    static func reason(for status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }
}

/// Stops at a redirect unless the command had `-L`; with `-L`, automatically follows only same-origin
/// `http`/`https` redirects without HTTPS→HTTP downgrade so credentials and cookies are never forwarded cross-origin.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let follow: Bool
    let originScheme: String
    let originHost: String
    let originPort: Int

    init(follow: Bool, originURL: URL) {
        self.follow = follow
        let scheme = originURL.scheme?.lowercased() ?? ""
        self.originScheme = scheme
        self.originHost = originURL.host?.lowercased() ?? ""
        self.originPort = originURL.port ?? (scheme == "https" ? 443 : 80)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard follow, let nextURL = request.url,
              let scheme = nextURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completionHandler(nil)
            return
        }
        // Never downgrade HTTPS to HTTP, and do not automatically follow cross-origin redirects with request headers.
        if originScheme == "https" && scheme != "https" {
            completionHandler(nil)
            return
        }
        let nextHost = nextURL.host?.lowercased() ?? ""
        let nextPort = nextURL.port ?? (scheme == "https" ? 443 : 80)
        guard scheme == originScheme, nextHost == originHost, nextPort == originPort else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
