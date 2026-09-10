// AdBannerView.swift
//
// Responsive commercial ad banner component for Bixel Studio.
// Displays rotating commercial advertisements (Google Ads, Unity Store, itch.io, Wacom)
// for free-tier users. Automatically hidden when the user acquires the 'ad_free' lifetime entitlement.

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
            bannerContainer
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.96))
                ))
                .animation(.easeInOut(duration: 0.25), value: adManager.shouldShowAds)
        }
    }

    private var bannerContainer: some View {
        let ad = adManager.currentAd

        return HStack(spacing: 12) {
            // MARK: - Ad Network Badges (AD + AdChoices)
            HStack(spacing: 5) {
                Text("AD")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )

                Text(ad.badgeText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(ad.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(ad.accentColor.opacity(0.15))
                    )
            }

            // MARK: - Advertiser Brand Icon & Name
            Button {
                adManager.clickCurrentAd()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ad.iconSystemName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ad.accentColor)
                        .frame(width: 16)

                    Text(ad.advertiser)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .help("Visit \(ad.advertiser)")

            Divider()
                .frame(height: 14)
                .overlay(Color.white.opacity(0.12))

            // MARK: - Ad Headline & Description (Clickable)
            Button {
                adManager.clickCurrentAd()
            } label: {
                HStack(spacing: 6) {
                    Text(ad.headline)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.95))
                        .lineLimit(1)

                    Text("—")
                        .foregroundColor(Color.white.opacity(0.3))

                    Text(ad.description)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .help("Click ad: \(ad.destinationURL.absoluteString)")

            Spacer(minLength: 8)

            // MARK: - Ad Call-To-Action (Advertiser link)
            Button {
                adManager.clickCurrentAd()
            } label: {
                HStack(spacing: 4) {
                    Text(ad.callToAction)
                        .font(.system(size: 10, weight: .bold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(ad.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ad.accentColor.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(ad.accentColor.opacity(0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Open advertiser website")

            // MARK: - Next / Rotate Ad Affordance
            Button {
                adManager.nextAd()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.4))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Show next advertisement")

            Divider()
                .frame(height: 16)
                .overlay(Color.white.opacity(0.18))

            // MARK: - "Remove Ads" Action Button -> Opens RevenueCat Paywall
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
                .shadow(color: StudioTheme.bixelGreen.opacity(0.35), radius: 5, y: 1)
            }
            .buttonStyle(.plain)
            .help("One-time lifetime purchase: Remove all ads forever")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1)
                )
        )
        .onAppear {
            adManager.recordImpression()
        }
    }
}
