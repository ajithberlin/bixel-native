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

        let nativeSource = [UInt8](repeating: 0, count: 8 * 8 * 4)
        var markedSource = nativeSource
        let sourcePixel = (2 * 8 + 2) * 4
        markedSource[sourcePixel..<(sourcePixel + 4)] = [255, 0, 0, 255]
        let importModel = EditorModel(width: 4, height: 4)
        importModel.applyImageToNewFrame(markedSource, width: 8, height: 8)
        precondition(importModel.frame == 1, "Imported artwork must be placed on a new frame")
        precondition(importModel.document.getPixel(layer: importModel.activeLayer, frame: 1, x: 0, y: 0).r == 255,
                     "A larger source must retain native pixels at its centered crop instead of being resampled")
        precondition(importModel.tool == .transform && importModel.selectionRect != nil,
                     "Imported artwork must be immediately ready for manual transform")

        let placementModel = EditorModel(width: 4, height: 4)
        var oversizedSource = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let oversizedPixel = (2 * 8 + 2) * 4
        oversizedSource[oversizedPixel..<(oversizedPixel + 4)] = [255, 0, 0, 255]
        placementModel.placeAsset(AIService.rgbaToPNG(oversizedSource, width: 8, height: 8)!, name: "oversized.png")
        precondition(placementModel.document.getPixel(layer: placementModel.activeLayer, frame: 0, x: 0, y: 0).r == 255,
                     "Larger dropped assets must be centered with native pixels instead of clamping their origin")

        precondition(CanvasCursorPolicy.kind(tool: .pencil, insideArtboard: true) == .paint)
        precondition(CanvasCursorPolicy.kind(tool: .eyedropper, insideArtboard: true) == .eyedropper)
        precondition(CanvasCursorPolicy.kind(tool: .pencil, insideArtboard: false) == .arrow)
        precondition(CanvasCursorPolicy.kind(tool: .transform, insideArtboard: true, transformHandle: .right) == .resizeHorizontal)
        precondition(CanvasCursorPolicy.kind(tool: .transform, insideArtboard: true, rotationHandle: true) == .rotate)
        print("Editor interaction tests passed")
    }
}
