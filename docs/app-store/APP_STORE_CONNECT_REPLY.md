# App Store Connect — Review Resolution Center Response

Copy and paste the following reply into App Store Connect under **Resolution Center** for Submission **baef6394-dcb8-468b-b92d-6df58be1c774**:

---

Dear App Review Team,

Thank you for your review and feedback regarding Bixel Studio. We have addressed both items and uploaded a new binary for your review.

### 1. Guideline 2.4.5(i) - Performance: Minimum Entitlements
Regarding `com.apple.security.files.downloads.read-write`:
We have reviewed our app's entitlement usage and removed `com.apple.security.files.downloads.read-write` entirely from the application entitlements. Bixel Studio only accesses files explicitly chosen by the user through system file dialogs (`NSOpenPanel` / `NSSavePanel`), which is handled exclusively by the `com.apple.security.files.user-selected.read-write` entitlement. The Downloads folder entitlement was redundant and has been removed from the new binary.

### 2. Guideline 2.1(b) - Performance: In-App Purchase "Remove Ads"
We resolved the issue where ads continued to be displayed after purchasing "Remove Ads":
1. **Direct StoreKit Framework Integration**: We integrated Apple's native **StoreKit 2** framework directly into the app (`Transaction.updates` and `Transaction.currentEntitlements`). The app now listens continuously to verified StoreKit transactions in real time and verifies entitlements directly against Apple's local StoreKit daemon upon launch and purchase.
2. **Resilient Entitlement Evaluation**: In addition to checking entitlement identifiers, the app now explicitly verifies the purchased StoreKit product identifier (`bixel_ad_free`), non-subscription transaction records, and verified StoreKit 2 transaction states.
3. **Immediate UI Dismissal & Safeguards**: We updated all ad surfaces (`AdBannerView`, `ProjectLoadingAdView`, and canvas overlays) to immediately hide all ads and dismiss any open interstitial loading overlays as soon as the `bixel_ad_free` transaction is confirmed.
4. **Persistent State**: The unlocked ad-free status is now stored locally in `UserDefaults` to ensure that ad-free status persists immediately across launches without any delay.

### Testing Instructions for Reviewer:
- To test Remove Ads:
  1. Click the "Remove Ads" button on the banner at the bottom of the canvas, or open the action menu (top right) and choose "Unlock Lifetime Ad-Free…".
  2. Complete the purchase in the sandbox environment.
  3. Notice that the paywall immediately closes, the ad banner disappears, interstitial project loading ads are skipped, and the top bar updates to reflect the Lifetime Ad-Free status.
  4. Restoring purchases via "Restore Purchases" in the menu or Customer Center also verifies the purchase state directly with StoreKit.

Thank you again for your time and assistance. Please let us know if you need any additional information.

Best regards,
Ajith Berlin A
Bixel Studio Development Team
