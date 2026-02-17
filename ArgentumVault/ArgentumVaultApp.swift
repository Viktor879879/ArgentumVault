//
//  ArgentumVaultApp.swift
//  ArgentumVault
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import SwiftUI
import SwiftData
import CloudKit

@main
struct ArgentumVaultApp: App {
    var body: some Scene {
        WindowGroup {
            AppBootstrapView()
        }
    }
}

private struct AppBootstrapView: View {
    @State private var modelContainer: ModelContainer?
    @State private var isCloudStoreEnabled = false

    var body: some View {
        Group {
            if let modelContainer {
                ContentView()
                    .modelContainer(modelContainer)
            } else {
                LoadingBootstrapView()
            }
        }
        .task {
            await bootstrapIfNeeded()
        }
    }

    @MainActor
    private func bootstrapIfNeeded() async {
        guard modelContainer == nil else { return }
        await switchContainerIfNeeded(refreshEntitlements: true)
    }

    @MainActor
    private func switchContainerIfNeeded(refreshEntitlements: Bool) async {
        let shouldUseCloudKit: Bool = {
            if refreshEntitlements {
                return false
            }
            return SubscriptionManager.shouldUseCloudKitStorage()
        }()

        let resolvedShouldUseCloudKit: Bool
        if refreshEntitlements {
            resolvedShouldUseCloudKit = await SubscriptionManager.resolveProAccessForLaunch()
        } else {
            resolvedShouldUseCloudKit = shouldUseCloudKit
        }

        if modelContainer != nil, resolvedShouldUseCloudKit == isCloudStoreEnabled {
            return
        }

        let previousContainer = modelContainer
        let previousUsesCloudStore = isCloudStoreEnabled
        let cloudKitPreflightResult = resolvedShouldUseCloudKit ? await CloudKitPreflight.evaluate() : nil
        var selection = AppModelContainerFactory.makeContainerSelection(shouldUseCloudKit: resolvedShouldUseCloudKit)

        if resolvedShouldUseCloudKit,
           !selection.usesCloudKit,
           selection.cloudKitFailureReasonCode == nil {
            selection = AppModelContainerSelection(
                container: selection.container,
                usesCloudKit: false,
                cloudKitErrorDescription: selection.cloudKitErrorDescription,
                cloudKitFailureReasonCode: cloudKitPreflightResult?.reasonCode ?? "generic"
            )
        }

        if selection.usesCloudKit {
            if let previousContainer, !previousUsesCloudStore {
                try? DataStoreMigrator.migrateLocalSnapshotToCloudIfNeeded(
                    from: previousContainer,
                    to: selection.container
                )
            } else if previousContainer == nil {
                if let currentLocalContainer = try? AppModelContainerFactory.makeCurrentLocalContainerForMigration() {
                    try? DataStoreMigrator.migrateLocalSnapshotToCloudIfNeeded(
                        from: currentLocalContainer,
                        to: selection.container
                    )
                }
                if let legacyLocalContainer = try? AppModelContainerFactory.makeLegacyLocalContainerForMigration() {
                    try? DataStoreMigrator.migrateLocalSnapshotToCloudIfNeeded(
                        from: legacyLocalContainer,
                        to: selection.container
                    )
                }
            }
        }

        modelContainer = selection.container
        isCloudStoreEnabled = selection.usesCloudKit
        AppStorageDiagnostics.persist(requestedCloud: resolvedShouldUseCloudKit, selection: selection)
    }
}

private struct CloudKitPreflightResult {
    let canUseCloudKit: Bool
    let reasonCode: String?
}

private enum CloudKitPreflight {
    private static let containerIdentifier = "iCloud.com.argentumvault.app"

    static func evaluate() async -> CloudKitPreflightResult {
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
    private static let localStoreName = "ArgentumVaultLocalStore"
    private static let cloudStoreName = "ArgentumVaultCloudStore"
    private static let schema = Schema([
        Category.self,
        Transaction.self,
        Asset.self,
        Wallet.self,
        WalletFolder.self,
        RecurringTransactionRule.self,
        CategoryBudget.self,
    ])

    static func makeContainerSelection(shouldUseCloudKit: Bool) -> AppModelContainerSelection {
        let preferredConfiguration = ModelConfiguration(
            shouldUseCloudKit ? cloudStoreName : localStoreName,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: shouldUseCloudKit ? .automatic : .none
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

            // Keep app usable when CloudKit schema/capabilities are not ready yet.
            let localFallbackConfiguration = ModelConfiguration(
                localStoreName,
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

    static func makeCurrentLocalContainerForMigration() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            localStoreName,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func makeLegacyLocalContainerForMigration() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
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
    static func reasonCode(from error: Error) -> String {
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
        let lines = flatten(error: error)
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
