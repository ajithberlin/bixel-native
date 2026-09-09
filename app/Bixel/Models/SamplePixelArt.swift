// SamplePixelArt.swift
//
// Starter pixel artwork and presets for the Bixel Studio Home Gallery:
// generates authentic pixel art bitmaps for Slime Sprite, Character Walk,
// Forest Tiles, Tokyo Street, UI Icons, NPC Portraits, and templates.

import SwiftUI
import AppKit

enum SamplePixelArt {
    struct TemplateItem: Identifiable {
        let id: String
        let name: String
        let description: String
        let kind: AssetKind
        let width: Int
        let height: Int
        let badge: String
    }

    static let templates: [TemplateItem] = [
        TemplateItem(
            id: "pixel_village",
            name: "Pixel Village",
            description: "A cozy village tileset to kickstart your world.",
            kind: .tileset,
            width: 128,
            height: 128,
            badge: "Tileset"
        ),
        TemplateItem(
            id: "char_base",
            name: "Character Base",
            description: "A versatile character template with animations.",
            kind: .animation,
            width: 64,
            height: 64,
            badge: "Animation"
        ),
        TemplateItem(
            id: "rpg_icons",
            name: "RPG Icons",
            description: "Essential UI icons for your next adventure.",
            kind: .sprite,
            width: 32,
            height: 32,
            badge: "Sprite"
        )
    ]

    struct ActivityItem: Identifiable {
        let id = UUID()
        let projectName: String
        let action: String
        let timeAgo: String
        let iconName: String
    }

    static let sampleActivities: [ActivityItem] = [
        ActivityItem(projectName: "Slime Sprite", action: "Edited Slime Sprite", timeAgo: "2 hours ago", iconName: "slime"),
        ActivityItem(projectName: "Forest Tiles", action: "Created Forest Tiles", timeAgo: "1 day ago", iconName: "forest"),
        ActivityItem(projectName: "Tokyo Street", action: "Edited Tokyo Street", timeAgo: "4 days ago", iconName: "tokyo")
    ]

    // MARK: - Pixel Buffer Generation

    static func generateSampleData(for name: String, width: Int, height: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: max(1, width * height * 4))
        let lower = name.lowercased()

        if lower.contains("slime") {
            drawSlime(into: &buf, w: width, h: height)
        } else if lower.contains("character") || lower.contains("walk") {
            drawCharacter(into: &buf, w: width, h: height)
        } else if lower.contains("forest") || lower.contains("village") {
            drawForest(into: &buf, w: width, h: height)
        } else if lower.contains("tokyo") || lower.contains("street") {
            drawTokyo(into: &buf, w: width, h: height)
        } else if lower.contains("icon") || lower.contains("rpg") {
            drawUIIcons(into: &buf, w: width, h: height)
        } else if lower.contains("portrait") || lower.contains("npc") {
            drawPortrait(into: &buf, w: width, h: height)
        } else {
            drawDefaultGrid(into: &buf, w: width, h: height)
        }

        return buf
    }

    // MARK: - Drawing Helpers

    private static func setPixel(_ buf: inout [UInt8], w: Int, h: Int, x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        guard x >= 0, x < w, y >= 0, y < h else { return }
        let idx = (y * w + x) * 4
        buf[idx] = r
        buf[idx + 1] = g
        buf[idx + 2] = b
        buf[idx + 3] = a
    }

    private static func fillRect(_ buf: inout [UInt8], w: Int, h: Int, rect: CGRect, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        let x0 = max(0, Int(rect.minX))
        let x1 = min(w - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY))
        let y1 = min(h - 1, Int(rect.maxY))
        for y in y0...y1 {
            for x in x0...x1 {
                setPixel(&buf, w: w, h: h, x: x, y: y, r: r, g: g, b: b, a: a)
            }
        }
    }

    // 1. Slime Sprite (Cute vibrant green droplet with big shiny eyes)
    private static func drawSlime(into buf: inout [UInt8], w: Int, h: Int) {
        let cx = w / 2
        let cy = h / 2 + 2
        let rx = w * 3 / 8
        let ry = h * 3 / 8
        let rx2 = Double(rx * rx)
        let ry2 = Double(ry * ry)

        // Body outline & fill
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x - cx)
                let dy = Double(y - cy)
                // Droplet formula: taper at the top
                let taper = 1.0 + Double(y - cy) * 0.04
                let taper2 = rx2 * taper * taper
                let d = (dx * dx) / taper2 + (dy * dy) / ry2
                if d <= 1.05 {
                    if d > 0.88 {
                        // Dark green outline
                        setPixel(&buf, w: w, h: h, x: x, y: y, r: 42, g: 110, b: 35)
                    } else if y < cy - 2 && x < cx {
                        // Highlight
                        setPixel(&buf, w: w, h: h, x: x, y: y, r: 180, g: 255, b: 140)
                    } else {
                        // Main body lime green
                        setPixel(&buf, w: w, h: h, x: x, y: y, r: 133, g: 224, b: 87)
                    }
                }
            }
        }

        // Cute big shiny eyes
        let eyeY = cy - 1
        let eyeLeftX = cx - max(2, w / 7)
        let eyeRightX = cx + max(2, w / 7)

        for ex in [eyeLeftX, eyeRightX] {
            fillRect(&buf, w: w, h: h, rect: CGRect(x: ex - 1, y: eyeY - 2, width: 3, height: 4), r: 24, g: 48, b: 20)
            // White glint
            setPixel(&buf, w: w, h: h, x: ex, y: eyeY - 2, r: 255, g: 255, b: 255)
        }

        // Blush cheeks
        setPixel(&buf, w: w, h: h, x: eyeLeftX - 3, y: eyeY + 1, r: 255, g: 140, b: 160)
        setPixel(&buf, w: w, h: h, x: eyeRightX + 3, y: eyeY + 1, r: 255, g: 140, b: 160)

        // Cute mouth
        setPixel(&buf, w: w, h: h, x: cx, y: eyeY + 2, r: 24, g: 48, b: 20)
    }

    // 2. Character Walk (Pixel hero with blue jacket, brown hair)
    private static func drawCharacter(into buf: inout [UInt8], w: Int, h: Int) {
        let cx = w / 2
        let cy = h / 2

        // Hair
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 6, y: cy - 14, width: 12, height: 7), r: 120, g: 70, b: 40)
        setPixel(&buf, w: w, h: h, x: cx - 7, y: cy - 11, r: 120, g: 70, b: 40)
        setPixel(&buf, w: w, h: h, x: cx + 6, y: cy - 11, r: 120, g: 70, b: 40)

        // Face / Skin
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 5, y: cy - 8, width: 10, height: 6), r: 255, g: 210, b: 170)
        // Eyes
        setPixel(&buf, w: w, h: h, x: cx - 3, y: cy - 6, r: 40, g: 30, b: 30)
        setPixel(&buf, w: w, h: h, x: cx + 2, y: cy - 6, r: 40, g: 30, b: 30)

        // Blue jacket
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 6, y: cy - 2, width: 12, height: 8), r: 60, g: 110, b: 200)
        // Shirt inside
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 6), r: 230, g: 140, b: 80)

        // Pants
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 5, y: cy + 6, width: 10, height: 6), r: 50, g: 60, b: 90)
        // Boots
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 6, y: cy + 12, width: 4, height: 3), r: 110, g: 65, b: 40)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx + 2, y: cy + 12, width: 4, height: 3), r: 110, g: 65, b: 40)
    }

    // 3. Forest Tiles (Grass, tree, stone tileset)
    private static func drawForest(into buf: inout [UInt8], w: Int, h: Int) {
        // Upper: Tree crown
        fillRect(&buf, w: w, h: h, rect: CGRect(x: 0, y: 0, width: w, height: h * 2 / 5), r: 40, g: 130, b: 60)
        for y in 0..<(h * 2 / 5) {
            for x in 0..<w {
                if (x * 7 + y * 13) % 9 == 0 {
                    setPixel(&buf, w: w, h: h, x: x, y: y, r: 70, g: 180, b: 85)
                } else if (x + y) % 8 == 0 {
                    setPixel(&buf, w: w, h: h, x: x, y: y, r: 25, g: 90, b: 40)
                }
            }
        }

        // Mid: Green Grass ground
        fillRect(&buf, w: w, h: h, rect: CGRect(x: 0, y: h * 2 / 5, width: w, height: h / 5), r: 85, g: 165, b: 65)
        for x in 0..<w {
            setPixel(&buf, w: w, h: h, x: x, y: h * 2 / 5, r: 125, g: 215, b: 90)
        }

        // Lower: Dirt & Stones
        fillRect(&buf, w: w, h: h, rect: CGRect(x: 0, y: h * 3 / 5, width: w, height: h * 2 / 5), r: 110, g: 75, b: 50)
        for y in (h * 3 / 5)..<h {
            for x in 0..<w {
                if (x * 11 + y * 5) % 13 == 0 {
                    setPixel(&buf, w: w, h: h, x: x, y: y, r: 145, g: 105, b: 70)
                } else if (x * 3 + y * 7) % 11 == 0 {
                    setPixel(&buf, w: w, h: h, x: x, y: y, r: 75, g: 50, b: 35)
                }
            }
        }
    }

    // 4. Tokyo Street (Cyberpunk city neon street)
    private static func drawTokyo(into buf: inout [UInt8], w: Int, h: Int) {
        // Night sky gradient
        for y in 0..<h {
            let sky = UInt8(max(15, 45 - y * 45 / h))
            for x in 0..<w {
                setPixel(&buf, w: w, h: h, x: x, y: y, r: sky + 10, g: 15, b: sky + 35)
            }
        }
        // Neon building silhouettes
        fillRect(&buf, w: w, h: h, rect: CGRect(x: 0, y: h / 4, width: w / 3, height: h), r: 25, g: 25, b: 45)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: w * 2 / 3, y: h / 5, width: w / 3, height: h), r: 28, g: 25, b: 50)

        // Glowing neon signs (Magenta & Cyan)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: w / 10, y: h / 3, width: 3, height: 16), r: 255, g: 45, b: 120)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: w * 8 / 10, y: h / 3, width: 4, height: 14), r: 50, g: 215, b: 255)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: w / 6, y: h / 2, width: 8, height: 3), r: 255, g: 190, b: 40)

        // Road with perspective reflections
        for y in (h * 3 / 5)..<h {
            for x in 0..<w {
                if (x + y * 2) % 12 == 0 {
                    setPixel(&buf, w: w, h: h, x: x, y: y, r: 80, g: 40, b: 90)
                } else {
                    setPixel(&buf, w: w, h: h, x: x, y: y, r: 30, g: 25, b: 40)
                }
            }
        }
    }

    // 5. UI Icons (Heart, Coin, Potion bottle, Sword)
    private static func drawUIIcons(into buf: inout [UInt8], w: Int, h: Int) {
        // 1. Red Pixel Heart (Top Left)
        let hx = w / 4 - 3
        let hy = h / 4 - 3
        fillRect(&buf, w: w, h: h, rect: CGRect(x: hx, y: hy + 1, width: 3, height: 3), r: 235, g: 50, b: 75)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: hx + 4, y: hy + 1, width: 3, height: 3), r: 235, g: 50, b: 75)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: hx + 1, y: hy + 3, width: 5, height: 3), r: 235, g: 50, b: 75)
        setPixel(&buf, w: w, h: h, x: hx + 3, y: hy + 6, r: 235, g: 50, b: 75)
        // Heart glint
        setPixel(&buf, w: w, h: h, x: hx + 1, y: hy + 2, r: 255, g: 170, b: 180)

        // 2. Gold Coin (Top Right)
        let cx = w * 3 / 4 - 2
        let cy = h / 4
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 2, y: cy - 2, width: 6, height: 6), r: 255, g: 195, b: 40)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 1, y: cy - 1, width: 4, height: 4), r: 255, g: 230, b: 110)
        setPixel(&buf, w: w, h: h, x: cx, y: cy, r: 210, g: 145, b: 20)

        // 3. Blue Potion (Bottom Left)
        let px = w / 4 - 2
        let py = h * 3 / 4 - 2
        fillRect(&buf, w: w, h: h, rect: CGRect(x: px, y: py - 2, width: 3, height: 2), r: 180, g: 140, b: 90) // Cork
        fillRect(&buf, w: w, h: h, rect: CGRect(x: px - 2, y: py, width: 7, height: 6), r: 80, g: 150, b: 255) // Bottle
        setPixel(&buf, w: w, h: h, x: px - 1, y: py + 1, r: 190, g: 225, b: 255) // Glint

        // 4. Pixel Sword (Bottom Right)
        let sx = w * 3 / 4
        let sy = h * 3 / 4
        for i in 0..<6 {
            setPixel(&buf, w: w, h: h, x: sx - i, y: sy + i, r: 215, g: 225, b: 235) // Blade
        }
        setPixel(&buf, w: w, h: h, x: sx - 4, y: sy + 4, r: 215, g: 165, b: 45) // Guard
        setPixel(&buf, w: w, h: h, x: sx - 6, y: sy + 6, r: 130, g: 85, b: 50)  // Hilt
    }

    // 6. NPC Portrait (Fantasy mage girl portrait)
    private static func drawPortrait(into buf: inout [UInt8], w: Int, h: Int) {
        let cx = w / 2
        let cy = h / 2

        // Ruby / Magenta hair
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 10, y: cy - 14, width: 20, height: 22), r: 195, g: 60, b: 95)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 12, y: cy - 8, width: 24, height: 16), r: 175, g: 50, b: 85)

        // Face
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 6, y: cy - 7, width: 12, height: 11), r: 255, g: 215, b: 185)

        // Big Anime Eyes (Sapphire blue)
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 5, y: cy - 4, width: 3, height: 4), r: 40, g: 90, b: 180)
        setPixel(&buf, w: w, h: h, x: cx - 4, y: cy - 4, r: 255, g: 255, b: 255) // Glint

        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx + 2, y: cy - 4, width: 3, height: 4), r: 40, g: 90, b: 180)
        setPixel(&buf, w: w, h: h, x: cx + 3, y: cy - 4, r: 255, g: 255, b: 255) // Glint

        // Cheeks
        setPixel(&buf, w: w, h: h, x: cx - 5, y: cy + 1, r: 255, g: 150, b: 160)
        setPixel(&buf, w: w, h: h, x: cx + 4, y: cy + 1, r: 255, g: 150, b: 160)

        // Clothing collar
        fillRect(&buf, w: w, h: h, rect: CGRect(x: cx - 8, y: cy + 6, width: 16, height: 8), r: 45, g: 40, b: 65)
        setPixel(&buf, w: w, h: h, x: cx, y: cy + 8, r: 240, g: 200, b: 80) // Gold brooch
    }

    private static func drawDefaultGrid(into buf: inout [UInt8], w: Int, h: Int) {
        for y in 0..<h {
            for x in 0..<w {
                let c: UInt8 = ((x / 4) + (y / 4)) % 2 == 0 ? 45 : 35
                setPixel(&buf, w: w, h: h, x: x, y: y, r: c, g: c, b: c + 8)
            }
        }
    }

    // MARK: - CGImage Thumbnail Helper

    static func makePreviewImage(for name: String, width: Int = 48, height: Int = 48) -> CGImage? {
        let pixels = generateSampleData(for: name, width: width, height: height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
