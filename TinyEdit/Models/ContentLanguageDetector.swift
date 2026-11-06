import Foundation

/// Conservative, local-only heuristics. Ambiguous text stays Plain Text.
/// Rules run from the most specific signature to the loosest, so a later rule may assume the earlier ones failed.
enum ContentLanguageDetector {
    static let sampleLimit = 32_768
    /// The regex rules read only the head of the sample; the linear JSON scan reads all of it.
    private static let ruleSampleLimit = 8_192
    /// Line-shape rules (YAML, INI, shell) look at no more than this many lines.
    private static let lineLimit = 400

    static func detect(_ text: String, isComplete: Bool = true) -> EditorLanguage? {
        let full = String(text.prefix(sampleLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return nil }
        let script = EditorLanguage.detect(fileName: "", text: full)
        if script != .plain { return script }
        if full.first == "{" || full.first == "[", isJSON(full, isComplete: isComplete) { return .json }

        var head = full
        if !isComplete || head.utf8.count > ruleSampleLimit {
            // Cutting mid-character leaves a replacement character, which goes with the cut-off last line:
            // a truncated sample ends mid-line, and line-shape rules must not see the cut.
            head = String(decoding: head.utf8.prefix(ruleSampleLimit), as: UTF8.self)
            if let cut = head.lastIndex(of: "\n") { head = String(head[..<cut]) }
        }
        let s = Sample(head)
        if s.has(#"\A(?:diff |--- |Index: |From [0-9a-f]{7,40} )"#), s.has(#"(?m)^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@"#) { return .diff }
        if s.has(#"(?m)^\s*```[^\n]*\n[\s\S]+?\n\s*```\s*$"#) { return .markdown }
        if s.text.contains("<?php") { return .php }
        if let markup = markup(s) { return markup }
        if s.has(#"\\documentclass(?:\[[^\]\n]*\])?\{"#) ||
           (s.has(#"\\begin\{\w+\*?\}"#) && s.has(#"\\end\{"#) && s.has(#"\\(?:section|subsection|usepackage|item|label|textbf|emph)\b"#)) { return .latex }
        if let first = s.lines.first(where: { !$0.hasPrefix("#") }), first.range(of: #"^(?:FROM|ARG)\s+\S"#, options: .regularExpression) != nil,
           s.has(#"(?m)^(?:RUN|COPY|ADD|WORKDIR|CMD|ENTRYPOINT|ENV|EXPOSE)\s"#) { return .dockerfile }
        if let code = compiled(s) ?? scripting(s) ?? web(s) { return code }
        if let data = sql(s) ?? css(s) { return data }
        if s.has(#"(?m)^\.PHONY\s*:"#) || s.has(#"(?m)^[\w.%/$(){}-]+(?:[ ]+[\w.%/$(){}-]+)*[ ]*:(?!=)[^\n]*\n\t\S"#) { return .makefile }
        if isYAML(s.rawLines) { return .yaml }
        if let config = keyValueConfig(s.lines) { return config }
        if isShell(s.lines) { return .shell }
        return markdown(s)
    }

    // MARK: Rule groups

    private static func markup(_ s: Sample) -> EditorLanguage? {
        if s.has(#"(?i)\A(?:<!--[\s\S]*?-->\s*)?(?:<!doctype\s+html\b|<html(?:\s|>))"#) { return .html }
        if s.text.hasPrefix("<?xml") { return .xml }
        guard s.text.hasPrefix("<"), s.has(#"</[\w:.-]+\s*>|/>"#) else { return nil }
        if s.has(#"\A<(?:svg\b|[\w.-]+:)"#) || s.has(#"\A<[^>]*\bxmlns[:=]"#) { return .xml }
        let htmlTags = #"(?i)<(?:div|span|p|a|ul|ol|li|table|tr|td|th|head|body|script|style|section|article|nav|header|footer|main|img|br|form|input|button|label|select|option|textarea|h[1-6]|template|meta|link)[\s/>]"#
        return s.has(htmlTags) ? .html : .xml
    }

    /// C family, Java, C#, Kotlin, Go, Rust and Swift: each needs a signature no other supported language shares.
    private static func compiled(_ s: Sample) -> EditorLanguage? {
        if s.has(#"(?m)^\s*#(?:include\s*[<"]|define\s+\w+|ifndef\s+\w+|pragma\s+once)"#) {
            let cpp = #"std::|#include\s*<(?:iostream|vector|string|map|memory|algorithm)>|\b(?:namespace\s+\w+|template\s*<|class\s+\w+|public:|private:|nullptr)"#
            return s.has(cpp) ? .cpp : .c
        }
        if s.has(#"(?m)^\s*using\s+System(?:\.[\w.]+)?\s*;"#) || s.has(#"\bConsole\.Write(?:Line)?\("#) ||
           s.has(#"\{\s*get;\s*(?:(?:private|init)\s+)?set;\s*\}"#) || s.has(#"(?m)^\s*namespace\s+[\w.]+\s*;"#) { return .csharp }
        if s.has(#"(?m)^\s*package\s+[\w.]+\s*;"#) || s.has(#"(?m)^\s*import\s+(?:static\s+)?[\w.]+(?:\.\*)?\s*;"#) ||
           s.has(#"\bSystem\.out\.print"#) || s.has(#"(?m)^\s*public\s+(?:(?:static|final|abstract|sealed)\s+)*(?:class|interface|enum|record)\s+\w+"#) { return .java }
        if s.has(#"(?m)^\s*(?:(?:private|public|internal|protected|override|open|suspend|inline|operator|infix)\s+)*fun\s+(?:<[^>\n]+>\s*)?[\w.]+\s*\("#) ||
           s.has(#"(?m)^\s*data\s+class\s+\w+\s*\("#) { return .kotlin }
        if (s.has(#"(?m)^func\s"#) && (s.has(#"(?m)^package\s+\w+\s*$"#) || s.has(":=") || s.has(#"\bfmt\.\w+\("#) || s.has(#"\berr\s*!=\s*nil\b"#))) ||
           (s.has(#"(?m)^package\s+\w+\s*$"#) && s.has(#"(?m)^import\s+(?:"|\()"#)) { return .go }
        if s.has(#"(?m)^\s*(?:pub(?:\([^)\n]*\))?\s+)?(?:(?:async|const|unsafe)\s+)*fn\s+\w+\s*[<(]"#) ||
           s.has(#"(?m)^\s*use\s+(?:std|crate|super)::"#) || s.has(#"(?m)^\s*#\[derive\("#) { return .rust }
        if s.has(#"(?m)^\s*import\s+(?:Foundation|SwiftUI|AppKit|UIKit|Combine|XCTest|Testing|Observation|CryptoKit)\b"#) ||
           s.has(#"\bsome\s+View\b"#) { return .swift }
        let swiftFunc = #"(?m)^\s*(?:(?:@\w+|private|fileprivate|internal|public|open|static|class|override|mutating|nonisolated)\s+)*func\s+\w+"#
        let swiftDecl = #"(?m)^\s*(?:(?:private|fileprivate|public|final)\s+)*(?:struct|class|enum|extension|protocol|actor)\s+\w+(?:<[^>\n]*>)?:\s*\w[\w, .]*\{"#
        if (s.has(swiftFunc) || s.has(swiftDecl)),
           s.has(#"->|\bguard\s|\b(?:let|var)\s+\w+\s*(?::\s*\w|=)|(?m)^\s*@\w+"#) { return .swift }
        return nil
    }

    /// Python, Ruby, Lua and PowerShell.
    private static func scripting(_ s: Sample) -> EditorLanguage? {
        if s.has(#"(?m)^\s*(?:async\s+)?def\s+\w+\s*\([^\n]*\)\s*(?:->[^\n]+)?:"#) || s.has(#"(?m)^from\s+\.*[\w.]*\s+import\s+\S"#) ||
           s.has(#"\bif\s+__name__\s*=="#) || s.has(#"(?m)^class\s+\w+(?:\([^)\n]*\))?:\s*$"#) { return .python }
        let pythonHints = [#"(?m)^\s*(?:if|elif|while|for|with|except)\b[^\n;{}]*:\s*(?:#.*)?$"#, #"(?m)^\s*(?:else|try|finally)\s*:\s*$"#,
                           #"(?m)^import\s+[\w.]+(?:\s+as\s+\w+)?(?:\s*,\s*[\w.]+(?:\s+as\s+\w+)?)*\s*$"#,
                           #"\bprint\("#, #"\bself\.\w"#, #"\b(?:None|True|False)\b"#]
        if pythonHints.filter(s.has).count >= 2 { return .python }
        let blockEnd = s.has(#"(?m)^\s*end\s*$"#)
        if blockEnd, s.has(#"(?m)^\s*(?:def\s+(?:self\.)?\w+[!?=]?(?:\([^)\n]*\))?|class\s+\w+(?:\s*<\s*[\w:]+)?)\s*$"#) || s.has(#"\bdo\s*\|[^|\n]*\|"#) { return .ruby }
        if s.has(#"(?m)^\s*require(?:_relative)?\s+['"]"#), s.has(#"(?m)^\s*puts\s"#) { return .ruby }
        if s.has(#"(?m)^\s*end\s*[,)]?\s*$"#), s.has(#"(?m)^\s*(?:local\s+\w+|(?:local\s+)?function\s+[\w.:]+\s*\()"#) { return .lua }
        if s.has(#"\b(?:Get|Set|New|Remove|Write|Invoke|Import|Export|Start|Stop|Test|Add|Out|Select|Where|ForEach)-[A-Z]\w+"#),
           s.has(#"\$\w+|\s-[A-Z]\w+"#) { return .powershell }
        return nil
    }

    private static func web(_ s: Sample) -> EditorLanguage? {
        let typeScript = [
            #"(?m)^\s*(?:export\s+)?(?:declare\s+)?interface\s+\w+(?:<[^>\n]*>)?(?:\s+extends\s+[^{\n]+)?\s*\{"#,
            #"(?m)^\s*(?:export\s+)?type\s+\w+(?:<[^>\n]*>)?\s*="#,
            #"(?m)^\s*(?:export\s+)?(?:const|let)\s+\w+\s*:\s*(?:string|number|boolean|any|unknown|never|Record<|Promise<|Array<)"#,
            #"(?m)^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\w*\s*(?:<[^>\n]*>)?\([^)\n]*\b\w+\??:\s*[\w<>\[\]|'" ]+[,)]"#,
            #"\(\s*\w+\??\s*:\s*[\w<>\[\]|]+(?:\s*,\s*\w+\??\s*:\s*[\w<>\[\]|]+)*\s*\)\s*(?::\s*[\w<>\[\]|]+\s*)?=>"#,
            #"(?m)^\s*(?:private|public|protected)\s+(?:readonly\s+)?\w+\??\s*:\s*\w"#,
            #"(?m)^\s*import\s+type\s"#, #"\bas\s+const\b"#, #"(?m)^\s*(?:export\s+)?(?:abstract\s+)?class\s+\w+[^{\n]*\bimplements\b"#,
        ]
        if typeScript.contains(where: s.has) { return .typescript }
        let javaScript = [
            #"(?m)^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*\*?\s*\w*\s*\([^\n]*\)\s*\{"#,
            #"(?m)^\s*(?:export\s+)?(?:const|let|var)\s+\w+\s*=\s*(?:async\s+)?(?:\([^)\n]*\)|\w+)\s*=>"#,
            #"(?m)^\s*import\s+(?:[\w*{}\s,]+\s+from\s+)?['"][^'"\n]+['"];?\s*$"#,
            #"(?m)^\s*export\s+(?:default|const|let|function|class|async)\b"#,
            #"\bmodule\.exports\b|\brequire\(\s*['"][^'"\n]+['"]\s*\)"#,
            #"\b(?:console\.(?:log|error|warn|info)|document\.(?:querySelector(?:All)?|getElementById)|addEventListener)\s*\("#,
        ]
        return javaScript.contains(where: s.has) ? .javascript : nil
    }

    private static func sql(_ s: Sample) -> EditorLanguage? {
        let statements = [
            #"(?ims)^\s*(?:with\s+\w+\s+as\s*\(|select\s).{0,2000}?\bfrom\s+[\w."`\[(]"#,
            #"(?im)^\s*insert\s+into\s+[\w."`\[]"#, #"(?im)^\s*update\s+[\w."`\[\]]+\s+set\s+\w"#, #"(?im)^\s*delete\s+from\s+[\w."`\[]"#,
            #"(?im)^\s*(?:create|alter|drop)\s+(?:or\s+replace\s+)?(?:temporary\s+)?(?:table|view|index|unique\s+index|database|schema|function|procedure|trigger)\b"#,
        ]
        guard statements.contains(where: s.has) else { return nil }
        // Prose such as "Select the best option from the list" also matches; real SQL shows one more sign.
        let confirmed = s.has(#"\b(?:SELECT|FROM|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)\b"#) || s.has(#"(?m);\s*$"#) ||
            s.has(#"(?i)\b(?:where|join|group\s+by|order\s+by|values|limit)\b"#) || s.has(#"(?i)\bfrom\s+\w+\s*$"#)
        return confirmed ? .sql : nil
    }

    private static func css(_ s: Sample) -> EditorLanguage? {
        let block = s.has(#"(?m)^[^\n{};]+\{[ \t]*$"#) || s.has(#"\S[ \t]*\{[ \t]*[\w-]+\s*:[^{}\n]+;\s*\}"#)
        guard block, s.count(#"(?m)^\s*-{0,2}[a-zA-Z][\w-]*\s*:\s*[^;{}\n]+;\s*$"#) >= 2 || s.has(#"\{\s*[\w-]+\s*:[^{}\n]+;\s*\}"#) else { return nil }
        return s.has(#"(?m)^\s*[$@][\w-]+\s*:|@(?:mixin|include|extend)\b|&[:.\-&]"#) ? .scss : .css
    }

    /// Every line must be a key, a list item, a comment, a document marker or part of a block scalar.
    /// Short key lists ("Todo: buy milk", "Ingredients:" with indented amounts) stay Plain Text.
    private static func isYAML(_ lines: [Substring]) -> Bool {
        var keys = 0, nested = false, listOrMarker = false, blockScalarIndent: Int?
        for line in lines.prefix(lineLimit) where !line.allSatisfy(\.isWhitespace) {
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            if indentation.contains("\t") { return false }
            if let block = blockScalarIndent, indentation.count > block { continue }
            blockScalarIndent = nil
            var body = line.dropFirst(indentation.count).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("#") { continue }
            if body == "---" || body == "..." { listOrMarker = true; continue }
            let listItem = body == "-" || body.hasPrefix("- ")
            if listItem { listOrMarker = true; body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let key = body.range(of: #"^(?:[\w.\-/]+|"[^"\n]*"|'[^'\n]*')\s*:(?=\s|$)"#, options: .regularExpression) else {
                if listItem { continue }
                return false
            }
            keys += 1
            if !indentation.isEmpty { nested = true }
            if body[key.upperBound...].range(of: #"^\s*[|>][-+]?\d*\s*(?:#.*)?$"#, options: .regularExpression) != nil {
                blockScalarIndent = indentation.count
            }
        }
        return keys >= 2 && (listOrMarker || (nested && keys >= 4))
    }

    /// TOML and INI need a section header; extension-less `.env` files need upper-case keys.
    private static func keyValueConfig(_ lines: [String]) -> EditorLanguage? {
        var sections = 0, keys = 0, upperKeys = 0, tomlValues = 0, bareValues = 0
        var openBrackets = 0, openString: String?     // inside a TOML array or `"""` string spanning lines
        for line in lines.prefix(lineLimit) {
            if let quote = openString {
                if line.contains(quote) { openString = nil }
                continue
            }
            if openBrackets > 0 { openBrackets = max(0, openBrackets + bracketBalance(line)); continue }
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.range(of: #"^\[\[?[\w.\- "']+\]\]?$"#, options: .regularExpression) != nil {
                sections += 1
                if line.hasPrefix("[[") { tomlValues += 1 }
                continue
            }
            guard let eq = line.firstIndex(of: "="),
                  line[..<eq].range(of: #"^\s*[\w.\-"']+\s*$"#, options: .regularExpression) != nil else { return nil }
            keys += 1
            if line[..<eq].range(of: #"^[A-Z][A-Z0-9_]*$"#, options: .regularExpression) != nil { upperKeys += 1 }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = ["\"\"\"", "'''"].first(where: value.hasPrefix) {
                tomlValues += 1
                if !value.dropFirst(3).contains(quote) { openString = quote }
                continue
            }
            if value.hasPrefix("[") { openBrackets = max(0, bracketBalance(value)) }
            if value.range(of: #"^(?:["'\[{]|\d{4}-\d{2}-\d{2})"#, options: .regularExpression) != nil { tomlValues += 1 }
            else if value.range(of: #"^(?:true|false|[-+]?\d[\d_]*(?:\.\d+)?)$"#, options: .regularExpression) == nil { bareValues += 1 }
        }
        guard keys > 0 else { return nil }
        if sections > 0 { return tomlValues > 0 && bareValues == 0 ? .toml : .ini }
        return keys >= 2 && upperKeys == keys ? .ini : nil
    }

    /// Open `[` minus `]` on a line, outside quotes and before a `#` comment.
    private static func bracketBalance(_ line: some StringProtocol) -> Int {
        var depth = 0, quote: Character?, escaped = false
        for ch in line {
            if let q = quote {
                if escaped { escaped = false } else if ch == "\\", q == "\"" { escaped = true } else if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case "[": depth += 1
            case "]": depth -= 1
            case "#": return depth
            default: break
            }
        }
        return depth
    }

    /// Mostly command or control-flow lines. Commands that are also everyday English words (go, make, open, find) are left out.
    private static func isShell(_ lines: [String]) -> Bool {
        let command = #"^(?:\$\s+)?(?:sudo\s+)?(?:cd|echo|export|source|alias|unset|brew|npm|npx|yarn|pnpm|pip3?|python3?|node|git|curl|wget|chmod|chown|mkdir|rm|cp|mv|ls|grep|sed|awk|tar|ssh|scp|apt(?:-get)?|docker|kubectl|xcodebuild|xcodegen|xcrun|swift|cargo|defaults|launchctl)(?:\s|$)"#
        let control = #"^(?:if\s+\[\[?\s|then$|else$|elif\s|fi$|for\s+\w+\s+in\s|while\s|do$|done$|case\s.+\sin$|esac$|function\s+\w+|\w+\s*\(\)\s*\{)"#
        let other = #"^(?:export\s+)?[A-Za-z_]\w*=\S|\$\{?\w+"#
        var strong = 0, shellish = 0, total = 0
        for line in lines.prefix(lineLimit) where !line.hasPrefix("#") {
            total += 1
            if line.range(of: command, options: .regularExpression) != nil || line.range(of: control, options: .regularExpression) != nil {
                strong += 1; shellish += 1
            } else if line.range(of: other, options: .regularExpression) != nil {
                shellish += 1
            }
        }
        return strong >= 2 && shellish * 10 >= total * 6
    }

    /// Two different Markdown signals, and not mostly lines that end like code.
    private static func markdown(_ s: Sample) -> EditorLanguage? {
        let signals = [#"(?m)^#{1,6}\s+\S"#, #"(?m)^\s*(?:[-*+]|\d+[.)])\s+\S"#,
                       #"(?<![\w\])])\[[^\]\n]+\]\([^\s)]+\)"#, #"(?<![\w*])\*\*[^*\s][^*\n]*\*\*(?![\w*])"#,
                       #"(?m)^>\s+\S"#, #"(?m)^\|.+\|\s*\n\|[\s:|-]+\|\s*$"#].filter(s.has).count
        guard signals >= 2 else { return nil }
        let codeLines = s.lines.filter { $0.hasSuffix(";") || $0.hasSuffix("{") || $0.hasSuffix("}") }.count
        return codeLines * 3 > s.lines.count ? nil : .markdown
    }

    // MARK: JSON

    private enum JSONState { case value, arrayStart, key, colon, next }

    /// A structural JSON check that also accepts JSONC (comments, trailing commas) and JSON Lines.
    /// When `isComplete` is false the text may stop anywhere, as long as everything before the cut is valid.
    static func isJSON(_ text: String, isComplete: Bool) -> Bool {
        let b = Array(text.utf8)
        var i = 0, stack: [UInt8] = [], state = JSONState.value, values = 0
        let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        let truncated = { !isComplete && values > 0 }
        while true {
            while i < b.count {   // whitespace and comments
                if b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1; continue }
                guard b[i] == slash, i + 1 < b.count, b[i + 1] == slash || b[i + 1] == star else { break }
                if b[i + 1] == slash {
                    while i < b.count, b[i] != 0x0A { i += 1 }
                } else {
                    i += 2
                    while i + 1 < b.count, !(b[i] == star && b[i + 1] == slash) { i += 1 }
                    if i + 1 >= b.count { return truncated() }
                    i += 2
                }
            }
            guard i < b.count else { return stack.isEmpty && state == .next ? true : truncated() }
            let c = b[i]
            if stack.isEmpty && state == .next {   // JSON Lines: another top-level container may follow
                guard c == UInt8(ascii: "{") || c == UInt8(ascii: "[") else { return false }
                state = .value
            }
            switch state {
            case .colon:
                guard c == UInt8(ascii: ":") else { return false }
                i += 1; state = .value
                continue
            case .next:
                if c == UInt8(ascii: ",") {
                    i += 1; state = stack.last == UInt8(ascii: "{") ? .key : .arrayStart
                    continue
                }
            case .key:
                if c == quote {
                    switch scanString(b, from: i) {
                    case .end(let end): i = end; state = .colon
                    case .truncated: return truncated()
                    case .invalid: return false
                    }
                    continue
                }
            case .value, .arrayStart:
                break
            }
            // A closer, or a value.
            if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                let opener = c == UInt8(ascii: "}") ? UInt8(ascii: "{") : UInt8(ascii: "[")
                let allowed = c == UInt8(ascii: "}") ? (state == .key || state == .next) : (state == .arrayStart || state == .next)
                guard allowed, stack.last == opener else { return false }
                stack.removeLast(); i += 1; state = .next; values += 1
                continue
            }
            guard state == .value || state == .arrayStart else { return false }
            switch c {
            case UInt8(ascii: "{"): stack.append(c); i += 1; state = .key; continue
            case UInt8(ascii: "["): stack.append(c); i += 1; state = .arrayStart; continue
            case quote:
                switch scanString(b, from: i) {
                case .end(let end): i = end
                case .truncated: return truncated()
                case .invalid: return false
                }
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                i += 1
                while i < b.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b[i]) || "+-.eE".utf8.contains(b[i]) { i += 1 }
            default:
                guard let word = ["true", "false", "null"].first(where: { $0.utf8.first == c }) else { return false }
                let w = Array(word.utf8), n = min(w.count, b.count - i)
                guard Array(b[i ..< i + n]) == Array(w[..<n]) else { return false }
                if n < w.count { return truncated() }
                i += n
            }
            values += 1; state = .next
        }
    }

    private enum StringScan { case end(Int), truncated, invalid }

    /// Scans a string literal starting at its opening quote. Raw line breaks are not allowed inside.
    private static func scanString(_ b: [UInt8], from start: Int) -> StringScan {
        var i = start + 1
        while i < b.count {
            switch b[i] {
            case UInt8(ascii: "\\"): i += 2
            case UInt8(ascii: "\""): return .end(i + 1)
            case 0x0A, 0x0D: return .invalid
            default: i += 1
            }
        }
        return .truncated
    }
}

private struct Sample {
    let text: String
    /// Every line, untrimmed.
    let rawLines: [Substring]
    /// Non-blank lines with surrounding whitespace removed.
    let lines: [String]

    init(_ text: String) {
        self.text = text
        rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    func count(_ pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
