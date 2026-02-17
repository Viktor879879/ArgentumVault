import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

private struct DismissKeyboardOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
#if canImport(UIKit)
        content
            .onAppear {
                GlobalKeyboardDismissTapInstaller.shared.installIfNeeded()
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    GlobalKeyboardDismissTapInstaller.shared.dismissKeyboard()
                },
                including: .all
            )
#else
        content
#endif
    }
}

#if canImport(UIKit)
@MainActor
private final class GlobalKeyboardDismissTapInstaller: NSObject, UIGestureRecognizerDelegate {
    static let shared = GlobalKeyboardDismissTapInstaller()

    private let recognizerName = "ArgentumVault.GlobalKeyboardDismissTap"

    func installIfNeeded() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)

        for window in windows {
            if window.gestureRecognizers?.contains(where: { $0.name == recognizerName }) == true {
                continue
            }

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleWindowTap(_:)))
            tap.name = recognizerName
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }
    }

    func dismissKeyboard() {
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

    @objc private func handleWindowTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        dismissKeyboard()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
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
