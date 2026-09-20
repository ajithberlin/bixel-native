// AdManager.swift
//
// Sponsor message coordinator for Bixel Studio.
// The app loads clearly labelled house ads from a published feed; no ad SDK or
// behavioural targeting is bundled with the app.

import Foundation
import SwiftUI
import Combine
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct AdItem: Identifiable, Equatable {
    let id: String
    let advertiser: String
    let headline: String
    let description: String
    let callToAction: String
    let iconSystemName: String
    let iconURL: URL?
    let imageURL: URL?
    let accentColor: Color
    let destinationURL: URL
    let badgeText: String

    init(
        id: String,
        advertiser: String,
        headline: String,
        description: String,
        callToAction: String,
        iconSystemName: String,
        iconURL: URL? = nil,
        imageURL: URL? = nil,
        accentColor: Color,
        destinationURL: URL,
        badgeText: String
    ) {
        self.id = id
        self.advertiser = advertiser
        self.headline = headline
        self.description = description
        self.callToAction = callToAction
        self.iconSystemName = iconSystemName
        self.iconURL = iconURL
        self.imageURL = imageURL
        self.accentColor = accentColor
        self.destinationURL = destinationURL
        self.badgeText = badgeText
    }
}

extension AdItem {
    init?(remote creative: RemoteAdCreative) {
        guard creative.isValid,
              let id = creative.adID,
              let product = creative.product,
              let advertiser = creative.advertiser,
              let headline = creative.headline,
              let body = creative.body,
              let callToAction = creative.callToAction,
              let destinationURL = creative.destinationURL else {
            return nil
        }

        self.init(
            id: id,
            advertiser: advertiser,
            headline: headline,
            description: body,
            callToAction: callToAction,
            iconSystemName: Self.fallbackIcon(for: creative.category),
            iconURL: creative.iconURL,
            imageURL: creative.imageURL,
            accentColor: Self.accentColor(for: product),
            destinationURL: destinationURL,
            badgeText: "Sponsored"
        )
    }

    private static func fallbackIcon(for category: String?) -> String {
        switch category?.lowercased() {
        case let category where category?.contains("education") == true:
            return "book.fill"
        case let category where category?.contains("restaurant") == true:
            return "fork.knife"
        case let category where category?.contains("cloud") == true:
            return "cloud.fill"
        default:
            return "sparkles"
        }
    }

    private static func accentColor(for product: String) -> Color {
        switch product.lowercased() {
        case "langcity":
            return Color(red: 0.98, green: 0.47, blue: 0.28)
        case "dinertech":
            return Color(red: 0.18, green: 0.72, blue: 0.62)
        case "alphberlin":
            return Color(red: 0.34, green: 0.55, blue: 0.98)
        default:
            return Color(red: 0.70, green: 0.52, blue: 0.98)
        }
    }
}

@MainActor
final class AdManager: ObservableObject {
    static let shared = AdManager()

    static let remoteFeedURL = RemoteAdFeedLoader.defaultEndpoint

    // MARK: - State

    /// Reference to subscription manager for entitlement checks.
    private let subscriptionManager = SubscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var rotationTimer: AnyCancellable?
    private var remoteRefreshTimer: AnyCancellable?
    private var remoteLoadTask: Task<Void, Never>?

    /// Current inventory from the last successful `ad.json` response.
    @Published private(set) var ads: [AdItem] = []

    /// Whether a validated remote ad is ready to render for a free user.
    @Published private(set) var shouldShowAds: Bool = false

    /// Currently active commercial advertisement.
    @Published private(set) var currentAdIndex: Int = 0

    /// Tracks total ad impressions or click events for analytics.
    @Published private(set) var impressionCount: Int = 0

    var currentAd: AdItem? {
        guard !ads.isEmpty else { return nil }
        return ads[currentAdIndex % ads.count]
    }

    private init() {
        // Observe entitlement changes: when isAdFree becomes true, shouldShowAds is false.
        subscriptionManager.$isAdFree
            .sink { [weak self] isAdFree in
                guard let self = self else { return }
                if isAdFree {
                    self.shouldShowAds = false
                    self.ads = []
                    self.stopRotation()
                    self.stopRemoteFeedRefresh()
                    self.remoteLoadTask?.cancel()
                } else {
                    self.scheduleRemoteFeedRefresh()
                    self.loadRemoteAds()
                }
            }
            .store(in: &cancellables)
    }

    /// Converts validated feed creatives into the existing ad inventory model.
    static func makeAdItems(from creatives: [RemoteAdCreative]) -> [AdItem] {
        creatives.compactMap { AdItem(remote: $0) }
    }

    private func scheduleRemoteFeedRefresh() {
        remoteRefreshTimer?.cancel()
        remoteRefreshTimer = Timer.publish(every: 6 * 60 * 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.loadRemoteAds()
            }
    }

    private func stopRemoteFeedRefresh() {
        remoteRefreshTimer?.cancel()
        remoteRefreshTimer = nil
    }

    private func loadRemoteAds() {
        guard !subscriptionManager.isAdFree else {
            self.shouldShowAds = false
            self.ads = []
            return
        }

        remoteLoadTask?.cancel()
        remoteLoadTask = Task { [weak self] in
            guard let self else { return }
            guard !self.subscriptionManager.isAdFree else { return }

            do {
                let creatives = try await RemoteAdFeedLoader(endpoint: Self.remoteFeedURL).load()
                let remoteAds = Self.makeAdItems(from: creatives)
                guard !remoteAds.isEmpty, !Task.isCancelled, !self.subscriptionManager.isAdFree else {
                    if self.subscriptionManager.isAdFree {
                        self.ads = []
                        self.shouldShowAds = false
                    }
                    return
                }

                self.ads = remoteAds
                self.currentAdIndex = 0
                self.shouldShowAds = true
                self.startRotation()
            } catch is CancellationError {
                // A purchase or a newer refresh cancelled this request.
            } catch {
                // Keep a previously loaded remote inventory if one exists and user is not ad-free.
                if self.subscriptionManager.isAdFree || self.ads.isEmpty {
                    self.shouldShowAds = false
                    self.stopRotation()
                }
                print("[AdManager] Remote ad feed unavailable: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Ad Rotation

    func startRotation() {
        rotationTimer?.cancel()
        rotationTimer = Timer.publish(every: 14.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.nextAd()
            }
    }

    func stopRotation() {
        rotationTimer?.cancel()
        rotationTimer = nil
    }

    func nextAd() {
        guard !ads.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentAdIndex = (currentAdIndex + 1) % ads.count
        }
        recordImpression()
    }

    func previousAd() {
        guard !ads.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentAdIndex = (currentAdIndex - 1 + ads.count) % ads.count
        }
        recordImpression()
    }

    func selectAd(at index: Int) {
        guard index >= 0 && index < ads.count else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentAdIndex = index
        }
        recordImpression()
    }

    // MARK: - Interactions & Tracking

    /// Record an impression for analytics / tracking.
    func recordImpression() {
        impressionCount += 1
    }

    /// Open destination URL when user clicks the ad.
    func clickCurrentAd() {
        guard let url = currentAd?.destinationURL else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }

    /// Open the public support page so users can report an inappropriate or
    /// misleading sponsor message without leaving the app's normal browser flow.
    func reportCurrentAd() {
        let url = URL(string: "https://ajithberlin.github.io/bixel-native/support.html#ad-report")!
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }
}
