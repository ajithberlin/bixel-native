import Foundation

@main
struct ImageImportTests {
    static func main() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homePage = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Bixel/Views/HomePageView.swift"),
            encoding: .utf8
        )

        precondition(
            homePage.contains(".fileImporter("),
            "The Home import action must present a SwiftUI file importer on iOS"
        )
        precondition(
            homePage.contains("allowsMultipleSelection: true"),
            "The importer must allow selecting a manifest and its sibling image together"
        )
        precondition(
            !homePage.contains("private func importFile() {\n        #if os(macOS)"),
            "The Home import action must not be compiled out on iOS"
        )

        precondition(
            homePage.contains("pathExtension.lowercased() == \"tmj\""),
            "The Home import action must route Tiled .tmj files to the scene importer"
        )
        precondition(
            homePage.contains("importTiledMap(from: tiledMapURL, createProject: true)"),
            "A Home .tmj import must create a standalone scene project"
        )

        let contentView = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Bixel/Views/ContentView.swift"),
            encoding: .utf8
        )
        precondition(
            contentView.contains("UTType(filenameExtension: \"tmj\")"),
            "The scene picker must allow Tiled .tmj files"
        )

        let tinyPNG = try XCTinyPNG.make()
        var validImageWithLargePayload = tinyPNG
        validImageWithLargePayload.append(Data(repeating: 0xA5, count: 32_000_001))
        precondition(
            AIService.pngToRGBA(validImageWithLargePayload) != nil,
            "Valid images must not be rejected based only on encoded file size"
        )

        let editorModel = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Bixel/Models/EditorModel.swift"),
            encoding: .utf8
        )
        precondition(
            editorModel.contains("#elseif os(iOS)\nimport UIKit"),
            "The iOS editor paths require UIKit to compile"
        )

        let tileMapPanels = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Bixel/Views/TileMap/TileMapPanels.swift"),
            encoding: .utf8
        )
        precondition(
            tileMapPanels.contains(".fileImporter("),
            "Tilemap image actions must present a SwiftUI file importer on iOS"
        )
        precondition(
            tileMapPanels.contains("startAccessingSecurityScopedResource()"),
            "Tilemap image import must access selected iOS files with security-scoped permissions"
        )
        precondition(
            !tileMapPanels.contains("private func pickImage() {\n        #if os(macOS)"),
            "The tileset image action must not be compiled out on iOS"
        )
        precondition(
            !tileMapPanels.contains("private func pickImageLayer() {\n        #if os(macOS)"),
            "The image-layer action must not be compiled out on iOS"
        )

        let iosCanvas = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Bixel/Views/TileMap/TileMapCanvasView.iOS.swift"),
            encoding: .utf8
        )
        precondition(
            iosCanvas.contains("private func renderInfiniteRegion(model: TileMapModel)"),
            "The iOS canvas must render visible content for infinite scenes"
        )
        precondition(
            iosCanvas.contains("private func makeGridPath("),
            "The iOS canvas must build a grid path independently of finite map dimensions"
        )
        precondition(
            iosCanvas.contains("cellPoints >= 5"),
            "The iOS grid should remain visible when cells are large enough to read"
        )

        print("Image import tests passed!")
    }
}

private enum XCTinyPNG {
    static func make() throws -> Data {
        guard let data = pngData(from: [255, 0, 255, 255], width: 1, height: 1) else {
            throw NSError(domain: "ImageImportTests", code: 1)
        }
        return data
    }
}
