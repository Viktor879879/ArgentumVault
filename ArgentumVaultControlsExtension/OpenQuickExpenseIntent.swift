import AppIntents

@available(iOS 18.0, *)
struct OpenQuickExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "AV New Expense Test"
    static let description = IntentDescription("Opens Argentum Vault.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        .result()
    }
}
