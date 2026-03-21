import Foundation

extension Notification.Name {
    static let accountSessionDidChange = Notification.Name("ArgentumVault.accountSessionDidChange")
    static let modelStoreDidRestore = Notification.Name("ArgentumVault.modelStoreDidRestore")
    static let modelStoreRestoreWillBegin = Notification.Name("ArgentumVault.modelStoreRestoreWillBegin")
}

enum SessionEvents {
    static func postAccountSessionDidChange() {
        NotificationCenter.default.post(name: .accountSessionDidChange, object: nil)
    }

    static func postModelStoreRestoreWillBegin() {
        NotificationCenter.default.post(name: .modelStoreRestoreWillBegin, object: nil)
    }

    static func postModelStoreDidRestore(restored: Bool = true) {
        NotificationCenter.default.post(
            name: .modelStoreDidRestore,
            object: nil,
            userInfo: ["restored": restored]
        )
    }
}
