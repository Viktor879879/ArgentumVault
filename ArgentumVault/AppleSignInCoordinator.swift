import Foundation
import AuthenticationServices

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppleSignInCoordinator: NSObject {
    private static var isAuthorizationInProgress = false
    private static var lastStartTimestamp: TimeInterval = 0
    private static let minimumStartInterval: TimeInterval = 1.2

    private var completion: ((Result<ASAuthorization, Error>) -> Void)?

    func start(completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        let now = Date().timeIntervalSince1970
        guard !Self.isAuthorizationInProgress else { return }
        guard now - Self.lastStartTimestamp >= Self.minimumStartInterval else { return }
        guard self.completion == nil else { return }

        Self.isAuthorizationInProgress = true
        Self.lastStartTimestamp = now
        self.completion = completion

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        DispatchQueue.main.async {
            controller.performRequests()
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let handler = completion
        completion = nil
        Self.isAuthorizationInProgress = false
        handler?(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let handler = completion
        completion = nil
        Self.isAuthorizationInProgress = false
        handler?(.failure(error))
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
#if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        if let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) {
            if let keyWindow = activeScene.windows.first(where: \.isKeyWindow) {
                return keyWindow
            }
            if let window = activeScene.windows.first {
                return window
            }
        }

        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }

        if let window = scenes.flatMap(\.windows).first {
            return window
        }

        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }

        fatalError("No UIWindowScene available for Sign in with Apple presentation anchor.")
#elseif canImport(AppKit)
        return NSApplication.shared.windows.first ?? NSWindow()
#else
        return ASPresentationAnchor()
#endif
    }
}
