//
//  ArgentumVaultApp.swift
//  ArgentumVault
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import SwiftUI
import SwiftData
import CloudKit
import CryptoKit

@main
struct ArgentumVaultApp: App {
    var body: some Scene {
        WindowGroup {
            AppBootstrapView()
        }
    }
}

private struct AppBootstrapView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appleUserID") private var bootstrapAppleUserID = ""
    @AppStorage("emailUserEmail") private var bootstrapEmailUserEmail = ""
    @AppStorage("authMethod") private var bootstrapAuthMethod = ""
    @State private var modelContainer: ModelContainer?
    @State private var isCloudStoreEnabled = false
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
            if !isSwitchingContainer, let modelContainer {
                ContentView()
                    .id(containerEpoch)
                    .modelContainer(modelContainer)
            } else {
                LoadingBootstrapView()
            }
        }
        .task {
            await bootstrapIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
            Task { @MainActor in
                handleModelContextDidSave(notification)
            }
        }
        .onChange(of: bootstrapAppleUserID) { _, _ in
            Task { @MainActor in
                await switchContainerIfNeeded(refreshEntitlements: false)
            }
        }
        .onChange(of: bootstrapEmailUserEmail) { _, _ in
            Task { @MainActor in
                await switchContainerIfNeeded(refreshEntitlements: false)
            }
        }
        .onChange(of: bootstrapAuthMethod) { _, _ in
            Task { @MainActor in
                await switchContainerIfNeeded(refreshEntitlements: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
            Task { @MainActor in
                await switchContainerIfNeeded(refreshEntitlements: false)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { @MainActor in
                if newPhase == .active {
                    await switchContainerIfNeeded(refreshEntitlements: true)
                } else if newPhase == .inactive || newPhase == .background {
                    performImmediateBackupIfPossible(force: true)
                }
            }
        }
    }

    @MainActor
    private func bootstrapIfNeeded() async {
        guard modelContainer == nil else { return }
        await switchContainerIfNeeded(refreshEntitlements: true)
        guard modelContainer == nil else { return }

        // Emergency fallback: never leave bootstrap screen hanging.
        let accountIdentifier = StorageModePolicy.currentAccountIdentifier()
        let fallbackSelection = AppModelContainerFactory.makeContainerSelection(
            shouldUseCloudKit: false,
            accountIdentifier: accountIdentifier
        )
        modelContainer = fallbackSelection.container
        isCloudStoreEnabled = false
        activeStoreAccountIdentifier = accountIdentifier
        isSwitchingContainer = false
        AppStorageDiagnostics.persist(requestedCloud: false, selection: fallbackSelection)
        configureICloudBackupPipeline(
            requestedCloud: false,
            usesCloudKit: false,
            container: fallbackSelection.container
        )
    }

    @MainActor
    private func switchContainerIfNeeded(refreshEntitlements: Bool) async {
        guard !isReconfiguringContainer else {
            hasPendingReconfigureRequest = true
            pendingReconfigureNeedsEntitlementRefresh = pendingReconfigureNeedsEntitlementRefresh || refreshEntitlements
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
                    await switchContainerIfNeeded(refreshEntitlements: needsRefresh)
                }
            }
        }

        if refreshEntitlements {
            // Do not block app bootstrap on StoreKit entitlement refresh.
            Task.detached(priority: .utility) {
                _ = await SubscriptionManager.resolveProAccessForLaunch()
            }
        }
        // Main SwiftData store is always local and account-scoped.
        // CloudKit is used only by backup/restore pipeline to keep app accounts isolated.
        let resolvedShouldUseCloudKit = false
        let resolvedShouldEnableCloudBackup = StorageModePolicy.shouldRequestCloudKitStorage()
        let resolvedAccountIdentifier = StorageModePolicy.currentAccountIdentifier()

        if let existingContainer = modelContainer,
           resolvedShouldUseCloudKit == isCloudStoreEnabled,
           resolvedAccountIdentifier == activeStoreAccountIdentifier {
            configureICloudBackupPipeline(
                requestedCloud: resolvedShouldEnableCloudBackup,
                usesCloudKit: isCloudStoreEnabled,
                container: existingContainer
            )
            return
        }

        let previousContainer = modelContainer
        let previousUsesCloudStore = isCloudStoreEnabled
        let previousContainerIdentifier = previousContainer.map(ObjectIdentifier.init)

        let selection = AppModelContainerFactory.makeContainerSelection(
            shouldUseCloudKit: false,
            accountIdentifier: resolvedAccountIdentifier
        )

        if let previousContainer,
           selection.usesCloudKit == previousUsesCloudStore,
           resolvedAccountIdentifier == activeStoreAccountIdentifier {
            // Avoid container churn while CloudKit remains unavailable (or unchanged).
            // Recreating identical mode containers can invalidate live model objects and crash SwiftData views.
            AppStorageDiagnostics.persist(requestedCloud: resolvedShouldUseCloudKit, selection: selection)
            scheduleCloudRetryIfNeeded(requestedCloud: resolvedShouldUseCloudKit, selection: selection)
            configureICloudBackupPipeline(
                requestedCloud: resolvedShouldEnableCloudBackup,
                usesCloudKit: previousUsesCloudStore,
                container: previousContainer
            )
            return
        }

        let shouldSwitchStoreType = previousContainer != nil
            && (
                selection.usesCloudKit != previousUsesCloudStore
                || resolvedAccountIdentifier != activeStoreAccountIdentifier
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

        modelContainer = selection.container
        isCloudStoreEnabled = selection.usesCloudKit
        activeStoreAccountIdentifier = resolvedAccountIdentifier
        AppStorageDiagnostics.persist(requestedCloud: resolvedShouldUseCloudKit, selection: selection)
        scheduleCloudRetryIfNeeded(requestedCloud: resolvedShouldUseCloudKit, selection: selection)
        configureICloudBackupPipeline(
            requestedCloud: resolvedShouldEnableCloudBackup,
            usesCloudKit: selection.usesCloudKit,
            container: selection.container
        )

        if previousContainerIdentifier != ObjectIdentifier(selection.container) {
            containerEpoch += 1
        }
    }

    @MainActor
    private func scheduleCloudRetryIfNeeded(requestedCloud: Bool, selection: AppModelContainerSelection) {
        cloudRetryTask?.cancel()
        cloudRetryTask = nil

        guard requestedCloud, !selection.usesCloudKit else {
            return
        }

        cloudRetryTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await switchContainerIfNeeded(refreshEntitlements: false)
        }
    }

    @MainActor
    private func configureICloudBackupPipeline(
        requestedCloud: Bool,
        usesCloudKit: Bool,
        container: ModelContainer
    ) {
        startupBackupTask?.cancel()
        startupBackupTask = nil
        periodicBackupTask?.cancel()
        periodicBackupTask = nil

        guard requestedCloud, let accountIdentifier = StorageModePolicy.currentCloudBackupAccountIdentifier() else {
            lastKnownAccountIdentifier = nil
            return
        }
        lastKnownAccountIdentifier = accountIdentifier

        startupBackupTask = Task { @MainActor [container] in
            let startupDelay: UInt64 = usesCloudKit ? 10_000_000_000 : 350_000_000
            try? await Task.sleep(nanoseconds: startupDelay)
            guard !Task.isCancelled else { return }
            guard isBackupPipelineContextCurrent(container: container, accountIdentifier: accountIdentifier) else {
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
                let backupContext = ModelContext(container)
                ICloudBackupManager.backupIfNeeded(
                    modelContext: backupContext,
                    accountIdentifier: accountIdentifier,
                    force: true
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
                let backupContext = ModelContext(container)
                ICloudBackupManager.backupIfNeeded(
                    modelContext: backupContext,
                    accountIdentifier: latestAccountIdentifier
                )
            }
        }
    }

    @MainActor
    private func handleModelContextDidSave(_ notification: Notification) {
        guard notification.object is ModelContext else { return }
        guard modelContainer != nil else { return }
        guard StorageModePolicy.currentCloudBackupAccountIdentifier() != nil else { return }
        guard !isSwitchingContainer else { return }

        saveTriggeredBackupTask?.cancel()
        saveTriggeredBackupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            performImmediateBackupIfPossible(force: false)
        }
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
}

private struct CloudKitPreflightResult {
    let canUseCloudKit: Bool
    let reasonCode: String?
}

private enum CloudKitPreflight {
    private static let containerIdentifier = "iCloud.com.argentumvault.app.x9w248m88b.vp20260219"

    static func evaluate() async -> CloudKitPreflightResult {
        await withTaskGroup(of: CloudKitPreflightResult.self) { group in
            group.addTask {
                await evaluateWithoutTimeout()
            }
            group.addTask {
                // CloudKit account status may occasionally hang.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                return CloudKitPreflightResult(canUseCloudKit: false, reasonCode: "network")
            }
            let result = await group.next() ?? CloudKitPreflightResult(canUseCloudKit: false, reasonCode: "network")
            group.cancelAll()
            return result
        }
    }

    private static func evaluateWithoutTimeout() async -> CloudKitPreflightResult {
        await withCheckedContinuation { continuation in
            let container = CKContainer(identifier: containerIdentifier)
            container.accountStatus { status, error in
                if let reasonCode = reasonCode(from: error) {
                    continuation.resume(returning: CloudKitPreflightResult(canUseCloudKit: false, reasonCode: reasonCode))
                    return
                }

                switch status {
                case .available:
                    continuation.resume(returning: CloudKitPreflightResult(canUseCloudKit: true, reasonCode: nil))
                case .noAccount:
                    continuation.resume(returning: CloudKitPreflightResult(canUseCloudKit: false, reasonCode: "no_icloud_account"))
                case .restricted:
                    continuation.resume(returning: CloudKitPreflightResult(canUseCloudKit: false, reasonCode: "restricted"))
                case .couldNotDetermine:
                    continuation.resume(returning: CloudKitPreflightResult(canUseCloudKit: false, reasonCode: "network"))
                case .temporarilyUnavailable:
                    continuation.resume(returning: CloudKitPreflightResult(canUseCloudKit: false, reasonCode: "network"))
                @unknown default:
                    continuation.resume(returning: CloudKitPreflightResult(canUseCloudKit: false, reasonCode: "generic"))
                }
            }
        }
    }

    private static func reasonCode(from error: Error?) -> String? {
        guard let error else { return nil }
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return "no_icloud_account"
            case .permissionFailure:
                return "restricted"
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                return "network"
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("not authenticated") || message.contains("icloud account") {
            return "no_icloud_account"
        }
        if message.contains("restricted") || message.contains("permission") {
            return "restricted"
        }
        if message.contains("network") || message.contains("unavailable") || message.contains("timed out") {
            return "network"
        }
        return "generic"
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
                cloudKitFailureReasonCode: nil
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
                        cloudKitFailureReasonCode: nil
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
                    cloudKitFailureReasonCode: reasonCode
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
        "\(prefix)-\(accountBucket(accountIdentifier))"
    }

    private static func accountBucket(_ accountIdentifier: String?) -> String {
        guard let accountIdentifier, !accountIdentifier.isEmpty else { return "guest" }
        let digest = SHA256.hash(data: Data(accountIdentifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).lowercased()
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
                name: sourceCategory.name,
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
        defaults.set(selection.usesCloudKit ? "cloud" : "local", forKey: activeModeKey)
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
    private static let appleUserIDKey = "appleUserID"
    private static let emailUserEmailKey = "emailUserEmail"

    static func currentCloudBackupAccountIdentifier() -> String? {
        currentAppleAccountIdentifier()
    }

    static func currentAppleAccountIdentifier() -> String? {
        let defaults = UserDefaults.standard
        let appleUserID = defaults.string(forKey: appleUserIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appleUserID.isEmpty else { return nil }
        return "apple:\(appleUserID)"
    }

    static func currentEmailAccountIdentifier() -> String? {
        let defaults = UserDefaults.standard
        let emailUserEmail = defaults.string(forKey: emailUserEmailKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !emailUserEmail.isEmpty else { return nil }
        return "email:\(emailUserEmail)"
    }

    static func currentAccountIdentifier() -> String? {
        currentAppleAccountIdentifier() ?? currentEmailAccountIdentifier()
    }

    static func shouldRequestCloudKitStorage() -> Bool {
        // Until backend email auth is introduced, cloud backup/sync is Apple-ID-only.
        return currentCloudBackupAccountIdentifier() != nil
    }
}
