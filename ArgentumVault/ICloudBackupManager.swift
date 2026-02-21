import Foundation
import SwiftData
import CryptoKit
import CloudKit

@MainActor
enum ICloudBackupManager {
    private struct PendingCloudUpload {
        let payload: Data
        let payloadHash: String
        let force: Bool
    }

    struct SnapshotDebugStatus {
        let accountBucket: String
        let storageMode: String
        let storageReasonCode: String?
        let storageError: String?
        let lastLocalSuccess: Date?
        let lastCloudSuccess: Date?
        let lastLocalError: String?
        let lastCloudError: String?
    }

    // Periodic safety backup. Primary trigger is save-driven backup in app runtime.
    static let periodicIntervalNanoseconds: UInt64 = 900_000_000_000 // 15 minutes

    private static let schemaVersion = 1
    private static let ubiquityContainerIdentifier = "iCloud.com.argentumvault.app.x9w248m88b.vp20260219"
    private static let cloudKitContainerIdentifier = "iCloud.com.argentumvault.app.x9w248m88b.vp20260219"
    private static let cloudSnapshotRecordType = "AVBackupSnapshot"
    private static let cloudPayloadAssetField = "payloadAsset"
    private static let cloudPayloadHashField = "payloadHash"
    private static let cloudUpdatedAtField = "updatedAt"
    private static let cloudSchemaVersionField = "schemaVersion"
    private static let backupDirectoryName = "ArgentumVaultBackups"
    private static let backupFileName = "snapshot.json"
    private static let lastHashDefaultsPrefix = "backup.icloud.last_hash."
    private static let lastCloudHashDefaultsPrefix = "backup.icloud.cloudkit.last_hash."
    private static let lastAttemptDefaultsPrefix = "backup.icloud.last_attempt."
    private static let lastSuccessDefaultsPrefix = "backup.icloud.last_success."
    private static let lastErrorDefaultsKey = "backup.icloud.last_error"
    private static let lastCloudSuccessDefaultsPrefix = "backup.icloud.cloudkit.last_success."
    private static let lastCloudErrorDefaultsPrefix = "backup.icloud.cloudkit.last_error."
    private static let storageCloudKitErrorKey = "storage.cloudkit.last_error"
    private static let storageCloudKitReasonKey = "storage.cloudkit.last_reason_code"
    private static let minimumAttemptInterval: TimeInterval = 5
    private static var cloudUploadTasks: [String: Task<Void, Never>] = [:]
    private static var pendingCloudUploads: [String: PendingCloudUpload] = [:]

    static func backupIfNeeded(modelContext: ModelContext, accountIdentifier: String, force: Bool = false) {
        let backupURL = backupFileURL(for: accountIdentifier)
        let bucket = accountBucket(accountIdentifier)
        let now = Date().timeIntervalSince1970
        let lastAttemptKey = lastAttemptDefaultsPrefix + bucket
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.double(forKey: lastAttemptKey)
        if !force, lastAttempt > 0, (now - lastAttempt) < minimumAttemptInterval {
            return
        }
        defaults.set(now, forKey: lastAttemptKey)

        do {
            let snapshot = try makeSnapshot(from: modelContext)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(snapshot)

            let payloadHash = hashHex(data: payload)
            let lastHashKey = lastHashDefaultsPrefix + bucket
            let lastCloudHashKey = lastCloudHashDefaultsPrefix + bucket
            let localHashMatches = defaults.string(forKey: lastHashKey) == payloadHash
            let cloudHashMatches = defaults.string(forKey: lastCloudHashKey) == payloadHash
            if localHashMatches && cloudHashMatches && !force {
                return
            }

            if let backupURL {
                try FileManager.default.createDirectory(
                    at: backupURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try payload.write(to: backupURL, options: .atomic)
            }

            defaults.set(payloadHash, forKey: lastHashKey)
            defaults.set(Date().timeIntervalSince1970, forKey: lastSuccessDefaultsPrefix + bucket)
            defaults.removeObject(forKey: lastErrorDefaultsKey)
            uploadSnapshotToCloudKit(payload: payload, payloadHash: payloadHash, bucket: bucket, force: force)
        } catch {
            let description = String(describing: error)
            defaults.set(description, forKey: lastErrorDefaultsKey)
            defaults.set(description, forKey: storageCloudKitErrorKey)
            defaults.set(reasonCode(for: error), forKey: storageCloudKitReasonKey)
        }
    }

    @discardableResult
    static func restoreIfNeeded(modelContext: ModelContext, accountIdentifier: String) async throws -> Bool {
        guard !hasCoreFinancialData(in: modelContext) else { return false }
        let bucket = accountBucket(accountIdentifier)

        let payload: Data
        if let backupURL = backupFileURL(for: accountIdentifier),
           FileManager.default.fileExists(atPath: backupURL.path) {
            payload = try Data(contentsOf: backupURL)
        } else if let cloudPayload = try await fetchSnapshotPayloadFromCloudKit(bucket: bucket) {
            payload = cloudPayload
            if let backupURL = backupFileURL(for: accountIdentifier) {
                try? FileManager.default.createDirectory(
                    at: backupURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? payload.write(to: backupURL, options: .atomic)
            }
        } else {
            return false
        }

        let didRestore = try restorePayload(payload, modelContext: modelContext, bucket: bucket)
        if didRestore {
            UserDefaults.standard.removeObject(forKey: lastCloudErrorDefaultsPrefix + bucket)
        }
        return didRestore
    }

    static func shouldForceBackupAfterRestoreAttempt(
        modelContext: ModelContext,
        didRestore: Bool
    ) -> Bool {
        _ = modelContext
        return didRestore
    }

    static func debugStatus(accountIdentifier: String) -> SnapshotDebugStatus {
        let defaults = UserDefaults.standard
        let bucket = accountBucket(accountIdentifier)
        let localSuccess = dateFromDefaults(defaults, key: lastSuccessDefaultsPrefix + bucket)
        let cloudSuccess = dateFromDefaults(defaults, key: lastCloudSuccessDefaultsPrefix + bucket)
        let localError = defaults.string(forKey: lastErrorDefaultsKey)
        let cloudError = defaults.string(forKey: lastCloudErrorDefaultsPrefix + bucket)
        return SnapshotDebugStatus(
            accountBucket: bucket,
            storageMode: defaults.string(forKey: "storage.mode.active") ?? "local",
            storageReasonCode: defaults.string(forKey: storageCloudKitReasonKey),
            storageError: defaults.string(forKey: storageCloudKitErrorKey),
            lastLocalSuccess: localSuccess,
            lastCloudSuccess: cloudSuccess,
            lastLocalError: localError,
            lastCloudError: cloudError
        )
    }

    private static func restorePayload(
        _ payload: Data,
        modelContext: ModelContext,
        bucket: String
    ) throws -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BackupSnapshot.self, from: payload)
        guard snapshot.schemaVersion <= schemaVersion else { return false }

        do {
            try clearAllData(in: modelContext)
            try apply(snapshot: snapshot, to: modelContext)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        let lastHashKey = lastHashDefaultsPrefix + bucket
        let lastCloudHashKey = lastCloudHashDefaultsPrefix + bucket
        UserDefaults.standard.set(hashHex(data: payload), forKey: lastHashKey)
        UserDefaults.standard.set(hashHex(data: payload), forKey: lastCloudHashKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSuccessDefaultsPrefix + bucket)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCloudSuccessDefaultsPrefix + bucket)
        UserDefaults.standard.removeObject(forKey: lastErrorDefaultsKey)
        return true
    }

    private static func backupFileURL(for accountIdentifier: String) -> URL? {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerIdentifier) else {
            return nil
        }
        let bucket = accountBucket(accountIdentifier)
        return containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent(backupFileName, isDirectory: false)
    }

    private static func accountBucket(_ accountIdentifier: String) -> String {
        hashHex(string: accountIdentifier).prefix(24).lowercased()
    }

    private static func uploadSnapshotToCloudKit(
        payload: Data,
        payloadHash: String,
        bucket: String,
        force: Bool
    ) {
        let defaults = UserDefaults.standard
        let lastCloudHashKey = lastCloudHashDefaultsPrefix + bucket
        let lastCloudHash = defaults.string(forKey: lastCloudHashKey)
        if !force, lastCloudHash == payloadHash {
            return
        }
        let cloudSuccessKey = lastCloudSuccessDefaultsPrefix + bucket
        let cloudErrorKey = lastCloudErrorDefaultsPrefix + bucket
        let storageErrorKey = storageCloudKitErrorKey
        let storageReasonKey = storageCloudKitReasonKey

        if cloudUploadTasks[bucket] != nil {
            pendingCloudUploads[bucket] = PendingCloudUpload(
                payload: payload,
                payloadHash: payloadHash,
                force: force
            )
            return
        }

        cloudUploadTasks[bucket] = Task.detached(priority: .utility) {
            defer {
                Task { @MainActor in
                    cloudUploadTasks[bucket] = nil
                    if let pending = pendingCloudUploads.removeValue(forKey: bucket) {
                        uploadSnapshotToCloudKit(
                            payload: pending.payload,
                            payloadHash: pending.payloadHash,
                            bucket: bucket,
                            force: pending.force
                        )
                    }
                }
            }
            guard !Task.isCancelled else { return }
            do {
                try await saveSnapshotPayloadToCloudKit(payload: payload, payloadHash: payloadHash, bucket: bucket)
                guard !Task.isCancelled else { return }
                let defaults = UserDefaults.standard
                defaults.set(payloadHash, forKey: lastCloudHashKey)
                defaults.set(Date().timeIntervalSince1970, forKey: cloudSuccessKey)
                defaults.removeObject(forKey: cloudErrorKey)
                defaults.removeObject(forKey: storageErrorKey)
                defaults.removeObject(forKey: storageReasonKey)
            } catch {
                let description = String(describing: error)
                let defaults = UserDefaults.standard
                defaults.set(description, forKey: cloudErrorKey)
                defaults.set(description, forKey: storageErrorKey)
                defaults.set(reasonCode(for: error), forKey: storageReasonKey)
            }
        }
    }

    private static func saveSnapshotPayloadToCloudKit(
        payload: Data,
        payloadHash: String,
        bucket: String
    ) async throws {
        let container = CKContainer(identifier: cloudKitContainerIdentifier)
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: "snapshot-\(bucket)")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).json", isDirectory: false)
        try payload.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        for attempt in 0..<3 {
            do {
                let record = try await fetchOrCreateRecord(
                    in: database,
                    recordID: recordID
                )
                applySnapshotFields(
                    to: record,
                    payloadHash: payloadHash,
                    tempURL: tempURL
                )
                _ = try await saveRecord(record, in: database)
                return
            } catch let ckError as CKError where ckError.code == .serverRecordChanged {
                if let serverRecord = ckError.serverRecord {
                    applySnapshotFields(
                        to: serverRecord,
                        payloadHash: payloadHash,
                        tempURL: tempURL
                    )
                    _ = try await saveRecord(serverRecord, in: database)
                    return
                }
                if attempt == 2 { throw ckError }
            } catch {
                if attempt == 2 { throw error }
            }
        }
    }

    private static func fetchSnapshotPayloadFromCloudKit(bucket: String) async throws -> Data? {
        let container = CKContainer(identifier: cloudKitContainerIdentifier)
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: "snapshot-\(bucket)")
        do {
            guard let record = try await fetchRecord(with: recordID, in: database) else {
                return nil
            }

            if let asset = record[cloudPayloadAssetField] as? CKAsset,
               let fileURL = asset.fileURL,
               FileManager.default.fileExists(atPath: fileURL.path) {
                return try Data(contentsOf: fileURL)
            }

            return nil
        } catch {
            let defaults = UserDefaults.standard
            defaults.set(String(describing: error), forKey: storageCloudKitErrorKey)
            defaults.set(reasonCode(for: error), forKey: storageCloudKitReasonKey)
            throw error
        }
    }

    private static func fetchOrCreateRecord(
        in database: CKDatabase,
        recordID: CKRecord.ID
    ) async throws -> CKRecord {
        if let existing = try await fetchRecord(with: recordID, in: database) {
            return existing
        }
        return CKRecord(recordType: cloudSnapshotRecordType, recordID: recordID)
    }

    private static func applySnapshotFields(
        to record: CKRecord,
        payloadHash: String,
        tempURL: URL
    ) {
        record[cloudPayloadHashField] = payloadHash as CKRecordValue
        record[cloudUpdatedAtField] = Date() as CKRecordValue
        record[cloudSchemaVersionField] = NSNumber(value: schemaVersion)
        record[cloudPayloadAssetField] = CKAsset(fileURL: tempURL)
    }

    private static func fetchRecord(
        with recordID: CKRecord.ID,
        in database: CKDatabase
    ) async throws -> CKRecord? {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: record)
            }
        }
    }

    private static func saveRecord(
        _ record: CKRecord,
        in database: CKDatabase
    ) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(
                recordsToSave: [record],
                recordIDsToDelete: nil
            )
            operation.savePolicy = .changedKeys
            operation.isAtomic = true
            operation.modifyRecordsCompletionBlock = { savedRecords, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let savedRecord = savedRecords?.first {
                    continuation.resume(returning: savedRecord)
                } else {
                    continuation.resume(throwing: CKError(.internalError))
                }
            }
            database.add(operation)
        }
    }

    nonisolated private static func reasonCode(for error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return "no_icloud_account"
            case .permissionFailure:
                return "restricted"
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                return "network"
            default:
                return "model_issue"
            }
        }
        let message = String(describing: error).lowercased()
        if message.contains("not authenticated") || message.contains("no account") {
            return "no_icloud_account"
        }
        if message.contains("permission") || message.contains("restricted") || message.contains("forbidden") {
            return "restricted"
        }
        if message.contains("network") || message.contains("timed out") || message.contains("unavailable") {
            return "network"
        }
        return "model_issue"
    }

    private static func makeSnapshot(from context: ModelContext) throws -> BackupSnapshot {
        let categories = try context.fetch(FetchDescriptor<Category>())
        let folders = try context.fetch(FetchDescriptor<WalletFolder>())
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        let assets = try context.fetch(FetchDescriptor<Asset>())
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let recurringRules = try context.fetch(FetchDescriptor<RecurringTransactionRule>())
        let budgets = try context.fetch(FetchDescriptor<CategoryBudget>())

        var categoryRecords: [CategoryRecord] = []
        var categoryKeyByID: [PersistentIdentifier: String] = [:]
        for (index, category) in categories.sorted(by: categorySort).enumerated() {
            let key = makeEntityKey(
                kind: "category",
                index: index,
                parts: [category.name, category.type.rawValue, category.createdAt.timeIntervalSince1970.description]
            )
            categoryRecords.append(
                CategoryRecord(
                    key: key,
                    name: category.name,
                    typeRaw: category.type.rawValue,
                    colorHex: category.colorHex,
                    createdAt: category.createdAt,
                    updatedAt: category.updatedAt
                )
            )
            categoryKeyByID[category.persistentModelID] = key
        }

        var folderRecords: [WalletFolderRecord] = []
        var folderKeyByID: [PersistentIdentifier: String] = [:]
        for (index, folder) in folders.sorted(by: folderSort).enumerated() {
            let key = makeEntityKey(
                kind: "folder",
                index: index,
                parts: [folder.name, folder.createdAt.timeIntervalSince1970.description]
            )
            folderRecords.append(
                WalletFolderRecord(
                    key: key,
                    name: folder.name,
                    createdAt: folder.createdAt
                )
            )
            folderKeyByID[folder.persistentModelID] = key
        }

        var walletRecords: [WalletRecord] = []
        var walletKeyByID: [PersistentIdentifier: String] = [:]
        for (index, wallet) in wallets.sorted(by: walletSort).enumerated() {
            let key = makeEntityKey(
                kind: "wallet",
                index: index,
                parts: [
                    wallet.name,
                    wallet.assetCode,
                    wallet.kind.rawValue,
                    wallet.createdAt.timeIntervalSince1970.description
                ]
            )
            let folderKey = wallet.folder.flatMap { folderKeyByID[$0.persistentModelID] }
            walletRecords.append(
                WalletRecord(
                    key: key,
                    name: wallet.name,
                    assetCode: wallet.assetCode,
                    kindRaw: wallet.kind.rawValue,
                    balance: wallet.balance,
                    colorHex: wallet.colorHex,
                    createdAt: wallet.createdAt,
                    updatedAt: wallet.updatedAt,
                    folderKey: folderKey
                )
            )
            walletKeyByID[wallet.persistentModelID] = key
        }

        let assetRecords: [AssetRecord] = assets
            .sorted(by: assetSort)
            .map { asset in
                AssetRecord(symbol: asset.symbol, name: asset.name, kindRaw: asset.kind.rawValue)
            }

        let transactionRecords: [TransactionRecord] = transactions
            .sorted(by: transactionSort)
            .map { transaction in
                TransactionRecord(
                    amount: transaction.amount,
                    currencyCode: transaction.currencyCode,
                    date: transaction.date,
                    note: transaction.note,
                    typeRaw: transaction.type?.rawValue,
                    walletNameSnapshot: transaction.walletNameSnapshot,
                    walletKindRaw: transaction.walletKindRaw,
                    walletColorHexSnapshot: transaction.walletColorHexSnapshot,
                    transferWalletNameSnapshot: transaction.transferWalletNameSnapshot,
                    transferWalletCurrencyCode: transaction.transferWalletCurrencyCode,
                    transferWalletKindRaw: transaction.transferWalletKindRaw,
                    transferWalletColorHexSnapshot: transaction.transferWalletColorHexSnapshot,
                    transferAmount: transaction.transferAmount,
                    photoData: transaction.photoData,
                    categoryKey: transaction.category.flatMap { categoryKeyByID[$0.persistentModelID] },
                    walletKey: transaction.wallet.flatMap { walletKeyByID[$0.persistentModelID] },
                    transferWalletKey: transaction.transferWallet.flatMap { walletKeyByID[$0.persistentModelID] }
                )
            }

        let recurringRuleRecords: [RecurringRuleRecord] = recurringRules
            .sorted(by: recurringRuleSort)
            .map { rule in
                RecurringRuleRecord(
                    title: rule.title,
                    amount: rule.amount,
                    currencyCode: rule.currencyCode,
                    typeRaw: rule.type.rawValue,
                    frequencyRaw: rule.frequency.rawValue,
                    interval: rule.interval,
                    nextRunDate: rule.nextRunDate,
                    note: rule.note,
                    isActive: rule.isActive,
                    createdAt: rule.createdAt,
                    updatedAt: rule.updatedAt,
                    categoryKey: rule.category.flatMap { categoryKeyByID[$0.persistentModelID] },
                    walletKey: rule.wallet.flatMap { walletKeyByID[$0.persistentModelID] }
                )
            }

        let budgetRecords: [BudgetRecord] = budgets
            .sorted(by: budgetSort)
            .map { budget in
                BudgetRecord(
                    amount: budget.amount,
                    currencyCode: budget.currencyCode,
                    periodRaw: budget.period.rawValue,
                    isActive: budget.isActive,
                    createdAt: budget.createdAt,
                    updatedAt: budget.updatedAt,
                    categoryKey: budget.category.flatMap { categoryKeyByID[$0.persistentModelID] }
                )
            }

        return BackupSnapshot(
            schemaVersion: schemaVersion,
            exportedAt: Date(),
            categories: categoryRecords,
            walletFolders: folderRecords,
            wallets: walletRecords,
            assets: assetRecords,
            transactions: transactionRecords,
            recurringRules: recurringRuleRecords,
            budgets: budgetRecords
        )
    }

    private static func apply(snapshot: BackupSnapshot, to context: ModelContext) throws {
        var categoryByKey: [String: Category] = [:]
        for record in snapshot.categories {
            let category = Category(
                name: record.name,
                type: CategoryType(rawValue: record.typeRaw) ?? .expense,
                colorHex: record.colorHex,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(category)
            categoryByKey[record.key] = category
        }

        var folderByKey: [String: WalletFolder] = [:]
        for record in snapshot.walletFolders {
            let folder = WalletFolder(name: record.name, createdAt: record.createdAt)
            context.insert(folder)
            folderByKey[record.key] = folder
        }

        for record in snapshot.assets {
            let asset = Asset(
                symbol: record.symbol,
                name: record.name,
                kind: AssetKind(rawValue: record.kindRaw) ?? .fiat
            )
            context.insert(asset)
        }

        var walletByKey: [String: Wallet] = [:]
        for record in snapshot.wallets {
            let wallet = Wallet(
                name: record.name,
                assetCode: record.assetCode,
                kind: AssetKind(rawValue: record.kindRaw) ?? .fiat,
                balance: record.balance,
                colorHex: record.colorHex,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            if let folderKey = record.folderKey {
                wallet.folder = folderByKey[folderKey]
            }
            context.insert(wallet)
            walletByKey[record.key] = wallet
        }

        for record in snapshot.transactions {
            let resolvedType = TransactionType(rawValue: record.typeRaw ?? "") ?? .expense
            let transaction = Transaction(
                amount: record.amount,
                currencyCode: record.currencyCode,
                date: record.date,
                note: record.note,
                type: resolvedType,
                walletNameSnapshot: record.walletNameSnapshot,
                walletKindRaw: record.walletKindRaw,
                walletColorHexSnapshot: record.walletColorHexSnapshot,
                transferWalletNameSnapshot: record.transferWalletNameSnapshot,
                transferWalletCurrencyCode: record.transferWalletCurrencyCode,
                transferWalletKindRaw: record.transferWalletKindRaw,
                transferWalletColorHexSnapshot: record.transferWalletColorHexSnapshot,
                transferAmount: record.transferAmount,
                photoData: record.photoData,
                category: record.categoryKey.flatMap { categoryByKey[$0] },
                wallet: record.walletKey.flatMap { walletByKey[$0] },
                transferWallet: record.transferWalletKey.flatMap { walletByKey[$0] }
            )
            if record.typeRaw == nil {
                transaction.type = nil
            }
            context.insert(transaction)
        }

        for record in snapshot.recurringRules {
            let recurringRule = RecurringTransactionRule(
                title: record.title,
                amount: record.amount,
                currencyCode: record.currencyCode,
                type: TransactionType(rawValue: record.typeRaw) ?? .expense,
                frequency: RecurrenceFrequency(rawValue: record.frequencyRaw) ?? .monthly,
                interval: max(1, record.interval),
                nextRunDate: record.nextRunDate,
                note: record.note,
                isActive: record.isActive,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                category: record.categoryKey.flatMap { categoryByKey[$0] },
                wallet: record.walletKey.flatMap { walletByKey[$0] }
            )
            context.insert(recurringRule)
        }

        for record in snapshot.budgets {
            let budget = CategoryBudget(
                amount: record.amount,
                currencyCode: record.currencyCode,
                period: BudgetPeriod(rawValue: record.periodRaw) ?? .monthly,
                isActive: record.isActive,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                category: record.categoryKey.flatMap { categoryByKey[$0] }
            )
            context.insert(budget)
        }
    }

    private static func hasCoreFinancialData(in context: ModelContext) -> Bool {
        guard let wallets = safeFetch(FetchDescriptor<Wallet>(), in: context) else { return true }
        if !wallets.isEmpty { return true }

        guard let transactions = safeFetch(FetchDescriptor<Transaction>(), in: context) else { return true }
        if !transactions.isEmpty { return true }

        guard let recurringRules = safeFetch(FetchDescriptor<RecurringTransactionRule>(), in: context) else { return true }
        if !recurringRules.isEmpty { return true }

        guard let budgets = safeFetch(FetchDescriptor<CategoryBudget>(), in: context) else { return true }
        if !budgets.isEmpty { return true }

        guard let folders = safeFetch(FetchDescriptor<WalletFolder>(), in: context) else { return true }
        if !folders.isEmpty { return true }

        return false
    }

    private static func safeFetch<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        in context: ModelContext
    ) -> [Model]? {
        do {
            return try context.fetch(descriptor)
        } catch {
            let description = String(describing: error)
            let defaults = UserDefaults.standard
            defaults.set(description, forKey: storageCloudKitErrorKey)
            defaults.set("model_issue", forKey: storageCloudKitReasonKey)
            defaults.set(description, forKey: lastErrorDefaultsKey)
            return nil
        }
    }

    private static func clearAllData(in context: ModelContext) throws {
        try context.fetch(FetchDescriptor<Transaction>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<RecurringTransactionRule>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CategoryBudget>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<Wallet>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<WalletFolder>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<Category>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<Asset>()).forEach(context.delete)
    }

    private static func makeEntityKey(kind: String, index: Int, parts: [String]) -> String {
        hashHex(string: "\(kind)|\(index)|\(parts.joined(separator: "|"))")
    }

    private static func dateFromDefaults(_ defaults: UserDefaults, key: String) -> Date? {
        let timestamp = defaults.double(forKey: key)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func hashHex(string: String) -> String {
        hashHex(data: Data(string.utf8))
    }

    private static func hashHex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func categorySort(_ lhs: Category, _ rhs: Category) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.type.rawValue < rhs.type.rawValue
    }

    private static func folderSort(_ lhs: WalletFolder, _ rhs: WalletFolder) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.name < rhs.name
    }

    private static func walletSort(_ lhs: Wallet, _ rhs: Wallet) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.assetCode < rhs.assetCode
    }

    private static func assetSort(_ lhs: Asset, _ rhs: Asset) -> Bool {
        if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private static func transactionSort(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.currencyCode != rhs.currencyCode { return lhs.currencyCode < rhs.currencyCode }
        return lhs.amount < rhs.amount
    }

    private static func recurringRuleSort(_ lhs: RecurringTransactionRule, _ rhs: RecurringTransactionRule) -> Bool {
        if lhs.nextRunDate != rhs.nextRunDate { return lhs.nextRunDate < rhs.nextRunDate }
        return lhs.title < rhs.title
    }

    private static func budgetSort(_ lhs: CategoryBudget, _ rhs: CategoryBudget) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.currencyCode != rhs.currencyCode { return lhs.currencyCode < rhs.currencyCode }
        return lhs.amount < rhs.amount
    }
}

private struct BackupSnapshot: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let categories: [CategoryRecord]
    let walletFolders: [WalletFolderRecord]
    let wallets: [WalletRecord]
    let assets: [AssetRecord]
    let transactions: [TransactionRecord]
    let recurringRules: [RecurringRuleRecord]
    let budgets: [BudgetRecord]
}

private struct CategoryRecord: Codable {
    let key: String
    let name: String
    let typeRaw: String
    let colorHex: String
    let createdAt: Date
    let updatedAt: Date
}

private struct WalletFolderRecord: Codable {
    let key: String
    let name: String
    let createdAt: Date
}

private struct WalletRecord: Codable {
    let key: String
    let name: String
    let assetCode: String
    let kindRaw: String
    let balance: Decimal
    let colorHex: String?
    let createdAt: Date
    let updatedAt: Date
    let folderKey: String?
}

private struct AssetRecord: Codable {
    let symbol: String
    let name: String
    let kindRaw: String
}

private struct TransactionRecord: Codable {
    let amount: Decimal
    let currencyCode: String
    let date: Date
    let note: String?
    let typeRaw: String?
    let walletNameSnapshot: String?
    let walletKindRaw: String?
    let walletColorHexSnapshot: String?
    let transferWalletNameSnapshot: String?
    let transferWalletCurrencyCode: String?
    let transferWalletKindRaw: String?
    let transferWalletColorHexSnapshot: String?
    let transferAmount: Decimal?
    let photoData: Data?
    let categoryKey: String?
    let walletKey: String?
    let transferWalletKey: String?
}

private struct RecurringRuleRecord: Codable {
    let title: String
    let amount: Decimal
    let currencyCode: String
    let typeRaw: String
    let frequencyRaw: String
    let interval: Int
    let nextRunDate: Date
    let note: String?
    let isActive: Bool
    let createdAt: Date
    let updatedAt: Date
    let categoryKey: String?
    let walletKey: String?
}

private struct BudgetRecord: Codable {
    let amount: Decimal
    let currencyCode: String
    let periodRaw: String
    let isActive: Bool
    let createdAt: Date
    let updatedAt: Date
    let categoryKey: String?
}
