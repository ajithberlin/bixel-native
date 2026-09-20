import Foundation

@main
@MainActor
struct SubscriptionEntitlementTests {
    static func main() {
        let manager = SubscriptionManager.shared
        manager.resetForTesting()

        precondition(!manager.isAdFree, "A fresh customer must not start ad-free")
        precondition(!UserDefaults.standard.bool(forKey: SubscriptionManager.userDefaultsAdFreeKey), "UserDefaults must not have ad-free set for a fresh customer")
        precondition(!AdManager.shared.shouldShowAds, "Ads stay hidden until the remote feed loads")

        manager.applyAdFreeEntitlement(isActive: true)

        precondition(manager.isAdFree, "An active ad-free entitlement must update shared state")
        precondition(UserDefaults.standard.bool(forKey: SubscriptionManager.userDefaultsAdFreeKey), "Ad-free entitlement must be persisted in UserDefaults")
        precondition(!AdManager.shared.shouldShowAds, "Ads must disappear as soon as entitlement becomes active")
        precondition(AdManager.shared.ads.isEmpty, "Ads inventory must be empty when ad-free")

        manager.applyAdFreeEntitlement(isActive: false)

        precondition(!manager.isAdFree, "A revoked entitlement must clear shared state")
        precondition(!UserDefaults.standard.bool(forKey: SubscriptionManager.userDefaultsAdFreeKey), "Revoked entitlement must clear UserDefaults")
        precondition(!AdManager.shared.shouldShowAds, "Ads stay hidden until a remote creative is available")

        manager.resetForTesting()
        print("Subscription entitlement tests passed")
    }
}
