import Combine
import Foundation

enum QuickExpenseRoute {
    static let scheme = "argentumvault"
    static let host = "expense"
    static let path = "/new"
    static let url = URL(string: "argentumvault://expense/new")!

    static func matches(_ url: URL) -> Bool {
        let normalizedScheme = url.scheme?.lowercased()
        let normalizedHost = url.host()?.lowercased()
        let normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()

        return normalizedScheme == scheme
            && normalizedHost == host
            && normalizedPath == "new"
    }
}

@MainActor
final class QuickExpenseRouter: ObservableObject {
    @Published private(set) var pendingRequestID: UUID?

    func handle(url: URL) {
        guard QuickExpenseRoute.matches(url) else { return }
        pendingRequestID = UUID()
    }

    func consumePendingRequest() {
        pendingRequestID = nil
    }
}
