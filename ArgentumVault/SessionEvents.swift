import Foundation

extension Notification.Name {
    static let accountSessionDidChange = Notification.Name("ArgentumVault.accountSessionDidChange")
}

enum SessionEvents {
    static func postAccountSessionDidChange() {
        NotificationCenter.default.post(name: .accountSessionDidChange, object: nil)
    }
}
