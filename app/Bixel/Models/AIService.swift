// AIService.swift
//
// Swift wrapper over the Rust AI engine (goose SDK → OpenRouter) plus small
// image helpers. Model-backed calls are blocking; run them off the main thread.

import Foundation
import AppKit
import CoreGraphics
import ImageIO

enum AIService {
    static func available() -> Bool {
        bixel_ai_available()
    }

    static func listSkills() -> [SkillInfo] {
        let ptr = bixel_ai_list_skills()
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SkillInfo].self, from: data)) ?? []
    }

    /// Text-to-image via the configured image model. Returns PNG bytes.
    static func generateArt(prompt: String) -> Data? {
        var len: UInt64 = 0
        let ptr = bixel_ai_generate_art(prompt, &len)
        guard let ptr, len > 0 else { return nil }
        defer { bixel_ai_free_buffer(ptr) }
        return Data(bytes: ptr, count: Int(len))
    }

    /// Image-to-image: predict the next animation frame. Returns PNG bytes.
    static func nextFrame(png: Data, prompt: String) -> Data? {
        var len: UInt64 = 0
        let ptr = png.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UnsafeMutablePointer<UInt8>? in
            bixel_ai_next_frame(
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt64(png.count),
                prompt,
                &len
            )
        }
        guard let ptr, len > 0 else { return nil }
        defer { bixel_ai_free_buffer(ptr) }
        return Data(bytes: ptr, count: Int(len))
    }

    /// Deterministic: reduce an RGBA buffer to `2^bits` colors.
    static func compress(_ rgba: [UInt8], width: Int, height: Int, bits: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rgba.count)
        rgba.withUnsafeBytes { inBuf in
            out.withUnsafeMutableBytes { outBuf in
                bixel_ai_compress_rgba(
                    inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    UInt32(width), UInt32(height), bits,
                    outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        return out
    }

    /// Deterministic: remove a near-uniform background.
    static func removeBackground(_ rgba: [UInt8], width: Int, height: Int, tolerance: Float) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rgba.count)
        rgba.withUnsafeBytes { inBuf in
            out.withUnsafeMutableBytes { outBuf in
                bixel_ai_remove_bg_rgba(
                    inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    UInt32(width), UInt32(height), tolerance,
                    outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        return out
    }

    // MARK: - image helpers

    static func rgbaToPNG(_ rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { return nil }
        rgba.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dest = rep.bitmapData {
                memcpy(dest, base, rgba.count)
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    static func pngToRGBA(_ data: Data) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width
        let h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (rgba, w, h)
    }
}

struct SkillInfo: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let category: String
    let model: String
    var params_schema: SkillParamsSchema?

    struct SkillParamsSchema: Decodable {
        // Only the top-level shape is needed for display.
    }
}
