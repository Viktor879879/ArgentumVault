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
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("didShowOnboarding") private var didShowOnboarding = false
    @AppStorage("forceShowOnboardingOnce_v4") private var forceShowOnboardingOnce = true
    @AppStorage("didRunMigration_v1") private var didRunMigration = false
    @StateObject private var rateService = RateService()
    @State private var showSplash = true
    @State private var showOnboarding = false
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private var interactiveTint: Color {
        .secondary
    }
    
    var body: some View {
        ZStack {
            if baseCurrencyCode.isEmpty {
                BaseCurrencySetupView()
            } else {
                TabView {
                    HomeView(rateService: rateService)
                        .tabItem {
                            Label(L10n.text("tab.home", lang: uiLanguageCode), systemImage: "house.fill")
                        }
                    
                    AnalyticsView(rateService: rateService)
                        .tabItem {
                            Label(L10n.text("tab.analytics", lang: uiLanguageCode), systemImage: "chart.pie.fill")
                        }
                    
                    SettingsView()
                        .tabItem {
                            Label(L10n.text("tab.settings", lang: uiLanguageCode), systemImage: "gearshape.fill")
                        }
                }
            }
            
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .dismissKeyboardOnTap()
        .tint(interactiveTint)
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
                if !didShowOnboarding || forceShowOnboardingOnce {
                    showOnboarding = true
                }
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(lang: uiLanguageCode) {
                didShowOnboarding = true
                forceShowOnboardingOnce = false
                showOnboarding = false
            }
        }
        .environment(\.locale, currentLocale)
        .preferredColorScheme(AppTheme.colorScheme(from: appTheme))
    }
    
    private var currentLocale: Locale {
        if appLanguageCode == "system" {
            return .autoupdatingCurrent
        }
        return Locale(identifier: appLanguageCode)
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
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @State private var selection = CurrencyCatalog.baseCurrencies.first?.code ?? "USD"
    
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("settings.base_currency", lang: uiLanguageCode)) {
                    Picker(L10n.text("settings.currency", lang: uiLanguageCode), selection: $selection) {
                        ForEach(CurrencyCatalog.baseCurrencies, id: \.code) { currency in
                            Text(L10n.currencyDisplay(code: currency.code, fallbackName: currency.name, lang: uiLanguageCode))
                                .tag(currency.code)
                        }
                    }
                }
                
                Section {
                    Button(L10n.text("setup.continue", lang: uiLanguageCode)) {
                        baseCurrencyCode = selection
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle(L10n.text("setup.welcome", lang: uiLanguageCode))
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("totalCurrencies") private var totalCurrenciesStorage = ""
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    @AppStorage("isRoundedAmounts") private var isRoundedAmounts = false
    
    @ObservedObject var rateService: RateService
    
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Wallet.name) private var wallets: [Wallet]
    @Query(sort: \WalletFolder.name) private var walletFolders: [WalletFolder]
    
    @State private var isAddingTransaction = false
    @State private var editingTransaction: Transaction?
    @State private var isAddingWallet = false
    @State private var isAddingWalletFolder = false
    @State private var editingWalletFolder: WalletFolder?
    @State private var editingWallet: Wallet?
    @State private var viewingWallet: Wallet?
    @State private var isManagingTotals = false
    @State private var walletToDeleteName: String?
    @State private var walletToDeleteAssetCode: String?
    @State private var showDeleteWalletConfirm = false
    @State private var collapsedFolderIDs: Set<PersistentIdentifier> = []
    @State private var knownFolderIDs: Set<PersistentIdentifier> = []
    @State private var didInitializeFolderCollapse = false
    
    private var ungroupedWallets: [Wallet] {
        wallets.filter { $0.folder == nil }
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
        unique.removeAll { $0 == baseCurrencyCode }
        unique.insert(baseCurrencyCode, at: 0)
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
                        lang: uiLanguageCode,
                        totalCurrencies: totalCurrencies,
                        baseCurrencyCode: baseCurrencyCode,
                        wallets: wallets,
                        rateService: rateService,
                        addAction: { isManagingTotals = true },
                        isNumbersHidden: isNumbersHidden,
                        isRoundedAmounts: isRoundedAmounts
                    )
                }
                
                Section {
                    WalletsHeader(
                        lang: uiLanguageCode,
                        addAction: {
                            isAddingWalletFolder = false
                            isAddingWallet = true
                        },
                        addFolderAction: {
                            isAddingWallet = false
                            isAddingWalletFolder = true
                        }
                    )
                    
                    if wallets.isEmpty {
                        Text(L10n.text("home.no_wallets", lang: uiLanguageCode))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(walletFolders, id: \.persistentModelID) { folder in
                            let folderWallets = wallets.filter { $0.folder?.persistentModelID == folder.persistentModelID }
                            if !folderWallets.isEmpty {
                                let isExpanded = !collapsedFolderIDs.contains(folder.persistentModelID)
                                HStack {
                                    Button {
                                        toggleFolder(folder)
                                    } label: {
                                        HStack {
                                            Text(folder.name)
                                            Spacer()
                                            Text("\(folderWallets.count)")
                                                .foregroundStyle(.secondary)
                                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(L10n.text("common.delete", lang: uiLanguageCode), role: .destructive) {
                                        deleteWalletFolder(folder)
                                    }
                                    .tint(.red)
                                    Button(L10n.text("common.edit", lang: uiLanguageCode)) {
                                        editingWalletFolder = folder
                                    }
                                    .tint(Color(hex: "4A4A4AFF"))
                                }
                                
                                if isExpanded {
                                    ForEach(folderWallets, id: \.persistentModelID) { wallet in
                                        walletRowItem(wallet)
                                    }
                                }
                            }
                        }
                        
                        if !ungroupedWallets.isEmpty {
                            if !walletFolders.isEmpty {
                                Text(L10n.text("home.ungrouped", lang: uiLanguageCode))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(ungroupedWallets, id: \.persistentModelID) { wallet in
                                walletRowItem(wallet)
                            }
                        }
                    }
                }
                
                Section(L10n.text("home.transaction_history", lang: uiLanguageCode)) {
                    if transactions.isEmpty {
                        Text(L10n.text("home.no_transactions", lang: uiLanguageCode))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transactions, id: \.persistentModelID) { transaction in
                            TransactionRow(transaction: transaction)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingTransaction = transaction
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(L10n.text("common.delete", lang: uiLanguageCode), role: .destructive) {
                                        deleteTransaction(transaction)
                                    }
                                    .tint(.red)
                                    Button(L10n.text("common.edit", lang: uiLanguageCode)) {
                                        editingTransaction = transaction
                                    }
                                    .tint(Color(hex: "4A4A4AFF"))
                                }
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("app.name", lang: uiLanguageCode))
            .onAppear {
                initializeFolderCollapseIfNeeded()
            }
            .onChange(of: walletFolders.count) {
                syncFolderCollapseState()
            }
            .onChange(of: baseCurrencyCode) {
                Task { await rateService.refreshAllRates(base: baseCurrencyCode, wallets: wallets, force: true) }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isNumbersHidden.toggle()
                    } label: {
                        Image(systemName: isNumbersHidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(L10n.text("a11y.toggle_privacy", lang: uiLanguageCode))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await rateService.refreshAllRates(base: baseCurrencyCode, wallets: wallets, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(L10n.text("a11y.refresh_rates", lang: uiLanguageCode))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isAddingTransaction = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel(L10n.text("a11y.add_transaction", lang: uiLanguageCode))
                }
            }
            .task {
                await rateService.refreshAllRates(base: baseCurrencyCode, wallets: wallets, force: false)
            }
            .sheet(isPresented: $isAddingTransaction) {
                AddTransactionView(defaultCurrencyCode: baseCurrencyCode, rateService: rateService)
            }
            .sheet(
                isPresented: Binding(
                    get: { editingTransaction != nil },
                    set: { if !$0 { editingTransaction = nil } }
                )
            ) {
                if let editingTransaction {
                    AddTransactionView(
                        transaction: editingTransaction,
                        defaultCurrencyCode: baseCurrencyCode,
                        rateService: rateService
                    )
                }
            }
            .sheet(isPresented: $isAddingWallet) {
                AddWalletView(defaultCurrencyCode: baseCurrencyCode)
            }
            .sheet(isPresented: $isAddingWalletFolder) {
                AddWalletFolderView()
            }
            .sheet(
                isPresented: Binding(
                    get: { editingWalletFolder != nil },
                    set: { if !$0 { editingWalletFolder = nil } }
                )
            ) {
                if let editingWalletFolder {
                    AddWalletFolderView(folder: editingWalletFolder)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { editingWallet != nil },
                    set: { if !$0 { editingWallet = nil } }
                )
            ) {
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
            .alert(
                L10n.text("home.delete_wallet_title", lang: uiLanguageCode),
                isPresented: $showDeleteWalletConfirm
            ) {
                Button(L10n.text("common.cancel", lang: uiLanguageCode), role: .cancel) {}
                Button(L10n.text("common.delete", lang: uiLanguageCode), role: .destructive) {
                    guard let walletName = walletToDeleteName,
                          let assetCode = walletToDeleteAssetCode,
                          let wallet = wallets.first(where: { $0.name == walletName && $0.assetCode == assetCode }) else {
                        walletToDeleteName = nil
                        walletToDeleteAssetCode = nil
                        return
                    }
                    for transaction in transactions {
                        if transaction.wallet?.persistentModelID == wallet.persistentModelID ||
                            (transaction.walletNameSnapshot == wallet.name && transaction.currencyCode == wallet.assetCode) {
                            transaction.wallet = nil
                        }
                        if transaction.transferWallet?.persistentModelID == wallet.persistentModelID ||
                            (transaction.transferWalletNameSnapshot == wallet.name && transaction.transferWalletCurrencyCode == wallet.assetCode) {
                            transaction.transferWallet = nil
                        }
                    }
                    modelContext.delete(wallet)
                    walletToDeleteName = nil
                    walletToDeleteAssetCode = nil
                }
            } message: {
                Text(L10n.text("home.delete_wallet_message", lang: uiLanguageCode))
            }
        }
    }
    
    private func deleteTransaction(_ transaction: Transaction) {
        let type = transaction.type ?? .expense
        let sourceWallet = transaction.wallet ?? wallets.first(where: {
            $0.name == transaction.walletNameSnapshot && $0.assetCode == transaction.currencyCode
        })
        let destinationWallet = transaction.transferWallet ?? wallets.first(where: {
            $0.name == transaction.transferWalletNameSnapshot && $0.assetCode == transaction.transferWalletCurrencyCode
        })
        
        switch type {
        case .expense:
            sourceWallet?.balance += transaction.amount
        case .income:
            sourceWallet?.balance -= transaction.amount
        case .transfer:
            sourceWallet?.balance += transaction.amount
            destinationWallet?.balance -= (transaction.transferAmount ?? transaction.amount)
        }
        modelContext.delete(transaction)
    }
    
    private func deleteWalletFolder(_ folder: WalletFolder) {
        for wallet in wallets where wallet.folder?.persistentModelID == folder.persistentModelID {
            wallet.folder = nil
        }
        collapsedFolderIDs.remove(folder.persistentModelID)
        modelContext.delete(folder)
    }
    
    private func toggleFolder(_ folder: WalletFolder) {
        if collapsedFolderIDs.contains(folder.persistentModelID) {
            collapsedFolderIDs.remove(folder.persistentModelID)
        } else {
            collapsedFolderIDs.insert(folder.persistentModelID)
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private func initializeFolderCollapseIfNeeded() {
        guard !didInitializeFolderCollapse else { return }
        let ids = Set(walletFolders.map(\.persistentModelID))
        collapsedFolderIDs = ids
        knownFolderIDs = ids
        didInitializeFolderCollapse = true
    }
    
    private func syncFolderCollapseState() {
        let currentIDs = Set(walletFolders.map(\.persistentModelID))
        let newIDs = currentIDs.subtracting(knownFolderIDs)
        if !newIDs.isEmpty {
            collapsedFolderIDs.formUnion(newIDs)
        }
        collapsedFolderIDs = collapsedFolderIDs.intersection(currentIDs)
        knownFolderIDs = currentIDs
    }
    
    @ViewBuilder
    private func walletRowItem(_ wallet: Wallet) -> some View {
        WalletRow(wallet: wallet)
            .contentShape(Rectangle())
            .onTapGesture {
                viewingWallet = wallet
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(L10n.text("common.delete", lang: uiLanguageCode), role: .destructive) {
                    walletToDeleteName = wallet.name
                    walletToDeleteAssetCode = wallet.assetCode
                    showDeleteWalletConfirm = true
                }
                .tint(.red)
                Button(L10n.text("common.edit", lang: uiLanguageCode)) {
                    editingWallet = wallet
                }
                .tint(Color(hex: "4A4A4AFF"))
            }
    }
}

struct TotalsHeader: View {
    let lang: String
    let totalCurrencies: [String]
    let baseCurrencyCode: String
    let wallets: [Wallet]
    let rateService: RateService
    let addAction: () -> Void
    let isNumbersHidden: Bool
    let isRoundedAmounts: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("home.total", lang: lang))
                    .font(.headline)
                Spacer()
                Button(action: addAction) {
                    Image(systemName: "plus.circle")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.text("a11y.add_total_currency", lang: lang))
            }
            
            if wallets.isEmpty {
                Text(L10n.text("home.add_wallets_for_total", lang: lang))
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
        let formatted = DecimalFormatter.string(from: total, maximumFractionDigits: isRoundedAmounts ? 0 : 2)
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
    let lang: String
    let addAction: () -> Void
    let addFolderAction: () -> Void
    
    var body: some View {
        HStack {
            Text(L10n.text("home.wallets", lang: lang))
                .font(.headline)
            Spacer()
            HStack(spacing: 16) {
                Button(action: addFolderAction) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.text("a11y.add_folder", lang: lang))
                
                Button(action: addAction) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.text("a11y.add_wallet", lang: lang))
            }
            .padding(.trailing, 2)
        }
    }
}

struct WalletRow: View {
    let wallet: Wallet
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("isRoundedAmounts") private var isRoundedAmounts = false
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(wallet.name)
                    .font(.headline)
                    .foregroundStyle(primaryWalletTextColor)
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isNumbersHidden {
                    Text("*** \(wallet.assetCode)")
                        .font(.headline)
                        .foregroundStyle(primaryWalletTextColor)
                } else {
                    Text("\(DecimalFormatter.string(from: wallet.balance, maximumFractionDigits: isRoundedAmounts ? 0 : 2)) \(wallet.assetCode)")
                        .font(.headline)
                        .foregroundStyle(primaryWalletTextColor)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(walletHighlightColor)
        )
    }
    
    private var kindLabel: String {
        switch wallet.kind {
        case .fiat: return L10n.text("wallet.kind.fiat", lang: uiLanguageCode)
        case .crypto: return L10n.text("wallet.kind.crypto", lang: uiLanguageCode)
        case .metal: return L10n.text("wallet.kind.metal", lang: uiLanguageCode)
        case .stock: return L10n.text("wallet.kind.stock", lang: uiLanguageCode)
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private var walletHex: String {
        wallet.colorHex ?? "FFFFFFFF"
    }
    
    private var isDefaultWalletColor: Bool {
        String(walletHex.prefix(6)).uppercased() == "FFFFFF"
    }
    
    private var walletHighlightColor: Color {
        guard !isDefaultWalletColor else { return .clear }
        return Color(hex: walletHex).opacity(0.22)
    }
    
    private var primaryWalletTextColor: Color {
        guard !isDefaultWalletColor else { return .primary }
        return Color(hex: walletHex)
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

enum AnalyticsMode: String, CaseIterable {
    case expense
    case net
    case income
    
    func title(lang: String) -> String {
        switch self {
        case .expense: return L10n.text("common.expenses", lang: lang)
        case .net: return L10n.text("analytics.net", lang: lang)
        case .income: return L10n.text("common.income", lang: lang)
        }
    }
}

struct AnalyticsView: View {
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    @ObservedObject var rateService: RateService
    
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Wallet.name) private var analyticsWallets: [Wallet]
    
    @State private var selectedMode: AnalyticsMode = .net
    @State private var selectedRange: AnalyticsRange = .month
    @State private var rangeAnchor: Date = Date()
    @State private var selectedWalletID: PersistentIdentifier?
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(L10n.text("analytics.mode", lang: uiLanguageCode), selection: $selectedMode) {
                        ForEach(AnalyticsMode.allCases, id: \.self) { mode in
                            Text(mode.title(lang: uiLanguageCode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    Picker(L10n.text("analytics.range", lang: uiLanguageCode), selection: $selectedRange) {
                        ForEach(AnalyticsRange.allCases, id: \.self) { range in
                            Text(range.title(lang: uiLanguageCode)).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    HStack {
                        Spacer()
                        Menu {
                            Button(L10n.text("analytics.all_wallets", lang: uiLanguageCode)) {
                                selectedWalletID = nil
                            }
                            ForEach(analyticsWallets, id: \.persistentModelID) { wallet in
                                Button(wallet.name) {
                                    selectedWalletID = wallet.persistentModelID
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedWalletTitle)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .tint(.secondary)
                        Spacer()
                    }
                    
                    HStack {
                        Button {
                            shiftToPast()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        .disabled(!canMoveBackward)
                        
                        Spacer()
                        Text(rangeLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Spacer()
                        
                        Button {
                            shiftToPresent()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.title3.weight(.semibold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        .disabled(!canMoveForward)
                    }
                }
                
                Section(L10n.text("analytics.summary", lang: uiLanguageCode)) {
                    SummaryComparisonView(
                        lang: uiLanguageCode,
                        currentTotal: currentTotal,
                        previousTotal: previousTotal,
                        currency: baseCurrencyCode,
                        isNumbersHidden: isNumbersHidden,
                        mode: selectedMode
                    )
                    
                    if categoryTotals.isEmpty {
                        Text(L10n.text("analytics.no_data", lang: uiLanguageCode))
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(categoryTotals) { item in
                            SectorMark(
                                angle: .value("Amount", abs(NSDecimalNumber(decimal: item.amount).doubleValue)),
                                innerRadius: .ratio(0.6)
                            )
                            .foregroundStyle(item.color)
                        }
                        .frame(height: 260)
                        
                        ForEach(categoryTotals) { item in
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
                                        .foregroundStyle(item.amount < 0 ? .red : .green)
                                    Text(item.formattedPercent)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("tab.analytics", lang: uiLanguageCode))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isNumbersHidden.toggle()
                    } label: {
                        Image(systemName: isNumbersHidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(L10n.text("a11y.toggle_privacy", lang: uiLanguageCode))
                }
            }
        }
        .task {
            await rateService.refreshAllRates(base: baseCurrencyCode, wallets: analyticsWallets, force: false)
        }
        .onChange(of: selectedRange) {
            rangeAnchor = Date()
        }
        .onChange(of: baseCurrencyCode) {
            Task { await rateService.refreshAllRates(base: baseCurrencyCode, wallets: analyticsWallets, force: true) }
        }
    }
    
    private var categoryTotals: [CategoryTotal] {
        let dateRange = selectedRange.dateRange(anchor: rangeAnchor)
        let filtered = transactions.filter { transaction in
            guard let _ = transaction.category else { return false }
            if let selectedWalletKey {
                guard transaction.walletNameSnapshot == selectedWalletKey.name,
                      transaction.currencyCode == selectedWalletKey.assetCode else {
                    return false
                }
            }
            return transaction.date >= dateRange.start && transaction.date <= dateRange.end
        }
        
        var sums: [PersistentIdentifier: Decimal] = [:]
        var totalAbs = Decimal(0)
        for transaction in filtered {
            guard let category = transaction.category else { continue }
            let amount = signedConvertedAmount(for: transaction)
            if amount == 0 { continue }
            sums[category.persistentModelID, default: 0] += amount
            totalAbs += absDecimal(amount)
        }
        
        return categories
            .compactMap { category in
                guard let amount = sums[category.persistentModelID], amount != 0 else { return nil }
                return CategoryTotal(
                    id: category.persistentModelID,
                    name: category.name,
                    amount: amount,
                    color: Color(hex: category.colorHex),
                    total: totalAbs,
                    currency: baseCurrencyCode
                )
            }
            .sorted { absDecimal($0.amount) > absDecimal($1.amount) }
    }
    
    private var selectedWalletKey: (name: String, assetCode: String)? {
        guard let selectedWalletID,
              let wallet = analyticsWallets.first(where: { $0.persistentModelID == selectedWalletID }) else {
            return nil
        }
        return (wallet.name, wallet.assetCode)
    }
    
    private var currentTotal: Decimal {
        let dateRange = selectedRange.dateRange(anchor: rangeAnchor)
        return periodTotal(for: dateRange)
    }
    
    private var previousTotal: Decimal {
        var candidateAnchor = selectedRange.shift(anchor: rangeAnchor, by: -1)
        while selectedRange.dateRange(anchor: candidateAnchor).start >= minAnchorStart {
            let dateRange = selectedRange.dateRange(anchor: candidateAnchor)
            let total = periodTotal(for: dateRange)
            if total != 0 {
                return total
            }
            let next = selectedRange.shift(anchor: candidateAnchor, by: -1)
            if next == candidateAnchor {
                break
            }
            candidateAnchor = next
        }
        return 0
    }
    
    private var rangeLabel: String {
        selectedRange.label(anchor: rangeAnchor, lang: uiLanguageCode)
    }
    
    private var selectedWalletTitle: String {
        if let selectedWalletID,
           let wallet = analyticsWallets.first(where: { $0.persistentModelID == selectedWalletID }) {
            return wallet.name
        }
        return L10n.text("analytics.all_wallets", lang: uiLanguageCode)
    }
    
    private var canMoveBackward: Bool {
        currentAnchorStart > minAnchorStart
    }
    
    private var canMoveForward: Bool {
        currentAnchorStart < maxAnchorStart
    }
    
    private func shiftToPast() {
        shiftRange(by: -1)
    }
    
    private func shiftToPresent() {
        shiftRange(by: 1)
    }
    
    private func shiftRange(by value: Int) {
        let moved = selectedRange.shift(anchor: rangeAnchor, by: value)
        let movedStart = selectedRange.dateRange(anchor: moved).start
        if movedStart <= minAnchorStart {
            rangeAnchor = minAnchorStart
        } else if movedStart >= maxAnchorStart {
            rangeAnchor = maxAnchorStart
        } else {
            rangeAnchor = moved
        }
    }
    
    private func periodTotal(for dateRange: (start: Date, end: Date)) -> Decimal {
        var total = Decimal(0)
        for transaction in transactions {
            guard transaction.date >= dateRange.start && transaction.date <= dateRange.end else { continue }
            if let selectedWalletKey {
                guard transaction.walletNameSnapshot == selectedWalletKey.name,
                      transaction.currencyCode == selectedWalletKey.assetCode else {
                    continue
                }
            }
            total += signedConvertedAmount(for: transaction)
        }
        return total
    }
    
    private func signedConvertedAmount(for transaction: Transaction) -> Decimal {
        if transaction.type == .transfer {
            return 0
        }
        guard let category = transaction.category else { return 0 }
        let type = transaction.type ?? (category.type == .income ? .income : .expense)
        let converted = rateService.convert(
            amount: transaction.amount,
            from: transaction.currencyCode,
            kind: kindForTransaction(transaction),
            to: baseCurrencyCode
        ) ?? transaction.amount
        
        switch selectedMode {
        case .income:
            return type == .income ? absDecimal(converted) : 0
        case .expense:
            return type == .expense ? -absDecimal(converted) : 0
        case .net:
            return type == .income ? absDecimal(converted) : -absDecimal(converted)
        }
    }
    
    private func kindForTransaction(_ transaction: Transaction) -> AssetKind {
        if let raw = transaction.walletKindRaw,
           let kind = AssetKind(rawValue: raw) {
            return kind
        }
        if CurrencyCatalog.allCurrencies.contains(where: { $0.code == transaction.currencyCode && $0.kind == .crypto }) {
            return .crypto
        }
        if CurrencyCatalog.allCurrencies.contains(where: { $0.code == transaction.currencyCode && $0.kind == .metal }) {
            return .metal
        }
        if CurrencyCatalog.allCurrencies.contains(where: { $0.code == transaction.currencyCode && $0.kind == .fiat }) {
            return .fiat
        }
        return .stock
    }
    
    private func absDecimal(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
    
    private var currentAnchorStart: Date {
        selectedRange.dateRange(anchor: rangeAnchor).start
    }
    
    private var maxAnchorStart: Date {
        selectedRange.dateRange(anchor: Date()).start
    }
    
    private var minAnchorStart: Date {
        Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? Date.distantPast
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
}

enum AnalyticsRange: CaseIterable {
    case day
    case week
    case month
    case year
    
    func title(lang: String) -> String {
        switch self {
        case .day: return L10n.text("analytics.day", lang: lang)
        case .week: return L10n.text("analytics.week", lang: lang)
        case .month: return L10n.text("analytics.month", lang: lang)
        case .year: return L10n.text("analytics.year", lang: lang)
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
    
    func label(anchor: Date, lang: String) -> String {
        switch self {
        case .day:
            return DateFormatterCache.day(lang: lang).string(from: anchor)
        case .week:
            let range = dateRange(anchor: anchor)
            let startDay = DateFormatterCache.dayShort(lang: lang).string(from: range.start)
            let endDay = DateFormatterCache.dayShortYear(lang: lang).string(from: range.end)
            return "\(startDay) – \(endDay)"
        case .month:
            return DateFormatterCache.monthYear(lang: lang).string(from: anchor)
        case .year:
            return DateFormatterCache.year(lang: lang).string(from: anchor)
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
        let percent = (absDecimal(amount) as NSDecimalNumber).doubleValue / (total as NSDecimalNumber).doubleValue * 100
        return String(format: "%.0f%%", percent)
    }
    
    private func absDecimal(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
}

enum CategoryColorPalette {
    static let all: [String] = [
        "2F80EDFF", "27AE60FF", "F2C94CFF", "EB5757FF", "9B51E0FF",
        "56CCF2FF", "F2994AFF", "6FCF97FF", "00ACC1FF", "BDBDBDFF"
    ]
}

enum DecimalFormatter {
    static func string(from value: Decimal, maximumFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.secondaryGroupingSize = 3
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(value)"
    }
    
    static func editingString(from value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.decimalSeparator = "."
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(value)"
    }
    
    static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        
        var cleaned = trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "_", with: "")
        
        let lastComma = cleaned.lastIndex(of: ",")
        let lastDot = cleaned.lastIndex(of: ".")
        
        if let comma = lastComma, let dot = lastDot {
            if comma > dot {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if lastComma != nil {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        
        let allowed = CharacterSet(charactersIn: "0123456789.")
        if cleaned.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }
        if cleaned.filter({ $0 == "." }).count > 1 {
            return nil
        }
        return Decimal(string: cleaned)
    }
}

enum DateFormatterCache {
    static func locale(for lang: String) -> Locale {
        if ["en", "ru", "uk", "sv"].contains(lang) {
            return Locale(identifier: lang)
        }
        return .autoupdatingCurrent
    }
    
    static func day(lang: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = locale(for: lang)
        return formatter
    }
    
    static func dayShort(lang: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.locale = locale(for: lang)
        return formatter
    }
    
    static func dayShortYear(lang: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = locale(for: lang)
        return formatter
    }
    
    static func monthYear(lang: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        formatter.locale = locale(for: lang)
        return formatter
    }
    
    static func year(lang: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        formatter.locale = locale(for: lang)
        return formatter
    }
    
    static let export: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct SummaryComparisonView: View {
    let lang: String
    let currentTotal: Decimal
    let previousTotal: Decimal
    let currency: String
    let isNumbersHidden: Bool
    let mode: AnalyticsMode
    
    var body: some View {
        let delta = currentTotal - previousTotal
        let percent: Double = {
            if previousTotal == 0 {
                return 0
            }
            return NSDecimalNumber(decimal: delta).doubleValue / NSDecimalNumber(decimal: previousTotal).doubleValue * 100
        }()
        
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("analytics.current", lang: lang))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayAmount(currentTotal))
                    .font(.headline)
                    .foregroundStyle(amountColor(currentTotal))
            }
            HStack {
                Text(L10n.text("analytics.previous", lang: lang))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayAmount(previousTotal))
                    .font(.subheadline)
                    .foregroundStyle(amountColor(previousTotal))
            }
            HStack {
                Text(L10n.text("analytics.change", lang: lang))
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
        let sign = amount > 0 ? "+" : amount < 0 ? "-" : ""
        return "\(sign)\(DecimalFormatter.string(from: absDecimal(amount))) \(currency)"
    }
    
    private func changeLabel(delta: Decimal, percent: Double) -> String {
        let sign = delta >= 0 ? "+" : "-"
        let absDelta = delta >= 0 ? delta : -delta
        let deltaText = DecimalFormatter.string(from: absDelta)
        return "\(sign)\(deltaText) \(currency) (\(String(format: "%.1f", abs(percent)))%)"
    }
    
    private func amountColor(_ value: Decimal) -> Color {
        switch mode {
        case .expense:
            return .red
        case .income:
            return .green
        case .net:
            if value > 0 { return .green }
            if value < 0 { return .red }
            return .primary
        }
    }
    
    private func absDecimal(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
}

struct WalletDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    
    let wallet: Wallet
    @ObservedObject var rateService: RateService
    
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @State private var isAddingTransaction = false
    
    private var walletTransactions: [Transaction] {
        transactions.filter {
            ($0.walletNameSnapshot == wallet.name && $0.currencyCode == wallet.assetCode) ||
            ($0.transferWalletNameSnapshot == wallet.name && $0.transferWalletCurrencyCode == wallet.assetCode)
        }
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
                Section(L10n.text("wallet.balance", lang: uiLanguageCode)) {
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
                
                Section(L10n.text("home.transaction_history", lang: uiLanguageCode)) {
                    if walletTransactions.isEmpty {
                        Text(L10n.text("home.no_transactions", lang: uiLanguageCode))
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
                    Button(L10n.text("common.close", lang: uiLanguageCode)) { dismiss() }
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
                    preselectedWalletID: wallet.persistentModelID,
                    rateService: rateService
                )
            }
            .task {
                await rateService.refreshAllRates(base: baseCurrencyCode, wallets: [wallet], force: false)
            }
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    @AppStorage("isNumbersHidden") private var isNumbersHidden = false
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("isRoundedAmounts") private var isRoundedAmounts = false
    
    private var signedAmount: Decimal {
        let inferredType: TransactionType = {
            if let type = transaction.type { return type }
            if transaction.category?.type == .income { return .income }
            return .expense
        }()
        switch inferredType {
        case .income:
            return transaction.amount
        case .expense:
            return -transaction.amount
        case .transfer:
            return 0
        }
    }
    
    private var transactionTypeResolved: TransactionType {
        if let type = transaction.type { return type }
        if transaction.category?.type == .income { return .income }
        return .expense
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(primaryTitle)
                    .font(.headline)
                if let note = transaction.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let walletSubtitle, !walletSubtitle.isEmpty {
                    Text(walletSubtitle)
                        .font(.caption)
                        .foregroundStyle(walletSubtitleColor)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isNumbersHidden {
                    Text("*** \(transaction.currencyCode)")
                        .font(.headline)
                } else {
                    if transactionTypeResolved == .transfer {
                        Text("\(DecimalFormatter.string(from: transaction.amount, maximumFractionDigits: isRoundedAmounts ? 0 : 2)) \(transaction.currencyCode)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else {
                        let sign = signedAmount >= 0 ? "+" : "-"
                        Text("\(sign)\(DecimalFormatter.string(from: absDecimal(signedAmount), maximumFractionDigits: isRoundedAmounts ? 0 : 2)) \(transaction.currencyCode)")
                            .font(.headline)
                            .foregroundStyle(signedAmount >= 0 ? .green : .red)
                    }
                }
                Text(formattedDate(transaction.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func absDecimal(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
    
    private var primaryTitle: String {
        if transactionTypeResolved == .transfer {
            return transferTitle
        }
        return transaction.category?.name ?? L10n.text("transaction.untagged", lang: uiLanguageCode)
    }
    
    private var transferTitle: String {
        L10n.text("common.transfer", lang: uiLanguageCode)
    }
    
    private var walletSubtitle: String? {
        if transactionTypeResolved == .transfer {
            let source = transaction.walletNameSnapshot ?? ""
            let destination = transaction.transferWalletNameSnapshot ?? ""
            guard !source.isEmpty || !destination.isEmpty else { return nil }
            return "\(source) -> \(destination)"
        }
        return transaction.walletNameSnapshot
    }
    
    private var walletSubtitleColor: Color {
        if transactionTypeResolved == .transfer {
            return .secondary
        }
        let hex = transaction.wallet?.colorHex ?? transaction.walletColorHexSnapshot ?? "FFFFFFFF"
        if String(hex.prefix(6)).uppercased() == "FFFFFF" {
            return .primary
        }
        return Color(hex: hex)
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = DateFormatterCache.locale(for: uiLanguageCode)
        return formatter.string(from: date)
    }
}

struct AddCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    
    private let category: Category?
    
    @State private var name: String
    @State private var type: CategoryType
    @State private var colorHex: String
    @State private var isShowingColorPicker = false
    @State private var customColor: Color
    @State private var customHexInput: String
    
    init(category: Category? = nil) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _type = State(initialValue: category?.type ?? .expense)
        _colorHex = State(initialValue: category?.colorHex ?? "2F80EDFF")
        let initialHex = category?.colorHex ?? "2F80EDFF"
        _customColor = State(initialValue: Color(hex: initialHex))
        _customHexInput = State(initialValue: "#\(String(initialHex.prefix(6)))")
    }
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("common.name", lang: uiLanguageCode)) {
                    TextField(L10n.text("tag.name_placeholder", lang: uiLanguageCode), text: $name)
                }
                
                Section(L10n.text("common.type", lang: uiLanguageCode)) {
                    Picker(L10n.text("common.type", lang: uiLanguageCode), selection: $type) {
                        Text(L10n.text("common.expenses", lang: uiLanguageCode)).tag(CategoryType.expense)
                        Text(L10n.text("common.income", lang: uiLanguageCode)).tag(CategoryType.income)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section(L10n.text("common.color", lang: uiLanguageCode)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(colorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(colorHex == hex ? 0.8 : 0), lineWidth: 2)
                                )
                                .onTapGesture { colorHex = hex }
                        }
                        
                        Circle()
                            .fill(.clear)
                            .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.secondary)
                            )
                            .onTapGesture {
                                customColor = Color(hex: colorHex)
                                customHexInput = "#\(String(colorHex.prefix(6)))"
                                isShowingColorPicker = true
                            }
                    }
                }
            }
            .navigationTitle(category == nil ? L10n.text("tag.new", lang: uiLanguageCode) : L10n.text("tag.edit", lang: uiLanguageCode))
            .dismissKeyboardOnTap()
            .keyboardDismissBehavior()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.text("common.cancel", lang: uiLanguageCode))
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
            .sheet(isPresented: $isShowingColorPicker) {
                NavigationStack {
                    Form {
                        Section(L10n.text("tag.palette", lang: uiLanguageCode)) {
                            ColorPicker(L10n.text("common.color", lang: uiLanguageCode), selection: $customColor, supportsOpacity: false)
                                .onChange(of: customColor) {
                                    let newHex = "#\(String(customColor.toHexString().prefix(6)))"
                                    if customHexInput.uppercased() != newHex.uppercased() {
                                        customHexInput = newHex
                                    }
                                }
                            
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(customColor)
                                    .frame(width: 30, height: 30)
                                Text(displayHex(customHexInput))
                                    .font(.subheadline.monospaced())
                            }
                        }
                        
                        Section(L10n.text("common.hex", lang: uiLanguageCode)) {
                            TextField(L10n.text("common.hex_placeholder", lang: uiLanguageCode), text: $customHexInput)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .onChange(of: customHexInput) {
                                    guard let parsed = parseHex(customHexInput) else { return }
                                    customColor = Color(hex: parsed)
                                }
                        }
                    }
                    .navigationTitle(L10n.text("tag.choose_color", lang: uiLanguageCode))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.text("common.cancel", lang: uiLanguageCode)) {
                                isShowingColorPicker = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("common.apply", lang: uiLanguageCode)) {
                                if let parsed = parseHex(customHexInput) {
                                    colorHex = parsed
                                } else {
                                    colorHex = customColor.toHexString()
                                }
                                isShowingColorPicker = false
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private var colorOptions: [String] {
        let base = CategoryColorPalette.all
        if base.contains(colorHex) {
            return base
        }
        return base + [colorHex]
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
    
    private func parseHex(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        let valid = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard cleaned.rangeOfCharacter(from: valid.inverted) == nil else { return nil }
        switch cleaned.count {
        case 6:
            return "\(cleaned)FF"
        case 8:
            return cleaned
        default:
            return nil
        }
    }
    
    private func displayHex(_ value: String) -> String {
        if let parsed = parseHex(value) {
            return "#\(String(parsed.prefix(6)))"
        }
        return value
    }
}

struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Wallet.name) private var wallets: [Wallet]
    
    private let transaction: Transaction?
    private let defaultCurrencyCode: String
    @ObservedObject var rateService: RateService
    
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var date: Date
    @State private var note: String
    @State private var selectedCategoryID: PersistentIdentifier?
    @State private var selectedWalletID: PersistentIdentifier?
    @State private var selectedTransferWalletID: PersistentIdentifier?
    @State private var transactionType: TransactionType
    @State private var transferAmountText: String
    @State private var isTransferAmountManuallyEdited: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoData: Data?
    
    private let originalWalletID: PersistentIdentifier?
    private let originalTransferWalletID: PersistentIdentifier?
    private let originalAmount: Decimal
    private let originalTransferAmount: Decimal
    private let originalType: TransactionType
    
    init(
        transaction: Transaction? = nil,
        defaultCurrencyCode: String,
        preselectedWalletID: PersistentIdentifier? = nil,
        rateService: RateService
    ) {
        self.transaction = transaction
        self.defaultCurrencyCode = defaultCurrencyCode
        self.rateService = rateService
        _amountText = State(initialValue: transaction.map { DecimalFormatter.editingString(from: $0.amount) } ?? "")
        _currencyCode = State(initialValue: transaction?.currencyCode ?? defaultCurrencyCode)
        _date = State(initialValue: transaction?.date ?? Date())
        _note = State(initialValue: transaction?.note ?? "")
        _selectedCategoryID = State(initialValue: transaction?.category?.persistentModelID)
        _selectedWalletID = State(initialValue: transaction?.wallet?.persistentModelID ?? preselectedWalletID)
        _selectedTransferWalletID = State(initialValue: transaction?.transferWallet?.persistentModelID)
        _transactionType = State(initialValue: transaction?.type ?? .expense)
        _transferAmountText = State(initialValue: transaction.flatMap { $0.transferAmount.map { NSDecimalNumber(decimal: $0).stringValue } } ?? "")
        _isTransferAmountManuallyEdited = State(initialValue: transaction?.transferAmount != nil)
        _photoData = State(initialValue: transaction?.photoData)
        
        originalWalletID = transaction?.wallet?.persistentModelID
        originalTransferWalletID = transaction?.transferWallet?.persistentModelID
        originalAmount = transaction?.amount ?? 0
        originalTransferAmount = transaction?.transferAmount ?? (transaction?.amount ?? 0)
        originalType = transaction?.type ?? .expense
    }
    
    private var canSave: Bool {
        guard parsedAmount != nil, selectedWalletID != nil else { return false }
        if transactionType == .transfer {
            guard let targetID = selectedTransferWalletID, let sourceID = selectedWalletID else { return false }
            return targetID != sourceID && parsedTransferAmount != nil
        }
        return selectedCategoryID != nil
    }
    
    private var parsedAmount: Decimal? {
        let amount = DecimalFormatter.parse(amountText)
        if let amount, amount > 0 {
            return amount
        }
        return nil
    }
    
    private var parsedTransferAmount: Decimal? {
        let value = DecimalFormatter.parse(transferAmountText)
        if let value, value > 0 {
            return value
        }
        return nil
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("common.type", lang: uiLanguageCode)) {
                    Picker(L10n.text("common.type", lang: uiLanguageCode), selection: $transactionType) {
                        Text(L10n.text("common.expenses", lang: uiLanguageCode)).tag(TransactionType.expense)
                        Text(L10n.text("common.income", lang: uiLanguageCode)).tag(TransactionType.income)
                        Text(L10n.text("common.transfer", lang: uiLanguageCode)).tag(TransactionType.transfer)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section(L10n.text("home.wallets", lang: uiLanguageCode)) {
                    Picker(L10n.text("home.wallets", lang: uiLanguageCode), selection: $selectedWalletID) {
                        Text(L10n.text("transaction.select_wallet", lang: uiLanguageCode)).tag(PersistentIdentifier?.none)
                        ForEach(wallets, id: \.persistentModelID) { wallet in
                            Text(wallet.name)
                                .tag(Optional(wallet.persistentModelID))
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                if transactionType == .transfer {
                    Section(L10n.text("transaction.transfer_to_wallet", lang: uiLanguageCode)) {
                        Picker(L10n.text("transaction.transfer_to_wallet", lang: uiLanguageCode), selection: $selectedTransferWalletID) {
                            Text(L10n.text("transaction.select_destination_wallet", lang: uiLanguageCode)).tag(PersistentIdentifier?.none)
                            ForEach(transferTargetWallets, id: \.persistentModelID) { wallet in
                                Text(wallet.name)
                                    .tag(Optional(wallet.persistentModelID))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Section(L10n.text("transaction.conversion", lang: uiLanguageCode)) {
                        TextField(L10n.text("common.amount_placeholder", lang: uiLanguageCode), text: $transferAmountText)
                            .keyboardType(.decimalPad)
                            .onChange(of: transferAmountText) {
                                isTransferAmountManuallyEdited = true
                            }
                        
                        if let destinationWallet = selectedTransferWallet,
                           let sourceWallet = selectedWallet {
                            Text("\(L10n.text("transaction.destination_amount", lang: uiLanguageCode)): \(destinationWallet.assetCode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if let autoAmount = autoConvertedTransferAmount {
                                Text("\(L10n.text("transaction.auto_rate_hint", lang: uiLanguageCode)) \(DecimalFormatter.string(from: autoAmount, maximumFractionDigits: 6)) \(destinationWallet.assetCode)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(L10n.text("transaction.auto_rate_unavailable", lang: uiLanguageCode))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Button(L10n.text("transaction.use_auto_amount", lang: uiLanguageCode)) {
                                applyAutoTransferAmount(force: true)
                            }
                            .disabled(autoConvertedTransferAmount == nil)
                            
                            Text("\(L10n.text("transaction.source_wallet", lang: uiLanguageCode)): \(sourceWallet.name) (\(sourceWallet.assetCode))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section(L10n.text("common.amount", lang: uiLanguageCode)) {
                    TextField(L10n.text("common.amount_placeholder", lang: uiLanguageCode), text: $amountText)
                        .keyboardType(.decimalPad)
                }
                
                Section(L10n.text("settings.currency", lang: uiLanguageCode)) {
                    Text(selectedWalletID == nil ? L10n.text("transaction.select_wallet_for_currency", lang: uiLanguageCode) : currencyCode)
                        .foregroundStyle(.secondary)
                }
                
                if transactionType != .transfer {
                    Section(L10n.text("settings.tags", lang: uiLanguageCode)) {
                        Picker(L10n.text("settings.tags", lang: uiLanguageCode), selection: $selectedCategoryID) {
                            Text(L10n.text("transaction.select_tag", lang: uiLanguageCode)).tag(PersistentIdentifier?.none)
                            ForEach(filteredCategories, id: \.persistentModelID) { category in
                                Text(category.name)
                                    .tag(Optional(category.persistentModelID))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                
                Section(L10n.text("common.date", lang: uiLanguageCode)) {
                    DatePicker(L10n.text("common.date", lang: uiLanguageCode), selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
                
                Section(L10n.text("common.comment", lang: uiLanguageCode)) {
                    TextField(L10n.text("transaction.add_comment", lang: uiLanguageCode), text: $note, axis: .vertical)
                }
                
                Section(L10n.text("common.photo", lang: uiLanguageCode)) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label(L10n.text("transaction.select_photo", lang: uiLanguageCode), systemImage: "photo")
                    }
                    if let photoData, let image = platformImage(from: photoData) {
                        platformImageView(image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                    }
                }
            }
            .navigationTitle(transaction == nil ? L10n.text("transaction.new", lang: uiLanguageCode) : L10n.text("transaction.edit", lang: uiLanguageCode))
            .keyboardDismissBehavior()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel", lang: uiLanguageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.save", lang: uiLanguageCode)) {
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
                normalizeTransferSelection()
                applyAutoTransferAmount(force: !isTransferAmountManuallyEdited)
            }
            .onAppear {
                normalizeSelections()
            }
            .onChange(of: transactionType) {
                if transactionType == .transfer {
                    selectedCategoryID = nil
                } else if let selectedCategoryID,
                          let selectedCategory = categories.first(where: { $0.persistentModelID == selectedCategoryID }),
                          selectedCategory.type != categoryTypeFromTransactionType() {
                    self.selectedCategoryID = nil
                }
                normalizeTransferSelection()
                applyAutoTransferAmount(force: true)
            }
            .onChange(of: selectedTransferWalletID) {
                applyAutoTransferAmount(force: !isTransferAmountManuallyEdited)
            }
            .onChange(of: amountText) {
                applyAutoTransferAmount(force: !isTransferAmountManuallyEdited)
            }
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private func saveTransaction() {
        guard let amount = parsedAmount else { return }
        guard selectedWalletID != nil else { return }
        
        let selectedCategory = categories.first { $0.persistentModelID == selectedCategoryID }
        let selectedWallet = self.selectedWallet
        let selectedTransferWallet = self.selectedTransferWallet
        
        if transactionType == .transfer {
            guard selectedTransferWallet != nil, parsedTransferAmount != nil else { return }
        } else if selectedCategory == nil {
            return
        }
        
        let walletNameSnapshot = selectedWallet?.name
        let walletKindRaw = selectedWallet?.kind.rawValue
        let walletColorHexSnapshot = selectedWallet?.colorHex
        let transferWalletNameSnapshot = selectedTransferWallet?.name
        let transferWalletCurrencyCode = selectedTransferWallet?.assetCode
        let transferWalletKindRaw = selectedTransferWallet?.kind.rawValue
        let transferWalletColorHexSnapshot = selectedTransferWallet?.colorHex
        let transferAmount = parsedTransferAmount
        
        applyWalletChanges(
            newWallet: selectedWallet,
            newTransferWallet: selectedTransferWallet,
            newAmount: amount,
            newTransferAmount: transferAmount,
            newType: transactionType
        )
        
        if let transaction {
            transaction.amount = amount
            transaction.currencyCode = currencyCode
            transaction.date = date
            transaction.note = note.isEmpty ? nil : note
            transaction.type = transactionType
            transaction.photoData = photoData
            transaction.walletNameSnapshot = walletNameSnapshot
            transaction.walletKindRaw = walletKindRaw
            transaction.walletColorHexSnapshot = walletColorHexSnapshot
            transaction.transferWalletNameSnapshot = transferWalletNameSnapshot
            transaction.transferWalletCurrencyCode = transferWalletCurrencyCode
            transaction.transferWalletKindRaw = transferWalletKindRaw
            transaction.transferWalletColorHexSnapshot = transferWalletColorHexSnapshot
            transaction.transferAmount = transferAmount
            transaction.category = selectedCategory
            transaction.wallet = selectedWallet
            transaction.transferWallet = selectedTransferWallet
        } else {
            let newTransaction = Transaction(
                amount: amount,
                currencyCode: currencyCode,
                date: date,
                note: note.isEmpty ? nil : note,
                type: transactionType,
                walletNameSnapshot: walletNameSnapshot,
                walletKindRaw: walletKindRaw,
                walletColorHexSnapshot: walletColorHexSnapshot,
                transferWalletNameSnapshot: transferWalletNameSnapshot,
                transferWalletCurrencyCode: transferWalletCurrencyCode,
                transferWalletKindRaw: transferWalletKindRaw,
                transferWalletColorHexSnapshot: transferWalletColorHexSnapshot,
                transferAmount: transferAmount,
                photoData: photoData,
                category: selectedCategory,
                wallet: selectedWallet,
                transferWallet: selectedTransferWallet
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
        if transactionType == .transfer {
            return []
        }
        let expectedType = categoryTypeFromTransactionType()
        return categories.filter { $0.type == expectedType }
    }
    
    private func categoryTypeFromTransactionType() -> CategoryType {
        switch transactionType {
        case .expense: return .expense
        case .income: return .income
        case .transfer: return .expense
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
        normalizeTransferSelection()
        applyWalletSelection()
        applyAutoTransferAmount(force: transferAmountText.isEmpty || !isTransferAmountManuallyEdited)
    }
    
    private func normalizeTransferSelection() {
        guard transactionType == .transfer else {
            selectedTransferWalletID = nil
            transferAmountText = ""
            isTransferAmountManuallyEdited = false
            return
        }
        if let selectedTransferWalletID,
           transferTargetWallets.first(where: { $0.persistentModelID == selectedTransferWalletID }) == nil {
            self.selectedTransferWalletID = nil
        }
    }
    
    private var selectedWallet: Wallet? {
        guard let selectedWalletID else { return nil }
        return wallets.first { $0.persistentModelID == selectedWalletID }
    }
    
    private var selectedTransferWallet: Wallet? {
        guard let selectedTransferWalletID else { return nil }
        return wallets.first { $0.persistentModelID == selectedTransferWalletID }
    }
    
    private var transferTargetWallets: [Wallet] {
        guard let sourceWalletID = selectedWalletID else {
            return []
        }
        return wallets.filter {
            $0.persistentModelID != sourceWalletID
        }
    }
    
    private var autoConvertedTransferAmount: Decimal? {
        guard transactionType == .transfer,
              let amount = parsedAmount,
              let sourceWallet = selectedWallet,
              let destinationWallet = selectedTransferWallet else {
            return nil
        }
        
        if sourceWallet.assetCode == destinationWallet.assetCode {
            return amount
        }
        
        return rateService.convert(
            amount: amount,
            from: sourceWallet.assetCode,
            kind: sourceWallet.kind,
            to: destinationWallet.assetCode
        )
    }
    
    private func applyAutoTransferAmount(force: Bool) {
        guard transactionType == .transfer else { return }
        guard force || !isTransferAmountManuallyEdited else { return }
        guard let autoAmount = autoConvertedTransferAmount else { return }
        transferAmountText = DecimalFormatter.editingString(from: autoAmount)
        isTransferAmountManuallyEdited = false
    }
    
    private func applyWalletChanges(
        newWallet: Wallet?,
        newTransferWallet: Wallet?,
        newAmount: Decimal,
        newTransferAmount: Decimal?,
        newType: TransactionType
    ) {
        if let originalWalletID,
           let originalWallet = wallets.first(where: { $0.persistentModelID == originalWalletID }) {
            let originalTransferWallet = wallets.first(where: { $0.persistentModelID == originalTransferWalletID })
            applyEffect(
                sourceWallet: originalWallet,
                destinationWallet: originalTransferWallet,
                amount: originalAmount,
                destinationAmount: originalTransferAmount,
                type: originalType,
                reversing: true
            )
        }
        
        if let newWallet {
            applyEffect(
                sourceWallet: newWallet,
                destinationWallet: newTransferWallet,
                amount: newAmount,
                destinationAmount: newTransferAmount ?? newAmount,
                type: newType,
                reversing: false
            )
        }
    }
    
    private func applyEffect(
        sourceWallet: Wallet?,
        destinationWallet: Wallet?,
        amount: Decimal,
        destinationAmount: Decimal,
        type: TransactionType,
        reversing: Bool
    ) {
        switch type {
        case .expense:
            guard let sourceWallet else { return }
            sourceWallet.balance += reversing ? amount : -amount
        case .income:
            guard let sourceWallet else { return }
            sourceWallet.balance += reversing ? -amount : amount
        case .transfer:
            guard let sourceWallet, let destinationWallet else { return }
            sourceWallet.balance += reversing ? amount : -amount
            destinationWallet.balance += reversing ? -destinationAmount : destinationAmount
        }
    }
}

struct AddWalletView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @Query(sort: \WalletFolder.name) private var walletFolders: [WalletFolder]
    
    private let wallet: Wallet?
    private let defaultCurrencyCode: String
    
    @State private var name: String
    @State private var kind: AssetKind
    @State private var assetCode: String
    @State private var balanceText: String
    @State private var colorHex: String
    @State private var selectedFolderID: PersistentIdentifier?
    @State private var isShowingColorPicker = false
    @State private var customColor: Color
    @State private var customHexInput: String
    
    init(wallet: Wallet? = nil, defaultCurrencyCode: String) {
        self.wallet = wallet
        self.defaultCurrencyCode = defaultCurrencyCode
        _name = State(initialValue: wallet?.name ?? "")
        _kind = State(initialValue: wallet?.kind ?? .fiat)
        _assetCode = State(initialValue: wallet?.assetCode ?? defaultCurrencyCode)
        _balanceText = State(initialValue: wallet.map { DecimalFormatter.editingString(from: $0.balance) } ?? "")
        let initialHex = wallet?.colorHex ?? "FFFFFFFF"
        _colorHex = State(initialValue: initialHex)
        _selectedFolderID = State(initialValue: wallet?.folder?.persistentModelID)
        _customColor = State(initialValue: Color(hex: initialHex))
        _customHexInput = State(initialValue: "#\(String(initialHex.prefix(6)))")
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
                Section(L10n.text("common.name", lang: uiLanguageCode)) {
                    TextField(L10n.text("wallet.name_placeholder", lang: uiLanguageCode), text: $name)
                }
                
                Section(L10n.text("common.type", lang: uiLanguageCode)) {
                    Picker(L10n.text("common.type", lang: uiLanguageCode), selection: $kind) {
                        Text(L10n.text("wallet.kind.fiat", lang: uiLanguageCode)).tag(AssetKind.fiat)
                        Text(L10n.text("wallet.kind.crypto", lang: uiLanguageCode)).tag(AssetKind.crypto)
                        Text(L10n.text("wallet.kind.metal", lang: uiLanguageCode)).tag(AssetKind.metal)
                        Text(L10n.text("wallet.kind.stock", lang: uiLanguageCode)).tag(AssetKind.stock)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section(L10n.text("wallet.asset", lang: uiLanguageCode)) {
                    if kind == .stock {
                        TextField(L10n.text("wallet.ticker_placeholder", lang: uiLanguageCode), text: $assetCode)
                            .textInputAutocapitalization(.characters)
                    } else {
                        Picker(L10n.text("wallet.asset", lang: uiLanguageCode), selection: $assetCode) {
                            ForEach(CurrencyCatalog.allCurrencies.filter { $0.kind == kind }, id: \.code) { item in
                                Text(L10n.currencyDisplay(code: item.code, fallbackName: item.name, lang: uiLanguageCode))
                                    .tag(item.code)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                
                Section(L10n.text("wallet.balance", lang: uiLanguageCode)) {
                    TextField(L10n.text("common.amount_placeholder", lang: uiLanguageCode), text: $balanceText)
                        .keyboardType(.decimalPad)
                }
                
                Section(L10n.text("common.color", lang: uiLanguageCode)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(colorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(colorHex == hex ? 0.8 : 0), lineWidth: 2)
                                )
                                .onTapGesture { colorHex = hex }
                        }
                        
                        Circle()
                            .fill(.clear)
                            .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.secondary)
                            )
                            .onTapGesture {
                                customColor = Color(hex: colorHex)
                                customHexInput = "#\(String(colorHex.prefix(6)))"
                                isShowingColorPicker = true
                            }
                    }
                }
                
                Section(L10n.text("wallet.folder", lang: uiLanguageCode)) {
                    Picker(L10n.text("wallet.folder", lang: uiLanguageCode), selection: $selectedFolderID) {
                        Text(L10n.text("common.none", lang: uiLanguageCode)).tag(PersistentIdentifier?.none)
                        ForEach(walletFolders, id: \.persistentModelID) { folder in
                            Text(folder.name).tag(Optional(folder.persistentModelID))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle(wallet == nil ? L10n.text("wallet.new", lang: uiLanguageCode) : L10n.text("wallet.edit", lang: uiLanguageCode))
            .keyboardDismissBehavior()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel", lang: uiLanguageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.save", lang: uiLanguageCode)) {
                        saveWallet()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $isShowingColorPicker) {
                NavigationStack {
                    Form {
                        Section(L10n.text("tag.palette", lang: uiLanguageCode)) {
                            ColorPicker(L10n.text("common.color", lang: uiLanguageCode), selection: $customColor, supportsOpacity: false)
                                .onChange(of: customColor) {
                                    let newHex = "#\(String(customColor.toHexString().prefix(6)))"
                                    if customHexInput.uppercased() != newHex.uppercased() {
                                        customHexInput = newHex
                                    }
                                }
                            
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(customColor)
                                    .frame(width: 30, height: 30)
                                Text(displayHex(customHexInput))
                                    .font(.subheadline.monospaced())
                            }
                        }
                        
                        Section(L10n.text("common.hex", lang: uiLanguageCode)) {
                            TextField(L10n.text("common.hex_placeholder", lang: uiLanguageCode), text: $customHexInput)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .onChange(of: customHexInput) {
                                    guard let parsed = parseHex(customHexInput) else { return }
                                    customColor = Color(hex: parsed)
                                }
                        }
                    }
                    .navigationTitle(L10n.text("tag.choose_color", lang: uiLanguageCode))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.text("common.cancel", lang: uiLanguageCode)) {
                                isShowingColorPicker = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("common.apply", lang: uiLanguageCode)) {
                                if let parsed = parseHex(customHexInput) {
                                    colorHex = parsed
                                } else {
                                    colorHex = customColor.toHexString()
                                }
                                isShowingColorPicker = false
                            }
                        }
                    }
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
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private func saveWallet() {
        guard let balance = parsedBalance else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAsset = assetCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let selectedFolder = walletFolders.first { $0.persistentModelID == selectedFolderID }
        
        if let wallet {
            wallet.name = trimmedName
            wallet.kind = kind
            wallet.assetCode = trimmedAsset
            wallet.balance = balance
            wallet.colorHex = colorHex
            wallet.folder = selectedFolder
            wallet.updatedAt = Date()
        } else {
            let newWallet = Wallet(
                name: trimmedName,
                assetCode: trimmedAsset,
                kind: kind,
                balance: balance,
                colorHex: colorHex
            )
            newWallet.folder = selectedFolder
            modelContext.insert(newWallet)
        }
    }
    
    private var colorOptions: [String] {
        let base = ["FFFFFFFF"] + CategoryColorPalette.all
        if base.contains(colorHex) {
            return base
        }
        return base + [colorHex]
    }
    
    private func parseHex(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        let valid = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard cleaned.rangeOfCharacter(from: valid.inverted) == nil else { return nil }
        switch cleaned.count {
        case 6:
            return "\(cleaned)FF"
        case 8:
            return cleaned
        default:
            return nil
        }
    }
    
    private func displayHex(_ value: String) -> String {
        if let parsed = parseHex(value) {
            return "#\(String(parsed.prefix(6)))"
        }
        return value
    }
}

struct AddWalletFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    
    private let folder: WalletFolder?
    @State private var name: String
    
    init(folder: WalletFolder? = nil) {
        self.folder = folder
        _name = State(initialValue: folder?.name ?? "")
    }
    
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("common.name", lang: uiLanguageCode)) {
                    TextField(L10n.text("folder.name_placeholder", lang: uiLanguageCode), text: $name)
                }
            }
            .navigationTitle(folder == nil ? L10n.text("folder.new", lang: uiLanguageCode) : L10n.text("folder.edit", lang: uiLanguageCode))
            .dismissKeyboardOnTap()
            .keyboardDismissBehavior()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel", lang: uiLanguageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.save", lang: uiLanguageCode)) {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let folder {
                            folder.name = trimmed
                        } else {
                            let folder = WalletFolder(name: trimmed)
                            modelContext.insert(folder)
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
}

struct TotalsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
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
                        Text(L10n.currencyDisplay(code: currency.code, fallbackName: currency.name, lang: uiLanguageCode))
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
            .navigationTitle(L10n.text("total.currencies", lang: uiLanguageCode))
            .dismissKeyboardOnTap()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel", lang: uiLanguageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.save", lang: uiLanguageCode)) {
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
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
    
    private func toggle(_ code: String) {
        if selectedCodes.contains(code) {
            selectedCodes.remove(code)
        } else {
            selectedCodes.insert(code)
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("isRoundedAmounts") private var isRoundedAmounts = false
    
    @Query(sort: \Category.name) private var categories: [Category]
    
    @State private var selectedType: CategoryType = .expense
    @State private var isAddingCategory = false
    @State private var editingCategory: Category?
    
    private let languages: [String] = [
        "system",
        "en",
        "ru",
        "uk",
        "sv"
    ]
    
    private let themes: [(code: String, titleKey: String)] = [
        ("system", "settings.theme.system"),
        ("light", "settings.theme.light"),
        ("dark", "settings.theme.dark")
    ]
    
    private var filteredCategories: [Category] {
        categories.filter { $0.type == selectedType }
    }
    
    private var controlsTint: Color {
        .secondary
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("settings.language", lang: uiLanguageCode)) {
                    Picker(L10n.text("settings.app_language", lang: uiLanguageCode), selection: $appLanguageCode) {
                        ForEach(languages, id: \.self) { code in
                            Text(L10n.languageDisplay(code: code, lang: uiLanguageCode)).tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(controlsTint)
                }
                
                Section(L10n.text("settings.base_currency", lang: uiLanguageCode)) {
                    Picker(L10n.text("settings.currency", lang: uiLanguageCode), selection: $baseCurrencyCode) {
                        ForEach(CurrencyCatalog.baseCurrencies, id: \.code) { currency in
                            Text(L10n.currencyDisplay(code: currency.code, fallbackName: currency.name, lang: uiLanguageCode))
                                .tag(currency.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(controlsTint)
                }
                
                Section(L10n.text("settings.theme", lang: uiLanguageCode)) {
                    Picker(L10n.text("settings.theme", lang: uiLanguageCode), selection: $appTheme) {
                        ForEach(themes, id: \.code) { item in
                            Text(L10n.text(item.titleKey, lang: uiLanguageCode))
                                .tag(item.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(controlsTint)
                }
                
                Section(L10n.text("settings.amounts", lang: uiLanguageCode)) {
                    Toggle(L10n.text("settings.round_amounts", lang: uiLanguageCode), isOn: $isRoundedAmounts)
                        .tint(controlsTint)
                }
                
                Section {
                    Picker(L10n.text("common.type", lang: uiLanguageCode), selection: $selectedType) {
                        Text(L10n.text("common.expenses", lang: uiLanguageCode)).tag(CategoryType.expense)
                        Text(L10n.text("common.income", lang: uiLanguageCode)).tag(CategoryType.income)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    if filteredCategories.isEmpty {
                        Text(L10n.text("settings.no_tags", lang: uiLanguageCode))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredCategories, id: \.persistentModelID) { category in
                            CategoryRow(category: category)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingCategory = category
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(L10n.text("common.delete", lang: uiLanguageCode), role: .destructive) {
                                        modelContext.delete(category)
                                    }
                                    .tint(.red)
                                    Button(L10n.text("common.edit", lang: uiLanguageCode)) {
                                        editingCategory = category
                                    }
                                    .tint(Color(hex: "4A4A4AFF"))
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text(L10n.text("settings.tags", lang: uiLanguageCode))
                        Spacer()
                        Button {
                            isAddingCategory = true
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "plus.circle")
                                Text(L10n.text("settings.new_tags", lang: uiLanguageCode))
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("settings.new_tags", lang: uiLanguageCode))
                    }
                }
            }
            .navigationTitle(L10n.text("tab.settings", lang: uiLanguageCode))
            .sheet(isPresented: $isAddingCategory) {
                AddCategoryView()
            }
            .sheet(
                isPresented: Binding(
                    get: { editingCategory != nil },
                    set: { if !$0 { editingCategory = nil } }
                )
            ) {
                if let editingCategory {
                    AddCategoryView(category: editingCategory)
                }
            }
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }
}

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let titleKey: String
    let descriptionKey: String
    let systemImage: String
}

struct OnboardingView: View {
    let lang: String
    let onDone: () -> Void
    @State private var pageIndex: Int? = 0
    
    private var pages: [OnboardingPage] {
        [
            OnboardingPage(titleKey: "onboarding.transaction.title", descriptionKey: "onboarding.transaction.body", systemImage: "plus.circle.fill"),
            OnboardingPage(titleKey: "onboarding.tags.title", descriptionKey: "onboarding.tags.body", systemImage: "tag.fill"),
            OnboardingPage(titleKey: "onboarding.analytics.title", descriptionKey: "onboarding.analytics.body", systemImage: "chart.pie.fill"),
            OnboardingPage(titleKey: "onboarding.refresh.title", descriptionKey: "onboarding.refresh.body", systemImage: "arrow.clockwise"),
            OnboardingPage(titleKey: "onboarding.groups.title", descriptionKey: "onboarding.groups.body", systemImage: "folder.badge.plus")
        ]
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            VStack(spacing: 20) {
                                Image(systemName: page.systemImage)
                                    .font(.system(size: 44, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(L10n.text(page.titleKey, lang: lang))
                                    .font(.title2.weight(.bold))
                                Text(L10n.text(page.descriptionKey, lang: lang))
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(index)
                            .padding(.horizontal, 28)
                            .padding(.top, 24)
                            .containerRelativeFrame(.horizontal)
                            .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
                .scrollTargetLayout()
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $pageIndex)
                .frame(height: 320)
                .clipped()
                
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == (pageIndex ?? 0) ? Color.secondary : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                
                Button((pageIndex ?? 0) == pages.count - 1 ? L10n.text("onboarding.done", lang: lang) : L10n.text("onboarding.next", lang: lang)) {
                    let current = pageIndex ?? 0
                    if current < pages.count - 1 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            pageIndex = current + 1
                        }
                    } else {
                        onDone()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.secondary)
                .padding(.bottom, 12)
            }
            .padding(.top, 16)
            .navigationTitle(L10n.text("onboarding.welcome", lang: lang))
        }
    }
}

enum L10n {
    static func text(_ key: String, lang: String) -> String {
        let code = ["en", "ru", "uk", "sv"].contains(lang) ? lang : "en"
        if let bundle = bundle(for: code) {
            let localized = NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: key, comment: "")
            if localized != key {
                return localized
            }
        }
        if code != "en", let enBundle = bundle(for: "en") {
            let fallback = NSLocalizedString(key, tableName: "Localizable", bundle: enBundle, value: key, comment: "")
            if fallback != key {
                return fallback
            }
        }
        return key
    }

    static func currencyDisplay(code: String, fallbackName: String, lang: String) -> String {
        let name = currencyName(code: code, lang: lang) ?? fallbackName
        return "\(code.uppercased()) — \(name)"
    }

    static func languageDisplay(code: String, lang: String) -> String {
        switch code {
        case "system":
            return text("settings.language.system", lang: lang)
        case "en":
            return text("settings.language.english", lang: lang)
        case "ru":
            return text("settings.language.russian", lang: lang)
        case "uk":
            return text("settings.language.ukrainian", lang: lang)
        case "sv":
            return text("settings.language.swedish", lang: lang)
        default:
            return code.uppercased()
        }
    }

    private static func currencyName(code: String, lang: String) -> String? {
        Locale(identifier: normalizedLanguageCode(lang))
            .localizedString(forCurrencyCode: code.uppercased())
    }

    private static func normalizedLanguageCode(_ lang: String) -> String {
        ["en", "ru", "uk", "sv"].contains(lang) ? lang : "en"
    }
    
    private static func bundle(for code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}

enum AppTheme {
    static func colorScheme(from value: String) -> ColorScheme? {
        switch value {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }
}

private struct DismissKeyboardOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
#if canImport(UIKit)
        content.simultaneousGesture(
            TapGesture().onEnded {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
        )
#else
        content
#endif
    }
}

private extension View {
    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTapModifier())
    }
    
    @ViewBuilder
    func keyboardDismissBehavior() -> some View {
#if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
#else
        self
#endif
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Category.self, Transaction.self, Asset.self, Wallet.self, WalletFolder.self], inMemory: true)
}
