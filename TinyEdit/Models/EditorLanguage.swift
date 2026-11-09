import Foundation

/// Raw values are persisted in session.json; never rename one.
enum EditorLanguage: String, Codable, CaseIterable, Sendable {
    case plain, json, markdown, python
    case javascript, typescript, java, kotlin, swift, go, rust, c, cpp, csharp, php, ruby, perl, lua
    case shell, powershell, sql, html, xml, css, scss, yaml, toml, ini
    case makefile, dockerfile, diff, r, dart, scala, groovy, haskell, latex

    var statusLabel: String {
        switch self {
        case .plain: String(localized: "Plain Text")
        case .json: "JSON"
        case .markdown: "Markdown"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .swift: "Swift"
        case .go: "Go"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .php: "PHP"
        case .ruby: "Ruby"
        case .perl: "Perl"
        case .lua: "Lua"
        case .shell: "Shell"
        case .powershell: "PowerShell"
        case .sql: "SQL"
        case .html: "HTML"
        case .xml: "XML"
        case .css: "CSS"
        case .scss: "SCSS / Less"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .ini: "INI / Config"
        case .makefile: "Makefile"
        case .dockerfile: "Dockerfile"
        case .diff: "Diff"
        case .r: "R"
        case .dart: "Dart"
        case .scala: "Scala"
        case .groovy: "Groovy"
        case .haskell: "Haskell"
        case .latex: "LaTeX"
        }
    }

    /// Plain Text first, then alphabetical: the order shown in menus.
    static let menuOrder: [EditorLanguage] =
        [.plain] + allCases.filter { $0 != .plain }.sorted { $0.statusLabel.localizedCaseInsensitiveCompare($1.statusLabel) == .orderedAscending }

    /// The extension a new file in this language is named with: its first listed one, else `txt`.
    var preferredExtension: String {
        Self.extensionTable.first { $0.0 == self }?.1.split(separator: " ").first.map(String.init) ?? "txt"
    }

    private static let extensionTable: [(EditorLanguage, String)] = [
        (.markdown, "md markdown mdown mkd"),
        (.json, "json jsonc json5 geojson webmanifest jsonl ndjson har ipynb xcstrings code-workspace"),
        (.python, "py pyw pyi"), (.javascript, "js mjs cjs jsx"), (.typescript, "ts tsx mts cts"),
        (.java, "java"), (.kotlin, "kt kts"), (.swift, "swift"), (.go, "go"), (.rust, "rs"),
        (.c, "c h"), (.cpp, "cpp cc cxx c++ hpp hh hxx h++ mm ino"), (.csharp, "cs csx"),
        (.php, "php phtml"), (.ruby, "rb rake gemspec ru"), (.perl, "pl pm t"), (.lua, "lua"),
        (.shell, "sh bash zsh ksh fish command"), (.powershell, "ps1 psm1 psd1"), (.sql, "sql"),
        (.html, "html htm xhtml vue svelte"),
        (.xml, "xml xsd xsl xslt plist svg xaml csproj storyboard xib entitlements xcscheme xcworkspacedata"),
        (.css, "css"), (.scss, "scss sass less"), (.yaml, "yaml yml"), (.toml, "toml"),
        (.ini, "ini cfg conf properties env editorconfig gitconfig"), (.makefile, "mk mak"),
        (.diff, "diff patch"), (.r, "r rmd"), (.dart, "dart"), (.scala, "scala sc"),
        (.groovy, "groovy gradle"), (.haskell, "hs lhs"), (.latex, "tex sty cls bib"),
    ]

    private static let byExtension: [String: EditorLanguage] = {
        var map: [String: EditorLanguage] = [:]
        for (lang, exts) in extensionTable { for e in exts.split(separator: " ") { map[String(e)] = lang } }
        return map
    }()

    /// Lower-cased names of files whose extension does not say what they hold: lock files, rc files, dotfiles.
    private static let byFilename: [String: EditorLanguage] = {
        let table: [(EditorLanguage, String)] = [
            (.makefile, "makefile gnumakefile"), (.dockerfile, "dockerfile containerfile"),
            (.ruby, "gemfile rakefile podfile vagrantfile brewfile fastfile appfile dangerfile guardfile capfile berksfile"),
            (.shell, ".bashrc .bash_profile .bash_login .bash_logout .bash_aliases .zshrc .zprofile .zshenv .zlogin .zlogout .profile .kshrc .envrc"),
            (.toml, "cargo.lock poetry.lock uv.lock pdm.lock gopkg.lock pipfile"),
            (.json, "composer.lock flake.lock deno.lock package.resolved .jshintrc .swcrc .watchmanconfig"),
            (.yaml, "podfile.lock pubspec.lock .clang-format .clang-tidy .yamllint"),
            (.ini, ".gitconfig .gitmodules .npmrc .pypirc .pylintrc .flake8 .coveragerc"),
            (.groovy, "jenkinsfile"), (.plain, "cmakelists.txt"),
        ]
        var map: [String: EditorLanguage] = [:]
        for (lang, names) in table { for name in names.split(separator: " ") { map[String(name)] = lang } }
        return map
    }()

    /// Written as either JSON or YAML: the first character decides.
    private static let jsonOrYAML: Set<String> = [".babelrc", ".eslintrc", ".prettierrc", ".stylelintrc", ".lintstagedrc"]

    static func from(fileExtension ext: String) -> EditorLanguage {
        byExtension[ext.lowercased()] ?? .plain
    }

    /// File name first (Makefile, Dockerfile), then the extension, then a `#!` line for extension-less scripts.
    static func detect(fileName: String, text: String) -> EditorLanguage {
        let lower = fileName.lowercased()
        if let l = byFilename[lower] { return l }
        if jsonOrYAML.contains(lower) {
            let first = text.first { !$0.isWhitespace }
            return first == nil || first == "{" || first == "[" ? .json : .yaml
        }
        if lower.hasPrefix("dockerfile.") { return .dockerfile }
        if lower == ".env" || lower.hasPrefix(".env.") { return .ini }    // .env.local, .env.production
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty { return from(fileExtension: ext) }
        // NSString gives a dotfile no extension: `.editorconfig` is named by what follows its dot.
        if lower.hasPrefix("."), case let l = from(fileExtension: String(lower.dropFirst())), l != .plain { return l }
        guard text.hasPrefix("#!") else { return .plain }
        let first = String(text.prefix(200).split(whereSeparator: \.isNewline).first ?? "")
        for (needle, lang) in [("python", EditorLanguage.python), ("node", .javascript), ("ruby", .ruby), ("perl", .perl),
                               ("php", .php), ("lua", .lua), ("pwsh", .powershell), ("bash", .shell), ("zsh", .shell),
                               ("/sh", .shell), ("env sh", .shell)] where first.contains(needle) {
            return lang
        }
        return .plain
    }
}
