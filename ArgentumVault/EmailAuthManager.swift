import Foundation
import Supabase
import Auth
import OSLog

enum AppAuthMethod: String, Sendable {
    case apple
    case email
}

private enum DeleteAccountTokenSource: String {
    case authSession = "auth.session"
    case refreshedSession = "auth.refreshSession"
}

struct AppAuthSession {
    let email: String
    let userID: String
    let authMethod: AppAuthMethod
}

enum AccountDeletionError: Error {
    case sessionRequired(message: String?)
    case networkFailure
    case requestFailed(statusCode: Int?, message: String?)
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
        let configuration = try SupabaseConfiguration.resolved()
        let cachedSession = client.auth.currentSession
        let cachedToken = normalized(token: cachedSession?.accessToken)
        let cachedJWT = jwtDiagnosticsSummary(token: cachedToken, projectRef: configuration.projectRef)
        AppDiagnostics.accountDeletion.debug(
            """
            deleteCurrentAccount preflight hasCachedSession=\(cachedSession != nil, privacy: .public) \
            hasCachedToken=\(cachedToken != nil, privacy: .public) \
            cachedTokenLooksLikeJWT=\(looksLikeJWT(cachedToken), privacy: .public) \
            cachedTokenMatchesPublishableKey=\(matchesPublishableKey(cachedToken, publishableKey: configuration.clientKey), privacy: .public) \
            cachedIssuer=\(cachedJWT?.issuer ?? "none", privacy: .public) \
            cachedAudience=\(cachedJWT?.audience ?? "none", privacy: .public) \
            cachedExp=\(cachedJWT?.expirationDescription ?? "none", privacy: .public) \
            cachedSub=\(cachedJWT?.subject ?? "none", privacy: .public) \
            cachedProjectRefMatches=\(cachedJWT?.matchesProjectRef ?? false, privacy: .public) \
            tokenPrefix=\(tokenPrefix(cachedToken), privacy: .public)
            """
        )

        let activeSessionContext: DeleteAccountSessionContext
        do {
            activeSessionContext = try await ensureActiveSession(
                client: client,
                publishableKey: configuration.clientKey,
                projectRef: configuration.projectRef
            )
        } catch {
            AppDiagnostics.accountDeletion.error(
                "deleteCurrentAccount missing active session after refresh attempts error=\(String(describing: error), privacy: .public)"
            )
            throw AccountDeletionError.sessionRequired(message: nil)
        }

        let accessToken = activeSessionContext.accessToken
        let sessionUserID = normalized(userID: activeSessionContext.session.user.id) ?? "unknown"
        let functionURL = configuration.functionsURL.appendingPathComponent("delete-account")

        AppDiagnostics.accountDeletion.debug(
            """
            deleteCurrentAccount start userID=\(sessionUserID, privacy: .public) \
            tokenSource=\(activeSessionContext.source.rawValue, privacy: .public) \
            tokenLooksLikeJWT=\(looksLikeJWT(accessToken), privacy: .public) \
            tokenMatchesPublishableKey=\(matchesPublishableKey(accessToken, publishableKey: configuration.clientKey), privacy: .public) \
            tokenPrefix=\(tokenPrefix(accessToken), privacy: .public)
            """
        )

        do {
            var request = URLRequest(url: functionURL)
            request.httpMethod = "POST"
            request.httpBody = Data()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(configuration.clientKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            AppDiagnostics.accountDeletion.debug(
                """
                deleteCurrentAccount request prepared url=\(functionURL.absoluteString, privacy: .public) \
                hasAuthorizationHeader=true hasApiKeyHeader=true \
                authorizationTokenPrefix=\(tokenPrefix(accessToken), privacy: .public)
                """
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppDiagnostics.accountDeletion.error(
                    "deleteCurrentAccount invalid response type userID=\(sessionUserID, privacy: .public)"
                )
                throw AccountDeletionError.requestFailed(
                    statusCode: nil,
                    message: "Invalid response type."
                )
            }

            let bodySnippet = decodedFunctionBodySnippet(from: data)
            AppDiagnostics.accountDeletion.debug(
                """
                deleteCurrentAccount response userID=\(sessionUserID, privacy: .public) \
                statusCode=\(httpResponse.statusCode, privacy: .public) \
                body=\(bodySnippet ?? "none", privacy: .public)
                """
            )

            guard 200..<300 ~= httpResponse.statusCode else {
                let message = decodedFunctionErrorMessage(from: data) ?? bodySnippet
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw AccountDeletionError.sessionRequired(message: message)
                }
                throw AccountDeletionError.requestFailed(
                    statusCode: httpResponse.statusCode,
                    message: message
                )
            }

            AppDiagnostics.accountDeletion.debug(
                "deleteCurrentAccount edge function success userID=\(sessionUserID, privacy: .public)"
            )
        } catch is URLError {
            AppDiagnostics.accountDeletion.error(
                "deleteCurrentAccount network failure userID=\(sessionUserID, privacy: .public)"
            )
            throw AccountDeletionError.networkFailure
        } catch let error as AccountDeletionError {
            AppDiagnostics.accountDeletion.error(
                "deleteCurrentAccount request failure userID=\(sessionUserID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        } catch {
            AppDiagnostics.accountDeletion.error(
                "deleteCurrentAccount unexpected failure userID=\(sessionUserID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw AccountDeletionError.requestFailed(
                statusCode: nil,
                message: error.localizedDescription
            )
        }

        do {
            try await client.auth.signOut(scope: .local)
            AppDiagnostics.accountDeletion.debug(
                "deleteCurrentAccount local signOut success userID=\(sessionUserID, privacy: .public)"
            )
        } catch {
            AppDiagnostics.accountDeletion.error(
                "deleteCurrentAccount local signOut failure userID=\(sessionUserID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
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

        let sessionUser = try await client.auth.session.user
        if let normalizedUserID = normalized(userID: sessionUser.id) {
            return normalizedUserID
        }

        throw EmailAuthError.storageFailure
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

    private static func normalized(token: String?) -> String? {
        guard let token else { return nil }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func tokenPrefix(_ token: String?) -> String {
        guard let token = normalized(token: token) else {
            return "none"
        }
        return String(token.prefix(12))
    }

    private static func looksLikeJWT(_ token: String?) -> Bool {
        guard let token = normalized(token: token) else {
            return false
        }
        return token.split(separator: ".").count == 3
    }

    private static func matchesPublishableKey(_ token: String?, publishableKey: String) -> Bool {
        guard let token = normalized(token: token) else {
            return false
        }
        return token == publishableKey
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

    private static func decodedFunctionErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let payload = try? JSONDecoder().decode(EdgeFunctionErrorPayload.self, from: data) {
            let candidate = (payload.message ?? payload.error)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let candidate, !candidate.isEmpty {
                return candidate
            }
        }

        if let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }

        return nil
    }

    private static func decodedFunctionBodySnippet(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty
        else {
            return nil
        }

        let maxLength = 240
        guard body.count > maxLength else {
            return body
        }
        let index = body.index(body.startIndex, offsetBy: maxLength)
        return "\(body[..<index])..."
    }

    private static func ensureActiveSession(
        client: SupabaseClient,
        publishableKey: String,
        projectRef: String
    ) async throws -> DeleteAccountSessionContext {
        do {
            let session = try await client.auth.session
            if let context = try await validatedDeleteAccountSessionContext(
                client: client,
                session: session,
                source: .authSession,
                publishableKey: publishableKey,
                projectRef: projectRef
            ) {
                return context
            }
        } catch {
            AppDiagnostics.accountDeletion.error(
                "deleteCurrentAccount auth.session failed error=\(String(describing: error), privacy: .public)"
            )
        }

        let refreshedSession = try await client.auth.refreshSession()
        if let context = try await validatedDeleteAccountSessionContext(
            client: client,
            session: refreshedSession,
            source: .refreshedSession,
            publishableKey: publishableKey,
            projectRef: projectRef
        ) {
            return context
        }

        throw AccountDeletionError.sessionRequired(message: "Invalid access token.")
    }

    private static func validatedDeleteAccountSessionContext(
        client: SupabaseClient,
        session: Session,
        source: DeleteAccountTokenSource,
        publishableKey: String,
        projectRef: String
    ) async throws -> DeleteAccountSessionContext? {
        guard let accessToken = normalized(token: session.accessToken) else {
            AppDiagnostics.accountDeletion.error(
                "deleteCurrentAccount token missing source=\(source.rawValue, privacy: .public)"
            )
            return nil
        }

        let summary = jwtDiagnosticsSummary(token: accessToken, projectRef: projectRef)
        let looksLikeJWT = looksLikeJWT(accessToken)
        let matchesKey = matchesPublishableKey(accessToken, publishableKey: publishableKey)
        let issuer = summary?.issuer ?? "none"
        let audience = summary?.audience ?? "none"
        let expiration = summary?.expirationDescription ?? "none"
        let subject = summary?.subject ?? "none"
        let matchesProjectRef = summary?.matchesProjectRef ?? false
        let isExpired = summary?.isExpired ?? false

        guard looksLikeJWT else {
            AppDiagnostics.accountDeletion.error(
                """
                deleteCurrentAccount token is not JWT source=\(source.rawValue, privacy: .public) \
                tokenMatchesPublishableKey=\(matchesKey, privacy: .public) \
                issuer=\(issuer, privacy: .public) audience=\(audience, privacy: .public) \
                exp=\(expiration, privacy: .public) sub=\(subject, privacy: .public) \
                projectRefMatches=\(matchesProjectRef, privacy: .public) \
                tokenPrefix=\(tokenPrefix(accessToken), privacy: .public)
                """
            )
            return nil
        }

        guard !matchesKey else {
            AppDiagnostics.accountDeletion.error(
                """
                deleteCurrentAccount token matches publishable key source=\(source.rawValue, privacy: .public) \
                issuer=\(issuer, privacy: .public) audience=\(audience, privacy: .public) \
                exp=\(expiration, privacy: .public) sub=\(subject, privacy: .public) \
                projectRefMatches=\(matchesProjectRef, privacy: .public) \
                tokenPrefix=\(tokenPrefix(accessToken), privacy: .public)
                """
            )
            return nil
        }

        guard matchesProjectRef else {
            AppDiagnostics.accountDeletion.error(
                """
                deleteCurrentAccount token issuer mismatch source=\(source.rawValue, privacy: .public) \
                issuer=\(issuer, privacy: .public) audience=\(audience, privacy: .public) \
                exp=\(expiration, privacy: .public) sub=\(subject, privacy: .public) \
                expectedProjectRef=\(projectRef, privacy: .public) \
                tokenPrefix=\(tokenPrefix(accessToken), privacy: .public)
                """
            )
            return nil
        }

        if isExpired {
            AppDiagnostics.accountDeletion.error(
                """
                deleteCurrentAccount token expired source=\(source.rawValue, privacy: .public) \
                issuer=\(issuer, privacy: .public) audience=\(audience, privacy: .public) \
                exp=\(expiration, privacy: .public) sub=\(subject, privacy: .public) \
                tokenPrefix=\(tokenPrefix(accessToken), privacy: .public)
                """
            )
            return nil
        }

        do {
            _ = try await client.auth.user(jwt: accessToken)
            AppDiagnostics.accountDeletion.debug(
                """
                deleteCurrentAccount token verified source=\(source.rawValue, privacy: .public) \
                issuer=\(issuer, privacy: .public) audience=\(audience, privacy: .public) \
                exp=\(expiration, privacy: .public) sub=\(subject, privacy: .public) \
                projectRefMatches=\(matchesProjectRef, privacy: .public) \
                tokenPrefix=\(tokenPrefix(accessToken), privacy: .public)
                """
            )
        } catch {
            AppDiagnostics.accountDeletion.error(
                """
                deleteCurrentAccount token rejected by auth source=\(source.rawValue, privacy: .public) \
                issuer=\(issuer, privacy: .public) audience=\(audience, privacy: .public) \
                exp=\(expiration, privacy: .public) sub=\(subject, privacy: .public) \
                projectRefMatches=\(matchesProjectRef, privacy: .public) \
                tokenPrefix=\(tokenPrefix(accessToken), privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            return nil
        }

        return DeleteAccountSessionContext(
            session: session,
            accessToken: accessToken,
            source: source
        )
    }

    private static func jwtDiagnosticsSummary(
        token: String?,
        projectRef: String
    ) -> JWTDiagnosticsSummary? {
        guard let token = normalized(token: token) else {
            return nil
        }

        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payloadData = decodeBase64URL(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        let issuer = object["iss"] as? String
        let subject = object["sub"] as? String
        let audience: String? = {
            if let string = object["aud"] as? String {
                return string
            }
            if let array = object["aud"] as? [String] {
                return array.joined(separator: ",")
            }
            return nil
        }()

        let expirationEpoch: TimeInterval? = {
            if let number = object["exp"] as? NSNumber {
                return number.doubleValue
            }
            if let string = object["exp"] as? String, let value = TimeInterval(string) {
                return value
            }
            return nil
        }()

        let expirationDescription: String? = expirationEpoch.map { String(Int($0)) }
        let isExpired = expirationEpoch.map { $0 <= Date().timeIntervalSince1970 } ?? false
        let matchesProjectRef = issuer?.contains(projectRef) ?? false

        return JWTDiagnosticsSummary(
            issuer: issuer,
            audience: audience,
            expirationDescription: expirationDescription,
            subject: subject,
            matchesProjectRef: matchesProjectRef,
            isExpired: isExpired
        )
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

private struct DeleteAccountSessionContext {
    let session: Session
    let accessToken: String
    let source: DeleteAccountTokenSource
}

private struct JWTDiagnosticsSummary {
    let issuer: String?
    let audience: String?
    let expirationDescription: String?
    let subject: String?
    let matchesProjectRef: Bool
    let isExpired: Bool
}

private struct EdgeFunctionErrorPayload: Decodable {
    let error: String?
    let message: String?
}

private enum SupabaseConfiguration {
    private static let urlKey = "SUPABASE_URL"
    private static let anonKeyKey = "SUPABASE_ANON_KEY"

    struct ResolvedConfiguration {
        let supabaseURL: URL
        let clientKey: String
        let projectRef: String

        var functionsURL: URL {
            supabaseURL.appendingPathComponent("/functions/v1")
        }
    }

    static func resolved() throws -> ResolvedConfiguration {
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

        let projectRef = url.host?
            .split(separator: ".")
            .first
            .map(String.init) ?? ""

        guard !projectRef.isEmpty else {
            throw EmailAuthError.storageFailure
        }

        return ResolvedConfiguration(
            supabaseURL: url,
            clientKey: trimmedKey,
            projectRef: projectRef
        )
    }

    static func makeClient() throws -> SupabaseClient {
        let resolvedConfiguration = try resolved()

        let options = SupabaseClientOptions(
            auth: .init(emitLocalSessionAsInitialSession: true),
            global: .init(logger: nil)
        )

        return SupabaseClient(
            supabaseURL: resolvedConfiguration.supabaseURL,
            supabaseKey: resolvedConfiguration.clientKey,
            options: options
        )
    }
}
