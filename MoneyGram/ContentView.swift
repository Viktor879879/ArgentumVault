//
//  ContentView.swift
//  MoneyGram
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import SwiftUI
import SwiftData
import PhotosUI
import Charts

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("didRunMigration_v1") private var didRunMigration = false
    @StateObject private var rateService = RateService()
    @State private var showSplash = true
    
    var body: some View {
        ZStack {
            if baseCurrencyCode.isEmpty {
                BaseCurrencySetupView()
            } else {
                TabView {
                    HomeView(rateService: rateService)
                        .tabItem {
                            Label("Home", systemImage: "house.fill")
                        }
                    
                    AnalyticsView(rateService: rateService)
                        .tabItem {
                            Label("Analytics", systemImage: "chart.pie.fill")
                        }
                }
            }
            
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            Migration.runIfNeeded(
                modelContext: modelContext,
                baseCurrencyCode: baseCurrencyCode,
                didRunMigration: &didRunMigration
            )
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeOut(duration: 0.25)) {
                    showSplash = false
                }
            }
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            // Keep splash background stable in dark mode to avoid black frame around a light logo asset.
            Color(hex: "ECECECFF")
                .ignoresSafeArea()
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
        }
    }
}

struct BaseCurrencySetupView: View {
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @State private var selection = CurrencyCatalog.baseCurrencies.first?.code ?? "USD"
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Base Currency") {
                    Picker("Currency", selection: $selection) {
                        ForEach(CurrencyCatalog.baseCurrencies, id: \.code) { currency in
                            Text("\(currency.code) — \(currency.name)")
                                .tag(currency.code)
                        }
                    }
                }
                
                Section {
                    Button("Continue") {
                        baseCurrencyCode = selection
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Welcome")
        }
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("totalCurrencies") private var totalCurrenciesStorage = ""
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    
    @ObservedObject var rateService: RateService
    
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Wallet.name) private var wallets: [Wallet]
    
    @State private var selectedType: CategoryType = .expense
    @State private var isAddingCategory = false
    @State private var isAddingTransaction = false
    @State private var isEditingCategory = false
    @State private var isEditingTransaction = false
    @State private var editingCategory: Category?
    @State private var editingTransaction: Transaction?
    @State private var isAddingWallet = false
    @State private var isEditingWallet = false
    @State private var editingWallet: Wallet?
    @State private var viewingWallet: Wallet?
    @State private var isManagingTotals = false
    
    private var filteredCategories: [Category] {
        categories.filter { $0.type == selectedType }
    }
    
    private var totalCurrencies: [String] {
        let stored = totalCurrenciesStorage
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for code in stored {
            if !unique.contains(code) {
                unique.append(code)
            }
        }
        if !unique.contains(baseCurrencyCode) {
            unique.insert(baseCurrencyCode, at: 0)
        }
        if unique.isEmpty {
            return [baseCurrencyCode]
        }
        return unique
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TotalsHeader(
                        totalCurrencies: totalCurrencies,
                        baseCurrencyCode: baseCurrencyCode,
                        wallets: wallets,
                        rateService: rateService,
                        addAction: { isManagingTotals = true },
                        isNumbersHidden: isNumbersHidden
                    )
                }
                
                Section {
                    WalletsHeader(addAction: { isAddingWallet = true })
                }
                
                Section("Wallets") {
                    if wallets.isEmpty {
                        Text("No wallets yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(wallets, id: \.persistentModelID) { wallet in
                            WalletRow(wallet: wallet)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewingWallet = wallet
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Delete", role: .destructive) {
                                        modelContext.delete(wallet)
                                    }
                                    Button("Edit") {
                                        editingWallet = wallet
                                        isEditingWallet = true
                                    }
                                }
                        }
                    }
                }
                
                Section {
                    Picker("Type", selection: $selectedType) {
                        ForEach(CategoryType.allCases, id: \.self) { type in
                            Text(type == .expense ? "Expenses" : "Income").tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Categories") {
                    if filteredCategories.isEmpty {
                        Text("No categories yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredCategories, id: \.persistentModelID) { category in
                            CategoryRow(category: category)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingCategory = category
                                    isEditingCategory = true
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Delete", role: .destructive) {
                                        modelContext.delete(category)
                                    }
                                    Button("Edit") {
                                        editingCategory = category
                                        isEditingCategory = true
                                    }
                                }
                        }
                    }
                }
                
                Section("Transactions") {
                    if transactions.isEmpty {
                        Text("No transactions yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transactions, id: \.persistentModelID) { transaction in
                            TransactionRow(transaction: transaction)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingTransaction = transaction
                                    isEditingTransaction = true
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Delete", role: .destructive) {
                                        deleteTransaction(transaction)
                                    }
                                    Button("Edit") {
                                        editingTransaction = transaction
                                        isEditingTransaction = true
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("MoneyGram")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isNumbersHidden.toggle()
                    } label: {
                        Image(systemName: isNumbersHidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel("Toggle privacy")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await rateService.refreshAllRates(base: baseCurrencyCode, wallets: wallets, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh rates")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isAddingTransaction = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add transaction")
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isAddingCategory = true
                    } label: {
                        Image(systemName: "square.grid.2x2.fill")
                    }
                    .accessibilityLabel("Add category")
                }
            }
            .task {
                await rateService.refreshAllRates(base: baseCurrencyCode, wallets: wallets, force: false)
            }
            .sheet(isPresented: $isAddingCategory) {
                AddCategoryView()
            }
            .sheet(isPresented: $isAddingTransaction) {
                AddTransactionView(defaultCurrencyCode: baseCurrencyCode)
            }
            .sheet(isPresented: $isEditingCategory) {
                if let editingCategory {
                    AddCategoryView(category: editingCategory)
                }
            }
            .sheet(isPresented: $isEditingTransaction) {
                if let editingTransaction {
                    AddTransactionView(
                        transaction: editingTransaction,
                        defaultCurrencyCode: baseCurrencyCode
                    )
                }
            }
            .sheet(isPresented: $isAddingWallet) {
                AddWalletView(defaultCurrencyCode: baseCurrencyCode)
            }
            .sheet(isPresented: $isEditingWallet) {
                if let editingWallet {
                    AddWalletView(wallet: editingWallet, defaultCurrencyCode: baseCurrencyCode)
                }
            }
            .sheet(item: $viewingWallet) { wallet in
                WalletDetailView(wallet: wallet, rateService: rateService)
            }
            .sheet(isPresented: $isManagingTotals) {
                TotalsManagerView(
                    selectedCodes: totalCurrencies,
                    baseCurrencyCode: baseCurrencyCode
                ) { newCodes in
                    totalCurrenciesStorage = newCodes.joined(separator: ",")
                }
            }
        }
    }
    
    private func deleteTransaction(_ transaction: Transaction) {
        if let wallet = transaction.wallet {
            var delta = transaction.amount
            if (transaction.type ?? .expense) == .expense {
                delta = -delta
            }
            wallet.balance -= delta
        }
        modelContext.delete(transaction)
    }
}

struct TotalsHeader: View {
    let totalCurrencies: [String]
    let baseCurrencyCode: String
    let wallets: [Wallet]
    let rateService: RateService
    let addAction: () -> Void
    let isNumbersHidden: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Total")
                    .font(.headline)
                Spacer()
                Button(action: addAction) {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add total currency")
            }
            
            if wallets.isEmpty {
                Text("Add wallets to see totals.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(totalCurrencies, id: \.self) { code in
                    HStack {
                        Text(code)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formattedTotal(for: code))
                            .font(.title3.weight(.semibold))
                    }
                }
            }
        }
    }
    
    private func formattedTotal(for target: String) -> String {
        let total = totalForCurrency(target)
        if isNumbersHidden {
            return "*** \(target)"
        }
        let formatted = DecimalFormatter.string(from: total)
        return "\(formatted) \(target)"
    }
    
    private func totalForCurrency(_ target: String) -> Decimal {
        var total = Decimal(0)
        for wallet in wallets {
            if let converted = rateService.convert(
                amount: wallet.balance,
                from: wallet.assetCode,
                kind: wallet.kind,
                to: target
            ) {
                total += converted
            }
        }
        return total
    }
    
}

struct WalletsHeader: View {
    let addAction: () -> Void
    
    var body: some View {
        HStack {
            Text("Wallets")
                .font(.headline)
            Spacer()
            Button(action: addAction) {
                Image(systemName: "plus.circle")
            }
            .accessibilityLabel("Add wallet")
        }
    }
}

struct WalletRow: View {
    let wallet: Wallet
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(wallet.name)
                    .font(.headline)
                Text(wallet.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isNumbersHidden {
                    Text("*** \(wallet.assetCode)")
                        .font(.headline)
                } else {
                    Text("\(DecimalFormatter.string(from: wallet.balance)) \(wallet.assetCode)")
                        .font(.headline)
                }
            }
        }
    }
}

extension Wallet {
    var kindLabel: String {
        switch kind {
        case .fiat: return "Fiat"
        case .crypto: return "Crypto"
        case .metal: return "Metal"
        case .stock: return "Stock"
        }
    }
}

struct CategoryRow: View {
    let category: Category
    
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: category.colorHex))
                .frame(width: 22, height: 22)
            Text(category.name)
            Spacer()
        }
    }
}

struct AnalyticsView: View {
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    @ObservedObject var rateService: RateService
    
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Wallet.name) private var analyticsWallets: [Wallet]
    
    @State private var selectedType: CategoryType = .expense
    @State private var selectedRange: AnalyticsRange = .month
    @State private var rangeAnchor: Date = Date()
    @State private var selectedWalletID: PersistentIdentifier?
    @State private var exportURL: URL?
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Type", selection: $selectedType) {
                        ForEach(CategoryType.allCases, id: \.self) { type in
                            Text(type == .expense ? "Expenses" : "Income").tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    Picker("Range", selection: $selectedRange) {
                        ForEach(AnalyticsRange.allCases, id: \.self) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    Picker("Wallet", selection: $selectedWalletID) {
                        Text("All Wallets").tag(PersistentIdentifier?.none)
                        ForEach(analyticsWallets, id: \.persistentModelID) { wallet in
                            Text(wallet.name).tag(Optional(wallet.persistentModelID))
                        }
                    }
                    
                    HStack {
                        Button {
                            shiftRange(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        
                        Spacer()
                        Text(rangeLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        
                        Button {
                            shiftRange(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!canMoveForward)
                    }
                }
                
                Section("Summary") {
                    if totals.isEmpty {
                        Text("No data for this period.")
                            .foregroundStyle(.secondary)
                    } else {
                        SummaryComparisonView(
                            currentTotal: currentTotal,
                            previousTotal: previousTotal,
                            currency: baseCurrencyCode,
                            isNumbersHidden: isNumbersHidden
                        )
                        
                        Chart(totals) { item in
                            SectorMark(
                                angle: .value("Amount", item.amount),
                                innerRadius: .ratio(0.6)
                            )
                            .foregroundStyle(item.color)
                        }
                        .frame(height: 260)
                        
                        ForEach(totals) { item in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 12, height: 12)
                                Text(item.name)
                                Spacer()
                                if isNumbersHidden {
                                    Text("***")
                                        .font(.subheadline.weight(.semibold))
                                } else {
                                    Text(item.formattedAmount)
                                        .font(.subheadline.weight(.semibold))
                                    Text(item.formattedPercent)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Analytics")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isNumbersHidden.toggle()
                    } label: {
                        Image(systemName: isNumbersHidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel("Toggle privacy")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Export CSV")
                    } else {
                        Button {
                            exportCSV()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Export CSV")
                    }
                }
            }
        }
        .task {
            await rateService.refreshAllRates(base: baseCurrencyCode, wallets: analyticsWallets, force: false)
        }
        .onChange(of: selectedRange) {
            rangeAnchor = Date()
        }
    }
    
    private var totals: [CategoryTotal] {
        let dateRange = selectedRange.dateRange(anchor: rangeAnchor)
        let filtered = transactions.filter { transaction in
            guard let category = transaction.category else { return false }
            guard category.type == selectedType else { return false }
            if let selectedWalletID,
               transaction.wallet?.persistentModelID != selectedWalletID {
                return false
            }
            return transaction.date >= dateRange.start && transaction.date <= dateRange.end
        }
        
        var sums: [PersistentIdentifier: Decimal] = [:]
        for transaction in filtered {
            guard let category = transaction.category else { continue }
            let amount = transaction.amount
            let kind = transaction.wallet?.kind ?? .fiat
            let converted = rateService.convert(
                amount: amount,
                from: transaction.currencyCode,
                kind: kind,
                to: baseCurrencyCode
            ) ?? amount
            sums[category.persistentModelID, default: 0] += converted
        }
        
        let totalSum = sums.values.reduce(Decimal(0), +)
        return categories
            .filter { $0.type == selectedType }
            .compactMap { category in
                guard let amount = sums[category.persistentModelID], amount > 0 else { return nil }
                return CategoryTotal(
                    id: category.persistentModelID,
                    name: category.name,
                    amount: amount,
                    color: Color(hex: category.colorHex),
                    total: totalSum,
                    currency: baseCurrencyCode
                )
            }
            .sorted { $0.amount > $1.amount }
    }
    
    private var currentTotal: Decimal {
        totals.reduce(Decimal(0)) { $0 + $1.amount }
    }
    
    private var previousTotal: Decimal {
        let previousAnchor = selectedRange.shift(anchor: rangeAnchor, by: -1)
        let dateRange = selectedRange.dateRange(anchor: previousAnchor)
        let filtered = transactions.filter { transaction in
            guard let category = transaction.category else { return false }
            guard category.type == selectedType else { return false }
            if let selectedWalletID,
               transaction.wallet?.persistentModelID != selectedWalletID {
                return false
            }
            return transaction.date >= dateRange.start && transaction.date <= dateRange.end
        }
        
        var total = Decimal(0)
        for transaction in filtered {
            let amount = transaction.amount
            let kind = transaction.wallet?.kind ?? .fiat
            let converted = rateService.convert(
                amount: amount,
                from: transaction.currencyCode,
                kind: kind,
                to: baseCurrencyCode
            ) ?? amount
            total += converted
        }
        return total
    }
    
    private var rangeLabel: String {
        selectedRange.label(anchor: rangeAnchor)
    }
    
    private var canMoveForward: Bool {
        let range = selectedRange.dateRange(anchor: rangeAnchor)
        return range.end < Date()
    }
    
    private func shiftRange(by value: Int) {
        rangeAnchor = selectedRange.shift(anchor: rangeAnchor, by: value)
    }
    
    private func exportCSV() {
        let csv = CSVExporter.transactionsCSV(filteredTransactionsForExport())
        let filename = "moneygram-transactions-\(DateFormatterCache.export.string(from: Date())).csv"
        exportURL = try? CSVExporter.writeCSVToDocuments(csv, filename: filename)
    }
    
    private func filteredTransactionsForExport() -> [Transaction] {
        let dateRange = selectedRange.dateRange(anchor: rangeAnchor)
        return transactions.filter { transaction in
            guard let category = transaction.category else { return false }
            guard category.type == selectedType else { return false }
            if let selectedWalletID,
               transaction.wallet?.persistentModelID != selectedWalletID {
                return false
            }
            return transaction.date >= dateRange.start && transaction.date <= dateRange.end
        }
    }
}

enum AnalyticsRange: CaseIterable {
    case day
    case week
    case month
    case year
    
    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
    
    func dateRange(anchor: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        switch self {
        case .day:
            let start = calendar.startOfDay(for: anchor)
            let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? anchor
            return (start, end)
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: anchor)
            let start = interval?.start ?? anchor
            let end = interval?.end.addingTimeInterval(-1) ?? anchor
            return (start, end)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: anchor)
            let start = interval?.start ?? anchor
            let end = interval?.end.addingTimeInterval(-1) ?? anchor
            return (start, end)
        case .year:
            let interval = calendar.dateInterval(of: .year, for: anchor)
            let start = interval?.start ?? anchor
            let end = interval?.end.addingTimeInterval(-1) ?? anchor
            return (start, end)
        }
    }
    
    func label(anchor: Date) -> String {
        switch self {
        case .day:
            return DateFormatterCache.day.string(from: anchor)
        case .week:
            let range = dateRange(anchor: anchor)
            let startDay = DateFormatterCache.dayShort.string(from: range.start)
            let endDay = DateFormatterCache.dayShortYear.string(from: range.end)
            return "\(startDay) – \(endDay)"
        case .month:
            return DateFormatterCache.monthYear.string(from: anchor)
        case .year:
            return DateFormatterCache.year.string(from: anchor)
        }
    }
    
    func shift(anchor: Date, by value: Int) -> Date {
        let calendar = Calendar.current
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: value, to: anchor) ?? anchor
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: value, to: anchor) ?? anchor
        case .month:
            return calendar.date(byAdding: .month, value: value, to: anchor) ?? anchor
        case .year:
            return calendar.date(byAdding: .year, value: value, to: anchor) ?? anchor
        }
    }
}

struct CategoryTotal: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let amount: Decimal
    let color: Color
    let total: Decimal
    let currency: String
    
    var formattedAmount: String {
        let value = DecimalFormatter.string(from: amount)
        return "\(value) \(currency)"
    }
    
    var formattedPercent: String {
        guard total > 0 else { return "0%" }
        let percent = (amount as NSDecimalNumber).doubleValue / (total as NSDecimalNumber).doubleValue * 100
        return String(format: "%.0f%%", percent)
    }
}

enum CategoryColorPalette {
    static let all: [String] = [
        "2F80EDFF", "27AE60FF", "F2C94CFF", "EB5757FF", "9B51E0FF", "56CCF2FF",
        "F2994AFF", "6FCF97FF", "BB6BD9FF", "219653FF", "BDBDBDFF", "333333FF"
    ]
}

enum DecimalFormatter {
    static func string(from value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(value)"
    }
    
    static func editingString(from value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(value)"
    }
    
    static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let locale = Locale.current
        var cleaned = trimmed.replacingOccurrences(of: " ", with: "")
        if let grouping = locale.groupingSeparator, !grouping.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: grouping, with: "")
        }
        if let decimal = locale.decimalSeparator, decimal != "." {
            cleaned = cleaned.replacingOccurrences(of: decimal, with: ".")
        }
        let allowed = CharacterSet(charactersIn: "0123456789.")
        if cleaned.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }
        return Decimal(string: cleaned)
    }
}

enum DateFormatterCache {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
    
    static let dayShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
    
    static let dayShortYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
    
    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
    
    static let year: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()
    
    static let export: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct SummaryComparisonView: View {
    let currentTotal: Decimal
    let previousTotal: Decimal
    let currency: String
    let isNumbersHidden: Bool
    
    var body: some View {
        let delta = currentTotal - previousTotal
        let percent = previousTotal == 0 ? nil :
            (NSDecimalNumber(decimal: delta).doubleValue / NSDecimalNumber(decimal: previousTotal).doubleValue * 100)
        
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Current")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayAmount(currentTotal))
                    .font(.headline)
            }
            HStack {
                Text("Previous")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayAmount(previousTotal))
                    .font(.subheadline)
            }
            HStack {
                Text("Change")
                    .foregroundStyle(.secondary)
                Spacer()
                if isNumbersHidden {
                    Text("***")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(changeLabel(delta: delta, percent: percent))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(delta >= 0 ? .green : .red)
                }
            }
        }
    }
    
    private func displayAmount(_ amount: Decimal) -> String {
        if isNumbersHidden { return "*** \(currency)" }
        return "\(DecimalFormatter.string(from: amount)) \(currency)"
    }
    
    private func changeLabel(delta: Decimal, percent: Double?) -> String {
        let sign = delta >= 0 ? "+" : "-"
        let absDelta = delta >= 0 ? delta : -delta
        let deltaText = DecimalFormatter.string(from: absDelta)
        if let percent {
            return "\(sign)\(deltaText) \(currency) (\(String(format: "%.1f", abs(percent)))%)"
        }
        return "\(sign)\(deltaText) \(currency)"
    }
}

struct WalletDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    
    let wallet: Wallet
    @ObservedObject var rateService: RateService
    
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @State private var isAddingTransaction = false
    
    private var walletTransactions: [Transaction] {
        transactions.filter { $0.wallet?.persistentModelID == wallet.persistentModelID }
    }
    
    private var walletTotalInBase: Decimal? {
        rateService.convert(
            amount: wallet.balance,
            from: wallet.assetCode,
            kind: wallet.kind,
            to: baseCurrencyCode
        )
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Balance") {
                    HStack {
                        Text(wallet.name)
                        Spacer()
                        if isNumbersHidden {
                            Text("*** \(wallet.assetCode)")
                        } else {
                            Text("\(DecimalFormatter.string(from: wallet.balance)) \(wallet.assetCode)")
                        }
                    }
                    if let walletTotalInBase, baseCurrencyCode != wallet.assetCode {
                        HStack {
                            Text("≈ \(baseCurrencyCode)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isNumbersHidden {
                                Text("*** \(baseCurrencyCode)")
                            } else {
                                Text("\(DecimalFormatter.string(from: walletTotalInBase)) \(baseCurrencyCode)")
                            }
                        }
                    }
                }
                
                Section("Transactions") {
                    if walletTransactions.isEmpty {
                        Text("No transactions yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(walletTransactions, id: \.persistentModelID) { transaction in
                            TransactionRow(transaction: transaction)
                        }
                    }
                }
            }
            .navigationTitle(wallet.name)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isAddingTransaction = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingTransaction) {
                AddTransactionView(
                    defaultCurrencyCode: wallet.assetCode,
                    preselectedWalletID: wallet.persistentModelID
                )
            }
            .task {
                await rateService.refreshAllRates(base: baseCurrencyCode, wallets: [wallet], force: false)
            }
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.category?.name ?? "Uncategorized")
                    .font(.headline)
                Text(transaction.note?.isEmpty == false ? transaction.note! : "No comment")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let wallet = transaction.wallet {
                    Text(wallet.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isNumbersHidden {
                    Text("*** \(transaction.currencyCode)")
                        .font(.headline)
                } else {
                    Text("\(DecimalFormatter.string(from: transaction.amount)) \(transaction.currencyCode)")
                        .font(.headline)
                }
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AddCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    private let category: Category?
    
    @State private var name: String
    @State private var type: CategoryType
    @State private var colorHex: String
    
    init(category: Category? = nil) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _type = State(initialValue: category?.type ?? .expense)
        _colorHex = State(initialValue: category?.colorHex ?? "2F80EDFF")
    }
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Category name", text: $name)
                }
                
                Section("Type") {
                    Picker("Type", selection: $type) {
                        Text("Expenses").tag(CategoryType.expense)
                        Text("Income").tag(CategoryType.income)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(CategoryColorPalette.all, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(colorHex == hex ? 0.8 : 0), lineWidth: 2)
                                )
                                .onTapGesture { colorHex = hex }
                        }
                    }
                }
            }
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveCategory()
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
    
    private func saveCategory() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let category {
            category.name = trimmed
            category.type = type
            category.colorHex = colorHex
            category.updatedAt = Date()
        } else {
            let newCategory = Category(
                name: trimmed,
                type: type,
                colorHex: colorHex
            )
            modelContext.insert(newCategory)
        }
    }
}

struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Wallet.name) private var wallets: [Wallet]
    
    private let transaction: Transaction?
    private let defaultCurrencyCode: String
    
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var date: Date
    @State private var note: String
    @State private var selectedCategoryID: PersistentIdentifier?
    @State private var selectedWalletID: PersistentIdentifier?
    @State private var transactionType: TransactionType
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoData: Data?
    
    private let originalWalletID: PersistentIdentifier?
    private let originalAmount: Decimal
    private let originalType: TransactionType
    
    init(transaction: Transaction? = nil, defaultCurrencyCode: String, preselectedWalletID: PersistentIdentifier? = nil) {
        self.transaction = transaction
        self.defaultCurrencyCode = defaultCurrencyCode
        _amountText = State(initialValue: transaction.map { DecimalFormatter.editingString(from: $0.amount) } ?? "")
        _currencyCode = State(initialValue: transaction?.currencyCode ?? defaultCurrencyCode)
        _date = State(initialValue: transaction?.date ?? Date())
        _note = State(initialValue: transaction?.note ?? "")
        _selectedCategoryID = State(initialValue: transaction?.category?.persistentModelID)
        _selectedWalletID = State(initialValue: transaction?.wallet?.persistentModelID ?? preselectedWalletID)
        _transactionType = State(initialValue: transaction?.type ?? .expense)
        _photoData = State(initialValue: transaction?.photoData)
        
        originalWalletID = transaction?.wallet?.persistentModelID
        originalAmount = transaction?.amount ?? 0
        originalType = transaction?.type ?? .expense
    }
    
    private var canSave: Bool {
        parsedAmount != nil && selectedCategoryID != nil && selectedWalletID != nil
    }
    
    private var parsedAmount: Decimal? {
        let amount = DecimalFormatter.parse(amountText)
        if let amount, amount > 0 {
            return amount
        }
        return nil
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $transactionType) {
                        Text("Expenses").tag(TransactionType.expense)
                        Text("Income").tag(TransactionType.income)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Wallet") {
                    Picker("Wallet", selection: $selectedWalletID) {
                        Text("Select wallet").tag(PersistentIdentifier?.none)
                        ForEach(wallets, id: \.persistentModelID) { wallet in
                            Text(wallet.name)
                                .tag(Optional(wallet.persistentModelID))
                        }
                    }
                }
                
                Section("Amount") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                }
                
                Section("Currency") {
                    Text(selectedWalletID == nil ? "Select wallet to set currency" : currencyCode)
                        .foregroundStyle(.secondary)
                }
                
                Section("Category") {
                    Picker("Category", selection: $selectedCategoryID) {
                        Text("Select category").tag(PersistentIdentifier?.none)
                        ForEach(filteredCategories, id: \.persistentModelID) { category in
                            Text(category.name)
                                .tag(Optional(category.persistentModelID))
                        }
                    }
                }
                
                Section("Date") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
                
                Section("Comment") {
                    TextField("Add a comment", text: $note, axis: .vertical)
                }
                
                Section("Photo") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Select Photo", systemImage: "photo")
                    }
                    if let photoData, let image = platformImage(from: photoData) {
                        platformImageView(image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                    }
                }
            }
            .navigationTitle(transaction == nil ? "New Transaction" : "Edit Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTransaction()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: selectedPhotoItem) {
                Task { await loadPhoto() }
            }
            .onChange(of: selectedWalletID) {
                applyWalletSelection()
            }
            .onAppear {
                normalizeSelections()
            }
            .onChange(of: transactionType) {
                if let selectedCategoryID,
                   let selectedCategory = categories.first(where: { $0.persistentModelID == selectedCategoryID }),
                   selectedCategory.type != categoryTypeFromTransactionType() {
                    self.selectedCategoryID = nil
                }
            }
        }
    }
    
    private func saveTransaction() {
        guard let amount = parsedAmount else { return }
        guard let selectedCategoryID else { return }
        guard let selectedWalletID else { return }
        let selectedCategory = categories.first { $0.persistentModelID == selectedCategoryID }
        let selectedWallet = wallets.first { $0.persistentModelID == selectedWalletID }
        
        applyWalletChanges(newWallet: selectedWallet, newAmount: amount, newType: transactionType)
        
        if let transaction {
            transaction.amount = amount
            transaction.currencyCode = currencyCode
            transaction.date = date
            transaction.note = note.isEmpty ? nil : note
            transaction.type = transactionType
            transaction.photoData = photoData
            transaction.category = selectedCategory
            transaction.wallet = selectedWallet
        } else {
            let newTransaction = Transaction(
                amount: amount,
                currencyCode: currencyCode,
                date: date,
                note: note.isEmpty ? nil : note,
                type: transactionType,
                photoData: photoData,
                category: selectedCategory,
                wallet: selectedWallet
            )
            modelContext.insert(newTransaction)
        }
    }
    
    private func loadPhoto() async {
        guard let selectedPhotoItem else { return }
        if let data = try? await selectedPhotoItem.loadTransferable(type: Data.self) {
            await MainActor.run {
                photoData = data
            }
        }
    }
    
    private func platformImage(from data: Data) -> PlatformImage? {
#if canImport(UIKit)
        UIImage(data: data)
#else
        NSImage(data: data)
#endif
    }
    
    private func platformImageView(_ image: PlatformImage) -> Image {
#if canImport(UIKit)
        Image(uiImage: image)
#else
        Image(nsImage: image)
#endif
    }
    
    private var filteredCategories: [Category] {
        let expectedType = categoryTypeFromTransactionType()
        return categories.filter { $0.type == expectedType }
    }
    
    private func categoryTypeFromTransactionType() -> CategoryType {
        switch transactionType {
        case .expense: return .expense
        case .income: return .income
        }
    }
    
    private func applyWalletSelection() {
        guard let selectedWalletID,
              let wallet = wallets.first(where: { $0.persistentModelID == selectedWalletID }) else {
            return
        }
        currencyCode = wallet.assetCode
    }
    
    private func normalizeSelections() {
        if let selectedWalletID,
           wallets.first(where: { $0.persistentModelID == selectedWalletID }) == nil {
            self.selectedWalletID = nil
        }
        if let selectedCategoryID,
           categories.first(where: { $0.persistentModelID == selectedCategoryID }) == nil {
            self.selectedCategoryID = nil
        }
        if let selectedCategoryID,
           let category = categories.first(where: { $0.persistentModelID == selectedCategoryID }) {
            let inferredType: TransactionType = category.type == .income ? .income : .expense
            if transactionType != inferredType {
                transactionType = inferredType
            }
        }
        applyWalletSelection()
    }
    
    private func applyWalletChanges(newWallet: Wallet?, newAmount: Decimal, newType: TransactionType) {
        if let originalWalletID,
           let originalWallet = wallets.first(where: { $0.persistentModelID == originalWalletID }) {
            adjust(wallet: originalWallet, amount: originalAmount, type: originalType, reversing: true)
        }
        
        if let newWallet {
            adjust(wallet: newWallet, amount: newAmount, type: newType, reversing: false)
        }
    }
    
    private func adjust(wallet: Wallet, amount: Decimal, type: TransactionType, reversing: Bool) {
        var delta = amount
        if type == .expense {
            delta = -delta
        }
        if reversing {
            delta = -delta
        }
        wallet.balance += delta
    }
}

struct AddWalletView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    private let wallet: Wallet?
    private let defaultCurrencyCode: String
    
    @State private var name: String
    @State private var kind: AssetKind
    @State private var assetCode: String
    @State private var balanceText: String
    
    init(wallet: Wallet? = nil, defaultCurrencyCode: String) {
        self.wallet = wallet
        self.defaultCurrencyCode = defaultCurrencyCode
        _name = State(initialValue: wallet?.name ?? "")
        _kind = State(initialValue: wallet?.kind ?? .fiat)
        _assetCode = State(initialValue: wallet?.assetCode ?? defaultCurrencyCode)
        _balanceText = State(initialValue: wallet.map { DecimalFormatter.editingString(from: $0.balance) } ?? "")
    }
    
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedBalance != nil
    }
    
    private var parsedBalance: Decimal? {
        let value = DecimalFormatter.parse(balanceText)
        if let value, value >= 0 {
            return value
        }
        return nil
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Wallet name", text: $name)
                }
                
                Section("Type") {
                    Picker("Type", selection: $kind) {
                        Text("Fiat").tag(AssetKind.fiat)
                        Text("Crypto").tag(AssetKind.crypto)
                        Text("Metal").tag(AssetKind.metal)
                        Text("Stock").tag(AssetKind.stock)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Asset") {
                    if kind == .stock {
                        TextField("Ticker (e.g. AAPL)", text: $assetCode)
                            .textInputAutocapitalization(.characters)
                    } else {
                        Picker("Asset", selection: $assetCode) {
                            ForEach(CurrencyCatalog.allCurrencies.filter { $0.kind == kind }, id: \.code) { item in
                                Text("\(item.code) — \(item.name)")
                                    .tag(item.code)
                            }
                        }
                    }
                }
                
                Section("Balance") {
                    TextField("0.00", text: $balanceText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle(wallet == nil ? "New Wallet" : "Edit Wallet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveWallet()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: kind) {
                switch kind {
                case .fiat:
                    assetCode = defaultCurrencyCode
                case .crypto:
                    assetCode = "BTC"
                case .metal:
                    assetCode = "XAU"
                case .stock:
                    assetCode = ""
                }
            }
        }
    }
    
    private func saveWallet() {
        guard let balance = parsedBalance else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAsset = assetCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        
        if let wallet {
            wallet.name = trimmedName
            wallet.kind = kind
            wallet.assetCode = trimmedAsset
            wallet.balance = balance
            wallet.updatedAt = Date()
        } else {
            let newWallet = Wallet(
                name: trimmedName,
                assetCode: trimmedAsset,
                kind: kind,
                balance: balance
            )
            modelContext.insert(newWallet)
        }
    }
}

struct TotalsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCodes: Set<String>
    let baseCurrencyCode: String
    let onSave: ([String]) -> Void
    
    init(selectedCodes: [String], baseCurrencyCode: String, onSave: @escaping ([String]) -> Void) {
        self.baseCurrencyCode = baseCurrencyCode
        self.onSave = onSave
        _selectedCodes = State(initialValue: Set(selectedCodes))
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(CurrencyCatalog.baseCurrencies, id: \.code) { currency in
                    HStack {
                        Text("\(currency.code) — \(currency.name)")
                        Spacer()
                        if selectedCodes.contains(currency.code) {
                            Image(systemName: "checkmark")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggle(currency.code)
                    }
                }
            }
            .navigationTitle("Total Currencies")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let ordered = CurrencyCatalog.baseCurrencies
                            .map(\.code)
                            .filter { selectedCodes.contains($0) }
                        onSave(ordered)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if selectedCodes.isEmpty {
                    selectedCodes.insert(baseCurrencyCode)
                }
            }
        }
    }
    
    private func toggle(_ code: String) {
        if selectedCodes.contains(code) {
            selectedCodes.remove(code)
        } else {
            selectedCodes.insert(code)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Category.self, Transaction.self, Asset.self, Wallet.self], inMemory: true)
}
