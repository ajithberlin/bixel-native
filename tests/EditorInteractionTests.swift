import AppKit

@main
struct EditorInteractionTests {
    static func main() {
        var workspaceRed: CGFloat = 0
        var workspaceGreen: CGFloat = 0
        var workspaceBlue: CGFloat = 0
        var workspaceAlpha: CGFloat = 0
        PixelCanvas.workspaceBaseColor.getRed(
            &workspaceRed, green: &workspaceGreen, blue: &workspaceBlue, alpha: &workspaceAlpha
        )
        let paletteTolerance: CGFloat = 0.001
        precondition(abs(workspaceRed - 32.0 / 255.0) <= paletteTolerance &&
                     abs(workspaceGreen - 34.0 / 255.0) <= paletteTolerance &&
                     abs(workspaceBlue - 38.0 / 255.0) <= paletteTolerance &&
                     abs(workspaceAlpha - 1.0) <= paletteTolerance,
                     "Workspace base color must be approximately #202226")
        precondition(abs(PixelCanvas.workspaceDimAlpha - 0.22) <= paletteTolerance,
                     "Workspace dim overlay alpha must be approximately 0.22")

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
        let unrotatedGeometry = TransformGeometry(
            center: CGPoint(x: 10, y: 20),
            size: CGSize(width: 8, height: 4),
            angle: 0
        )
        precondition(geometry.point(for: .top) != unrotatedGeometry.point(for: .top) &&
                     geometry.rotationHandlePoint != unrotatedGeometry.rotationHandlePoint,
                     "A 90° transform must expose handle and rotation controls at oriented, not axis-aligned, points")
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
        func floatingGestureModel(sourceWidth: Int = 4, sourceHeight: Int = 2) -> EditorModel {
            let result = EditorModel(width: 16, height: 16)
            result.beginFloatingImport(
                rgba: nativeSource(width: sourceWidth, height: sourceHeight),
                width: sourceWidth, height: sourceHeight,
                target: .newFrame(layer: 0), name: "gesture-source",
                center: CGPoint(x: 8, y: 8)
            )
            return result
        }

        // Floating hit testing is based on the oriented geometry, while a body
        // press begins a move only when it lands inside that geometry.
        let hitModel = floatingGestureModel()
        guard let hitGeometry = hitModel.floatingTransformGeometry else {
            fatalError("Floating import must expose transform geometry")
        }
        precondition(hitModel.beginFloatingMove(x: 7, y: 8),
                     "A press inside a floating image must start a move")
        precondition(!hitModel.beginFloatingMove(x: 2, y: 2),
                     "A press outside a floating image must not start a move")
        let topLeft = hitGeometry.point(for: .topLeft)
        precondition(hitModel.hitFloatingTransformHandle(x: topLeft.x, y: topLeft.y, tolerance: 0.01) == .topLeft,
                     "Floating transform handles must be hit at their oriented geometry positions")
        precondition(hitModel.hitFloatingTransformHandle(x: 8, y: 8, tolerance: 0.01) == nil,
                     "The floating transform center must not be mistaken for a handle")
        let floatingRotationHandle = hitGeometry.rotationHandlePoint
        precondition(hitModel.hitFloatingRotationHandle(x: floatingRotationHandle.x, y: floatingRotationHandle.y, tolerance: 0.01),
                     "Floating rotation handles must be hit at their oriented geometry position")
        precondition(!hitModel.hitFloatingRotationHandle(x: 8, y: 8, tolerance: 0.01),
                     "The floating center must not be mistaken for the rotation handle")

        // A move preserves the pointer's original offset instead of snapping
        // the floating center beneath the cursor, and nudge applies document-space deltas.
        let moveModel = floatingGestureModel()
        precondition(moveModel.beginFloatingMove(x: 6.5, y: 7.5))
        moveModel.updateFloatingMove(x: 11.5, y: 12.5)
        assertNear(moveModel.floatingImport!.center, CGPoint(x: 13, y: 13),
                   "Floating move must preserve press-to-center offset")
        moveModel.nudgeFloatingImport(dx: 2, dy: -3)
        assertNear(moveModel.floatingImport!.center, CGPoint(x: 15, y: 10),
                   "Floating nudge must apply document-space deltas")

        // Crossing the -pi/pi branch is a small clockwise delta, and a cancelled
        // rotation restores the angle from the start of that rotation gesture.
        let rotationModel = floatingGestureModel()
        let radius: CGFloat = 10
        let beforeBranch = CGPoint(x: 8 + cos(.pi - 0.1) * radius, y: 8 + sin(.pi - 0.1) * radius)
        let afterBranch = CGPoint(x: 8 + cos(-.pi + 0.1) * radius, y: 8 + sin(-.pi + 0.1) * radius)
        rotationModel.beginFloatingRotation(x: beforeBranch.x, y: beforeBranch.y)
        rotationModel.updateFloatingRotation(x: afterBranch.x, y: afterBranch.y)
        precondition(abs(rotationModel.floatingImport!.angle - 0.2) <= tolerance,
                     "Floating rotation must accumulate the shortest angle across the pi boundary")
        rotationModel.endFloatingRotation(commit: false)
        precondition(abs(rotationModel.floatingImport!.angle) <= tolerance,
                     "Cancelling a floating rotation must restore its starting angle")

        // A rotated edge resize keeps its opposite edge anchored in document
        // space and changes only the requested local axis.
        let rotatedResizeModel = floatingGestureModel()
        rotatedResizeModel.beginFloatingRotation(x: 8, y: 0)
        rotatedResizeModel.updateFloatingRotation(x: 16, y: 8)
        rotatedResizeModel.endFloatingRotation(commit: true)
        let anchoredLeft = rotatedResizeModel.floatingTransformGeometry!.point(for: .left)
        rotatedResizeModel.beginFloatingResize(handle: .right, x: 8, y: 10, uniform: false)
        rotatedResizeModel.updateFloatingResize(x: 8, y: 12)
        let rotatedResize = rotatedResizeModel.floatingImport!
        assertNear(rotatedResizeModel.floatingTransformGeometry!.point(for: .left), anchoredLeft,
                   "Rotated resize must keep the opposite edge anchored")
        precondition(abs(rotatedResize.scaleX - 1.5) <= tolerance && abs(rotatedResize.scaleY - 1) <= tolerance,
                     "Rotated right-edge resize must change only local width")

        // Uniform corner resize uses one scale factor and keeps the opposite
        // corner fixed; an ordinary edge resize still changes only its axis.
        let uniformResizeModel = floatingGestureModel()
        uniformResizeModel.uniformTransform = true
        let anchoredTopLeft = uniformResizeModel.floatingTransformGeometry!.point(for: .topLeft)
        uniformResizeModel.beginFloatingResize(handle: .bottomRight, x: 10, y: 9, uniform: false)
        uniformResizeModel.updateFloatingResize(x: 14, y: 11)
        let uniformResize = uniformResizeModel.floatingImport!
        assertNear(uniformResizeModel.floatingTransformGeometry!.point(for: .topLeft), anchoredTopLeft,
                   "Uniform corner resize must keep the opposite corner anchored")
        precondition(abs(uniformResize.scaleX - 2) <= tolerance && abs(uniformResize.scaleY - 2) <= tolerance,
                     "Uniform corner resize must preserve the source aspect ratio")

        let edgeResizeModel = floatingGestureModel()
        edgeResizeModel.beginFloatingResize(handle: .right, x: 10, y: 8, uniform: true)
        edgeResizeModel.updateFloatingResize(x: 12, y: 30)
        let edgeResize = edgeResizeModel.floatingImport!
        precondition(abs(edgeResize.scaleX - 1.5) <= tolerance && abs(edgeResize.scaleY - 1) <= tolerance,
                     "Edge resize must ignore uniform scaling and change only its corresponding axis")

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

        // A coalesced geometry refresh can observe only the replacement source:
        // cache its CGImage by source identity so a transform does not rebuild
        // it, but cancellation followed by a new import does replace it.
        let sourceCacheModel = EditorModel(width: 4, height: 4)
        let sourceCacheLayer = CALayer()
        var sourceCache = FloatingImageContentsCache()
        sourceCacheModel.applyImageToNewFrame(nativeSource(width: 2, height: 2), width: 2, height: 2)
        guard let sourceA = sourceCacheModel.floatingImport else {
            fatalError("The first source must become a floating import")
        }
        sourceCache.update(layer: sourceCacheLayer, source: sourceA)
        guard sourceCacheLayer.contents != nil else {
            fatalError("The floating source cache must build the first CGImage")
        }
        let contentsA = sourceCacheLayer.contents! as! CGImage
        sourceCacheModel.nudgeFloatingImport(dx: 1, dy: 0)
        guard let transformedA = sourceCacheModel.floatingImport else {
            fatalError("Transforming a source must keep it pending")
        }
        precondition(transformedA.sourceID == sourceA.sourceID,
                     "Transforming a floating import must preserve its source identity")
        sourceCache.update(layer: sourceCacheLayer, source: transformedA)
        precondition((sourceCacheLayer.contents as! CGImage) === contentsA,
                     "Transform refreshes must retain the cached floating CGImage")

        sourceCacheModel.cancelFloatingImport()
        sourceCacheModel.applyImageToNewFrame([0, 255, 0, 255], width: 1, height: 1)
        guard let sourceB = sourceCacheModel.floatingImport else {
            fatalError("The replacement source must become a floating import")
        }
        precondition(sourceB.sourceID != sourceA.sourceID,
                     "Each floating import must receive a distinct source identity")
        sourceCache.update(layer: sourceCacheLayer, source: sourceB)
        guard sourceCacheLayer.contents != nil else {
            fatalError("The replacement source must build a CGImage")
        }
        let contentsB = sourceCacheLayer.contents! as! CGImage
        precondition(contentsB !== contentsA,
                     "A replacement source observed after cancellation must replace cached pixels")
        sourceCache.update(layer: sourceCacheLayer, source: sourceB)
        precondition((sourceCacheLayer.contents as! CGImage) === contentsB,
                     "Repeated geometry refreshes for one source must not rebuild its CGImage")

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

        // Releasing a canvas resize leaves the transformed source pending; only
        // Place/Enter may rasterize it into the document. This drives the real
        // PixelCanvas mouse router because the bug lived in its mouseUp branch.
        let canvasResizeModel = floatingGestureModel()
        let canvasResizeViewport = CanvasViewport()
        canvasResizeViewport.zoom = 10
        let canvasResize = PixelCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let canvasResizeCoordinator = CanvasView.Coordinator(model: canvasResizeModel, viewport: canvasResizeViewport)
        canvasResize.coordinator = canvasResizeCoordinator
        canvasResize.updateArtboardGeometry()
        func canvasMouseEvent(_ type: NSEvent.EventType, point: CGPoint) -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else {
                fatalError("Could not construct canvas mouse event")
            }
            return event
        }
        // The 4×2 source is centered at document (8, 8), so its right handle
        // is document (10, 8) / view (220, 200); drag it right by two pixels.
        canvasResize.mouseDown(with: canvasMouseEvent(.leftMouseDown, point: CGPoint(x: 220, y: 200)))
        canvasResize.mouseDragged(with: canvasMouseEvent(.leftMouseDragged, point: CGPoint(x: 240, y: 200)))
        canvasResize.mouseUp(with: canvasMouseEvent(.leftMouseUp, point: CGPoint(x: 240, y: 200)))
        precondition(canvasResizeModel.floatingImport != nil,
                     "A floating resize mouse-up must retain the pending source until explicit placement")
        precondition(abs(canvasResizeModel.floatingImport!.scaleX - 1.5) <= tolerance,
                     "Floating resize mouse-up must retain the transformed geometry for subsequent edits")

        // A click outside the floating source is the normal canvas placement
        // boundary. It must commit the pending import instead of being
        // swallowed by the floating gesture branch.
        let outsideClickModel = floatingGestureModel()
        let outsideClickViewport = CanvasViewport()
        outsideClickViewport.zoom = 10
        let outsideClickCanvas = PixelCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let outsideClickCoordinator = CanvasView.Coordinator(model: outsideClickModel, viewport: outsideClickViewport)
        outsideClickCanvas.coordinator = outsideClickCoordinator
        outsideClickCanvas.updateArtboardGeometry()
        outsideClickCanvas.mouseDown(with: canvasMouseEvent(.leftMouseDown, point: CGPoint(x: 130, y: 130)))
        precondition(outsideClickModel.floatingImport == nil && outsideClickModel.frameCount == 2,
                     "Clicking outside a floating source must place it so the editor is usable again")

        let toolSwitchModel = floatingGestureModel()
        toolSwitchModel.selectTool(.pencil)
        precondition(toolSwitchModel.floatingImport == nil && toolSwitchModel.frameCount == 2 &&
                     toolSwitchModel.tool == .pencil,
                     "Switching tools must place a pending import before resuming normal editing")

        precondition(CanvasCursorPolicy.kind(tool: .pencil, insideArtboard: true) == .paint)
        precondition(CanvasCursorPolicy.kind(tool: .eyedropper, insideArtboard: true) == .eyedropper)
        precondition(CanvasCursorPolicy.kind(tool: .pencil, insideArtboard: false) == .arrow)
        precondition(CanvasCursorPolicy.kind(tool: .transform, insideArtboard: true, transformHandle: .right) == .resizeHorizontal)
        precondition(CanvasCursorPolicy.kind(tool: .transform, insideArtboard: true, rotationHandle: true) == .rotate)
        precondition(CanvasCursorPolicy.kind(tool: .transform, insideArtboard: false, floatingBody: true) == .move,
                     "A floating source body outside the artboard must retain its move cursor")

        // Infinite scene fitting must centre the actual world content, not
        // merely reset the camera to cell (0, 0). The camera also has to keep
        // a zoom anchor fixed when a right-side panel reduces the usable view.
        let infiniteViewport = CanvasViewport()
        let mapViewSize = CGSize(width: 1200, height: 800)
        let contentBounds = (x: -320, y: 160, width: 640, height: 320)
        infiniteViewport.zoomToFitInfinite(viewSize: mapViewSize, contentBounds: contentBounds)
        precondition(infiniteViewport.didFit, "Fitting an infinite scene must complete even when its content is offset")
        let contentCenter = infiniteViewport.docToView(
            x: Double(contentBounds.x + contentBounds.width / 2),
            y: Double(contentBounds.y + contentBounds.height / 2),
            viewSize: mapViewSize
        )
        assertNear(contentCenter, CGPoint(x: mapViewSize.width / 2, y: mapViewSize.height / 2),
                   "Infinite scene fit must centre content")

        let anchoredViewport = CanvasViewport()
        anchoredViewport.rightInset = 240
        anchoredViewport.zoom = 2
        let anchorSize = CGSize(width: 1200, height: 800)
        let anchor = anchoredViewport.docToView(x: 37, y: -19, viewSize: anchorSize)
        anchoredViewport.zoomBy(1.5, anchor: anchor, viewSize: anchorSize)
        assertNear(anchoredViewport.docToView(x: 37, y: -19, viewSize: anchorSize), anchor,
                   "Zoom must keep the document point below the cursor")

        let emptyMapViewport = CanvasViewport()
        let emptyMapCanvas = MapCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let emptyMapModel = TileMapModel(infiniteOrientation: .orthogonal, tileWidth: 16, tileHeight: 16)
        let emptyMapCoordinator = TileMapCanvasView.Coordinator(model: emptyMapModel, viewport: emptyMapViewport)
        emptyMapCanvas.coordinator = emptyMapCoordinator
        emptyMapCanvas.layout()
        precondition(emptyMapViewport.didFit && emptyMapViewport.zoom == 1,
                     "An empty infinite scene must establish a stable readable initial camera")

        // The Move tool is also the map navigation tool: dragging empty scene
        // space must pan the camera instead of silently creating a selection.
        let mapMoveModel = TileMapModel(infiniteOrientation: .orthogonal, tileWidth: 16, tileHeight: 16)
        mapMoveModel.tool = .move
        let mapMoveViewport = CanvasViewport()
        mapMoveViewport.zoom = 1
        let mapMoveCanvas = MapCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let mapMoveCoordinator = TileMapCanvasView.Coordinator(model: mapMoveModel, viewport: mapMoveViewport)
        mapMoveCanvas.coordinator = mapMoveCoordinator
        mapMoveCanvas.updateArtboardGeometry()
        mapMoveCanvas.mouseDown(with: canvasMouseEvent(.leftMouseDown, point: CGPoint(x: 200, y: 200)))
        mapMoveCanvas.mouseDragged(with: canvasMouseEvent(.leftMouseDragged, point: CGPoint(x: 248, y: 217)))
        mapMoveCanvas.mouseUp(with: canvasMouseEvent(.leftMouseUp, point: CGPoint(x: 248, y: 217)))
        assertNear(mapMoveViewport.pan, CGPoint(x: 48, y: 17),
                   "Dragging empty infinite-map space with Move must pan the camera")
        precondition(mapMoveModel.selection == nil,
                     "Panning with Move must not create an accidental tile selection")

        let selectedMoveModel = TileMapModel(infiniteOrientation: .orthogonal, tileWidth: 16, tileHeight: 16)
        _ = selectedMoveModel.map.setTile(layer: 0, x: 0, y: 0, gid: 1)
        selectedMoveModel.selection = MapCellRect(x: 0, y: 0, width: 1, height: 1)
        selectedMoveModel.tool = .move
        let selectedMoveViewport = CanvasViewport()
        selectedMoveViewport.zoom = 1
        let selectedMoveCanvas = MapCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let selectedMoveCoordinator = TileMapCanvasView.Coordinator(model: selectedMoveModel, viewport: selectedMoveViewport)
        selectedMoveCanvas.coordinator = selectedMoveCoordinator
        selectedMoveCanvas.updateArtboardGeometry()
        selectedMoveCanvas.mouseDown(with: canvasMouseEvent(.leftMouseDown, point: CGPoint(x: 200, y: 200)))
        selectedMoveCanvas.mouseDragged(with: canvasMouseEvent(.leftMouseDragged, point: CGPoint(x: 232, y: 200)))
        selectedMoveCanvas.mouseUp(with: canvasMouseEvent(.leftMouseUp, point: CGPoint(x: 232, y: 200)))
        precondition(selectedMoveModel.map.getTile(layer: 0, x: 0, y: 0) == 0 &&
                     selectedMoveModel.map.getTile(layer: 0, x: 2, y: 0) == 1,
                     "Dragging a selected tile with Move must reposition it instead of panning")

        // A moved ghost follows the projection-aware cell origin on
        // isometric scenes; raw x/y × tile-size is not the screen position.
        let isoMoveModel = TileMapModel(infiniteOrientation: .isometric, tileWidth: 16, tileHeight: 16)
        _ = isoMoveModel.map.setTile(layer: 0, x: 0, y: 0, gid: 1)
        isoMoveModel.selection = MapCellRect(x: 0, y: 0, width: 1, height: 1)
        isoMoveModel.tool = .move
        isoMoveModel.beginStroke(x: 0, y: 0)
        isoMoveModel.continueStroke(x: 1, y: 0)
        precondition(isoMoveModel.hoverPixel?.x == isoMoveModel.cellOrigin(1, 0).x &&
                     isoMoveModel.hoverPixel?.y == isoMoveModel.cellOrigin(1, 0).y,
                     "Moved isometric ghosts must use projected cell origins")
        print("Editor interaction tests passed")
    }
}
