import Foundation

/// A curl command as a browser's "Copy as cURL" (bash) or an API doc writes it, read without a shell: the words
/// are split with POSIX quoting rules and the options are turned into one HTTP request. Nothing is expanded or
/// run, so anything a shell would do beyond quoting (pipes, `;`, `$(…)`, variables, redirection) means the text is
/// not taken as a request at all. Pure: no network, no file system.
struct CurlCommand: Equatable, Sendable {
    struct Header: Equatable, Sendable {
        var name: String
        var value: String
    }

    var method: String
    var url: URL
    var headers: [Header] = []
    var body: Data?
    /// `-L`. curl does not follow redirects without it, so neither does the request.
    var followRedirects = false
    /// `-m` / `--max-time`, seconds.
    var maxTime: TimeInterval?
    /// The first option that cannot be honored (`-k`, `-d @file`, …), as written. Such a command is shown but not sent.
    var unsupported: String?

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `nil` unless the whole text is one curl command with an http(s) URL. Leading and trailing blanks, a `$ `
    /// prompt and `\` line continuations are fine; a second command or any shell syntax is not.
    static func parse(_ text: String) -> CurlCommand? {
        guard looksLikeCurl(text), var words = ShellWords.split(text) else { return nil }
        if words.first == "$" { words.removeFirst() }
        guard words.first == "curl" else { return nil }
        var builder = Builder()
        builder.read(Array(words.dropFirst()))
        return builder.command()
    }

    /// Cheap check before splitting: the first word is `curl`, after an optional `$ ` prompt.
    static func looksLikeCurl(_ text: String) -> Bool {
        var rest = text.drop { $0.isWhitespace }
        if rest.hasPrefix("$ ") { rest = rest.dropFirst(2).drop { $0 == " " } }
        guard rest.hasPrefix("curl") else { return false }
        let after = rest.dropFirst(4).first
        return after == nil || after!.isWhitespace || after == "\\"
    }

    /// The command the caret is in: the caret's line plus the lines joined to it by a trailing `\`. `nil` when that
    /// block does not start with `curl`.
    static func commandRange(around location: Int, in text: NSString) -> NSRange? {
        guard location <= text.length else { return nil }
        func continues(_ line: NSRange) -> Bool {
            var end = NSMaxRange(line)
            if end > line.location, text.character(at: end - 1) == 0x0A { end -= 1 }
            return end > line.location && text.character(at: end - 1) == 0x5C
        }
        var first = text.lineRange(for: NSRange(location: location, length: 0))
        var last = first
        while first.location > 0 {
            let previous = text.lineRange(for: NSRange(location: first.location - 1, length: 0))
            guard continues(previous) else { break }
            first = previous
        }
        while continues(last), NSMaxRange(last) < text.length {
            last = text.lineRange(for: NSRange(location: NSMaxRange(last), length: 0))
        }
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        return looksLikeCurl(text.substring(with: range)) ? range : nil
    }

    // MARK: Options

    private enum Option {
        case request, header, data(DataKind), json, form(literal: Bool), user, cookie, userAgent, referer
        case maxTime, url, range, bearer
        /// Takes a value that changes nothing here (`-o`, `-w`, `--retry`, …).
        case ignoredValue
        /// Takes a value and cannot be honored (`-x`, `--cacert`, …).
        case unsupportedValue
        case get, head, location, noLocation
        case ignored
        case unsupported
    }

    private enum DataKind { case ascii, raw, binary, urlencode }

    private static let short: [Character: Option] = [
        "X": .request, "H": .header, "d": .data(.ascii), "F": .form(literal: false), "u": .user, "b": .cookie,
        "A": .userAgent, "e": .referer, "m": .maxTime, "r": .range,
        "o": .ignoredValue, "w": .ignoredValue, "c": .ignoredValue, "D": .ignoredValue,
        "T": .unsupportedValue, "x": .unsupportedValue, "E": .unsupportedValue, "K": .unsupportedValue,
        "U": .unsupportedValue, "C": .unsupportedValue, "Q": .unsupportedValue, "P": .unsupportedValue,
        "t": .unsupportedValue, "y": .unsupportedValue, "Y": .unsupportedValue, "z": .unsupportedValue,
        "G": .get, "I": .head, "L": .location,
        "s": .ignored, "S": .ignored, "v": .ignored, "i": .ignored, "f": .ignored, "g": .ignored, "N": .ignored,
        "O": .ignored, "J": .ignored, "R": .ignored, "#": .ignored, "0": .ignored, "1": .ignored, "2": .ignored,
        "3": .ignored, "4": .ignored, "6": .ignored, "q": .ignored, "B": .ignored, "Z": .ignored,
        "k": .unsupported, "n": .unsupported, "p": .unsupported, "j": .ignored, "l": .unsupported,
    ]

    private static let long: [String: Option] = [
        "request": .request, "header": .header,
        "data": .data(.ascii), "data-ascii": .data(.ascii), "data-raw": .data(.raw), "data-binary": .data(.binary),
        "data-urlencode": .data(.urlencode), "json": .json,
        "form": .form(literal: false), "form-string": .form(literal: true),
        "user": .user, "cookie": .cookie, "user-agent": .userAgent, "referer": .referer,
        "max-time": .maxTime, "url": .url, "range": .range, "oauth2-bearer": .bearer,
        "output": .ignoredValue, "write-out": .ignoredValue, "cookie-jar": .ignoredValue, "dump-header": .ignoredValue,
        "connect-timeout": .ignoredValue, "retry": .ignoredValue, "retry-delay": .ignoredValue,
        "retry-max-time": .ignoredValue, "max-redirs": .ignoredValue, "output-dir": .ignoredValue,
        "max-filesize": .ignoredValue, "limit-rate": .ignoredValue, "keepalive-time": .ignoredValue,
        "expect100-timeout": .ignoredValue, "trace": .ignoredValue, "trace-ascii": .ignoredValue,
        "stderr": .ignoredValue, "tls-max": .ignoredValue,
        "upload-file": .unsupportedValue, "proxy": .unsupportedValue, "proxy-user": .unsupportedValue,
        "cert": .unsupportedValue, "key": .unsupportedValue, "cacert": .unsupportedValue, "capath": .unsupportedValue,
        "pinnedpubkey": .unsupportedValue, "ciphers": .unsupportedValue, "config": .unsupportedValue,
        "resolve": .unsupportedValue, "connect-to": .unsupportedValue, "interface": .unsupportedValue,
        "unix-socket": .unsupportedValue, "abstract-unix-socket": .unsupportedValue, "dns-servers": .unsupportedValue,
        "doh-url": .unsupportedValue, "local-port": .unsupportedValue, "aws-sigv4": .unsupportedValue,
        "request-target": .unsupportedValue, "continue-at": .unsupportedValue, "quote": .unsupportedValue,
        "get": .get, "head": .head, "location": .location, "location-trusted": .unsupported, "no-location": .noLocation,
        "silent": .ignored, "show-error": .ignored, "verbose": .ignored, "include": .ignored, "fail": .ignored,
        "fail-with-body": .ignored, "fail-early": .ignored, "globoff": .ignored, "no-buffer": .ignored,
        "remote-name": .ignored, "remote-header-name": .ignored, "remote-time": .ignored, "compressed": .ignored,
        "http1.0": .ignored, "http1.1": .ignored, "http2": .ignored, "http2-prior-knowledge": .ignored,
        "http3": .ignored, "ipv4": .ignored, "ipv6": .ignored, "tlsv1": .ignored, "tlsv1.0": .ignored,
        "tlsv1.1": .ignored, "tlsv1.2": .ignored, "tlsv1.3": .ignored, "no-keepalive": .ignored,
        "tcp-nodelay": .ignored, "tcp-fastopen": .ignored, "progress-bar": .ignored, "no-progress-meter": .ignored,
        "path-as-is": .ignored, "basic": .ignored, "anyauth": .ignored, "create-dirs": .ignored, "xattr": .ignored,
        "styled-output": .ignored, "no-styled-output": .ignored, "disable": .ignored, "ssl-no-revoke": .ignored,
        "ssl-reqd": .ignored, "junk-session-cookies": .ignored, "post301": .ignored, "post302": .ignored,
        "post303": .ignored, "raw": .ignored, "netrc-optional": .ignored, "no-compressed": .ignored,
        "insecure": .unsupported, "digest": .unsupported, "ntlm": .unsupported, "negotiate": .unsupported,
        "netrc": .unsupported, "proxy-insecure": .unsupported, "http3-only": .unsupported,
    ]

    /// Collects the options in order, then makes the request the way curl would.
    private struct Builder {
        var method: String?
        var urls: [String] = []
        var headers: [Header] = []
        var dataParts: [String] = []
        var jsonParts: [String] = []
        var formParts: [(name: String, value: String, type: String?)] = []
        var cookies: [String] = []
        var get = false
        var head = false
        var follow = false
        var maxTime: TimeInterval?
        var unsupported: String?

        mutating func reject(_ written: String) {
            if unsupported == nil { unsupported = written }
        }

        mutating func read(_ words: [String]) {
            var i = 0
            var optionsEnded = false
            func next() -> String? {
                i += 1
                return i < words.count ? words[i] : nil
            }
            while i < words.count {
                let word = words[i]
                defer { i += 1 }
                if optionsEnded || !word.hasPrefix("-") || word == "-" {
                    urls.append(word)
                    continue
                }
                if word == "--" { optionsEnded = true; continue }
                if word.hasPrefix("--") {
                    let name = String(word.dropFirst(2))
                    guard let option = CurlCommand.long[name] else {
                        // Unknown, so whether it takes a value is unknown too: the request cannot be trusted.
                        reject(word)
                        continue
                    }
                    if takesValue(option) {
                        guard let value = next() else { reject(word); continue }
                        apply(option, value: value, written: word)
                    } else {
                        apply(option, value: nil, written: word)
                    }
                    continue
                }
                // Short options combine (`-sSL`); one that takes a value takes the rest of the word or the next word.
                var letters = Substring(word.dropFirst())
                while let letter = letters.first {
                    letters = letters.dropFirst()
                    let written = "-" + String(letter)
                    guard let option = CurlCommand.short[letter] else { reject(written); break }
                    if takesValue(option) {
                        let value = letters.isEmpty ? next() : String(letters)
                        letters = ""
                        guard let value else { reject(written); break }
                        apply(option, value: value, written: written)
                    } else {
                        apply(option, value: nil, written: written)
                    }
                }
            }
        }

        private func takesValue(_ option: Option) -> Bool {
            switch option {
            case .get, .head, .location, .noLocation, .ignored, .unsupported: false
            default: true
            }
        }

        private mutating func apply(_ option: Option, value: String?, written: String) {
            let value = value ?? ""
            switch option {
            case .request: method = value
            case .header: addHeader(value, written: written)
            case .data(let kind): addData(value, kind: kind, written: written)
            case .json:
                if value.hasPrefix("@") { reject(written + " @file") } else { jsonParts.append(value) }
            case .form(let literal): addForm(value, literal: literal, written: written)
            case .user:
                // Without a password curl asks for one.
                guard value.contains(":") else { return reject(written) }
                headers.append(Header(name: "Authorization", value: "Basic " + Data(value.utf8).base64EncodedString()))
            case .cookie:
                // Without `=` it names a cookie file.
                if value.contains("=") { cookies.append(value) } else { reject(written + " file") }
            case .userAgent: headers.append(Header(name: "User-Agent", value: value))
            case .referer: headers.append(Header(name: "Referer", value: value))
            case .maxTime: maxTime = TimeInterval(value).flatMap { $0 > 0 ? $0 : nil }
            case .url: urls.append(value)
            case .range: headers.append(Header(name: "Range", value: "bytes=" + value))
            case .bearer: headers.append(Header(name: "Authorization", value: "Bearer " + value))
            case .ignoredValue, .ignored: break
            case .unsupportedValue, .unsupported: reject(written)
            case .get: get = true
            case .head: head = true
            case .location: follow = true
            case .noLocation: follow = false
            }
        }

        /// `Name: value`; `Name;` sends an empty value; `Name:` removes a header curl would add, which changes
        /// nothing here. `@file` reads headers from a file.
        private mutating func addHeader(_ raw: String, written: String) {
            if raw.hasPrefix("@") { return reject(written + " @file") }
            if let colon = raw.firstIndex(of: ":") {
                let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
                let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !value.isEmpty else { return }
                headers.append(Header(name: name, value: value))
            } else if raw.hasSuffix(";") {
                let name = raw.dropLast().trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { headers.append(Header(name: name, value: "")) }
            }
        }

        private mutating func addData(_ value: String, kind: DataKind, written: String) {
            switch kind {
            case .ascii, .binary:
                if value.hasPrefix("@") { return reject(written + " @file") }
                dataParts.append(value)
            case .raw:
                dataParts.append(value)
            case .urlencode:
                // `content`, `=content`, `name=content`; `@file` and `name@file` read a file.
                if let eq = value.firstIndex(of: "=") {
                    let name = String(value[..<eq])
                    if name.contains("@") { return reject(written + " @file") }
                    let content = CurlCommand.urlEncoded(String(value[value.index(after: eq)...]))
                    dataParts.append(name.isEmpty ? content : name + "=" + content)
                } else if value.contains("@") {
                    reject(written + " @file")
                } else {
                    dataParts.append(CurlCommand.urlEncoded(value))
                }
            }
        }

        /// `name=value`, optionally `;type=…`. A value starting with `@` or `<` reads a file (not for `--form-string`).
        private mutating func addForm(_ raw: String, literal: Bool, written: String) {
            guard let eq = raw.firstIndex(of: "=") else { return reject(written) }
            let name = String(raw[..<eq])
            var value = String(raw[raw.index(after: eq)...])
            var type: String?
            if !literal {
                if value.hasPrefix("@") || value.hasPrefix("<") { return reject(written + " @file") }
                if let r = value.range(of: ";type=") {
                    type = String(value[r.upperBound...])
                    value = String(value[..<r.lowerBound])
                }
            }
            formParts.append((name, value, type))
        }

        func command() -> CurlCommand? {
            guard let raw = urls.first else { return nil }
            var unsupported = self.unsupported
            if urls.count > 1, unsupported == nil { unsupported = urls[1] }
            guard var components = CurlCommand.components(raw) else { return nil }
            if !["http", "https"].contains(components.scheme?.lowercased() ?? ""), unsupported == nil {
                unsupported = (components.scheme ?? "") + "://"
            }
            var headers = self.headers
            if let user = components.percentEncodedUser {
                let password = components.percentEncodedPassword ?? ""
                let pair = (user.removingPercentEncoding ?? user) + ":" + (password.removingPercentEncoding ?? password)
                if !headers.contains(where: { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                    headers.append(Header(name: "Authorization", value: "Basic " + Data(pair.utf8).base64EncodedString()))
                }
                components.user = nil
                components.password = nil
            }
            components.fragment = nil
            if !cookies.isEmpty {
                let joined = cookies.joined(separator: "; ")
                if let i = headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }) {
                    headers[i].value += "; " + joined
                } else {
                    headers.append(Header(name: "Cookie", value: joined))
                }
            }
            // URLSession sets these itself, Accept-Encoding included so that it can decode the body. A Host that
            // names another server cannot be sent.
            headers.removeAll { ["accept-encoding", "content-length", "connection"].contains($0.name.lowercased()) }
            let expectedHost = components.host?.lowercased() ?? ""
            let expectedHostPort = expectedHost + (components.port.map { ":\($0)" } ?? "")
            for header in headers where header.name.lowercased() == "host" {
                let named = header.value.trimmingCharacters(in: .whitespaces).lowercased()
                if named != expectedHost, named != expectedHostPort, unsupported == nil {
                    unsupported = "-H Host"
                }
            }
            headers.removeAll { $0.name.lowercased() == "host" }
            func hasHeader(_ name: String) -> Bool {
                headers.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }

            var body: Data?
            let hasData = !dataParts.isEmpty || !jsonParts.isEmpty
            if hasData, !formParts.isEmpty, unsupported == nil { unsupported = "-F" }
            if get, hasData {
                // -G moves the data into the query; sanitize raw bytes so percentEncodedQuery never traps.
                let data = (dataParts + jsonParts).map(CurlCommand.sanitizePercentEncodedQuery).joined(separator: "&")
                let existing = components.percentEncodedQuery
                let query = existing.map { $0.isEmpty ? data : $0 + "&" + data } ?? data
                components.percentEncodedQuery = query
            } else if !jsonParts.isEmpty {
                body = Data((dataParts.joined(separator: "&") + jsonParts.joined()).utf8)
                if !hasHeader("Content-Type") { headers.append(Header(name: "Content-Type", value: "application/json")) }
                if !hasHeader("Accept") { headers.append(Header(name: "Accept", value: "application/json")) }
            } else if !dataParts.isEmpty {
                body = Data(dataParts.joined(separator: "&").utf8)
                if !hasHeader("Content-Type") {
                    headers.append(Header(name: "Content-Type", value: "application/x-www-form-urlencoded"))
                }
            } else if !formParts.isEmpty {
                let boundary = "------------------------" + CurlCommand.boundaryToken()
                body = CurlCommand.multipart(formParts, boundary: boundary)
                if let i = headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                    // curl keeps a given multipart type and adds its boundary.
                    if !headers[i].value.contains("boundary=") { headers[i].value += "; boundary=" + boundary }
                } else {
                    headers.append(Header(name: "Content-Type", value: "multipart/form-data; boundary=" + boundary))
                }
            }
            guard let url = components.url, let host = url.host, !host.isEmpty else { return nil }

            let method = self.method?.uppercased() ?? (head ? "HEAD" : body != nil ? "POST" : "GET")
            if body != nil, ["GET", "HEAD"].contains(method), unsupported == nil {
                // URLSession does not send a body with GET or HEAD.
                unsupported = "-X \(method)"
            }
            return CurlCommand(method: method, url: url, headers: headers, body: body, followRedirects: follow,
                               maxTime: maxTime, unsupported: unsupported)
        }
    }

    /// curl adds `http://` to a URL without a scheme.
    private static func components(_ raw: String) -> URLComponents? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil
            ? "http://" + trimmed : trimmed
        guard let url = URL(string: withScheme) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    /// Makes a raw `-G -d` / `--json` query piece valid for `URLComponents.percentEncodedQuery`:
    /// keeps valid `%XX` escapes and query-allowed ASCII characters, and percent-encodes everything else.
    private static func sanitizePercentEncodedQuery(_ raw: String) -> String {
        func isHex(_ b: UInt8) -> Bool {
            (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
        }
        func isQueryAllowedASCII(_ b: UInt8) -> Bool {
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
                || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
                || b == 0x21 || b == 0x24 || b == 0x26 || b == 0x27 || b == 0x28 || b == 0x29
                || b == 0x2A || b == 0x2B || b == 0x2C || b == 0x3B || b == 0x3D
                || b == 0x3A || b == 0x40 || b == 0x2F || b == 0x3F
        }
        let hex = Array("0123456789ABCDEF".utf8)
        let bytes = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x25, i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
                out.append(contentsOf: [b, bytes[i + 1], bytes[i + 2]])
                i += 3
            } else if isQueryAllowedASCII(b) {
                out.append(b)
                i += 1
            } else {
                out.append(0x25)
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// curl's escaping: everything but RFC 3986 unreserved characters.
    static func urlEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func boundaryToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
    }

    private static func multipart(_ parts: [(name: String, value: String, type: String?)], boundary: String) -> Data {
        var out = ""
        for part in parts {
            out += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\"\r\n"
            if let type = part.type { out += "Content-Type: \(type)\r\n" }
            out += "\r\n\(part.value)\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }
}

/// What the suggestion card shows of a parsed command before it is sent.
struct CurlSummary: Equatable, Sendable {
    enum BodyKind: Equatable, Sendable { case json, form, multipart, text }

    var method: String
    /// With the port when it is not the scheme's default.
    var host: String
    /// Path and query.
    var path: String
    var headerNames: [String]
    var sendsCookies: Bool
    /// An Authorization header, or one whose name says it holds a token or key.
    var sendsCredentials: Bool
    var bodyBytes: Int
    var bodyKind: BodyKind?
    var unsupported: String?

    init(_ command: CurlCommand) {
        method = command.method
        let url = command.url
        let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
        host = (url.host ?? "") + (url.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? "")
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        if let query = url.query(percentEncoded: true) { path += "?" + query }
        self.path = path
        headerNames = command.headers.map(\.name)
        sendsCookies = command.header("Cookie") != nil
        sendsCredentials = command.headers.contains { header in
            let name = header.name.lowercased()
            return name == "authorization" || name == "proxy-authorization"
                || ["token", "api-key", "apikey", "secret", "session"].contains { name.contains($0) }
        }
        bodyBytes = command.body?.count ?? 0
        if let body = command.body {
            let type = command.header("Content-Type")?.lowercased() ?? ""
            if type.contains("json") || (try? JSONSerialization.jsonObject(with: body)) != nil {
                bodyKind = .json
            } else if type.hasPrefix("multipart/") {
                bodyKind = .multipart
            } else if type.contains("x-www-form-urlencoded") {
                bodyKind = .form
            } else {
                bodyKind = .text
            }
        }
        unsupported = command.unsupported
    }
}

/// POSIX shell word splitting for one command: quotes, backslashes, `$'…'` and line continuations. Returns `nil`
/// for anything a shell would do more with (operators, substitutions, variables, a second command).
enum ShellWords {
    static func split(_ text: String) -> [String]? {
        let s = Array(text.unicodeScalars)
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        var i = 0

        func finishWord() {
            if inWord { words.append(String(word)) }
            word = String.UnicodeScalarView()
            inWord = false
        }
        /// After `$`: what a shell would expand (`$name`, `${…}`, `$(…)`, `$1`, `$?`, …).
        func expands(at j: Int) -> Bool {
            guard j < s.count else { return false }
            let c = s[j]
            return c.isASCIIAlphanumeric || "_{(@*#?$!-".unicodeScalars.contains(c)
        }

        while i < s.count {
            let c = s[i]
            switch c {
            case " ", "\t":
                finishWord(); i += 1
            case "\n", "\r":
                // An unescaped line break ends the command: only blanks may follow.
                finishWord()
                guard s[i...].allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
                i = s.count
            case "\\":
                if i + 1 < s.count, s[i + 1] == "\n" {
                    i += 2
                } else if i + 2 < s.count, s[i + 1] == "\r", s[i + 2] == "\n" {
                    i += 3
                } else if i + 1 < s.count {
                    word.append(s[i + 1]); inWord = true; i += 2
                } else {
                    i += 1
                }
            case "'":
                guard let end = s[(i + 1)...].firstIndex(of: "'") else { return nil }
                word.append(contentsOf: s[(i + 1)..<end])
                inWord = true
                i = end + 1
            case "\"":
                var j = i + 1
                var closed = false
                while j < s.count {
                    let d = s[j]
                    if d == "\"" { closed = true; break }
                    if d == "`" || (d == "$" && expands(at: j + 1)) { return nil }
                    if d == "\\", j + 1 < s.count {
                        let e = s[j + 1]
                        if e == "\n" { j += 2; continue }
                        if "$`\"\\".unicodeScalars.contains(e) { word.append(e); j += 2; continue }
                    }
                    word.append(d)
                    j += 1
                }
                guard closed else { return nil }
                inWord = true
                i = j + 1
            case "$":
                if i + 1 < s.count, s[i + 1] == "'" {
                    guard let (piece, end) = ansiC(s, from: i + 2) else { return nil }
                    word.append(contentsOf: piece.unicodeScalars)
                    inWord = true
                    i = end
                } else if expands(at: i + 1) || (i + 1 < s.count && s[i + 1] == "\"") {
                    return nil
                } else {
                    word.append(c); inWord = true; i += 1
                }
            case "#" where !inWord:
                // A comment runs to the end of the line, which ends the command.
                while i < s.count, s[i] != "\n" { i += 1 }
            case "|", ";", "&", "<", ">", "(", ")", "`":
                return nil
            default:
                word.append(c); inWord = true; i += 1
            }
        }
        finishWord()
        return words
    }

    /// The body of `$'…'` starting at `start`, and the index after its closing quote. `\x` and octal escapes are
    /// bytes, decoded as UTF-8 together with the text around them.
    private static func ansiC(_ s: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        var bytes: [UInt8] = []
        var i = start
        func appendScalar(_ v: UInt32) {
            if let scalar = Unicode.Scalar(v) { bytes.append(contentsOf: Array(String(Character(scalar)).utf8)) }
        }
        /// Up to `count` hex digits at `i`, consumed.
        func hex(_ count: Int) -> UInt32? {
            var v: UInt32 = 0
            var n = 0
            while n < count, i < s.count, let d = s[i].hexValue { v = v << 4 | d; n += 1; i += 1 }
            return n > 0 ? v : nil
        }
        while i < s.count {
            let c = s[i]
            if c == "'" { return (String(decoding: bytes, as: UTF8.self), i + 1) }
            guard c == "\\", i + 1 < s.count else {
                appendScalar(c.value); i += 1; continue
            }
            let e = s[i + 1]
            i += 2
            switch e {
            case "n": bytes.append(0x0A)
            case "t": bytes.append(0x09)
            case "r": bytes.append(0x0D)
            case "a": bytes.append(0x07)
            case "b": bytes.append(0x08)
            case "e", "E": bytes.append(0x1B)
            case "f": bytes.append(0x0C)
            case "v": bytes.append(0x0B)
            case "\\", "'", "\"", "?": appendScalar(e.value)
            case "x":
                if let v = hex(2) { bytes.append(UInt8(v)) } else { bytes.append(contentsOf: Array("\\x".utf8)) }
            case "u", "U":
                if let v = hex(e == "u" ? 4 : 8) { appendScalar(v) } else { bytes.append(0x5C); appendScalar(e.value) }
            case "0"..."7":
                var v = e.value - 0x30
                var n = 0
                while n < 2, i < s.count, ("0"..."7").contains(s[i]) { v = v * 8 + s[i].value - 0x30; i += 1; n += 1 }
                bytes.append(UInt8(truncatingIfNeeded: v))
            default:
                bytes.append(0x5C); appendScalar(e.value)
            }
        }
        return nil
    }
}

private extension Unicode.Scalar {
    var hexValue: UInt32? {
        switch value {
        case 0x30...0x39: value - 0x30
        case 0x41...0x46: value - 0x41 + 10
        case 0x61...0x66: value - 0x61 + 10
        default: nil
        }
    }

    var isASCIIAlphanumeric: Bool {
        (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }
}
