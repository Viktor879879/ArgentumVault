import Foundation
import AuthenticationServices
import CryptoKit
import Security

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

struct AppleSignInAuthorization {
    let authorization: ASAuthorization
    let rawNonce: String
}

private enum AppleSignInCoordinatorError: LocalizedError {
    case missingNonce

    var errorDescription: String? {
        switch self {
        case .missingNonce:
            return "Apple sign in did not return a valid nonce."
        }
    }
}

@MainActor
final class AppleSignInCoordinator: NSObject {
    private static var isAuthorizationInProgress = false
    private static var lastStartTimestamp: TimeInterval = 0
    private static let minimumStartInterval: TimeInterval = 1.2

    private var completion: ((Result<AppleSignInAuthorization, Error>) -> Void)?
    private var activeController: ASAuthorizationController?
    private var currentNonce: String?

    func start(completion: @escaping (Result<AppleSignInAuthorization, Error>) -> Void) {
        let now = Date().timeIntervalSince1970
        guard !Self.isAuthorizationInProgress else { return }
        guard now - Self.lastStartTimestamp >= Self.minimumStartInterval else { return }
        guard self.completion == nil else { return }

        Self.isAuthorizationInProgress = true
        Self.lastStartTimestamp = now
        self.completion = completion

        let request = ASAuthorizationAppleIDProvider().createRequest()
        let rawNonce = Self.randomNonceString()
        currentNonce = rawNonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(rawNonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        activeController = controller
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
        let rawNonce = currentNonce
        completion = nil
        activeController = nil
        currentNonce = nil
        Self.isAuthorizationInProgress = false
        guard let rawNonce, !rawNonce.isEmpty else {
            handler?(.failure(AppleSignInCoordinatorError.missingNonce))
            return
        }
        handler?(.success(AppleSignInAuthorization(authorization: authorization, rawNonce: rawNonce)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let handler = completion
        completion = nil
        activeController = nil
        currentNonce = nil
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

extension AppleSignInCoordinator {
    static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)

        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)

        while result.count < length {
            var randomByte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &randomByte)
            guard status == errSecSuccess else {
                continue
            }

            if randomByte < charset.count {
                result.append(charset[Int(randomByte)])
            }
        }

        return result
    }
}
