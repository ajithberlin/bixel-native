import Foundation

@main
@MainActor
struct SubscriptionEntitlementTests {
    static func main() {
        let manager = SubscriptionManager.shared

        precondition(!manager.isAdFree, "A fresh customer must not start ad-free")
        precondition(AdManager.shared.shouldShowAds, "Ads should be visible for a free customer")

        manager.applyAdFreeEntitlement(isActive: true)

        precondition(manager.isAdFree, "An active ad-free entitlement must update shared state")
        precondition(!AdManager.shared.shouldShowAds, "Ads must disappear as soon as entitlement becomes active")

        manager.applyAdFreeEntitlement(isActive: false)

        precondition(!manager.isAdFree, "A revoked entitlement must clear shared state")
        precondition(AdManager.shared.shouldShowAds, "Ads must return when entitlement is inactive")
        print("Subscription entitlement tests passed")
    }
}
