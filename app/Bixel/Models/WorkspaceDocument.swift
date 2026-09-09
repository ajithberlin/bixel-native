import Foundation

enum AssetKind: String, Codable, CaseIterable, Identifiable {
    case sprite, animation, spritesheet, tileset, map, image
    var id: String { rawValue }
    var title: String { rawValue == "spritesheet" ? "Sprite sheet" : rawValue.capitalized }
    var usesCells: Bool { self == .map || self == .tileset || self == .spritesheet }
    var symbol: String {
        switch self {
        case .sprite: return "person.crop.square"
        case .animation: return "film"
        case .spritesheet: return "square.grid.3x3"
        case .tileset: return "square.grid.2x2"
        case .map: return "map"
        case .image: return "photo"
        }
    }
}

struct WorkspaceDocument: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var kind: AssetKind
    /// Pixels for images/sprites; cells for maps, tilesets and sheets.
    var width: Int
    var height: Int
    var cellWidth: Int = 16
    var cellHeight: Int = 16
    var sourcePath: String? = nil
    var pixelWidth: Int { safeProduct(width, kind.usesCells ? cellWidth : 1) }
    var pixelHeight: Int { safeProduct(height, kind.usesCells ? cellHeight : 1) }
    var path: String { "documents/\(id).json" }
    var summary: String {
        kind.usesCells ? "\(width) × \(height) cells · \(cellWidth) × \(cellHeight) px each" : "\(pixelWidth) × \(pixelHeight) px"
    }
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this document a name." }
        if width < 1 || height < 1 || cellWidth < 1 || cellHeight < 1 || pixelWidth < 1 || pixelHeight < 1 || pixelWidth > 4096 || pixelHeight > 4096 {
            return "Use positive sizes up to 4096 × 4096 total pixels."
        }
        if !id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) || id.isEmpty { return "Invalid document identifier." }
        return nil
    }
    private func safeProduct(_ a: Int, _ b: Int) -> Int {
        let result = a.multipliedReportingOverflow(by: b)
        return result.overflow ? 0 : result.partialValue
    }
}

struct WorkspaceCatalog: Codable {
    var schema = 1
    var documents: [WorkspaceDocument] = []
    var activeDocumentID: String? = nil
    var style = ""
}

struct ProjectAssetFile: Decodable, Identifiable {
    let path: String
    let name: String
    let bytes: Int
    var id: String { path }
    var isImage: Bool { ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    var isSource: Bool { name.contains("_source") }
}
