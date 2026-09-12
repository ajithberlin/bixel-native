// EditorBridge.swift
//
// Host side of the Take Control runtime. The Rust agent's `editor_read` /
// `editor_command` tools call the C callback installed here; this file resolves
// the live editor model, applies validated operations through the same methods
// the UI uses (so undo, layer caching and rendering stay correct), and returns a
// JSON response. It never lets the agent touch the Rust document handle behind
// the editor's back.

import Foundation

/// How the assistant's destructive editor changes are approved.
enum EditorApprovalMode: String {
    /// Destructive operations require the user's approval (`confirm: true`).
    case confirm
    /// Apply destructive operations without prompting.
    case autonomous

    static var current: EditorApprovalMode {
        EditorApprovalMode(rawValue: UserDefaults.standard.string(forKey: "bixel.editorApprovalMode") ?? "") ?? .confirm
    }
}

/// Error thrown while applying a single agent operation.
struct AgentOpError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Error text that keeps the domain and code for non-localized failures, so an
/// opaque "The operation couldn't be completed." stays diagnosable.
func agentErrorDescription(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain || ns.domain == NSOSStatusErrorDomain {
        return "\(error.localizedDescription) (\(ns.domain) \(ns.code))"
    }
    return error.localizedDescription
}

/// Trampoline installed into the Rust editor bridge. Runs on the agent's
/// background thread; hops to the main actor, waits with a bounded timeout, and
/// copies the JSON response into the caller-owned buffer.
private func bixelEditorBridgeTrampoline(
    _ request: UnsafePointer<CChar>?,
    _ response: UnsafeMutablePointer<CChar>?,
    _ capacity: UInt,
    _ context: UnsafeMutableRawPointer?
) -> Bool {
    guard let request, let response, capacity > 1 else { return false }
    let requestJSON = String(cString: request)
    let semaphore = DispatchSemaphore(value: 0)
    var payload: String?
    Task { @MainActor in
        payload = EditorBridge.shared.handle(requestJSON: requestJSON)
        semaphore.signal()
    }
    // The agent turn runs off the main thread; the editor responds promptly.
    if semaphore.wait(timeout: .now() + 30) == .timedOut { return false }
    guard let payload else { return false }
    let bytes = Array(payload.utf8) + [0]
    guard UInt(bytes.count) <= capacity else { return false }
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        memcpy(response, base, bytes.count)
    }
    return true
}

/// Main-actor bridge between the agent tools and the live editors.
@MainActor
final class EditorBridge {
    static let shared = EditorBridge()

    private weak var store: ProjectStore?

    private init() {}

    /// Bind the active project store and install the Rust callback. Safe to call
    /// more than once (e.g. on project switch).
    func attach(store: ProjectStore) {
        self.store = store
        bixel_ai_set_editor_bridge(bixelEditorBridgeTrampoline, nil)
    }

    /// Remove the callback (e.g. when no project is open).
    func detach() {
        store = nil
        bixel_ai_clear_editor_bridge()
    }

    // MARK: Request dispatch

    func handle(requestJSON: String) -> String {
        guard let data = requestJSON.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.error("invalid_request", "Malformed editor request.")
        }
        let command = request["command"] as? String ?? ""
        switch command {
        case "read":
            return handleRead(request)
        case "apply":
            return handleApply(request)
        default:
            return Self.error("unknown_command", "Unknown editor command '\(command)'.")
        }
    }

    private func handleRead(_ request: [String: Any]) -> String {
        guard let store else {
            return Self.error("no_project", "Open a project before reading the editor.")
        }
        let scope = request["scope"] as? String ?? "all"
        let includePreview = request["include_preview"] as? Bool ?? true
        let previewMax = min(2048, max(64, request["preview_max"] as? Int ?? 1024))
        let isMap = store.isMapActive

        var payload: [String: Any] = [
            "active_editor": isMap ? "map" : "document",
            "project": ["name": store.current?.name ?? ""],
        ]
        if isMap, scope != "document", let map = store.mapEditor {
            payload["map"] = map.agentState()
            if includePreview, let png = Self.downscaledPNG(
                rgba: map.compositeRGBA(), width: map.map.pixelWidth, height: map.map.pixelHeight, max: previewMax
            ) {
                payload["preview_png_base64"] = png.base64EncodedString()
            }
        } else if scope != "map" {
            let editor = store.editor
            payload["document"] = editor.agentState()
            if includePreview, let png = Self.downscaledPNG(
                rgba: editor.compositeCurrentFrame(), width: editor.width, height: editor.height, max: previewMax
            ) {
                payload["preview_png_base64"] = png.base64EncodedString()
            }
        }
        return Self.ok(payload)
    }

    private func handleApply(_ request: [String: Any]) -> String {
        guard let store else {
            return Self.error("no_project", "Open a project before changing the editor.")
        }
        let ops = request["ops"] as? [[String: Any]] ?? []
        guard !ops.isEmpty else {
            return Self.error("invalid_request", "editor_command needs at least one op.")
        }
        let confirm = request["confirm"] as? Bool ?? false
        let destructive = ops
            .compactMap { $0["op"] as? String }
            .filter { Self.destructiveOps.contains($0) }
        // Destructive ops need the user's approval, asserted by the agent via
        // confirm. Autonomous mode skips the requirement. This stays
        // agent-mediated so no modal AppKit session runs inside the bridge.
        if !destructive.isEmpty, !confirm, EditorApprovalMode.current == .confirm {
            return Self.error(
                "approval_required",
                "Destructive operations need the user's approval: \(destructive.joined(separator: ", ")). Ask the user, then call editor_command again with confirm=true."
            )
        }
        let workspace = (request["workspace"] as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        // Asset persistence is a project operation, not an editor one, so run
        // those ops here and delegate the rest to the active editor model.
        var results: [[String: Any]] = []
        var modelOps: [[String: Any]] = []
        for op in ops {
            if (op["op"] as? String) == "accept_asset" {
                results.append(acceptAsset(op, workspace: workspace))
            } else {
                modelOps.append(op)
            }
        }
        if !modelOps.isEmpty {
            if store.isMapActive, let map = store.mapEditor {
                results += map.applyAgentOps(modelOps, confirm: confirm, workspace: workspace)
            } else {
                results += store.editor.applyAgentOps(modelOps, confirm: confirm, workspace: workspace)
            }
        }
        return Self.ok(["results": results])
    }

    /// Copy a generated workspace file into the project's permanent `assets/`
    /// folder so it survives chat cleanup.
    private func acceptAsset(_ op: [String: Any], workspace: URL?) -> [String: Any] {
        guard let store, let projectRoot = store.projectRoot else {
            return ["op": "accept_asset", "ok": false, "error": "Open a project first."]
        }
        guard let path = op["path"] as? String, let source = Self.resolve(path, in: workspace) else {
            return ["op": "accept_asset", "ok": false, "error": "accept_asset needs a workspace-relative path."]
        }
        do {
            let data = try Data(contentsOf: source)
            let name = (op["name"] as? String) ?? source.lastPathComponent
            let destination = "assets/\(UUID().uuidString)-\(name)"
            try ProjectStorage.write(base: projectRoot, path: destination, data: data)
            store.refreshAssets()
            return ["op": "accept_asset", "ok": true, "path": destination]
        } catch {
            return ["op": "accept_asset", "ok": false, "error": agentErrorDescription(error)]
        }
    }

    /// Operations that remove, resize, or otherwise risk existing work.
    private static let destructiveOps: Set<String> = [
        "remove_layer", "remove_frame", "remove_tag", "resize",
        "map_remove_layer", "map_remove_object", "map_remove_tileset", "map_resize",
    ]

    // MARK: Helpers

    static func ok(_ data: [String: Any]) -> String {
        encode(["ok": true, "data": data])
    }

    static func error(_ code: String, _ message: String) -> String {
        encode(["ok": false, "code": code, "error": message])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"code":"encode_error","error":"Could not encode the editor response."}"#
        }
        return text
    }

    /// Resolve a workspace-relative path, refusing to escape the workspace.
    nonisolated static func resolve(_ relative: String, in workspace: URL?) -> URL? {
        guard let workspace, !relative.isEmpty else { return nil }
        let root = workspace.standardizedFileURL
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return candidate
    }

    /// Nearest-neighbor downscale to `max` on the longest side, then PNG.
    nonisolated static func downscaledPNG(rgba: [UInt8], width: Int, height: Int, max limit: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let longest = Swift.max(width, height)
        guard longest > limit else {
            return AIService.rgbaToPNG(rgba, width: width, height: height)
        }
        let scale = Double(limit) / Double(longest)
        let w = Swift.max(1, Int((Double(width) * scale).rounded()))
        let h = Swift.max(1, Int((Double(height) * scale).rounded()))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let sy = Swift.min(height - 1, y * height / h)
            for x in 0..<w {
                let sx = Swift.min(width - 1, x * width / w)
                let src = (sy * width + sx) * 4
                let dst = (y * w + x) * 4
                out[dst] = rgba[src]
                out[dst + 1] = rgba[src + 1]
                out[dst + 2] = rgba[src + 2]
                out[dst + 3] = rgba[src + 3]
            }
        }
        return AIService.rgbaToPNG(out, width: w, height: h)
    }
}
