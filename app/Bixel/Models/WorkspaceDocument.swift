import Foundation

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case map

    var id: String { rawValue }
    var title: String { self == .map ? "Map" : "Normal" }
    var symbol: String { self == .map ? "map" : "square.dashed" }
    var usesCells: Bool { self == .map }
    var supportsAnimationAssist: Bool { self == .normal }
}

struct WorkspaceDocument: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var mode: WorkspaceMode
    /// Pixels for normal documents; cells for map documents.
    var width: Int
    var height: Int
    var cellWidth: Int = 16
    var cellHeight: Int = 16
    var sourcePath: String? = nil
    var pixelWidth: Int { safeProduct(width, mode.usesCells ? cellWidth : 1) }
    var pixelHeight: Int { safeProduct(height, mode.usesCells ? cellHeight : 1) }
    var path: String { "documents/\(id).json" }
    var summary: String {
        mode.usesCells ? "\(width) × \(height) cells · \(cellWidth) × \(cellHeight) px each" : "\(pixelWidth) × \(pixelHeight) px"
    }
    var supportsAnimationAssist: Bool { mode.supportsAnimationAssist }

    init(id: String = UUID().uuidString, name: String, mode: WorkspaceMode = .normal,
         width: Int, height: Int, cellWidth: Int = 16, cellHeight: Int = 16,
         sourcePath: String? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.width = width
        self.height = height
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.sourcePath = sourcePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mode, kind, width, height, cellWidth, cellHeight, sourcePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        if let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) {
            mode = rawMode == WorkspaceMode.map.rawValue ? .map : .normal
        } else {
            let legacyKind = try container.decodeIfPresent(String.self, forKey: .kind)
            mode = legacyKind == WorkspaceMode.map.rawValue ? .map : .normal
        }
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        cellWidth = try container.decodeIfPresent(Int.self, forKey: .cellWidth) ?? 16
        cellHeight = try container.decodeIfPresent(Int.self, forKey: .cellHeight) ?? 16
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(cellWidth, forKey: .cellWidth)
        try container.encode(cellHeight, forKey: .cellHeight)
        try container.encodeIfPresent(sourcePath, forKey: .sourcePath)
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
    var schema = 2
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
    var isAssistantInput: Bool { path.hasPrefix(".studio/cache/ai/") && path.contains("/inputs/") }
    var isCached: Bool { path.hasPrefix(".studio/cache/") }
    var isGenerated: Bool { isCached && !isAssistantInput }
    var locationLabel: String {
        if isAssistantInput { return "Assistant input" }
        return isGenerated ? "Generated" : "Project asset"
    }
}
