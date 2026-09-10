import Foundation
import Compression
import ImageIO

enum TileMapImportError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Adapts an arbitrary Tiled 1.10 JSON map into the fixed-size, uncompressed
/// form `bixel-core` understands. External tilesets are copied through the
/// caller's asset writer, base64/zlib tile data is decoded, and infinite maps
/// (chunked layers) are flattened into the bounding box of their used cells.
enum TileMapImport {
    static func prepareMapJSON(
        _ data: Data,
        sourceDirectory: URL,
        persistImage: (Data, String) throws -> String
    ) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TileMapImportError.message("The imported map must contain a JSON object.")
        }
        try importTilesets(&root, sourceDirectory: sourceDirectory, persistImage: persistImage)
        try importLayers(&root)
        return try jsonString(root)
    }

    // MARK: - Tilesets

    private static func importTilesets(
        _ root: inout [String: Any],
        sourceDirectory: URL,
        persistImage: (Data, String) throws -> String
    ) throws {
        guard var tilesets = root["tilesets"] as? [[String: Any]] else { return }

        for index in tilesets.indices {
            var tileset = tilesets[index]

            // External `.tsx` tileset: load it and resolve its image relative to
            // the `.tsx` file (not the map), then inline it.
            if let source = tileset["source"] as? String, !source.isEmpty {
                let tsxURL = resolvedURL(source, relativeTo: sourceDirectory)
                guard let tsxData = try? Data(contentsOf: tsxURL),
                      var tsx = try? JSONSerialization.jsonObject(with: tsxData) as? [String: Any] else {
                    throw TileMapImportError.message("Could not read external tileset \"\(source)\" next to the imported map.")
                }
                if let firstgid = tileset["firstgid"] {
                    tsx["firstgid"] = firstgid
                }
                if let imagePath = tsx["image"] as? String, !imagePath.isEmpty {
                    let persisted = try persistTilesetImage(imagePath, relativeTo: tsxURL.deletingLastPathComponent(), persistImage: persistImage)
                    tsx["image"] = persisted.path
                    applyImageSize(&tsx, width: persisted.width, height: persisted.height)
                }
                tilesets[index] = tsx
                continue
            }

            guard let imagePath = tileset["image"] as? String, !imagePath.isEmpty else {
                if tileset["tiles"] != nil {
                    throw TileMapImportError.message("This tileset stores a separate image per tile, which Bixel cannot import yet. Export it as a single tileset image.")
                }
                continue
            }
            let persisted = try persistTilesetImage(imagePath, relativeTo: sourceDirectory, persistImage: persistImage)
            tileset["image"] = persisted.path
            applyImageSize(&tileset, width: persisted.width, height: persisted.height)
            tilesets[index] = tileset
        }
        root["tilesets"] = tilesets
    }

    private static func persistTilesetImage(
        _ path: String,
        relativeTo directory: URL,
        persistImage: (Data, String) throws -> String
    ) throws -> (path: String, width: Int, height: Int) {
        let url = resolvedURL(path, relativeTo: directory)
        guard let imageData = try? Data(contentsOf: url) else {
            throw TileMapImportError.message("Could not read tileset image \"\(path)\" next to the imported map.")
        }
        let name = url.lastPathComponent.isEmpty ? "tileset.png" : url.lastPathComponent
        let persisted = try persistImage(imageData, name)
        let size = imagePixelSize(imageData) ?? (0, 0)
        return (persisted, size.0, size.1)
    }

    /// Fill in tileset geometry the engine needs when Tiled omitted it.
    private static func applyImageSize(_ tileset: inout [String: Any], width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if intValue(tileset["imagewidth"]) <= 0 { tileset["imagewidth"] = width }
        if intValue(tileset["imageheight"]) <= 0 { tileset["imageheight"] = height }
        let tileWidth = max(1, intValue(tileset["tilewidth"]))
        let tileHeight = max(1, intValue(tileset["tileheight"]))
        let margin = intValue(tileset["margin"])
        let spacing = intValue(tileset["spacing"])
        let usableW = max(0, width - 2 * margin)
        let usableH = max(0, height - 2 * margin)
        let columns = max(1, (usableW + spacing) / (tileWidth + spacing))
        let rows = max(1, (usableH + spacing) / (tileHeight + spacing))
        if intValue(tileset["columns"]) <= 0 { tileset["columns"] = columns }
        if intValue(tileset["tilecount"]) <= 0 { tileset["tilecount"] = columns * rows }
    }

    private static func imagePixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    // MARK: - Layers

    private static func importLayers(_ root: inout [String: Any]) throws {
        guard var layers = root["layers"] as? [[String: Any]] else { return }
        let infinite = (root["infinite"] as? Bool) ?? false

        // Bounds of chunked (infinite) data across every tile layer.
        var minCellX = Int.max, minCellY = Int.max
        var maxCellX = Int.min, maxCellY = Int.min
        for layer in layers where (layer["type"] as? String) == "tilelayer" {
            guard let chunks = layer["chunks"] as? [[String: Any]] else { continue }
            for chunk in chunks {
                let cx = intValue(chunk["x"]), cy = intValue(chunk["y"])
                let cw = intValue(chunk["width"]), ch = intValue(chunk["height"])
                minCellX = min(minCellX, cx); minCellY = min(minCellY, cy)
                maxCellX = max(maxCellX, cx + cw); maxCellY = max(maxCellY, cy + ch)
            }
        }
        let hasChunks = maxCellX > minCellX && maxCellY > minCellY

        var mapWidth = intValue(root["width"])
        var mapHeight = intValue(root["height"])
        if hasChunks {
            mapWidth = maxCellX - minCellX
            mapHeight = maxCellY - minCellY
            minCellX = 0; minCellY = 0
        }
        guard mapWidth > 0, mapHeight > 0 else {
            throw TileMapImportError.message("The imported map has no usable dimensions.")
        }
        guard mapWidth <= 4096, mapHeight <= 4096 else {
            throw TileMapImportError.message("The imported map is \(mapWidth) × \(mapHeight) cells; the editor supports up to 4096 × 4096.")
        }

        let tileWidth = max(1, intValue(root["tilewidth"]))
        let tileHeight = max(1, intValue(root["tileheight"]))

        for index in layers.indices {
            let type = layers[index]["type"] as? String ?? ""
            if type != "tilelayer" {
                if infinite, type == "objectgroup" {
                    shiftObjects(&layers[index], dx: -minCellX, dy: -minCellY,
                                 tileWidth: tileWidth, tileHeight: tileHeight)
                }
                continue
            }

            let compression = layers[index]["compression"] as? String
            var grid = [UInt32](repeating: 0, count: mapWidth * mapHeight)

            if let chunks = layers[index]["chunks"] as? [[String: Any]] {
                for chunk in chunks {
                    let cx = intValue(chunk["x"]), cy = intValue(chunk["y"])
                    let cw = intValue(chunk["width"]), ch = intValue(chunk["height"])
                    let tiles = try decodeTileData(chunk["data"], compression: compression, expected: cw * ch)
                    blit(source: tiles, srcW: cw, srcH: ch, into: &grid, dstW: mapWidth, dstH: mapHeight,
                         ox: cx - minCellX, oy: cy - minCellY)
                }
            } else {
                let layerW = max(1, intValue(layers[index]["width"]))
                let layerH = max(1, intValue(layers[index]["height"]))
                let tiles = try decodeTileData(layers[index]["data"], compression: compression, expected: layerW * layerH)
                let startX = intValue(layers[index]["startx"]) - minCellX
                let startY = intValue(layers[index]["starty"]) - minCellY
                blit(source: tiles, srcW: layerW, srcH: layerH, into: &grid, dstW: mapWidth, dstH: mapHeight,
                     ox: startX, oy: startY)
            }

            layers[index]["data"] = grid.map { Int($0) }
            layers[index]["width"] = mapWidth
            layers[index]["height"] = mapHeight
            layers[index]["x"] = 0
            layers[index]["y"] = 0
            for key in ["chunks", "compression", "encoding", "startx", "starty"] {
                layers[index].removeValue(forKey: key)
            }
        }

        root["layers"] = layers
        root["width"] = mapWidth
        root["height"] = mapHeight
        root["infinite"] = false
    }

    private static func blit(
        source: [UInt32], srcW: Int, srcH: Int,
        into grid: inout [UInt32], dstW: Int, dstH: Int,
        ox: Int, oy: Int
    ) {
        guard srcW > 0, srcH > 0 else { return }
        for row in 0..<srcH {
            for col in 0..<srcW {
                let gx = ox + col, gy = oy + row
                guard gx >= 0, gy >= 0, gx < dstW, gy < dstH else { continue }
                let src = row * srcW + col
                guard src < source.count else { continue }
                grid[gy * dstW + gx] = source[src]
            }
        }
    }

    private static func shiftObjects(
        _ layer: inout [String: Any],
        dx: Int, dy: Int, tileWidth: Int, tileHeight: Int
    ) {
        guard dx != 0 || dy != 0,
              var objects = layer["objects"] as? [[String: Any]] else { return }
        for index in objects.indices {
            let x = doubleValue(objects[index]["x"]) - Double(dx * tileWidth)
            let y = doubleValue(objects[index]["y"]) - Double(dy * tileHeight)
            objects[index]["x"] = x
            objects[index]["y"] = y
        }
        layer["objects"] = objects
    }

    // MARK: - Tile data decoding

    /// Normalizes a Tiled layer/chunk `data` value to a little-endian GID array.
    private static func decodeTileData(_ raw: Any?, compression: String?, expected: Int) throws -> [UInt32] {
        guard let raw else { return [] }

        if let numbers = raw as? [Any] {
            return numbers.map { UInt32(truncatingIfNeeded: intValue($0)) }
        }
        guard let text = raw as? String else { return [] }

        // CSV (uncompressed text) is handled directly by bixel-core, but decode
        // here too so infinite chunks and mixed formats normalize uniformly.
        if text.contains(",") || text.contains("\n") || text.contains("\r") {
            return text
                .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == " " })
                .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        }

        guard let encoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TileMapImportError.message("The map's tile data is not valid base64.")
        }
        let bytes: Data
        if let compression, !compression.isEmpty {
            bytes = try decompress(encoded, algorithm: compression, expected: expected * 4)
        } else {
            bytes = encoded
        }

        let count = expected > 0 ? expected : bytes.count / 4
        var out = [UInt32](repeating: 0, count: count)
        let available = min(count, bytes.count / 4)
        bytes.withUnsafeBytes { raw in
            for i in 0..<available {
                let b0 = UInt32(raw[i * 4])
                let b1 = UInt32(raw[i * 4 + 1]) << 8
                let b2 = UInt32(raw[i * 4 + 2]) << 16
                let b3 = UInt32(raw[i * 4 + 3]) << 24
                out[i] = b0 | b1 | b2 | b3
            }
        }
        return out
    }

    private static func decompress(_ data: Data, algorithm: String, expected: Int) throws -> Data {
        let compression: compression_algorithm
        switch algorithm.lowercased() {
        case "zlib":
            compression = COMPRESSION_ZLIB
        case "gzip":
            throw TileMapImportError.message("Gzip-compressed tile data is not supported. Re-export the map with zlib or no compression.")
        default:
            throw TileMapImportError.message("Unsupported tile data compression \"\(algorithm)\".")
        }

        let capacity = max(expected, 1)
        var destination = [UInt8](repeating: 0, count: capacity)
        let written: Int = data.withUnsafeBytes { source in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return destination.withUnsafeMutableBytes { dest in
                guard let destBase = dest.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destBase, capacity, sourceBase, data.count, nil, compression)
            }
        }
        guard written > 0 else {
            throw TileMapImportError.message("Could not decompress the map's tile data.")
        }
        return Data(destination.prefix(written))
    }

    // MARK: - Helpers

    private static func resolvedURL(_ path: String, relativeTo directory: URL) -> URL {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") {
            return URL(fileURLWithPath: normalized).standardizedFileURL
        }
        return directory.appendingPathComponent(normalized).standardizedFileURL
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) ?? 0 }
        return 0
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
