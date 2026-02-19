//
//  ContentView.swift
//  ArgentumVault
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import SwiftUI
import SwiftData
import PhotosUI
import Charts
import UniformTypeIdentifiers
import AuthenticationServices
import CryptoKit
import Security

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

private struct AdaptiveRootContainer<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let maxWidth: CGFloat
    private let content: Content

    init(maxWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        Group {
            if usesWidePadLayout {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    content
                        .frame(maxWidth: maxWidth)
                    Spacer(minLength: 0)
                }
            } else {
                content
            }
        }
    }

    private var usesWidePadLayout: Bool {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
#else
        horizontalSizeClass == .regular
#endif
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("appCountryCode") private var appCountryCode = ""
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("didCompleteInitialSetup_v1") private var didCompleteInitialSetup = false
    @AppStorage("didShowOnboarding") private var didShowOnboarding = false
    @AppStorage("forceShowOnboardingOnce_v4") private var forceShowOnboardingOnce = true
    @AppStorage("didRunMigration_v1") private var didRunMigration = false
    @AppStorage("didSeedDefaultCategories_v1") private var didSeedDefaultCategories = false
    @AppStorage("appleUserID") private var appleUserID = ""
    @AppStorage("appleUserEmail") private var appleUserEmail = ""
    @AppStorage("appleUserName") private var appleUserName = ""
    @AppStorage("emailUserEmail") private var emailUserEmail = ""
    @AppStorage("authMethod") private var authMethod = ""
#if DEBUG
    @AppStorage("debugResetFirstLaunchOnce_v5") private var debugResetFirstLaunchOnce = true
#endif
    @StateObject private var rateService = RateService()
    @StateObject private var subscriptionManager = SubscriptionManager()
    @State private var showSplash = true
    @State private var showOnboarding = false
    @State private var showGlobalPaywall = false
    
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

    private var isAccountConnected: Bool {
        !appleUserID.isEmpty || !emailUserEmail.isEmpty
    }
    
    var body: some View {
        ZStack {
            if !isAccountConnected {
                AdaptiveRootContainer(maxWidth: 760) {
                    FirstLaunchSetupView(requiresPreferencesStep: !didCompleteInitialSetup || baseCurrencyCode.isEmpty)
                }
            } else if !didCompleteInitialSetup && baseCurrencyCode.isEmpty {
                AdaptiveRootContainer(maxWidth: 760) {
                    FirstLaunchSetupView()
                }
            } else if baseCurrencyCode.isEmpty {
                AdaptiveRootContainer(maxWidth: 760) {
                    BaseCurrencySetupView()
                }
            } else {
                AdaptiveRootContainer(maxWidth: 1120) {
                    VStack(spacing: 0) {
                        TabView {
                            HomeView(rateService: rateService)
                                .tabItem {
                                    Label(L10n.text("tab.home", lang: uiLanguageCode), systemImage: "house.fill")
                                }

                            AnalyticsView(rateService: rateService)
                                .tabItem {
                                    Label(L10n.text("tab.analytics", lang: uiLanguageCode), systemImage: "chart.pie.fill")
                                }

                            SettingsView(rateService: rateService)
                                .tabItem {
                                    Label(L10n.text("tab.settings", lang: uiLanguageCode), systemImage: "gearshape.fill")
                                }
                        }

                        GlobalAdHost(lang: uiLanguageCode, slot: .homeBottomBanner) {
                            showGlobalPaywall = true
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: subscriptionManager.hasProAccess)
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
#if DEBUG
            if debugResetFirstLaunchOnce {
                didCompleteInitialSetup = false
                didShowOnboarding = false
                forceShowOnboardingOnce = true
                didSeedDefaultCategories = false
                baseCurrencyCode = ""
                appCountryCode = ""
                appleUserID = ""
                appleUserEmail = ""
                appleUserName = ""
                emailUserEmail = ""
                authMethod = ""
                debugResetFirstLaunchOnce = false
            }
#endif
            if !didCompleteInitialSetup, !baseCurrencyCode.isEmpty {
                // Keep existing installs unblocked after update.
                didCompleteInitialSetup = true
            }
            if authMethod.isEmpty {
                if !appleUserID.isEmpty {
                    authMethod = "apple"
                } else if !emailUserEmail.isEmpty {
                    authMethod = "email"
                }
            }
            if appCountryCode.isEmpty {
                appCountryCode = CountryCatalog.defaultCountryCode()
            }
            Migration.runIfNeeded(
                modelContext: modelContext,
                baseCurrencyCode: baseCurrencyCode,
                didRunMigration: &didRunMigration
            )
            if didCompleteInitialSetup {
                Migration.seedDefaultCategoriesIfNeeded(
                    modelContext: modelContext,
                    languageCode: uiLanguageCode,
                    didSeedDefaultCategories: &didSeedDefaultCategories
                )
            }
            await subscriptionManager.start()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeOut(duration: 0.25)) {
                    showSplash = false
                }
                if didCompleteInitialSetup && (!didShowOnboarding || forceShowOnboardingOnce) {
                    showOnboarding = true
                }
            }
        }
        .onChange(of: didCompleteInitialSetup) {
            guard didCompleteInitialSetup else { return }
            if !didShowOnboarding || forceShowOnboardingOnce {
                showOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(lang: uiLanguageCode) {
                didShowOnboarding = true
                forceShowOnboardingOnce = false
                showOnboarding = false
            }
        }
        .sheet(isPresented: $showGlobalPaywall) {
            PaywallView(lang: uiLanguageCode)
                .environmentObject(subscriptionManager)
        }
        .environment(\.locale, currentLocale)
        .preferredColorScheme(AppTheme.colorScheme(from: appTheme))
        .environmentObject(subscriptionManager)
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

private enum FirstSetupStep {
    case account
    case preferences
}

struct FirstLaunchSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("appCountryCode") private var appCountryCode = ""
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("appleUserID") private var appleUserID = ""
    @AppStorage("appleUserEmail") private var appleUserEmail = ""
    @AppStorage("appleUserName") private var appleUserName = ""
    @AppStorage("emailUserEmail") private var emailUserEmail = ""
    @AppStorage("authMethod") private var authMethod = ""
    @AppStorage("didCompleteInitialSetup_v1") private var didCompleteInitialSetup = false
    @AppStorage("didSeedDefaultCategories_v1") private var didSeedDefaultCategories = false

    @State private var appleSignInCoordinator = AppleSignInCoordinator()
    @State private var step: FirstSetupStep = .account
    @State private var selectedLanguageCode = FirstLaunchSetupView.defaultLanguageCode()
    @State private var selectedCurrencyCode = CurrencyCatalog.baseCurrencies.first?.code ?? "USD"
    @State private var selectedCountryCode = CountryCatalog.defaultCountryCode()
    @State private var showAppleAuthError = false
    @State private var appleAuthErrorMessage = ""
    @State private var activeEmailAuthMode: EmailAuthMode?

    private let requiresPreferencesStep: Bool

    init(requiresPreferencesStep: Bool = true) {
        self.requiresPreferencesStep = requiresPreferencesStep
    }

    private let selectableLanguages = ["en", "ru", "uk", "sv"]

    private var uiLanguageCode: String {
        guard requiresPreferencesStep else {
            if appLanguageCode == "system" {
                return FirstLaunchSetupView.defaultLanguageCode()
            }
            return selectableLanguages.contains(appLanguageCode) ? appLanguageCode : "en"
        }
        return selectedLanguageCode
    }

    private var countryOptions: [CountryOption] {
        CountryCatalog.options(lang: uiLanguageCode)
    }

    private var isAccountConnected: Bool {
        !appleUserID.isEmpty || !emailUserEmail.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if step == .account {
                    Section(L10n.text("setup.auth.title", lang: uiLanguageCode)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("setup.auth.body", lang: uiLanguageCode))
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if !isAccountConnected {
                                VStack(spacing: 14) {
                                    AppleSignInActionButton(title: L10n.text("settings.account.sign_in_apple", lang: uiLanguageCode), action: startAppleSignIn)

                                    Text(L10n.text("common.or", lang: uiLanguageCode))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)

                                    Button {
                                        openEmailAuth(mode: .signIn)
                                    } label: {
                                        Text(L10n.text("settings.account.sign_in_email", lang: uiLanguageCode))
                                            .font(.headline)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.black)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .center)

                                    Text(L10n.text("common.or", lang: uiLanguageCode))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)

                                    Button {
                                        openEmailAuth(mode: .signUp)
                                    } label: {
                                        Text(L10n.text("settings.account.create_email", lang: uiLanguageCode))
                                            .font(.headline)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.black)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .padding(.vertical, 2)

                                Text(L10n.text("setup.auth.required", lang: uiLanguageCode))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

#if targetEnvironment(simulator)
                            Text(L10n.text("settings.account.simulator_hint", lang: uiLanguageCode))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
#endif
                        }
                    }

                } else {
                    Section(L10n.text("setup.preferences.title", lang: uiLanguageCode)) {
                        Picker(L10n.text("settings.app_language", lang: uiLanguageCode), selection: $selectedLanguageCode) {
                            ForEach(selectableLanguages, id: \.self) { code in
                                Text(L10n.languageDisplay(code: code, lang: uiLanguageCode)).tag(code)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker(L10n.text("settings.currency", lang: uiLanguageCode), selection: $selectedCurrencyCode) {
                            ForEach(CurrencyCatalog.baseCurrencies, id: \.code) { currency in
                                Text(L10n.currencyDisplay(code: currency.code, fallbackName: currency.name, lang: uiLanguageCode))
                                    .tag(currency.code)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker(L10n.text("settings.country", lang: uiLanguageCode), selection: $selectedCountryCode) {
                            ForEach(countryOptions, id: \.code) { country in
                                Text(country.name)
                                    .tag(country.code)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section {
                        Button(L10n.text("setup.finish", lang: uiLanguageCode)) {
                            completeSetup()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle(L10n.text("setup.first_launch.title", lang: uiLanguageCode))
        }
        .interactiveDismissDisabled(true)
        .sheet(item: $activeEmailAuthMode) { mode in
            EmailAuthSheetView(
                lang: uiLanguageCode,
                initialMode: mode,
                showsModePicker: false
            ) { email in
                handleEmailAuthSuccess(email: email)
            }
        }
        .alert(
            L10n.text("settings.account.error_title", lang: uiLanguageCode),
            isPresented: $showAppleAuthError
        ) {
            Button(L10n.text("common.ok", lang: uiLanguageCode), role: .cancel) {}
        } message: {
            Text(appleAuthErrorMessage)
        }
        .onAppear {
            guard step == .account, isAccountConnected else { return }
            triggerProRestoreAfterAuthorization()
            if !restoreSetupProfileForCurrentAccountIfPresent() {
                proceedAfterAuth()
            }
        }
        .onChange(of: isAccountConnected) {
            guard step == .account, isAccountConnected else { return }
            triggerProRestoreAfterAuthorization()
            if !restoreSetupProfileForCurrentAccountIfPresent() {
                proceedAfterAuth()
            }
        }
    }

    private static func defaultLanguageCode() -> String {
        let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
        return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
    }

    private func completeSetup() {
        let normalizedLanguage = normalizedLanguageCode(selectedLanguageCode)
        let normalizedCurrency = normalizedCurrencyCode(selectedCurrencyCode)
        let normalizedCountry = normalizedCountryCode(selectedCountryCode, lang: normalizedLanguage)

        appLanguageCode = normalizedLanguage
        baseCurrencyCode = normalizedCurrency
        appCountryCode = normalizedCountry
        selectedLanguageCode = normalizedLanguage
        selectedCurrencyCode = normalizedCurrency
        selectedCountryCode = normalizedCountry

        Migration.seedDefaultCategoriesIfNeeded(
            modelContext: modelContext,
            languageCode: normalizedLanguage,
            didSeedDefaultCategories: &didSeedDefaultCategories
        )
        didCompleteInitialSetup = true
        saveSetupProfileForCurrentAccount()
    }

    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                appleAuthErrorMessage = L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
                showAppleAuthError = true
                return
            }
            showAppleAuthError = false
            emailUserEmail = ""
            appleUserID = credential.user
            authMethod = "apple"
            if let email = credential.email, !email.isEmpty {
                appleUserEmail = email
            }
            let given = credential.fullName?.givenName ?? ""
            let family = credential.fullName?.familyName ?? ""
            let fullName = [given, family]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !fullName.isEmpty {
                appleUserName = fullName
            }
            SessionEvents.postAccountSessionDidChange()
            syncBackupImmediately(accountIdentifier: "apple:\(credential.user)")
            triggerProRestoreAfterAuthorization()
            if let accountID = SetupProfileStore.appleAccountID(credential.user),
               restoreSetupProfileIfPresent(for: accountID) {
                return
            }
            proceedAfterAuth()
        case .failure(let error):
            if let appleError = error as? ASAuthorizationError, appleError.code == .canceled {
                return
            }
            appleAuthErrorMessage = localizedAppleSignInError(error)
            showAppleAuthError = true
        }
    }

    private func handleEmailAuthSuccess(email: String) {
        appleUserID = ""
        appleUserEmail = ""
        appleUserName = ""
        emailUserEmail = email
        authMethod = "email"
        SessionEvents.postAccountSessionDidChange()
        syncBackupImmediately(accountIdentifier: "email:\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
        triggerProRestoreAfterAuthorization()
        if let accountID = SetupProfileStore.emailAccountID(email),
           restoreSetupProfileIfPresent(for: accountID) {
            return
        }
        proceedAfterAuth()
    }

    private func syncBackupImmediately(accountIdentifier: String) {
        Task { @MainActor in
            let didRestore = (try? await ICloudBackupManager.restoreIfNeeded(
                modelContext: modelContext,
                accountIdentifier: accountIdentifier
            )) ?? false
            if ICloudBackupManager.shouldForceBackupAfterRestoreAttempt(
                modelContext: modelContext,
                didRestore: didRestore
            ) {
                ICloudBackupManager.backupIfNeeded(
                    modelContext: modelContext,
                    accountIdentifier: accountIdentifier,
                    force: true
                )
            }
        }
    }

    private func openEmailAuth(mode: EmailAuthMode) {
        activeEmailAuthMode = mode
    }

    private func startAppleSignIn() {
        appleSignInCoordinator.start { result in
            handleAppleSignIn(result: result)
        }
    }

    private func triggerProRestoreAfterAuthorization() {
        Task {
            await subscriptionManager.restoreAfterAuthorization()
        }
    }

    private func proceedAfterAuth() {
        if didCompleteInitialSetup && !baseCurrencyCode.isEmpty {
            return
        }
        if requiresPreferencesStep {
            step = .preferences
        } else {
            didCompleteInitialSetup = true
        }
    }

    private func restoreSetupProfileForCurrentAccountIfPresent() -> Bool {
        guard let accountID = currentSetupAccountID() else {
            return false
        }
        return restoreSetupProfileIfPresent(for: accountID)
    }

    private func restoreSetupProfileIfPresent(for accountID: String) -> Bool {
        guard let profile = try? SetupProfileStore.load(for: accountID) else {
            return false
        }

        let normalizedLanguage = normalizedLanguageCode(profile.languageCode)
        let normalizedCurrency = normalizedCurrencyCode(profile.currencyCode)
        let normalizedCountry = normalizedCountryCode(profile.countryCode, lang: normalizedLanguage)

        appLanguageCode = normalizedLanguage
        baseCurrencyCode = normalizedCurrency
        appCountryCode = normalizedCountry
        selectedLanguageCode = normalizedLanguage
        selectedCurrencyCode = normalizedCurrency
        selectedCountryCode = normalizedCountry
        didCompleteInitialSetup = true

        return true
    }

    private func saveSetupProfileForCurrentAccount() {
        guard let accountID = currentSetupAccountID() else { return }
        let profile = StoredSetupProfile(
            languageCode: normalizedLanguageCode(appLanguageCode),
            currencyCode: normalizedCurrencyCode(baseCurrencyCode),
            countryCode: normalizedCountryCode(appCountryCode, lang: normalizedLanguageCode(appLanguageCode)),
            savedAtTimestamp: Date().timeIntervalSince1970
        )
        try? SetupProfileStore.save(profile, for: accountID)
    }

    private func currentSetupAccountID() -> String? {
        switch authMethod {
        case "apple":
            return SetupProfileStore.appleAccountID(appleUserID)
        case "email":
            return SetupProfileStore.emailAccountID(emailUserEmail)
        default:
            if let appleAccountID = SetupProfileStore.appleAccountID(appleUserID) {
                return appleAccountID
            }
            return SetupProfileStore.emailAccountID(emailUserEmail)
        }
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        let normalized = code.trimmed.lowercased()
        return selectableLanguages.contains(normalized) ? normalized : FirstLaunchSetupView.defaultLanguageCode()
    }

    private func normalizedCurrencyCode(_ code: String) -> String {
        let normalized = code.trimmed.uppercased()
        if CurrencyCatalog.baseCurrencies.contains(where: { $0.code == normalized }) {
            return normalized
        }
        return CurrencyCatalog.baseCurrencies.first?.code ?? "USD"
    }

    private func normalizedCountryCode(_ code: String, lang: String) -> String {
        let normalized = code.trimmed.uppercased()
        if CountryCatalog.options(lang: lang).contains(where: { $0.code == normalized }) {
            return normalized
        }
        return CountryCatalog.defaultCountryCode()
    }

    private func localizedAppleSignInError(_ error: Error) -> String {
        if let appleError = error as? ASAuthorizationError {
            switch appleError.code {
            case .canceled:
                return L10n.text("settings.account.error_canceled", lang: uiLanguageCode)
            case .invalidResponse:
                return L10n.text("settings.account.error_invalid_response", lang: uiLanguageCode)
            case .notHandled:
                return L10n.text("settings.account.error_not_handled", lang: uiLanguageCode)
            case .failed:
                return L10n.text("settings.account.error_failed", lang: uiLanguageCode)
            case .notInteractive:
                return L10n.text("settings.account.error_not_interactive", lang: uiLanguageCode)
            case .unknown:
                return L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
            case .matchedExcludedCredential, .credentialImport, .credentialExport, .preferSignInWithApple, .deviceNotConfiguredForPasskeyCreation:
                return L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
            @unknown default:
                return L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
            }
        }
        return error.localizedDescription
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
    @Query(sort: \RecurringTransactionRule.nextRunDate) private var recurringRules: [RecurringTransactionRule]
    
    @State private var isAddingTransaction = false
    @State private var editingTransaction: Transaction?
    @State private var isAddingWallet = false
    @State private var isAddingWalletFolder = false
    @State private var editingWalletFolder: WalletFolder?
    @State private var editingWallet: Wallet?
    @State private var viewingWallet: WalletDetailPayload?
    @State private var isManagingTotals = false
    @State private var walletToDeleteName: String?
    @State private var walletToDeleteAssetCode: String?
    @State private var showDeleteWalletConfirm = false
    @State private var collapsedFolderIDs: Set<PersistentIdentifier> = []
    @State private var knownFolderIDs: Set<PersistentIdentifier> = []
    @State private var didInitializeFolderCollapse = false
    @State private var transactionSearchText = ""
    
    private var ungroupedWallets: [Wallet] {
        wallets.filter { $0.folder == nil }
    }

    private var walletRateSnapshots: [WalletRateSnapshot] {
        wallets.map { WalletRateSnapshot(assetCode: $0.assetCode, kind: $0.kind) }
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

    private var filteredTransactions: [Transaction] {
        transactions.filter { transaction in
            matchesTransactionSearch(transaction)
        }
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
                    TextField(
                        L10n.text("history.search_placeholder", lang: uiLanguageCode),
                        text: $transactionSearchText
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if transactions.isEmpty {
                        Text(L10n.text("home.no_transactions", lang: uiLanguageCode))
                            .foregroundStyle(.secondary)
                    } else {
                        if filteredTransactions.isEmpty {
                            Text(L10n.text("history.no_matches", lang: uiLanguageCode))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredTransactions, id: \.persistentModelID) { transaction in
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
            }
            .navigationTitle(L10n.text("app.name", lang: uiLanguageCode))
            .onAppear {
                initializeFolderCollapseIfNeeded()
            }
            .onChange(of: walletFolders.count) {
                syncFolderCollapseState()
            }
            .onChange(of: baseCurrencyCode) {
                let snapshots = walletRateSnapshots
                Task { await rateService.refreshAllRates(base: baseCurrencyCode, wallets: snapshots, force: true) }
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
                        let snapshots = walletRateSnapshots
                        Task { await rateService.refreshAllRates(base: baseCurrencyCode, wallets: snapshots, force: true) }
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
                processRecurringRulesIfNeeded()
                let snapshots = walletRateSnapshots
                await rateService.refreshAllRates(base: baseCurrencyCode, wallets: snapshots, force: false)
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
                    try? modelContext.save()
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
        try? modelContext.save()
    }
    
    private func deleteWalletFolder(_ folder: WalletFolder) {
        for wallet in wallets where wallet.folder?.persistentModelID == folder.persistentModelID {
            wallet.folder = nil
        }
        collapsedFolderIDs.remove(folder.persistentModelID)
        modelContext.delete(folder)
        try? modelContext.save()
    }
    
    private func toggleFolder(_ folder: WalletFolder) {
        if collapsedFolderIDs.contains(folder.persistentModelID) {
            collapsedFolderIDs.remove(folder.persistentModelID)
        } else {
            collapsedFolderIDs.insert(folder.persistentModelID)
        }
    }

    private func processRecurringRulesIfNeeded() {
        let now = Date()
        let maxGeneratedPerRule = 120
        var didMutateData = false

        for rule in recurringRules where rule.isActive {
            guard let wallet = rule.wallet else {
                rule.isActive = false
                rule.updatedAt = now
                didMutateData = true
                continue
            }
            guard rule.type != .transfer else {
                rule.isActive = false
                rule.updatedAt = now
                didMutateData = true
                continue
            }

            var generatedCount = 0
            while rule.nextRunDate <= now && generatedCount < maxGeneratedPerRule {
                let scheduledDate = rule.nextRunDate
                createRecurringTransaction(from: rule, wallet: wallet, date: scheduledDate)
                rule.nextRunDate = nextRecurringDate(
                    after: scheduledDate,
                    frequency: rule.frequency,
                    interval: rule.interval
                )
                rule.updatedAt = now
                generatedCount += 1
                didMutateData = true
            }
        }
        if didMutateData {
            try? modelContext.save()
        }
    }

    private func createRecurringTransaction(from rule: RecurringTransactionRule, wallet: Wallet, date: Date) {
        rule.currencyCode = wallet.assetCode

        let transaction = Transaction(
            amount: rule.amount,
            currencyCode: wallet.assetCode,
            date: date,
            note: recurringNote(for: rule),
            type: rule.type,
            walletNameSnapshot: wallet.name,
            walletKindRaw: wallet.kind.rawValue,
            walletColorHexSnapshot: wallet.colorHex,
            category: rule.category,
            wallet: wallet
        )
        modelContext.insert(transaction)

        switch rule.type {
        case .expense:
            wallet.balance -= rule.amount
        case .income:
            wallet.balance += rule.amount
        case .transfer:
            break
        }
    }

    private func recurringNote(for rule: RecurringTransactionRule) -> String? {
        let trimmed = rule.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "\(L10n.text("recurring.note_prefix", lang: uiLanguageCode)): \(rule.title)"
        }
        return trimmed
    }

    private func nextRecurringDate(after date: Date, frequency: RecurrenceFrequency, interval: Int) -> Date {
        let calendar = Calendar.current
        let safeInterval = max(1, interval)
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: safeInterval, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: safeInterval, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: safeInterval, to: date) ?? date
        }
    }

    private func matchesTransactionSearch(_ transaction: Transaction) -> Bool {
        let query = transactionSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return true }

        let typeTitle: String = {
            switch resolvedTransactionType(for: transaction) {
            case .expense:
                return L10n.text("common.expenses", lang: uiLanguageCode)
            case .income:
                return L10n.text("common.income", lang: uiLanguageCode)
            case .transfer:
                return L10n.text("common.transfer", lang: uiLanguageCode)
            }
        }()

        let searchBlob = [
            transaction.category?.name ?? "",
            transaction.note ?? "",
            transaction.walletNameSnapshot ?? "",
            transaction.transferWalletNameSnapshot ?? "",
            transaction.currencyCode,
            typeTitle
        ]
            .joined(separator: " ")
            .lowercased()

        return searchBlob.contains(query)
    }

    private func resolvedTransactionType(for transaction: Transaction) -> TransactionType {
        if let type = transaction.type {
            return type
        }
        if transaction.category?.type == .income {
            return .income
        }
        return .expense
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
                viewingWallet = WalletDetailPayload(
                    id: wallet.persistentModelID,
                    name: wallet.name,
                    assetCode: wallet.assetCode,
                    balance: wallet.balance,
                    kind: wallet.kind
                )
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

struct WalletDetailPayload: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let assetCode: String
    let balance: Decimal
    let kind: AssetKind
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

extension RecurrenceFrequency {
    func title(lang: String) -> String {
        switch self {
        case .daily:
            return L10n.text("recurring.frequency.daily", lang: lang)
        case .weekly:
            return L10n.text("recurring.frequency.weekly", lang: lang)
        case .monthly:
            return L10n.text("recurring.frequency.monthly", lang: lang)
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
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
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

    private var walletRateSnapshots: [WalletRateSnapshot] {
        analyticsWallets.map { WalletRateSnapshot(assetCode: $0.assetCode, kind: $0.kind) }
    }
    
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

                if subscriptionManager.isUnlocked(.advancedAnalytics) {
                    Section(L10n.text("pro.analytics.advanced_title", lang: uiLanguageCode)) {
                        Text(L10n.text("pro.analytics.history_hint", lang: uiLanguageCode))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        analyticsMetricRow(
                            title: L10n.text("pro.analytics.tx_count", lang: uiLanguageCode),
                            value: "\(transactionsInCurrentRange.count)"
                        )
                        analyticsMetricRow(
                            title: L10n.text("pro.analytics.avg_expense_tx", lang: uiLanguageCode),
                            value: formatAmount(averageExpenseTransaction)
                        )
                        analyticsMetricRow(
                            title: L10n.text("pro.analytics.income_trend", lang: uiLanguageCode),
                            value: percentChangeText(current: rangeIncome, previous: previousRangeIncome)
                        )
                        analyticsMetricRow(
                            title: L10n.text("pro.analytics.expense_trend", lang: uiLanguageCode),
                            value: percentChangeText(current: rangeExpenseAbs, previous: previousRangeExpenseAbs)
                        )
                        analyticsMetricRow(
                            title: L10n.text("pro.analytics.top_day", lang: uiLanguageCode),
                            value: topExpenseDayText
                        )
                        analyticsMetricRow(
                            title: L10n.text("pro.analytics.largest_expense", lang: uiLanguageCode),
                            value: largestExpenseText
                        )
                        analyticsMetricRow(
                            title: L10n.text("pro.analytics.savings_ratio", lang: uiLanguageCode),
                            value: savingsRateText
                        )
                        Text(L10n.text("pro.analytics.savings_ratio_hint", lang: uiLanguageCode))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if subscriptionManager.isUnlocked(.aiInsights) {
                    Section(L10n.text("pro.ai.daily_tip.title", lang: uiLanguageCode)) {
                        Text(L10n.text("pro.ai.daily_tip.hint", lang: uiLanguageCode))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        analyticsMetricRow(
                            title: L10n.text("pro.ai.daily_tip.today_spend", lang: uiLanguageCode),
                            value: todaySpendText
                        )
                        analyticsMetricRow(
                            title: L10n.text("pro.ai.daily_tip.target", lang: uiLanguageCode),
                            value: todayTargetText
                        )

                        Text(dailySavingsTipText)
                            .font(.subheadline)
                    }

                    Section(L10n.text("pro.ai.title", lang: uiLanguageCode)) {
                        ForEach(aiInsights, id: \.self) { insight in
                            Text("• \(insight)")
                                .font(.subheadline)
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
            let snapshots = walletRateSnapshots
            await rateService.refreshAllRates(base: baseCurrencyCode, wallets: snapshots, force: false)
        }
        .onChange(of: selectedRange) {
            rangeAnchor = Date()
        }
        .onChange(of: baseCurrencyCode) {
            let snapshots = walletRateSnapshots
            Task { await rateService.refreshAllRates(base: baseCurrencyCode, wallets: snapshots, force: true) }
        }
    }

    @ViewBuilder
    private func analyticsMetricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            if isNumbersHidden {
                Text("***")
                    .font(.subheadline.weight(.semibold))
            } else {
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
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

    private var transactionsInCurrentRange: [Transaction] {
        transactions(in: selectedRange.dateRange(anchor: rangeAnchor))
    }

    private var transactionsInPreviousRange: [Transaction] {
        let previousAnchor = selectedRange.shift(anchor: rangeAnchor, by: -1)
        return transactions(in: selectedRange.dateRange(anchor: previousAnchor))
    }

    private var rangeIncome: Decimal {
        incomeTotal(for: transactionsInCurrentRange)
    }

    private var previousRangeIncome: Decimal {
        incomeTotal(for: transactionsInPreviousRange)
    }

    private var rangeExpenseAbs: Decimal {
        expenseTotal(for: transactionsInCurrentRange)
    }

    private var previousRangeExpenseAbs: Decimal {
        expenseTotal(for: transactionsInPreviousRange)
    }

    private var averageExpenseTransaction: Decimal {
        let expenses = expenseTransactionsInCurrentRange
        guard !expenses.isEmpty else { return 0 }
        return NSDecimalNumber(decimal: rangeExpenseAbs)
            .dividing(by: NSDecimalNumber(value: expenses.count))
            .decimalValue
    }

    private var expenseTransactionsInCurrentRange: [Transaction] {
        transactionsInCurrentRange.filter { resolvedTransactionType(for: $0) == .expense }
    }

    private var topExpenseDayText: String {
        guard let daySummary = topExpenseDay else {
            return L10n.text("pro.analytics.no_data", lang: uiLanguageCode)
        }
        let dayText = DateFormatterCache.dayShortYear(lang: uiLanguageCode).string(from: daySummary.day)
        return "\(dayText) • \(formatAmount(daySummary.amount))"
    }

    private var largestExpenseText: String {
        guard let largest = largestExpenseTransaction else {
            return L10n.text("pro.analytics.no_data", lang: uiLanguageCode)
        }
        let amountText = formatAmount(convertedAbsoluteAmount(for: largest))
        let categoryText = largest.category?.name ?? L10n.text("transaction.untagged", lang: uiLanguageCode)
        return "\(amountText) • \(categoryText)"
    }

    private var topExpenseDay: (day: Date, amount: Decimal)? {
        var sumsByDay: [Date: Decimal] = [:]
        let calendar = Calendar.current

        for transaction in expenseTransactionsInCurrentRange {
            let day = calendar.startOfDay(for: transaction.date)
            sumsByDay[day, default: 0] += convertedAbsoluteAmount(for: transaction)
        }

        return sumsByDay.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    private var largestExpenseTransaction: Transaction? {
        expenseTransactionsInCurrentRange.max(by: { lhs, rhs in
            convertedAbsoluteAmount(for: lhs) < convertedAbsoluteAmount(for: rhs)
        })
    }

    private func percentChangeText(current: Decimal, previous: Decimal) -> String {
        guard previous > 0 else {
            return L10n.text("pro.analytics.not_enough_history", lang: uiLanguageCode)
        }
        let diff = NSDecimalNumber(decimal: current - previous)
            .dividing(by: NSDecimalNumber(decimal: previous))
            .multiplying(by: NSDecimalNumber(value: 100))
            .doubleValue
        let rounded = DecimalFormatter.doubleString(from: abs(diff), minimumFractionDigits: 0, maximumFractionDigits: 1)
        let sign = diff >= 0 ? "+" : "-"
        return "\(sign)\(rounded)%"
    }

    private func transactions(in dateRange: (start: Date, end: Date)) -> [Transaction] {
        transactions.filter { transaction in
            guard transaction.date >= dateRange.start && transaction.date <= dateRange.end else { return false }
            if let selectedWalletKey {
                return transaction.walletNameSnapshot == selectedWalletKey.name &&
                    transaction.currencyCode == selectedWalletKey.assetCode
            }
            return true
        }
    }

    private func incomeTotal(for rangeTransactions: [Transaction]) -> Decimal {
        var total = Decimal(0)
        for transaction in rangeTransactions {
            let type = resolvedTransactionType(for: transaction)
            guard type == .income else { continue }
            total += convertedAbsoluteAmount(for: transaction)
        }
        return total
    }

    private func expenseTotal(for rangeTransactions: [Transaction]) -> Decimal {
        var total = Decimal(0)
        for transaction in rangeTransactions {
            let type = resolvedTransactionType(for: transaction)
            guard type == .expense else { continue }
            total += convertedAbsoluteAmount(for: transaction)
        }
        return total
    }

    private func convertedAbsoluteAmount(for transaction: Transaction) -> Decimal {
        let converted = rateService.convert(
            amount: transaction.amount,
            from: transaction.currencyCode,
            kind: kindForTransaction(transaction),
            to: baseCurrencyCode
        ) ?? transaction.amount
        return absDecimal(converted)
    }

    private var averageDailyExpense: Decimal {
        guard daysCountInCurrentRange > 0 else { return 0 }
        return NSDecimalNumber(decimal: rangeExpenseAbs)
            .dividing(by: NSDecimalNumber(value: daysCountInCurrentRange))
            .decimalValue
    }

    private var projectedMonthExpense: Decimal {
        let daysInMonth = Calendar.current.range(of: .day, in: .month, for: rangeAnchor)?.count ?? 30
        return NSDecimalNumber(decimal: averageDailyExpense)
            .multiplying(by: NSDecimalNumber(value: daysInMonth))
            .decimalValue
    }

    private var daysCountInCurrentRange: Int {
        let range = selectedRange.dateRange(anchor: rangeAnchor)
        let start = Calendar.current.startOfDay(for: range.start)
        let end = Calendar.current.startOfDay(for: range.end)
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, days + 1)
    }

    private var savingsRateText: String {
        guard rangeIncome > 0 else { return "0%" }
        let net = rangeIncome - rangeExpenseAbs
        let percent = NSDecimalNumber(decimal: net)
            .dividing(by: NSDecimalNumber(decimal: rangeIncome))
            .multiplying(by: NSDecimalNumber(value: 100))
            .doubleValue
        let rounded = DecimalFormatter.doubleString(from: percent, minimumFractionDigits: 0, maximumFractionDigits: 0)
        return "\(rounded)%"
    }

    private var aiInsights: [String] {
        guard !transactionsInCurrentRange.isEmpty else {
            return [L10n.text("pro.ai.empty", lang: uiLanguageCode)]
        }

        var insights: [String] = []
        var expenseByCategory: [String: Decimal] = [:]

        for transaction in transactionsInCurrentRange {
            guard resolvedTransactionType(for: transaction) == .expense else { continue }
            let converted = rateService.convert(
                amount: transaction.amount,
                from: transaction.currencyCode,
                kind: kindForTransaction(transaction),
                to: baseCurrencyCode
            ) ?? transaction.amount
            let amount = absDecimal(converted)
            let categoryName = transaction.category?.name ?? L10n.text("transaction.untagged", lang: uiLanguageCode)
            expenseByCategory[categoryName, default: 0] += amount
        }

        if let top = expenseByCategory.max(by: { $0.value < $1.value }) {
            insights.append(
                "\(L10n.text("pro.ai.top_category", lang: uiLanguageCode)): \(top.key) — \(formatAmount(top.value))."
            )
        }

        if rangeIncome > 0 {
            let ratio = NSDecimalNumber(decimal: rangeExpenseAbs)
                .dividing(by: NSDecimalNumber(decimal: rangeIncome))
                .doubleValue
            if ratio > 0.9 {
                insights.append(L10n.text("pro.ai.high_burn", lang: uiLanguageCode))
            } else if ratio < 0.7 {
                insights.append(L10n.text("pro.ai.healthy_burn", lang: uiLanguageCode))
            }
        }

        if averageDailyExpense > 0 {
            insights.append(
                "\(L10n.text("pro.ai.daily_spend", lang: uiLanguageCode)): \(formatAmount(averageDailyExpense))."
            )
        }

        if projectedMonthExpense > rangeExpenseAbs && selectedRange != .month {
            insights.append(
                "\(L10n.text("pro.ai.projection_hint", lang: uiLanguageCode)): \(formatAmount(projectedMonthExpense))."
            )
        }

        if insights.isEmpty {
            insights.append(L10n.text("pro.ai.empty", lang: uiLanguageCode))
        }
        return Array(insights.prefix(3))
    }

    private var todayDateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? Date()
        return (start, end)
    }

    private var rolling7DayDateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let end = todayDateRange.end
        let startOfToday = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        return (start, end)
    }

    private var todayExpenseTransactions: [Transaction] {
        transactions(in: todayDateRange).filter { resolvedTransactionType(for: $0) == .expense }
    }

    private var todayExpenseTotal: Decimal {
        expenseTotal(for: todayExpenseTransactions)
    }

    private var rolling7DayExpenseTransactions: [Transaction] {
        transactions(in: rolling7DayDateRange).filter { resolvedTransactionType(for: $0) == .expense }
    }

    private var rolling7DayAverageExpense: Decimal {
        let total = expenseTotal(for: rolling7DayExpenseTransactions)
        return NSDecimalNumber(decimal: total)
            .dividing(by: NSDecimalNumber(value: 7))
            .decimalValue
    }

    private var todaySavingsTarget: Decimal {
        guard rolling7DayAverageExpense > 0 else { return 0 }
        return NSDecimalNumber(decimal: rolling7DayAverageExpense)
            .multiplying(by: NSDecimalNumber(value: 0.9))
            .decimalValue
    }

    private var todaySpendText: String {
        formatAmount(todayExpenseTotal)
    }

    private var todayTargetText: String {
        guard todaySavingsTarget > 0 else {
            return L10n.text("pro.analytics.not_enough_history", lang: uiLanguageCode)
        }
        return formatAmount(todaySavingsTarget)
    }

    private var topTodayExpenseCategorySummary: (name: String, amount: Decimal)? {
        var sums: [String: Decimal] = [:]
        for transaction in todayExpenseTransactions {
            let categoryName = transaction.category?.name ?? L10n.text("transaction.untagged", lang: uiLanguageCode)
            sums[categoryName, default: 0] += convertedAbsoluteAmount(for: transaction)
        }
        guard let top = sums.max(by: { $0.value < $1.value }) else { return nil }
        return (top.key, top.value)
    }

    private var dailySavingsTipText: String {
        if isNumbersHidden {
            return L10n.text("pro.ai.daily_tip.hidden", lang: uiLanguageCode)
        }

        guard !todayExpenseTransactions.isEmpty else {
            return L10n.text("pro.ai.daily_tip.no_spend", lang: uiLanguageCode)
        }

        guard rolling7DayExpenseTransactions.count > 1, todaySavingsTarget > 0 else {
            if let top = topTodayExpenseCategorySummary {
                return localizedFormat("pro.ai.daily_tip.starting_category", top.name)
            }
            return L10n.text("pro.ai.daily_tip.starting_generic", lang: uiLanguageCode)
        }

        if todayExpenseTotal > todaySavingsTarget {
            let overspend = todayExpenseTotal - todaySavingsTarget
            if let top = topTodayExpenseCategorySummary {
                let suggestedCut = min(overspend, top.amount)
                return localizedFormat("pro.ai.daily_tip.over_with_category", formatAmount(suggestedCut), top.name)
            }
            return localizedFormat("pro.ai.daily_tip.over_generic", formatAmount(overspend))
        }

        let reserve = todaySavingsTarget - todayExpenseTotal
        return localizedFormat("pro.ai.daily_tip.on_track", formatAmount(reserve))
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

    private func resolvedTransactionType(for transaction: Transaction) -> TransactionType {
        if let type = transaction.type {
            return type
        }
        if transaction.category?.type == .income {
            return .income
        }
        return .expense
    }

    private func formatAmount(_ amount: Decimal) -> String {
        "\(DecimalFormatter.string(from: amount)) \(baseCurrencyCode)"
    }

    private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        let format = L10n.text(key, lang: uiLanguageCode)
        return String(format: format, locale: DateFormatterCache.locale(for: uiLanguageCode), arguments: arguments)
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
        let percentText = DecimalFormatter.doubleString(
            from: percent,
            minimumFractionDigits: 0,
            maximumFractionDigits: 0
        )
        return "\(percentText)%"
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
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let supportedLanguageCodes: Set<String> = ["en", "ru", "uk", "sv"]

    private static func appNumberLocale() -> Locale {
        let languageCode = UserDefaults.standard.string(forKey: "appLanguageCode") ?? "system"
        if languageCode == "system" {
            return .autoupdatingCurrent
        }
        if supportedLanguageCodes.contains(languageCode) {
            return Locale(identifier: languageCode)
        }
        return .autoupdatingCurrent
    }

    private static func formatter(
        locale: Locale,
        usesGroupingSeparator: Bool,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = usesGroupingSeparator
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter
    }

    static func string(from value: Decimal, maximumFractionDigits: Int = 2) -> String {
        let formatter = formatter(
            locale: appNumberLocale(),
            usesGroupingSeparator: true,
            minimumFractionDigits: 0,
            maximumFractionDigits: maximumFractionDigits
        )
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(value)"
    }
    
    static func editingString(from value: Decimal, maximumFractionDigits: Int = 6) -> String {
        let formatter = formatter(
            locale: appNumberLocale(),
            usesGroupingSeparator: false,
            minimumFractionDigits: 0,
            maximumFractionDigits: maximumFractionDigits
        )
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(value)"
    }

    static func exportString(from value: Decimal, maximumFractionDigits: Int = 6) -> String {
        let formatter = formatter(
            locale: posixLocale,
            usesGroupingSeparator: false,
            minimumFractionDigits: 0,
            maximumFractionDigits: maximumFractionDigits
        )
        formatter.decimalSeparator = "."
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(value)"
    }

    static func doubleString(
        from value: Double,
        minimumFractionDigits: Int = 0,
        maximumFractionDigits: Int = 2
    ) -> String {
        let formatter = formatter(
            locale: appNumberLocale(),
            usesGroupingSeparator: true,
            minimumFractionDigits: minimumFractionDigits,
            maximumFractionDigits: maximumFractionDigits
        )
        let number = NSNumber(value: value)
        return formatter.string(from: number) ?? "\(value)"
    }
    
    static func parse(_ text: String) -> Decimal? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }

        cleaned = cleaned
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")

        let locale = appNumberLocale()
        if let groupingSeparator = locale.groupingSeparator, !groupingSeparator.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if let decimalSeparator = locale.decimalSeparator,
           !decimalSeparator.isEmpty,
           decimalSeparator != "." {
            cleaned = cleaned.replacingOccurrences(of: decimalSeparator, with: ".")
        }
        
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
        
        let allowed = CharacterSet(charactersIn: "0123456789.-")
        if cleaned.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }
        if cleaned.filter({ $0 == "." }).count > 1 {
            return nil
        }
        if cleaned.filter({ $0 == "-" }).count > 1 {
            return nil
        }
        if let minusIndex = cleaned.firstIndex(of: "-"), minusIndex != cleaned.startIndex {
            return nil
        }
        return Decimal(string: cleaned, locale: posixLocale)
    }

    static func parseOrEvaluate(_ text: String) -> Decimal? {
        if let parsed = parse(text) {
            return parsed
        }
        return AmountExpressionEvaluator.evaluate(text)
    }
}

enum AmountExpressionEvaluator {
    private enum Token {
        case number(Decimal)
        case op(Character)
        case leftParen
        case rightParen
    }

    static func evaluate(_ expression: String) -> Decimal? {
        guard let tokens = tokenize(expression), !tokens.isEmpty else { return nil }
        guard let rpn = toReversePolishNotation(tokens) else { return nil }
        return evaluateRPN(rpn)
    }

    private static func tokenize(_ expression: String) -> [Token]? {
        var tokens: [Token] = []
        var buffer = ""

        func flushBuffer() -> Bool {
            guard !buffer.isEmpty else { return true }
            guard let number = DecimalFormatter.parse(buffer) else { return false }
            tokens.append(.number(number))
            buffer = ""
            return true
        }

        func canTreatAsUnaryMinus() -> Bool {
            guard let last = tokens.last else { return true }
            switch last {
            case .op, .leftParen:
                return true
            case .number, .rightParen:
                return false
            }
        }

        for character in expression {
            if character.isWhitespace {
                continue
            }

            if character.isNumber || character == "." || character == "," || character == "_" || character == "'" || character == "’" {
                buffer.append(character)
                continue
            }

            if character == "-" && buffer.isEmpty && canTreatAsUnaryMinus() {
                buffer.append(character)
                continue
            }

            if character == "(" {
                guard flushBuffer() else { return nil }
                tokens.append(.leftParen)
                continue
            }

            if character == ")" {
                guard flushBuffer() else { return nil }
                tokens.append(.rightParen)
                continue
            }

            if character == "+" || character == "-" || character == "*" || character == "/" {
                guard flushBuffer() else { return nil }
                tokens.append(.op(character))
                continue
            }

            return nil
        }

        guard flushBuffer() else { return nil }
        return tokens
    }

    private static func toReversePolishNotation(_ tokens: [Token]) -> [Token]? {
        var output: [Token] = []
        var operators: [Token] = []

        for token in tokens {
            switch token {
            case .number:
                output.append(token)
            case .op(let current):
                while let last = operators.last {
                    switch last {
                    case .op(let topOperator):
                        if precedence(of: topOperator) >= precedence(of: current) {
                            output.append(operators.removeLast())
                        } else {
                            break
                        }
                    case .leftParen:
                        break
                    case .number, .rightParen:
                        return nil
                    }

                    if case .leftParen = operators.last {
                        break
                    }
                    if case .op(let topOperator) = operators.last,
                       precedence(of: topOperator) < precedence(of: current) {
                        break
                    }
                }
                operators.append(token)
            case .leftParen:
                operators.append(token)
            case .rightParen:
                var foundLeftParen = false
                while let last = operators.last {
                    operators.removeLast()
                    if case .leftParen = last {
                        foundLeftParen = true
                        break
                    }
                    output.append(last)
                }
                if !foundLeftParen {
                    return nil
                }
            }
        }

        while let last = operators.popLast() {
            if case .leftParen = last {
                return nil
            }
            output.append(last)
        }
        return output
    }

    private static func evaluateRPN(_ tokens: [Token]) -> Decimal? {
        var stack: [Decimal] = []

        for token in tokens {
            switch token {
            case .number(let value):
                stack.append(value)
            case .op(let op):
                guard stack.count >= 2 else { return nil }
                let rhs = stack.removeLast()
                let lhs = stack.removeLast()
                guard let result = apply(op: op, lhs: lhs, rhs: rhs) else { return nil }
                stack.append(result)
            case .leftParen, .rightParen:
                return nil
            }
        }

        guard stack.count == 1 else { return nil }
        return stack[0]
    }

    private static func precedence(of op: Character) -> Int {
        switch op {
        case "*", "/":
            return 2
        case "+", "-":
            return 1
        default:
            return 0
        }
    }

    private static func apply(op: Character, lhs: Decimal, rhs: Decimal) -> Decimal? {
        let left = NSDecimalNumber(decimal: lhs)
        let right = NSDecimalNumber(decimal: rhs)

        switch op {
        case "+":
            return left.adding(right).decimalValue
        case "-":
            return left.subtracting(right).decimalValue
        case "*":
            return left.multiplying(by: right).decimalValue
        case "/":
            if right == .zero {
                return nil
            }
            return left.dividing(by: right).decimalValue
        default:
            return nil
        }
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
                    .foregroundStyle(isNumbersHidden ? .primary : amountColor(currentTotal))
            }
            HStack {
                Text(L10n.text("analytics.previous", lang: lang))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayAmount(previousTotal))
                    .font(.subheadline)
                    .foregroundStyle(isNumbersHidden ? .primary : amountColor(previousTotal))
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
        let percentText = DecimalFormatter.doubleString(
            from: abs(percent),
            minimumFractionDigits: 1,
            maximumFractionDigits: 1
        )
        return "\(sign)\(deltaText) \(currency) (\(percentText)%)"
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
    
    let wallet: WalletDetailPayload
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
                    preselectedWalletID: wallet.id,
                    rateService: rateService
                )
            }
            .task {
                let snapshots = [WalletRateSnapshot(assetCode: wallet.assetCode, kind: wallet.kind)]
                await rateService.refreshAllRates(base: baseCurrencyCode, wallets: snapshots, force: false)
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
        try? modelContext.save()
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
        _transferAmountText = State(initialValue: transaction.flatMap { $0.transferAmount.map { DecimalFormatter.editingString(from: $0) } } ?? "")
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
        let amount = DecimalFormatter.parseOrEvaluate(amountText)
        if let amount, amount > 0 {
            return amount
        }
        return nil
    }
    
    private var parsedTransferAmount: Decimal? {
        let value = DecimalFormatter.parseOrEvaluate(transferAmountText)
        if let value, value > 0 {
            return value
        }
        return nil
    }

    private var calculatedAmountResult: Decimal? {
        guard DecimalFormatter.parse(amountText) == nil else { return nil }
        guard let value = AmountExpressionEvaluator.evaluate(amountText), value > 0 else { return nil }
        return value
    }

    private var calculatedTransferAmountResult: Decimal? {
        guard DecimalFormatter.parse(transferAmountText) == nil else { return nil }
        guard let value = AmountExpressionEvaluator.evaluate(transferAmountText), value > 0 else { return nil }
        return value
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

                        if let calculatedTransferAmountResult {
                            Text("\(L10n.text("calculator.result", lang: uiLanguageCode)): \(DecimalFormatter.string(from: calculatedTransferAmountResult, maximumFractionDigits: 6))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(L10n.text("calculator.use_result", lang: uiLanguageCode)) {
                                transferAmountText = DecimalFormatter.editingString(from: calculatedTransferAmountResult)
                                isTransferAmountManuallyEdited = true
                            }
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

                    if let calculatedAmountResult {
                        Text("\(L10n.text("calculator.result", lang: uiLanguageCode)): \(DecimalFormatter.string(from: calculatedAmountResult, maximumFractionDigits: 6))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L10n.text("calculator.use_result", lang: uiLanguageCode)) {
                            amountText = DecimalFormatter.editingString(from: calculatedAmountResult)
                        }
                    }
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
        try? modelContext.save()
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
        let value = DecimalFormatter.parseOrEvaluate(balanceText)
        if let value, value >= 0 {
            return value
        }
        return nil
    }

    private var calculatedBalanceResult: Decimal? {
        guard DecimalFormatter.parse(balanceText) == nil else { return nil }
        guard let value = AmountExpressionEvaluator.evaluate(balanceText), value >= 0 else { return nil }
        return value
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

                    if let calculatedBalanceResult {
                        Text("\(L10n.text("calculator.result", lang: uiLanguageCode)): \(DecimalFormatter.string(from: calculatedBalanceResult, maximumFractionDigits: 6))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L10n.text("calculator.use_result", lang: uiLanguageCode)) {
                            balanceText = DecimalFormatter.editingString(from: calculatedBalanceResult)
                        }
                    }
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
        try? modelContext.save()
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
                        try? modelContext.save()
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
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @AppStorage("baseCurrencyCode") private var baseCurrencyCode = ""
    @AppStorage("appCountryCode") private var appCountryCode = ""
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("isRoundedAmounts") private var isRoundedAmounts = false
    @AppStorage("appleUserID") private var appleUserID = ""
    @AppStorage("appleUserEmail") private var appleUserEmail = ""
    @AppStorage("appleUserName") private var appleUserName = ""
    @AppStorage("emailUserEmail") private var emailUserEmail = ""
    @AppStorage("authMethod") private var authMethod = ""
    @AppStorage("didCompleteInitialSetup_v1") private var didCompleteInitialSetup = false

    @ObservedObject var rateService: RateService

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \RecurringTransactionRule.nextRunDate) private var recurringRules: [RecurringTransactionRule]

    @State private var selectedType: CategoryType = .expense
    @State private var isAddingCategory = false
    @State private var editingCategory: Category?
    @State private var isAddingRecurringRule = false
    @State private var editingRecurringRule: RecurringTransactionRule?
    @State private var showAppleAuthError = false
    @State private var appleAuthErrorMessage = ""
    @State private var showPaywall = false
    @State private var showEmailAuthSheet = false
    @State private var appleSignInCoordinator = AppleSignInCoordinator()
#if DEBUG
    @State private var cloudDebugStatus: ICloudBackupManager.SnapshotDebugStatus?
    @State private var cloudDebugMessage = ""
    @State private var isCloudDebugBusy = false
    @State private var cloudDebugOperationToken: UUID?
#endif
    
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

    private var recurringRulesSorted: [RecurringTransactionRule] {
        recurringRules.sorted { $0.nextRunDate < $1.nextRunDate }
    }

    private var countryOptions: [CountryOption] {
        CountryCatalog.options(lang: uiLanguageCode)
    }

    private var isAccountConnected: Bool {
        !appleUserID.isEmpty || !emailUserEmail.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("settings.account", lang: uiLanguageCode)) {
                    if !isAccountConnected {
                        AppleSignInActionButton(title: L10n.text("settings.account.sign_in_apple", lang: uiLanguageCode)) {
                            appleSignInCoordinator.start { result in
                                handleAppleSignIn(result: result)
                            }
                        }
                        Text(L10n.text("common.or", lang: uiLanguageCode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Button(L10n.text("settings.account.sign_in_email", lang: uiLanguageCode)) {
                            showEmailAuthSheet = true
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(authMethod == "email"
                                 ? L10n.text("settings.account.connected_email", lang: uiLanguageCode)
                                 : L10n.text("settings.account.connected", lang: uiLanguageCode))
                                .font(.subheadline.weight(.semibold))
                            if authMethod == "email" {
                                Text(emailUserEmail)
                                    .font(.subheadline)
                            } else if !appleUserName.isEmpty {
                                Text(appleUserName)
                                    .font(.subheadline)
                            }
                            if authMethod == "apple", !appleUserEmail.isEmpty {
                                Text(appleUserEmail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            clearAccountSession()
                        } label: {
                            Text(L10n.text("settings.account.sign_out", lang: uiLanguageCode))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
#if DEBUG
                if isAccountConnected {
                    Section("CloudKit Debug") {
                        if let status = cloudDebugStatus {
                            Text("Bucket: \(status.accountBucket)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text("Storage mode: \(status.storageMode)")
                                .font(.subheadline)

                            if let reason = status.storageReasonCode, !reason.isEmpty {
                                Text("Reason: \(reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let storageError = status.storageError, !storageError.isEmpty {
                                Text("Cloud error: \(storageError)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            Text("Last local backup: \(debugDateText(status.lastLocalSuccess))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Last CloudKit upload: \(debugDateText(status.lastCloudSuccess))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let cloudError = status.lastCloudError, !cloudError.isEmpty {
                                Text("Last upload error: \(cloudError)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            if let localError = status.lastLocalError, !localError.isEmpty {
                                Text("Last local backup error: \(localError)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("No debug status yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            refreshCloudDebugStatus()
                        } label: {
                            HStack {
                                Text("Refresh cloud status")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            forceCloudBackupNow()
                        } label: {
                            HStack {
                                Text("Force cloud backup now")
                                Spacer()
                                if isCloudDebugBusy {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            restoreFromCloudNow()
                        } label: {
                            HStack {
                                Text("Try restore from cloud")
                                Spacer()
                                if isCloudDebugBusy {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isCloudDebugBusy {
                            Button(role: .destructive) {
                                resetCloudDebugLock(message: "Debug lock reset manually.")
                            } label: {
                                HStack {
                                    Text("Reset debug lock")
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if !cloudDebugMessage.isEmpty {
                            Text(cloudDebugMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
#endif

                Section(L10n.text("pro.title_short", lang: uiLanguageCode)) {
                    if subscriptionManager.hasProAccess {
                        Label(L10n.text("pro.status.active", lang: uiLanguageCode), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(L10n.text("pro.upsell.short", lang: uiLanguageCode))
                            .foregroundStyle(.secondary)
                        Button(L10n.text("pro.cta.unlock", lang: uiLanguageCode)) {
                            showPaywall = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
#if DEBUG
                    Toggle(L10n.text("pro.debug.force_title", lang: uiLanguageCode), isOn: $subscriptionManager.debugProOverride)
                        .tint(controlsTint)
                    Text(L10n.text("pro.debug.force_hint", lang: uiLanguageCode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
#endif
                }

                Section {
                    Picker(L10n.text("settings.app_language", lang: uiLanguageCode), selection: $appLanguageCode) {
                        ForEach(languages, id: \.self) { code in
                            Text(L10n.languageDisplay(code: code, lang: uiLanguageCode)).tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(controlsTint)

                    Picker(L10n.text("settings.currency", lang: uiLanguageCode), selection: $baseCurrencyCode) {
                        ForEach(CurrencyCatalog.baseCurrencies, id: \.code) { currency in
                            Text(L10n.currencyDisplay(code: currency.code, fallbackName: currency.name, lang: uiLanguageCode))
                                .tag(currency.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(controlsTint)

                    Picker(L10n.text("settings.country", lang: uiLanguageCode), selection: $appCountryCode) {
                        ForEach(countryOptions, id: \.code) { country in
                            Text(country.name)
                                .tag(country.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(controlsTint)

                    Picker(L10n.text("settings.theme", lang: uiLanguageCode), selection: $appTheme) {
                        ForEach(themes, id: \.code) { item in
                            Text(L10n.text(item.titleKey, lang: uiLanguageCode))
                                .tag(item.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(controlsTint)

                    Toggle(L10n.text("settings.round_amounts", lang: uiLanguageCode), isOn: $isRoundedAmounts)
                        .tint(controlsTint)
                }

                Section {
                    if recurringRulesSorted.isEmpty {
                        Text(L10n.text("recurring.empty", lang: uiLanguageCode))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recurringRulesSorted, id: \.persistentModelID) { rule in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(rule.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(rule.isActive ? L10n.text("common.active", lang: uiLanguageCode) : L10n.text("common.inactive", lang: uiLanguageCode))
                                        .font(.caption)
                                        .foregroundStyle(rule.isActive ? .green : .secondary)
                                }
                                Text("\(DecimalFormatter.string(from: rule.amount)) \(rule.currencyCode)")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(rule.frequency.title(lang: uiLanguageCode)) • \(L10n.text("recurring.every", lang: uiLanguageCode)) \(rule.interval)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(L10n.text("recurring.next_run", lang: uiLanguageCode)): \(recurringDateText(rule.nextRunDate))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingRecurringRule = rule
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(rule.isActive ? L10n.text("common.pause", lang: uiLanguageCode) : L10n.text("common.resume", lang: uiLanguageCode)) {
                                    rule.isActive.toggle()
                                    rule.updatedAt = Date()
                                }
                                .tint(.orange)
                                Button(L10n.text("common.edit", lang: uiLanguageCode)) {
                                    editingRecurringRule = rule
                                }
                                .tint(Color(hex: "4A4A4AFF"))
                                Button(L10n.text("common.delete", lang: uiLanguageCode), role: .destructive) {
                                    modelContext.delete(rule)
                                    try? modelContext.save()
                                }
                                .tint(.red)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(L10n.text("settings.recurring", lang: uiLanguageCode))
                        Spacer()
                        Button {
                            isAddingRecurringRule = true
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "plus.circle")
                                Text(L10n.text("recurring.new", lang: uiLanguageCode))
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("recurring.new", lang: uiLanguageCode))
                    }
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
                                        try? modelContext.save()
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
            .sheet(isPresented: $isAddingRecurringRule) {
                AddRecurringRuleView()
            }
            .sheet(
                isPresented: Binding(
                    get: { editingRecurringRule != nil },
                    set: { if !$0 { editingRecurringRule = nil } }
                )
            ) {
                if let editingRecurringRule {
                    AddRecurringRuleView(rule: editingRecurringRule)
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(lang: uiLanguageCode)
                    .environmentObject(subscriptionManager)
            }
            .sheet(isPresented: $showEmailAuthSheet) {
                EmailAuthSheetView(lang: uiLanguageCode) { email in
                    handleEmailAuthSuccess(email: email)
                }
            }
            .alert(
                L10n.text("settings.account.error_title", lang: uiLanguageCode),
                isPresented: $showAppleAuthError
            ) {
                Button(L10n.text("common.ok", lang: uiLanguageCode), role: .cancel) {}
            } message: {
                Text(appleAuthErrorMessage)
            }
            .onAppear {
                if appCountryCode.isEmpty {
                    appCountryCode = CountryCatalog.defaultCountryCode()
                }
                validateAppleCredentialIfNeeded()
                persistSetupProfileIfPossible()
                Task { await subscriptionManager.start() }
#if DEBUG
                refreshCloudDebugStatus()
#endif
            }
            .onChange(of: appLanguageCode) {
                persistSetupProfileIfPossible()
            }
            .onChange(of: baseCurrencyCode) {
                persistSetupProfileIfPossible()
            }
            .onChange(of: appCountryCode) {
                persistSetupProfileIfPossible()
            }
#if DEBUG
            .onChange(of: isAccountConnected) {
                refreshCloudDebugStatus()
            }
#endif
        }
    }
    
    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }

    private var storageModeDiagnosticsText: String {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "storage.mode.active") ?? "local"
        let requestedCloud = defaults.bool(forKey: "storage.mode.requested_cloud")

        if mode == "cloud" {
            return L10n.text("settings.storage.mode.cloud", lang: uiLanguageCode)
        }
        if requestedCloud {
            return L10n.text("settings.storage.mode.local_fallback", lang: uiLanguageCode)
        }
        return L10n.text("settings.storage.mode.local", lang: uiLanguageCode)
    }

    private var storageFallbackReasonText: String? {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "storage.mode.active") ?? "local"
        let requestedCloud = defaults.bool(forKey: "storage.mode.requested_cloud")
        guard requestedCloud, mode != "cloud" else {
            return nil
        }

        let reasonCode = defaults.string(forKey: "storage.cloudkit.last_reason_code") ?? "generic"
        let localizationKey: String
        switch reasonCode {
        case "no_icloud_account":
            localizationKey = "settings.storage.reason.no_icloud_account"
        case "restricted":
            localizationKey = "settings.storage.reason.restricted"
        case "network":
            localizationKey = "settings.storage.reason.network"
        case "model_issue":
            localizationKey = "settings.storage.reason.model_issue"
        default:
            localizationKey = "settings.storage.reason.generic"
        }
        return L10n.text(localizationKey, lang: uiLanguageCode)
    }

    private var storageTechnicalErrorText: String? {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "storage.mode.active") ?? "local"
        let requestedCloud = defaults.bool(forKey: "storage.mode.requested_cloud")
        guard requestedCloud, mode != "cloud" else {
            return nil
        }

        let rawError = defaults.string(forKey: "storage.cloudkit.last_error")?.trimmed ?? ""
        guard !rawError.isEmpty else {
            return nil
        }

        let prefix = L10n.text("settings.storage.error_prefix", lang: uiLanguageCode)
        return "\(prefix): \(rawError)"
    }

    private func recurringDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = DateFormatterCache.locale(for: uiLanguageCode)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                appleAuthErrorMessage = L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
                showAppleAuthError = true
                return
            }
            showAppleAuthError = false
            emailUserEmail = ""
            appleUserID = credential.user
            authMethod = "apple"
            if let email = credential.email, !email.isEmpty {
                appleUserEmail = email
            }
            let given = credential.fullName?.givenName ?? ""
            let family = credential.fullName?.familyName ?? ""
            let fullName = [given, family]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !fullName.isEmpty {
                appleUserName = fullName
            }
            SessionEvents.postAccountSessionDidChange()
            syncBackupImmediately(accountIdentifier: "apple:\(credential.user)")
            triggerProRestoreAfterAuthorization()
            persistSetupProfileIfPossible()
#if DEBUG
            refreshCloudDebugStatus()
#endif
        case .failure(let error):
            if let appleError = error as? ASAuthorizationError, appleError.code == .canceled {
                return
            }
            appleAuthErrorMessage = localizedAppleSignInError(error)
            showAppleAuthError = true
        }
    }

    private func validateAppleCredentialIfNeeded() {
        guard authMethod != "email" else { return }
        let storedUserID = appleUserID
        guard !storedUserID.isEmpty else { return }

        let provider = ASAuthorizationAppleIDProvider()
        provider.getCredentialState(forUserID: storedUserID) { credentialState, error in
            Task { @MainActor in
                if let error {
                    // Background status check should not block UX with alerts.
                    // Keep stored account as-is unless Apple explicitly says it's revoked/notFound.
                    _ = error
                    return
                }
                if credentialState == .revoked || credentialState == .notFound {
                    clearAccountSession()
                }
            }
        }
    }

    private func clearAccountSession() {
        appleUserID = ""
        appleUserEmail = ""
        appleUserName = ""
        emailUserEmail = ""
        authMethod = ""
        SessionEvents.postAccountSessionDidChange()
    }

    private func handleEmailAuthSuccess(email: String) {
        appleUserID = ""
        appleUserEmail = ""
        appleUserName = ""
        emailUserEmail = email
        authMethod = "email"
        SessionEvents.postAccountSessionDidChange()
        syncBackupImmediately(accountIdentifier: "email:\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
        triggerProRestoreAfterAuthorization()
        persistSetupProfileIfPossible()
#if DEBUG
        refreshCloudDebugStatus()
#endif
    }

    private func syncBackupImmediately(accountIdentifier: String) {
        Task { @MainActor in
            let didRestore = (try? await ICloudBackupManager.restoreIfNeeded(
                modelContext: modelContext,
                accountIdentifier: accountIdentifier
            )) ?? false
            if ICloudBackupManager.shouldForceBackupAfterRestoreAttempt(
                modelContext: modelContext,
                didRestore: didRestore
            ) {
                ICloudBackupManager.backupIfNeeded(
                    modelContext: modelContext,
                    accountIdentifier: accountIdentifier,
                    force: true
                )
            }
        }
    }

    private func triggerProRestoreAfterAuthorization() {
        Task {
            await subscriptionManager.restoreAfterAuthorization()
        }
    }

#if DEBUG
    private var currentBackupAccountIdentifier: String? {
        switch authMethod {
        case "apple":
            guard !appleUserID.isEmpty else { return nil }
            return "apple:\(appleUserID)"
        case "email":
            let email = emailUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty else { return nil }
            return "email:\(email)"
        default:
            if !appleUserID.isEmpty {
                return "apple:\(appleUserID)"
            }
            let email = emailUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return email.isEmpty ? nil : "email:\(email)"
        }
    }

    private func refreshCloudDebugStatus() {
        guard let accountIdentifier = currentBackupAccountIdentifier else {
            cloudDebugStatus = nil
            cloudDebugMessage = "No active account identifier."
            return
        }
        cloudDebugStatus = ICloudBackupManager.debugStatus(accountIdentifier: accountIdentifier)
    }

    private func forceCloudBackupNow() {
        guard let accountIdentifier = currentBackupAccountIdentifier else {
            cloudDebugMessage = "No active account identifier."
            return
        }
        guard let token = startCloudDebugOperation(message: "Running forced backup...") else {
            return
        }
        Task { @MainActor in
            ICloudBackupManager.backupIfNeeded(
                modelContext: modelContext,
                accountIdentifier: accountIdentifier,
                force: true
            )
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refreshCloudDebugStatus()
            finishCloudDebugOperation(
                token: token,
                message: "Forced backup finished. Refresh CloudKit Dashboard."
            )
        }
    }

    private func restoreFromCloudNow() {
        guard let accountIdentifier = currentBackupAccountIdentifier else {
            cloudDebugMessage = "No active account identifier."
            return
        }
        guard let token = startCloudDebugOperation(message: "Trying restore from cloud...") else {
            return
        }
        Task { @MainActor in
            let restored = (try? await ICloudBackupManager.restoreIfNeeded(
                modelContext: modelContext,
                accountIdentifier: accountIdentifier
            )) ?? false
            refreshCloudDebugStatus()
            finishCloudDebugOperation(
                token: token,
                message: restored
                    ? "Restore completed from cloud snapshot."
                    : "No cloud snapshot found for this account."
            )
        }
    }

    private func startCloudDebugOperation(message: String) -> UUID? {
        if isCloudDebugBusy {
            cloudDebugMessage = "Another debug action is running. If it hangs, tap Reset debug lock."
            return nil
        }
        let token = UUID()
        cloudDebugOperationToken = token
        isCloudDebugBusy = true
        cloudDebugMessage = message

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard isCloudDebugBusy, cloudDebugOperationToken == token else { return }
            resetCloudDebugLock(message: "Debug action timed out. Try again.")
        }
        return token
    }

    private func finishCloudDebugOperation(token: UUID, message: String) {
        guard cloudDebugOperationToken == token else { return }
        cloudDebugOperationToken = nil
        isCloudDebugBusy = false
        cloudDebugMessage = message
    }

    private func resetCloudDebugLock(message: String) {
        cloudDebugOperationToken = nil
        isCloudDebugBusy = false
        cloudDebugMessage = message
    }

    private func debugDateText(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
#endif

    private func persistSetupProfileIfPossible() {
        guard didCompleteInitialSetup, !baseCurrencyCode.trimmed.isEmpty else { return }
        guard let accountID = currentSetupAccountID() else { return }
        let normalizedLanguage = normalizedLanguageCode(appLanguageCode)
        let normalizedCurrency = normalizedCurrencyCode(baseCurrencyCode)
        let normalizedCountry = normalizedCountryCode(appCountryCode, lang: normalizedLanguage)
        let profile = StoredSetupProfile(
            languageCode: normalizedLanguage,
            currencyCode: normalizedCurrency,
            countryCode: normalizedCountry,
            savedAtTimestamp: Date().timeIntervalSince1970
        )
        try? SetupProfileStore.save(profile, for: accountID)
    }

    private func currentSetupAccountID() -> String? {
        switch authMethod {
        case "apple":
            return SetupProfileStore.appleAccountID(appleUserID)
        case "email":
            return SetupProfileStore.emailAccountID(emailUserEmail)
        default:
            if let appleAccountID = SetupProfileStore.appleAccountID(appleUserID) {
                return appleAccountID
            }
            return SetupProfileStore.emailAccountID(emailUserEmail)
        }
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        let normalized = code.trimmed.lowercased()
        let supported = ["en", "ru", "uk", "sv"]
        if normalized == "system" {
            let systemCode = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return supported.contains(systemCode) ? systemCode : "en"
        }
        return supported.contains(normalized) ? normalized : "en"
    }

    private func normalizedCurrencyCode(_ code: String) -> String {
        let normalized = code.trimmed.uppercased()
        if CurrencyCatalog.baseCurrencies.contains(where: { $0.code == normalized }) {
            return normalized
        }
        return CurrencyCatalog.baseCurrencies.first?.code ?? "USD"
    }

    private func normalizedCountryCode(_ code: String, lang: String) -> String {
        let normalized = code.trimmed.uppercased()
        if CountryCatalog.options(lang: lang).contains(where: { $0.code == normalized }) {
            return normalized
        }
        return CountryCatalog.defaultCountryCode()
    }

    private func localizedAppleSignInError(_ error: Error) -> String {
        if let appleError = error as? ASAuthorizationError {
            switch appleError.code {
            case .canceled:
                return L10n.text("settings.account.error_canceled", lang: uiLanguageCode)
            case .invalidResponse:
                return L10n.text("settings.account.error_invalid_response", lang: uiLanguageCode)
            case .notHandled:
                return L10n.text("settings.account.error_not_handled", lang: uiLanguageCode)
            case .failed:
                return L10n.text("settings.account.error_failed", lang: uiLanguageCode)
            case .notInteractive:
                return L10n.text("settings.account.error_not_interactive", lang: uiLanguageCode)
            case .unknown:
                return L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
            case .matchedExcludedCredential, .credentialImport, .credentialExport, .preferSignInWithApple, .deviceNotConfiguredForPasskeyCreation:
                return L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
            @unknown default:
                return L10n.text("settings.account.error_unknown", lang: uiLanguageCode)
            }
        }
        return error.localizedDescription
    }
}

struct AddRecurringRuleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Wallet.name) private var wallets: [Wallet]

    private let rule: RecurringTransactionRule?

    @State private var title: String
    @State private var amountText: String
    @State private var note: String
    @State private var type: TransactionType
    @State private var frequency: RecurrenceFrequency
    @State private var interval: Int
    @State private var nextRunDate: Date
    @State private var selectedCategoryID: PersistentIdentifier?
    @State private var selectedWalletID: PersistentIdentifier?
    @State private var isActive: Bool

    init(rule: RecurringTransactionRule? = nil) {
        self.rule = rule
        _title = State(initialValue: rule?.title ?? "")
        _amountText = State(initialValue: rule.map { DecimalFormatter.editingString(from: $0.amount) } ?? "")
        _note = State(initialValue: rule?.note ?? "")
        let resolvedType: TransactionType = {
            guard let type = rule?.type else { return .expense }
            return type == .income ? .income : .expense
        }()
        _type = State(initialValue: resolvedType)
        _frequency = State(initialValue: rule?.frequency ?? .monthly)
        _interval = State(initialValue: max(1, rule?.interval ?? 1))
        _nextRunDate = State(initialValue: rule?.nextRunDate ?? Date())
        _selectedCategoryID = State(initialValue: rule?.category?.persistentModelID)
        _selectedWalletID = State(initialValue: rule?.wallet?.persistentModelID)
        _isActive = State(initialValue: rule?.isActive ?? true)
    }

    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }

    private var parsedAmount: Decimal? {
        guard let value = DecimalFormatter.parseOrEvaluate(amountText), value > 0 else { return nil }
        return value
    }

    private var calculatedAmountResult: Decimal? {
        guard DecimalFormatter.parse(amountText) == nil else { return nil }
        guard let value = AmountExpressionEvaluator.evaluate(amountText), value > 0 else { return nil }
        return value
    }

    private var selectedWallet: Wallet? {
        guard let selectedWalletID else { return nil }
        return wallets.first(where: { $0.persistentModelID == selectedWalletID })
    }

    private var filteredCategories: [Category] {
        let expectedType: CategoryType = (type == .income) ? .income : .expense
        return categories.filter { $0.type == expectedType }
    }

    private var canSave: Bool {
        guard parsedAmount != nil else { return false }
        guard selectedWallet != nil else { return false }
        guard selectedCategoryID != nil else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedTitle.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("common.name", lang: uiLanguageCode)) {
                    TextField(L10n.text("recurring.title_placeholder", lang: uiLanguageCode), text: $title)
                }

                Section(L10n.text("common.type", lang: uiLanguageCode)) {
                    Picker(L10n.text("common.type", lang: uiLanguageCode), selection: $type) {
                        Text(L10n.text("common.expenses", lang: uiLanguageCode)).tag(TransactionType.expense)
                        Text(L10n.text("common.income", lang: uiLanguageCode)).tag(TransactionType.income)
                    }
                    .pickerStyle(.segmented)
                }

                Section(L10n.text("home.wallets", lang: uiLanguageCode)) {
                    Picker(L10n.text("home.wallets", lang: uiLanguageCode), selection: $selectedWalletID) {
                        Text(L10n.text("transaction.select_wallet", lang: uiLanguageCode)).tag(PersistentIdentifier?.none)
                        ForEach(wallets, id: \.persistentModelID) { wallet in
                            Text(wallet.name).tag(Optional(wallet.persistentModelID))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(L10n.text("settings.tags", lang: uiLanguageCode)) {
                    Picker(L10n.text("settings.tags", lang: uiLanguageCode), selection: $selectedCategoryID) {
                        Text(L10n.text("transaction.select_tag", lang: uiLanguageCode)).tag(PersistentIdentifier?.none)
                        ForEach(filteredCategories, id: \.persistentModelID) { category in
                            Text(category.name).tag(Optional(category.persistentModelID))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(L10n.text("common.amount", lang: uiLanguageCode)) {
                    TextField(L10n.text("common.amount_placeholder", lang: uiLanguageCode), text: $amountText)
                        .keyboardType(.decimalPad)

                    if let calculatedAmountResult {
                        Text("\(L10n.text("calculator.result", lang: uiLanguageCode)): \(DecimalFormatter.string(from: calculatedAmountResult, maximumFractionDigits: 6))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L10n.text("calculator.use_result", lang: uiLanguageCode)) {
                            amountText = DecimalFormatter.editingString(from: calculatedAmountResult)
                        }
                    }
                }

                Section(L10n.text("recurring.schedule", lang: uiLanguageCode)) {
                    Picker(L10n.text("recurring.frequency", lang: uiLanguageCode), selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases, id: \.self) { option in
                            Text(option.title(lang: uiLanguageCode)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(
                        "\(L10n.text("recurring.interval", lang: uiLanguageCode)): \(interval)",
                        value: $interval,
                        in: 1...365
                    )

                    DatePicker(
                        L10n.text("recurring.next_run", lang: uiLanguageCode),
                        selection: $nextRunDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section(L10n.text("common.comment", lang: uiLanguageCode)) {
                    TextField(L10n.text("transaction.add_comment", lang: uiLanguageCode), text: $note, axis: .vertical)
                }

                Section {
                    Toggle(L10n.text("common.active", lang: uiLanguageCode), isOn: $isActive)
                }
            }
            .navigationTitle(rule == nil ? L10n.text("recurring.new", lang: uiLanguageCode) : L10n.text("recurring.edit", lang: uiLanguageCode))
            .keyboardDismissBehavior()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel", lang: uiLanguageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.save", lang: uiLanguageCode)) {
                        saveRule()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: type) {
                if let selectedCategoryID,
                   let category = categories.first(where: { $0.persistentModelID == selectedCategoryID }),
                   ((type == .income && category.type != .income) || (type == .expense && category.type != .expense)) {
                    self.selectedCategoryID = nil
                }
            }
            .onAppear {
                normalizeSelections()
            }
        }
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
    }

    private func saveRule() {
        guard let amount = parsedAmount else { return }
        guard let wallet = selectedWallet else { return }
        guard let categoryID = selectedCategoryID,
              let category = categories.first(where: { $0.persistentModelID == categoryID }) else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if let rule {
            rule.title = trimmedTitle
            rule.amount = amount
            rule.currencyCode = wallet.assetCode
            rule.type = type
            rule.frequency = frequency
            rule.interval = max(1, interval)
            rule.nextRunDate = nextRunDate
            rule.note = trimmedNote.isEmpty ? nil : trimmedNote
            rule.isActive = isActive
            rule.category = category
            rule.wallet = wallet
            rule.updatedAt = Date()
        } else {
            let newRule = RecurringTransactionRule(
                title: trimmedTitle,
                amount: amount,
                currencyCode: wallet.assetCode,
                type: type,
                frequency: frequency,
                interval: max(1, interval),
                nextRunDate: nextRunDate,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                isActive: isActive,
                category: category,
                wallet: wallet
            )
            modelContext.insert(newRule)
        }
        try? modelContext.save()
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

private enum EmailAuthMode: String, CaseIterable, Identifiable {
    case signIn
    case signUp

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .signIn: return "settings.account.auth_mode.sign_in"
        case .signUp: return "settings.account.auth_mode.sign_up"
        }
    }

    var actionKey: String {
        switch self {
        case .signIn: return "settings.account.sign_in_email"
        case .signUp: return "settings.account.create_email"
        }
    }
}

private struct EmailAuthSheetView: View {
    let lang: String
    let showsModePicker: Bool
    let onSuccess: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: EmailAuthMode
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSubmitting = false
    @State private var showError = false
    @State private var errorMessage = ""

    init(
        lang: String,
        initialMode: EmailAuthMode = .signIn,
        showsModePicker: Bool = true,
        onSuccess: @escaping (String) -> Void
    ) {
        self.lang = lang
        self.showsModePicker = showsModePicker
        self.onSuccess = onSuccess
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                if showsModePicker {
                    Section {
                        Picker(L10n.text("settings.account.auth_mode", lang: lang), selection: $mode) {
                            ForEach(EmailAuthMode.allCases, id: \.self) { item in
                                Text(L10n.text(item.titleKey, lang: lang)).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section(L10n.text("settings.account.email", lang: lang)) {
                    TextField(L10n.text("settings.account.email", lang: lang), text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }

                Section(L10n.text("settings.account.password", lang: lang)) {
                    SecureField(L10n.text("settings.account.password", lang: lang), text: $password)
                    if mode == .signUp {
                        SecureField(L10n.text("settings.account.confirm_password", lang: lang), text: $confirmPassword)
                    }
                }

                Section {
                    Button(L10n.text(mode.actionKey, lang: lang)) {
                        submit()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(isSubmitting || email.trimmed.isEmpty || password.isEmpty || (mode == .signUp && confirmPassword.isEmpty))
                }
            }
            .navigationTitle(L10n.text("settings.account", lang: lang))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.text("common.cancel", lang: lang)) {
                        dismiss()
                    }
                }
            }
        }
        .dismissKeyboardOnTap()
        .keyboardDismissBehavior()
        .alert(
            L10n.text("settings.account.error_title", lang: lang),
            isPresented: $showError
        ) {
            Button(L10n.text("common.ok", lang: lang), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let normalizedEmail = try EmailAuthManager.authenticate(
                mode: mode,
                email: email,
                password: password,
                confirmPassword: confirmPassword
            )
            onSuccess(normalizedEmail)
            dismiss()
        } catch {
            errorMessage = localizedEmailAuthError(error)
            showError = true
        }
    }

    private func localizedEmailAuthError(_ error: Error) -> String {
        guard let authError = error as? EmailAuthError else {
            return L10n.text("settings.account.error_unknown", lang: lang)
        }
        switch authError {
        case .invalidEmail:
            return L10n.text("settings.account.error_email_invalid", lang: lang)
        case .passwordTooShort:
            return L10n.text("settings.account.error_password_short", lang: lang)
        case .passwordMismatch:
            return L10n.text("settings.account.error_password_mismatch", lang: lang)
        case .accountAlreadyExists:
            return L10n.text("settings.account.error_email_exists", lang: lang)
        case .accountNotFound:
            return L10n.text("settings.account.error_email_not_found", lang: lang)
        case .invalidCredentials:
            return L10n.text("settings.account.error_invalid_credentials", lang: lang)
        case .storageFailure:
            return L10n.text("settings.account.error_storage", lang: lang)
        }
    }
}

private enum EmailAuthError: Error {
    case invalidEmail
    case passwordTooShort
    case passwordMismatch
    case accountAlreadyExists
    case accountNotFound
    case invalidCredentials
    case storageFailure
}

private struct StoredEmailCredentials: Codable {
    let email: String
    let saltBase64: String
    let hashBase64: String
}

private struct StoredSetupProfile: Codable {
    let languageCode: String
    let currencyCode: String
    let countryCode: String
    let savedAtTimestamp: TimeInterval
}

private enum SetupProfileStore {
    private static let service = "com.argentumvault.app.setup_profile"

    static func appleAccountID(_ userID: String) -> String? {
        let normalized = userID.trimmed
        guard !normalized.isEmpty else { return nil }
        return "apple:\(normalized)"
    }

    static func emailAccountID(_ email: String) -> String? {
        let normalized = email.trimmed.lowercased()
        guard !normalized.isEmpty else { return nil }
        return "email:\(normalized)"
    }

    static func load(for accountID: String) throws -> StoredSetupProfile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw EmailAuthError.storageFailure
        }
        do {
            return try JSONDecoder().decode(StoredSetupProfile.self, from: data)
        } catch {
            throw EmailAuthError.storageFailure
        }
    }

    static func save(_ profile: StoredSetupProfile, for accountID: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(profile)
        } catch {
            throw EmailAuthError.storageFailure
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw EmailAuthError.storageFailure
            }
            return
        }

        if status == errSecItemNotFound {
            var addQuery = query
            for (key, value) in updateAttributes {
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw EmailAuthError.storageFailure
            }
            return
        }

        throw EmailAuthError.storageFailure
    }
}

private enum EmailAuthManager {
    private static let service = "com.argentumvault.app.emailauth"
    private static let account = "primary"

    static func authenticate(
        mode: EmailAuthMode,
        email: String,
        password: String,
        confirmPassword: String
    ) throws -> String {
        switch mode {
        case .signIn:
            return try signIn(email: email, password: password)
        case .signUp:
            return try signUp(email: email, password: password, confirmPassword: confirmPassword)
        }
    }

    private static func signUp(email: String, password: String, confirmPassword: String) throws -> String {
        let normalizedEmail = try normalized(email: email)
        try validate(password: password)
        guard password == confirmPassword else {
            throw EmailAuthError.passwordMismatch
        }

        if try loadCredentials() != nil {
            throw EmailAuthError.accountAlreadyExists
        }

        let salt = try randomSalt(length: 16)
        let hash = passwordHash(password: password, salt: salt)
        let credentials = StoredEmailCredentials(
            email: normalizedEmail,
            saltBase64: salt.base64EncodedString(),
            hashBase64: hash.base64EncodedString()
        )
        try saveCredentials(credentials)
        return normalizedEmail
    }

    private static func signIn(email: String, password: String) throws -> String {
        let normalizedEmail = try normalized(email: email)
        guard let credentials = try loadCredentials() else {
            throw EmailAuthError.accountNotFound
        }

        guard credentials.email == normalizedEmail else {
            throw EmailAuthError.invalidCredentials
        }

        guard let salt = Data(base64Encoded: credentials.saltBase64),
              let expectedHash = Data(base64Encoded: credentials.hashBase64) else {
            throw EmailAuthError.storageFailure
        }

        let hash = passwordHash(password: password, salt: salt)
        guard hash == expectedHash else {
            throw EmailAuthError.invalidCredentials
        }
        return normalizedEmail
    }

    private static func normalized(email: String) throws -> String {
        let normalized = email.trimmed.lowercased()
        guard normalized.contains("@"), normalized.contains(".") else {
            throw EmailAuthError.invalidEmail
        }
        return normalized
    }

    private static func validate(password: String) throws {
        guard password.count >= 6 else {
            throw EmailAuthError.passwordTooShort
        }
    }

    private static func passwordHash(password: String, salt: Data) -> Data {
        var payload = Data()
        payload.append(salt)
        payload.append(contentsOf: password.utf8)
        return Data(SHA256.hash(data: payload))
    }

    private static func randomSalt(length: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else {
            throw EmailAuthError.storageFailure
        }
        return Data(bytes)
    }

    private static func loadCredentials() throws -> StoredEmailCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw EmailAuthError.storageFailure
        }
        do {
            return try JSONDecoder().decode(StoredEmailCredentials.self, from: data)
        } catch {
            throw EmailAuthError.storageFailure
        }
    }

    private static func saveCredentials(_ credentials: StoredEmailCredentials) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw EmailAuthError.storageFailure
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw EmailAuthError.storageFailure
            }
            return
        }

        if status == errSecItemNotFound {
            var addQuery = query
            for (key, value) in updateAttributes {
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw EmailAuthError.storageFailure
            }
            return
        }

        throw EmailAuthError.storageFailure
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AppleSignInActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "applelogo")
                    .font(.headline)
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black)
        .foregroundStyle(.white)
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                Category.self,
                Transaction.self,
                Asset.self,
                Wallet.self,
                WalletFolder.self,
                RecurringTransactionRule.self,
                CategoryBudget.self
            ],
            inMemory: true
        )
}
