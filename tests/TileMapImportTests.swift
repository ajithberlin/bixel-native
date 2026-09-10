import Foundation

@main
struct TileMapImportTests {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bixel-tilemap-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("tiled")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceImage = sourceDirectory.appendingPathComponent("terrain.png")
        let imageData = Data([1, 2, 3, 4])
        try imageData.write(to: sourceImage)

        let input: [String: Any] = [
            "type": "map",
            "width": 1,
            "height": 1,
            "tilewidth": 16,
            "tileheight": 16,
            "tilesets": [[
                "firstgid": 1,
                "name": "terrain",
                "image": "terrain.png",
                "imagewidth": 16,
                "imageheight": 16,
                "tilewidth": 16,
                "tileheight": 16,
                "columns": 1,
                "tilecount": 1
            ]],
            "layers": []
        ]
        let inputData = try JSONSerialization.data(withJSONObject: input)
        var persisted: [(data: Data, name: String)] = []

        let output = try TileMapImport.prepareMapJSON(
            inputData,
            sourceDirectory: sourceDirectory
        ) { data, name in
            persisted.append((data, name))
            return "assets/copied-\(name)"
        }

        let value = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let tilesets = value["tilesets"] as! [[String: Any]]
        precondition(tilesets[0]["image"] as? String == "assets/copied-terrain.png")
        precondition(persisted.count == 1)
        precondition(persisted[0].data == imageData)
        precondition(persisted[0].name == "terrain.png")
        print("Tile map import tests passed")
    }
}
