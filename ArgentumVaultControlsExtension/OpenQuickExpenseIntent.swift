import AppIntents

@available(iOS 18.0, *)
struct OpenQuickExpenseIntent: AppIntent {
    private static let quickExpenseURL = URL(string: "argentumvault://expense/new")!

    static let title: LocalizedStringResource = "control.new_expense.intent_title"
    static let description = IntentDescription("control.new_expense.description")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.quickExpenseURL))
    }
}
