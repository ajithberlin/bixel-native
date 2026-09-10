import Foundation

enum TileMapImportError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum TileMapImport {
    /// Copies embedded Tiled tileset images through the caller's project asset
    /// writer and rewrites their paths for the imported map document.
    static func prepareMapJSON(
        _ data: Data,
        sourceDirectory: URL,
        persistImage: (Data, String) throws -> String
    ) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TileMapImportError.message("The imported map must contain a JSON object.")
        }
        guard var tilesets = root["tilesets"] as? [[String: Any]] else {
            return try jsonString(root)
        }

        for index in tilesets.indices {
            guard let imagePath = tilesets[index]["image"] as? String, !imagePath.isEmpty else {
                if tilesets[index]["source"] != nil {
                    throw TileMapImportError.message("External .tsx tilesets are not supported. Export the Tiled map with embedded tilesets.")
                }
                continue
            }

            let sourceURL = resolvedImageURL(imagePath, relativeTo: sourceDirectory)
            let imageData: Data
            do {
                imageData = try Data(contentsOf: sourceURL)
            } catch {
                throw TileMapImportError.message("Could not read tileset image \"\(imagePath)\" next to the imported map.")
            }
            let name = sourceURL.lastPathComponent.isEmpty ? "tileset-\(index).png" : sourceURL.lastPathComponent
            tilesets[index]["image"] = try persistImage(imageData, name)
        }

        root["tilesets"] = tilesets
        return try jsonString(root)
    }

    private static func resolvedImageURL(_ path: String, relativeTo directory: URL) -> URL {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") {
            return URL(fileURLWithPath: normalized).standardizedFileURL
        }
        return directory.appendingPathComponent(normalized).standardizedFileURL
    }

    private static func jsonString(_ root: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw TileMapImportError.message("The imported map contains unsupported JSON values.")
        }
        let output = try JSONSerialization.data(withJSONObject: root)
        guard let text = String(data: output, encoding: .utf8) else {
            throw TileMapImportError.message("Could not encode the imported map.")
        }
        return text
    }
}
