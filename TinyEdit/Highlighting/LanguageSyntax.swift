import Foundation

/// Data-driven description of a C-like / scripting language for `GenericHighlighter`.
struct LanguageSyntax: Sendable {
    struct StringRule: Sendable {
        var open: [UInt16]
        var close: [UInt16]
        var escapes = true
        var multiline = false
        /// Give up (not a string) when the close is not found within this many units: Rust lifetimes, Lisp quotes.
        var maxLength: Int?
        init(_ open: String, close: String? = nil, escapes: Bool = true, multiline: Bool = false, maxLength: Int? = nil) {
            self.open = Array(open.utf16); self.close = Array((close ?? open).utf16)
            self.escapes = escapes; self.multiline = multiline; self.maxLength = maxLength
        }
    }

    var lineComments: [[UInt16]] = []
    var blockComments: [([UInt16], [UInt16])] = []
    var strings: [StringRule] = []
    var keywords: Set<String> = []
    var constants: Set<String> = []        // true/false/null-like; matched like keywords
    var caseInsensitive = false
    var preprocessor = false               // `#include`-style lines
    var attributePrefix: UInt16?           // `@decorator`, `@media`
    var dollarVariables = false            // `$name` is a variable, never a keyword
    var hexColors = false                  // `#fff`
    var dashIdentifiers = false            // `font-size`
    var colonSpaceKeys = false             // CSS `prop: value`
    var keyValue = false                   // YAML/TOML/INI key at the start of a line
    var sectionHeaders = false             // `[section]`
    var valueBrackets = false              // TOML arrays span lines: a `[` line inside one is not a section
    var inlineTableKeys = false            // TOML `{ key = v, … }`
    var dateTimes = false                  // `1979-05-27T07:32:00Z`, `07:32:00`
    var hashNeedsBoundary = false          // `#` starts a comment only after whitespace (`$#`, `${#a}`)

    init() {}

    init(keywords: String, constants: String = "true false null nil", line: [String] = [], block: [(String, String)] = [],
         strings: [StringRule] = [StringRule("\""), StringRule("'")], configure: (inout LanguageSyntax) -> Void = { _ in }) {
        self.keywords = Set(keywords.split(separator: " ").map(String.init))
        self.constants = Set(constants.split(separator: " ").map(String.init))
        lineComments = line.map { Array($0.utf16) }
        blockComments = block.map { (Array($0.0.utf16), Array($0.1.utf16)) }
        self.strings = strings
        configure(&self)
    }

    private static let cBlock = [("/*", "*/")]
    private static let jsStrings = [StringRule("\""), StringRule("'"), StringRule("`", multiline: true)]
    private static let tripleSwift = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
    private static let hashBoundary: (inout LanguageSyntax) -> Void = { $0.hashNeedsBoundary = true }

    static let table: [EditorLanguage: LanguageSyntax] = [
        .javascript: LanguageSyntax(
            keywords: "async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield get set",
            constants: "true false null undefined NaN Infinity", line: ["//"], block: cBlock, strings: jsStrings),
        .typescript: LanguageSyntax(
            keywords: "abstract as async await break case catch class const continue declare default delete do else enum export extends finally for from function if implements import in instanceof interface is keyof let namespace new of private protected public readonly return static super switch this throw try type typeof var void while with yield",
            constants: "true false null undefined NaN Infinity", line: ["//"], block: cBlock, strings: jsStrings) { $0.attributePrefix = 0x40 },
        .java: LanguageSyntax(
            keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try var void volatile while record sealed permits yield",
            line: ["//"], block: cBlock, strings: tripleSwift + [StringRule("'")]) { $0.attributePrefix = 0x40 },
        .kotlin: LanguageSyntax(
            keywords: "abstract annotation as break by catch class companion const constructor continue crossinline data do else enum expect external final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias val var vararg when where while",
            line: ["//"], block: cBlock, strings: tripleSwift + [StringRule("'")]) { $0.attributePrefix = 0x40 },
        .swift: LanguageSyntax(
            keywords: "actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is lazy let mutating nonisolated nonmutating open operator optional override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet",
            constants: "true false nil", line: ["//"], block: cBlock, strings: tripleSwift) {
            $0.attributePrefix = 0x40; $0.preprocessor = true
        },
        .go: LanguageSyntax(
            keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
            constants: "true false nil iota", line: ["//"], block: cBlock,
            strings: [StringRule("\""), StringRule("`", escapes: false, multiline: true), StringRule("'")]),
        .rust: LanguageSyntax(
            keywords: "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while",
            constants: "true false", line: ["//"], block: cBlock,
            strings: [StringRule("\"", multiline: true), StringRule("'", maxLength: 6)]),
        .c: LanguageSyntax(
            keywords: "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool _Complex",
            constants: "true false NULL", line: ["//"], block: cBlock) { $0.preprocessor = true },
        .cpp: LanguageSyntax(
            keywords: "alignas alignof and auto bool break case catch char class concept const consteval constexpr const_cast continue co_await co_return co_yield decltype default delete do double dynamic_cast else enum explicit export extern float for friend goto if inline int long mutable namespace new noexcept not operator or override private protected public register reinterpret_cast requires return short signed sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typeid typename union unsigned using virtual void volatile while",
            constants: "true false nullptr NULL", line: ["//"], block: cBlock) { $0.preprocessor = true },
        .csharp: LanguageSyntax(
            keywords: "abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new object operator out override params partial private protected public readonly record ref return sbyte sealed short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using var virtual void volatile when where while yield",
            line: ["//"], block: cBlock, strings: tripleSwift + [StringRule("'")]) { $0.preprocessor = true },
        .php: LanguageSyntax(
            keywords: "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield",
            constants: "true false null TRUE FALSE NULL", line: ["//", "#"], block: cBlock) { $0.dollarVariables = true },
        .ruby: LanguageSyntax(
            keywords: "alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer puts",
            constants: "true false nil", line: ["#"], block: [("=begin", "=end")], configure: hashBoundary),
        .perl: LanguageSyntax(
            keywords: "and cmp continue do else elsif eq for foreach ge gt if last le local lt my ne next no not or our package print redo return sub unless until use while xor",
            constants: "", line: ["#"], configure: { $0.hashNeedsBoundary = true; $0.dollarVariables = true }),
        .lua: LanguageSyntax(
            keywords: "and break do else elseif end for function goto if in local not or repeat return then until while",
            constants: "true false nil", line: ["--"], block: [("--[[", "]]")],
            strings: [StringRule("[["  , close: "]]", escapes: false, multiline: true), StringRule("\""), StringRule("'")]),
        .shell: LanguageSyntax(
            keywords: "alias bg break case cd command continue declare do done echo elif else esac eval exec exit export fg fi for function getopts if in let local popd pushd read readonly return select set shift source test then trap type typeset ulimit umask unalias unset until wait while",
            constants: "true false", line: ["#"], strings: [StringRule("\""), StringRule("'", escapes: false)]) {
            $0.hashNeedsBoundary = true; $0.dollarVariables = true
        },
        .powershell: LanguageSyntax(
            keywords: "begin break catch class continue data do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow",
            constants: "true false null $true $false $null", line: ["#"], block: [("<#", "#>")]) {
            $0.hashNeedsBoundary = true; $0.dollarVariables = true; $0.caseInsensitive = true
        },
        .sql: LanguageSyntax(
            keywords: "add all alter and as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references replace right rollback select set table then top transaction truncate union unique update values view when where with",
            constants: "true false null", line: ["--"], block: cBlock) { $0.caseInsensitive = true },
        .css: LanguageSyntax(keywords: "", constants: "", block: cBlock) {
            $0.attributePrefix = 0x40; $0.hexColors = true; $0.dashIdentifiers = true; $0.colonSpaceKeys = true
        },
        .scss: LanguageSyntax(keywords: "", constants: "", line: ["//"], block: cBlock) {
            $0.attributePrefix = 0x40; $0.hexColors = true; $0.dashIdentifiers = true; $0.colonSpaceKeys = true
        },
        .yaml: LanguageSyntax(keywords: "", constants: "true false null yes no on off True False Null ~", line: ["#"]) {
            $0.keyValue = true; $0.hashNeedsBoundary = true; $0.dateTimes = true
        },
        .toml: LanguageSyntax(keywords: "", constants: "true false inf nan", line: ["#"],
                              strings: [StringRule("\"\"\"", multiline: true), StringRule("'''", escapes: false, multiline: true),
                                        StringRule("\""), StringRule("'", escapes: false)]) {
            $0.keyValue = true; $0.sectionHeaders = true; $0.valueBrackets = true; $0.inlineTableKeys = true; $0.dateTimes = true
        },
        .ini: LanguageSyntax(keywords: "", constants: "true false yes no on off", line: [";", "#"]) {
            $0.keyValue = true; $0.sectionHeaders = true; $0.hashNeedsBoundary = true
        },
        .makefile: LanguageSyntax(
            keywords: "ifeq ifneq ifdef ifndef else endif include define endef export override vpath .PHONY .DEFAULT",
            constants: "", line: ["#"], strings: [StringRule("\""), StringRule("'")]) {
            $0.keyValue = true; $0.dollarVariables = true
        },
        .dockerfile: LanguageSyntax(
            keywords: "FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS",
            constants: "", line: ["#"]) { $0.dollarVariables = true; $0.hashNeedsBoundary = true },
        .r: LanguageSyntax(
            keywords: "break else for function if in next repeat return while library require",
            constants: "TRUE FALSE NULL NA Inf NaN", line: ["#"]),
        .dart: LanguageSyntax(
            keywords: "abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for Function get hide if implements import in interface is late library mixin new on operator part required rethrow return set show static super switch sync this throw try typedef var void while with yield",
            line: ["//"], block: cBlock, strings: tripleSwift + [StringRule("'''", multiline: true), StringRule("'")]) { $0.attributePrefix = 0x40 },
        .scala: LanguageSyntax(
            keywords: "abstract case catch class def do else extends final finally for forSome given if implicit import lazy match new object override package private protected return sealed super this throw trait try type using val var while with yield enum export then",
            line: ["//"], block: cBlock, strings: tripleSwift + [StringRule("'")]) { $0.attributePrefix = 0x40 },
        .groovy: LanguageSyntax(
            keywords: "abstract as assert boolean break byte case catch char class const continue def default do double else enum extends final finally float for goto if implements import in instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this threadsafe throw throws transient try void volatile while",
            line: ["//"], block: cBlock, strings: [StringRule("'''", multiline: true), StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]) { $0.attributePrefix = 0x40 },
        .haskell: LanguageSyntax(
            keywords: "case class data default deriving do else forall foreign if import in infix infixl infixr instance let module newtype of then type where",
            constants: "True False Nothing", line: ["--"], block: [("{-", "-}")], strings: [StringRule("\"")]),
        .latex: LanguageSyntax(keywords: "", constants: "", line: ["%"], strings: []) { $0.attributePrefix = 0x5C },
    ]
}
