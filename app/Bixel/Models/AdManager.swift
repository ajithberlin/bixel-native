// AdManager.swift
//
// Sponsor message coordinator for Bixel Studio.
// The app loads clearly labelled house ads from a published feed and retains a
// local fallback; no ad SDK or behavioural targeting is bundled with the app.

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

    // MARK: - Rotating Commercial Ad Inventory

    static let sampleAds: [AdItem] = [
        AdItem(
            id: "ad_google_cloud",
            advertiser: "Google Cloud",
            headline: "Build & Host Multiplayer 2D Game Servers",
            description: "Deploy low-latency dedicated game servers globally. Claim $300 free trial credits today.",
            callToAction: "Claim $300 Credits",
            iconSystemName: "cloud.fill",
            accentColor: Color(red: 0.26, green: 0.52, blue: 0.96),
            destinationURL: URL(string: "https://cloud.google.com/solutions/gaming")!,
            badgeText: "Sponsored"
        ),
        AdItem(
            id: "ad_unity_store",
            advertiser: "Unity Asset Store",
            headline: "Top 2D Pixel Art Spritesheets, Chiptunes & Tilemaps",
            description: "Over 40,000+ indie game assets ready for your next retro platformer or RPG.",
            callToAction: "Browse Assets",
            iconSystemName: "gamecontroller.fill",
            accentColor: Color(red: 0.12, green: 0.74, blue: 0.55),
            destinationURL: URL(string: "https://assetstore.unity.com/categories/2d")!,
            badgeText: "Sponsored"
        ),
        AdItem(
            id: "ad_itch_io",
            advertiser: "itch.io",
            headline: "Indie Game Creator Marketplace",
            description: "Publish and sell your pixel sprites, tilesets, and game sound effects with 0% platform cuts.",
            callToAction: "Join Creators",
            iconSystemName: "arrow.up.forward.app.fill",
            accentColor: Color(red: 0.98, green: 0.35, blue: 0.35),
            destinationURL: URL(string: "https://itch.io/game-assets")!,
            badgeText: "Sponsored"
        ),
        AdItem(
            id: "ad_wacom",
            advertiser: "Wacom Creative",
            headline: "Cintiq & Intuos Precision Stylus Tablets",
            description: "Industry-standard pressure sensitivity for pixel-perfect digital painting and animators.",
            callToAction: "Explore Displays",
            iconSystemName: "pencil.and.outline",
            accentColor: Color(red: 0.36, green: 0.72, blue: 0.98),
            destinationURL: URL(string: "https://www.wacom.com")!,
            badgeText: "Sponsored"
        ),
        AdItem(
            id: "ad_lospec",
            advertiser: "Lospec Pixel Community",
            headline: "Free Curated Pixel Art Color Palettes",
            description: "Explore 1,200+ classic 8-bit, 16-bit, and Game Boy color palettes created by masters.",
            callToAction: "Get Free Palettes",
            iconSystemName: "paintpalette.fill",
            accentColor: Color(red: 0.96, green: 0.71, blue: 0.20),
            destinationURL: URL(string: "https://lospec.com/palette-list")!,
            badgeText: "Community"
        )
    ]

    // MARK: - State

    /// Reference to subscription manager for entitlement checks.
    private let subscriptionManager = SubscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var rotationTimer: AnyCancellable?
    private var remoteRefreshTimer: AnyCancellable?
    private var remoteLoadTask: Task<Void, Never>?

    /// Current inventory. The local sample ads remain in place until a valid
    /// remote response arrives, and also act as the offline fallback.
    @Published private(set) var ads: [AdItem] = AdManager.sampleAds

    /// Whether ads should be rendered. True for free users, false for ad-free lifetime customers.
    @Published private(set) var shouldShowAds: Bool = true

    /// Currently active commercial advertisement.
    @Published private(set) var currentAdIndex: Int = 0

    /// Tracks total ad impressions or click events for analytics.
    @Published private(set) var impressionCount: Int = 0

    var currentAd: AdItem {
        ads[currentAdIndex % ads.count]
    }

    private init() {
        // Observe entitlement changes: when isAdFree becomes true, shouldShowAds is false.
        subscriptionManager.$isAdFree
            .sink { [weak self] isAdFree in
                guard let self = self else { return }
                self.shouldShowAds = !isAdFree
                if isAdFree {
                    self.stopRotation()
                    self.stopRemoteFeedRefresh()
                    self.remoteLoadTask?.cancel()
                } else {
                    self.startRotation()
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
        guard !subscriptionManager.isAdFree else { return }

        remoteLoadTask?.cancel()
        remoteLoadTask = Task { [weak self] in
            guard let self else { return }

            do {
                let creatives = try await RemoteAdFeedLoader(endpoint: Self.remoteFeedURL).load()
                let remoteAds = Self.makeAdItems(from: creatives)
                guard !remoteAds.isEmpty, !Task.isCancelled, !self.subscriptionManager.isAdFree else {
                    return
                }

                self.ads = remoteAds
                self.currentAdIndex = 0
            } catch is CancellationError {
                // A purchase or a newer refresh cancelled this request.
            } catch {
                // Keep the last successful inventory, which starts as the local
                // sample inventory, when the feed is unavailable.
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
        withAnimation(.easeInOut(duration: 0.3)) {
            currentAdIndex = (currentAdIndex + 1) % ads.count
        }
        recordImpression()
    }

    func previousAd() {
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
        let url = currentAd.destinationURL
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
