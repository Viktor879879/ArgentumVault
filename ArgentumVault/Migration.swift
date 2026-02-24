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

    static func seedDefaultCategoriesIfNeeded(
        modelContext: ModelContext,
        languageCode: String,
        didSeedDefaultCategories: inout Bool
    ) {
        guard !didSeedDefaultCategories else { return }

        let descriptor = FetchDescriptor<Category>()
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
            didSeedDefaultCategories = true
            return
        }

        for seed in defaultCategorySeeds(languageCode: languageCode) {
            let category = Category(
                name: seed.name,
                type: seed.type,
                colorHex: seed.colorHex
            )
            modelContext.insert(category)
        }

        try? modelContext.save()
        didSeedDefaultCategories = true
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

    private struct CategorySeed {
        let name: String
        let type: CategoryType
        let colorHex: String
    }

    private static func defaultCategorySeeds(languageCode: String) -> [CategorySeed] {
        switch languageCode {
        case "ru":
            return [
                CategorySeed(name: "Продукты", type: .expense, colorHex: "4CAF50FF"),
                CategorySeed(name: "Транспорт", type: .expense, colorHex: "2196F3FF"),
                CategorySeed(name: "Жильё", type: .expense, colorHex: "FF9800FF"),
                CategorySeed(name: "Кафе и рестораны", type: .expense, colorHex: "E91E63FF"),
                CategorySeed(name: "Покупки", type: .expense, colorHex: "9C27B0FF"),
                CategorySeed(name: "Здоровье", type: .expense, colorHex: "00BCD4FF"),
                CategorySeed(name: "Развлечения", type: .expense, colorHex: "FFC107FF"),
                CategorySeed(name: "Подписки", type: .expense, colorHex: "607D8BFF"),
                CategorySeed(name: "Зарплата", type: .income, colorHex: "2E7D32FF"),
                CategorySeed(name: "Подработка", type: .income, colorHex: "00897BFF"),
                CategorySeed(name: "Подарки", type: .income, colorHex: "1565C0FF")
            ]
        case "uk":
            return [
                CategorySeed(name: "Продукти", type: .expense, colorHex: "4CAF50FF"),
                CategorySeed(name: "Транспорт", type: .expense, colorHex: "2196F3FF"),
                CategorySeed(name: "Житло", type: .expense, colorHex: "FF9800FF"),
                CategorySeed(name: "Кафе та ресторани", type: .expense, colorHex: "E91E63FF"),
                CategorySeed(name: "Покупки", type: .expense, colorHex: "9C27B0FF"),
                CategorySeed(name: "Здоров'я", type: .expense, colorHex: "00BCD4FF"),
                CategorySeed(name: "Розваги", type: .expense, colorHex: "FFC107FF"),
                CategorySeed(name: "Підписки", type: .expense, colorHex: "607D8BFF"),
                CategorySeed(name: "Зарплата", type: .income, colorHex: "2E7D32FF"),
                CategorySeed(name: "Підробіток", type: .income, colorHex: "00897BFF"),
                CategorySeed(name: "Подарунки", type: .income, colorHex: "1565C0FF")
            ]
        case "sv":
            return [
                CategorySeed(name: "Mat", type: .expense, colorHex: "4CAF50FF"),
                CategorySeed(name: "Transport", type: .expense, colorHex: "2196F3FF"),
                CategorySeed(name: "Boende", type: .expense, colorHex: "FF9800FF"),
                CategorySeed(name: "Cafe och restaurang", type: .expense, colorHex: "E91E63FF"),
                CategorySeed(name: "Shopping", type: .expense, colorHex: "9C27B0FF"),
                CategorySeed(name: "Halsa", type: .expense, colorHex: "00BCD4FF"),
                CategorySeed(name: "Noje", type: .expense, colorHex: "FFC107FF"),
                CategorySeed(name: "Prenumerationer", type: .expense, colorHex: "607D8BFF"),
                CategorySeed(name: "Lon", type: .income, colorHex: "2E7D32FF"),
                CategorySeed(name: "Frilans", type: .income, colorHex: "00897BFF"),
                CategorySeed(name: "Gavor", type: .income, colorHex: "1565C0FF")
            ]
        default:
            return [
                CategorySeed(name: "Groceries", type: .expense, colorHex: "4CAF50FF"),
                CategorySeed(name: "Transport", type: .expense, colorHex: "2196F3FF"),
                CategorySeed(name: "Housing", type: .expense, colorHex: "FF9800FF"),
                CategorySeed(name: "Restaurants", type: .expense, colorHex: "E91E63FF"),
                CategorySeed(name: "Shopping", type: .expense, colorHex: "9C27B0FF"),
                CategorySeed(name: "Health", type: .expense, colorHex: "00BCD4FF"),
                CategorySeed(name: "Entertainment", type: .expense, colorHex: "FFC107FF"),
                CategorySeed(name: "Subscriptions", type: .expense, colorHex: "607D8BFF"),
                CategorySeed(name: "Salary", type: .income, colorHex: "2E7D32FF"),
                CategorySeed(name: "Freelance", type: .income, colorHex: "00897BFF"),
                CategorySeed(name: "Gifts", type: .income, colorHex: "1565C0FF")
            ]
        }
    }
}
