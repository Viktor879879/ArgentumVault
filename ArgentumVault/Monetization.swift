import SwiftUI
import StoreKit
import Combine
#if canImport(UIKit) && canImport(GoogleMobileAds)
import UIKit
import GoogleMobileAds
#endif

enum PremiumFeature: CaseIterable, Hashable {
    case iCloudSyncBackup
    case advancedAnalytics
    case aiInsights
    case adFree

    func title(lang: String) -> String {
        switch self {
        case .iCloudSyncBackup:
            return L10n.text("pro.feature.icloud_sync_backup", lang: lang)
        case .advancedAnalytics:
            return L10n.text("pro.feature.advanced_analytics", lang: lang)
        case .aiInsights:
            return L10n.text("pro.feature.ai_insights", lang: lang)
        case .adFree:
            return L10n.text("pro.feature.no_ads", lang: lang)
        }
    }
}

@MainActor
final class SubscriptionManager: ObservableObject {
    static let productIDs: [String] = [
        "com.argentumvault.pro.monthly1",
        "com.argentumvault.pro.yearly"
    ]
    private static let cachedProAccessKey = "pro.cached.hasAccess"
    private static let lastAutomaticRestoreAttemptAtKey = "pro.auto_restore.last_attempt_at"
    private static let automaticRestoreRetryInterval: TimeInterval = 6 * 60 * 60
    private static let lastAuthRestoreAttemptAtKey = "pro.auto_restore.last_auth_attempt_at"
    private static let authRestoreDebounceInterval: TimeInterval = 10
    static var cachedProAccessDefaultsKey: String { cachedProAccessKey }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isProUnlocked = false
    @Published private(set) var hasLoadedState = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchaseInProgress = false
#if DEBUG
    static let debugProOverrideKey = "debug.pro.override.enabled"
    @Published var debugProOverride = UserDefaults.standard.bool(forKey: debugProOverrideKey) {
        didSet {
            UserDefaults.standard.set(debugProOverride, forKey: Self.debugProOverrideKey)
        }
    }
#endif

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = observeTransactionUpdates()
    }

    deinit {
        updatesTask?.cancel()
    }

    func start() async {
        await loadProductsIfNeeded()
        await refreshEntitlements()
    }

    func loadProductsIfNeeded() async {
        guard products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = fetched.sorted(by: { lhs, rhs in
                lhs.price < rhs.price
            })
        } catch {
            products = []
        }
    }

    func refreshEntitlements() async {
        let hasActivePro = await Self.hasActiveProEntitlement()

        isProUnlocked = hasActivePro
        Self.persistCachedProAccess(hasActivePro)
        hasLoadedState = true
    }

    func restoreAfterAuthorization() async {
        await loadProductsIfNeeded()
        await refreshEntitlements()

        guard !hasProAccess else { return }
        guard Self.shouldAttemptAuthorizationRestore() else { return }

        Self.recordAuthorizationRestoreAttempt()
        do {
            try await AppStore.sync()
        } catch {
            // Non-blocking: keep current state and retry on next auth/launch refresh.
        }
        await refreshEntitlements()
    }

    static func resolveProAccessForLaunch() async -> Bool {
#if DEBUG
        if UserDefaults.standard.bool(forKey: debugProOverrideKey) {
            persistCachedProAccess(true)
            return true
        }
#endif
        var hasActivePro = await hasActiveProEntitlement()
        if !hasActivePro, shouldAttemptAutomaticRestore() {
            recordAutomaticRestoreAttempt()
            do {
                try await AppStore.sync()
            } catch {
                // Keep non-blocking launch behavior; we'll retry later based on interval.
            }
            hasActivePro = await hasActiveProEntitlement()
        }
        persistCachedProAccess(hasActivePro)
        return hasActivePro
    }

    static func shouldUseCloudKitStorage() -> Bool {
        let defaults = UserDefaults.standard
        let hasCachedProAccess = defaults.bool(forKey: cachedProAccessKey)
#if DEBUG
        return hasCachedProAccess || defaults.bool(forKey: debugProOverrideKey)
#else
        return hasCachedProAccess
#endif
    }

    var hasProAccess: Bool {
#if DEBUG
        isProUnlocked || debugProOverride
#else
        isProUnlocked
#endif
    }

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseState {
        isPurchaseInProgress = true
        defer { isPurchaseInProgress = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
                return hasProAccess ? .success : .failed
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    @discardableResult
    func restore() async -> PurchaseState {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            return hasProAccess ? .success : .failed
        } catch {
            return .failed
        }
    }

    func isUnlocked(_ feature: PremiumFeature) -> Bool {
        switch feature {
        case .iCloudSyncBackup, .advancedAnalytics, .aiInsights, .adFree:
            return hasProAccess
        }
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.unverifiedTransaction
        case .verified(let safe):
            return safe
        }
    }

    private static func hasActiveProEntitlement() async -> Bool {
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productType == .autoRenewable else { continue }
            guard Self.productIDs.contains(transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }

            if let expiration = transaction.expirationDate {
                if expiration > Date() {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    private static func persistCachedProAccess(_ hasProAccess: Bool) {
        UserDefaults.standard.set(hasProAccess, forKey: cachedProAccessKey)
    }

    private static func shouldAttemptAutomaticRestore(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.double(forKey: lastAutomaticRestoreAttemptAtKey)
        guard lastAttempt > 0 else { return true }
        return now.timeIntervalSince1970 - lastAttempt >= automaticRestoreRetryInterval
    }

    private static func recordAutomaticRestoreAttempt(now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastAutomaticRestoreAttemptAtKey)
    }

    private static func shouldAttemptAuthorizationRestore(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.double(forKey: lastAuthRestoreAttemptAtKey)
        guard lastAttempt > 0 else { return true }
        return now.timeIntervalSince1970 - lastAttempt >= authRestoreDebounceInterval
    }

    private static func recordAuthorizationRestoreAttempt(now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastAuthRestoreAttemptAtKey)
    }
}

enum PurchaseState {
    case success
    case pending
    case cancelled
    case failed
}

enum StoreError: Error {
    case unverifiedTransaction
}

struct LaunchAdOverlay: View {
    let lang: String
    let onClose: () -> Void
    let onUpgrade: () -> Void

    @State private var countdown = 3

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text(L10n.text("ad.sponsored", lang: lang))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Text(L10n.text("ad.launch.title", lang: lang))
                    .font(.title3.weight(.bold))

                Text(L10n.text("ad.launch.body", lang: lang))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(L10n.text("pro.cta.unlock", lang: lang)) {
                    onUpgrade()
                }
                .buttonStyle(.borderedProminent)

                Button(countdown == 0
                    ? L10n.text("common.close", lang: lang)
                    : "\(L10n.text("common.close", lang: lang)) (\(countdown))"
                ) {
                    guard countdown == 0 else { return }
                    onClose()
                }
                .buttonStyle(.bordered)
                .disabled(countdown > 0)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.background)
            )
            .padding(.horizontal, 16)
        }
        .onReceive(timer) { _ in
            guard countdown > 0 else { return }
            countdown -= 1
        }
    }
}

struct InlineAdCard: View {
    let lang: String
    let bannerUnitID: String
    let canShowLiveAd: Bool
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.text("ad.sponsored", lang: lang))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(L10n.text("pro.cta.no_ads", lang: lang)) {
                    onUpgrade()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }

#if canImport(UIKit) && canImport(GoogleMobileAds)
            if canShowLiveAd {
                AdMobBannerContainer(adUnitID: bannerUnitID, lang: lang)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            } else {
                Text(L10n.text("ad.inline.pending", lang: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 20)
            }
#else
            Text(L10n.text("ad.inline.body", lang: lang))
                .font(.caption)
#endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
    }
}

#if canImport(UIKit) && canImport(GoogleMobileAds)
private struct AdMobBannerContainer: View {
    let adUnitID: String
    let lang: String
    @StateObject private var loadObserver = BannerLoadObserver()
    @State private var effectiveAdUnitID = ""

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let width = max(320, proxy.size.width)
                AdMobBannerView(
                    adUnitID: effectiveAdUnitID.isEmpty ? adUnitID : effectiveAdUnitID,
                    width: width,
                    loadObserver: loadObserver
                )
                .frame(width: proxy.size.width, height: 54, alignment: .center)
            }
            .frame(height: 54)

            if !loadObserver.didLoad {
                Text(L10n.text("ad.inline.pending", lang: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 54)
        .onAppear {
            if effectiveAdUnitID != adUnitID {
                effectiveAdUnitID = adUnitID
                loadObserver.reset()
            }
        }
        .onChange(of: adUnitID) {
            effectiveAdUnitID = adUnitID
            loadObserver.reset()
        }
        .onChange(of: loadObserver.didFail) { _, failed in
#if DEBUG
            guard failed else { return }
            guard !AdsDefaults.isGoogleSampleBannerUnitID(effectiveAdUnitID) else { return }
            effectiveAdUnitID = AdsDefaults.debugFallbackTestBannerUnitID
            loadObserver.reset()
#endif
        }
    }
}

private struct AdMobBannerView: UIViewRepresentable {
    let adUnitID: String
    let width: CGFloat
    @ObservedObject var loadObserver: BannerLoadObserver

    func makeUIView(context: Context) -> BannerView {
        let bannerView = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        bannerView.adUnitID = adUnitID
        bannerView.rootViewController = UIApplication.activeRootViewController
        bannerView.delegate = context.coordinator
        bannerView.load(Request())
        return bannerView
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        uiView.rootViewController = UIApplication.activeRootViewController
        if uiView.adUnitID != adUnitID {
            loadObserver.reset()
            uiView.adUnitID = adUnitID
            uiView.load(Request())
        }
        let size = currentOrientationAnchoredAdaptiveBanner(width: width)
        if !isAdSizeEqualToSize(size1: uiView.adSize, size2: size) {
            uiView.adSize = size
            loadObserver.reset()
            uiView.load(Request())
        }
    }

    func makeCoordinator() -> BannerLoadObserver {
        loadObserver
    }
}

@MainActor
private final class BannerLoadObserver: NSObject, ObservableObject, BannerViewDelegate {
    @Published var didLoad = false
    @Published var didFail = false

    func reset() {
        didLoad = false
        didFail = false
    }

    nonisolated func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        Task { @MainActor in
            didLoad = true
            didFail = false
        }
    }

    nonisolated func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: any Error) {
        Task { @MainActor in
            didLoad = false
            didFail = true
        }
    }
}
#endif

struct ProLockedCard: View {
    let lang: String
    let title: String
    let description: String
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "lock.fill")
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(L10n.text("pro.cta.unlock", lang: lang)) {
                onUnlock()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    let lang: String

    @State private var showMessage = false
    @State private var messageText = ""

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("pro.includes", lang: lang)) {
                    ForEach(PremiumFeature.allCases, id: \.self) { feature in
                        Label(feature.title(lang: lang), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.88))
                    }
                }

                Section(L10n.text("pro.plans", lang: lang)) {
                    if subscriptionManager.products.isEmpty {
                        Text(L10n.text("pro.products_unavailable", lang: lang))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(subscriptionManager.products, id: \.id) { product in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(product.displayName)
                                        .font(.headline)
                                    Spacer()
                                    Text(product.displayPrice)
                                        .font(.headline)
                                }
                                Button(L10n.text("pro.cta.subscribe", lang: lang)) {
                                    Task {
                                        let state = await subscriptionManager.purchase(product)
                                        handle(state)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(subscriptionManager.isPurchaseInProgress)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("pro.title_short", lang: lang))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.close", lang: lang)) {
                        dismiss()
                    }
                }
            }
            .task {
                await subscriptionManager.start()
            }
            .alert(L10n.text("pro.status", lang: lang), isPresented: $showMessage) {
                Button(L10n.text("common.ok", lang: lang), role: .cancel) {}
            } message: {
                Text(messageText)
            }
        }
    }

    private func handle(_ state: PurchaseState) {
        switch state {
        case .success:
            messageText = L10n.text("pro.state.success", lang: lang)
        case .pending:
            messageText = L10n.text("pro.state.pending", lang: lang)
        case .cancelled:
            return
        case .failed:
            messageText = L10n.text("pro.state.failed", lang: lang)
        }
        showMessage = true
    }
}
