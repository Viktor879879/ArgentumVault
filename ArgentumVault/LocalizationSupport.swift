import SwiftUI
import Foundation

enum L10n {
    static func text(_ key: String, lang: String) -> String {
        let code = ["en", "ru", "uk", "sv"].contains(lang) ? lang : "en"
        if let bundle = bundle(for: code) {
            let localized = NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: key, comment: "")
            if localized != key {
                return localized
            }
        }

        if code != "en", let enBundle = bundle(for: "en") {
            let fallback = NSLocalizedString(key, tableName: "Localizable", bundle: enBundle, value: key, comment: "")
            if fallback != key {
                return fallback
            }
        }

        return key
    }

    static func currencyDisplay(code: String, fallbackName: String, lang: String) -> String {
        let name = currencyName(code: code, lang: lang) ?? fallbackName
        return "\(code.uppercased()) — \(name)"
    }

    static func languageDisplay(code: String, lang: String) -> String {
        switch code {
        case "system":
            return text("settings.language.system", lang: lang)
        case "en":
            return text("settings.language.english", lang: lang)
        case "ru":
            return text("settings.language.russian", lang: lang)
        case "uk":
            return text("settings.language.ukrainian", lang: lang)
        case "sv":
            return text("settings.language.swedish", lang: lang)
        default:
            return code.uppercased()
        }
    }

    private static func currencyName(code: String, lang: String) -> String? {
        Locale(identifier: normalizedLanguageCode(lang))
            .localizedString(forCurrencyCode: code.uppercased())
    }

    private static func normalizedLanguageCode(_ lang: String) -> String {
        ["en", "ru", "uk", "sv"].contains(lang) ? lang : "en"
    }

    private static func bundle(for code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}

enum AppTheme {
    static func colorScheme(from value: String) -> ColorScheme? {
        switch value {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }
}
