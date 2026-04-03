import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct QuickExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguageCode") private var appLanguageCode = "system"
    @AppStorage("quickExpense.lastWalletSyncID") private var lastWalletSyncID = ""
    @AppStorage("quickExpense.lastCategorySyncID") private var lastCategorySyncID = ""
    @ObservedObject private var moneyRuntimeDebug = MoneyRuntimeDebugStore.shared

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Wallet.name) private var wallets: [Wallet]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    @FocusState private var isAmountFieldFocused: Bool

    private let defaultCurrencyCode: String

    @State private var amountText = ""
    @State private var selectedWalletSyncID: String?
    @State private var selectedCategorySyncID: String?
    @State private var date = Date()
    @State private var note = ""
    @State private var isNoteExpanded = false
    @State private var isSaving = false
    @State private var saveErrorMessage = ""
    @State private var showSaveErrorAlert = false

    init(defaultCurrencyCode: String) {
        self.defaultCurrencyCode = defaultCurrencyCode
    }

    private var uiLanguageCode: String {
        if appLanguageCode == "system" {
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return ["en", "ru", "uk", "sv"].contains(code) ? code : "en"
        }
        return appLanguageCode
    }

    private var expenseCategories: [Category] {
        categories
            .filter { $0.type == .expense }
            .sorted {
                $0.displayName(languageCode: uiLanguageCode)
                    .localizedCaseInsensitiveCompare($1.displayName(languageCode: uiLanguageCode)) == .orderedAscending
            }
    }

    private var recentExpenseCategories: [Category] {
        var seenSyncIDs: Set<String> = []
        var result: [Category] = []

        for transaction in transactions {
            guard (transaction.type ?? .expense) == .expense else { continue }
            guard let category = transaction.category, category.type == .expense else { continue }
            guard seenSyncIDs.insert(category.syncID).inserted else { continue }
            result.append(category)
            if result.count == 6 {
                break
            }
        }

        return result
    }

    private var preferredWallet: Wallet? {
        if let storedWallet = wallets.first(where: { $0.syncID == lastWalletSyncID }), !lastWalletSyncID.isEmpty {
            return storedWallet
        }

        if let recentWallet = transactions.first(where: {
            ($0.type ?? .expense) == .expense && $0.wallet != nil
        })?.wallet {
            return recentWallet
        }

        return wallets.first
    }

    private var preferredCategory: Category? {
        if let storedCategory = expenseCategories.first(where: { $0.syncID == lastCategorySyncID }), !lastCategorySyncID.isEmpty {
            return storedCategory
        }

        if let recentCategory = recentExpenseCategories.first {
            return recentCategory
        }

        return expenseCategories.first
    }

    private var selectedWallet: Wallet? {
        guard let selectedWalletSyncID else { return nil }
        return wallets.first(where: { $0.syncID == selectedWalletSyncID })
    }

    private var selectedCategory: Category? {
        guard let selectedCategorySyncID else { return nil }
        return expenseCategories.first(where: { $0.syncID == selectedCategorySyncID })
    }

    private var parsedAmount: Decimal? {
        SecurityValidation.sanitizePositiveAmount(DecimalFormatter.parseOrEvaluate(amountText))
    }

    private var amountValidationMessage: String? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, parsedAmount == nil else { return nil }
        return L10n.text("quick_expense.amount_invalid", lang: uiLanguageCode)
    }

    private var canSave: Bool {
        !isSaving
            && SecurityValidation.isDateInSupportedRange(date)
            && parsedAmount != nil
            && selectedWallet != nil
            && selectedCategory != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    amountSection
                    walletSection
                    categorySection
                    dateSection
                    noteSection

                    if let saveError = inlineSaveErrorMessage {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel(saveError)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.text("quick_expense.title", lang: uiLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .task {
                applySelectionDefaults()
                MoneyRuntimeDebug.recordLiveField(
                    path: "QuickExpenseView/RawAmountTextField",
                    text: amountText,
                    parsed: parsedAmount
                )
                await focusAmountField()
            }
            .onChange(of: wallets.count) {
                applySelectionDefaults()
            }
            .onChange(of: categories.count) {
                applySelectionDefaults()
            }
            .onChange(of: selectedWalletSyncID) {
                if selectedWallet == nil {
                    applySelectionDefaults()
                }
            }
            .onChange(of: selectedCategorySyncID) {
                if selectedCategory == nil {
                    applySelectionDefaults()
                }
            }
            .onChange(of: amountText) {
                MoneyRuntimeDebug.recordLiveField(
                    path: "QuickExpenseView/RawAmountTextField",
                    text: amountText,
                    parsed: parsedAmount
                )
            }
            .onChange(of: note) {
                note = SecurityValidation.boundedMultilineInput(
                    note,
                    maxLength: SecurityValidation.maxNoteLength
                )
            }
            .onChange(of: date) {
                date = SecurityValidation.sanitizeDate(date)
            }
            .alert(
                L10n.text("quick_expense.save_failed_title", lang: uiLanguageCode),
                isPresented: $showSaveErrorAlert
            ) {
                Button(L10n.text("common.ok", lang: uiLanguageCode), role: .cancel) {}
            } message: {
                Text(saveErrorMessage)
            }
        }
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("common.amount", lang: uiLanguageCode))
                .font(.headline)
                .foregroundStyle(.secondary)

            RawAmountTextField(
                placeholder: L10n.text("common.amount_placeholder", lang: uiLanguageCode),
                text: $amountText,
                traceID: "quick_expense.amount",
                accessibilityIdentifier: "quick_expense.amount",
                accessibilityLabel: L10n.text("a11y.quick_expense_amount", lang: uiLanguageCode),
                font: amountFieldFont,
                isFocused: $isAmountFieldFocused
            )
                .accessibilityIdentifier("quick_expense.amount")
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(amountValidationMessage == nil ? Color.clear : Color.red.opacity(0.5), lineWidth: 1)
                }

            MoneyRuntimeDebugPanel(
                runtimePath: "QuickExpenseView/RawAmountTextField",
                fieldText: moneyRuntimeDebug.liveFieldText,
                parsedText: moneyRuntimeDebug.liveParsedText
            )

            if let amountValidationMessage {
                Text(amountValidationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var walletSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("home.wallets", lang: uiLanguageCode))
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.text("home.wallets", lang: uiLanguageCode), selection: $selectedWalletSyncID) {
                    Text(L10n.text("transaction.select_wallet", lang: uiLanguageCode)).tag(String?.none)
                    ForEach(wallets, id: \.syncID) { wallet in
                        Text(wallet.name).tag(Optional(wallet.syncID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(L10n.text("a11y.quick_expense_wallet", lang: uiLanguageCode))

                if let selectedWallet {
                    Text("\(selectedWallet.name) • \(selectedWallet.assetCode)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if wallets.isEmpty {
                    Text(L10n.text("quick_expense.no_wallets", lang: uiLanguageCode))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("settings.tags", lang: uiLanguageCode))
                .font(.headline)
                .foregroundStyle(.secondary)

            if !recentExpenseCategories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("quick_expense.recent_categories", lang: uiLanguageCode))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(recentExpenseCategories, id: \.syncID) { category in
                                QuickExpenseCategoryChip(
                                    title: category.displayName(languageCode: uiLanguageCode),
                                    colorHex: category.colorHex,
                                    isSelected: selectedCategorySyncID == category.syncID
                                ) {
                                    selectedCategorySyncID = category.syncID
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.text("settings.tags", lang: uiLanguageCode), selection: $selectedCategorySyncID) {
                    Text(L10n.text("transaction.select_tag", lang: uiLanguageCode)).tag(String?.none)
                    ForEach(expenseCategories, id: \.syncID) { category in
                        Text(category.displayName(languageCode: uiLanguageCode)).tag(Optional(category.syncID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(L10n.text("a11y.quick_expense_category", lang: uiLanguageCode))

                if let selectedCategory {
                    Text(selectedCategory.displayName(languageCode: uiLanguageCode))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if expenseCategories.isEmpty {
                    Text(L10n.text("quick_expense.no_categories", lang: uiLanguageCode))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("common.date", lang: uiLanguageCode))
                .font(.headline)
                .foregroundStyle(.secondary)

            DatePicker(
                L10n.text("common.date", lang: uiLanguageCode),
                selection: $date,
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(
                isExpanded: $isNoteExpanded,
                content: {
                    TextField(
                        L10n.text("transaction.add_comment", lang: uiLanguageCode),
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .padding(.top, 6)
                    .accessibilityLabel(L10n.text("a11y.quick_expense_note", lang: uiLanguageCode))
                },
                label: {
                    Text(L10n.text("quick_expense.note_optional", lang: uiLanguageCode))
                        .font(.headline)
                }
            )
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(L10n.text("common.cancel", lang: uiLanguageCode)) {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isSaving)
            .accessibilityLabel(L10n.text("a11y.quick_expense_cancel", lang: uiLanguageCode))

            Button {
                saveExpense()
            } label: {
                if isSaving {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(L10n.text("common.save", lang: uiLanguageCode))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSave)
            .accessibilityLabel(L10n.text("a11y.quick_expense_save", lang: uiLanguageCode))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private var inlineSaveErrorMessage: String? {
        showSaveErrorAlert ? saveErrorMessage : nil
    }

    private func applySelectionDefaults() {
        if selectedWallet == nil {
            selectedWalletSyncID = preferredWallet?.syncID
        }

        if selectedCategory == nil {
            selectedCategorySyncID = preferredCategory?.syncID
        }
    }

    private func focusAmountField() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        await MainActor.run {
            isAmountFieldFocused = true
        }
    }

#if canImport(UIKit)
    private var amountFieldFont: UIFont {
        let baseFont = UIFont.systemFont(ofSize: 40, weight: .semibold)
        let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        return UIFont(descriptor: roundedDescriptor, size: 40)
    }
#else
    private var amountFieldFont: Any? { nil }
#endif

    private func saveExpense() {
        guard !isSaving else { return }
        guard let amount = parsedAmount, let wallet = selectedWallet, let category = selectedCategory else { return }
        MoneyRuntimeDebug.recordSaveAttempt(
            path: "QuickExpenseView/RawAmountTextField",
            rawText: amountText,
            parsed: amount
        )

        isSaving = true
        saveErrorMessage = ""
        showSaveErrorAlert = false

        do {
            _ = try TransactionMutationService.save(
                request: TransactionSaveRequest(
                    transaction: nil,
                    originalState: nil,
                    amount: amount,
                    currencyCode: wallet.assetCode,
                    date: date,
                    note: note,
                    transactionType: .expense,
                    category: category,
                    wallet: wallet,
                    transferWallet: nil,
                    transferAmount: nil,
                    photoData: nil,
                    defaultCurrencyCode: defaultCurrencyCode
                ),
                modelContext: modelContext,
                availableWallets: wallets
            )

            lastWalletSyncID = wallet.syncID
            lastCategorySyncID = category.syncID
            dismiss()
        } catch {
            saveErrorMessage = L10n.text("quick_expense.save_failed", lang: uiLanguageCode)
            showSaveErrorAlert = true
        }

        isSaving = false
    }
}

private struct QuickExpenseCategoryChip: View {
    let title: String
    let colorHex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: colorHex))
                    .frame(width: 10, height: 10)

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSelected ? Color.primary.opacity(0.12) : Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
