// SubscriptionManager.swift
//
// In-App Purchase and Entitlement Manager for Bixel Studio using RevenueCat SDK.
// Handles one-time lifetime purchases, entitlement status checks ('ad_free'),
// offerings retrieval, purchase restorations, and real-time customer info updates.

import Foundation
import SwiftUI
import Combine
import StoreKit

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
    nonisolated static let apiKeyInfoPlistKey = "RevenueCatAPIKey"

    /// UserDefaults key for persisting ad-free state locally across sessions.
    nonisolated static let userDefaultsAdFreeKey = "bixel_is_ad_free"

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
    nonisolated static let entitlementID = "ad_free"

    /// Product identifier configured in App Store Connect and RevenueCat.
    nonisolated static let lifetimeProductID = "bixel_ad_free"

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

    private var transactionUpdatesTask: Task<Void, Never>?
    private var hasConfigured = false

    /// Whether RevenueCat has been initialized for this build.
    private(set) var isConfigured = false

    override private init() {
        super.init()
        // Restore cached purchase state immediately so ad views never show at startup for paid users.
        self.isAdFree = UserDefaults.standard.bool(forKey: Self.userDefaultsAdFreeKey)
        startStoreKitTransactionListener()
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    // MARK: - SDK Initialization

    /// Configure RevenueCat SDK with the API key and set up delegate callbacks.
    /// Call this once during application startup in `BixelApp.init()`.
    func configure() {
        guard !hasConfigured else { return }
        hasConfigured = true

        Task {
            await checkStoreKitEntitlements()
        }

        #if canImport(RevenueCat)
        guard let apiKey = Self.apiKey else {
            print("[SubscriptionManager] RevenueCat API key is not configured for this build. Using StoreKit 2.")
            return
        }

        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .info
        #endif

        Purchases.configure(withAPIKey: apiKey)
        Purchases.shared.delegate = self
        isConfigured = true

        Task {
            await refreshCustomerInfo()
            await fetchOfferings()
        }
        #else
        print("[SubscriptionManager] RevenueCat SDK is not linked in this build target. Using StoreKit 2.")
        #endif
    }

    // MARK: - StoreKit 2 Integration

    /// Listen for background App Store transactions (purchases, renewals, revocations).
    private func startStoreKitTransactionListener() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                switch result {
                case .verified(let transaction):
                    if transaction.productID == Self.lifetimeProductID {
                        let isActive = transaction.revocationDate == nil
                        await MainActor.run {
                            self.applyAdFreeEntitlement(isActive: isActive)
                        }
                    }
                    await transaction.finish()
                case .unverified(let transaction, _):
                    await transaction.finish()
                }
            }
        }
    }

    /// Checks active StoreKit 2 entitlements directly with Apple's local daemon.
    @discardableResult
    func checkStoreKitEntitlements() async -> Bool {
        var hasLifetime = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == Self.lifetimeProductID && transaction.revocationDate == nil {
                    hasLifetime = true
                    break
                }
            }
        }
        if hasLifetime {
            applyAdFreeEntitlement(isActive: true)
            return true
        }
        return false
    }

    // MARK: - Entitlement & Customer Info

    /// Fetch latest customer info from RevenueCat servers and update entitlement state.
    @discardableResult
    func refreshCustomerInfo() async -> Bool {
        #if canImport(RevenueCat)
        guard isConfigured else {
            return await checkStoreKitEntitlements()
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await Purchases.shared.customerInfo()
            self.customerInfo = info
            self.updateEntitlements(from: info)
            return true
        } catch {
            print("[SubscriptionManager] Failed to fetch customer info: \(error.localizedDescription)")
            let skResult = await checkStoreKitEntitlements()
            if !skResult {
                self.errorMessage = "Unable to verify purchase status: \(error.localizedDescription)"
            }
            return skResult
        }
        #else
        return await checkStoreKitEntitlements()
        #endif
    }

    #if canImport(RevenueCat)
    private func updateEntitlements(from info: CustomerInfo) {
        let hasEntitlement = info.entitlements[Self.entitlementID]?.isActive == true
        let hasLifetimeProduct = info.allPurchasedProductIdentifiers.contains(Self.lifetimeProductID)
            || info.nonSubscriptions.contains(where: { $0.productIdentifier == Self.lifetimeProductID })
        let hasAnyActiveEntitlement = !info.entitlements.active.isEmpty

        if hasEntitlement || hasLifetimeProduct || hasAnyActiveEntitlement {
            applyAdFreeEntitlement(isActive: true)
        } else {
            // Also check StoreKit 2 before revoking
            Task {
                let skVerified = await checkStoreKitEntitlements()
                if !skVerified {
                    applyAdFreeEntitlement(isActive: false)
                }
            }
        }
    }
    #endif

    /// Apply a freshly verified entitlement to the shared UI state and persist locally.
    ///
    /// Keeping this update decoupled from the network callbacks ensures the ad
    /// banner disappears immediately upon purchase confirmation.
    func applyAdFreeEntitlement(isActive: Bool) {
        UserDefaults.standard.set(isActive, forKey: Self.userDefaultsAdFreeKey)
        guard isAdFree != isActive else { return }
        isAdFree = isActive
        print("[SubscriptionManager] 'ad_free' entitlement updated: \(isActive)")
    }

    // MARK: - Offerings Retrieval

    /// Fetches the configured offerings and locates the lifetime package.
    func fetchOfferings() async {
        #if canImport(RevenueCat)
        guard isConfigured else { return }
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

            let isUnlocked = isAdFree
                || result.customerInfo.entitlements[Self.entitlementID]?.isActive == true
                || result.customerInfo.allPurchasedProductIdentifiers.contains(Self.lifetimeProductID)
                || result.customerInfo.nonSubscriptions.contains(where: { $0.productIdentifier == Self.lifetimeProductID })
                || !result.customerInfo.entitlements.active.isEmpty

            if isUnlocked {
                applyAdFreeEntitlement(isActive: true)
                statusNotice = "Thank you! Lifetime ad-free access has been unlocked."
                return true
            } else {
                if await checkStoreKitEntitlements() {
                    statusNotice = "Thank you! Lifetime ad-free access has been unlocked."
                    return true
                }
                errorMessage = "Purchase was completed, but 'ad_free' entitlement was not granted. Please contact support."
                return false
            }
        } catch let error as RevenueCat.ErrorCode {
            if error == .purchaseCancelledError {
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
    /// Falls back to native StoreKit 2 if RevenueCat is unavailable.
    @discardableResult
    func purchaseLifetime() async -> Bool {
        #if canImport(RevenueCat)
        if isConfigured {
            if let package = lifetimePackage ?? currentOffering?.lifetime {
                let success = await purchase(package: package)
                if success { return true }
            } else {
                await fetchOfferings()
                if let package = lifetimePackage ?? currentOffering?.lifetime {
                    let success = await purchase(package: package)
                    if success { return true }
                }
            }
        }
        #endif

        // Native StoreKit 2 purchase fallback
        return await purchaseViaStoreKit()
    }

    /// Purchase directly via Apple's native StoreKit 2 framework.
    private func purchaseViaStoreKit() async -> Bool {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let products = try await Product.products(for: [Self.lifetimeProductID])
            guard let product = products.first else {
                errorMessage = "Lifetime product '\(Self.lifetimeProductID)' is currently unavailable in the App Store."
                return false
            }

            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    let isActive = transaction.revocationDate == nil
                    applyAdFreeEntitlement(isActive: isActive)
                    await transaction.finish()
                    if isActive {
                        statusNotice = "Thank you! Lifetime ad-free access has been unlocked."
                        return true
                    } else {
                        errorMessage = "Purchase was revoked."
                        return false
                    }
                case .unverified(_, let error):
                    errorMessage = "Purchase could not be verified by Apple: \(error.localizedDescription)"
                    return false
                }
            case .userCancelled:
                return false
            case .pending:
                statusNotice = "Purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            print("[SubscriptionManager] StoreKit purchase error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Restore Purchases

    /// Restores previous purchases (required by App Store Review for non-consumables).
    @discardableResult
    func restorePurchases() async -> Bool {
        isRestoring = true
        errorMessage = nil
        statusNotice = nil
        defer { isRestoring = false }

        var restored = false

        #if canImport(RevenueCat)
        if isConfigured {
            do {
                let info = try await Purchases.shared.restorePurchases()
                self.customerInfo = info
                self.updateEntitlements(from: info)
                if isAdFree || info.allPurchasedProductIdentifiers.contains(Self.lifetimeProductID) {
                    applyAdFreeEntitlement(isActive: true)
                    restored = true
                }
            } catch {
                print("[SubscriptionManager] RevenueCat restore error: \(error.localizedDescription)")
            }
        }
        #endif

        // Also sync StoreKit 2 directly with Apple
        do {
            try await AppStore.sync()
            if await checkStoreKitEntitlements() {
                restored = true
            }
        } catch {
            print("[SubscriptionManager] AppStore.sync error: \(error.localizedDescription)")
        }

        if restored || isAdFree {
            statusNotice = "Purchases successfully restored! Lifetime ad-free is active."
            return true
        } else {
            statusNotice = "No prior Lifetime purchase found for this Apple Account."
            return false
        }
    }

    // MARK: - Testing / Debug Helpers

    /// For local UI testing: toggles ad-free state in DEBUG builds.
    func debugToggleAdFree() {
        #if DEBUG
        applyAdFreeEntitlement(isActive: !isAdFree)
        print("[SubscriptionManager] Debug toggle: isAdFree = \(isAdFree)")
        #endif
    }

    /// Reset state for unit tests.
    func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsAdFreeKey)
        isAdFree = false
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
