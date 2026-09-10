import Foundation

/// Per-frame timeline metadata emitted by the AI skills (mirrors the Rust
/// `FrameMeta`).
struct SheetFrameMeta: Codable, Hashable {
    var duration_ms: Int?
    var tag: String?
}

/// Sprite-sheet import helpers: pairing an image with its JSON manifest and
/// synthesising a grid manifest when only an image is available. The manifest
/// string is handed verbatim to the Rust `SheetPlan` planner, which owns the
/// actual shape detection (Bixel export / atlas / grid).
enum SheetImport {
    static let imageExtensions = ["png", "jpg", "jpeg", "webp"]

    /// Normalize arbitrary JSON data into a manifest string the Rust planner
    /// accepts, or nil when it is not a JSON object.
    static func manifest(fromJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: normalized, encoding: .utf8) else { return nil }
        return text
    }

    /// Build a uniform grid manifest (no sidecar JSON needed).
    static func gridManifest(cellWidth: Int, cellHeight: Int, cols: Int = 0, rows: Int = 0,
                             margin: Int = 0, spacing: Int = 0, durationMs: Int = 100) -> String {
        var object: [String: Any] = [
            "cell_width": max(1, cellWidth),
            "cell_height": max(1, cellHeight),
            "duration_ms": max(1, durationMs),
        ]
        if cols > 0 { object["cols"] = cols }
        if rows > 0 { object["rows"] = rows }
        if margin > 0 { object["margin"] = margin }
        if spacing > 0 { object["spacing"] = spacing }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// A `.json` manifest sharing the image's basename, if one exists.
    static func sidecarManifest(for imageURL: URL) -> String? {
        let jsonURL = imageURL.deletingPathExtension().appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL) else { return nil }
        return manifest(fromJSON: data)
    }

    /// The image next to a picked `.json` manifest (same basename).
    static func siblingImage(for jsonURL: URL) -> URL? {
        let stem = jsonURL.deletingPathExtension()
        for ext in imageExtensions {
            let candidate = stem.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
