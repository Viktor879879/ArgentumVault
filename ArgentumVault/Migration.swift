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
        let descriptor = FetchDescriptor<Category>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        if !existing.isEmpty {
            didSeedDefaultCategories = true
            return
        }

        for seed in defaultCategorySeeds(languageCode: languageCode) {
            let localizedNames = defaultLocalizedNameMap(for: seed.key)
            let category = Category(
                syncID: seed.key,
                name: seed.name,
                sourceLanguageCode: "en",
                localizedNamesJSON: CategoryLocalization.encodeLocalizedNames(localizedNames),
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
        let key: String
        let name: String
        let type: CategoryType
        let colorHex: String
    }

    typealias SeedName = (key: String, name: String)

    private static let expensePalette = [
        "4CAF50FF", "E91E63FF", "FF9800FF", "607D8BFF", "2196F3FF",
        "3F51B5FF", "00BCD4FF", "009688FF", "9C27B0FF", "F06292FF",
        "795548FF", "FFC107FF", "8BC34AFF", "673AB7FF", "FF5722FF",
        "26A69AFF", "5C6BC0FF", "7E57C2FF", "29B6F6FF", "8D6E63FF",
        "42A5F5FF", "78909CFF", "EF5350FF", "66BB6AFF", "90A4AEFF"
    ]

    private static let incomePalette = [
        "2E7D32FF", "43A047FF", "66BB6AFF", "00897BFF", "26A69AFF",
        "1565C0FF", "5E35B1FF", "1E88E5FF", "7CB342FF", "00ACC1FF",
        "8E24AAFF", "6D4C41FF", "3949ABFF", "2E7D32FF", "78909CFF"
    ]

    private static func defaultCategorySeeds(languageCode _: String) -> [CategorySeed] {
        let localizedSeeds = localizedDefaultSeedNames(languageCode: "en")

        let expenseSeeds = localizedSeeds.expenses.enumerated().map { index, seed in
            CategorySeed(
                key: seed.key,
                name: seed.name,
                type: .expense,
                colorHex: expensePalette[index % expensePalette.count]
            )
        }

        let incomeSeeds = localizedSeeds.income.enumerated().map { index, seed in
            CategorySeed(
                key: seed.key,
                name: seed.name,
                type: .income,
                colorHex: incomePalette[index % incomePalette.count]
            )
        }

        return expenseSeeds + incomeSeeds
    }

    private static func defaultLocalizedNameMap(for key: String) -> [String: String] {
        var result: [String: String] = [:]
        for languageCode in CategoryLocalization.supportedLanguageCodes {
            let localizedSeeds = localizedDefaultSeedNames(languageCode: languageCode)
            if let match = (localizedSeeds.expenses + localizedSeeds.income).first(where: { $0.key == key }) {
                result[languageCode] = match.name
            }
        }
        return result
    }

    static func localizedDefaultSeedNames(languageCode: String) -> (expenses: [SeedName], income: [SeedName]) {
        switch languageCode {
        case "ru":
            return (
                expenses: [
                    ("default.expense.groceries", "Продукты"),
                    ("default.expense.cafes_restaurants", "Кафе и рестораны"),
                    ("default.expense.home", "Дом"),
                    ("default.expense.utilities", "Коммунальные услуги"),
                    ("default.expense.transport", "Транспорт"),
                    ("default.expense.car", "Машина"),
                    ("default.expense.health", "Здоровье"),
                    ("default.expense.pharmacy", "Аптека"),
                    ("default.expense.clothes", "Одежда"),
                    ("default.expense.beauty_care", "Красота и уход"),
                    ("default.expense.subscriptions", "Подписки"),
                    ("default.expense.entertainment", "Развлечения"),
                    ("default.expense.travel", "Путешествия"),
                    ("default.expense.education", "Образование"),
                    ("default.expense.children", "Дети"),
                    ("default.expense.pets", "Питомцы"),
                    ("default.expense.gifts", "Подарки"),
                    ("default.expense.family", "Семья"),
                    ("default.expense.sports_fitness", "Спорт и фитнес"),
                    ("default.expense.work", "Работа"),
                    ("default.expense.tech_electronics", "Техника и электроника"),
                    ("default.expense.taxes_fees", "Налоги и комиссии"),
                    ("default.expense.loans_debts", "Кредиты и долги"),
                    ("default.expense.home_supplies", "Покупки для дома"),
                    ("default.expense.other", "Прочее")
                ],
                income: [
                    ("default.income.salary", "Зарплата"),
                    ("default.income.advance", "Аванс"),
                    ("default.income.bonus", "Бонус"),
                    ("default.income.freelance", "Фриланс"),
                    ("default.income.side_hustle", "Подработка"),
                    ("default.income.business", "Бизнес"),
                    ("default.income.gifts", "Подарки"),
                    ("default.income.transfers", "Переводы"),
                    ("default.income.refund", "Возврат"),
                    ("default.income.cashback", "Кэшбэк"),
                    ("default.income.benefits", "Пособия"),
                    ("default.income.selling_items", "Продажа вещей"),
                    ("default.income.rent", "Аренда"),
                    ("default.income.investments", "Инвестиции"),
                    ("default.income.other", "Прочее")
                ]
            )
        case "uk":
            return (
                expenses: [
                    ("default.expense.groceries", "Продукти"),
                    ("default.expense.cafes_restaurants", "Кафе та ресторани"),
                    ("default.expense.home", "Дім"),
                    ("default.expense.utilities", "Комунальні послуги"),
                    ("default.expense.transport", "Транспорт"),
                    ("default.expense.car", "Авто"),
                    ("default.expense.health", "Здоров'я"),
                    ("default.expense.pharmacy", "Аптека"),
                    ("default.expense.clothes", "Одяг"),
                    ("default.expense.beauty_care", "Краса та догляд"),
                    ("default.expense.subscriptions", "Підписки"),
                    ("default.expense.entertainment", "Розваги"),
                    ("default.expense.travel", "Подорожі"),
                    ("default.expense.education", "Освіта"),
                    ("default.expense.children", "Діти"),
                    ("default.expense.pets", "Домашні тварини"),
                    ("default.expense.gifts", "Подарунки"),
                    ("default.expense.family", "Сім'я"),
                    ("default.expense.sports_fitness", "Спорт і фітнес"),
                    ("default.expense.work", "Робота"),
                    ("default.expense.tech_electronics", "Техніка та електроніка"),
                    ("default.expense.taxes_fees", "Податки та комісії"),
                    ("default.expense.loans_debts", "Кредити та борги"),
                    ("default.expense.home_supplies", "Покупки для дому"),
                    ("default.expense.other", "Інше")
                ],
                income: [
                    ("default.income.salary", "Зарплата"),
                    ("default.income.advance", "Аванс"),
                    ("default.income.bonus", "Бонус"),
                    ("default.income.freelance", "Фриланс"),
                    ("default.income.side_hustle", "Підробіток"),
                    ("default.income.business", "Бізнес"),
                    ("default.income.gifts", "Подарунки"),
                    ("default.income.transfers", "Перекази"),
                    ("default.income.refund", "Повернення"),
                    ("default.income.cashback", "Кешбек"),
                    ("default.income.benefits", "Виплати"),
                    ("default.income.selling_items", "Продаж речей"),
                    ("default.income.rent", "Оренда"),
                    ("default.income.investments", "Інвестиції"),
                    ("default.income.other", "Інше")
                ]
            )
        case "sv":
            return (
                expenses: [
                    ("default.expense.groceries", "Matvaror"),
                    ("default.expense.cafes_restaurants", "Caféer och restauranger"),
                    ("default.expense.home", "Hem"),
                    ("default.expense.utilities", "Hushållsräkningar"),
                    ("default.expense.transport", "Transport"),
                    ("default.expense.car", "Bil"),
                    ("default.expense.health", "Hälsa"),
                    ("default.expense.pharmacy", "Apotek"),
                    ("default.expense.clothes", "Kläder"),
                    ("default.expense.beauty_care", "Skönhet och vård"),
                    ("default.expense.subscriptions", "Prenumerationer"),
                    ("default.expense.entertainment", "Underhållning"),
                    ("default.expense.travel", "Resor"),
                    ("default.expense.education", "Utbildning"),
                    ("default.expense.children", "Barn"),
                    ("default.expense.pets", "Husdjur"),
                    ("default.expense.gifts", "Presenter"),
                    ("default.expense.family", "Familj"),
                    ("default.expense.sports_fitness", "Sport och fitness"),
                    ("default.expense.work", "Arbete"),
                    ("default.expense.tech_electronics", "Teknik och elektronik"),
                    ("default.expense.taxes_fees", "Skatter och avgifter"),
                    ("default.expense.loans_debts", "Lån och skulder"),
                    ("default.expense.home_supplies", "Heminköp"),
                    ("default.expense.other", "Övrigt")
                ],
                income: [
                    ("default.income.salary", "Lön"),
                    ("default.income.advance", "Förskott"),
                    ("default.income.bonus", "Bonus"),
                    ("default.income.freelance", "Frilans"),
                    ("default.income.side_hustle", "Extrajobb"),
                    ("default.income.business", "Företag"),
                    ("default.income.gifts", "Presenter"),
                    ("default.income.transfers", "Överföringar"),
                    ("default.income.refund", "Återbetalning"),
                    ("default.income.cashback", "Cashback"),
                    ("default.income.benefits", "Bidrag"),
                    ("default.income.selling_items", "Försäljning av saker"),
                    ("default.income.rent", "Hyresintäkter"),
                    ("default.income.investments", "Investeringar"),
                    ("default.income.other", "Övrigt")
                ]
            )
        default:
            return (
                expenses: [
                    ("default.expense.groceries", "Groceries"),
                    ("default.expense.cafes_restaurants", "Cafes & Restaurants"),
                    ("default.expense.home", "Home"),
                    ("default.expense.utilities", "Utilities"),
                    ("default.expense.transport", "Transport"),
                    ("default.expense.car", "Car"),
                    ("default.expense.health", "Health"),
                    ("default.expense.pharmacy", "Pharmacy"),
                    ("default.expense.clothes", "Clothes"),
                    ("default.expense.beauty_care", "Beauty & Care"),
                    ("default.expense.subscriptions", "Subscriptions"),
                    ("default.expense.entertainment", "Entertainment"),
                    ("default.expense.travel", "Travel"),
                    ("default.expense.education", "Education"),
                    ("default.expense.children", "Children"),
                    ("default.expense.pets", "Pets"),
                    ("default.expense.gifts", "Gifts"),
                    ("default.expense.family", "Family"),
                    ("default.expense.sports_fitness", "Sports & Fitness"),
                    ("default.expense.work", "Work"),
                    ("default.expense.tech_electronics", "Tech & Electronics"),
                    ("default.expense.taxes_fees", "Taxes & Fees"),
                    ("default.expense.loans_debts", "Loans & Debts"),
                    ("default.expense.home_supplies", "Home Supplies"),
                    ("default.expense.other", "Other")
                ],
                income: [
                    ("default.income.salary", "Salary"),
                    ("default.income.advance", "Advance"),
                    ("default.income.bonus", "Bonus"),
                    ("default.income.freelance", "Freelance"),
                    ("default.income.side_hustle", "Side Hustle"),
                    ("default.income.business", "Business"),
                    ("default.income.gifts", "Gifts"),
                    ("default.income.transfers", "Transfers"),
                    ("default.income.refund", "Refund"),
                    ("default.income.cashback", "Cashback"),
                    ("default.income.benefits", "Benefits"),
                    ("default.income.selling_items", "Selling Items"),
                    ("default.income.rent", "Rent"),
                    ("default.income.investments", "Investments"),
                    ("default.income.other", "Other")
                ]
            )
        }
    }
}
