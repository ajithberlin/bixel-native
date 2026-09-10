// PaywallContainerView.swift
//
// Modern SwiftUI Paywall presentation for Bixel Studio.
// Integrates RevenueCatUI's PaywallView while providing a rich, native
// fallback and purchase flow for Lifetime Ad-Free access.

import SwiftUI

#if canImport(RevenueCat)
import RevenueCat
#endif
#if canImport(RevenueCatUI)
import RevenueCatUI
#endif

struct PaywallContainerView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if canImport(RevenueCatUI)
        if subscriptionManager.isConfigured {
            PaywallView()
                .onPurchaseCompleted { info in
                    if info.entitlements[SubscriptionManager.entitlementID]?.isActive == true {
                        dismiss()
                    }
                }
                .onRestoreCompleted { info in
                    if info.entitlements[SubscriptionManager.entitlementID]?.isActive == true {
                        dismiss()
                    }
                }
                .frame(minWidth: 500, minHeight: 620)
        } else {
            nativeFallbackPaywall
                .frame(width: 520, height: 620)
        }
        #else
        nativeFallbackPaywall
            .frame(width: 520, height: 620)
        #endif
    }

    // MARK: - Native Fallback Paywall
    // Provides a complete, fully functional native Mac purchase sheet for Lifetime Ad-Free.

    private var nativeFallbackPaywall: some View {
        ZStack {
            StudioTheme.homeDark
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Header Bar with Close Button
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                // Crown / Mascot Icon
                ZStack {
                    Circle()
                        .fill(StudioTheme.bixelGreenSoft)
                        .frame(width: 72, height: 72)
                    Image(systemName: "crown.fill")
                        .font(.system(size: 32))
                        .foregroundColor(StudioTheme.bixelGreen)
                }

                // Headline
                VStack(spacing: 6) {
                    Text("Unlock Bixel Studio Lifetime")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("One-time purchase. No recurring subscriptions.")
                        .font(.system(size: 14))
                        .foregroundColor(StudioTheme.textSecondary)
                }

                // Feature Highlights
                VStack(alignment: .leading, spacing: 14) {
                    featureRow(icon: "shield.slash.fill", title: "100% Ad-Free Canvas", description: "Never see another banner or promotion while creating.")
                    featureRow(icon: "sparkles", title: "Unrestricted Pixel Art Creation", description: "Full access to sprite, animation, and tilemap suites.")
                    featureRow(icon: "arrow.down.to.line.compact", title: "All Future Updates Included", description: "Buy once, own it forever on your Apple Account.")
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(StudioTheme.homeCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                        )
                )

                // Error / Status Message
                if let error = subscriptionManager.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else if let notice = subscriptionManager.statusNotice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundColor(StudioTheme.bixelGreen)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                // Primary Purchase Action
                Button {
                    Task {
                        let success = await subscriptionManager.purchaseLifetime()
                        if success {
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if subscriptionManager.isPurchasing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "cart.fill")
                            Text("Unlock Lifetime — One-Time Purchase")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(StudioTheme.bixelGreen)
                    )
                    .shadow(color: StudioTheme.bixelGreen.opacity(0.3), radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(subscriptionManager.isPurchasing)

                // Secondary Action: Restore Purchases
                Button {
                    Task {
                        let success = await subscriptionManager.restorePurchases()
                        if success {
                            dismiss()
                        }
                    }
                } label: {
                    if subscriptionManager.isRestoring {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Already purchased? Restore Purchases")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(subscriptionManager.isRestoring)
            }
            .padding(32)
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(StudioTheme.bixelGreen)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(StudioTheme.textSecondary)
            }
            Spacer()
        }
    }
}
