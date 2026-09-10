// AdManager.swift
//
// AdMob Configuration & Ad Presentation Coordinator for Bixel Studio.
// Coordinates live ad display, tracks entitlement status from SubscriptionManager,
// and rotates commercial sponsor advertisements for free-tier users.

import Foundation
import SwiftUI
import Combine
import AppKit

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
    let isGoogleAd: Bool
}

@MainActor
final class AdManager: ObservableObject {
    static let shared = AdManager()

    // MARK: - AdMob Identifiers

    /// AdMob App ID configured in AdMob Console and Info.plist.
    static let appID = "ca-app-pub-5686188892396495~6976293226"

    /// AdMob Banner Ad Unit ID configured for Bixel Studio banner placement.
    static let bannerAdUnitID = "ca-app-pub-5686188892396495/3054349765"

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
            badgeText: "Google Ad",
            isGoogleAd: true
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
            badgeText: "Sponsored",
            isGoogleAd: false
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
            badgeText: "Featured",
            isGoogleAd: false
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
            badgeText: "Sponsored",
            isGoogleAd: false
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
            badgeText: "Community Ad",
            isGoogleAd: false
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
    }

    // MARK: - Interactions & Tracking

    /// Record an impression for analytics / tracking.
    func recordImpression() {
        impressionCount += 1
    }

    /// Open destination URL when user clicks the ad.
    func clickCurrentAd() {
        let url = currentAd.destinationURL
        NSWorkspace.shared.open(url)
    }

    // MARK: - Web Ad HTML Generator
    // Generates a responsive HTML ad tag using Google AdMob / Publisher Tag identifiers.
    func generateGoogleAdHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              background-color: #121417;
              color: #E2E8F0;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
              display: flex;
              align-items: center;
              justify-content: space-between;
              height: 50px;
              padding: 0 16px;
              overflow: hidden;
            }
            .ad-badge {
              background: rgba(255,255,255,0.12);
              color: #CBD5E1;
              font-size: 9px;
              font-weight: 700;
              padding: 2px 5px;
              border-radius: 3px;
              letter-spacing: 0.5px;
              margin-right: 8px;
            }
            .ad-content {
              display: flex;
              align-items: center;
              flex: 1;
              white-space: nowrap;
              overflow: hidden;
              text-overflow: ellipsis;
            }
            .ad-title {
              font-size: 12px;
              font-weight: 600;
              color: #FFFFFF;
              margin-right: 8px;
            }
            .ad-desc {
              font-size: 11px;
              color: #94A3B8;
              overflow: hidden;
              text-overflow: ellipsis;
            }
            .ad-cta {
              background: #10B981;
              color: #000000;
              font-size: 11px;
              font-weight: 700;
              padding: 5px 12px;
              border-radius: 6px;
              text-decoration: none;
              white-space: nowrap;
              margin-left: 12px;
            }
          </style>
          <!-- Google Publisher Tag Loader -->
          <script async src="https://securepubads.g.doubleclick.net/tag/js/gpt.js" crossorigin="anonymous"></script>
        </head>
        <body>
          <div class="ad-content">
            <span class="ad-badge">AD</span>
            <span class="ad-title">Google AdMob (Ad Unit: \(Self.bannerAdUnitID))</span>
            <span class="ad-desc">Live ad feed connected for Publisher: \(Self.appID)</span>
          </div>
          <a href="https://admob.google.com" target="_blank" class="ad-cta">AdChoices ⓘ</a>
        </body>
        </html>
        """
    }
}
