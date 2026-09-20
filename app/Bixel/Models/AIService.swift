// AIService.swift
//
// Swift wrapper over the Rust AI engine (goose SDK → OpenRouter) plus small
// image helpers. Model-backed calls are blocking; run them off the main thread.

import Foundation
import CoreGraphics
import ImageIO
#if canImport(SafariServices) && canImport(UIKit)
import SafariServices
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Host bridge for OAuth browser interactions. On iOS/iPadOS, presents an
/// in-app SFSafariViewController without suspending the app process; on macOS,
/// opens the default system browser via NSWorkspace.
final class AIOAuthBridge: NSObject {
    static let shared = AIOAuthBridge()

    #if canImport(SafariServices) && canImport(UIKit) && !os(macOS)
    private weak var safariVC: SFSafariViewController?
    #endif

    func setup() {
        bixel_ai_set_open_url_callback({ (cStr, _) in
            guard let cStr else { return }
            let urlString = String(cString: cStr)
            AIOAuthBridge.shared.openURL(urlString)
        }, nil)
    }

    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            #if canImport(SafariServices) && canImport(UIKit) && !os(macOS)
            guard let topVC = Self.topViewController() else {
                UIApplication.shared.open(url)
                return
            }
            let safari = SFSafariViewController(url: url)
            safari.delegate = self
            self.safariVC = safari
            topVC.present(safari, animated: true)
            #elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    func dismissSafari() {
        DispatchQueue.main.async {
            #if canImport(SafariServices) && canImport(UIKit) && !os(macOS)
            if let safari = self.safariVC {
                safari.dismiss(animated: true)
                self.safariVC = nil
            }
            #endif
        }
    }

    #if canImport(UIKit) && !os(macOS)
    private static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }
            .first?.rootViewController
        if let nav = root as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = root?.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }
    #endif
}

#if canImport(SafariServices) && canImport(UIKit) && !os(macOS)
extension AIOAuthBridge: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        self.safariVC = nil
        AIService.cancelCodexOAuth()
    }
}
#endif

enum AIService {
    static func available() -> Bool {
        bixel_ai_available()
    }

    static func setup() {
        AIOAuthBridge.shared.setup()
    }

    // MARK: - Connection

    /// Per-role model readiness (`text`, `vision`, `image`).
    struct AIRoleReadiness {
        var model = ""
        var ready = false
        var reason = ""
    }

    /// Masked connection status (never contains a full credential).
    struct AIConnectionStatus {
        var connected = false
        var provider = "openrouter"
        var providerLabel = "OpenRouter"
        var key: String?
        var models: [String: String] = [:]
        var imageSource: String?
        var baseURL = "https://openrouter.ai/api/v1"
        var readiness: [String: AIRoleReadiness] = [:]
    }

    /// Image generation is available only when the provider connection and
    /// the image model role have both passed the readiness check.
    static func imageGenerationIsReady(_ status: AIConnectionStatus) -> Bool {
        status.connected && status.readiness["image"]?.ready == true
    }

    static func connectionStatus() -> AIConnectionStatus {
        guard let ptr = bixel_ai_connection_status() else { return AIConnectionStatus() }
        defer { bixel_string_free(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return AIConnectionStatus() }
        return decodeStatus(json)
    }

    /// Decode the masked connection-status JSON shared by the local FFI and the
    /// remote Mac host.
    static func decodeStatus(_ json: [String: Any]) -> AIConnectionStatus {
        var status = AIConnectionStatus()
        status.connected = json["connected"] as? Bool ?? false
        status.provider = json["provider"] as? String ?? "openrouter"
        status.providerLabel = json["provider_label"] as? String ?? status.provider
        status.key = json["key"] as? String
        status.models = json["models"] as? [String: String] ?? [:]
        status.imageSource = json["image_source"] as? String
        status.baseURL = json["base_url"] as? String ?? status.baseURL
        if let readiness = json["readiness"] as? [String: Any] {
            for (role, value) in readiness {
                guard let roleJSON = value as? [String: Any] else { continue }
                status.readiness[role] = AIRoleReadiness(
                    model: roleJSON["model"] as? String ?? "",
                    ready: roleJSON["ready"] as? Bool ?? false,
                    reason: roleJSON["reason"] as? String ?? ""
                )
            }
        }
        return status
    }

    /// Connect the assistant. Keys are write-only (stored in the system
    /// secret store); returns nil on success or an error message.
    static func connect(provider: String, apiKey: String, imageAPIKey: String,
                        textModel: String, visionModel: String, imageModel: String) -> String? {
        let normalizedProvider = (provider == "openrouter" || provider == "open_router") ? "open_router" : provider
        var cfg: [String: Any] = [
            "provider": normalizedProvider,
            "models": ["text": textModel, "vision": visionModel, "image": imageModel],
            "validate": true,
        ]
        if !apiKey.isEmpty { cfg["api_key"] = apiKey }
        if !imageAPIKey.isEmpty { cfg["image_api_key"] = imageAPIKey }
        guard let data = try? JSONSerialization.data(withJSONObject: cfg),
              let json = String(data: data, encoding: .utf8) else {
            return "Could not encode the connection config."
        }
        guard let errorPtr = bixel_ai_connect(json) else { return nil }
        defer { bixel_string_free(errorPtr) }
        return String(cString: errorPtr)
    }

    static func disconnect() {
        bixel_ai_disconnect()
    }

    /// Run the ChatGPT (Codex) browser sign-in. Returns nil on success.
    static func startCodexOAuth() -> String? {
        AIOAuthBridge.shared.setup()
        guard let errorPtr = bixel_ai_start_codex_oauth() else { return nil }
        defer { bixel_string_free(errorPtr) }
        return String(cString: errorPtr)
    }

    /// Abort an in-flight ChatGPT sign-in so it can be retried immediately.
    static func cancelCodexOAuth() {
        bixel_ai_cancel_codex_oauth()
    }

    struct AIModelOption: Identifiable, Hashable {
        let id: String
        let label: String
        let capabilities: Set<String>
        let recommended: Bool

        var capabilitySummary: String {
            [capabilities.contains("chat") ? "Chat" : nil,
             capabilities.contains("vision") ? "Vision" : nil,
             capabilities.contains("image") ? "Image" : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    /// A provider-scoped model catalog. Capabilities come from Goose/provider
    /// metadata, not from a stale global image-model default.
    struct AIModelCatalog {
        var models: [AIModelOption] = []
        var defaultModel: String?
    }

    /// Selectable model ids for a provider (`openrouter` / `chatgpt_codex`).
    static func listModels(provider: String) -> AIModelCatalog {
        guard let ptr = bixel_ai_list_models(provider) else { return AIModelCatalog() }
        defer { bixel_string_free(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil else { return AIModelCatalog() }
        let structured = (json["model_options"] as? [[String: Any]] ?? []).compactMap { value -> AIModelOption? in
            guard let id = value["id"] as? String, !id.isEmpty else { return nil }
            let label = value["label"] as? String ?? id
            let capabilities = Set(value["capabilities"] as? [String] ?? [])
            return AIModelOption(id: id, label: label, capabilities: capabilities,
                                 recommended: value["recommended"] as? Bool ?? false)
        }
        let models = structured.isEmpty
            ? (json["models"] as? [String] ?? []).map {
                AIModelOption(id: $0, label: $0, capabilities: ["chat"], recommended: $0 == (json["default"] as? String))
            }
            : structured
        return AIModelCatalog(models: models, defaultModel: json["default"] as? String)
    }

    static func listSkills() -> [SkillInfo] {
        let ptr = bixel_ai_list_skills()
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SkillInfo].self, from: data)) ?? []
    }

    // MARK: - App settings (skills, MCP, paths)

    /// An installed `SKILL.md` package discovered by goose, with app-level
    /// enablement. `base` may be empty for global skills only.
    struct InstalledSkillInfo: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let description: String
        let source: String
        let path: String
        let global: Bool
        let enabled: Bool
    }

    static func listInstalledSkills(base: String) -> [InstalledSkillInfo] {
        let ptr = base.withCString { bixel_ai_list_installed_skills($0) }
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([InstalledSkillInfo].self, from: data)) ?? []
    }

    /// Persist a skill's enabled state. Returns nil on success or an error.
    static func setSkillEnabled(name: String, enabled: Bool) -> String? {
        guard let ptr = name.withCString({ bixel_ai_set_skill_enabled($0, enabled) }) else { return nil }
        defer { bixel_string_free(ptr) }
        return String(cString: ptr)
    }

    /// A configured goose MCP extension. Credential values are never included.
    struct MCPExtensionInfo: Decodable, Identifiable, Hashable {
        let key: String
        let name: String
        let type: String
        let description: String
        let enabled: Bool
        let display_name: String?
        let command: String?
        let args: [String]
        let uri: String?
        let timeout: UInt64?
        let env_keys: [String]
        let bundled: Bool

        var id: String { key }

        var transportLabel: String {
            switch type {
            case "stdio": return "stdio"
            case "streamable_http": return "HTTP"
            case "builtin": return "Built-in"
            case "platform": return "Platform"
            default: return type
            }
        }

        var summary: String {
            if let command, !command.isEmpty {
                return ([command] + args).joined(separator: " ")
            }
            if let uri, !uri.isEmpty { return uri }
            return description
        }
    }

    static func listMCP() -> [MCPExtensionInfo] {
        let ptr = bixel_ai_list_mcp()
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([MCPExtensionInfo].self, from: data)) ?? []
    }

    /// Create or update an MCP extension. Returns nil on success or an error.
    static func saveMCP(_ spec: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: spec),
              let json = String(data: data, encoding: .utf8) else {
            return "Could not encode the MCP server."
        }
        guard let ptr = json.withCString({ bixel_ai_set_mcp($0) }) else { return nil }
        defer { bixel_string_free(ptr) }
        return String(cString: ptr)
    }

    static func removeMCP(key: String) -> String? {
        guard let ptr = key.withCString({ bixel_ai_remove_mcp($0) }) else { return nil }
        defer { bixel_string_free(ptr) }
        return String(cString: ptr)
    }

    static func setMCPEnabled(key: String, enabled: Bool) -> Bool {
        key.withCString { bixel_ai_set_mcp_enabled($0, enabled) }
    }

    /// App + goose storage locations for the About pane.
    struct AppPathsInfo: Decodable {
        let goose_root: String
        let goose_config: String
        let secrets: String
        let skills_dir: String
        let venv_dir: String
    }

    static func appPaths() -> AppPathsInfo? {
        let ptr = bixel_ai_app_paths()
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AppPathsInfo.self, from: data)
    }

    /// An installed skill slash-command discovered by goose.
    struct AgentCommandInfo: Decodable, Hashable {
        let name: String
        let description: String
        let source: String
        let inputHint: String?

        private enum CodingKeys: String, CodingKey {
            case name, description, source
            case inputHint = "input_hint"
        }
    }

    /// Installed skill commands for `base` (project/conversation workspace).
    static func listAgentCommands(base: String) -> [AgentCommandInfo] {
        let ptr = base.withCString { bixel_ai_list_commands($0) }
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AgentCommandInfo].self, from: data)) ?? []
    }

    /// Expand an invoked `/skill` into its loaded SKILL.md context, via goose's
    /// own resolver. Returns nil when it is not an installed skill.
    static func resolveCommand(name: String, args: String = "", base: String) -> String? {
        let ptr = name.withCString { namePtr in
            args.withCString { argsPtr in
                base.withCString { basePtr in
                    bixel_ai_resolve_command(namePtr, argsPtr, basePtr)
                }
            }
        }
        defer { bixel_string_free(ptr) }
        guard let ptr else { return nil }
        let text = String(cString: ptr)
        return text.isEmpty ? nil : text
    }

    /// Run any registered skill by id. `prompt` is forwarded to model-backed
    /// skills through the same JSON boundary as `params`; `png` is optional
    /// reference input. Returns decoded output or nil on failure.
    static func runSkill(id: String, params: [String: Any] = [:], prompt: String = "", png: Data? = nil) -> SkillRunResult? {
        var skillParams = params
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skillParams["prompt"] = prompt
        }
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: skillParams, options: []))
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
    static func chat(prompt: String, system: String = "You are Bixel, an AI assistant for a 2D design studio. Be concise and helpful.") -> String? {
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
        pngData(from: rgba, width: width, height: height)
    }

    static func pngToRGBA(_ data: Data) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              sourceWidth > 0, sourceHeight > 0, sourceWidth <= 4096, sourceHeight <= 4096,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width
        let h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (rgba, w, h)
    }

    /// Rasterizes a native-resolution source into a destination buffer using
    /// inverse nearest-neighbour sampling. The source remains untouched, so
    /// oversized images can be transformed before they are clipped on commit.
    static func rasterizeNativeImage(
        rgba: [UInt8], srcWidth: Int, srcHeight: Int,
        center: CGPoint, scaleX: CGFloat, scaleY: CGFloat,
        angle: CGFloat, dstWidth: Int, dstHeight: Int
    ) -> [UInt8] {
        guard dstWidth > 0, dstHeight > 0,
              dstHeight <= Int.max / 4,
              dstWidth <= Int.max / (dstHeight * 4) else { return [] }
        let destinationCount = dstWidth * dstHeight * 4
        var destination = [UInt8](repeating: 0, count: destinationCount)

        guard srcWidth > 0, srcHeight > 0,
              srcHeight <= Int.max / 4,
              srcWidth <= Int.max / (srcHeight * 4),
              rgba.count >= srcWidth * srcHeight * 4,
              center.x.isFinite, center.y.isFinite,
              scaleX.isFinite, scaleY.isFinite, angle.isFinite else {
            // Signal failure with an empty buffer so callers can surface an
            // error instead of silently committing a fully transparent frame.
            return []
        }

        let safeScaleX = max(0.0001, scaleX)
        let safeScaleY = max(0.0001, scaleY)
        let cosine = cos(angle)
        let sine = sin(angle)
        let sourceCenterX = CGFloat(srcWidth) / 2
        let sourceCenterY = CGFloat(srcHeight) / 2

        for y in 0..<dstHeight {
            let destinationY = CGFloat(y) + 0.5
            for x in 0..<dstWidth {
                let destinationX = CGFloat(x) + 0.5
                let offsetX = destinationX - center.x
                let offsetY = destinationY - center.y

                // Inverse-rotate into source-local space, then undo scale.
                let sourceLocalX = (offsetX * cosine + offsetY * sine) / safeScaleX
                let sourceLocalY = (-offsetX * sine + offsetY * cosine) / safeScaleY
                let mappedSourceX = sourceCenterX + sourceLocalX
                let mappedSourceY = sourceCenterY + sourceLocalY
                guard mappedSourceX >= 0, mappedSourceX < CGFloat(srcWidth),
                      mappedSourceY >= 0, mappedSourceY < CGFloat(srcHeight) else { continue }
                let sourceX = Int(floor(mappedSourceX))
                let sourceY = Int(floor(mappedSourceY))

                let sourceOffset = (sourceY * srcWidth + sourceX) * 4
                let destinationOffset = (y * dstWidth + x) * 4
                destination[destinationOffset..<(destinationOffset + 4)] =
                    rgba[sourceOffset..<(sourceOffset + 4)]
            }
        }
        return destination
    }

    /// Resamples an RGBA image to target dimensions using nearest-neighbor pixel art scaling.
    /// Preserves aspect ratio by centering on a transparent canvas if aspect ratios differ.
    static func fitToFrame(rgba: [UInt8], srcWidth: Int, srcHeight: Int, dstWidth: Int, dstHeight: Int) -> [UInt8] {
        guard srcWidth > 0, srcHeight > 0, dstWidth > 0, dstHeight > 0 else { return [] }
        if srcWidth == dstWidth && srcHeight == dstHeight { return rgba }

        var dst = [UInt8](repeating: 0, count: dstWidth * dstHeight * 4)

        let scaleX = Double(dstWidth) / Double(srcWidth)
        let scaleY = Double(dstHeight) / Double(srcHeight)
        let scale = min(scaleX, scaleY)

        let scaledW = max(1, Int(round(Double(srcWidth) * scale)))
        let scaledH = max(1, Int(round(Double(srcHeight) * scale)))

        let offsetX = (dstWidth - scaledW) / 2
        let offsetY = (dstHeight - scaledH) / 2

        for dy in 0..<scaledH {
            let sy = min(srcHeight - 1, (dy * srcHeight) / scaledH)
            let dstY = offsetY + dy
            guard dstY >= 0 && dstY < dstHeight else { continue }

            for dx in 0..<scaledW {
                let sx = min(srcWidth - 1, (dx * srcWidth) / scaledW)
                let dstX = offsetX + dx
                guard dstX >= 0 && dstX < dstWidth else { continue }

                let srcOffset = (sy * srcWidth + sx) * 4
                let dstOffset = (dstY * dstWidth + dstX) * 4

                dst[dstOffset] = rgba[srcOffset]
                dst[dstOffset + 1] = rgba[srcOffset + 1]
                dst[dstOffset + 2] = rgba[srcOffset + 2]
                dst[dstOffset + 3] = rgba[srcOffset + 3]
            }
        }
        return dst
    }

    /// Places an image at native resolution on a fixed-size canvas. Pixels
    /// outside the canvas are clipped; no resampling or color changes occur.
    static func placeNativeImage(rgba: [UInt8], srcWidth: Int, srcHeight: Int,
                                 dstWidth: Int, dstHeight: Int, x: Int, y: Int) -> [UInt8] {
        guard srcWidth > 0, srcHeight > 0, dstWidth > 0, dstHeight > 0,
              rgba.count >= srcWidth * srcHeight * 4 else { return [] }
        var dst = [UInt8](repeating: 0, count: dstWidth * dstHeight * 4)
        let srcX = max(0, -x)
        let srcY = max(0, -y)
        let dstX = max(0, x)
        let dstY = max(0, y)
        let copyWidth = min(srcWidth - srcX, dstWidth - dstX)
        let copyHeight = min(srcHeight - srcY, dstHeight - dstY)
        guard copyWidth > 0, copyHeight > 0 else { return dst }

        for row in 0..<copyHeight {
            let sourceStart = ((srcY + row) * srcWidth + srcX) * 4
            let destinationStart = ((dstY + row) * dstWidth + dstX) * 4
            let count = copyWidth * 4
            dst[destinationStart..<(destinationStart + count)] =
                rgba[sourceStart..<(sourceStart + count)]
        }
        return dst
    }

    /// Centers an image on the canvas while retaining native pixels. A larger
    /// source is center-cropped rather than silently reduced.
    static func centerNativeImage(rgba: [UInt8], srcWidth: Int, srcHeight: Int,
                                  dstWidth: Int, dstHeight: Int) -> [UInt8] {
        placeNativeImage(rgba: rgba, srcWidth: srcWidth, srcHeight: srcHeight,
                         dstWidth: dstWidth, dstHeight: dstHeight,
                         x: (dstWidth - srcWidth) / 2,
                         y: (dstHeight - srcHeight) / 2)
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
    let source_image: String?
    let image: String?
    let frames: [String]?
    /// Per-frame durations/tags aligned with `frames`.
    let frame_meta: [SheetFrameMeta]?
    /// Sheet manifest (JSON) describing the frames.
    let atlas: String?
    let error: String?
}

struct AssistantEvent: Decodable {
    let type: String
    var id: String?
    var parent_id: String?
    var title: String?
    var name: String?
    var delta: String?
    var arguments: String?
    var text: String?
    var success: Bool?
    var message: String?
    var png: String?
    var width: Int?
    var height: Int?
    var source: Bool?
    /// JSON array of per-frame `{duration_ms, tag}` for sheet artifacts.
    var frame_meta: String?
    /// Sheet manifest (JSON) describing the frames.
    var atlas: String?
    var input_tokens: Int?
    var output_tokens: Int?
}

final class AssistantCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

private final class AssistantStreamObserver {
    let cancellation: AssistantCancellation
    let receive: (AssistantEvent) -> Void
    init(_ cancellation: AssistantCancellation, _ receive: @escaping (AssistantEvent) -> Void) {
        self.cancellation = cancellation; self.receive = receive
    }
}

extension AIService {
    static func modelInfo() -> [String: String] {
        guard let ptr = bixel_ai_model_info() else { return [:] }
        defer { bixel_string_free(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json.compactMapValues { $0 as? String }
    }

    /// The Rust callback lends one complete event at a time; copy/decode before returning.
    static func streamChat(request: [String: Any], cancellation: AssistantCancellation, receive: @escaping (AssistantEvent) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: request), let json = String(data: data, encoding: .utf8) else {
            receive(AssistantEvent(type: "error", message: "Could not encode the request.")); return
        }
        let observer = Unmanaged.passRetained(AssistantStreamObserver(cancellation, receive))
        defer { observer.release() }
        _ = bixel_ai_chat_stream(json, { pointer, context in
            guard let pointer, let context else { return false }
            let observer = Unmanaged<AssistantStreamObserver>.fromOpaque(context).takeUnretainedValue()
            guard !observer.cancellation.isStopped else { return false }
            if let data = String(cString: pointer).data(using: .utf8), let event = try? JSONDecoder().decode(AssistantEvent.self, from: data) {
                observer.receive(event)
            }
            return !observer.cancellation.isStopped
        }, observer.toOpaque())
    }
}
