import SwiftUI
import Foundation
import Combine

#if canImport(UIKit) && canImport(GoogleMobileAds)
import UIKit
import GoogleMobileAds
#endif

#if canImport(UIKit) && canImport(UserMessagingPlatform)
import UserMessagingPlatform
#endif

enum AdSlot: String, CaseIterable, Codable {
    case homeBottomBanner = "iOS_Home_Bottom_Banner"
}

@MainActor
final class AdsManager: ObservableObject {
    static let shared = AdsManager()

    @Published private(set) var adsEnabledForFree = true
    @Published private(set) var bannerUnitIDsBySlot = AdsDefaults.bannerUnitIDsBySlot
    @Published private(set) var canRequestAds = false

    private let remoteConfigService = AdsRemoteConfigService()
    private var didStartPreparation = false
#if canImport(UIKit) && canImport(GoogleMobileAds)
    private var didStartMobileAds = false
#endif

    var shouldShowLiveBanner: Bool {
#if DEBUG
        adsEnabledForFree
#else
        adsEnabledForFree && canRequestAds
#endif
    }

    func bannerUnitID(for slot: AdSlot) -> String {
        bannerUnitIDsBySlot[slot.rawValue] ?? AdsDefaults.bannerUnitID(for: slot)
    }

    func shouldShowLiveBanner(for slot: AdSlot) -> Bool {
        shouldShowLiveBanner && AdsDefaults.shouldRequestLiveAds(for: bannerUnitID(for: slot))
    }

    func prepareIfNeeded() async {
        guard !didStartPreparation else { return }
        didStartPreparation = true

        apply(remoteConfigService.cachedOrDefaultConfiguration())

        let latestConfig = await remoteConfigService.fetchLatestConfigurationIfNeeded()
        apply(latestConfig)

        await requestConsentIfNeeded()
        startMobileAdsIfNeeded()
    }

    private func apply(_ config: AdsConfiguration) {
        adsEnabledForFree = config.adsEnabledForFree
        bannerUnitIDsBySlot = config.bannerAdUnitIDs
    }

    private func requestConsentIfNeeded() async {
#if canImport(UIKit) && canImport(UserMessagingPlatform)
        let canRequest = await withCheckedContinuation { continuation in
            let parameters = RequestParameters()

            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { _ in
                ConsentForm.loadAndPresentIfRequired(from: UIApplication.activeRootViewController) { _ in
                    continuation.resume(returning: ConsentInformation.shared.canRequestAds)
                }
            }
        }
        canRequestAds = canRequest
#else
        canRequestAds = false
#endif
    }

    private func startMobileAdsIfNeeded() {
#if canImport(UIKit) && canImport(GoogleMobileAds)
        guard !didStartMobileAds else { return }
        guard shouldShowLiveBanner else { return }

        didStartMobileAds = true
        MobileAds.shared.start(completionHandler: nil)
#endif
    }
}

private struct AdsConfiguration: Codable {
    let adsEnabledForFree: Bool
    let bannerAdUnitIDs: [String: String]
}

private final class AdsRemoteConfigService {
    private let userDefaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let cacheKey = "ads.remote.config.v2"
    private let lastFetchDateKey = "ads.remote.config.last_fetch_date.v2"

    func cachedOrDefaultConfiguration() -> AdsConfiguration {
        guard let data = userDefaults.data(forKey: cacheKey),
              let cached = try? decoder.decode(AdsConfiguration.self, from: data)
        else {
            return defaultConfiguration
        }
        return normalized(cached)
    }

    func fetchLatestConfigurationIfNeeded() async -> AdsConfiguration {
        guard let url = AdsDefaults.remoteConfigURL else {
            return cachedOrDefaultConfiguration()
        }

        guard shouldFetchNow() else {
            return cachedOrDefaultConfiguration()
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                return cachedOrDefaultConfiguration()
            }

            let payload = try decoder.decode(AdsRemotePayload.self, from: data)
            let current = cachedOrDefaultConfiguration()
            var mergedSlotIDs = current.bannerAdUnitIDs

            if let payloadSlotIDs = payload.bannerAdUnitIDs, !payloadSlotIDs.isEmpty {
                for (slot, unitID) in payloadSlotIDs {
                    if let trimmed = unitID.trimmedNonEmpty {
                        mergedSlotIDs[slot] = trimmed
                    }
                }
            }

            if let legacyUnitID = payload.bannerAdUnitID?.trimmedNonEmpty {
                mergedSlotIDs[AdSlot.homeBottomBanner.rawValue] = legacyUnitID
            }

            let merged = AdsConfiguration(
                adsEnabledForFree: payload.adsEnabledForFree ?? current.adsEnabledForFree,
                bannerAdUnitIDs: mergedSlotIDs
            )
            let normalizedMerged = normalized(merged)

            if let encoded = try? encoder.encode(normalizedMerged) {
                userDefaults.set(encoded, forKey: cacheKey)
            }
            userDefaults.set(Date().timeIntervalSince1970, forKey: lastFetchDateKey)

            return normalizedMerged
        } catch {
            return cachedOrDefaultConfiguration()
        }
    }

    private var defaultConfiguration: AdsConfiguration {
        AdsConfiguration(
            adsEnabledForFree: true,
            bannerAdUnitIDs: AdsDefaults.bannerUnitIDsBySlot
        )
    }

    private func shouldFetchNow() -> Bool {
        let lastFetchTimestamp = userDefaults.double(forKey: lastFetchDateKey)
        guard lastFetchTimestamp > 0 else { return true }

        let elapsed = Date().timeIntervalSince1970 - lastFetchTimestamp
        return elapsed >= AdsDefaults.remoteConfigFetchInterval
    }

    private func normalized(_ config: AdsConfiguration) -> AdsConfiguration {
        var normalizedSlotIDs = config.bannerAdUnitIDs
        for slot in AdSlot.allCases {
            normalizedSlotIDs[slot.rawValue] = AdsDefaults.normalizedBannerUnitID(
                config.bannerAdUnitIDs[slot.rawValue],
                slot: slot
            )
        }
        return AdsConfiguration(
            adsEnabledForFree: config.adsEnabledForFree,
            bannerAdUnitIDs: normalizedSlotIDs
        )
    }
}

private struct AdsRemotePayload: Decodable {
    let adsEnabledForFree: Bool?
    let bannerAdUnitID: String?
    let bannerAdUnitIDs: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case adsEnabledForFree = "adsEnabledForFree"
        case adsEnabledForFreeSnake = "ads_enabled_for_free"
        case bannerAdUnitID = "bannerAdUnitID"
        case bannerAdUnitIDSnake = "banner_ad_unit_id"
        case bannerAdUnitIDs = "bannerAdUnitIDs"
        case bannerAdUnitIDsSnake = "banner_ad_unit_ids"
        case adUnitIDs = "adUnitIDs"
        case adUnitIDsSnake = "ad_unit_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adsEnabledForFree =
            try container.decodeIfPresent(Bool.self, forKey: .adsEnabledForFree)
            ?? container.decodeIfPresent(Bool.self, forKey: .adsEnabledForFreeSnake)

        bannerAdUnitID =
            try container.decodeIfPresent(String.self, forKey: .bannerAdUnitID)
            ?? container.decodeIfPresent(String.self, forKey: .bannerAdUnitIDSnake)

        bannerAdUnitIDs =
            try container.decodeIfPresent([String: String].self, forKey: .bannerAdUnitIDs)
            ?? container.decodeIfPresent([String: String].self, forKey: .bannerAdUnitIDsSnake)
            ?? container.decodeIfPresent([String: String].self, forKey: .adUnitIDs)
            ?? container.decodeIfPresent([String: String].self, forKey: .adUnitIDsSnake)
    }
}

private enum AdsDefaults {
    private static let googleSampleBannerUnitIDs: Set<String> = [
        "ca-app-pub-3940256099942544/2435281174"
    ]
    private static let slotInfoKeyBySlot: [AdSlot: String] = [
        .homeBottomBanner: "AdsHomeBottomBannerUnitID"
    ]

    static var bannerUnitIDsBySlot: [String: String] {
        var result: [String: String] = [:]
        for slot in AdSlot.allCases {
            result[slot.rawValue] = bannerUnitID(for: slot)
        }
        return result
    }

    static func bannerUnitID(for slot: AdSlot) -> String {
        normalizedBannerUnitID(nil, slot: slot)
    }

    static func normalizedBannerUnitID(_ unitID: String?, slot: AdSlot) -> String {
        let fallback = bundledBannerUnitID(for: slot) ?? ""
        guard let trimmed = unitID?.trimmedNonEmpty else {
            return fallback
        }
        if isGoogleSampleBannerUnitID(trimmed) {
            if let fallbackTrimmed = fallback.trimmedNonEmpty,
               !isGoogleSampleBannerUnitID(fallbackTrimmed) {
                return fallbackTrimmed
            }
            return ""
        }
        return trimmed
    }

    static func shouldRequestLiveAds(for unitID: String) -> Bool {
        guard let trimmed = unitID.trimmedNonEmpty else { return false }
        return !isGoogleSampleBannerUnitID(trimmed)
    }

    private static func bundledBannerUnitID(for slot: AdSlot) -> String? {
        if let slotKey = slotInfoKeyBySlot[slot],
           let slotConfigured = Bundle.main.object(forInfoDictionaryKey: slotKey) as? String,
           let slotTrimmed = slotConfigured.trimmedNonEmpty {
            return isGoogleSampleBannerUnitID(slotTrimmed) ? nil : slotTrimmed
        }

        if let genericConfigured = Bundle.main.object(forInfoDictionaryKey: "GADBannerAdUnitID") as? String,
           let genericTrimmed = genericConfigured.trimmedNonEmpty {
            return isGoogleSampleBannerUnitID(genericTrimmed) ? nil : genericTrimmed
        }

        return nil
    }

    private static func isGoogleSampleBannerUnitID(_ unitID: String) -> Bool {
        googleSampleBannerUnitIDs.contains(unitID)
    }

    static var remoteConfigURL: URL? {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "AdsRemoteConfigURL") as? String,
              let trimmed = configured.trimmedNonEmpty,
              let url = URL(string: trimmed)
        else {
            return nil
        }
        return url
    }

    static var remoteConfigFetchInterval: TimeInterval {
        if let numericValue = Bundle.main.object(forInfoDictionaryKey: "AdsRemoteConfigFetchIntervalSeconds") as? NSNumber {
            return max(300, numericValue.doubleValue)
        }
        return 3600
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct GlobalAdHost: View {
    let lang: String
    var slot: AdSlot = .homeBottomBanner
    let onUpgrade: () -> Void

    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @ObservedObject private var adsManager = AdsManager.shared

    var body: some View {
        let bannerUnitID = adsManager.bannerUnitID(for: slot)
        Group {
            if !subscriptionManager.hasProAccess, adsManager.adsEnabledForFree {
                InlineAdCard(
                    lang: lang,
                    bannerUnitID: bannerUnitID,
                    canShowLiveAd: adsManager.shouldShowLiveBanner(for: slot),
                    onUpgrade: onUpgrade
                )
            }
        }
        .task(id: subscriptionManager.hasProAccess) {
            guard !subscriptionManager.hasProAccess else { return }
            await adsManager.prepareIfNeeded()
        }
    }
}

#if canImport(UIKit)
extension UIApplication {
    static var activeRootViewController: UIViewController? {
        let windowScenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = windowScenes.first(where: { $0.activationState == .foregroundActive })
        let candidateWindows = activeScene?.windows ?? windowScenes.flatMap(\.windows)
        return candidateWindows.first(where: \.isKeyWindow)?.rootViewController ?? candidateWindows.first?.rootViewController
    }
}
#endif
