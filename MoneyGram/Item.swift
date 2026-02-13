//
//  Item.swift
//  MoneyGram
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
}

@Model
final class Category {
    var name: String
    var type: CategoryType
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date
    
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []
    
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
    var amount: Decimal
    var currencyCode: String
    var date: Date
    var note: String?
    var type: TransactionType?
    var walletNameSnapshot: String?
    var walletKindRaw: String?
    
    @Attribute(.externalStorage)
    var photoData: Data?
    
    @Relationship(deleteRule: .nullify)
    var category: Category?
    
    @Relationship(deleteRule: .nullify)
    var wallet: Wallet?
    
    init(
        amount: Decimal,
        currencyCode: String,
        date: Date = Date(),
        note: String? = nil,
        type: TransactionType = TransactionType.expense,
        walletNameSnapshot: String? = nil,
        walletKindRaw: String? = nil,
        photoData: Data? = nil,
        category: Category? = nil,
        wallet: Wallet? = nil
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.date = date
        self.note = note
        self.type = type
        self.walletNameSnapshot = walletNameSnapshot
        self.walletKindRaw = walletKindRaw
        self.photoData = photoData
        self.category = category
        self.wallet = wallet
    }
}

@Model
final class Asset {
    var symbol: String
    var name: String
    var kind: AssetKind
    
    init(symbol: String, name: String, kind: AssetKind) {
        self.symbol = symbol
        self.name = name
        self.kind = kind
    }
}

@Model
final class Wallet {
    var name: String
    var assetCode: String
    var kind: AssetKind
    var balance: Decimal
    var createdAt: Date
    var updatedAt: Date
    
    var folder: WalletFolder?
    
    init(
        name: String,
        assetCode: String,
        kind: AssetKind,
        balance: Decimal,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.assetCode = assetCode
        self.kind = kind
        self.balance = balance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class WalletFolder {
    var name: String
    var createdAt: Date
    var wallets: [Wallet] = []
    
    init(name: String, createdAt: Date = Date()) {
        self.name = name
        self.createdAt = createdAt
    }
}
