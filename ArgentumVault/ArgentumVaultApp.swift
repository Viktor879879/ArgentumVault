//
//  ArgentumVaultApp.swift
//  ArgentumVault
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import SwiftUI
import SwiftData
import CryptoKit
import OSLog

@main
struct ArgentumVaultApp: App {
    var body: some Scene {
        WindowGroup {
            AppBootstrapView()
        }
    }
}

enum AppDiagnostics {
    static let accountScope = Logger(subsystem: "com.argentumvault.app", category: "AccountScope")
    static let accountDeletion = Logger(subsystem: "com.argentumvault.app", category: "AccountDeletion")
    static let backup = Logger(subsystem: "com.argentumvault.app", category: "BackupRestore")
}

enum AccountBucketHasher {
    static func bucket(for accountIdentifier: String?) -> String {
        guard let accountIdentifier else { return "guest" }
        let normalized = accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "guest" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).lowercased()
    }
}

struct AccountScopeSnapshot {
    private static let appleUserIDKey = "appleUserID"
    private static let emailUserEmailKey = "emailUserEmail"
    private static let emailUserIDKey = "emailUserID"
    private static let authMethodKey = "authMethod"

    let appleUserID: String
    let emailUserEmail: String
    let emailUserID: String
    let authMethod: String

    init(
        appleUserID: String,
        emailUserEmail: String,
        emailUserID: String,
        authMethod: String
    ) {
        self.appleUserID = appleUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emailUserEmail = emailUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.emailUserID = emailUserID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.authMethod = authMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(defaults: UserDefaults = .standard) {
        self.init(
            appleUserID: defaults.string(forKey: Self.appleUserIDKey) ?? "",
            emailUserEmail: defaults.string(forKey: Self.emailUserEmailKey) ?? "",
            emailUserID: defaults.string(forKey: Self.emailUserIDKey) ?? "",
            authMethod: defaults.string(forKey: Self.authMethodKey) ?? ""
        )
    }

    var declaredAuthMethod: AppAuthMethod? {
        AppAuthMethod(rawValue: authMethod)
    }

    var inferredAuthMethod: AppAuthMethod? {
        if !appleUserID.isEmpty {
            return .apple
        }
        if !emailUserID.isEmpty || !emailUserEmail.isEmpty {
            return .email
        }
        return nil
    }

    var effectiveAuthMethod: AppAuthMethod? {
        declaredAuthMethod ?? inferredAuthMethod
    }

    var appleAccountIdentifier: String? {
        guard !appleUserID.isEmpty else { return nil }
        return "apple:\(appleUserID)"
    }

    var canonicalEmailAccountIdentifier: String? {
        guard !emailUserID.isEmpty else { return nil }
        return "email_uid:\(emailUserID)"
    }

    var legacyEmailAccountIdentifier: String? {
        guard !emailUserEmail.isEmpty else { return nil }
        return "email:\(emailUserEmail)"
    }

    var inferredAuthMethodRawValue: String? {
        effectiveAuthMethod?.rawValue
    }

    var hasAnyAuthSignals: Bool {
        !appleUserID.isEmpty || !emailUserEmail.isEmpty || !emailUserID.isEmpty || effectiveAuthMethod != nil
    }

    func resolvedScope(allowLegacyEmailStoreFallback: Bool) -> ResolvedAccountScope {
        let canonicalEmailAccountIdentifier = canonicalEmailAccountIdentifier
        let legacyEmailAccountIdentifier = legacyEmailAccountIdentifier
        let effectiveAuthMethod = effectiveAuthMethod

        let primaryStoreAccountIdentifier: String?
        let primaryCloudBackupAccountIdentifier: String?

        switch effectiveAuthMethod {
        case .apple:
            primaryStoreAccountIdentifier = appleAccountIdentifier ?? canonicalEmailAccountIdentifier
            primaryCloudBackupAccountIdentifier = appleAccountIdentifier ?? canonicalEmailAccountIdentifier
        case .email:
            primaryStoreAccountIdentifier = canonicalEmailAccountIdentifier
            primaryCloudBackupAccountIdentifier = canonicalEmailAccountIdentifier
        case nil:
            primaryStoreAccountIdentifier = appleAccountIdentifier ?? canonicalEmailAccountIdentifier
            primaryCloudBackupAccountIdentifier = appleAccountIdentifier ?? canonicalEmailAccountIdentifier
        }

        let storeAccountIdentifier: String?
        let usesLegacyEmailStoreFallback: Bool
        if let primaryStoreAccountIdentifier {
            storeAccountIdentifier = primaryStoreAccountIdentifier
            usesLegacyEmailStoreFallback = false
        } else if allowLegacyEmailStoreFallback, let legacyEmailAccountIdentifier {
            storeAccountIdentifier = legacyEmailAccountIdentifier
            usesLegacyEmailStoreFallback = true
        } else {
            storeAccountIdentifier = nil
            usesLegacyEmailStoreFallback = false
        }

        let needsBootstrapStabilization = hasAnyAuthSignals
            && storeAccountIdentifier == nil
            && legacyEmailAccountIdentifier != nil

        return ResolvedAccountScope(
            snapshot: self,
            storeAccountIdentifier: storeAccountIdentifier,
            cloudBackupAccountIdentifier: primaryCloudBackupAccountIdentifier,
            canonicalEmailAccountIdentifier: canonicalEmailAccountIdentifier,
            legacyEmailAccountIdentifier: legacyEmailAccountIdentifier,
            usesLegacyEmailStoreFallback: usesLegacyEmailStoreFallback,
            needsBootstrapStabilization: needsBootstrapStabilization
        )
    }
}

struct ResolvedAccountScope {
    let snapshot: AccountScopeSnapshot
    let storeAccountIdentifier: String?
    let cloudBackupAccountIdentifier: String?
    let canonicalEmailAccountIdentifier: String?
    let legacyEmailAccountIdentifier: String?
    let usesLegacyEmailStoreFallback: Bool
    let needsBootstrapStabilization: Bool

    var shouldRequestCloudBackup: Bool {
        cloudBackupAccountIdentifier != nil
    }

    var storeBucket: String {
        AccountBucketHasher.bucket(for: storeAccountIdentifier)
    }

    var cloudBackupBucket: String? {
        cloudBackupAccountIdentifier.map { AccountBucketHasher.bucket(for: $0) }
    }

    var debugSummary: String {
        [
            "authMethod=\(snapshot.effectiveAuthMethod?.rawValue ?? "none")",
            "appleUserID=\(snapshot.appleUserID)",
            "emailUserEmail=\(snapshot.emailUserEmail)",
            "emailUserID=\(snapshot.emailUserID)",
            "storeAccountIdentifier=\(storeAccountIdentifier ?? "nil")",
            "cloudBackupAccountIdentifier=\(cloudBackupAccountIdentifier ?? "nil")",
            "storeBucket=\(storeBucket)",
            "cloudBackupBucket=\(cloudBackupBucket ?? "nil")",
            "legacyEmailFallback=\(usesLegacyEmailStoreFallback)",
            "needsBootstrapStabilization=\(needsBootstrapStabilization)"
        ].joined(separator: " ")
    }
}

enum AccountSessionDefaults {
    private static let appleUserIDKey = "appleUserID"
    private static let appleUserEmailKey = "appleUserEmail"
    private static let appleUserNameKey = "appleUserName"
    private static let emailUserEmailKey = "emailUserEmail"
    private static let emailUserIDKey = "emailUserID"
    private static let authMethodKey = "authMethod"

    static func applyRestoredSession(_ session: AppAuthSession) {
        let defaults = UserDefaults.standard
        switch session.authMethod {
        case .apple:
            setEmailUserID(session.userID, in: defaults)
            setEmailUserEmail(session.email, in: defaults)
            defaults.set(AppAuthMethod.apple.rawValue, forKey: authMethodKey)
        case .email:
            clearStoredAppleIdentity(in: defaults)
            setEmailUserID(session.userID, in: defaults)
            setEmailUserEmail(session.email, in: defaults)
            defaults.set(AppAuthMethod.email.rawValue, forKey: authMethodKey)
        }
    }

    static func persistAppleSession(
        _ session: AppAuthSession,
        appleUserID: String,
        appleUserEmail: String,
        appleUserName: String,
        postChangeNotification: Bool
    ) {
        let defaults = UserDefaults.standard
        setAppleUserID(appleUserID, in: defaults)
        setAppleUserEmail(appleUserEmail, in: defaults)
        setAppleUserName(appleUserName, in: defaults)
        setEmailUserID(session.userID, in: defaults)
        setEmailUserEmail(session.email, in: defaults)
        defaults.set(AppAuthMethod.apple.rawValue, forKey: authMethodKey)
        if postChangeNotification {
            SessionEvents.postAccountSessionDidChange()
        }
    }

    static func persistEmailSession(_ session: AppAuthSession, postChangeNotification: Bool) {
        let defaults = UserDefaults.standard
        clearStoredAppleIdentity(in: defaults)
        setEmailUserID(session.userID, in: defaults)
        setEmailUserEmail(session.email, in: defaults)
        defaults.set(AppAuthMethod.email.rawValue, forKey: authMethodKey)
        if postChangeNotification {
            SessionEvents.postAccountSessionDidChange()
        }
    }

    static func clearSession(postChangeNotification: Bool) {
        let defaults = UserDefaults.standard
        clearStoredAppleIdentity(in: defaults)
        defaults.removeObject(forKey: emailUserEmailKey)
        defaults.removeObject(forKey: emailUserIDKey)
        defaults.removeObject(forKey: authMethodKey)
        if postChangeNotification {
            SessionEvents.postAccountSessionDidChange()
        }
    }

    private static func clearStoredAppleIdentity(in defaults: UserDefaults) {
        defaults.removeObject(forKey: appleUserIDKey)
        defaults.removeObject(forKey: appleUserEmailKey)
        defaults.removeObject(forKey: appleUserNameKey)
    }

    private static func setAppleUserID(_ value: String, in defaults: UserDefaults) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            defaults.removeObject(forKey: appleUserIDKey)
        } else {
            defaults.set(normalized, forKey: appleUserIDKey)
        }
    }

    private static func setAppleUserEmail(_ value: String, in defaults: UserDefaults) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            defaults.removeObject(forKey: appleUserEmailKey)
        } else {
            defaults.set(normalized, forKey: appleUserEmailKey)
        }
    }

    private static func setAppleUserName(_ value: String, in defaults: UserDefaults) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            defaults.removeObject(forKey: appleUserNameKey)
        } else {
            defaults.set(normalized, forKey: appleUserNameKey)
        }
    }

    private static func setEmailUserEmail(_ value: String, in defaults: UserDefaults) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            defaults.removeObject(forKey: emailUserEmailKey)
        } else {
            defaults.set(normalized, forKey: emailUserEmailKey)
        }
    }

    private static func setEmailUserID(_ value: String, in defaults: UserDefaults) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            defaults.removeObject(forKey: emailUserIDKey)
        } else {
            defaults.set(normalized, forKey: emailUserIDKey)
        }
    }
}

private struct AppBootstrapView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appleUserID") private var bootstrapAppleUserID = ""
    @AppStorage("emailUserEmail") private var bootstrapEmailUserEmail = ""
    @AppStorage("emailUserID") private var bootstrapEmailUserID = ""
    @AppStorage("authMethod") private var bootstrapAuthMethod = ""
    @StateObject private var quickExpenseRouter = QuickExpenseRouter()
    @State private var modelContainer: ModelContainer?
    @State private var isCloudStoreEnabled = false
    @State private var isAuthBootstrapComplete = false
    @State private var hasResolvedAccountScope = false
    @State private var isReconfiguringContainer = false
    @State private var isSwitchingContainer = false
    @State private var cloudRetryTask: Task<Void, Never>?
    @State private var periodicBackupTask: Task<Void, Never>?
    @State private var saveTriggeredBackupTask: Task<Void, Never>?
    @State private var startupBackupTask: Task<Void, Never>?
    @State private var hasPendingReconfigureRequest = false
    @State private var pendingReconfigureNeedsEntitlementRefresh = false
    @State private var containerEpoch = 0
    @State private var lastKnownAccountIdentifier: String?
    @State private var activeStoreAccountIdentifier: String?

    var body: some View {
        Group {
            if isAuthBootstrapComplete, hasResolvedAccountScope, !isSwitchingContainer, let modelContainer {
                ContentView()
                    .id(containerEpoch)
                    .modelContainer(modelContainer)
            } else {
                LoadingBootstrapView()
            }
        }
        .onOpenURL { url in
            quickExpenseRouter.handle(url: url)
        }
        .task {
            await bootstrapIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ModelContext.didSave),
            perform: handleModelContextSaveNotification
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .accountSessionDidChange),
            perform: handleAccountSessionChangeNotification
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .modelStoreRestoreWillBegin),
            perform: handleModelStoreRestoreWillBeginNotification
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .modelStoreDidRestore),
            perform: handleModelStoreRestoreDidFinishNotification
        )
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .environmentObject(quickExpenseRouter)
    }

    @MainActor
    private func bootstrapIfNeeded() async {
        guard modelContainer == nil else { return }
        isSwitchingContainer = true
        hasResolvedAccountScope = false

        let initialScope = currentResolvedAccountScope(allowLegacyEmailStoreFallback: false)
        AppDiagnostics.accountScope.debug("bootstrap begin \(initialScope.debugSummary, privacy: .public)")

        if initialScope.needsBootstrapStabilization {
            AppDiagnostics.accountScope.debug("bootstrap restoreSession start \(initialScope.debugSummary, privacy: .public)")
            if let restoredSession = await EmailAuthManager.restoreSession() {
                AccountSessionDefaults.applyRestoredSession(restoredSession)
                AppDiagnostics.accountScope.debug(
                    "bootstrap restoreSession resolved method=\(restoredSession.authMethod.rawValue, privacy: .public) email=\(restoredSession.email, privacy: .public) userID=\(restoredSession.userID, privacy: .public)"
                )
            } else {
                AppDiagnostics.accountScope.debug("bootstrap restoreSession returned nil")
            }
        } else if bootstrapAuthMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let inferredAuthMethod = currentResolvedAccountScope(
                    allowLegacyEmailStoreFallback: false
                  ).snapshot.inferredAuthMethodRawValue {
            bootstrapAuthMethod = inferredAuthMethod
        }

        isAuthBootstrapComplete = true
        let stabilizedScope = currentResolvedAccountScope(allowLegacyEmailStoreFallback: true)
        AppDiagnostics.accountScope.debug("bootstrap stabilized \(stabilizedScope.debugSummary, privacy: .public)")

        await switchContainerIfNeeded(
            refreshEntitlements: true,
            reason: "bootstrap_complete"
        )
        guard modelContainer == nil else { return }

        // Emergency fallback: never leave bootstrap screen hanging.
        let accountIdentifier = stabilizedScope.storeAccountIdentifier
        let fallbackSelection = AppModelContainerFactory.makeContainerSelection(
            shouldUseCloudKit: false,
            accountIdentifier: accountIdentifier
        )
        modelContainer = fallbackSelection.container
        isCloudStoreEnabled = false
        hasResolvedAccountScope = true
        activeStoreAccountIdentifier = accountIdentifier
        isSwitchingContainer = false
        AppStorageDiagnostics.persist(
            requestedCloud: stabilizedScope.shouldRequestCloudBackup,
            selection: fallbackSelection
        )
        configureICloudBackupPipeline(
            requestedCloud: false,
            usesCloudKit: false,
            container: fallbackSelection.container,
            accountIdentifier: nil
        )
        AppDiagnostics.accountScope.debug(
            "bootstrap emergency fallback store=\(fallbackSelection.storeName, privacy: .public) bucket=\(fallbackSelection.accountBucket, privacy: .public)"
        )
    }

    private func scheduleContainerSwitch(refreshEntitlements: Bool, reason: String) {
        guard isAuthBootstrapComplete else {
            AppDiagnostics.accountScope.debug("scheduleContainerSwitch ignored reason=\(reason, privacy: .public) bootstrap incomplete")
            return
        }
        let scope = currentResolvedAccountScope(allowLegacyEmailStoreFallback: true)
        guard !scope.needsBootstrapStabilization else {
            AppDiagnostics.accountScope.debug(
                "scheduleContainerSwitch deferred reason=\(reason, privacy: .public) \(scope.debugSummary, privacy: .public)"
            )
            return
        }
        AppDiagnostics.accountScope.debug(
            "scheduleContainerSwitch reason=\(reason, privacy: .public) refreshEntitlements=\(refreshEntitlements) \(scope.debugSummary, privacy: .public)"
        )
        Task { @MainActor in
            await switchContainerIfNeeded(
                refreshEntitlements: refreshEntitlements,
                reason: reason
            )
        }
    }

    private func handleModelContextSaveNotification(_ notification: Notification) {
        Task { @MainActor in
            handleModelContextDidSave(notification)
        }
    }

    private func handleAccountSessionChangeNotification(_: Notification) {
        scheduleContainerSwitch(refreshEntitlements: false, reason: "account_session_changed")
    }

    private func handleModelStoreRestoreWillBeginNotification(_: Notification) {
        handleModelStoreRestoreWillBegin()
    }

    private func handleModelStoreRestoreDidFinishNotification(_ notification: Notification) {
        handleModelStoreDidRestore(notification)
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        Task { @MainActor in
            if newPhase == .active {
                await switchContainerIfNeeded(
                    refreshEntitlements: true,
                    reason: "scene_active"
                )
            } else if newPhase == .inactive || newPhase == .background {
                performImmediateBackupIfPossible(force: true)
            }
        }
    }

    @MainActor
    private func switchContainerIfNeeded(
        refreshEntitlements: Bool,
        forceRebuild: Bool = false,
        reason: String
    ) async {
        guard !isReconfiguringContainer else {
            hasPendingReconfigureRequest = true
            pendingReconfigureNeedsEntitlementRefresh = pendingReconfigureNeedsEntitlementRefresh || refreshEntitlements
            AppDiagnostics.accountScope.debug(
                "switchContainerIfNeeded queued reason=\(reason, privacy: .public) refreshEntitlements=\(refreshEntitlements) forceRebuild=\(forceRebuild)"
            )
            return
        }
        isReconfiguringContainer = true
        defer {
            // Defensive reset to avoid getting stuck on bootstrap loading screen.
            isSwitchingContainer = false
            isReconfiguringContainer = false
            if hasPendingReconfigureRequest {
                let needsRefresh = pendingReconfigureNeedsEntitlementRefresh
                hasPendingReconfigureRequest = false
                pendingReconfigureNeedsEntitlementRefresh = false
                Task { @MainActor in
                    await switchContainerIfNeeded(
                        refreshEntitlements: needsRefresh,
                        reason: "pending_reconfigure"
                    )
                }
            }
        }

        if refreshEntitlements {
            // Do not block app bootstrap on StoreKit entitlement refresh.
            Task.detached(priority: .utility) {
                _ = await SubscriptionManager.resolveProAccessForLaunch()
            }
        }
        // Main SwiftData store is local and account-scoped.
        // Remote sync/backup is handled separately (Supabase for email accounts).
        let resolvedShouldUseCloudKit = false
        let resolvedScope = currentResolvedAccountScope(
            allowLegacyEmailStoreFallback: isAuthBootstrapComplete
        )
        guard !resolvedScope.needsBootstrapStabilization else {
            AppDiagnostics.accountScope.debug(
                "switchContainerIfNeeded aborted reason=\(reason, privacy: .public) unresolved scope \(resolvedScope.debugSummary, privacy: .public)"
            )
            return
        }
        let resolvedShouldEnableCloudBackup = resolvedScope.shouldRequestCloudBackup
        let resolvedAccountIdentifier = resolvedScope.storeAccountIdentifier
        let resolvedCloudBackupAccountIdentifier = resolvedScope.cloudBackupAccountIdentifier
        AppDiagnostics.accountScope.debug(
            "switchContainerIfNeeded begin reason=\(reason, privacy: .public) refreshEntitlements=\(refreshEntitlements) forceRebuild=\(forceRebuild) \(resolvedScope.debugSummary, privacy: .public)"
        )

        if !forceRebuild,
           let existingContainer = modelContainer,
           resolvedShouldUseCloudKit == isCloudStoreEnabled,
           resolvedAccountIdentifier == activeStoreAccountIdentifier {
            configureICloudBackupPipeline(
                requestedCloud: resolvedShouldEnableCloudBackup,
                usesCloudKit: isCloudStoreEnabled,
                container: existingContainer,
                accountIdentifier: resolvedCloudBackupAccountIdentifier
            )
            hasResolvedAccountScope = true
            return
        }

        let previousContainer = modelContainer
        let previousUsesCloudStore = isCloudStoreEnabled
        let previousContainerIdentifier = previousContainer.map(ObjectIdentifier.init)

        let selection = AppModelContainerFactory.makeContainerSelection(
            shouldUseCloudKit: false,
            accountIdentifier: resolvedAccountIdentifier
        )
        let didMigrateLegacyEmailStore = migrateLegacyEmailScopedLocalStoreIfNeeded(
            into: selection.container,
            resolvedScope: resolvedScope
        )

        if !forceRebuild,
           let previousContainer,
           selection.usesCloudKit == previousUsesCloudStore,
           resolvedAccountIdentifier == activeStoreAccountIdentifier {
            // Avoid container churn while CloudKit remains unavailable (or unchanged).
            // Recreating identical mode containers can invalidate live model objects and crash SwiftData views.
            AppStorageDiagnostics.persist(requestedCloud: resolvedShouldEnableCloudBackup, selection: selection)
            scheduleCloudRetryIfNeeded(requestedCloud: resolvedShouldEnableCloudBackup, selection: selection)
            configureICloudBackupPipeline(
                requestedCloud: resolvedShouldEnableCloudBackup,
                usesCloudKit: previousUsesCloudStore,
                container: previousContainer,
                accountIdentifier: resolvedCloudBackupAccountIdentifier
            )
            hasResolvedAccountScope = true
            return
        }

        let shouldSwitchStoreType = (previousContainer != nil && forceRebuild)
            || previousContainer != nil
            && (
                selection.usesCloudKit != previousUsesCloudStore
                || resolvedAccountIdentifier != activeStoreAccountIdentifier
            )

        let shouldGateInitialPresentation = previousContainer == nil
            && resolvedShouldEnableCloudBackup
            && resolvedCloudBackupAccountIdentifier != nil
            && !ICloudBackupManager.hasCoreFinancialData(in: ModelContext(selection.container))

        AppDiagnostics.accountScope.debug(
            "container selection reason=\(reason, privacy: .public) storeName=\(selection.storeName, privacy: .public) bucket=\(selection.accountBucket, privacy: .public) requestedCloud=\(resolvedShouldEnableCloudBackup) didMigrateLegacyEmailStore=\(didMigrateLegacyEmailStore) gateInitialPresentation=\(shouldGateInitialPresentation)"
        )

        if shouldSwitchStoreType {
            periodicBackupTask?.cancel()
            periodicBackupTask = nil
            saveTriggeredBackupTask?.cancel()
            saveTriggeredBackupTask = nil
            startupBackupTask?.cancel()
            startupBackupTask = nil
            performImmediateBackupIfPossible(
                container: previousContainer,
                accountIdentifier: lastKnownAccountIdentifier,
                force: true
            )
            // Phase 1: remove data-driven view tree while the old container is still valid.
            isSwitchingContainer = true
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            // Phase 2: drop the old container, then bind the new one.
            modelContainer = nil
            await Task.yield()
        }

        if shouldGateInitialPresentation {
            isSwitchingContainer = true
        }

        modelContainer = selection.container
        isCloudStoreEnabled = selection.usesCloudKit
        activeStoreAccountIdentifier = resolvedAccountIdentifier
        AppStorageDiagnostics.persist(requestedCloud: resolvedShouldEnableCloudBackup, selection: selection)
        scheduleCloudRetryIfNeeded(requestedCloud: resolvedShouldEnableCloudBackup, selection: selection)

        if previousContainerIdentifier != ObjectIdentifier(selection.container) {
            containerEpoch += 1
        }

        if shouldGateInitialPresentation, let resolvedAccountIdentifier {
            await performInitialBootstrapRestoreIfNeeded(
                container: selection.container,
                accountIdentifier: resolvedAccountIdentifier
            )
        }

        configureICloudBackupPipeline(
            requestedCloud: resolvedShouldEnableCloudBackup,
            usesCloudKit: selection.usesCloudKit,
            container: selection.container,
            accountIdentifier: resolvedCloudBackupAccountIdentifier
        )
        hasResolvedAccountScope = true
    }

    @MainActor
    private func scheduleCloudRetryIfNeeded(requestedCloud: Bool, selection: AppModelContainerSelection) {
        _ = requestedCloud
        _ = selection
        cloudRetryTask?.cancel()
        cloudRetryTask = nil
    }

    @MainActor
    private func configureICloudBackupPipeline(
        requestedCloud: Bool,
        usesCloudKit: Bool,
        container: ModelContainer,
        accountIdentifier: String?
    ) {
        startupBackupTask?.cancel()
        startupBackupTask = nil
        periodicBackupTask?.cancel()
        periodicBackupTask = nil

        guard requestedCloud, let accountIdentifier else {
            lastKnownAccountIdentifier = nil
            AppDiagnostics.accountScope.debug("configureICloudBackupPipeline disabled requestedCloud=\(requestedCloud)")
            return
        }
        lastKnownAccountIdentifier = accountIdentifier
        AppDiagnostics.accountScope.debug(
            "configureICloudBackupPipeline accountIdentifier=\(accountIdentifier, privacy: .public) bucket=\(AccountBucketHasher.bucket(for: accountIdentifier), privacy: .public) usesCloudKit=\(usesCloudKit)"
        )

        startupBackupTask = Task { @MainActor [container] in
            let startupDelay: UInt64 = usesCloudKit ? 10_000_000_000 : 350_000_000
            try? await Task.sleep(nanoseconds: startupDelay)
            guard !Task.isCancelled else { return }
            guard isBackupPipelineContextCurrent(container: container, accountIdentifier: accountIdentifier) else {
                return
            }

            if ICloudBackupManager.hasPendingLocalChanges(accountIdentifier: accountIdentifier) {
                let backupContext = ModelContext(container)
                ICloudBackupManager.backupIfNeeded(
                    modelContext: backupContext,
                    accountIdentifier: accountIdentifier,
                    force: false
                )
                return
            }

            let restoreContext = ModelContext(container)
            let didRestore = (try? await ICloudBackupManager.restoreIfNeeded(
                modelContext: restoreContext,
                accountIdentifier: accountIdentifier
            )) ?? false

            guard !Task.isCancelled else { return }
            guard isBackupPipelineContextCurrent(container: container, accountIdentifier: accountIdentifier) else {
                return
            }
            if didRestore {
                await switchContainerIfNeeded(
                    refreshEntitlements: false,
                    forceRebuild: true,
                    reason: "startup_restore_rebuild"
                )
                return
            }

            let backupContext = ModelContext(container)
            if ICloudBackupManager.shouldForceBackupAfterRestoreAttempt(
                modelContext: backupContext,
                didRestore: didRestore
            ) {
                ICloudBackupManager.backupIfNeeded(
                    modelContext: backupContext,
                    accountIdentifier: accountIdentifier,
                    force: didRestore
                )
            }
        }

        periodicBackupTask = Task { @MainActor [container] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ICloudBackupManager.periodicIntervalNanoseconds)
                guard !Task.isCancelled else { break }
                guard let latestAccountIdentifier = StorageModePolicy.currentCloudBackupAccountIdentifier() else {
                    continue
                }
                guard isBackupPipelineContextCurrent(
                    container: container,
                    accountIdentifier: latestAccountIdentifier
                ) else {
                    continue
                }
                if ICloudBackupManager.hasPendingLocalChanges(accountIdentifier: latestAccountIdentifier) {
                    let backupContext = ModelContext(container)
                    ICloudBackupManager.backupIfNeeded(
                        modelContext: backupContext,
                        accountIdentifier: latestAccountIdentifier,
                        force: false
                    )
                    continue
                }
                let syncContext = ModelContext(container)
                let didRestore = (try? await ICloudBackupManager.restoreIfNeeded(
                    modelContext: syncContext,
                    accountIdentifier: latestAccountIdentifier
                )) ?? false
                guard !Task.isCancelled else { break }
                guard isBackupPipelineContextCurrent(
                    container: container,
                    accountIdentifier: latestAccountIdentifier
                ) else {
                    continue
                }
                if didRestore {
                    await switchContainerIfNeeded(
                        refreshEntitlements: false,
                        forceRebuild: true,
                        reason: "periodic_restore_rebuild"
                    )
                    continue
                }
                let backupContext = ModelContext(container)
                if ICloudBackupManager.shouldForceBackupAfterRestoreAttempt(
                    modelContext: backupContext,
                    didRestore: didRestore
                ) {
                    ICloudBackupManager.backupIfNeeded(
                        modelContext: backupContext,
                        accountIdentifier: latestAccountIdentifier,
                        force: didRestore
                    )
                }
            }
        }
    }

    @MainActor
    private func handleModelContextDidSave(_ notification: Notification) {
        guard notification.object is ModelContext else { return }
        guard modelContainer != nil else { return }
        guard isAuthBootstrapComplete, hasResolvedAccountScope else { return }
        guard let accountIdentifier = StorageModePolicy.currentCloudBackupAccountIdentifier() else { return }
        guard !isSwitchingContainer else { return }
        guard !ICloudBackupManager.consumeIgnoredSaveEventIfNeeded(accountIdentifier: accountIdentifier) else {
            return
        }

        ICloudBackupManager.noteLocalMutation(accountIdentifier: accountIdentifier)

        saveTriggeredBackupTask?.cancel()
        saveTriggeredBackupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            performImmediateBackupIfPossible(force: false)
        }
    }

    @MainActor
    private func handleModelStoreRestoreWillBegin() {
        guard modelContainer != nil else { return }
        isSwitchingContainer = true
    }

    @MainActor
    private func handleModelStoreDidRestore(_ notification: Notification) {
        guard modelContainer != nil else { return }
        let didRestore = (notification.userInfo?["restored"] as? Bool) ?? true
        if didRestore {
            Task { @MainActor in
                await switchContainerIfNeeded(
                    refreshEntitlements: false,
                    forceRebuild: true,
                    reason: "model_store_restore_notification"
                )
            }
            return
        }
        isSwitchingContainer = false
    }

    @MainActor
    private func performImmediateBackupIfPossible(
        container: ModelContainer? = nil,
        accountIdentifier: String? = nil,
        force: Bool = false
    ) {
        let resolvedContainer = container ?? modelContainer
        guard let resolvedContainer else { return }
        let resolvedAccountIdentifier = accountIdentifier
            ?? StorageModePolicy.currentCloudBackupAccountIdentifier()
            ?? lastKnownAccountIdentifier
        guard let resolvedAccountIdentifier, !resolvedAccountIdentifier.isEmpty else { return }
        let backupContext = ModelContext(resolvedContainer)
        ICloudBackupManager.backupIfNeeded(
            modelContext: backupContext,
            accountIdentifier: resolvedAccountIdentifier,
            force: force
        )
    }

    @MainActor
    private func isBackupPipelineContextCurrent(
        container: ModelContainer,
        accountIdentifier: String
    ) -> Bool {
        guard !isSwitchingContainer else { return false }
        guard let currentContainer = modelContainer else { return false }
        guard ObjectIdentifier(currentContainer) == ObjectIdentifier(container) else { return false }
        guard StorageModePolicy.currentCloudBackupAccountIdentifier() == accountIdentifier else { return false }
        return true
    }

    @MainActor
    private func isBootstrapRestoreContextCurrent(
        container: ModelContainer,
        accountIdentifier: String
    ) -> Bool {
        guard let currentContainer = modelContainer else { return false }
        guard ObjectIdentifier(currentContainer) == ObjectIdentifier(container) else { return false }
        guard StorageModePolicy.currentCloudBackupAccountIdentifier() == accountIdentifier else { return false }
        return true
    }

    @MainActor
    private func performInitialBootstrapRestoreIfNeeded(
        container: ModelContainer,
        accountIdentifier: String
    ) async {
        let maxAttempts = 3

        for attempt in 0..<maxAttempts {
            guard !Task.isCancelled else { return }
            guard isBootstrapRestoreContextCurrent(
                container: container,
                accountIdentifier: accountIdentifier
            ) else {
                return
            }
            let restoreContext = ModelContext(container)
            let didRestore = (try? await ICloudBackupManager.restoreIfNeeded(
                modelContext: restoreContext,
                accountIdentifier: accountIdentifier
            )) ?? false
            if didRestore {
                return
            }
            if ICloudBackupManager.hasCoreFinancialData(in: ModelContext(container)) {
                return
            }
            guard attempt < (maxAttempts - 1) else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    private func currentResolvedAccountScope(allowLegacyEmailStoreFallback: Bool) -> ResolvedAccountScope {
        StorageModePolicy.resolveAccountScope(
            allowLegacyEmailStoreFallback: allowLegacyEmailStoreFallback
        )
    }

    @MainActor
    private func migrateLegacyEmailScopedLocalStoreIfNeeded(
        into destination: ModelContainer,
        resolvedScope: ResolvedAccountScope
    ) -> Bool {
        guard let canonicalEmailAccountIdentifier = resolvedScope.canonicalEmailAccountIdentifier,
              let legacyEmailAccountIdentifier = resolvedScope.legacyEmailAccountIdentifier,
              resolvedScope.storeAccountIdentifier == canonicalEmailAccountIdentifier,
              canonicalEmailAccountIdentifier != legacyEmailAccountIdentifier
        else {
            return false
        }

        let destinationContext = ModelContext(destination)
        guard !ICloudBackupManager.hasCoreFinancialData(in: destinationContext) else {
            return false
        }

        do {
            let legacyContainer = try AppModelContainerFactory.makeCurrentLocalContainerForMigration(
                accountIdentifier: legacyEmailAccountIdentifier
            )
            let legacyContext = ModelContext(legacyContainer)
            guard ICloudBackupManager.hasCoreFinancialData(in: legacyContext) else {
                return false
            }
            try DataStoreMigrator.migrateLocalSnapshotToCloudIfNeeded(
                from: legacyContainer,
                to: destination
            )
            AppDiagnostics.accountScope.debug(
                "migrated legacy local email store legacyIdentifier=\(legacyEmailAccountIdentifier, privacy: .public) canonicalIdentifier=\(canonicalEmailAccountIdentifier, privacy: .public)"
            )
            return true
        } catch {
            AppDiagnostics.accountScope.error(
                "failed to migrate legacy local email store canonicalIdentifier=\(canonicalEmailAccountIdentifier, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}

private struct LoadingBootstrapView: View {
    var body: some View {
        ZStack {
            Color(hex: "ECECECFF")
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                ProgressView()
                    .tint(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct AppModelContainerSelection {
    let container: ModelContainer
    let usesCloudKit: Bool
    let cloudKitErrorDescription: String?
    let cloudKitFailureReasonCode: String?
    let storeName: String
    let accountBucket: String
    let accountIdentifier: String?
}

private enum AppModelContainerFactory {
    private static let localStoreNamePrefix = "ArgentumVaultLocalStore"
    private static let cloudStoreNamePrefix = "ArgentumVaultCloudStore"
    private static let cloudContainerIdentifier = "iCloud.com.argentumvault.app.x9w248m88b.vp20260219"
    private static let schema = Schema([
        Category.self,
        Transaction.self,
        Asset.self,
        Wallet.self,
        WalletFolder.self,
        RecurringTransactionRule.self,
        CategoryBudget.self,
    ])

    static func makeContainerSelection(
        shouldUseCloudKit: Bool,
        accountIdentifier: String?
    ) -> AppModelContainerSelection {
        let accountBucket = AccountBucketHasher.bucket(for: accountIdentifier)
        let scopedLocalStoreName = scopedStoreName(
            prefix: localStoreNamePrefix,
            accountIdentifier: accountIdentifier
        )
        let scopedCloudStoreName = scopedStoreName(
            prefix: cloudStoreNamePrefix,
            accountIdentifier: accountIdentifier
        )
        let preferredConfiguration = ModelConfiguration(
            shouldUseCloudKit ? scopedCloudStoreName : scopedLocalStoreName,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: shouldUseCloudKit ? .private(cloudContainerIdentifier) : .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [preferredConfiguration])
            return AppModelContainerSelection(
                container: container,
                usesCloudKit: shouldUseCloudKit,
                cloudKitErrorDescription: nil,
                cloudKitFailureReasonCode: nil,
                storeName: shouldUseCloudKit ? scopedCloudStoreName : scopedLocalStoreName,
                accountBucket: accountBucket,
                accountIdentifier: accountIdentifier
            )
        } catch let preferredError {
            guard shouldUseCloudKit else {
                fatalError("Could not create local ModelContainer: \(preferredError)")
            }

            if CloudKitErrorDiagnostics.shouldRetryAfterStoreReset(error: preferredError) {
                resetStoreArtifacts(at: preferredConfiguration.url)
                do {
                    let retriedContainer = try ModelContainer(for: schema, configurations: [preferredConfiguration])
                    return AppModelContainerSelection(
                        container: retriedContainer,
                        usesCloudKit: true,
                        cloudKitErrorDescription: nil,
                        cloudKitFailureReasonCode: nil,
                        storeName: scopedCloudStoreName,
                        accountBucket: accountBucket,
                        accountIdentifier: accountIdentifier
                    )
                } catch {
                    // Continue to local fallback below.
                }
            }

            // Keep app usable when CloudKit schema/capabilities are not ready yet.
            let localFallbackConfiguration = ModelConfiguration(
                scopedLocalStoreName,
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )

            do {
                let localContainer = try ModelContainer(for: schema, configurations: [localFallbackConfiguration])
                let details = CloudKitErrorDiagnostics.technicalDetails(from: preferredError)
                let reasonCode = CloudKitErrorDiagnostics.reasonCode(from: preferredError)
                return AppModelContainerSelection(
                    container: localContainer,
                    usesCloudKit: false,
                    cloudKitErrorDescription: details,
                    cloudKitFailureReasonCode: reasonCode,
                    storeName: scopedLocalStoreName,
                    accountBucket: accountBucket,
                    accountIdentifier: accountIdentifier
                )
            } catch let localError {
                fatalError(
                    "Could not create ModelContainer. CloudKit error: \(preferredError). Local fallback error: \(localError)"
                )
            }
        }
    }

    private static func resetStoreArtifacts(at url: URL) {
        let fileManager = FileManager.default
        let primaryStoreURL = url
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")

        for candidate in [primaryStoreURL, walURL, shmURL] {
            if fileManager.fileExists(atPath: candidate.path) {
                try? fileManager.removeItem(at: candidate)
            }
        }
    }

    static func makeCurrentLocalContainerForMigration(accountIdentifier: String?) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            scopedStoreName(prefix: localStoreNamePrefix, accountIdentifier: accountIdentifier),
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func makeLegacyLocalContainerForMigration() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            localStoreNamePrefix,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func scopedStoreName(prefix: String, accountIdentifier: String?) -> String {
        "\(prefix)-\(AccountBucketHasher.bucket(for: accountIdentifier))"
    }
}

private enum DataStoreMigrator {
    static func migrateLocalSnapshotToCloudIfNeeded(from source: ModelContainer, to destination: ModelContainer) throws {
        let sourceContext = source.mainContext
        let destinationContext = destination.mainContext

        guard try hasAnyData(in: sourceContext) else { return }
        guard try !hasAnyData(in: destinationContext) else { return }

        let sourceCategories = try sourceContext.fetch(FetchDescriptor<Category>())
        let sourceWalletFolders = try sourceContext.fetch(FetchDescriptor<WalletFolder>())
        let sourceWallets = try sourceContext.fetch(FetchDescriptor<Wallet>())
        let sourceAssets = try sourceContext.fetch(FetchDescriptor<Asset>())
        let sourceTransactions = try sourceContext.fetch(FetchDescriptor<Transaction>())
        let sourceRecurringRules = try sourceContext.fetch(FetchDescriptor<RecurringTransactionRule>())
        let sourceBudgets = try sourceContext.fetch(FetchDescriptor<CategoryBudget>())

        var categoryMap: [PersistentIdentifier: Category] = [:]
        for sourceCategory in sourceCategories {
            let copiedCategory = Category(
                syncID: sourceCategory.syncID,
                name: sourceCategory.name,
                sourceLanguageCode: sourceCategory.sourceLanguageCode,
                localizedNamesJSON: sourceCategory.localizedNamesJSON,
                type: sourceCategory.type,
                colorHex: sourceCategory.colorHex,
                createdAt: sourceCategory.createdAt,
                updatedAt: sourceCategory.updatedAt
            )
            destinationContext.insert(copiedCategory)
            categoryMap[sourceCategory.persistentModelID] = copiedCategory
        }

        var folderMap: [PersistentIdentifier: WalletFolder] = [:]
        for sourceFolder in sourceWalletFolders {
            let copiedFolder = WalletFolder(
                name: sourceFolder.name,
                createdAt: sourceFolder.createdAt
            )
            destinationContext.insert(copiedFolder)
            folderMap[sourceFolder.persistentModelID] = copiedFolder
        }

        for sourceAsset in sourceAssets {
            let copiedAsset = Asset(
                symbol: sourceAsset.symbol,
                name: sourceAsset.name,
                kind: sourceAsset.kind
            )
            destinationContext.insert(copiedAsset)
        }

        var walletMap: [PersistentIdentifier: Wallet] = [:]
        for sourceWallet in sourceWallets {
            let copiedWallet = Wallet(
                name: sourceWallet.name,
                assetCode: sourceWallet.assetCode,
                kind: sourceWallet.kind,
                balance: sourceWallet.balance,
                colorHex: sourceWallet.colorHex,
                createdAt: sourceWallet.createdAt,
                updatedAt: sourceWallet.updatedAt
            )
            if let sourceFolder = sourceWallet.folder {
                copiedWallet.folder = folderMap[sourceFolder.persistentModelID]
            }
            destinationContext.insert(copiedWallet)
            walletMap[sourceWallet.persistentModelID] = copiedWallet
        }

        for sourceTransaction in sourceTransactions {
            let copiedTransaction = Transaction(
                amount: sourceTransaction.amount,
                currencyCode: sourceTransaction.currencyCode,
                date: sourceTransaction.date,
                note: sourceTransaction.note,
                type: sourceTransaction.type ?? .expense,
                walletNameSnapshot: sourceTransaction.walletNameSnapshot,
                walletKindRaw: sourceTransaction.walletKindRaw,
                walletColorHexSnapshot: sourceTransaction.walletColorHexSnapshot,
                transferWalletNameSnapshot: sourceTransaction.transferWalletNameSnapshot,
                transferWalletCurrencyCode: sourceTransaction.transferWalletCurrencyCode,
                transferWalletKindRaw: sourceTransaction.transferWalletKindRaw,
                transferWalletColorHexSnapshot: sourceTransaction.transferWalletColorHexSnapshot,
                transferAmount: sourceTransaction.transferAmount,
                photoData: sourceTransaction.photoData,
                category: sourceTransaction.category.flatMap { categoryMap[$0.persistentModelID] },
                wallet: sourceTransaction.wallet.flatMap { walletMap[$0.persistentModelID] },
                transferWallet: sourceTransaction.transferWallet.flatMap { walletMap[$0.persistentModelID] }
            )
            if sourceTransaction.type == nil {
                copiedTransaction.type = nil
            }
            destinationContext.insert(copiedTransaction)
        }

        for sourceRule in sourceRecurringRules {
            let copiedRule = RecurringTransactionRule(
                title: sourceRule.title,
                amount: sourceRule.amount,
                currencyCode: sourceRule.currencyCode,
                type: sourceRule.type,
                frequency: sourceRule.frequency,
                interval: sourceRule.interval,
                nextRunDate: sourceRule.nextRunDate,
                note: sourceRule.note,
                isActive: sourceRule.isActive,
                createdAt: sourceRule.createdAt,
                updatedAt: sourceRule.updatedAt,
                category: sourceRule.category.flatMap { categoryMap[$0.persistentModelID] },
                wallet: sourceRule.wallet.flatMap { walletMap[$0.persistentModelID] }
            )
            destinationContext.insert(copiedRule)
        }

        for sourceBudget in sourceBudgets {
            let copiedBudget = CategoryBudget(
                amount: sourceBudget.amount,
                currencyCode: sourceBudget.currencyCode,
                period: sourceBudget.period,
                isActive: sourceBudget.isActive,
                createdAt: sourceBudget.createdAt,
                updatedAt: sourceBudget.updatedAt,
                category: sourceBudget.category.flatMap { categoryMap[$0.persistentModelID] }
            )
            destinationContext.insert(copiedBudget)
        }

        try destinationContext.save()
    }

    private static func hasAnyData(in context: ModelContext) throws -> Bool {
        let categories = try context.fetch(FetchDescriptor<Category>())
        if !categories.isEmpty { return true }

        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        if !wallets.isEmpty { return true }

        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        if !transactions.isEmpty { return true }

        let recurringRules = try context.fetch(FetchDescriptor<RecurringTransactionRule>())
        if !recurringRules.isEmpty { return true }

        let budgets = try context.fetch(FetchDescriptor<CategoryBudget>())
        if !budgets.isEmpty { return true }

        let walletFolders = try context.fetch(FetchDescriptor<WalletFolder>())
        if !walletFolders.isEmpty { return true }

        let assets = try context.fetch(FetchDescriptor<Asset>())
        return !assets.isEmpty
    }
}

private enum CloudKitErrorDiagnostics {
    static func shouldRetryAfterStoreReset(error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "SwiftData.SwiftDataError", nsError.code == 1 {
            return true
        }
        let summary = flatten(error: error).joined(separator: " ").lowercased()
        return summary.contains("migration")
            || summary.contains("loadissuemodelcontainer")
            || summary.contains("incompatible")
            || summary.contains("store")
    }

    static func reasonCode(from error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "SwiftData.SwiftDataError", nsError.code == 1 {
            return "model_issue"
        }

        let summary = flatten(error: error).joined(separator: " ").lowercased()

        if summary.contains("ckerrornotauthenticated")
            || summary.contains("not authenticated")
            || summary.contains("no icloud")
            || summary.contains("no account")
            || summary.contains("account unavailable")
            || summary.contains("accountstatus = 3") {
            return "no_icloud_account"
        }
        if summary.contains("permission")
            || summary.contains("restricted")
            || summary.contains("forbidden")
            || summary.contains("not entitled") {
            return "restricted"
        }
        if summary.contains("network")
            || summary.contains("timed out")
            || summary.contains("service unavailable")
            || summary.contains("temporarily unavailable")
            || summary.contains("unreachable") {
            return "network"
        }
        if summary.contains("loadissuemodelcontainer")
            || summary.contains("model")
            || summary.contains("schema")
            || summary.contains("relationship")
            || summary.contains("migration") {
            return "model_issue"
        }
        return "generic"
    }

    static func technicalDetails(from error: Error) -> String {
        var lines = flatten(error: error)
        let reflection = String(reflecting: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !reflection.isEmpty, !lines.contains(reflection) {
            lines.insert(reflection, at: 0)
        }
        return lines.isEmpty ? String(describing: error) : lines.joined(separator: " | ")
    }

    private static func flatten(error: Error) -> [String] {
        var lines: [String] = []
        collect(error: error as NSError, depth: 0, lines: &lines)
        return lines
    }

    private static func collect(error: NSError, depth: Int, lines: inout [String]) {
        guard depth < 5 else { return }

        let base = "[\(error.domain):\(error.code)] \(error.localizedDescription)"
        if !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !lines.contains(base) {
            lines.append(base)
        }

        for (key, value) in error.userInfo {
            let keyText = String(describing: key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyText.isEmpty else { continue }
            let valueText = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !valueText.isEmpty else { continue }
            let line = "\(keyText)=\(valueText)"
            if !lines.contains(line) {
                lines.append(line)
            }
        }

        if let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !lines.contains(reason) {
            lines.append(reason)
        }

        if let detailed = error.userInfo["NSDetailedErrors"] as? [NSError] {
            for nested in detailed.prefix(3) {
                collect(error: nested, depth: depth + 1, lines: &lines)
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            collect(error: underlying, depth: depth + 1, lines: &lines)
        }
    }
}

private enum AppStorageDiagnostics {
    private static let activeModeKey = "storage.mode.active"
    private static let requestedCloudKey = "storage.mode.requested_cloud"
    private static let cloudKitErrorKey = "storage.cloudkit.last_error"
    private static let cloudKitReasonKey = "storage.cloudkit.last_reason_code"

    static func persist(requestedCloud: Bool, selection: AppModelContainerSelection) {
        let defaults = UserDefaults.standard
        defaults.set(requestedCloud ? "cloud" : "local", forKey: activeModeKey)
        defaults.set(requestedCloud, forKey: requestedCloudKey)
        if let error = selection.cloudKitErrorDescription, !error.isEmpty {
            defaults.set(error, forKey: cloudKitErrorKey)
        } else {
            defaults.removeObject(forKey: cloudKitErrorKey)
        }
        if let reasonCode = selection.cloudKitFailureReasonCode, !reasonCode.isEmpty {
            defaults.set(reasonCode, forKey: cloudKitReasonKey)
        } else {
            defaults.removeObject(forKey: cloudKitReasonKey)
        }
    }
}

private enum StorageModePolicy {
    static func resolveAccountScope(
        allowLegacyEmailStoreFallback: Bool = true
    ) -> ResolvedAccountScope {
        AccountScopeSnapshot(defaults: .standard)
            .resolvedScope(allowLegacyEmailStoreFallback: allowLegacyEmailStoreFallback)
    }

    static func currentCloudBackupAccountIdentifier() -> String? {
        resolveAccountScope().cloudBackupAccountIdentifier
    }

    static func currentAppleAccountIdentifier() -> String? {
        resolveAccountScope().snapshot.appleAccountIdentifier
    }

    static func currentEmailAccountIdentifier() -> String? {
        let resolvedScope = resolveAccountScope()
        return resolvedScope.canonicalEmailAccountIdentifier
            ?? resolvedScope.legacyEmailAccountIdentifier
    }

    static func currentAccountIdentifier() -> String? {
        resolveAccountScope().storeAccountIdentifier
    }

    static func shouldRequestCloudKitStorage() -> Bool {
        resolveAccountScope().shouldRequestCloudBackup
    }
}
