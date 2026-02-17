//
//  ArgentumVaultApp.swift
//  ArgentumVault
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import SwiftUI
import SwiftData

@main
struct ArgentumVaultApp: App {
    var body: some Scene {
        WindowGroup {
            AppBootstrapView()
        }
    }
}

private struct AppBootstrapView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SubscriptionManager.cachedProAccessDefaultsKey) private var cachedProAccess = false
#if DEBUG
    @AppStorage(SubscriptionManager.debugProOverrideKey) private var debugProOverride = false
#endif
    @State private var modelContainer: ModelContainer?
    @State private var isCloudStoreEnabled = false

    var body: some View {
        Group {
            if let modelContainer {
                ContentView()
                    .modelContainer(modelContainer)
            } else {
                LoadingBootstrapView()
            }
        }
        .task {
            await bootstrapIfNeeded()
        }
        .onChange(of: cachedProAccess) {
            Task {
                await switchContainerIfNeeded(refreshEntitlements: false)
            }
        }
#if DEBUG
        .onChange(of: debugProOverride) {
            Task {
                await switchContainerIfNeeded(refreshEntitlements: false)
            }
        }
#endif
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            Task {
                await switchContainerIfNeeded(refreshEntitlements: true)
            }
        }
    }

    @MainActor
    private func bootstrapIfNeeded() async {
        guard modelContainer == nil else { return }
        await switchContainerIfNeeded(refreshEntitlements: true)
    }

    @MainActor
    private func switchContainerIfNeeded(refreshEntitlements: Bool) async {
        let shouldUseCloudKit: Bool = {
            if refreshEntitlements {
                return false
            }
            return SubscriptionManager.shouldUseCloudKitStorage()
        }()

        let resolvedShouldUseCloudKit: Bool
        if refreshEntitlements {
            resolvedShouldUseCloudKit = await SubscriptionManager.resolveProAccessForLaunch()
        } else {
            resolvedShouldUseCloudKit = shouldUseCloudKit
        }

        if modelContainer != nil, resolvedShouldUseCloudKit == isCloudStoreEnabled {
            return
        }

        let selection = AppModelContainerFactory.makeContainerSelection(shouldUseCloudKit: resolvedShouldUseCloudKit)
        modelContainer = selection.container
        isCloudStoreEnabled = selection.usesCloudKit
        AppStorageDiagnostics.persist(requestedCloud: resolvedShouldUseCloudKit, selection: selection)
    }
}

private struct LoadingBootstrapView: View {
    var body: some View {
        ZStack {
            Color(hex: "ECECECFF")
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                ProgressView()
                    .tint(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct AppModelContainerSelection {
    let container: ModelContainer
    let usesCloudKit: Bool
    let cloudKitErrorDescription: String?
    let cloudKitFailureReasonCode: String?
}

private enum AppModelContainerFactory {
    static func makeContainerSelection(shouldUseCloudKit: Bool) -> AppModelContainerSelection {
        let schema = Schema([
            Category.self,
            Transaction.self,
            Asset.self,
            Wallet.self,
            WalletFolder.self,
            RecurringTransactionRule.self,
            CategoryBudget.self,
        ])
        let preferredConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: shouldUseCloudKit ? .automatic : .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [preferredConfiguration])
            return AppModelContainerSelection(
                container: container,
                usesCloudKit: shouldUseCloudKit,
                cloudKitErrorDescription: nil,
                cloudKitFailureReasonCode: nil
            )
        } catch let preferredError {
            guard shouldUseCloudKit else {
                fatalError("Could not create local ModelContainer: \(preferredError)")
            }

            // Keep app usable when CloudKit schema/capabilities are not ready yet.
            let localFallbackConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )

            do {
                let localContainer = try ModelContainer(for: schema, configurations: [localFallbackConfiguration])
                let details = CloudKitErrorDiagnostics.technicalDetails(from: preferredError)
                let reasonCode = CloudKitErrorDiagnostics.reasonCode(from: preferredError)
                return AppModelContainerSelection(
                    container: localContainer,
                    usesCloudKit: false,
                    cloudKitErrorDescription: details,
                    cloudKitFailureReasonCode: reasonCode
                )
            } catch let localError {
                fatalError(
                    "Could not create ModelContainer. CloudKit error: \(preferredError). Local fallback error: \(localError)"
                )
            }
        }
    }
}

private enum CloudKitErrorDiagnostics {
    static func reasonCode(from error: Error) -> String {
        let summary = flatten(error: error).joined(separator: " ").lowercased()

        if summary.contains("ckerrornotauthenticated")
            || summary.contains("not authenticated")
            || summary.contains("no icloud")
            || summary.contains("no account")
            || summary.contains("account unavailable")
            || summary.contains("accountstatus = 3") {
            return "no_icloud_account"
        }
        if summary.contains("permission")
            || summary.contains("restricted")
            || summary.contains("forbidden")
            || summary.contains("not entitled") {
            return "restricted"
        }
        if summary.contains("network")
            || summary.contains("timed out")
            || summary.contains("service unavailable")
            || summary.contains("temporarily unavailable")
            || summary.contains("unreachable") {
            return "network"
        }
        if summary.contains("loadissuemodelcontainer")
            || summary.contains("model")
            || summary.contains("schema")
            || summary.contains("relationship")
            || summary.contains("migration") {
            return "model_issue"
        }
        return "generic"
    }

    static func technicalDetails(from error: Error) -> String {
        let lines = flatten(error: error)
        return lines.isEmpty ? String(describing: error) : lines.joined(separator: " | ")
    }

    private static func flatten(error: Error) -> [String] {
        var lines: [String] = []
        collect(error: error as NSError, depth: 0, lines: &lines)
        return lines
    }

    private static func collect(error: NSError, depth: Int, lines: inout [String]) {
        guard depth < 5 else { return }

        let base = "[\(error.domain):\(error.code)] \(error.localizedDescription)"
        if !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !lines.contains(base) {
            lines.append(base)
        }

        if let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !lines.contains(reason) {
            lines.append(reason)
        }

        if let detailed = error.userInfo["NSDetailedErrors"] as? [NSError] {
            for nested in detailed.prefix(3) {
                collect(error: nested, depth: depth + 1, lines: &lines)
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            collect(error: underlying, depth: depth + 1, lines: &lines)
        }
    }
}

private enum AppStorageDiagnostics {
    private static let activeModeKey = "storage.mode.active"
    private static let requestedCloudKey = "storage.mode.requested_cloud"
    private static let cloudKitErrorKey = "storage.cloudkit.last_error"
    private static let cloudKitReasonKey = "storage.cloudkit.last_reason_code"

    static func persist(requestedCloud: Bool, selection: AppModelContainerSelection) {
        let defaults = UserDefaults.standard
        defaults.set(selection.usesCloudKit ? "cloud" : "local", forKey: activeModeKey)
        defaults.set(requestedCloud, forKey: requestedCloudKey)
        if let error = selection.cloudKitErrorDescription, !error.isEmpty {
            defaults.set(error, forKey: cloudKitErrorKey)
        } else {
            defaults.removeObject(forKey: cloudKitErrorKey)
        }
        if let reasonCode = selection.cloudKitFailureReasonCode, !reasonCode.isEmpty {
            defaults.set(reasonCode, forKey: cloudKitReasonKey)
        } else {
            defaults.removeObject(forKey: cloudKitReasonKey)
        }
    }
}
