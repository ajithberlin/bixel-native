// Theme.swift
//
// Procreate-inspired dark design system for the studio: monochrome charcoal
// surfaces, a single quiet accent, and thin hairline borders. Everything the
// canvas-facing chrome uses is defined here so the whole UI stays consistent.

import SwiftUI

enum StudioTheme {
    // Surfaces
    static let background = Color(red: 0.086, green: 0.088, blue: 0.098)      // ~#16161a
    static let panel = Color(red: 0.13, green: 0.133, blue: 0.145)            // ~#222226
    static let panelElevated = Color(red: 0.165, green: 0.169, blue: 0.184)   // ~#2a2b2f
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)

    // Text
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textDisabled = Color.white.opacity(0.28)

    // Accent (Procreate's vivid blue highlight)
    static let accent = Color(red: 0.10, green: 0.50, blue: 0.98)              // #1a7ffb
    static let accentSoft = Color(red: 0.10, green: 0.50, blue: 0.98).opacity(0.18)
    static let procreateBlue = Color(red: 0.10, green: 0.50, blue: 0.98)
    static let procreateGlass = Color(red: 0.13, green: 0.135, blue: 0.15).opacity(0.88)
    static let procreateRowInactive = Color(white: 0.20, opacity: 0.55)

    // Bixel Brand Accents & Home Dashboard
    static let bixelGreen = Color(red: 0.52, green: 0.88, blue: 0.34)          // #85E057
    static let bixelGreenDark = Color(red: 0.32, green: 0.65, blue: 0.18)
    static let bixelGreenSoft = Color(red: 0.52, green: 0.88, blue: 0.34).opacity(0.18)
    static let homeDark = Color(red: 0.065, green: 0.07, blue: 0.08)          // Deep dark charcoal
    static let homeCard = Color(red: 0.105, green: 0.112, blue: 0.128)        // Card surface
    static let homeCardHover = Color(red: 0.14, green: 0.148, blue: 0.168)
    static let homeCardBorder = Color.white.opacity(0.07)
    static let homeBorderHover = Color.white.opacity(0.16)

    // Asset Tag Badges
    static let tagSpriteBg = Color(red: 0.12, green: 0.28, blue: 0.18)
    static let tagSpriteText = Color(red: 0.48, green: 0.92, blue: 0.52)
    static let tagAnimationBg = Color(red: 0.26, green: 0.16, blue: 0.42)
    static let tagAnimationText = Color(red: 0.78, green: 0.58, blue: 0.98)
    static let tagTilesetBg = Color(red: 0.14, green: 0.24, blue: 0.42)
    static let tagTilesetText = Color(red: 0.46, green: 0.72, blue: 0.98)
    static let tagMapBg = Color(red: 0.32, green: 0.20, blue: 0.10)
    static let tagMapText = Color(red: 0.98, green: 0.72, blue: 0.36)

    static let canvasBackground = Color(red: 0.11, green: 0.113, blue: 0.125)

    // Misc
    static let cornerRadius: CGFloat = 10
    static let panelRadius: CGFloat = 16
    static let controlHeight: CGFloat = 30
}

// MARK: - Shared modifiers

extension View {
    /// A hairline-bordered, subtle-surfaced card used for panels and bars.
    func studioSurface() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadius, style: .continuous)
                    .fill(StudioTheme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius, style: .continuous)
                            .strokeBorder(StudioTheme.hairline, lineWidth: 1)
                    )
            )
    }

    func studioButton() -> some View {
        self
            .buttonStyle(StudioButtonStyle())
    }

    /// Floating capsule chrome (top bar, tool rail) — translucent material
    /// with a hairline and soft shadow, Procreate-style.
    func studioPill() -> some View {
        self
            .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
            .overlay(Capsule(style: .continuous).strokeBorder(StudioTheme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    /// Floating rounded panel (color/layers, assistant) over the canvas.
    func studioPanel(radius: CGFloat = 14) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(StudioTheme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
    }

    /// Procreate-style floating frosted card with deep blur and subtle hairline.
    func procreatePanel(radius: CGFloat = 16) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(StudioTheme.procreateGlass)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 8)
    }
}

/// Procreate layer visibility checkbox (square with clean checkmark).
struct ProcreateCheckbox: View {
    let isChecked: Bool
    var isOnBlue: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isOnBlue ? Color.white.opacity(0.85) : Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 17, height: 17)
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isOnBlue ? .white : Color.white.opacity(0.9))
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StudioButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundColor(isEnabled ? StudioTheme.textPrimary : StudioTheme.textDisabled)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? StudioTheme.panelElevated : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        configuration.isPressed ? StudioTheme.hairlineStrong : Color.clear,
                        lineWidth: 1
                    )
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A compact labelled slider used for brush size / opacity.
struct StudioSlider: View {
    let icon: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(StudioTheme.textSecondary)
                .frame(width: 16)
            Slider(value: $value, in: range)
                .controlSize(.mini)
            Text(String(format: "%0.f", value * 100))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)
                .frame(width: 24)
        }
    }
}

// MARK: - Color conversion helpers

extension BixelColor {
    /// HSV where h ∈ 0..360, s ∈ 0..1, v ∈ 0..1.
    var hsv: (h: Double, s: Double, v: Double) {
        let r = Double(self.r) / 255
        let g = Double(self.g) / 255
        let b = Double(self.b) / 255
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        var h: Double = 0
        if delta > 0 {
            if maxV == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
        }
        if h < 0 { h += 360 }
        let s = maxV == 0 ? 0 : delta / maxV
        return (h, s, maxV)
    }

    init(h: Double, s: Double, v: Double) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var r: Double = 0, g: Double = 0, b: Double = 0
        switch h {
        case 0..<60: (r, g, b) = (c, x, 0)
        case 60..<120: (r, g, b) = (x, c, 0)
        case 120..<180: (r, g, b) = (0, c, x)
        case 180..<240: (r, g, b) = (0, x, c)
        case 240..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self = BixelColor(
            r: UInt8((r + m) * 255),
            g: UInt8((g + m) * 255),
            b: UInt8((b + m) * 255),
            a: 255
        )
    }
}
