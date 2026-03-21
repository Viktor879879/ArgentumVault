<<<<<<< HEAD
//
//  Item.swift
//  MoneyGram
=======
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
<<<<<<< HEAD
=======
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
<<<<<<< HEAD
    var name: String
    var type: CategoryType
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date
    
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []
=======
    var name: String = ""
    var type: CategoryType = CategoryType.expense
    var colorHex: String = "FFFFFFFF"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction]?

    @Relationship(deleteRule: .nullify, inverse: \CategoryBudget.category)
    var budgets: [CategoryBudget]?

    @Relationship(deleteRule: .nullify, inverse: \RecurringTransactionRule.category)
    var recurringRules: [RecurringTransactionRule]?
    
    init(
        name: String,
        type: CategoryType,
        colorHex: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.type = type
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Transaction {
<<<<<<< HEAD
    var amount: Decimal
    var currencyCode: String
    var date: Date
    var note: String?
    var type: TransactionType?
=======
    var amount: Decimal = 0
    var currencyCode: String = "USD"
    var date: Date = Date()
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
    
<<<<<<< HEAD
    @Relationship(deleteRule: .nullify)
    var category: Category?
    
    @Relationship(deleteRule: .nullify)
    var wallet: Wallet?
    
=======
    var category: Category?
    
    var wallet: Wallet?
    
    var transferWallet: Wallet?
    
    init(
        amount: Decimal,
        currencyCode: String,
        date: Date = Date(),
        note: String? = nil,
        type: TransactionType = TransactionType.expense,
<<<<<<< HEAD
        photoData: Data? = nil,
        category: Category? = nil,
        wallet: Wallet? = nil
=======
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
        self.amount = amount
        self.currencyCode = currencyCode
        self.date = date
        self.note = note
        self.type = type
<<<<<<< HEAD
        self.photoData = photoData
        self.category = category
        self.wallet = wallet
=======
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
<<<<<<< HEAD
    var symbol: String
    var name: String
    var kind: AssetKind
=======
    var symbol: String = ""
    var name: String = ""
    var kind: AssetKind = AssetKind.fiat
    
    init(symbol: String, name: String, kind: AssetKind) {
        self.symbol = symbol
        self.name = name
        self.kind = kind
    }
}

@Model
final class Wallet {
<<<<<<< HEAD
    var name: String
    var assetCode: String
    var kind: AssetKind
    var balance: Decimal
    var createdAt: Date
    var updatedAt: Date
=======
    var name: String = ""
    var assetCode: String = "USD"
    var kind: AssetKind = AssetKind.fiat
    var balance: Decimal = 0
    var colorHex: String?
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
        name: String,
        assetCode: String,
        kind: AssetKind,
        balance: Decimal,
<<<<<<< HEAD
=======
        colorHex: String? = "FFFFFFFF",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.assetCode = assetCode
        self.kind = kind
        self.balance = balance
<<<<<<< HEAD
=======
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
<<<<<<< HEAD
=======

@Model
final class WalletFolder {
    var name: String = ""
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Wallet.folder)
    var wallets: [Wallet]?
    
    init(name: String, createdAt: Date = Date()) {
        self.name = name
        self.createdAt = createdAt
    }
}

@Model
final class RecurringTransactionRule {
    var title: String = ""
    var amount: Decimal = 0
    var currencyCode: String = "USD"
    var type: TransactionType = TransactionType.expense
    var frequency: RecurrenceFrequency = RecurrenceFrequency.monthly
    var interval: Int = 1
    var nextRunDate: Date = Date()
    var note: String?
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var category: Category?

    var wallet: Wallet?

    init(
        title: String,
        amount: Decimal,
        currencyCode: String,
        type: TransactionType,
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        nextRunDate: Date = Date(),
        note: String? = nil,
        isActive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        category: Category? = nil,
        wallet: Wallet? = nil
    ) {
        self.title = title
        self.amount = amount
        self.currencyCode = currencyCode
        self.type = type
        self.frequency = frequency
        self.interval = max(1, interval)
        self.nextRunDate = nextRunDate
        self.note = note
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
        self.wallet = wallet
    }
}

@Model
final class CategoryBudget {
    var amount: Decimal = 0
    var currencyCode: String = "USD"
    var period: BudgetPeriod = BudgetPeriod.monthly
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify)
    var category: Category?

    init(
        amount: Decimal,
        currencyCode: String,
        period: BudgetPeriod = .monthly,
        isActive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        category: Category? = nil
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.period = period
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
    }
}
