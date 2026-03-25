import Foundation
import SwiftData

enum AccountScopedDataPurger {
    private static let localStoreNamePrefix = "ArgentumVaultLocalStore"
    private static let cloudStoreNamePrefix = "ArgentumVaultCloudStore"
    private static let schema = Schema([
        Category.self,
        Transaction.self,
        Asset.self,
        Wallet.self,
        WalletFolder.self,
        RecurringTransactionRule.self,
        CategoryBudget.self,
    ])

    static func purgeArtifacts(for accountIdentifier: String) {
        let normalized = accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        purgeStoreArtifacts(prefix: localStoreNamePrefix, accountIdentifier: normalized)
        purgeStoreArtifacts(prefix: cloudStoreNamePrefix, accountIdentifier: normalized)
        ICloudBackupManager.deleteBackupArtifacts(for: normalized)
    }

    private static func purgeStoreArtifacts(prefix: String, accountIdentifier: String) {
        let storeName = "\(prefix)-\(AccountBucketHasher.bucket(for: accountIdentifier))"
        let configuration = ModelConfiguration(
            storeName,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        let fileManager = FileManager.default
        let primaryURL = configuration.url
        let walURL = URL(fileURLWithPath: primaryURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: primaryURL.path + "-shm")

        for candidate in [primaryURL, walURL, shmURL] where fileManager.fileExists(atPath: candidate.path) {
            try? fileManager.removeItem(at: candidate)
        }
    }
}
