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

    // Accent (used sparingly, like Procreate's understated highlights)
    static let accent = Color(red: 0.42, green: 0.60, blue: 1.0)              // #6b99ff
    static let accentSoft = Color(red: 0.42, green: 0.60, blue: 1.0).opacity(0.16)

    static let canvasBackground = Color(red: 0.11, green: 0.113, blue: 0.125)

    // Misc
    static let cornerRadius: CGFloat = 10
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
