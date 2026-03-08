import Foundation
import Supabase
import Auth

enum EmailAuthManager {
    private static let clientResult: Result<SupabaseClient, EmailAuthError> = {
        do {
            return .success(try SupabaseConfiguration.makeClient())
        } catch {
            return .failure(.storageFailure)
        }
    }()

    static func authenticate(
        mode: EmailAuthMode,
        email: String,
        password: String,
        confirmPassword: String
    ) async throws -> String {
        switch mode {
        case .signIn:
            return try await signIn(email: email, password: password)
        case .signUp:
            return try await signUp(email: email, password: password, confirmPassword: confirmPassword)
        }
    }

    static func restoreSessionEmail() async -> String? {
        guard let client = try? configuredClient() else { return nil }

        if let currentEmail = normalized(email: client.auth.currentUser?.email) {
            return currentEmail
        }

        guard let sessionEmail = try? await client.auth.session.user.email else {
            return nil
        }

        return normalized(email: sessionEmail)
    }

    static func signOutCurrentSession() async {
        guard let client = try? configuredClient() else { return }
        try? await client.auth.signOut(scope: .local)
    }

    private static func signUp(email: String, password: String, confirmPassword: String) async throws -> String {
        let normalizedEmail = try normalizedRequired(email: email)
        try validate(password: password)
        guard password == confirmPassword else {
            throw EmailAuthError.passwordMismatch
        }

        let client = try configuredClient()

        do {
            let response = try await client.auth.signUp(email: normalizedEmail, password: password)

            if let responseEmail = normalized(email: response.user.email) {
                return responseEmail
            }

            let session = try await client.auth.signIn(email: normalizedEmail, password: password)
            return normalized(email: session.user.email) ?? normalizedEmail
        } catch {
            throw map(error)
        }
    }

    private static func signIn(email: String, password: String) async throws -> String {
        let normalizedEmail = try normalizedRequired(email: email)

        let client = try configuredClient()

        do {
            let session = try await client.auth.signIn(email: normalizedEmail, password: password)
            return normalized(email: session.user.email) ?? normalizedEmail
        } catch {
            throw map(error)
        }
    }

    private static func configuredClient() throws -> SupabaseClient {
        try clientResult.get()
    }

    private static func normalizedRequired(email: String) throws -> String {
        guard let normalized = normalized(email: email) else {
            throw EmailAuthError.invalidEmail
        }
        return normalized
    }

    private static func normalized(email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), normalized.contains("."), !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func validate(password: String) throws {
        guard password.count >= 6 else {
            throw EmailAuthError.passwordTooShort
        }
    }

    private static func map(_ error: Error) -> EmailAuthError {
        if let authError = error as? AuthError {
            switch authError.errorCode {
            case .emailExists, .userAlreadyExists:
                return .accountAlreadyExists
            case .invalidCredentials:
                return .invalidCredentials
            case .userNotFound:
                return .accountNotFound
            case .emailNotConfirmed:
                return .emailNotConfirmed
            case .weakPassword:
                return .passwordTooShort
            default:
                break
            }

            let message = authError.message.lowercased()
            if message.contains("already") && message.contains("exist") {
                return .accountAlreadyExists
            }
            if message.contains("invalid") && message.contains("credential") {
                return .invalidCredentials
            }
            if message.contains("not confirmed") {
                return .emailNotConfirmed
            }
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("already") && message.contains("exist") {
            return .accountAlreadyExists
        }
        if message.contains("invalid") && message.contains("credential") {
            return .invalidCredentials
        }
        if message.contains("not confirmed") {
            return .emailNotConfirmed
        }

        return .storageFailure
    }
}

private enum SupabaseConfiguration {
    private static let urlKey = "SUPABASE_URL"
    private static let anonKeyKey = "SUPABASE_ANON_KEY"

    static func makeClient() throws -> SupabaseClient {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: urlKey) as? String else {
            throw EmailAuthError.storageFailure
        }
        guard let anonKey = Bundle.main.object(forInfoDictionaryKey: anonKeyKey) as? String else {
            throw EmailAuthError.storageFailure
        }

        let trimmedURL = urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "\\/", with: "/")
        let trimmedKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty, !trimmedKey.isEmpty,
              let url = URL(string: trimmedURL)
        else {
            throw EmailAuthError.storageFailure
        }

        let options = SupabaseClientOptions(
            auth: .init(emitLocalSessionAsInitialSession: true),
            global: .init(logger: nil)
        )

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: trimmedKey,
            options: options
        )
    }
}
