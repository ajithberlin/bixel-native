import Foundation

/// The complete user choice made in the Home AI Studio composer.
struct AICreationRequest: Hashable, Sendable {
    let prompt: String
    let width: Int
    let height: Int
    let style: String

    var size: Int { max(width, height) }

    init(prompt: String, width: Int, height: Int, style: String) {
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.width = max(1, width)
        self.height = max(1, height)
        self.style = style.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(prompt: String, size: Int, style: String) {
        self.init(prompt: prompt, width: size, height: size, style: style)
    }

    /// Explicit dimensions and style keep the provider target tied to the
    /// user's menu selection. Background policy remains prompt-driven so a
    /// request such as "no background" can produce real alpha.
    var imageParameters: [String: Any] {
        let cleanStyle = (style.caseInsensitiveCompare("none") == .orderedSame) ? "" : style
        return [
            "width": width,
            "height": height,
            "style": cleanStyle
        ]
    }
}

struct AIGeneratedImageDraft: Identifiable {
    let id: UUID
    let prompt: String
    let style: String
    let data: Data
    let rgba: [UInt8]
    let width: Int
    let height: Int
    let created: Date

    init(id: UUID = UUID(), request: AICreationRequest, data: Data,
         rgba: [UInt8], width: Int, height: Int, created: Date = Date()) {
        self.id = id
        self.prompt = request.prompt
        self.style = request.style
        self.data = data
        self.rgba = rgba
        self.width = width
        self.height = height
        self.created = created
    }

    var projectName: String {
        let words = prompt.split(whereSeparator: { $0.isWhitespace })
        let compact = words.joined(separator: " ")
        let title = String(compact.prefix(36)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "AI Artwork" : "AI: \(title)"
    }
}

enum AIGenerationError: LocalizedError {
    case provider(String)
    case missingImage
    case invalidImage
    case unexpectedDimensions(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)

    var errorDescription: String? {
        switch self {
        case .provider(let message): return message
        case .missingImage: return "The AI did not return an image. No project was created."
        case .invalidImage: return "The AI returned an unreadable image. No project was created."
        case .unexpectedDimensions(let expectedWidth, let expectedHeight, let actualWidth, let actualHeight):
            return "The AI returned \(actualWidth) × \(actualHeight) instead of \(expectedWidth) × \(expectedHeight). No project was created."
        }
    }
}

enum AIGenerationFlow {
    static func makeDraft(request: AICreationRequest, result: SkillRunResult?) throws -> AIGeneratedImageDraft {
        guard let result else { throw AIGenerationError.missingImage }
        if let message = result.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            throw AIGenerationError.provider(message)
        }
        guard let encoded = result.image, let data = Data(base64Encoded: encoded) else {
            throw AIGenerationError.missingImage
        }
        guard let decoded = AIService.pngToRGBA(data) else {
            throw AIGenerationError.invalidImage
        }
        guard decoded.width == request.width, decoded.height == request.height else {
            throw AIGenerationError.unexpectedDimensions(
                expectedWidth: request.width,
                expectedHeight: request.height,
                actualWidth: decoded.width,
                actualHeight: decoded.height
            )
        }
        return AIGeneratedImageDraft(request: request, data: data, rgba: decoded.rgba,
                                     width: decoded.width, height: decoded.height)
    }
}

struct AIGalleryItem: Codable, Identifiable {
    let id: UUID
    let name: String
    let data: Data
    let width: Int
    let height: Int
    let prompt: String
    let style: String
    let created: Date

    init(draft: AIGeneratedImageDraft) {
        id = draft.id
        name = draft.projectName
        data = draft.data
        width = draft.width
        height = draft.height
        prompt = draft.prompt
        style = draft.style
        created = draft.created
    }
}

/// App-level gallery for generated images that are not committed to a project.
/// It intentionally lives outside any project so declining project creation
/// never attaches the image to an unrelated active project.
@MainActor
final class AIGalleryStore: ObservableObject {
    @Published private(set) var items: [AIGalleryItem] = []
    @Published private(set) var error: String?

    private let root: URL
    private let path = ".studio/ai-gallery.json"
    private let maxItems = 40

    init(root: URL) {
        self.root = root
        reload()
    }

    @discardableResult
    func save(_ draft: AIGeneratedImageDraft) -> Bool {
        let previous = items
        items.insert(AIGalleryItem(draft: draft), at: 0)
        items = Array(items.prefix(maxItems))
        do {
            try persist()
            error = nil
            return true
        } catch {
            items = previous
            self.error = error.localizedDescription
            return false
        }
    }

    func reload() {
        do {
            guard let json = try ProjectStorage.read(base: root, path: path),
                  let data = json.data(using: .utf8) else {
                items = []
                error = nil
                return
            }
            items = try JSONDecoder().decode([AIGalleryItem].self, from: data)
            error = nil
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(items)
        try ProjectStorage.write(base: root, path: path, data: data)
    }
}
