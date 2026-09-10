import Foundation
import SwiftUI
import AppKit

@main
struct AICreationFlowTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared

        let request = AICreationRequest(
            prompt: "A neon slime with an electric aura",
            size: 128,
            style: "Cyberpunk Neon"
        )
        let params = request.imageParameters
        precondition(params["width"] as? Int == 128)
        precondition(params["height"] as? Int == 128)
        precondition(params["style"] as? String == "Cyberpunk Neon")

        let rgba = [UInt8](repeating: 90, count: 128 * 128 * 4)
        let png = AIService.rgbaToPNG(rgba, width: 128, height: 128)!
        let result = try JSONDecoder().decode(
            SkillRunResult.self,
            from: JSONSerialization.data(withJSONObject: ["image": png.base64EncodedString()])
        )
        let draft = try AIGenerationFlow.makeDraft(request: request, result: result)
        precondition(draft.width == 128 && draft.height == 128)
        precondition(draft.rgba == rgba)
        precondition(draft.projectName == "AI: A neon slime with an electric aura")

        let wrongSizePNG = AIService.rgbaToPNG([UInt8](repeating: 1, count: 32 * 32 * 4), width: 32, height: 32)!
        let wrongSizeResult = try JSONDecoder().decode(
            SkillRunResult.self,
            from: JSONSerialization.data(withJSONObject: ["image": wrongSizePNG.base64EncodedString()])
        )
        do {
            _ = try AIGenerationFlow.makeDraft(request: request, result: wrongSizeResult)
            preconditionFailure("A mismatched generated size must not become a project draft")
        } catch is AIGenerationError {
            // Expected: project creation is gated on the requested dimensions.
        }

        let projectsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bixel-ai-project-tests-\(UUID().uuidString)/Projects")
        let store = ProjectStore(root: projectsRoot)
        defer { try? FileManager.default.removeItem(at: projectsRoot.deletingLastPathComponent()) }
        let project = store.createProject(
            name: draft.projectName,
            mode: .normal,
            width: draft.width,
            height: draft.height,
            pixels: draft.rgba
        )
        precondition(project != nil)
        precondition(store.editor.width == 128 && store.editor.height == 128)
        precondition(store.editor.document.getPixel(layer: 0, frame: 0, x: 0, y: 0).r == 90)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bixel-ai-gallery-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gallery = AIGalleryStore(root: root)
        gallery.save(draft)
        let reopened = AIGalleryStore(root: root)
        precondition(reopened.items.count == 1)
        precondition(reopened.items[0].width == 128 && reopened.items[0].height == 128)
        precondition(reopened.items[0].data == png)

        print("AI creation request, prepared image, and gallery persistence passed")
    }
}
