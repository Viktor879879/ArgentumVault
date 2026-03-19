import Foundation
import Combine

struct FXRatesSnapshot: Codable {
    let base: String
    let date: String
    let rates: [String: Double]
}

enum RateServiceError: Error {
    case invalidURL
    case missingAPIKey
    case unexpectedResponse
}

@MainActor
final class RateService: ObservableObject {
    private enum CacheKeys {
        static let snapshot = "rateService.snapshot"
    }
    
    private let fxTTL: TimeInterval = 60 * 60 * 12
    private let cryptoTTL: TimeInterval = 60 * 5
    private let metalTTL: TimeInterval = 60 * 60 * 12
    private let stockTTL: TimeInterval = 60 * 60 * 12
    
    @Published private(set) var fxRates: [String: Double] = [:]
    @Published private(set) var fxBase: String = "EUR"
    @Published private(set) var lastFXUpdate: Date?
    @Published private(set) var cryptoUSDPrices: [String: Double] = [:]
    @Published private(set) var metalUSDPrices: [String: Double] = [:]
    @Published private(set) var stockUSDPrices: [String: Double] = [:]
    @Published private(set) var lastCryptoUpdate: Date?
    @Published private(set) var lastMetalUpdate: Date?
    @Published private(set) var lastStockUpdate: Date?
    
    private let frankfurter = FrankfurterProvider()
    private let exchangerateHost = ExchangerateHostProvider()
    private let erApi = ErApiProvider()
    private let metalsLive = MetalsLiveProvider()
    private let binance = BinanceProvider()
    private let alphaVantage = AlphaVantageProvider()
    
    init() {
        loadCache()
    }
    
    func refreshFX(base: String) async {
        do {
            let snapshot = try await frankfurter.latestRates(base: base)
            let baseCode = snapshot.base.uppercased()
            var normalizedRates: [String: Double] = [:]
            for (code, rate) in snapshot.rates {
                normalizedRates[code.uppercased()] = rate
            }
            normalizedRates[baseCode] = 1
            fxRates = normalizedRates
            fxBase = snapshot.base
            lastFXUpdate = ISO8601DateFormatter().date(from: snapshot.date)
            
            if fxRates["UAH"] == nil {
                if let fallback = try? await exchangerateHost.latestRates(base: baseCode, symbols: ["UAH"]) {
                    if let rate = fallback.rates["UAH"] {
                        fxRates["UAH"] = rate
                    }
                }
                if fxRates["UAH"] == nil {
                    if let usdToUAH = try? await erApi.usdRate(for: "UAH") {
                        let baseToUAH: Double
                        if baseCode == "USD" {
                            baseToUAH = usdToUAH
                        } else if let baseToUSD = fxRates["USD"] {
                            baseToUAH = usdToUAH * baseToUSD
                        } else {
                            baseToUAH = usdToUAH
                        }
                        fxRates["UAH"] = baseToUAH
                    }
                }
            }
            
            saveCache()
        } catch {
            // Keep previous rates if update fails.
        }
    }
    
    func refreshAssetPrices(wallets: [Wallet]) async {
        var cryptoSymbols: Set<String> = []
        var metalSymbols: Set<String> = []
        var stockSymbols: Set<String> = []
        
        for wallet in wallets {
            switch wallet.kind {
            case .crypto:
                cryptoSymbols.insert(wallet.assetCode.uppercased())
            case .metal:
                metalSymbols.insert(wallet.assetCode.uppercased())
            case .stock:
                stockSymbols.insert(wallet.assetCode.uppercased())
            case .fiat:
                break
            }
        }
        
        await withTaskGroup(of: Void.self) { group in
            for symbol in cryptoSymbols {
                group.addTask {
                    if let price = try? await self.binance.tickerPrice(base: symbol, quote: "USDT") {
                        await MainActor.run {
                            self.cryptoUSDPrices[symbol] = price
                            self.lastCryptoUpdate = Date()
                        }
                    }
                }
            }
            for symbol in metalSymbols {
                _ = symbol
            }
            for symbol in stockSymbols {
                group.addTask {
                    if let price = try? await self.alphaVantage.globalQuotePrice(symbol: symbol) {
                        await MainActor.run {
                            self.stockUSDPrices[symbol] = price
                            self.lastStockUpdate = Date()
                        }
                    }
                }
            }
        }
        
        if !metalSymbols.isEmpty {
            let upperSymbols = metalSymbols.map { $0.uppercased() }
            // Primary metals source
            if let spot = try? await metalsLive.spotUSD(symbols: upperSymbols) {
                await MainActor.run {
                    for (code, price) in spot {
                        let key = code.uppercased()
                        self.metalUSDPrices[key] = price
                        if key == "XAG" || key == "SILVER" {
                            self.metalUSDPrices["XAG"] = price
                            self.metalUSDPrices["SILVER"] = price
                        }
                        if key == "XAU" || key == "GOLD" {
                            self.metalUSDPrices["XAU"] = price
                            self.metalUSDPrices["GOLD"] = price
                        }
                    }
                    self.lastMetalUpdate = Date()
                }
            }
            
            // Fallback metals source
            if let fallback = try? await exchangerateHost.latestRates(base: "USD", symbols: upperSymbols) {
                await MainActor.run {
                    for (code, rate) in fallback.rates {
                        let key = code.uppercased()
                        if self.metalUSDPrices[key] == nil {
                            self.metalUSDPrices[key] = rate
                        }
                        if key == "XAG" || key == "SILVER" {
                            if self.metalUSDPrices["XAG"] == nil { self.metalUSDPrices["XAG"] = rate }
                            if self.metalUSDPrices["SILVER"] == nil { self.metalUSDPrices["SILVER"] = rate }
                        }
                        if key == "XAU" || key == "GOLD" {
                            if self.metalUSDPrices["XAU"] == nil { self.metalUSDPrices["XAU"] = rate }
                            if self.metalUSDPrices["GOLD"] == nil { self.metalUSDPrices["GOLD"] = rate }
                        }
                    }
                    self.lastMetalUpdate = Date()
                }
            }
        }
        saveCache()
    }
    
    func refreshAllRates(base: String, wallets: [Wallet], force: Bool) async {
        if shouldRefreshFX(base: base, force: force) {
            await refreshFX(base: base)
        }
        if shouldRefreshCrypto(force: force) || shouldRefreshMetal(force: force) || shouldRefreshStock(force: force) {
            await refreshAssetPrices(wallets: wallets)
        }
    }
    
    private func shouldRefreshFX(base: String, force: Bool) -> Bool {
        if force { return true }
        if base.uppercased() != fxBase.uppercased() { return true }
        guard let last = lastFXUpdate else { return true }
        return Date().timeIntervalSince(last) > fxTTL
    }
    
    private func shouldRefreshCrypto(force: Bool) -> Bool {
        if force { return true }
        guard let last = lastCryptoUpdate else { return true }
        return Date().timeIntervalSince(last) > cryptoTTL
    }
    
    private func shouldRefreshMetal(force: Bool) -> Bool {
        if force { return true }
        guard let last = lastMetalUpdate else { return true }
        return Date().timeIntervalSince(last) > metalTTL
    }
    
    private func shouldRefreshStock(force: Bool) -> Bool {
        if force { return true }
        guard let last = lastStockUpdate else { return true }
        return Date().timeIntervalSince(last) > stockTTL
    }
    
    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: CacheKeys.snapshot),
              let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: data) else {
            return
        }
        fxRates = snapshot.fxRates
        fxBase = snapshot.fxBase
        lastFXUpdate = snapshot.lastFXUpdate
        cryptoUSDPrices = snapshot.cryptoUSDPrices
        metalUSDPrices = snapshot.metalUSDPrices
        stockUSDPrices = snapshot.stockUSDPrices
        lastCryptoUpdate = snapshot.lastCryptoUpdate
        lastMetalUpdate = snapshot.lastMetalUpdate
        lastStockUpdate = snapshot.lastStockUpdate
    }
    
    private func saveCache() {
        let snapshot = CacheSnapshot(
            fxRates: fxRates,
            fxBase: fxBase,
            lastFXUpdate: lastFXUpdate,
            cryptoUSDPrices: cryptoUSDPrices,
            metalUSDPrices: metalUSDPrices,
            stockUSDPrices: stockUSDPrices,
            lastCryptoUpdate: lastCryptoUpdate,
            lastMetalUpdate: lastMetalUpdate,
            lastStockUpdate: lastStockUpdate
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: CacheKeys.snapshot)
        }
    }
    
    func convert(amount: Decimal, from assetCode: String, kind: AssetKind, to target: String) -> Decimal? {
        let targetCode = target.uppercased()
        
        switch kind {
        case .fiat:
            return convertFiat(amount: amount, from: assetCode, to: targetCode)
        case .crypto:
            guard let usdPrice = cryptoUSDPrices[assetCode.uppercased()] else { return nil }
            let usdValue = (amount as NSDecimalNumber).doubleValue * usdPrice
            return convertUSDToTarget(usdValue, target: targetCode)
        case .metal:
            guard let usdPrice = metalUSDPrices[assetCode.uppercased()] else { return nil }
            let usdValue = (amount as NSDecimalNumber).doubleValue * usdPrice
            return convertUSDToTarget(usdValue, target: targetCode)
        case .stock:
            guard let usdPrice = stockUSDPrices[assetCode.uppercased()] else { return nil }
            let usdValue = (amount as NSDecimalNumber).doubleValue * usdPrice
            return convertUSDToTarget(usdValue, target: targetCode)
        }
    }
    
    private func convertFiat(amount: Decimal, from source: String, to target: String) -> Decimal? {
        if source == target {
            return amount
        }
        guard let rateToSource = fxRate(for: source) else { return nil }
        let amountInBase = (amount as NSDecimalNumber).doubleValue / rateToSource
        if target == fxBase {
            return Decimal(amountInBase)
        }
        guard let rateToTarget = fxRate(for: target) else { return nil }
        let amountInTarget = amountInBase * rateToTarget
        return Decimal(amountInTarget)
    }
    
    private func convertUSDToTarget(_ usdValue: Double, target: String) -> Decimal? {
        if target == "USD" {
            return Decimal(usdValue)
        }
        guard let rateToUSD = fxRate(for: "USD") else { return nil }
        let amountInBase = usdValue / rateToUSD
        if target == fxBase {
            return Decimal(amountInBase)
        }
        guard let rateToTarget = fxRate(for: target) else { return nil }
        return Decimal(amountInBase * rateToTarget)
    }
    
    private func fxRate(for code: String) -> Double? {
        if code == fxBase {
            return 1
        }
        return fxRates[code]
    }
    
    func cryptoPrice(symbol: String, quote: String) async -> Double? {
        do {
            return try await binance.tickerPrice(base: symbol, quote: quote)
        } catch {
            return nil
        }
    }
    
    
    func stockQuote(symbol: String) async -> Double? {
        do {
            return try await alphaVantage.globalQuotePrice(symbol: symbol)
        } catch {
            return nil
        }
    }
}

private struct CacheSnapshot: Codable {
    let fxRates: [String: Double]
    let fxBase: String
    let lastFXUpdate: Date?
    let cryptoUSDPrices: [String: Double]
    let metalUSDPrices: [String: Double]
    let stockUSDPrices: [String: Double]
    let lastCryptoUpdate: Date?
    let lastMetalUpdate: Date?
    let lastStockUpdate: Date?
}

struct FrankfurterProvider {
    func latestRates(base: String) async throws -> FXRatesSnapshot {
        guard var components = URLComponents(string: "https://api.frankfurter.dev/v1/latest") else {
            throw RateServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "base", value: base)
        ]
        guard let url = components.url else { throw RateServiceError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(FXRatesSnapshot.self, from: data)
    }
}

struct BinanceProvider {
    func tickerPrice(base: String, quote: String) async throws -> Double {
        guard var components = URLComponents(string: "https://data-api.binance.vision/api/v3/ticker/price") else {
            throw RateServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "symbol", value: "\(base)\(quote)")
        ]
        guard let url = components.url else { throw RateServiceError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(BinanceTickerPrice.self, from: data)
        return Double(response.price) ?? 0
    }
    
    private struct BinanceTickerPrice: Decodable {
        let symbol: String
        let price: String
    }
}

struct AlphaVantageProvider {
    func globalQuotePrice(symbol: String) async throws -> Double {
        let apiKey = try apiKey()
        guard var components = URLComponents(string: "https://www.alphavantage.co/query") else {
            throw RateServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "function", value: "GLOBAL_QUOTE"),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
        guard let url = components.url else { throw RateServiceError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(AlphaVantageGlobalQuoteResponse.self, from: data)
        return Double(response.globalQuote.price) ?? 0
    }
    
    private func apiKey() throws -> String {
        if let key = Bundle.main.object(forInfoDictionaryKey: "ALPHA_VANTAGE_API_KEY") as? String,
           !key.isEmpty {
            return key
        }
        throw RateServiceError.missingAPIKey
    }
    
    private struct AlphaVantageGlobalQuoteResponse: Decodable {
        let globalQuote: AlphaVantageGlobalQuote
        
        private enum CodingKeys: String, CodingKey {
            case globalQuote = "Global Quote"
        }
    }
    
    private struct AlphaVantageGlobalQuote: Decodable {
        let price: String
        
        private enum CodingKeys: String, CodingKey {
            case price = "05. price"
        }
    }
}

struct ExchangerateHostProvider {
    func latestRates(base: String, symbols: [String]) async throws -> FXRatesSnapshot {
        guard var components = URLComponents(string: "https://api.exchangerate.host/latest") else {
            throw RateServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "base", value: base),
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))
        ]
        guard let url = components.url else { throw RateServiceError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(FXRatesSnapshot.self, from: data)
    }
}

struct ErApiProvider {
    func usdRate(for symbol: String) async throws -> Double {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else {
            throw RateServiceError.invalidURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(ErApiResponse.self, from: data)
        if let rate = response.rates[symbol.uppercased()] {
            return rate
        }
        throw RateServiceError.unexpectedResponse
    }
    
    private struct ErApiResponse: Decodable {
        let rates: [String: Double]
    }
}

struct MetalsLiveProvider {
    func spotUSD(symbols: [String]) async throws -> [String: Double] {
        guard let url = URL(string: "https://api.metals.live/v1/spot") else {
            throw RateServiceError.invalidURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let raw = try JSONSerialization.jsonObject(with: data) as? [[Any]] ?? []
        var result: [String: Double] = [:]
        for entry in raw {
            guard entry.count >= 2 else { continue }
            guard let symbol = entry[0] as? String else { continue }
            let value: Double?
            if let v = entry[1] as? Double {
                value = v
            } else if let number = entry[1] as? NSNumber {
                value = number.doubleValue
            } else {
                value = nil
            }
            if let value {
                let key = symbol.uppercased()
                result[key] = value
                if key == "SILVER" {
                    result["XAG"] = value
                }
                if key == "GOLD" {
                    result["XAU"] = value
                }
            }
        }
        if symbols.isEmpty { return result }
        let filter = Set(symbols.map { $0.uppercased() })
        return result.filter { filter.contains($0.key) }
    }
}
