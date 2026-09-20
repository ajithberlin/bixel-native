// ProjectLoadingAdView.swift
//
// Interstitial loading advertisement view presented when opening or loading projects.
// Displays an animated canvas preparation progress bar alongside a featured sponsor recommendation.
// Automatically finishes loading or lets the user continue once ready. Free-tier users can remove ads via the paywall.

import SwiftUI

struct ProjectLoadingAdView: View {
    let project: StudioProject
    let onFinish: () -> Void
    var onDismiss: (() -> Void)? = nil
    let onPresentPaywall: () -> Void

    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @ObservedObject private var adManager = AdManager.shared
    @State private var progress: Double = 0.0
    @State private var canContinue: Bool = false
    @State private var timer: Timer? = nil
    @State private var spinnerAngle: Double = 0

    var body: some View {
        ZStack {
            // Blurred dark backdrop
            Color.black.opacity(0.68)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            if let ad = adManager.currentAd {
                loadingContent(for: ad)
            } else {
                feedLoadingContent
            }
        }
        .onAppear {
            if subscriptionManager.isAdFree {
                finish()
                return
            }
            if adManager.currentAd != nil {
                adManager.recordImpression()
            }
            startLoading()
        }
        .onChange(of: subscriptionManager.isAdFree) { isAdFree in
            if isAdFree {
                finish()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Loading Header

    private func loadingContent(for ad: AdItem) -> some View {
        VStack(spacing: 0) {
            // 1. Loading Header Bar
            loadingHeader(for: ad)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // Progress Bar
            progressBar(for: ad)
                .padding(.horizontal, 22)
                .padding(.bottom, 18)

            Divider()
                .overlay(Color.white.opacity(0.08))

            // 2. Featured Sponsor Card
            sponsorCard(for: ad)
                .padding(20)

            Divider()
                .overlay(Color.white.opacity(0.08))

            // 3. Action Footer
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 530)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.13, blue: 0.16),
                            Color(red: 0.09, green: 0.10, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(ad.accentColor.opacity(0.35), lineWidth: 1.2)
                )
        )
        .shadow(color: Color.black.opacity(0.65), radius: 32, y: 12)
    }

    private var feedLoadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading sponsor message…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(StudioTheme.textSecondary)
        }
        .frame(width: 300, height: 140)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.14))
        )
    }

    // MARK: - Loading Header

    private func loadingHeader(for ad: AdItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(StudioTheme.bixelGreen.opacity(0.16))
                    .frame(width: 36, height: 36)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(StudioTheme.bixelGreen)
                    .rotationEffect(.degrees(spinnerAngle))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    spinnerAngle = 360
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Opening")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(StudioTheme.textSecondary)

                    Text(project.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                Text(progress >= 1.0 ? "Ready! Launching workspace..." : "Preparing canvas buffers, tile layers & color palettes...")
                    .font(.system(size: 11))
                    .foregroundColor(StudioTheme.textDisabled)
                    .lineLimit(1)
            }

            Spacer()

            // Ad badge & dismiss button
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("AD")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.14)))

                    Text(ad.badgeText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(ad.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(ad.accentColor.opacity(0.16)))
                }

                Button {
                    adManager.reportCurrentAd()
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(StudioTheme.textSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Report this ad")

                if let onDismiss = onDismiss {
                    Button {
                        timer?.invalidate()
                        timer = nil
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.5))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel opening project")
                }
            }
        }
    }

    // MARK: - Progress Bar

    private func progressBar(for ad: AdItem) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 5)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [StudioTheme.bixelGreen, ad.accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * CGFloat(progress)), height: 5)
                    .animation(.linear(duration: 0.05), value: progress)
            }
        }
        .frame(height: 5)
    }

    // MARK: - Featured Sponsor Card

    private func sponsorCard(for ad: AdItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                // Sponsor Icon Box
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    ad.accentColor.opacity(0.24),
                                    ad.accentColor.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(ad.accentColor.opacity(0.4), lineWidth: 1)
                        )

                    if let iconURL = ad.iconURL ?? ad.imageURL {
                        AsyncImage(url: iconURL) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: ad.iconSystemName)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(ad.accentColor)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Image(systemName: ad.iconSystemName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(ad.accentColor)
                    }
                }
                .frame(width: 52, height: 52)

                // Text Content
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(ad.advertiser)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("•")
                            .foregroundColor(Color.white.opacity(0.3))

                        Text("Partner Spotlight")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(StudioTheme.textSecondary)
                    }

                    Text(ad.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(ad.description)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.72))
                        .lineSpacing(2.5)
                        .lineLimit(2)
                }
            }

            // Sponsor Action Button
            Button {
                adManager.clickCurrentAd()
            } label: {
                HStack(spacing: 6) {
                    Text(ad.callToAction)
                        .font(.system(size: 11, weight: .bold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(ad.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(ad.accentColor.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(ad.accentColor.opacity(0.38), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Visit \(ad.advertiser) website")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    // MARK: - Footer Actions

    private var footer: some View {
        HStack {
            // Remove Ads Button
            Button {
                onPresentPaywall()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Remove All Ads")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundColor(StudioTheme.bixelGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help("Upgrade to Lifetime Ad-Free")

            Spacer()

            // Continue / Skip Button
            if canContinue || progress >= 1.0 {
                Button {
                    finish()
                } label: {
                    HStack(spacing: 6) {
                        Text("Open Project")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StudioTheme.bixelGreen)
                    )
                    .shadow(color: StudioTheme.bixelGreen.opacity(0.4), radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening in \(max(1, Int(ceil((1.0 - progress) * 2.4))))s...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(StudioTheme.textDisabled)
                }
            }
        }
    }

    // MARK: - Helpers

    private func startLoading() {
        let totalTicks = 50
        let interval = 2.4 / Double(totalTicks)
        var tick = 0

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { t in
            tick += 1
            progress = min(1.0, Double(tick) / Double(totalTicks))

            if progress >= 0.60 {
                canContinue = true
            }

            if tick >= totalTicks {
                t.invalidate()
                timer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    finish()
                }
            }
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        onFinish()
    }
}
