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

        let conversationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        precondition(ProjectArtifactCache.relativeDirectory(for: conversationID) == ".studio/cache/ai/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        precondition(ProjectArtifactCache.cacheURL(projectRoot: URL(fileURLWithPath: "/tmp/bixel"), conversationID: conversationID).path == "/tmp/bixel/.studio/cache/ai/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let safeName = ProjectArtifactCache.filename(for: "../Hero sheet (final).png", uniqueID: conversationID)
        precondition(safeName == "AAAAAAAA-Hero-sheet-final-.png")
        precondition(ProjectArtifactCache.filename(for: "Hero sheet (final)", uniqueID: conversationID).hasSuffix(".png"))
        precondition(WorkspaceDocument(name: "Walk", kind: .animation, width: 32, height: 32).supportsAnimationAssist)
        precondition(!WorkspaceDocument(name: "Map", kind: .map, width: 10, height: 10).supportsAnimationAssist)
        precondition(WorkspaceDocument(name: "Tiles", kind: .tileset, width: 4, height: 4).supportsAnimationAssist == false)
        precondition(WorkspaceDocument(name: "Reference", kind: .image, width: 64, height: 64).supportsAnimationAssist)
        let generated = ProjectAssetFile(path: ".studio/cache/ai/\(conversationID.uuidString)/hero.png", name: "hero.png", bytes: 12)
        let input = ProjectAssetFile(path: ".studio/cache/ai/\(conversationID.uuidString)/inputs/reference.png", name: "reference.png", bytes: 12)
        let accepted = ProjectAssetFile(path: "assets/hero.png", name: "hero.png", bytes: 12)
        let source = ProjectAssetFile(path: "assets/hero_source.png", name: "hero_source.png", bytes: 12)
        precondition(generated.isGenerated && generated.locationLabel == "Generated")
        precondition(input.isAssistantInput && !input.isGenerated && input.locationLabel == "Assistant input")
        precondition(!accepted.isGenerated && accepted.locationLabel == "Project asset")
        precondition(source.isSource)

        // TopBar order contract: brush tools -> layers -> color palette -> AI copilot.
        print("Workspace metadata tests passed")
    }
}
