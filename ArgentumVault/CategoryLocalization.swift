import Foundation
import SwiftData
import NaturalLanguage
import Translation

enum CategoryLocalization {
    static let supportedLanguageCodes = ["en", "ru", "uk", "sv"]

    static func normalizedLanguageCode(_ languageCode: String) -> String {
        supportedLanguageCodes.contains(languageCode) ? languageCode : "en"
    }

    static func currentInterfaceLanguageCode() -> String {
        let storedCode = UserDefaults.standard.string(forKey: "appLanguageCode") ?? "system"
        if storedCode == "system" {
            let systemCode = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return normalizedLanguageCode(systemCode)
        }
        return normalizedLanguageCode(storedCode)
    }

    static func isBuiltInKey(_ syncID: String) -> Bool {
        defaultEnglishNamesByKey[syncID] != nil
    }

    static func defaultEnglishName(for syncID: String) -> String? {
        defaultEnglishNamesByKey[syncID]
    }

    static func localizedDefaultName(for syncID: String, languageCode: String) -> String? {
        let normalizedCode = normalizedLanguageCode(languageCode)
        return defaultLocalizedNamesByKey[syncID]?[normalizedCode]
            ?? defaultLocalizedNamesByKey[syncID]?["en"]
    }

    static func decodeLocalizedNames(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded.reduce(into: [:]) { partialResult, item in
            let key = normalizedLanguageCode(item.key)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                partialResult[key] = value
            }
        }
    }

    static func encodeLocalizedNames(_ names: [String: String]) -> String? {
        let sanitized = names.reduce(into: [String: String]()) { partialResult, item in
            let key = normalizedLanguageCode(item.key)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                partialResult[key] = value
            }
        }
        guard !sanitized.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(sanitized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func detectSourceLanguage(for text: String, fallbackLanguageCode: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return normalizedLanguageCode(fallbackLanguageCode) }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        if let dominantLanguage = recognizer.dominantLanguage?.rawValue {
            let normalized = normalizedLanguageCode(dominantLanguage)
            if supportedLanguageCodes.contains(normalized) {
                return normalized
            }
        }

        return normalizedLanguageCode(fallbackLanguageCode)
    }

    static func displayName(for category: Category, languageCode: String) -> String {
        let normalizedCode = normalizedLanguageCode(languageCode)
        let localizedNames = decodeLocalizedNames(category.localizedNamesJSON)
        if let translated = localizedNames[normalizedCode], !translated.isEmpty {
            return translated
        }

        if shouldUseBuiltInLocalizedName(for: category),
           let builtInName = localizedDefaultName(for: category.syncID, languageCode: normalizedCode) {
            return builtInName
        }

        if let sourceCode = normalizedSourceLanguage(for: category),
           sourceCode == normalizedCode {
            let trimmed = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return category.name
    }

    static func normalizedSourceLanguage(for category: Category) -> String? {
        guard let sourceLanguageCode = category.sourceLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceLanguageCode.isEmpty else {
            return nil
        }
        return normalizedLanguageCode(sourceLanguageCode)
    }

    static func shouldUseBuiltInLocalizedName(for category: Category) -> Bool {
        guard isBuiltInKey(category.syncID) else { return false }
        if normalizedSourceLanguage(for: category) != nil { return false }
        return decodeLocalizedNames(category.localizedNamesJSON).isEmpty
    }

    static func canonicalizeBuiltInCategoryIfNeeded(_ category: Category) -> Bool {
        guard shouldUseBuiltInLocalizedName(for: category),
              let englishName = defaultEnglishName(for: category.syncID) else {
            return false
        }

        var didChange = false
        if category.name != englishName {
            category.name = englishName
            didChange = true
        }
        if category.sourceLanguageCode != nil {
            category.sourceLanguageCode = nil
            didChange = true
        }
        if category.localizedNamesJSON != nil {
            category.localizedNamesJSON = nil
            didChange = true
        }
        return didChange
    }

    private static let defaultLocalizedNamesByKey: [String: [String: String]] = {
        var namesByKey: [String: [String: String]] = [:]
        for languageCode in supportedLanguageCodes {
            let localizedSeeds = Migration.localizedDefaultSeedNames(languageCode: languageCode)
            for seed in localizedSeeds.expenses + localizedSeeds.income {
                namesByKey[seed.key, default: [:]][languageCode] = seed.name
            }
        }
        return namesByKey
    }()

    private static let defaultEnglishNamesByKey: [String: String] = {
        defaultLocalizedNamesByKey.reduce(into: [:]) { partialResult, item in
            if let englishName = item.value["en"] {
                partialResult[item.key] = englishName
            }
        }
    }()
}

extension Category {
    var isBuiltInDefaultCategory: Bool {
        CategoryLocalization.isBuiltInKey(syncID)
    }

    func displayName(languageCode: String) -> String {
        CategoryLocalization.displayName(for: self, languageCode: languageCode)
    }
}

@MainActor
enum CategoryLocalizationService {
    private static var inFlightSyncIDs: Set<String> = []

    static func scheduleBackfillAll(modelContext: ModelContext, currentLanguageCode: String) {
        let descriptor = FetchDescriptor<Category>()
        guard let categories = try? modelContext.fetch(descriptor) else { return }
        for category in categories where category.deletedAt == nil {
            scheduleBackfill(for: category, modelContext: modelContext, currentLanguageCode: currentLanguageCode)
        }
    }

    static func scheduleBackfill(for category: Category, modelContext: ModelContext, currentLanguageCode: String) {
        let syncID = category.syncID
        guard !syncID.isEmpty, !inFlightSyncIDs.contains(syncID) else { return }
        inFlightSyncIDs.insert(syncID)

        Task { @MainActor in
            defer { inFlightSyncIDs.remove(syncID) }
            await backfillCategory(syncID: syncID, modelContext: modelContext, currentLanguageCode: currentLanguageCode)
        }
    }

    private static func backfillCategory(syncID: String, modelContext: ModelContext, currentLanguageCode: String) async {
        guard let category = fetchCategory(syncID: syncID, modelContext: modelContext) else { return }

        if CategoryLocalization.canonicalizeBuiltInCategoryIfNeeded(category) {
            category.updatedAt = Date()
            try? modelContext.save()
            return
        }

        let sourceText = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        let fallbackLanguageCode = CategoryLocalization.normalizedLanguageCode(currentLanguageCode)
        let sourceLanguageCode = CategoryLocalization.normalizedSourceLanguage(for: category)
            ?? CategoryLocalization.detectSourceLanguage(for: sourceText, fallbackLanguageCode: fallbackLanguageCode)

        var localizedNames = CategoryLocalization.decodeLocalizedNames(category.localizedNamesJSON)
        var didChange = false

        if localizedNames[sourceLanguageCode] != sourceText {
            localizedNames[sourceLanguageCode] = sourceText
            didChange = true
        }

        let targetLanguageCodes = CategoryLocalization.supportedLanguageCodes.filter {
            guard let existing = localizedNames[$0] else { return true }
            return existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if !targetLanguageCodes.isEmpty {
            let translatedNames = await translate(
                text: sourceText,
                from: sourceLanguageCode,
                to: targetLanguageCodes
            )
            for (languageCode, translatedText) in translatedNames {
                guard !translatedText.isEmpty else { continue }
                if localizedNames[languageCode] != translatedText {
                    localizedNames[languageCode] = translatedText
                    didChange = true
                }
            }
        }

        let encodedLocalizedNames = CategoryLocalization.encodeLocalizedNames(localizedNames)
        if category.sourceLanguageCode != sourceLanguageCode {
            category.sourceLanguageCode = sourceLanguageCode
            didChange = true
        }
        if category.localizedNamesJSON != encodedLocalizedNames {
            category.localizedNamesJSON = encodedLocalizedNames
            didChange = true
        }

        if didChange {
            category.updatedAt = Date()
            try? modelContext.save()
        }
    }

    private static func fetchCategory(syncID: String, modelContext: ModelContext) -> Category? {
        let descriptor = FetchDescriptor<Category>()
        return (try? modelContext.fetch(descriptor))?.first {
            $0.syncID == syncID && $0.deletedAt == nil
        }
    }

    private static func translate(text: String, from sourceLanguageCode: String, to targetLanguageCodes: [String]) async -> [String: String] {
        var results: [String: String] = [:]
        for targetLanguageCode in targetLanguageCodes {
            let normalizedTargetLanguageCode = CategoryLocalization.normalizedLanguageCode(targetLanguageCode)
            if normalizedTargetLanguageCode == sourceLanguageCode {
                results[normalizedTargetLanguageCode] = text
                continue
            }

            guard #available(iOS 26.0, macOS 26.0, *) else { continue }

            do {
                let session = TranslationSession(
                    installedSource: Locale.Language(identifier: sourceLanguageCode),
                    target: Locale.Language(identifier: normalizedTargetLanguageCode)
                )
                try await session.prepareTranslation()
                let response = try await session.translate(text)
                let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !translatedText.isEmpty {
                    results[normalizedTargetLanguageCode] = translatedText
                }
            } catch {
                continue
            }
        }
        return results
    }
}
