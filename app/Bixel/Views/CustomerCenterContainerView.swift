// CustomerCenterContainerView.swift
//
// Customer Center presentation for Bixel Studio.
// Uses RevenueCatUI's CustomerCenterView for self-service purchase management,
// with a native fallback sheet displaying current purchase status and restore controls.

import SwiftUI

#if canImport(RevenueCat)
import RevenueCat
#endif
#if canImport(RevenueCatUI)
import RevenueCatUI
#endif

struct CustomerCenterContainerView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // RevenueCatUI's CustomerCenterView is currently iOS-only. The package
        // itself can still be imported on macOS, so gate the view by platform
        // as well as module availability.
        #if os(iOS) && canImport(RevenueCatUI)
        CustomerCenterView()
            .frame(minWidth: 500, minHeight: 550)
        #else
        nativeCustomerCenter
            .frame(width: 480, height: 440)
        #endif
    }

    private var nativeCustomerCenter: some View {
        ZStack {
            StudioTheme.homeDark
                .ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Text("Purchases & Account")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Plan")
                                .font(.system(size: 11))
                                .foregroundColor(StudioTheme.textSecondary)
                            Text(subscriptionManager.isAdFree ? "Lifetime Ad-Free (Unlocked)" : "Free Tier (Supported by Ads)")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Image(systemName: subscriptionManager.isAdFree ? "checkmark.seal.fill" : "person.crop.circle")
                            .font(.system(size: 24))
                            .foregroundColor(subscriptionManager.isAdFree ? StudioTheme.bixelGreen : StudioTheme.textDisabled)
                    }
                    .padding(16)
                    .background(StudioTheme.homeCard, in: RoundedRectangle(cornerRadius: 12))
                }

                if let notice = subscriptionManager.statusNotice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundColor(StudioTheme.bixelGreen)
                }

                Spacer()

                Button {
                    Task {
                        await subscriptionManager.restorePurchases()
                    }
                } label: {
                    HStack {
                        if subscriptionManager.isRestoring {
                            ProgressView().controlSize(.small)
                        }
                        Text("Restore Purchases")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(28)
        }
    }
}
