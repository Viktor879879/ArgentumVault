import Foundation
import SwiftData
import CryptoKit
import Supabase
import PostgREST

@MainActor
enum ICloudBackupManager {
    private struct PendingCloudUpload {
        let payload: Data
        let payloadHash: String
        let force: Bool
    }

    private struct PendingBackupRetry {
        let accountIdentifier: String
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

    // Lightweight periodic sync pass. Primary upload trigger is still save-driven backup.
    static let periodicIntervalNanoseconds: UInt64 = 10_000_000_000 // 10 seconds

    private static let schemaVersion = 1
    private static let appSupportBackupFolder = "ArgentumVaultBackups"
    private static let supabaseSnapshotsTable = "av_backup_snapshots"
    private static let supabaseOwnerUserIDField = "owner_user_id"
    private static let supabaseAccountBucketField = "account_bucket"
    private static let supabasePayloadBase64Field = "payload_base64"
    private static let supabasePayloadHashField = "payload_hash"
    private static let supabaseSchemaVersionField = "schema_version"
    private static let supabaseUpdatedAtField = "updated_at"
    private static let backupFileName = "snapshot.json"
    private static let lastHashDefaultsPrefix = "backup.icloud.last_hash."
    private static let lastCloudHashDefaultsPrefix = "backup.icloud.cloudkit.last_hash."
    private static let lastAttemptDefaultsPrefix = "backup.icloud.last_attempt."
    private static let lastSuccessDefaultsPrefix = "backup.icloud.last_success."
    private static let lastErrorDefaultsKey = "backup.icloud.last_error"
    private static let lastCloudSuccessDefaultsPrefix = "backup.icloud.cloudkit.last_success."
    private static let lastCloudErrorDefaultsPrefix = "backup.icloud.cloudkit.last_error."
    private static let localDirtyDefaultsPrefix = "backup.icloud.local_dirty."
    private static let storageCloudKitErrorKey = "storage.cloudkit.last_error"
    private static let storageCloudKitReasonKey = "storage.cloudkit.last_reason_code"
    private static let storageModeActiveKey = "storage.mode.active"
    private static let storageModeRequestedKey = "storage.mode.requested_cloud"
    private static let emailUserEmailKey = "emailUserEmail"
    private static let emailUserIDKey = "emailUserID"
    private static let minimumAttemptInterval: TimeInterval = 5
    private static var cloudUploadTasks: [String: Task<Void, Never>] = [:]
    private static var pendingCloudUploads: [String: PendingCloudUpload] = [:]
    private static var backupRetryTasks: [String: Task<Void, Never>] = [:]
    private static var pendingBackupRetries: [String: PendingBackupRetry] = [:]
    private static var ignoredSaveEventsByBucket: [String: Int] = [:]
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private struct SupabaseSnapshotUpsertRow: Encodable {
        let owner_user_id: String
        let account_bucket: String
        let payload_base64: String
        let payload_hash: String
        let schema_version: Int
        let updated_at: String
    }

    private struct SupabaseSnapshotSelectRow: Decodable {
        let owner_user_id: String?
        let account_bucket: String
        let payload_base64: String
        let payload_hash: String?
        let schema_version: Int?
        let updated_at: String?
    }

    private struct SupabaseSnapshotUpdateRow: Encodable {
        let payload_base64: String
        let payload_hash: String
        let schema_version: Int
        let updated_at: String
    }

    private struct RemoteSnapshotPayload {
        let payload: Data
        let payloadHash: String?
        let updatedAt: Date?
    }

    private enum BackupSyncRouteError: LocalizedError {
        case emailAccountRequired

        var errorDescription: String? {
            switch self {
            case .emailAccountRequired:
                return "Cloud sync requires email authentication."
            }
        }
    }

    static func backupIfNeeded(modelContext: ModelContext, accountIdentifier: String, force: Bool = false) {
        let backupURL = backupFileURL(for: accountIdentifier)
        let bucket = accountBucket(accountIdentifier)
        let now = Date().timeIntervalSince1970
        let lastAttemptKey = lastAttemptDefaultsPrefix + bucket
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.double(forKey: lastAttemptKey)
        if !force, lastAttempt > 0, (now - lastAttempt) < minimumAttemptInterval {
            let remainingDelay = max(0.25, minimumAttemptInterval - (now - lastAttempt) + 0.25)
            scheduleBackupRetry(
                after: remainingDelay,
                modelContext: modelContext,
                bucket: bucket,
                request: PendingBackupRetry(
                    accountIdentifier: accountIdentifier,
                    force: force
                )
            )
            return
        }
        cancelScheduledBackupRetry(for: bucket)
        defaults.set(now, forKey: lastAttemptKey)

        let hasCoreData = hasCoreFinancialData(in: modelContext)

        // Protect cloud snapshot from accidental overwrite with an empty state
        // right after first launch / fresh install on a new device.
        // If the account is already dirty, allow empty snapshots so deletions sync too.
        if !force, !hasCoreData, !hasPendingLocalChanges(accountIdentifier: accountIdentifier) {
            return
        }

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
                defaults.set(false, forKey: localDirtyDefaultsPrefix + bucket)
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
            uploadSnapshotToRemote(
                payload: payload,
                payloadHash: payloadHash,
                bucket: bucket,
                accountIdentifier: accountIdentifier,
                force: force
            )
        } catch {
            let description = String(describing: error)
            defaults.set(description, forKey: lastErrorDefaultsKey)
            defaults.set(description, forKey: storageCloudKitErrorKey)
            defaults.set(reasonCode(for: error), forKey: storageCloudKitReasonKey)
        }
    }

    @discardableResult
    static func restoreIfNeeded(modelContext: ModelContext, accountIdentifier: String) async throws -> Bool {
        let bucket = accountBucket(accountIdentifier)
        let hasLocalCoreData = hasCoreFinancialData(in: modelContext)

        if let remoteSnapshot = try await fetchSnapshotPayloadFromRemote(
            bucket: bucket,
            accountIdentifier: accountIdentifier
        ) {
            if shouldSkipRemoteRestore(
                remoteSnapshot: remoteSnapshot,
                modelContext: modelContext,
                bucket: bucket,
                hasLocalCoreData: hasLocalCoreData
            ) {
                return false
            }

            let payload = remoteSnapshot.payload
            if let backupURL = backupFileURL(for: accountIdentifier) {
                try? FileManager.default.createDirectory(
                    at: backupURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? payload.write(to: backupURL, options: .atomic)
            }

            let didRestore = try restorePayload(payload, modelContext: modelContext, bucket: bucket)
            if didRestore {
                UserDefaults.standard.removeObject(forKey: lastCloudErrorDefaultsPrefix + bucket)
            }
            return didRestore
        }

        guard !hasLocalCoreData else {
            return false
        }
        guard let backupURL = backupFileURL(for: accountIdentifier),
              FileManager.default.fileExists(atPath: backupURL.path) else {
            return false
        }
        let localPayload = try Data(contentsOf: backupURL)
        return try restorePayload(localPayload, modelContext: modelContext, bucket: bucket)
    }

    static func shouldForceBackupAfterRestoreAttempt(
        modelContext: ModelContext,
        didRestore: Bool
    ) -> Bool {
        if didRestore {
            return false
        }
        return hasCoreFinancialData(in: modelContext)
    }

    static func noteLocalMutation(accountIdentifier: String) {
        let bucket = accountBucket(accountIdentifier)
        UserDefaults.standard.set(true, forKey: localDirtyDefaultsPrefix + bucket)
    }

    static func hasPendingLocalChanges(accountIdentifier: String) -> Bool {
        let bucket = accountBucket(accountIdentifier)
        return UserDefaults.standard.bool(forKey: localDirtyDefaultsPrefix + bucket)
    }

    static func consumeIgnoredSaveEventIfNeeded(accountIdentifier: String) -> Bool {
        let bucket = accountBucket(accountIdentifier)
        guard let count = ignoredSaveEventsByBucket[bucket], count > 0 else {
            return false
        }
        if count == 1 {
            ignoredSaveEventsByBucket.removeValue(forKey: bucket)
        } else {
            ignoredSaveEventsByBucket[bucket] = count - 1
        }
        return true
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
            ignoredSaveEventsByBucket[bucket, default: 0] += 1
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
        UserDefaults.standard.set(false, forKey: localDirtyDefaultsPrefix + bucket)
        UserDefaults.standard.removeObject(forKey: lastErrorDefaultsKey)
        return true
    }

    private static func backupFileURL(for accountIdentifier: String) -> URL? {
        guard let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bucket = accountBucket(accountIdentifier)
        return appSupportURL
            .appendingPathComponent(appSupportBackupFolder, isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent(backupFileName, isDirectory: false)
    }

    private static func accountBucket(_ accountIdentifier: String) -> String {
        hashHex(string: accountIdentifier).prefix(24).lowercased()
    }

    private static func uploadSnapshotToRemote(
        payload: Data,
        payloadHash: String,
        bucket: String,
        accountIdentifier: String,
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
        let storageModeRequestedDefaultsKey = storageModeRequestedKey
        let storageModeActiveDefaultsKey = storageModeActiveKey

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
                        uploadSnapshotToRemote(
                            payload: pending.payload,
                            payloadHash: pending.payloadHash,
                            bucket: bucket,
                            accountIdentifier: accountIdentifier,
                            force: pending.force
                        )
                    }
                }
            }
            guard !Task.isCancelled else { return }
            do {
                try await saveSnapshotPayloadToRemote(
                    payload: payload,
                    payloadHash: payloadHash,
                    bucket: bucket,
                    accountIdentifier: accountIdentifier
                )
                guard !Task.isCancelled else { return }
                let defaults = UserDefaults.standard
                defaults.set(payloadHash, forKey: lastCloudHashKey)
                defaults.set(Date().timeIntervalSince1970, forKey: cloudSuccessKey)
                defaults.set(false, forKey: localDirtyDefaultsPrefix + bucket)
                defaults.removeObject(forKey: cloudErrorKey)
                defaults.removeObject(forKey: storageErrorKey)
                defaults.removeObject(forKey: storageReasonKey)
                defaults.set(true, forKey: storageModeRequestedDefaultsKey)
                defaults.set("cloud", forKey: storageModeActiveDefaultsKey)
            } catch {
                let description = String(describing: error)
                let defaults = UserDefaults.standard
                defaults.set(description, forKey: cloudErrorKey)
                defaults.set(description, forKey: storageErrorKey)
                defaults.set(reasonCode(for: error), forKey: storageReasonKey)
                defaults.set(true, forKey: storageModeRequestedDefaultsKey)
                defaults.set("local", forKey: storageModeActiveDefaultsKey)
            }
        }
    }

    private static func scheduleBackupRetry(
        after delay: TimeInterval,
        modelContext: ModelContext,
        bucket: String,
        request: PendingBackupRetry
    ) {
        pendingBackupRetries[bucket] = request
        backupRetryTasks[bucket]?.cancel()
        backupRetryTasks[bucket] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let pendingRequest = pendingBackupRetries.removeValue(forKey: bucket) ?? request
            backupRetryTasks[bucket] = nil
            backupIfNeeded(
                modelContext: modelContext,
                accountIdentifier: pendingRequest.accountIdentifier,
                force: pendingRequest.force
            )
        }
    }

    private static func cancelScheduledBackupRetry(for bucket: String) {
        backupRetryTasks[bucket]?.cancel()
        backupRetryTasks[bucket] = nil
        pendingBackupRetries.removeValue(forKey: bucket)
    }

    private static func saveSnapshotPayloadToRemote(
        payload: Data,
        payloadHash: String,
        bucket: String,
        accountIdentifier: String
    ) async throws {
        guard shouldUseSupabaseSync(for: accountIdentifier) else {
            throw BackupSyncRouteError.emailAccountRequired
        }

        try await saveSnapshotPayloadToSupabase(
            payload: payload,
            payloadHash: payloadHash,
            bucket: bucket
        )
    }

    private static func saveSnapshotPayloadToSupabase(
        payload: Data,
        payloadHash: String,
        bucket: String
    ) async throws {
        let client = try EmailAuthManager.syncClient()
        let ownerUserID = try await EmailAuthManager.currentSessionUserID()
        let updatedAt = iso8601Formatter.string(from: Date())
        let row = SupabaseSnapshotUpsertRow(
            owner_user_id: ownerUserID,
            account_bucket: bucket,
            payload_base64: payload.base64EncodedString(),
            payload_hash: payloadHash,
            schema_version: schemaVersion,
            updated_at: updatedAt
        )
        let updateRow = SupabaseSnapshotUpdateRow(
            payload_base64: row.payload_base64,
            payload_hash: row.payload_hash,
            schema_version: row.schema_version,
            updated_at: row.updated_at
        )

        do {
            _ = try await client
                .from(supabaseSnapshotsTable)
                .upsert(
                    row,
                    onConflict: "\(supabaseOwnerUserIDField),\(supabaseAccountBucketField)",
                    returning: .minimal
                )
                .execute()
            return
        } catch let postgrestError as PostgrestError {
            guard shouldFallbackFromUpsert(error: postgrestError) else {
                throw postgrestError
            }
        }

        let existing: PostgrestResponse<[SupabaseSnapshotSelectRow]> = try await client
            .from(supabaseSnapshotsTable)
            .select("\(supabaseOwnerUserIDField),\(supabaseAccountBucketField)")
            .eq(supabaseOwnerUserIDField, value: ownerUserID)
            .eq(supabaseAccountBucketField, value: bucket)
            .limit(1)
            .execute()

        if existing.value.isEmpty {
            _ = try await client
                .from(supabaseSnapshotsTable)
                .insert(row, returning: .minimal)
                .execute()
        } else {
            _ = try await client
                .from(supabaseSnapshotsTable)
                .update(updateRow, returning: .minimal)
                .eq(supabaseOwnerUserIDField, value: ownerUserID)
                .eq(supabaseAccountBucketField, value: bucket)
                .execute()
        }
    }

    private static func fetchSnapshotPayloadFromRemote(
        bucket: String,
        accountIdentifier: String
    ) async throws -> RemoteSnapshotPayload? {
        guard shouldUseSupabaseSync(for: accountIdentifier) else {
            return nil
        }

        if let primarySnapshot = try await fetchSnapshotPayloadFromSupabase(bucket: bucket) {
            return primarySnapshot
        }

        for legacyBucket in legacySupabaseBuckets(
            for: accountIdentifier,
            excluding: bucket
        ) {
            if let legacySnapshot = try await fetchSnapshotPayloadFromSupabase(bucket: legacyBucket) {
                return legacySnapshot
            }
        }

        return nil
    }

    private static func fetchSnapshotPayloadFromSupabase(bucket: String) async throws -> RemoteSnapshotPayload? {
        let client = try EmailAuthManager.syncClient()
        let ownerUserID = try await EmailAuthManager.currentSessionUserID()
        let response: PostgrestResponse<[SupabaseSnapshotSelectRow]> = try await client
            .from(supabaseSnapshotsTable)
            .select(
                "\(supabaseOwnerUserIDField),\(supabaseAccountBucketField),\(supabasePayloadBase64Field),\(supabasePayloadHashField),\(supabaseSchemaVersionField),\(supabaseUpdatedAtField)"
            )
            .eq(supabaseOwnerUserIDField, value: ownerUserID)
            .eq(supabaseAccountBucketField, value: bucket)
            .limit(1)
            .execute()

        let rows = response.value
        guard let row = rows.first else {
            return nil
        }

        guard let payload = Data(base64Encoded: row.payload_base64) else {
            throw NSError(
                domain: "ArgentumVault.SupabaseBackup",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid backup payload encoding in Supabase."]
            )
        }

        return RemoteSnapshotPayload(
            payload: payload,
            payloadHash: row.payload_hash,
            updatedAt: parseServerDate(row.updated_at)
        )
    }

    private static func shouldUseSupabaseSync(for accountIdentifier: String) -> Bool {
        accountIdentifier.hasPrefix("email:") || accountIdentifier.hasPrefix("email_uid:")
    }

    private static func legacySupabaseBuckets(
        for accountIdentifier: String,
        excluding primaryBucket: String
    ) -> [String] {
        let defaults = UserDefaults.standard
        let normalizedEmail = defaults.string(forKey: emailUserEmailKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedUserID = defaults.string(forKey: emailUserIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        var buckets: [String] = []
        if accountIdentifier.hasPrefix("email_uid:"), !normalizedEmail.isEmpty {
            buckets.append(accountBucket("email:\(normalizedEmail)"))
        }
        if accountIdentifier.hasPrefix("email:"), !normalizedUserID.isEmpty {
            buckets.append(accountBucket("email_uid:\(normalizedUserID)"))
        }

        var seen: Set<String> = [primaryBucket]
        return buckets.filter { bucket in
            guard !seen.contains(bucket) else { return false }
            seen.insert(bucket)
            return true
        }
    }

    private static func shouldFallbackFromUpsert(error: PostgrestError) -> Bool {
        let code = error.code?.lowercased() ?? ""
        let message = error.message.lowercased()
        let detail = error.detail?.lowercased() ?? ""
        let combined = "\(code) \(message) \(detail)"
        return combined.contains("42p10")
            || combined.contains("on conflict")
            || combined.contains("no unique")
            || combined.contains("exclusion constraint")
    }

    private static func shouldSkipRemoteRestore(
        remoteSnapshot: RemoteSnapshotPayload,
        modelContext: ModelContext,
        bucket: String,
        hasLocalCoreData: Bool
    ) -> Bool {
        guard hasLocalCoreData else { return false }

        if UserDefaults.standard.bool(forKey: localDirtyDefaultsPrefix + bucket) {
            return true
        }

        if let localPayload = try? encodeSnapshotPayload(from: modelContext),
           let remoteHash = remoteSnapshot.payloadHash {
            let localHash = hashHex(data: localPayload)
            if localHash == remoteHash {
                return true
            }
        }

        let defaults = UserDefaults.standard
        let lastCloudSuccess = dateFromDefaults(defaults, key: lastCloudSuccessDefaultsPrefix + bucket)
        let lastCloudHash = defaults.string(forKey: lastCloudHashDefaultsPrefix + bucket)

        guard let lastCloudSuccess else {
            // Device has local data but has never synced this account: prefer remote snapshot.
            return false
        }

        if let remoteUpdatedAt = remoteSnapshot.updatedAt,
           remoteUpdatedAt.timeIntervalSince1970 > (lastCloudSuccess.timeIntervalSince1970 + 1) {
            return false
        }

        if let remoteHash = remoteSnapshot.payloadHash,
           remoteHash != lastCloudHash {
            return false
        }

        return true
    }

    private static func encodeSnapshotPayload(from context: ModelContext) throws -> Data {
        let snapshot = try makeSnapshot(from: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    private static func parseServerDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let withFractional = iso8601Formatter.date(from: raw) {
            return withFractional
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    nonisolated private static func reasonCode(for error: Error) -> String {
        if let routeError = error as? BackupSyncRouteError {
            switch routeError {
            case .emailAccountRequired:
                return "email_account_required"
            }
        }

        if let postgrestError = error as? PostgrestError {
            let pgCode = postgrestError.code?.lowercased() ?? ""
            let pgMessage = postgrestError.message.lowercased()
            let pgDetail = postgrestError.detail?.lowercased() ?? ""
            let combined = "\(pgCode) \(pgMessage) \(pgDetail)"

            if (combined.contains("relation") && combined.contains("does not exist"))
                || combined.contains("schema cache")
                || combined.contains("could not find the table")
            {
                return "supabase_schema"
            }
            if combined.contains("jwt")
                || combined.contains("auth")
                || combined.contains("permission denied")
                || combined.contains("row-level security")
            {
                return "restricted"
            }
            if combined.contains("network")
                || combined.contains("timeout")
                || combined.contains("temporarily unavailable")
            {
                return "network"
            }
            return "model_issue"
        }
        let message = String(describing: error).lowercased()
        if message.contains("email authentication") {
            return "email_account_required"
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
