    //
//  Item.swift
//  ArgentumVault
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import Foundation
import SwiftData

enum CategoryType: String, Codable, CaseIterable {
    case expense
    case income
}

enum AssetKind: String, Codable, CaseIterable {
    case fiat
    case crypto
    case metal
    case stock
}

enum TransactionType: String, Codable, CaseIterable {
    case expense
    case income
    case transfer
}

enum RecurrenceFrequency: String, Codable, CaseIterable {
    case daily
    case weekly
    case monthly
}

enum BudgetPeriod: String, Codable, CaseIterable {
    case monthly
}

@Model
final class Category {
    var syncID: String = UUID().uuidString.lowercased()
    var name: String = ""
    var sourceLanguageCode: String?
    var localizedNamesJSON: String?
    var type: CategoryType = CategoryType.expense
    var colorHex: String = "FFFFFFFF"
    var deletedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction]?

    @Relationship(deleteRule: .nullify, inverse: \CategoryBudget.category)
    var budgets: [CategoryBudget]?

    @Relationship(deleteRule: .nullify, inverse: \RecurringTransactionRule.category)
    var recurringRules: [RecurringTransactionRule]?
    
    init(
        syncID: String = UUID().uuidString.lowercased(),
        name: String,
        sourceLanguageCode: String? = nil,
        localizedNamesJSON: String? = nil,
        type: CategoryType,
        colorHex: String,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.syncID = syncID
        self.name = name
        self.sourceLanguageCode = sourceLanguageCode
        self.localizedNamesJSON = localizedNamesJSON
        self.type = type
        self.colorHex = colorHex
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Transaction {
    var syncID: String = UUID().uuidString.lowercased()
    var amount: Decimal = 0
    var currencyCode: String = "USD"
    var date: Date = Date()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?
    var note: String?
    var type: TransactionType?
    var walletNameSnapshot: String?
    var walletKindRaw: String?
    var walletColorHexSnapshot: String?
    var transferWalletNameSnapshot: String?
    var transferWalletCurrencyCode: String?
    var transferWalletKindRaw: String?
    var transferWalletColorHexSnapshot: String?
    var transferAmount: Decimal?
    
    @Attribute(.externalStorage)
    var photoData: Data?
    
    var category: Category?
    
    var wallet: Wallet?
    
    var transferWallet: Wallet?
    
    init(
        syncID: String = UUID().uuidString.lowercased(),
        amount: Decimal,
        currencyCode: String,
        date: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        note: String? = nil,
        type: TransactionType = TransactionType.expense,
        walletNameSnapshot: String? = nil,
        walletKindRaw: String? = nil,
        walletColorHexSnapshot: String? = nil,
        transferWalletNameSnapshot: String? = nil,
        transferWalletCurrencyCode: String? = nil,
        transferWalletKindRaw: String? = nil,
        transferWalletColorHexSnapshot: String? = nil,
        transferAmount: Decimal? = nil,
        photoData: Data? = nil,
        category: Category? = nil,
        wallet: Wallet? = nil,
        transferWallet: Wallet? = nil
    ) {
        self.syncID = syncID
        self.amount = amount
        self.currencyCode = currencyCode
        self.date = date
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.note = note
        self.type = type
        self.walletNameSnapshot = walletNameSnapshot
        self.walletKindRaw = walletKindRaw
        self.walletColorHexSnapshot = walletColorHexSnapshot
        self.transferWalletNameSnapshot = transferWalletNameSnapshot
        self.transferWalletCurrencyCode = transferWalletCurrencyCode
        self.transferWalletKindRaw = transferWalletKindRaw
        self.transferWalletColorHexSnapshot = transferWalletColorHexSnapshot
        self.transferAmount = transferAmount
        self.photoData = photoData
        self.category = category
        self.wallet = wallet
        self.transferWallet = transferWallet
    }
}

@Model
final class Asset {
    var syncID: String = UUID().uuidString.lowercased()
    var symbol: String = ""
    var name: String = ""
    var kind: AssetKind = AssetKind.fiat
    var deletedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    
    init(
        syncID: String = UUID().uuidString.lowercased(),
        symbol: String,
        name: String,
        kind: AssetKind,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.syncID = syncID
        self.symbol = symbol
        self.name = name
        self.kind = kind
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Wallet {
    var syncID: String = UUID().uuidString.lowercased()
    var name: String = ""
    var assetCode: String = "USD"
    var kind: AssetKind = AssetKind.fiat
    var balance: Decimal = 0
    var colorHex: String?
    var deletedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    
    var folder: WalletFolder?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.wallet)
    var transactions: [Transaction]?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.transferWallet)
    var transferTransactions: [Transaction]?

    @Relationship(deleteRule: .nullify, inverse: \RecurringTransactionRule.wallet)
    var recurringRules: [RecurringTransactionRule]?
    
    init(
        syncID: String = UUID().uuidString.lowercased(),
        name: String,
        assetCode: String,
        kind: AssetKind,
        balance: Decimal,
        colorHex: String? = "FFFFFFFF",
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.syncID = syncID
        self.name = name
        self.assetCode = assetCode
        self.kind = kind
        self.balance = balance
        self.colorHex = colorHex
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class WalletFolder {
    var syncID: String = UUID().uuidString.lowercased()
    var name: String = ""
    var deletedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Wallet.folder)
    var wallets: [Wallet]?
    
    init(
        syncID: String = UUID().uuidString.lowercased(),
        name: String,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.syncID = syncID
        self.name = name
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class RecurringTransactionRule {
    var syncID: String = UUID().uuidString.lowercased()
    var title: String = ""
    var amount: Decimal = 0
    var currencyCode: String = "USD"
    var type: TransactionType = TransactionType.expense
    var frequency: RecurrenceFrequency = RecurrenceFrequency.monthly
    var interval: Int = 1
    var nextRunDate: Date = Date()
    var note: String?
    var isActive: Bool = true
    var deletedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var category: Category?

    var wallet: Wallet?

    init(
        syncID: String = UUID().uuidString.lowercased(),
        title: String,
        amount: Decimal,
        currencyCode: String,
        type: TransactionType,
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        nextRunDate: Date = Date(),
        note: String? = nil,
        isActive: Bool = true,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        category: Category? = nil,
        wallet: Wallet? = nil
    ) {
        self.syncID = syncID
        self.title = title
        self.amount = amount
        self.currencyCode = currencyCode
        self.type = type
        self.frequency = frequency
        self.interval = max(1, interval)
        self.nextRunDate = nextRunDate
        self.note = note
        self.isActive = isActive
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
        self.wallet = wallet
    }
}

@Model
final class CategoryBudget {
    var syncID: String = UUID().uuidString.lowercased()
    var amount: Decimal = 0
    var currencyCode: String = "USD"
    var period: BudgetPeriod = BudgetPeriod.monthly
    var isActive: Bool = true
    var deletedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify)
    var category: Category?

    init(
        syncID: String = UUID().uuidString.lowercased(),
        amount: Decimal,
        currencyCode: String,
        period: BudgetPeriod = .monthly,
        isActive: Bool = true,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        category: Category? = nil
    ) {
        self.syncID = syncID
        self.amount = amount
        self.currencyCode = currencyCode
        self.period = period
        self.isActive = isActive
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
    }
}
