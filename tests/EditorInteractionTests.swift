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

        // Selection state belongs to the selection/transform tool family and
        // must not leak into a painting tool after the user changes tools.
        model.selectTool(.selection)
        model.beginSelection(x: 1, y: 1)
        model.updateSelection(x: 5, y: 5)
        model.endSelection()
        precondition(model.tool == .transform && model.selectionRect != nil)
        precondition(model.hitTransformHandle(x: 3, y: 1, tolerance: 1.0) == .top)
        precondition(model.hitTransformHandle(x: 1, y: 3, tolerance: 1.0) == .left)
        precondition(model.rotationHandlePoint != nil)
        if let rotationPoint = model.rotationHandlePoint {
            precondition(model.hitRotationHandle(x: rotationPoint.x, y: rotationPoint.y, tolerance: 1.0))
            model.beginRotation(x: rotationPoint.x, y: rotationPoint.y)
            model.updateRotation(x: 5, y: 3)
            model.endRotation(commit: false)
        }
        model.selectTool(.pencil)
        precondition(model.selectionRect == nil && model.transformRect == nil,
                     "Changing from transform to a painting tool must close the selection")
        print("Editor interaction tests passed")
    }
}
