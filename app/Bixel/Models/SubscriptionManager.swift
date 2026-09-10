// SubscriptionManager.swift
//
// In-App Purchase and Entitlement Manager for Bixel Studio using RevenueCat SDK.
// Handles one-time lifetime purchases, entitlement status checks ('ad_free'),
// offerings retrieval, purchase restorations, and real-time customer info updates.

import Foundation
import SwiftUI
import Combine

#if canImport(RevenueCat)
import RevenueCat
#endif
#if canImport(RevenueCatUI)
import RevenueCatUI
#endif

@MainActor
final class SubscriptionManager: NSObject, ObservableObject {
    static let shared = SubscriptionManager()

    // MARK: - Configuration Constants

    /// Info.plist key populated by the build scripts from the selected dotenv file.
    static let apiKeyInfoPlistKey = "RevenueCatAPIKey"

    /// Public RevenueCat API key for the current build, if configured.
    static var apiKey: String? {
        guard let configuredKey = Bundle.main.object(forInfoDictionaryKey: apiKeyInfoPlistKey) as? String else {
            return nil
        }

        let key = configuredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    /// Entitlement identifier in RevenueCat dashboard.
    static let entitlementID = "ad_free"

    /// Expected identifier for the Lifetime one-time purchase product / package.
    static let lifetimeProductID = "lifetime"

    // MARK: - Published State

    /// Indicates whether the user has unlocked the ad-free lifetime entitlement.
    @Published private(set) var isAdFree: Bool = false

    /// Indicates network or purchase operations in progress.
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var isRestoring: Bool = false

    /// Human-readable error message to display in UI alerts if needed.
    @Published var errorMessage: String? = nil

    /// User-visible confirmation for actions like restore purchases.
    @Published var statusNotice: String? = nil

    #if canImport(RevenueCat)
    /// Cached customer info from RevenueCat.
    @Published private(set) var customerInfo: CustomerInfo? = nil

    /// Current offering retrieved from RevenueCat.
    @Published private(set) var currentOffering: Offering? = nil

    /// The specific one-time Lifetime package, if found in current offerings.
    @Published private(set) var lifetimePackage: Package? = nil
    #endif

    private var hasConfigured = false

    override private init() {
        super.init()
    }

    // MARK: - SDK Initialization

    /// Configure RevenueCat SDK with the API key and set up delegate callbacks.
    /// Call this once during application startup in `BixelApp.init()`.
    func configure() {
        guard !hasConfigured else { return }

        #if canImport(RevenueCat)
        guard let apiKey = Self.apiKey else {
            print("[SubscriptionManager] RevenueCat API key is not configured for this build.")
            return
        }

        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .info
        #endif

        Purchases.configure(withAPIKey: apiKey)
        Purchases.shared.delegate = self
        hasConfigured = true

        Task {
            await refreshCustomerInfo()
            await fetchOfferings()
        }
        #else
        hasConfigured = true
        print("[SubscriptionManager] RevenueCat SDK is not linked in this build target. Using mock fallback.")
        #endif
    }

    // MARK: - Entitlement & Customer Info

    /// Fetch latest customer info from RevenueCat servers and update entitlement state.
    @discardableResult
    func refreshCustomerInfo() async -> Bool {
        #if canImport(RevenueCat)
        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await Purchases.shared.customerInfo()
            self.customerInfo = info
            self.updateEntitlements(from: info)
            return true
        } catch {
            print("[SubscriptionManager] Failed to fetch customer info: \(error.localizedDescription)")
            self.errorMessage = "Unable to verify purchase status: \(error.localizedDescription)"
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(RevenueCat)
    private func updateEntitlements(from info: CustomerInfo) {
        let active = info.entitlements[Self.entitlementID]?.isActive == true
        if self.isAdFree != active {
            self.isAdFree = active
            print("[SubscriptionManager] 'ad_free' entitlement updated: \(active)")
        }
    }
    #endif

    // MARK: - Offerings Retrieval

    /// Fetches the configured offerings and locates the lifetime package.
    func fetchOfferings() async {
        #if canImport(RevenueCat)
        do {
            let offerings = try await Purchases.shared.offerings()
            self.currentOffering = offerings.current

            // Check standard lifetime package slot, or search by package/product identifier
            if let current = offerings.current {
                self.lifetimePackage = current.lifetime
                    ?? current.availablePackages.first {
                        $0.identifier.lowercased() == Self.lifetimeProductID.lowercased() ||
                        $0.storeProduct.productIdentifier.lowercased().contains(Self.lifetimeProductID.lowercased())
                    }
            }
        } catch {
            print("[SubscriptionManager] Error fetching offerings: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Purchase Operations

    #if canImport(RevenueCat)
    /// Purchases a specific package (e.g. Lifetime package) using async/await.
    @discardableResult
    func purchase(package: Package) async -> Bool {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                print("[SubscriptionManager] User cancelled purchase.")
                return false
            }

            self.customerInfo = result.customerInfo
            self.updateEntitlements(from: result.customerInfo)

            if isAdFree {
                statusNotice = "Thank you! Lifetime ad-free access has been unlocked."
                return true
            } else {
                errorMessage = "Purchase was completed, but 'ad_free' entitlement was not granted. Please contact support."
                return false
            }
        } catch let error as RevenueCat.ErrorCode {
            if error == .purchaseCancelledError {
                // User intentionally pressed cancel in the Apple sheet
                return false
            }
            let userMessage = Self.userFriendlyMessage(for: error)
            self.errorMessage = userMessage
            print("[SubscriptionManager] RevenueCat purchase error: \(error)")
            return false
        } catch {
            self.errorMessage = error.localizedDescription
            print("[SubscriptionManager] Purchase error: \(error.localizedDescription)")
            return false
        }
    }
    #endif

    /// Convenience method to purchase the configured Lifetime package.
    @discardableResult
    func purchaseLifetime() async -> Bool {
        #if canImport(RevenueCat)
        if let package = lifetimePackage ?? currentOffering?.lifetime {
            return await purchase(package: package)
        }

        // If offerings are not yet loaded, try fetching them once
        await fetchOfferings()
        if let package = lifetimePackage ?? currentOffering?.lifetime {
            return await purchase(package: package)
        }

        errorMessage = "Lifetime product is currently unavailable. Please check your internet connection or try again later."
        return false
        #else
        errorMessage = "In-App Purchases are not available in this build."
        return false
        #endif
    }

    // MARK: - Restore Purchases

    /// Restores previous purchases (required by App Store Review for non-consumables).
    @discardableResult
    func restorePurchases() async -> Bool {
        #if canImport(RevenueCat)
        isRestoring = true
        errorMessage = nil
        statusNotice = nil
        defer { isRestoring = false }

        do {
            let info = try await Purchases.shared.restorePurchases()
            self.customerInfo = info
            self.updateEntitlements(from: info)

            if isAdFree {
                statusNotice = "Purchases successfully restored! Lifetime ad-free is active."
                return true
            } else {
                statusNotice = "No prior Lifetime purchase found for this Apple Account."
                return false
            }
        } catch {
            self.errorMessage = "Failed to restore purchases: \(error.localizedDescription)"
            return false
        }
        #else
        errorMessage = "Restore purchases is not available in this build."
        return false
        #endif
    }

    // MARK: - Testing / Debug Helpers

    /// For local UI testing: toggles ad-free state in DEBUG builds.
    func debugToggleAdFree() {
        #if DEBUG
        isAdFree.toggle()
        print("[SubscriptionManager] Debug toggle: isAdFree = \(isAdFree)")
        #endif
    }

    // MARK: - Error Handling Helpers

    #if canImport(RevenueCat)
    private static func userFriendlyMessage(for errorCode: RevenueCat.ErrorCode) -> String {
        switch errorCode {
        case .purchaseNotAllowedError:
            return "Purchases are disabled on this device or Apple Account."
        case .paymentPendingError:
            return "Payment is pending approval (e.g. Ask to Buy)."
        case .networkError:
            return "Network connection issue. Please check your internet connection and try again."
        case .productAlreadyPurchasedError:
            return "You already own this item. Restoring purchases..."
        case .receiptAlreadyInUseError:
            return "This purchase is linked to another account."
        case .storeProblemError:
            return "There was a problem connecting to the App Store. Please try again."
        default:
            return errorCode.description
        }
    }
    #endif
}

// MARK: - PurchasesDelegate

#if canImport(RevenueCat)
extension SubscriptionManager: PurchasesDelegate {
    /// Called whenever customer info is updated in the background (e.g. after a purchase,
    /// family sharing grant, refund, or subscription status change).
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            self.customerInfo = customerInfo
            self.updateEntitlements(from: customerInfo)
        }
    }
}
#endif
