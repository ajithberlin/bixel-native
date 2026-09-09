import AppKit

@main
struct EditorInteractionTests {
    static func main() {
        let model = EditorModel(width: 8, height: 8)
        for _ in 1..<40 { _ = model.document.addLayer() }
        model.reloadLayers()
        let thumbnails = (0..<40).map { model.layerThumbnailCGImage($0)! }
        model.selectTool(.eraser)
        model.activeLayer = 10
        for layer in 0..<40 {
            guard model.layerThumbnailCGImage(layer) === thumbnails[layer] else {
                fatalError("Switching controls must reuse unchanged layer thumbnails, including documents with many layers")
            }
        }
        model.brushSize = 1
        model.selectTool(.pencil)
        model.beginStroke(x: 2, y: 3)
        model.endStroke(x: 2, y: 3)
        precondition(model.layerThumbnailCGImage(10) !== thumbnails[10], "Paint must invalidate the edited layer")
        precondition(model.layerThumbnailCGImage(11) === thumbnails[11], "Paint must preserve other layer thumbnails")
        model.addFrame()
        let nextFrame = model.layerThumbnailCGImage(10)!
        precondition(nextFrame !== thumbnails[10], "Changing frames must not reuse the previous frame's cel")
        print("Editor interaction tests passed")
    }
}
