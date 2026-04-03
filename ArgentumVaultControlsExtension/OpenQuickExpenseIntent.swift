import AppIntents

@available(iOS 18.0, *)
struct OpenQuickExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "control.new_expense.intent_title"
    static let description = IntentDescription("Opens Argentum Vault directly on the quick expense screen.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(URL(string: "argentumvault://expense/new")!))
    }
}
