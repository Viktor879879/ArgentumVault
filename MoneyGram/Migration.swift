import Foundation
import SwiftData

@MainActor
enum Migration {
    static func runIfNeeded(
        modelContext: ModelContext,
        baseCurrencyCode: String,
        didRunMigration: inout Bool
    ) {
        guard !didRunMigration else { return }
        guard !baseCurrencyCode.isEmpty else { return }
        
        migrateTransactions(modelContext: modelContext, baseCurrencyCode: baseCurrencyCode)
        migrateCategories(modelContext: modelContext)
        
        didRunMigration = true
    }
    
    private static func migrateTransactions(modelContext: ModelContext, baseCurrencyCode: String) {
        let descriptor = FetchDescriptor<Transaction>()
        guard let transactions = try? modelContext.fetch(descriptor) else { return }
        
        for transaction in transactions {
            if transaction.type == nil {
                if let categoryType = transaction.category?.type {
                    transaction.type = categoryType == .income ? .income : .expense
                } else {
                    transaction.type = .expense
                }
            }
            
            if transaction.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transaction.currencyCode = baseCurrencyCode
            }
        }
    }
    
    private static func migrateCategories(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Category>()
        guard let categories = try? modelContext.fetch(descriptor) else { return }
        
        for category in categories {
            if category.colorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                category.colorHex = "2F80EDFF"
            }
        }
    }
}
