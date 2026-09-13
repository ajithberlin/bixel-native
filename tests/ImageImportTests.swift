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
            !homePage.contains("private func importFile() {\n        #if os(macOS)"),
            "The Home import action must not be compiled out on iOS"
        )

        let editorModel = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Bixel/Models/EditorModel.swift"),
            encoding: .utf8
        )
        precondition(
            editorModel.contains("#elseif os(iOS)\nimport UIKit"),
            "The iOS editor paths require UIKit to compile"
        )

        print("Image import tests passed!")
    }
}
