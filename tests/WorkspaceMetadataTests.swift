import Foundation

@main struct WorkspaceMetadataTests {
    static func main() throws {
        let normal = WorkspaceDocument(name: "Hero", mode: .normal, width: 32, height: 48)
        let map = WorkspaceDocument(name: "Forest", mode: .map, width: 100, height: 60, cellWidth: 16, cellHeight: 16)
        precondition(normal.mode == .normal)
        precondition(normal.pixelWidth == 32 && normal.pixelHeight == 48)
        precondition(normal.supportsAnimationAssist)
        precondition(normal.pixelWidth == 32 && normal.pixelHeight == 48)
        precondition(map.pixelWidth == 1600 && map.pixelHeight == 960)
        precondition(map.validationError == nil)
        precondition(!map.supportsAnimationAssist)
        let invalid = WorkspaceDocument(name: "Oversized", mode: .map, width: 4096, height: 4096, cellWidth: 64, cellHeight: 64)
        precondition(invalid.validationError != nil)
        let oldMap = Data(#"{"name":"Old Map","kind":"map","width":10,"height":8,"cellWidth":16,"cellHeight":16}"#.utf8)
        let oldMapDocument = try! JSONDecoder().decode(WorkspaceDocument.self, from: oldMap)
        precondition(oldMapDocument.mode == .map)
        let oldAnimation = Data(#"{"name":"Walk","kind":"animation","width":32,"height":32}"#.utf8)
        let oldAnimationDocument = try! JSONDecoder().decode(WorkspaceDocument.self, from: oldAnimation)
        precondition(oldAnimationDocument.mode == .normal)
        let encoded = try! JSONEncoder().encode(oldAnimationDocument)
        let encodedObject = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(encodedObject["mode"] as? String == "normal")
        precondition(encodedObject["kind"] == nil)
        let sheet = WorkspaceDocument(name: "Walk", mode: .normal, width: 128, height: 96)
        precondition(sheet.pixelWidth == 128 && sheet.pixelHeight == 96)
        let state = WorkspaceCatalog(documents: [normal, map, sheet], activeDocumentID: normal.id)
        let roundtrip = try JSONDecoder().decode(WorkspaceCatalog.self, from: JSONEncoder().encode(state))
        precondition(roundtrip.documents.count == 3 && roundtrip.activeDocumentID == normal.id)

        let conversationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        precondition(ProjectArtifactCache.relativeDirectory(for: conversationID) == ".studio/cache/ai/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        precondition(ProjectArtifactCache.cacheURL(projectRoot: URL(fileURLWithPath: "/tmp/bixel"), conversationID: conversationID).path == "/tmp/bixel/.studio/cache/ai/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let safeName = ProjectArtifactCache.filename(for: "../Hero sheet (final).png", uniqueID: conversationID)
        precondition(safeName == "AAAAAAAA-Hero-sheet-final-.png")
        precondition(ProjectArtifactCache.filename(for: "Hero sheet (final)", uniqueID: conversationID).hasSuffix(".png"))
        precondition(WorkspaceMode.allCases == [.normal, .map])
        precondition(WorkspaceDocument(name: "Walk", mode: .normal, width: 32, height: 32).supportsAnimationAssist)
        precondition(!WorkspaceDocument(name: "Map", mode: .map, width: 10, height: 10).supportsAnimationAssist)
        precondition(WorkspaceDocument(name: "Reference", mode: .normal, width: 64, height: 64).supportsAnimationAssist)
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
