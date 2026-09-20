import Foundation
import SwiftUI
import AppKit

@main
struct ProjectThumbnailTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared

        let projectsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bixel-thumbnail-tests-\(UUID().uuidString)/Projects")
        defer { try? FileManager.default.removeItem(at: projectsRoot.deletingLastPathComponent()) }

        let store = ProjectStore(root: projectsRoot)

        // 1. Create a project with red pixels (255, 0, 0, 255)
        var redPixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        for i in stride(from: 0, to: redPixels.count, by: 4) {
            redPixels[i] = 255     // R
            redPixels[i + 1] = 0   // G
            redPixels[i + 2] = 0   // B
            redPixels[i + 3] = 255 // A
        }

        guard let project = store.createProject(
            name: "AI: Red Square",
            mode: .normal,
            width: 32,
            height: 32,
            pixels: redPixels
        ) else {
            fatalError("Failed to create project")
        }

        // Verify that thumbnail was generated in memory and on disk
        let base = projectsRoot.appendingPathComponent(project.id)
        let thumbPath = base.appendingPathComponent("thumbnail.png")
        precondition(FileManager.default.fileExists(atPath: thumbPath.path), "thumbnail.png must exist on disk after project creation")

        guard let initialThumb = store.thumbnail(for: project) else {
            fatalError("store.thumbnail(for:) must return non-nil for freshly created project")
        }
        precondition(initialThumb.width == 32 && initialThumb.height == 32, "Thumbnail dimensions must match sprite dimensions")

        // 2. Modify the project: paint green pixels into the active document
        store.editor.document.setPixel(layer: 0, frame: 0, x: 0, y: 0, BixelColor(r: 0, g: 255, b: 0, a: 255))
        try store.flush()

        guard let updatedThumb = store.thumbnail(for: project) else {
            fatalError("store.thumbnail(for:) must return non-nil after flush")
        }
        precondition(updatedThumb !== initialThumb, "Thumbnail must update when canvas changes are flushed")

        // Read thumbnail.png from disk and ensure it has updated
        guard let savedBytes = try? ProjectStorage.readBytes(base: base, path: "thumbnail.png"),
              let decoded = AIService.pngToRGBA(savedBytes) else {
            fatalError("thumbnail.png on disk must be decodable")
        }
        // Pixel (0, 0) should now be green
        precondition(decoded.rgba[0] == 0 && decoded.rgba[1] == 255 && decoded.rgba[2] == 0, "Saved thumbnail must reflect the green pixel edit")

        // 3. Test on-demand generation for existing projects that don't have thumbnail.png yet
        try FileManager.default.removeItem(at: thumbPath)
        precondition(!FileManager.default.fileExists(atPath: thumbPath.path), "thumbnail.png should be deleted for test")

        // Create a new store instance pointing to the same root (simulates reopening the app)
        let reopenedStore = ProjectStore(root: projectsRoot)
        precondition(reopenedStore.projects.contains(where: { $0.id == project.id }), "Reopened store must find project")

        // Wait for on-demand load
        let targetProject = reopenedStore.projects.first(where: { $0.id == project.id })!
        var loadedThumb: CGImage? = reopenedStore.thumbnail(for: targetProject)
        var attempts = 0
        while loadedThumb == nil && attempts < 50 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            loadedThumb = reopenedStore.thumbnail(for: targetProject)
            attempts += 1
        }

        guard let onDemandThumb = loadedThumb else {
            fatalError("On-demand thumbnail generation must produce a thumbnail for projects lacking thumbnail.png")
        }
        precondition(onDemandThumb.width == 32 && onDemandThumb.height == 32, "On-demand thumbnail dimensions match")
        precondition(FileManager.default.fileExists(atPath: thumbPath.path), "On-demand thumbnail must save thumbnail.png to disk for fast reload")

        // 4. Test map project thumbnail generation
        guard let mapProject = store.createProject(
            name: "Dungeon Map",
            mode: .map,
            width: 10,
            height: 10,
            cellWidth: 16,
            cellHeight: 16
        ) else {
            fatalError("Failed to create map project")
        }
        let mapBase = projectsRoot.appendingPathComponent(mapProject.id)
        let mapThumbPath = mapBase.appendingPathComponent("thumbnail.png")
        precondition(FileManager.default.fileExists(atPath: mapThumbPath.path), "Map project must write thumbnail.png")
        precondition(store.thumbnail(for: mapProject) != nil, "Map project must have thumbnail in memory")

        print("Project thumbnail tests passed!")
    }
}
