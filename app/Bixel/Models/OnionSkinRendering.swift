// OnionSkinRendering.swift
//
// Shared, platform-independent onion-skin state used by the canvas renderers.

import Foundation
import CoreGraphics

/// A simple RGB color representation for onion-skin layer tinting.
struct OnionTintColor: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    /// Default distinct colors per layer distance:
    /// 1: Coral Red, 2: Amber Orange, 3: Electric Blue, 4: Purple, 5: Emerald Green
    static let defaultPalette: [OnionTintColor] = [
        OnionTintColor(r: 255, g: 69, b: 58),    // Layer 1: Coral Red
        OnionTintColor(r: 255, g: 159, b: 10),  // Layer 2: Amber Orange
        OnionTintColor(r: 0, g: 150, b: 255),   // Layer 3: Electric Blue
        OnionTintColor(r: 175, g: 82, b: 222),  // Layer 4: Purple
        OnionTintColor(r: 52, g: 199, b: 89),   // Layer 5: Emerald Green
    ]

    static func color(forDistance distance: Int) -> OnionTintColor {
        guard distance > 0 else { return defaultPalette[0] }
        let idx = (distance - 1) % defaultPalette.count
        return defaultPalette[idx]
    }
}

/// Specification for a single active onion-skin layer.
struct OnionLayerSpec: Equatable {
    let frameIndex: Int
    let distance: Int
    let opacity: Double
    let tintColor: OnionTintColor?
}

/// The frame selection and settings that determine the onion-skin layers.
/// Keeping this separate from CALayer/NSView/UIKit code makes invalidation
/// behavior testable on every platform.
struct OnionSkinRenderState: Equatable {
    let currentFrame: Int
    let frameCount: Int
    let enabled: Bool
    let frameCountToShow: Int
    let opacity: Double
    let colorize: Bool

    init(
        currentFrame: Int,
        frameCount: Int,
        enabled: Bool,
        frameCountToShow: Int,
        opacity: Double,
        colorize: Bool = true
    ) {
        self.currentFrame = currentFrame
        self.frameCount = frameCount
        self.enabled = enabled
        self.frameCountToShow = frameCountToShow
        self.opacity = opacity
        self.colorize = colorize
    }

    /// All active onion skin layers ordered from oldest to newest.
    var layers: [OnionLayerSpec] {
        guard enabled, frameCount > 1, currentFrame >= 0, currentFrame < frameCount else { return [] }
        var result: [OnionLayerSpec] = []
        let count = max(1, min(frameCountToShow, 5))
        for d in 1...count {
            let frameIdx = currentFrame - d
            guard frameIdx >= 0 else { break }
            let layerOpacity = opacity * pow(0.72, Double(d - 1))
            let tint = colorize ? OnionTintColor.color(forDistance: d) : nil
            result.append(OnionLayerSpec(frameIndex: frameIdx, distance: d, opacity: layerOpacity, tintColor: tint))
        }
        return result
    }

    var previousFrame: Int? {
        layers.first?.frameIndex
    }

    var olderPreviousFrame: Int? {
        layers.count > 1 ? layers[1].frameIndex : nil
    }

    func needsRedraw(comparedTo previous: OnionSkinRenderState?) -> Bool {
        self != previous
    }
}

/// Create a tinted CGImage from RGBA pixels while preserving luminance and alpha,
/// so black outlines remain distinct and shading is preserved.
func makeTintedCGImage(pixels: [UInt8], width: Int, height: Int, tint: OnionTintColor) -> CGImage? {
    guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
    var tinted = [UInt8](repeating: 0, count: width * height * 4)
    let tr = UInt32(tint.r)
    let tg = UInt32(tint.g)
    let tb = UInt32(tint.b)

    for i in stride(from: 0, to: width * height * 4, by: 4) {
        let a = pixels[i + 3]
        guard a > 0 else { continue }
        let r = UInt32(pixels[i])
        let g = UInt32(pixels[i + 1])
        let b = UInt32(pixels[i + 2])
        // Perceptual luminance calculation (ITU-R BT.601)
        let lum = (r * 299 + g * 587 + b * 114) / 1000
        // Modulate tint with luminance so outlines stay defined and highlights remain bright
        tinted[i] = UInt8(min(255, (tr * (lum + 100)) / 255))
        tinted[i + 1] = UInt8(min(255, (tg * (lum + 100)) / 255))
        tinted[i + 2] = UInt8(min(255, (tb * (lum + 100)) / 255))
        tinted[i + 3] = a
    }
    return makeCGImage(pixels: tinted, width: width, height: height)
}
