import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

private struct DismissKeyboardOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
#if canImport(UIKit)
        content
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboardNow()
                    }
            )
#else
        content
#endif
    }
}

#if canImport(UIKit)
@MainActor
private func dismissKeyboardNow() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )

    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .forEach { $0.endEditing(true) }
}
#endif

extension View {
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
