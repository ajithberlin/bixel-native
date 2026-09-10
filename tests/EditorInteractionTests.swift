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

        func nativeSource(width: Int, height: Int) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    pixels[offset..<(offset + 4)] = [UInt8(x + 1), UInt8(y + 31), UInt8(x + y + 61), 255]
                }
            }
            return pixels
        }
        func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(pixels[offset..<(offset + 4)])
        }

        // A new-frame import must retain native RGBA until the user commits it,
        // and it must target the selected layer rather than layer zero.
        let pendingFrameModel = EditorModel(width: 4, height: 4)
        _ = pendingFrameModel.document.addLayer("Selected")
        pendingFrameModel.reloadLayers()
        pendingFrameModel.activeLayer = 1
        let pendingFrameSource = nativeSource(width: 8, height: 8)
        let framesBeforePendingFrame = pendingFrameModel.frameCount
        let frameBeforePendingFrame = pendingFrameModel.frame
        pendingFrameModel.applyImageToNewFrame(pendingFrameSource, width: 8, height: 8)
        guard let pendingFrame = pendingFrameModel.floatingImport else {
            fatalError("A new-frame import must become a floating import")
        }
        precondition((pendingFrame.width, pendingFrame.height, pendingFrame.rgba.count) == (8, 8, 8 * 8 * 4),
                     "Floating imports must retain the complete native source")
        guard case let .newFrame(layer: targetLayer) = pendingFrame.target else {
            fatalError("New-frame import must keep a new-frame target")
        }
        precondition(targetLayer == 1, "New-frame import must target the active layer")
        precondition(pendingFrameModel.frameCount == framesBeforePendingFrame && pendingFrameModel.frame == frameBeforePendingFrame,
                     "Beginning an import must not create or select a document frame")
        precondition(pendingFrameModel.tool == .transform,
                     "A pending import must enter the transform tool")

        // A dropped asset stores the requested top-left as a source center and
        // does not add its target layer until commit.
        let pendingLayerModel = EditorModel(width: 4, height: 4)
        let pendingLayerSource = nativeSource(width: 8, height: 8)
        let layersBeforePendingLayer = pendingLayerModel.document.layerCount
        pendingLayerModel.placeAsset(
            AIService.rgbaToPNG(pendingLayerSource, width: 8, height: 8)!,
            name: "oversized.png", x: 3, y: -2
        )
        guard let pendingLayer = pendingLayerModel.floatingImport else {
            fatalError("A dropped asset must become a floating import")
        }
        precondition((pendingLayer.width, pendingLayer.height, pendingLayer.rgba.count) == (8, 8, 8 * 8 * 4),
                     "Dropped oversized PNGs must retain every source pixel")
        guard case let .newLayer(frame: targetFrame, name: targetName) = pendingLayer.target else {
            fatalError("Dropped assets must keep a new-layer target")
        }
        precondition(targetFrame == 0 && targetName == "oversized.png",
                     "Dropped asset target must retain frame and layer name")
        assertNear(pendingLayer.center, CGPoint(x: 7, y: 2),
                   "Dropped asset center must derive from the requested source top-left")
        precondition(pendingLayerModel.document.layerCount == layersBeforePendingLayer,
                     "Beginning a dropped asset import must not add a document layer")

        // Cancellation is purely transient: it cannot affect document state or pixels.
        let cancellationModel = EditorModel(width: 4, height: 4)
        cancellationModel.document.setPixel(layer: 0, frame: 0, x: 1, y: 1, BixelColor(r: 9, g: 8, b: 7, a: 255))
        let cancellationPixels = cancellationModel.document.celRGBA(layer: 0, frame: 0)
        let cancellationFrames = cancellationModel.frameCount
        let cancellationLayers = cancellationModel.document.layerCount
        let cancellationFrame = cancellationModel.frame
        let cancellationActiveLayer = cancellationModel.activeLayer
        cancellationModel.applyImageToNewFrame(nativeSource(width: 8, height: 8), width: 8, height: 8)
        cancellationModel.cancelFloatingImport()
        precondition(cancellationModel.floatingImport == nil,
                     "Cancel must discard the pending import")
        precondition(cancellationModel.frameCount == cancellationFrames && cancellationModel.document.layerCount == cancellationLayers &&
                     cancellationModel.frame == cancellationFrame && cancellationModel.activeLayer == cancellationActiveLayer &&
                     cancellationModel.document.celRGBA(layer: 0, frame: 0) == cancellationPixels,
                     "Cancel must leave document frame, layer, selection, and pixels untouched")

        // Commit rasterizes the native source once into the fixed canvas. The
        // canvas clips it then, not when the import begins, and the frame change
        // is a single undoable document mutation.
        let commitFrameModel = EditorModel(width: 4, height: 4)
        _ = commitFrameModel.document.addLayer("Selected")
        commitFrameModel.reloadLayers()
        commitFrameModel.activeLayer = 1
        let commitFrameSource = nativeSource(width: 8, height: 8)
        commitFrameModel.applyImageToNewFrame(commitFrameSource, width: 8, height: 8)
        commitFrameModel.commitFloatingImport()
        precondition(commitFrameModel.floatingImport == nil && commitFrameModel.frameCount == 2 && commitFrameModel.frame == 1 &&
                     commitFrameModel.activeLayer == 1,
                     "Committing a new-frame import must add and select exactly one frame on its target layer")
        precondition(pixel(commitFrameModel.document.celRGBA(layer: 1, frame: 1), width: 4, x: 0, y: 0) ==
                     pixel(commitFrameSource, width: 8, x: 2, y: 2),
                     "Commit must clip the centered native source only in the document-sized result")
        precondition(commitFrameModel.selectionRect == CGRect(x: 0, y: 0, width: 4, height: 4),
                     "New-frame commit must select its committed content bounds")
        precondition(commitFrameModel.document.undo() && commitFrameModel.document.frameCount == 1 && !commitFrameModel.document.canUndo,
                     "New-frame commit must produce one undoable document mutation")

        let commitLayerModel = EditorModel(width: 4, height: 4)
        let commitLayerSource = nativeSource(width: 8, height: 8)
        commitLayerModel.placeAsset(AIService.rgbaToPNG(commitLayerSource, width: 8, height: 8)!, name: "oversized.png")
        commitLayerModel.commitFloatingImport()
        precondition(commitLayerModel.floatingImport == nil && commitLayerModel.document.layerCount == 2 &&
                     commitLayerModel.activeLayer == 1 && commitLayerModel.frame == 0,
                     "Committing a dropped asset must add and select exactly one layer on its target frame")
        precondition(pixel(commitLayerModel.document.celRGBA(layer: 1, frame: 0), width: 4, x: 0, y: 0) ==
                     pixel(commitLayerSource, width: 8, x: 2, y: 2),
                     "New-layer commit must use the document-sized raster result")
        precondition(commitLayerModel.document.undo() && commitLayerModel.document.layerCount == 1 && !commitLayerModel.document.canUndo,
                     "New-layer commit must remain one undoable document mutation")

        // Resizing transforms the native source before the single commit raster.
        let scaledImportModel = EditorModel(width: 8, height: 8)
        let scaledImportSource = nativeSource(width: 4, height: 4)
        scaledImportModel.applyImageToNewFrame(scaledImportSource, width: 4, height: 4)
        scaledImportModel.beginFloatingResize(handle: .bottomRight, x: 6, y: 6, uniform: false)
        scaledImportModel.updateFloatingResize(x: 4, y: 4)
        scaledImportModel.commitFloatingImport()
        let scaledPixels = scaledImportModel.document.celRGBA(layer: 0, frame: 1)
        precondition(pixel(scaledPixels, width: 8, x: 2, y: 2) == pixel(scaledImportSource, width: 4, x: 1, y: 1) &&
                     pixel(scaledPixels, width: 8, x: 3, y: 2) == pixel(scaledImportSource, width: 4, x: 3, y: 1),
                     "Reducing floating scale must place nearest source pixels at the transformed document positions")

        precondition(CanvasCursorPolicy.kind(tool: .pencil, insideArtboard: true) == .paint)
        precondition(CanvasCursorPolicy.kind(tool: .eyedropper, insideArtboard: true) == .eyedropper)
        precondition(CanvasCursorPolicy.kind(tool: .pencil, insideArtboard: false) == .arrow)
        precondition(CanvasCursorPolicy.kind(tool: .transform, insideArtboard: true, transformHandle: .right) == .resizeHorizontal)
        precondition(CanvasCursorPolicy.kind(tool: .transform, insideArtboard: true, rotationHandle: true) == .rotate)
        print("Editor interaction tests passed")
    }
}
