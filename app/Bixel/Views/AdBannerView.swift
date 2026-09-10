// AdBannerView.swift
//
// Responsive banner ad component for Bixel Studio.
// Displayed for free-tier users; automatically hidden when the user owns
// the 'ad_free' lifetime entitlement.
//
// On macOS: Renders a high-contrast, Procreate-styled desktop banner container
// with direct upgrade actions that trigger the RevenueCat Paywall.
// On iOS/Catalyst: Can embed the native Google Mobile Ads GADBannerView.

import SwiftUI
import AppKit

struct AdBannerView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @ObservedObject private var adManager = AdManager.shared

    /// Callback to open the RevenueCat paywall.
    var onPresentPaywall: () -> Void

    @State private var isHovered = false

    var body: some View {
        if adManager.shouldShowAds {
            bannerContent
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.96))
                ))
                .animation(.easeInOut(duration: 0.25), value: adManager.shouldShowAds)
        }
    }

    private var bannerContent: some View {
        HStack(spacing: 12) {
            // "Ad" badge required by standard ad policies
            Text("AD")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )

            // Pixel Art Icon / Mascot Accent
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(StudioTheme.bixelGreen)
                Text("Love Bixel Studio?")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Text("Unlock Lifetime Ad-Free with a one-time purchase. Support independent pixel art tools!")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Color.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // "Remove Ads" Action Button -> Opens RevenueCat Paywall
            Button {
                onPresentPaywall()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Remove Ads")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(StudioTheme.bixelGreen)
                )
                .shadow(color: StudioTheme.bixelGreen.opacity(0.3), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .help("One-time lifetime purchase to remove all ads forever")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StudioTheme.hairline, lineWidth: 1)
                )
        )
        .onAppear {
            adManager.recordImpression()
        }
    }
}
