// AdManager.swift
//
// AdMob Configuration & Ad Presentation Coordinator for Bixel Studio.
// Coordinates ad display, tracks entitlement status from SubscriptionManager,
// and manages ad parameters for both native macOS and iOS/Catalyst targets.

import Foundation
import SwiftUI
import Combine

@MainActor
final class AdManager: ObservableObject {
    static let shared = AdManager()

    // MARK: - AdMob Identifiers

    /// AdMob App ID configured in AdMob Console and Info.plist.
    static let appID = "ca-app-pub-5686188892396495~6976293226"

    /// AdMob Banner Ad Unit ID configured for Bixel Studio banner placement.
    static let bannerAdUnitID = "ca-app-pub-5686188892396495/3054349765"

    // MARK: - State

    /// Reference to subscription manager for entitlement checks.
    private let subscriptionManager = SubscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()

    /// Whether ads should be rendered. True for free users, false for ad-free lifetime customers.
    @Published private(set) var shouldShowAds: Bool = true

    /// Tracks total ad impressions or click events for analytics.
    @Published private(set) var impressionCount: Int = 0

    private init() {
        // Observe entitlement changes: when isAdFree becomes true, shouldShowAds is false.
        subscriptionManager.$isAdFree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAdFree in
                self?.shouldShowAds = !isAdFree
            }
            .store(in: &cancellables)
    }

    /// Record an impression for analytics / tracking.
    func recordImpression() {
        impressionCount += 1
    }
}
