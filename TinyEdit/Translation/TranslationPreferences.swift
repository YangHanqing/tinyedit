import Foundation
import NaturalLanguage
import Translation

enum TranslationEngine: String, CaseIterable, Identifiable, Equatable {
    case apple, custom
    var id: String { rawValue }

    /// Apple Translation (the Translation framework) needs macOS 15; macOS 14 offers only the custom model.
    static var available: [Self] {
        if #available(macOS 15, *) { allCases } else { [.custom] }
    }

    var title: String {
        switch self {
        case .apple: String(localized: "Apple Translation")
        case .custom: String(localized: "Custom AI Model (OpenAI Compatible)")
        }
    }
}

enum TranslationThinking: String, CaseIterable, Identifiable {
    case serviceDefault, off, on
    var id: String { rawValue }
    var title: String {
        switch self {
        case .serviceDefault: String(localized: "Service Default")
        case .off: String(localized: "Off")
        case .on: String(localized: "On")
        }
    }
}

/// Extensions differ across otherwise Chat Completions-compatible services.
enum TranslationThinkingFormat: String, CaseIterable, Identifiable {
    case openAI, deepSeek, enableThinking, chatTemplate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI · reasoning_effort"
        case .deepSeek: "DeepSeek · thinking.type"
        case .enableThinking: "enable_thinking"
        case .chatTemplate: "vLLM · chat_template_kwargs"
        }
    }

    func parameters(for mode: TranslationThinking) -> [String: Any] {
        guard mode != .serviceDefault else { return [:] }
        let enabled = mode == .on
        switch self {
        case .openAI: return ["reasoning_effort": enabled ? "medium" : "none"]
        case .deepSeek: return ["thinking": ["type": enabled ? "enabled" : "disabled"]]
        case .enableThinking: return ["enable_thinking": enabled]
        case .chatTemplate: return ["chat_template_kwargs": ["enable_thinking": enabled]]
        }
    }
}

/// Separate from the app's interface language; secrets never enter UserDefaults.
struct TranslationPreferences: Equatable {
    var engine: TranslationEngine = .apple
    var primary = ""
    var secondary = ""
    /// Full Chat Completions URL, so compatible services can use their own path.
    var endpoint = ""
    var model = ""
    var extraInstructions = ""
    var thinking: TranslationThinking = .serviceDefault
    var thinkingFormat: TranslationThinkingFormat = .openAI

    static func load(from defaults: UserDefaults = .standard) -> Self {
        var p = Self()
        p.engine = TranslationEngine(rawValue: defaults.string(forKey: "translation.engine") ?? "") ?? .apple
        if !TranslationEngine.available.contains(p.engine) { p.engine = .custom }
        p.primary = defaults.string(forKey: "translation.primary") ?? ""
        p.secondary = defaults.string(forKey: "translation.secondary") ?? ""
        p.endpoint = defaults.string(forKey: "translation.endpoint") ?? ""
        p.model = defaults.string(forKey: "translation.model") ?? ""
        p.extraInstructions = defaults.string(forKey: "translation.extraInstructions") ?? ""
        p.thinking = TranslationThinking(rawValue: defaults.string(forKey: "translation.thinking") ?? "") ?? .serviceDefault
        p.thinkingFormat = TranslationThinkingFormat(rawValue: defaults.string(forKey: "translation.thinkingFormat") ?? "") ?? .openAI
        return p
    }

    /// Saved form: the URL and model without surrounding whitespace.
    var trimmed: Self {
        var p = self
        p.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        p.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return p
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(engine.rawValue, forKey: "translation.engine")
        defaults.set(primary, forKey: "translation.primary")
        defaults.set(secondary, forKey: "translation.secondary")
        defaults.set(endpoint, forKey: "translation.endpoint")
        defaults.set(model, forKey: "translation.model")
        defaults.set(extraInstructions, forKey: "translation.extraInstructions")
        defaults.set(thinking.rawValue, forKey: "translation.thinking")
        defaults.set(thinkingFormat.rawValue, forKey: "translation.thinkingFormat")
    }
}

enum TranslationLanguages {
    // Read global preferences, bypassing TinyEdit's AppleLanguages interface override.
    static var systemPreferences: [String] {
        (CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? Locale.preferredLanguages
    }

    static func canonical(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        let code = language.languageCode?.identifier ?? identifier
        if code == "zh" {
            let script = language.script?.identifier
            let region = language.region?.identifier
            return script == "Hant" || ["TW", "HK", "MO"].contains(region ?? "") ? "zh-Hant" : "zh-Hans"
        }
        return code
    }

    /// Regions do not matter, but Simplified and Traditional Chinese are different targets.
    static func same(_ a: String, _ b: String) -> Bool {
        canonical(a) == canonical(b)
    }

    /// No arbitrary fallback for an English-only user: an empty target asks them to choose.
    static func target(source: String?, preferences: TranslationPreferences, system: [String]) -> String {
        let primary = canonical(preferences.primary.isEmpty ? (system.first ?? "en") : preferences.primary)
        guard let source, same(source, primary) else { return primary }
        let secondary: String
        if !preferences.secondary.isEmpty {
            secondary = canonical(preferences.secondary)
        } else if !same(primary, "en") {
            secondary = "en"
        } else {
            secondary = system.map(canonical).first { !same($0, primary) } ?? ""
        }
        return secondary.isEmpty || same(secondary, source) ? "" : secondary
    }

    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4096)))
        guard let language = recognizer.dominantLanguage,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.6 else { return nil }
        return canonical(language.rawValue)
    }

    static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func choices(extra: [String] = []) async -> [String] {
        var apple: [String] = []
        if #available(macOS 15, *) {
            apple = await LanguageAvailability().supportedLanguages.map { canonical($0.minimalIdentifier) }
        }
        let common = ["en", "zh-Hans", "zh-Hant", "ko", "ja", "de", "fr", "es", "it", "pt", "ru", "ar", "hi", "th", "vi", "id", "nl", "pl", "tr", "uk"]
        return Set(apple + common + systemPreferences.map(canonical) + extra.filter { !$0.isEmpty })
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}
