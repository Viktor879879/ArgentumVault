import Foundation

struct CurrencyItem: Identifiable, Hashable {
    let id = UUID()
    let code: String
    let name: String
    let kind: AssetKind
}

enum CurrencyCatalog {
    static let baseCurrencies: [CurrencyItem] = [
        .init(code: "USD", name: "US Dollar", kind: .fiat),
        .init(code: "EUR", name: "Euro", kind: .fiat),
        .init(code: "SEK", name: "Swedish Krona", kind: .fiat),
        .init(code: "NOK", name: "Norwegian Krone", kind: .fiat),
        .init(code: "DKK", name: "Danish Krone", kind: .fiat),
        .init(code: "GBP", name: "British Pound", kind: .fiat),
        .init(code: "JPY", name: "Japanese Yen", kind: .fiat),
        .init(code: "CNY", name: "Chinese Yuan", kind: .fiat),
        .init(code: "CHF", name: "Swiss Franc", kind: .fiat),
        .init(code: "CAD", name: "Canadian Dollar", kind: .fiat),
        .init(code: "AUD", name: "Australian Dollar", kind: .fiat),
        .init(code: "UAH", name: "Ukrainian Hryvnia", kind: .fiat)
    ]
    
    static let allCurrencies: [CurrencyItem] = baseCurrencies + [
        .init(code: "BTC", name: "Bitcoin", kind: .crypto),
        .init(code: "ETH", name: "Ethereum", kind: .crypto),
        .init(code: "SOL", name: "Solana", kind: .crypto),
        .init(code: "XAU", name: "Gold", kind: .metal),
        .init(code: "XAG", name: "Silver", kind: .metal)
    ]
}
