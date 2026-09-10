import Foundation
import SwiftUI
import AppKit

@main
struct ArtifactPersistenceTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bixel-artifact-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let session = AssistantSession()
        session.configure(
            projectRoot: root,
            state: AssistantSavedState(conversationID: conversationID, messages: [], history: [], tokenCount: 0)
        )
        session.messages = [AssistantMessage(isUser: false, text: "")]

        let png = AIService.rgbaToPNG([0, 255, 0, 255], width: 1, height: 1)!
        let cache = ProjectArtifactCache.cacheURL(projectRoot: root, conversationID: conversationID)
        session.receive(AssistantEvent(type: "started", id: "persist", title: "Generate"))
        session.receive(AssistantEvent(type: "tool_call", id: "persist-tool", name: "image_gen", arguments: "{}"))
        session.receive(AssistantEvent(
            type: "artifact",
            id: "persist-artifact",
            parent_id: "persist-tool",
            name: "hero (final)",
            png: png.base64EncodedString(),
            width: 1,
            height: 1
        ))

        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let cachedFiles = (try? FileManager.default.subpathsOfDirectory(atPath: cache.path)) ?? []
        precondition(cachedFiles.contains { $0.contains("hero-final") && $0.hasSuffix(".png") }, "streamed artifact must be persisted in the project cache; files=\(cachedFiles), error=\(session.error ?? "none")")
        print("Artifact persistence tests passed")
    }
}
