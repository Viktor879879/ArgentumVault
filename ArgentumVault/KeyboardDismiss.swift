import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
private final class KeyboardDismissGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    private weak var attachedWindow: UIWindow?

    private lazy var tapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        gesture.name = "ArgentumVaultKeyboardDismissGesture"
        return gesture
    }()

    func attachIfNeeded(to window: UIWindow?) {
        guard let window else { return }
        if attachedWindow === window { return }

        detach()

        if window.gestureRecognizers?.contains(where: { $0.name == tapGesture.name }) == true {
            attachedWindow = window
            return
        }

        window.addGestureRecognizer(tapGesture)
        attachedWindow = window
    }

    func detach() {
        guard let attachedWindow else { return }
        attachedWindow.removeGestureRecognizer(tapGesture)
        self.attachedWindow = nil
    }

    @objc
    private func handleTap() {
        dismissKeyboardNow()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touchedView = touch.view else { return true }
        return !touchedView.isInsideTextInput
    }
}

private struct KeyboardDismissGestureInstaller: UIViewRepresentable {
    func makeCoordinator() -> KeyboardDismissGestureCoordinator {
        KeyboardDismissGestureCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(to: uiView.window)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: KeyboardDismissGestureCoordinator) {
        coordinator.detach()
    }
}

private extension UIView {
    var isInsideTextInput: Bool {
        var currentView: UIView? = self
        while let view = currentView {
            if view is UITextField || view is UITextView || view is UISearchBar {
                return true
            }
            currentView = view.superview
        }
        return false
    }
}
#endif

private struct DismissKeyboardOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
#if canImport(UIKit)
        content
            .background(
                KeyboardDismissGestureInstaller()
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
