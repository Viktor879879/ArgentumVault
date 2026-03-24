import Foundation
import Supabase
import Auth

enum AppAuthMethod: String, Sendable {
    case apple
    case email
}

struct AppAuthSession {
    let email: String
    let userID: String
    let authMethod: AppAuthMethod
}

enum AccountDeletionError: Error {
    case sessionRequired
    case requestFailed
}

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
    ) async throws -> AppAuthSession {
        switch mode {
        case .signIn:
            return try await signIn(email: email, password: password)
        case .signUp:
            return try await signUp(email: email, password: password, confirmPassword: confirmPassword)
        }
    }

    static func authenticateWithApple(idToken: String, rawNonce: String) async throws -> AppAuthSession {
        let normalizedToken = idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNonce = rawNonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty, !normalizedNonce.isEmpty else {
            throw EmailAuthError.storageFailure
        }

        let client = try configuredClient()
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: normalizedToken,
                nonce: normalizedNonce
            )
        )

        guard let authSession = makeSession(from: session.user, fallbackAuthMethod: .apple) else {
            throw EmailAuthError.storageFailure
        }
        return authSession
    }

    static func restoreSession() async -> AppAuthSession? {
        guard let client = try? configuredClient() else { return nil }

        if let currentUser = client.auth.currentUser,
           let currentSession = makeSession(from: currentUser) {
            return currentSession
        }

        guard let sessionUser = try? await client.auth.session.user else {
            return nil
        }
        return makeSession(from: sessionUser)
    }

    static func signOutCurrentSession() async {
        guard let client = try? configuredClient() else { return }
        try? await client.auth.signOut(scope: .local)
    }

    static func deleteCurrentAccount() async throws {
        let client = try configuredClient()

        do {
            _ = try await client.auth.session
        } catch {
            throw AccountDeletionError.sessionRequired
        }

        do {
            try await client.functions.invoke(
                "delete-account",
                options: .init(method: .post)
            )
            try? await client.auth.signOut(scope: .local)
        } catch {
            throw AccountDeletionError.requestFailed
        }
    }

    private static func signUp(email: String, password: String, confirmPassword: String) async throws -> AppAuthSession {
        let normalizedEmail = try normalizedRequired(email: email)
        try validate(password: password)
        guard password == confirmPassword else {
            throw EmailAuthError.passwordMismatch
        }

        let client = try configuredClient()

        do {
            let response = try await client.auth.signUp(email: normalizedEmail, password: password)

            if let signUpSession = makeSession(from: response.user) {
                return signUpSession
            }

            let session = try await client.auth.signIn(email: normalizedEmail, password: password)
            guard let signInSession = makeSession(from: session.user) else {
                throw EmailAuthError.storageFailure
            }
            return signInSession
        } catch {
            throw map(error)
        }
    }

    private static func signIn(email: String, password: String) async throws -> AppAuthSession {
        let normalizedEmail = try normalizedRequired(email: email)

        let client = try configuredClient()

        do {
            let session = try await client.auth.signIn(email: normalizedEmail, password: password)
            guard let authSession = makeSession(from: session.user) else {
                throw EmailAuthError.storageFailure
            }
            return authSession
        } catch {
            throw map(error)
        }
    }

    private static func configuredClient() throws -> SupabaseClient {
        try clientResult.get()
    }

    static func syncClient() throws -> SupabaseClient {
        try configuredClient()
    }

    static func currentSessionUserID() async throws -> String {
        let client = try configuredClient()

        if let currentUser = client.auth.currentUser,
           let normalizedUserID = normalized(userID: currentUser.id) {
            return normalizedUserID
        }

        let sessionUser = try await client.auth.session.user
        guard let normalizedUserID = normalized(userID: sessionUser.id) else {
            throw EmailAuthError.storageFailure
        }
        return normalizedUserID
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
        guard normalized.contains("@"),
              normalized.contains("."),
              !normalized.isEmpty,
              normalized.count <= 254
        else {
            return nil
        }
        return normalized
    }

    private static func normalized(userID: UUID?) -> String? {
        guard let userID else { return nil }
        return userID.uuidString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeSession(
        from user: User?,
        fallbackAuthMethod: AppAuthMethod? = nil
    ) -> AppAuthSession? {
        guard let user,
              let normalizedUserID = normalized(userID: user.id) else {
            return nil
        }

        let resolvedAuthMethod = resolvedAuthMethod(from: user) ?? fallbackAuthMethod
        guard let resolvedAuthMethod else {
            return nil
        }

        let normalizedEmail = normalized(email: user.email) ?? ""
        return AppAuthSession(
            email: normalizedEmail,
            userID: normalizedUserID,
            authMethod: resolvedAuthMethod
        )
    }

    private static func resolvedAuthMethod(from user: User) -> AppAuthMethod? {
        if let provider = user.appMetadata["provider"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch provider {
            case AppAuthMethod.apple.rawValue:
                return .apple
            case AppAuthMethod.email.rawValue:
                return .email
            default:
                break
            }
        }

        if let identities = user.identities {
            if identities.contains(where: { $0.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == AppAuthMethod.apple.rawValue }) {
                return .apple
            }
            if identities.contains(where: { $0.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == AppAuthMethod.email.rawValue }) {
                return .email
            }
        }

        if normalized(email: user.email) != nil {
            return .email
        }
        return nil
    }

    private static func validate(password: String) throws {
        guard password.count >= 6 else {
            throw EmailAuthError.passwordTooShort
        }
        guard password.count <= 128 else {
            throw EmailAuthError.storageFailure
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

        guard !trimmedURL.isEmpty,
              !trimmedKey.isEmpty,
              SecurityValidation.isAllowedSupabaseClientKey(trimmedKey),
              let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host?.isEmpty == false
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
