// AdManager.swift
//
// Sponsor message coordinator for Bixel Studio.
// These are fixed, clearly labelled sponsor messages; no ad SDK or behavioural
// targeting is bundled with the app.

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
    let accentColor: Color
    let destinationURL: URL
    let badgeText: String
}

@MainActor
final class AdManager: ObservableObject {
    static let shared = AdManager()

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

    /// Whether ads should be rendered. True for free users, false for ad-free lifetime customers.
    @Published private(set) var shouldShowAds: Bool = true

    /// Currently active commercial advertisement.
    @Published private(set) var currentAdIndex: Int = 0

    /// Tracks total ad impressions or click events for analytics.
    @Published private(set) var impressionCount: Int = 0

    var currentAd: AdItem {
        Self.sampleAds[currentAdIndex % Self.sampleAds.count]
    }

    private init() {
        // Observe entitlement changes: when isAdFree becomes true, shouldShowAds is false.
        subscriptionManager.$isAdFree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAdFree in
                guard let self = self else { return }
                self.shouldShowAds = !isAdFree
                if isAdFree {
                    self.stopRotation()
                } else {
                    self.startRotation()
                }
            }
            .store(in: &cancellables)

        if shouldShowAds {
            startRotation()
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
            currentAdIndex = (currentAdIndex + 1) % Self.sampleAds.count
        }
        recordImpression()
    }

    func previousAd() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentAdIndex = (currentAdIndex - 1 + Self.sampleAds.count) % Self.sampleAds.count
        }
        recordImpression()
    }

    func selectAd(at index: Int) {
        guard index >= 0 && index < Self.sampleAds.count else { return }
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
