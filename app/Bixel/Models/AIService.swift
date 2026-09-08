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

    /// Run any registered skill by id. `params` is the skill's JSON params
    /// object; `png` is an optional input image. Returns decoded output (text,
    /// base64 image and/or frames) or nil on failure.
    static func runSkill(id: String, params: [String: Any] = [:], png: Data? = nil) -> SkillRunResult? {
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let ptr: UnsafeMutablePointer<CChar>? = id.withCString { idPtr in
            paramsJSON.withCString { paramsPtr in
                if let png {
                    return png.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UnsafeMutablePointer<CChar>? in
                        bixel_ai_run_skill(
                            idPtr, paramsPtr,
                            raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            UInt64(png.count)
                        )
                    }
                } else {
                    return bixel_ai_run_skill(idPtr, paramsPtr, nil, 0)
                }
            }
        }
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SkillRunResult.self, from: data)
    }

    /// Text chat with the configured text model. Returns the assistant's reply.
    static func chat(prompt: String, system: String = "You are Bixel, an AI assistant for a 2D pixel-art game studio. Be concise and helpful.") -> String? {
        guard let ptr = bixel_ai_chat(prompt, system) else { return nil }
        defer { bixel_string_free(ptr) }
        return String(cString: ptr)
    }

    /// Forget the current chat conversation (starts the next `chat` fresh).
    static func resetChat() {
        bixel_ai_chat_reset()
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

struct SkillRunResult: Decodable {
    let text: String?
    let image: String?
    let frames: [String]?
    let error: String?
}
