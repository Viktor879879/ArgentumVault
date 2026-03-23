import Foundation

enum AccountIdentityPolicy {
    static let activeAccountIdentifierKey = "activeAccountIdentifier_v1"

    private static let appleUserIDKey = "appleUserID"
    private static let emailUserEmailKey = "emailUserEmail"
    private static let emailUserIDKey = "emailUserID"
    private static let authMethodKey = "authMethod"

    static func currentAccountIdentifier(defaults: UserDefaults = .standard) -> String? {
        persistedAccountIdentifier(defaults: defaults) ?? derivedAccountIdentifier(defaults: defaults)
    }

    static func currentCloudBackupAccountIdentifier(defaults: UserDefaults = .standard) -> String? {
        currentAccountIdentifier(defaults: defaults)
    }

    @discardableResult
    static func persistCurrentAccountIdentifier(
        authMethod: String,
        appleUserID: String,
        emailUserEmail: String,
        emailUserID: String,
        reason: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        let resolved = derivedAccountIdentifier(
            authMethod: authMethod,
            appleUserID: appleUserID,
            emailUserEmail: emailUserEmail,
            emailUserID: emailUserID
        )
        persistAccountIdentifier(resolved, reason: reason, defaults: defaults)
        return resolved
    }

    @discardableResult
    static func persistCurrentAccountIdentifierFromDefaults(
        reason: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        let resolved = derivedAccountIdentifier(defaults: defaults)
        persistAccountIdentifier(resolved, reason: reason, defaults: defaults)
        return resolved
    }

    static func clearPersistedAccountIdentifier(
        reason: String,
        defaults: UserDefaults = .standard
    ) {
        persistAccountIdentifier(nil, reason: reason, defaults: defaults)
    }

    static func derivedAccountIdentifier(
        authMethod: String,
        appleUserID: String,
        emailUserEmail: String,
        emailUserID: String
    ) -> String? {
        let normalizedAuthMethod = normalized(raw: authMethod)?.lowercased() ?? ""
        let normalizedAppleUserID = normalized(raw: appleUserID)
        let normalizedEmailUserID = normalized(raw: emailUserID)?.lowercased()
        let normalizedEmail = normalized(raw: emailUserEmail)?.lowercased()

        let appleIdentifier = normalizedAppleUserID.map { "apple:\($0)" }
        let emailIdentifier = normalizedEmailUserID.map { "email_uid:\($0)" }
            ?? normalizedEmail.map { "email:\($0)" }

        switch normalizedAuthMethod {
        case "apple":
            return appleIdentifier ?? emailIdentifier
        case "email":
            return emailIdentifier ?? appleIdentifier
        default:
            return appleIdentifier ?? emailIdentifier
        }
    }

    private static func derivedAccountIdentifier(defaults: UserDefaults) -> String? {
        derivedAccountIdentifier(
            authMethod: defaults.string(forKey: authMethodKey) ?? "",
            appleUserID: defaults.string(forKey: appleUserIDKey) ?? "",
            emailUserEmail: defaults.string(forKey: emailUserEmailKey) ?? "",
            emailUserID: defaults.string(forKey: emailUserIDKey) ?? ""
        )
    }

    private static func persistedAccountIdentifier(defaults: UserDefaults) -> String? {
        normalized(raw: defaults.string(forKey: activeAccountIdentifierKey))
    }

    private static func persistAccountIdentifier(
        _ identifier: String?,
        reason: String,
        defaults: UserDefaults
    ) {
        let normalizedIdentifier = normalized(raw: identifier)
        let previousIdentifier = persistedAccountIdentifier(defaults: defaults)
        guard previousIdentifier != normalizedIdentifier else { return }

        if let normalizedIdentifier {
            defaults.set(normalizedIdentifier, forKey: activeAccountIdentifierKey)
        } else {
            defaults.removeObject(forKey: activeAccountIdentifierKey)
        }

        AppFlowDiagnostics.launch(
            "Active account identifier changed reason=\(reason) previous=\(previousIdentifier ?? "nil") new=\(normalizedIdentifier ?? "nil")"
        )
    }

    private static func normalized(raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }
}
