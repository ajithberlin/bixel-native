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

        let tolerance: CGFloat = 0.001
        func assertNear(_ actual: CGPoint, _ expected: CGPoint, _ message: String) {
            precondition(abs(actual.x - expected.x) <= tolerance && abs(actual.y - expected.y) <= tolerance,
                         "\(message): expected \(expected), got \(actual)")
        }

        let geometry = TransformGeometry(
            center: CGPoint(x: 10, y: 20),
            size: CGSize(width: 8, height: 4),
            angle: .pi / 2
        )
        let expectedCorners = [
            CGPoint(x: 12, y: 16), CGPoint(x: 12, y: 24),
            CGPoint(x: 8, y: 24), CGPoint(x: 8, y: 16)
        ]
        for (actual, expected) in zip(geometry.corners, expectedCorners) {
            assertNear(actual, expected, "Rotated transform corner")
        }
        let expectedTop = CGPoint(x: 12, y: 20)
        let expectedRotationHandle = CGPoint(x: 30, y: 20)
        assertNear(geometry.point(for: .top), expectedTop, "Rotated top handle")
        assertNear(geometry.rotationHandlePoint, expectedRotationHandle, "Rotated rotation handle")
        func hit(_ point: CGPoint) -> TransformHandle? {
            TransformHandle.allCases.first { handle in
                hypot(point.x - geometry.point(for: handle).x,
                      point.y - geometry.point(for: handle).y) <= 1
            }
        }
        precondition(hit(expectedTop) == .top, "Rotated top handle must be hit-testable")
        precondition(hit(CGPoint(x: 10, y: 18)) == nil,
                     "The old axis-aligned top handle location must not hit rotated geometry")
        precondition(geometry.contains(geometry.center), "The transform center must remain inside rotated geometry")

        func sourcePixel(_ x: Int, _ y: Int) -> [UInt8] {
            [UInt8(x + 1), UInt8(y + 11), UInt8(x + y + 21), 255]
        }
        var source = [UInt8](repeating: 0, count: 3 * 2 * 4)
        for y in 0..<2 {
            for x in 0..<3 {
                let offset = (y * 3 + x) * 4
                source.replaceSubrange(offset..<(offset + 4), with: sourcePixel(x, y))
            }
        }
        let rotated = AIService.rasterizeNativeImage(
            rgba: source, srcWidth: 3, srcHeight: 2,
            center: CGPoint(x: 2, y: 2), scaleX: 1, scaleY: 1,
            angle: .pi / 2, dstWidth: 5, dstHeight: 5
        )
        precondition(rotated.count == 5 * 5 * 4)
        for y in 0..<5 {
            for x in 0..<5 {
                let offset = (y * 5 + x) * 4
                let expected: [UInt8]
                switch (x, y) {
                case (1, 0): expected = sourcePixel(0, 1)
                case (2, 0): expected = sourcePixel(0, 0)
                case (1, 1): expected = sourcePixel(1, 1)
                case (2, 1): expected = sourcePixel(1, 0)
                case (1, 2): expected = sourcePixel(2, 1)
                case (2, 2): expected = sourcePixel(2, 0)
                default: expected = [0, 0, 0, 0]
                }
                precondition(Array(rotated[offset..<(offset + 4)]) == expected,
                             "Rotated source mismatch at (\(x), \(y))")
            }
        }

        var oversized = [UInt8](repeating: 0, count: 7 * 2 * 4)
        for y in 0..<2 {
            for x in 0..<7 {
                let offset = (y * 7 + x) * 4
                oversized.replaceSubrange(offset..<(offset + 4), with: [UInt8(x + 1), UInt8(y + 31), UInt8(x + y + 61), 255])
            }
        }
        let oversizedResult = AIService.rasterizeNativeImage(
            rgba: oversized, srcWidth: 7, srcHeight: 2,
            center: CGPoint(x: 2, y: 2), scaleX: 1, scaleY: 1,
            angle: 0, dstWidth: 5, dstHeight: 5
        )
        let oversizedOffset = (1 * 5 + 4) * 4
        precondition(Array(oversizedResult[oversizedOffset..<(oversizedOffset + 4)]) == [7, 31, 67, 255],
                     "An oversized source must be scanned directly instead of cropped first")

        let scaled = AIService.rasterizeNativeImage(
            rgba: source, srcWidth: 3, srcHeight: 2,
            center: CGPoint(x: 2, y: 2), scaleX: 0.5, scaleY: 0.5,
            angle: 0, dstWidth: 5, dstHeight: 5
        )
        let scaledFirstPixel = (1 * 5 + 1) * 4
        precondition(Array(scaled[scaledFirstPixel..<(scaledFirstPixel + 4)]) == sourcePixel(0, 0),
                     "Scaling must be applied by the commit-time rasterizer")
        let scaledSecondPixel = (1 * 5 + 2) * 4
        precondition(Array(scaled[scaledSecondPixel..<(scaledSecondPixel + 4)]) == sourcePixel(2, 0),
                     "Commit-time scaling must use nearest-neighbour sampling")

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
