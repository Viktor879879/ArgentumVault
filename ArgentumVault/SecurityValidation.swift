import Foundation

enum SecurityValidation {
    static let maxCategoryNameLength = 60
    static let maxWalletNameLength = 80
    static let maxFolderNameLength = 80
    static let maxRecurringTitleLength = 80
    static let maxNoteLength = 500
    static let maxAssetNameLength = 80
    static let maxAssetCodeLength = 16
    static let maxSnapshotLabelLength = 80
    static let maxLocalizedNamesJSONLength = 4_096
    nonisolated static let maxAmountInputLength = 40
    static let maxPhotoBytes = 5_000_000

    static let minimumSupportedDate = Date(timeIntervalSince1970: 0)
    static let maximumSupportedDate = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2100, month: 1, day: 1)
    ) ?? Date.distantFuture

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let maxAbsoluteAmount = Decimal(
        string: "999999999999.999999",
        locale: posixLocale
    ) ?? 999_999_999_999.999999
    nonisolated private static let amountCharacters = CharacterSet(charactersIn: "0123456789.,()+-*/ _'’\u{00A0}\u{202F}")
    private static let assetCodeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let lowercaseHexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    private static let uppercaseHexCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")

    static func sanitizeCategoryName(_ raw: String) -> String? {
        sanitizeRequiredSingleLine(raw, maxLength: maxCategoryNameLength)
    }

    static func sanitizeWalletName(_ raw: String) -> String? {
        sanitizeRequiredSingleLine(raw, maxLength: maxWalletNameLength)
    }

    static func sanitizeFolderName(_ raw: String) -> String? {
        sanitizeRequiredSingleLine(raw, maxLength: maxFolderNameLength)
    }

    static func sanitizeRecurringTitle(_ raw: String) -> String? {
        sanitizeRequiredSingleLine(raw, maxLength: maxRecurringTitleLength)
    }

    static func sanitizeAssetName(_ raw: String) -> String? {
        sanitizeRequiredSingleLine(raw, maxLength: maxAssetNameLength)
    }

    static func sanitizeNote(_ raw: String) -> String? {
        sanitizeOptionalMultiline(raw, maxLength: maxNoteLength)
    }

    static func sanitizeOptionalSnapshotLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return sanitizeRequiredSingleLine(raw, maxLength: maxSnapshotLabelLength)
    }

    static func sanitizeLocalizedNamesJSON(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return sanitizeOptionalMultiline(raw, maxLength: maxLocalizedNamesJSONLength)
    }

    static func sanitizeAssetCode(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !cleaned.isEmpty, cleaned.count <= maxAssetCodeLength else {
            return nil
        }
        guard cleaned.unicodeScalars.allSatisfy({ assetCodeCharacters.contains($0) }) else {
            return nil
        }
        return cleaned
    }

    static func sanitizeColorHex(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard cleaned.count == 6 || cleaned.count == 8 else {
            return fallback
        }
        guard cleaned.unicodeScalars.allSatisfy({ uppercaseHexCharacters.contains($0) }) else {
            return fallback
        }
        if cleaned.count == 6 {
            return "\(cleaned)FF"
        }
        return cleaned
    }

    static func boundedSingleLineInput(_ raw: String, maxLength: Int) -> String {
        let normalizedWhitespace = raw
            .unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                    return " "
                }
                return Character(scalar)
            }
        return String(normalizedWhitespace.prefix(maxLength))
    }

    static func boundedMultilineInput(_ raw: String, maxLength: Int) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let filteredScalars = normalized.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" {
                return true
            }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        return String(filtered.prefix(maxLength))
    }

    nonisolated static func boundedAmountInput(_ raw: String) -> String {
        let trimmedToLength = String(raw.prefix(maxAmountInputLength))
        let filteredScalars = trimmedToLength.unicodeScalars.filter { amountCharacters.contains($0) }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    nonisolated static func boundedAmountEditingInput(_ raw: String) -> String {
        // Pre-normalize the locale decimal separator to "." so it isn't
        // dropped by the character-set filter in boundedAmountInput.
        let localDecSep = Locale.autoupdatingCurrent.decimalSeparator ?? ""
        let preNormalized: String
        if !localDecSep.isEmpty && localDecSep != "." {
            preNormalized = raw.replacingOccurrences(of: localDecSep, with: ".")
        } else {
            preNormalized = raw
        }
        let bounded = boundedAmountInput(preNormalized)
        // Also normalize a lone ASCII comma to "." (decimal separator, not thousands grouping).
        let commas = bounded.filter { $0 == "," }.count
        guard commas == 1 else { return bounded }
        return bounded.replacingOccurrences(of: ",", with: ".")
    }

    nonisolated static func isAllowedAmountInput(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxAmountInputLength else {
            return false
        }
        return trimmed.unicodeScalars.allSatisfy { amountCharacters.contains($0) }
    }

    static func sanitizePositiveAmount(_ value: Decimal?) -> Decimal? {
        sanitizeAmount(value, allowZero: false)
    }

    static func sanitizeNonNegativeAmount(_ value: Decimal?) -> Decimal? {
        sanitizeAmount(value, allowZero: true)
    }

    static func sanitizeDate(_ value: Date) -> Date {
        min(max(value, minimumSupportedDate), maximumSupportedDate)
    }

    static func isDateInSupportedRange(_ value: Date) -> Bool {
        value >= minimumSupportedDate && value <= maximumSupportedDate
    }

    static func sanitizePhotoData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maxPhotoBytes else {
            return nil
        }
        return data
    }

    static func sanitizeSHA256Hex(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64 else { return nil }
        guard normalized.unicodeScalars.allSatisfy({ lowercaseHexCharacters.contains($0) }) else {
            return nil
        }
        return normalized
    }

    static func sanitizeAccountBucket(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 24 else { return nil }
        guard normalized.unicodeScalars.allSatisfy({ lowercaseHexCharacters.contains($0) }) else {
            return nil
        }
        return normalized
    }

    static func sanitizeUUIDString(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = UUID(uuidString: normalized) else { return nil }
        return parsed.uuidString.lowercased()
    }

    static func isAllowedSupabaseClientKey(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("service_role") || normalized.hasPrefix("sb_secret_") {
            return false
        }
        if normalized.hasPrefix("sb_publishable_") {
            return true
        }
        return normalized.split(separator: ".").count == 3
    }

    private static func sanitizeAmount(_ value: Decimal?, allowZero: Bool) -> Decimal? {
        guard let value else { return nil }
        if allowZero {
            guard value >= 0 else { return nil }
        } else {
            guard value > 0 else { return nil }
        }
        guard absDecimal(value) <= maxAbsoluteAmount else {
            return nil
        }
        return value
    }

    private static func sanitizeRequiredSingleLine(_ raw: String, maxLength: Int) -> String? {
        let trimmed = boundedSingleLineInput(raw, maxLength: maxLength)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizeOptionalMultiline(_ raw: String, maxLength: Int) -> String? {
        let normalized = boundedMultilineInput(raw, maxLength: maxLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func absDecimal(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
}
