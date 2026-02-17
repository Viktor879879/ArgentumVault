import Foundation

struct CountryOption {
    let code: String
    let name: String
}

enum CountryCatalog {
    static func options(lang: String) -> [CountryOption] {
        let locale = Locale(identifier: normalizedLanguageCode(lang))
        return allRegionCodes
            .compactMap { code -> CountryOption? in
                guard let name = locale.localizedString(forRegionCode: code) else { return nil }
                return CountryOption(code: code, name: name)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func defaultCountryCode() -> String {
        let regionCode: String?
        if #available(iOS 16.0, macOS 13.0, *) {
            regionCode = Locale.autoupdatingCurrent.region?.identifier.uppercased()
        } else {
            regionCode = Locale.autoupdatingCurrent.regionCode?.uppercased()
        }

        guard let code = regionCode, allRegionCodes.contains(code) else {
            return "US"
        }
        return code
    }

    private static var allRegionCodes: [String] {
        let excludedSpecialRegionCodes: Set<String> = [
            "AC", "CP", "CQ", "DG", "EA", "EU", "EZ", "FX", "IC", "QO", "SU", "TA", "UN"
        ]
        return NSLocale.isoCountryCodes.filter { !excludedSpecialRegionCodes.contains($0) }
    }

    private static func normalizedLanguageCode(_ lang: String) -> String {
        ["en", "ru", "uk", "sv"].contains(lang) ? lang : "en"
    }
}
