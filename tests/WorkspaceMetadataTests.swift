import Foundation

@main struct WorkspaceMetadataTests {
    static func main() throws {
        let sprite = WorkspaceDocument(name: "Hero", kind: .animation, width: 32, height: 48, cellWidth: 32, cellHeight: 48)
        let map = WorkspaceDocument(name: "Forest", kind: .map, width: 100, height: 60, cellWidth: 16, cellHeight: 16)
        precondition(sprite.pixelWidth == 32 && sprite.pixelHeight == 48)
        precondition(map.pixelWidth == 1600 && map.pixelHeight == 960)
        precondition(map.validationError == nil)
        let invalid = WorkspaceDocument(name: "Oversized", kind: .map, width: 4096, height: 4096, cellWidth: 64, cellHeight: 64)
        precondition(invalid.validationError != nil)
        let sheet = WorkspaceDocument(name: "Walk", kind: .spritesheet, width: 4, height: 2, cellWidth: 32, cellHeight: 48)
        precondition(sheet.pixelWidth == 128 && sheet.pixelHeight == 96)
        let state = WorkspaceCatalog(documents: [sprite, map, sheet], activeDocumentID: sprite.id)
        let roundtrip = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(state))
        precondition(roundtrip.documents.count == 3 && roundtrip.activeDocumentID == sprite.id)
        print("Workspace metadata tests passed")
    }
}
