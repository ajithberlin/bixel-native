// ColorNaming.swift
//
// Natural language color naming system for Bixel Studio in the spirit of Procreate.
// Analyzes Hue, Saturation, and Lightness to produce human-readable names
// like "Dark Grayish Purple", "Vivid Blue", "Muted Olive Green", "Pure White", etc.

import Foundation

public enum ColorNaming {
    public static func describe(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> String {
        if a == 0 { return "Transparent" }

        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0

        let maxV = max(rf, gf, bf)
        let minV = min(rf, gf, bf)
        let delta = maxV - minV

        let lightness = (maxV + minV) / 2.0
        let saturation: Double
        if delta == 0 {
            saturation = 0
        } else if lightness < 0.5 {
            saturation = delta / (maxV + minV)
        } else {
            saturation = delta / (2.0 - maxV - minV)
        }

        // Grayscale / Neutral checks
        if lightness < 0.05 {
            return "Black"
        }
        if lightness < 0.12 && saturation < 0.15 {
            return "Near Black"
        }
        if lightness > 0.96 && saturation < 0.08 {
            return "Pure White"
        }
        if lightness > 0.90 && saturation < 0.12 {
            return "Off-White"
        }
        if saturation < 0.08 {
            if lightness < 0.22 { return "Charcoal" }
            if lightness < 0.40 { return "Dark Gray" }
            if lightness < 0.60 { return "Medium Gray" }
            if lightness < 0.78 { return "Light Gray" }
            return "Very Light Gray"
        }

        // Hue calculation (0..<360)
        var hue: Double = 0
        if delta > 0 {
            if maxV == rf {
                hue = 60 * ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == gf {
                hue = 60 * ((bf - rf) / delta + 2)
            } else {
                hue = 60 * ((rf - gf) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }

        // Earthy tones override (Browns, Tans, Olives)
        if (15..<48).contains(hue) && (0.12...0.48).contains(lightness) && saturation >= 0.20 {
            if lightness < 0.25 { return "Dark Brown" }
            if saturation < 0.40 { return "Muted Brown" }
            return "Brown"
        }
        if (15..<50).contains(hue) && (0.60...0.85).contains(lightness) && (0.15...0.48).contains(saturation) {
            return "Tan"
        }
        if (48..<80).contains(hue) && (0.15...0.45).contains(lightness) && saturation >= 0.20 {
            if lightness < 0.28 { return "Dark Olive Green" }
            return "Olive Green"
        }

        // Base Hue Name
        let baseHue: String
        switch hue {
        case 0..<15: baseHue = "Red"
        case 15..<35: baseHue = "Red-Orange"
        case 35..<52: baseHue = "Orange"
        case 52..<68: baseHue = "Yellow-Orange"
        case 68..<82: baseHue = "Yellow"
        case 82..<105: baseHue = "Yellow-Green"
        case 105..<148: baseHue = "Green"
        case 148..<175: baseHue = "Teal"
        case 175..<200: baseHue = "Cyan"
        case 200..<222: baseHue = "Sky Blue"
        case 222..<248: baseHue = "Blue"
        case 248..<268: baseHue = "Indigo"
        case 268..<295: baseHue = "Purple"
        case 295..<320: baseHue = "Violet"
        case 320..<342: baseHue = "Magenta"
        case 342..<355: baseHue = "Pink"
        default: baseHue = "Red"
        }

        // Tone & Modifier
        let modifier: String
        if lightness < 0.22 {
            modifier = "Very Dark"
        } else if lightness < 0.38 {
            if saturation < 0.35 {
                modifier = "Dark Grayish"
            } else {
                modifier = "Dark"
            }
        } else if lightness > 0.80 {
            if saturation < 0.30 {
                modifier = "Pale"
            } else {
                modifier = "Light"
            }
        } else if lightness > 0.65 {
            if saturation < 0.30 {
                modifier = "Soft"
            } else if saturation > 0.80 {
                modifier = "Bright"
            } else {
                modifier = "Light"
            }
        } else {
            // Mid-range lightness (0.38...0.65)
            if saturation < 0.25 {
                modifier = "Grayish"
            } else if saturation < 0.52 {
                modifier = "Muted"
            } else if saturation > 0.85 {
                modifier = "Vivid"
            } else {
                modifier = ""
            }
        }

        if modifier.isEmpty {
            return baseHue
        }
        return "\(modifier) \(baseHue)"
    }
}

extension BixelColor {
    /// Human-readable color name matching Procreate's color descriptions
    public var descriptiveName: String {
        ColorNaming.describe(r: r, g: g, b: b, a: a)
    }
}
