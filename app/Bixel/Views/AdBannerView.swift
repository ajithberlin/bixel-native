// AdBannerView.swift
//
// Responsive commercial ad banner component for Bixel Studio.
// Displays rotating commercial advertisements from the remote house-ad feed
// for free-tier users with interactive carousel controls, rich typography,
// sponsor artwork, and a paywall trigger.
// Automatically hidden when the user acquires the 'ad_free' lifetime entitlement.

import SwiftUI

struct AdBannerView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @ObservedObject private var adManager = AdManager.shared

    /// Callback to open the RevenueCat paywall.
    var onPresentPaywall: () -> Void

    @State private var isHovered = false
    @State private var isCtaHovered = false
    @State private var isCrownHovered = false

    init(onPresentPaywall: @escaping () -> Void = {}) {
        self.onPresentPaywall = onPresentPaywall
    }

    var body: some View {
        if adManager.shouldShowAds, let ad = adManager.currentAd {
            bannerContainer(for: ad)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.96))
                ))
                .animation(.easeInOut(duration: 0.25), value: adManager.shouldShowAds)
        }
    }

    private func bannerContainer(for ad: AdItem) -> some View {
        HStack(spacing: 14) {
            // MARK: - Sponsor Icon / Brand Avatar Container
            Button {
                adManager.clickCurrentAd()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    ad.accentColor.opacity(0.22),
                                    ad.accentColor.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(ad.accentColor.opacity(isHovered ? 0.55 : 0.35), lineWidth: 1)
                        )

                    if let iconURL = ad.iconURL {
                        AsyncImage(url: iconURL) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: ad.iconSystemName)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(ad.accentColor)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        Image(systemName: ad.iconSystemName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(ad.accentColor)
                    }
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .help("Visit \(ad.advertiser)")

            if let imageURL = ad.imageURL {
                Button {
                    adManager.clickCurrentAd()
                } label: {
                    AsyncImage(url: imageURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 76, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Preview ad from \(ad.advertiser)")
            }

            // MARK: - Ad Content (Headline, Badges & Description)
            Button {
                adManager.clickCurrentAd()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    // Line 1: Badges + Advertiser + Headline
                    HStack(spacing: 6) {
                        // "AD" badge
                        Text("AD")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.85))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                            )

                        // Sponsor badge
                        Text(ad.badgeText)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(ad.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(ad.accentColor.opacity(0.16))
                            )

                        // Advertiser name
                        Text(ad.advertiser)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("•")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.35))

                        // Headline
                        Text(ad.headline)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.92))
                            .lineLimit(1)
                    }

                    // Line 2: Descriptive Subtitle
                    Text(ad.description)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Click ad: \(ad.destinationURL.absoluteString)")

            Spacer(minLength: 8)

            // MARK: - Carousel Navigation Indicators & Arrows
            HStack(spacing: 5) {
                // Prev button
                Button {
                    adManager.previousAd()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Previous sponsor")

                Text("\(adManager.currentAdIndex + 1) / \(adManager.ads.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.5))
                    .frame(minWidth: 34)
                    .help("Ad \(adManager.currentAdIndex + 1) of \(adManager.ads.count)")

                // Next button
                Button {
                    adManager.nextAd()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Next sponsor")
            }

            Divider()
                .frame(height: 24)
                .overlay(Color.white.opacity(0.12))

            // MARK: - Ad Call-To-Action (Advertiser Website)
            Button {
                adManager.clickCurrentAd()
            } label: {
                HStack(spacing: 5) {
                    Text(ad.callToAction)
                        .font(.system(size: 11, weight: .bold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(ad.accentColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(ad.accentColor.opacity(isCtaHovered ? 0.24 : 0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(ad.accentColor.opacity(isCtaHovered ? 0.6 : 0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .onHover { isCtaHovered = $0 }
            .help("Open \(ad.advertiser) website")

            // Apple requires an obvious way to report inappropriate ads.
            Button {
                adManager.reportCurrentAd()
            } label: {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(StudioTheme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Report this ad")

            // MARK: - "Remove Ads" Paywall Trigger
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(StudioTheme.bixelGreen)
                )
                .shadow(color: StudioTheme.bixelGreen.opacity(isCrownHovered ? 0.5 : 0.3), radius: isCrownHovered ? 8 : 4, y: 1)
            }
            .buttonStyle(.plain)
            .onHover { isCrownHovered = $0 }
            .help("One-time lifetime purchase: Remove all ads forever")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.98),
                            Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isHovered ? ad.accentColor.opacity(0.4) : Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 3)
        .onHover { isHovered = $0 }
        .onAppear {
            adManager.recordImpression()
        }
    }
}
