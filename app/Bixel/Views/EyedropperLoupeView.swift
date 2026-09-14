// EyedropperLoupeView.swift
//
// Procreate-style circular color picking loupe with split color ring:
// - Top half of ring: newly sampled color
// - Bottom half of ring: previous color
// - Center circle: magnified nearest-neighbor canvas pixels with reticle
// - Top banner HUD: "Picking color from canvas" + color name

import SwiftUI

struct EyedropperLoupeView: View {
    let session: EyedropperSession

    private let loupeDiameter: CGFloat = 144
    private let innerDiameter: CGFloat = 96
    private let ringThickness: CGFloat = 24

    var body: some View {
        ZStack {
            // Drop shadow for the whole loupe
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: loupeDiameter, height: loupeDiameter)
                .shadow(color: .black.opacity(0.65), radius: 20, y: 6)

            // Split outer ring
            ZStack {
                // Top half: Sampled new color
                Circle()
                    .strokeBorder(Color(session.currentColor.cgColor), lineWidth: ringThickness)
                    .frame(width: loupeDiameter - ringThickness, height: loupeDiameter - ringThickness)
                    .mask(
                        Rectangle()
                            .frame(width: loupeDiameter, height: loupeDiameter / 2)
                            .offset(y: -loupeDiameter / 4)
                    )

                // Bottom half: Previous color
                Circle()
                    .strokeBorder(Color(session.previousColor.cgColor), lineWidth: ringThickness)
                    .frame(width: loupeDiameter - ringThickness, height: loupeDiameter - ringThickness)
                    .mask(
                        Rectangle()
                            .frame(width: loupeDiameter, height: loupeDiameter / 2)
                            .offset(y: loupeDiameter / 4)
                    )

                // Horizontal dividers between the two semicircles
                HStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.7))
                        .frame(width: ringThickness, height: 1.5)
                    Spacer()
                    Rectangle()
                        .fill(Color.black.opacity(0.7))
                        .frame(width: ringThickness, height: 1.5)
                }
                .frame(width: loupeDiameter)

                // Hairline outer and inner borders
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2)
                    .frame(width: loupeDiameter, height: loupeDiameter)

                Circle()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.0)
                    .frame(width: innerDiameter, height: innerDiameter)
            }
            .frame(width: loupeDiameter, height: loupeDiameter)

            // Magnified center window
            ZStack {
                Circle()
                    .fill(Color(white: 0.12))
                    .frame(width: innerDiameter, height: innerDiameter)

                if let crop = session.magnifiedCrop {
                    Image(decorative: crop, scale: 1.0)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: innerDiameter, height: innerDiameter)
                }

                // Grid overlay and center target reticle (15x15 sample grid)
                LoupeReticleOverlay(size: innerDiameter, gridCount: 15)
            }
            .clipShape(Circle())
            .frame(width: innerDiameter, height: innerDiameter)
        }
        .frame(width: loupeDiameter, height: loupeDiameter)
    }
}

// MARK: - Center Reticle Overlay

private struct LoupeReticleOverlay: View {
    let size: CGFloat
    let gridCount: Int

    var body: some View {
        let cellSize = size / CGFloat(gridCount)

        ZStack {
            // Subtle pixel grid lines
            Canvas { context, canvasSize in
                var gridPath = Path()
                for i in 1..<gridCount {
                    let pos = CGFloat(i) * cellSize
                    // Vertical line
                    gridPath.move(to: CGPoint(x: pos, y: 0))
                    gridPath.addLine(to: CGPoint(x: pos, y: canvasSize.height))
                    // Horizontal line
                    gridPath.move(to: CGPoint(x: 0, y: pos))
                    gridPath.addLine(to: CGPoint(x: canvasSize.width, y: pos))
                }
                context.stroke(gridPath, with: .color(Color.white.opacity(0.18)), lineWidth: 0.5)
            }
            .frame(width: size, height: size)

            // Center pixel reticle target frame (framed around center sampled pixel)
            Rectangle()
                .strokeBorder(Color.black.opacity(0.85), lineWidth: 1.8)
                .overlay(
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 1.0)
                )
                .frame(width: cellSize + 0.5, height: cellSize + 0.5)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Top Notification HUD Banner

struct EyedropperTopBanner: View {
    let session: EyedropperSession

    var body: some View {
        VStack(spacing: 3) {
            Text("Picking color from canvas")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Color.white.opacity(0.78))

            Text(session.colorName.isEmpty ? "Color" : session.colorName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(StudioTheme.procreateGlass)
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
        .allowsHitTesting(false)
    }
}

// MARK: - Reactive Overlays

/// Observed wrapper to guarantee reactive SwiftUI invalidation and rendering
/// across coordinate spaces when `model.eyedropperSession` changes.
struct EyedropperOverlayView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { _ in
            if let session = model.eyedropperSession, session.isActive {
                EyedropperLoupeView(session: session)
                    .position(session.viewPosition)
                    .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.9), value: session.viewPosition)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.82), value: model.eyedropperSession?.isActive)
        .allowsHitTesting(false)
        .zIndex(100)
    }
}

/// Observed top banner HUD wrapper
struct EyedropperBannerOverlay: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let session = model.eyedropperSession, session.isActive {
            EyedropperTopBanner(session: session)
                .padding(.top, 46)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
        }
    }
}
