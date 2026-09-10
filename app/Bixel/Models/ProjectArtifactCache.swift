import Foundation

/// Canonical location and safe filenames for generated project artifacts.
/// The helper is pure so the storage contract can be tested without touching
/// the filesystem or the Rust boundary.
enum ProjectArtifactCache {
    static func relativeDirectory(for conversationID: UUID) -> String {
        ".studio/cache/ai/\(conversationID.uuidString)"
    }

    static func cacheURL(projectRoot: URL, conversationID: UUID) -> URL {
        projectRoot.appendingPathComponent(relativeDirectory(for: conversationID), isDirectory: true)
    }

    static func filename(for suggestedName: String, uniqueID: UUID = UUID()) -> String {
        let leaf = URL(fileURLWithPath: suggestedName).lastPathComponent
        let safe = leaf
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        let named: String
        if trimmed.isEmpty {
            named = "generated.png"
        } else if URL(fileURLWithPath: trimmed).pathExtension.isEmpty {
            named = "\(trimmed).png"
        } else {
            named = trimmed
        }
        return "\(uniqueID.uuidString.prefix(8))-\(named)"
    }
}
