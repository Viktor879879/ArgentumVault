import Foundation
import SwiftData

struct TransactionEffectSnapshot {
    let walletID: PersistentIdentifier?
    let transferWalletID: PersistentIdentifier?
    let amount: Decimal
    let transferAmount: Decimal
    let type: TransactionType
}

struct TransactionSaveRequest {
    let transaction: Transaction?
    let originalState: TransactionEffectSnapshot?
    let amount: Decimal
    let currencyCode: String
    let date: Date
    let note: String
    let transactionType: TransactionType
    let category: Category?
    let wallet: Wallet?
    let transferWallet: Wallet?
    let transferAmount: Decimal?
    let photoData: Data?
    let defaultCurrencyCode: String
}

enum TransactionMutationService {
    @MainActor
    static func save(
        request: TransactionSaveRequest,
        modelContext: ModelContext,
        availableWallets: [Wallet]
    ) throws -> Transaction {
        let walletNameSnapshot = request.wallet?.name
        let walletKindRaw = request.wallet?.kind.rawValue
        let walletColorHexSnapshot = request.wallet?.colorHex
        let transferWalletNameSnapshot = request.transferWallet?.name
        let transferWalletCurrencyCode = request.transferWallet?.assetCode
        let transferWalletKindRaw = request.transferWallet?.kind.rawValue
        let transferWalletColorHexSnapshot = request.transferWallet?.colorHex
        let safeDate = SecurityValidation.sanitizeDate(request.date)
        let safeNote = SecurityValidation.sanitizeNote(request.note)
        let safePhotoData = SecurityValidation.sanitizePhotoData(request.photoData)
        let safeCurrencyCode =
            SecurityValidation.sanitizeAssetCode(request.currencyCode)
            ?? request.wallet.flatMap { SecurityValidation.sanitizeAssetCode($0.assetCode) }
            ?? SecurityValidation.sanitizeAssetCode(request.defaultCurrencyCode)
            ?? "USD"
        let safeWalletNameSnapshot = SecurityValidation.sanitizeOptionalSnapshotLabel(walletNameSnapshot)
        let safeTransferWalletNameSnapshot = SecurityValidation.sanitizeOptionalSnapshotLabel(transferWalletNameSnapshot)
        let safeTransferWalletCurrencyCode = transferWalletCurrencyCode.flatMap(SecurityValidation.sanitizeAssetCode)
        let now = Date()

        applyWalletChanges(
            originalState: request.originalState,
            availableWallets: availableWallets,
            newWallet: request.wallet,
            newTransferWallet: request.transferWallet,
            newAmount: request.amount,
            newTransferAmount: request.transferAmount,
            newType: request.transactionType,
            now: now
        )

        let savedTransaction: Transaction
        if let transaction = request.transaction {
            transaction.amount = request.amount
            transaction.currencyCode = safeCurrencyCode
            transaction.date = safeDate
            transaction.note = safeNote
            transaction.type = request.transactionType
            transaction.photoData = safePhotoData
            transaction.walletNameSnapshot = safeWalletNameSnapshot
            transaction.walletKindRaw = walletKindRaw
            transaction.walletColorHexSnapshot = walletColorHexSnapshot
            transaction.transferWalletNameSnapshot = safeTransferWalletNameSnapshot
            transaction.transferWalletCurrencyCode = safeTransferWalletCurrencyCode
            transaction.transferWalletKindRaw = transferWalletKindRaw
            transaction.transferWalletColorHexSnapshot = transferWalletColorHexSnapshot
            transaction.transferAmount = request.transferAmount
            transaction.category = request.category
            transaction.wallet = request.wallet
            transaction.transferWallet = request.transferWallet
            transaction.updatedAt = now
            savedTransaction = transaction
        } else {
            let newTransaction = Transaction(
                amount: request.amount,
                currencyCode: safeCurrencyCode,
                date: safeDate,
                note: safeNote,
                type: request.transactionType,
                walletNameSnapshot: safeWalletNameSnapshot,
                walletKindRaw: walletKindRaw,
                walletColorHexSnapshot: walletColorHexSnapshot,
                transferWalletNameSnapshot: safeTransferWalletNameSnapshot,
                transferWalletCurrencyCode: safeTransferWalletCurrencyCode,
                transferWalletKindRaw: transferWalletKindRaw,
                transferWalletColorHexSnapshot: transferWalletColorHexSnapshot,
                transferAmount: request.transferAmount,
                photoData: safePhotoData,
                category: request.category,
                wallet: request.wallet,
                transferWallet: request.transferWallet
            )
            newTransaction.updatedAt = now
            modelContext.insert(newTransaction)
            savedTransaction = newTransaction
        }

        request.wallet?.updatedAt = now
        request.transferWallet?.updatedAt = now
        try modelContext.save()
        MoneyInputTrace.log(
            """
            persisted_transaction syncID=\(savedTransaction.syncID) \
            amount=\(savedTransaction.amount) \
            currency=\(savedTransaction.currencyCode) \
            formatted=\(DecimalFormatter.string(from: savedTransaction.amount, maximumFractionDigits: 6))
            """
        )
        MoneyRuntimeDebug.recordPersist(
            syncID: savedTransaction.syncID,
            amount: savedTransaction.amount,
            currency: savedTransaction.currencyCode
        )
        return savedTransaction
    }

    @MainActor
    private static func applyWalletChanges(
        originalState: TransactionEffectSnapshot?,
        availableWallets: [Wallet],
        newWallet: Wallet?,
        newTransferWallet: Wallet?,
        newAmount: Decimal,
        newTransferAmount: Decimal?,
        newType: TransactionType,
        now: Date
    ) {
        if let originalState,
           let originalWalletID = originalState.walletID,
           let originalWallet = availableWallets.first(where: { $0.persistentModelID == originalWalletID }) {
            let originalTransferWallet = originalState.transferWalletID.flatMap { transferWalletID in
                availableWallets.first(where: { $0.persistentModelID == transferWalletID })
            }
            applyEffect(
                sourceWallet: originalWallet,
                destinationWallet: originalTransferWallet,
                amount: originalState.amount,
                destinationAmount: originalState.transferAmount,
                type: originalState.type,
                reversing: true,
                now: now
            )
        }

        if let newWallet {
            applyEffect(
                sourceWallet: newWallet,
                destinationWallet: newTransferWallet,
                amount: newAmount,
                destinationAmount: newTransferAmount ?? newAmount,
                type: newType,
                reversing: false,
                now: now
            )
        }
    }

    @MainActor
    private static func applyEffect(
        sourceWallet: Wallet?,
        destinationWallet: Wallet?,
        amount: Decimal,
        destinationAmount: Decimal,
        type: TransactionType,
        reversing: Bool,
        now: Date
    ) {
        switch type {
        case .expense:
            guard let sourceWallet else { return }
            sourceWallet.balance += reversing ? amount : -amount
            sourceWallet.updatedAt = now
        case .income:
            guard let sourceWallet else { return }
            sourceWallet.balance += reversing ? -amount : amount
            sourceWallet.updatedAt = now
        case .transfer:
            guard let sourceWallet, let destinationWallet else { return }
            sourceWallet.balance += reversing ? amount : -amount
            destinationWallet.balance += reversing ? -destinationAmount : destinationAmount
            sourceWallet.updatedAt = now
            destinationWallet.updatedAt = now
        }
    }
}
