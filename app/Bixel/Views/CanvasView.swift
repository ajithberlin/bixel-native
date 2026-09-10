// CanvasView.swift
//
// High-performance Core Animation (CALayer) backed infinite canvas.
// Sublayers represent the workspace, artboard shadow, checkerboard / background,
// onion skinning frames, pixel art buffer (with nearest-neighbour filtering),
// pixel grid, and selection/transform overlays.
//
// Pan and zoom update layer geometry directly with CATransaction animations
// disabled, allowing the GPU / WindowServer to handle rendering at 120 FPS
// with zero CPU overhead.

import SwiftUI
import AppKit
import QuartzCore
import Combine

struct CanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, viewport: viewport)
    }

    func makeNSView(context: Context) -> PixelCanvas {
        let view = PixelCanvas()
        view.registerForDraggedTypes([.png])
        view.coordinator = context.coordinator
        context.coordinator.connect(view)
        return view
    }

    func updateNSView(_ view: PixelCanvas, context: Context) {
        context.coordinator.model = model
        context.coordinator.viewport = viewport
        view.updateArtboardGeometry()
    }

    final class Coordinator: NSObject {
        var model: EditorModel
        var viewport: CanvasViewport
        private var observations: [AnyCancellable] = []

        init(model: EditorModel, viewport: CanvasViewport) {
            self.model = model
            self.viewport = viewport
        }

        func connect(_ view: PixelCanvas) {
            model.canvasChanged.sink { [weak view] in
                view?.updateCanvasContents()
            }.store(in: &observations)

            // Model publishes happen *before* the new values land, so refresh
            // geometry on the next runloop tick — this guarantees the
            // selection/transform box and handles repaint after toolbar actions
            // (rotate, fit-to-canvas, auto-select) even if SwiftUI's representable
            // update path is delayed.
            model.objectWillChange.sink { [weak view] in
                view?.scheduleGeometryRefresh()
            }.store(in: &observations)

            viewport.objectWillChange.sink { [weak view] in
                view?.updateArtboardGeometry()
                view?.updateCanvasContents()
            }.store(in: &observations)
        }

        // MARK: - Painting

        func begin(at point: CGPoint, in view: PixelCanvas) {
            guard let p = pixelCoordinate(point, in: view) else { return }
            model.beginStroke(x: p.x, y: p.y)
        }

        func drag(at point: CGPoint, in view: PixelCanvas) {
            guard let p = pixelCoordinate(point, in: view) else { return }
            model.continueStroke(x: p.x, y: p.y)
        }

        func end(at point: CGPoint, in view: PixelCanvas) {
            guard let p = pixelCoordinate(point, in: view, clamp: true) else { return }
            model.endStroke(x: p.x, y: p.y)
        }

        /// Shift+drag: straight line between press and release.
        /// Shift+click (no drag): line continuing from the last stroke's end.
        func commitLine(from startView: CGPoint, to endView: CGPoint, dragged: Bool, in view: PixelCanvas) {
            guard let end = pixelCoordinate(endView, in: view, clamp: true) else { return }
            if !dragged, let last = model.lastStrokeEnd {
                model.strokeLine(from: last, to: end)
                return
            }
            guard dragged, let start = pixelCoordinate(startView, in: view, clamp: true) else { return }
            model.strokeLine(from: start, to: end)
        }

        fileprivate func pixelCoordinate(_ point: CGPoint, in view: PixelCanvas, clamp: Bool = false) -> (x: Int, y: Int)? {
            viewport.viewToDoc(point, viewSize: view.bounds.size,
                               width: model.width, height: model.height, clamp: clamp)
        }

        /// Continuous document coordinates used by the rotation handle, which
        /// can sit just outside the artboard and therefore cannot use the
        /// clamped integer pixel conversion.
        fileprivate func documentPoint(_ point: CGPoint, in view: PixelCanvas) -> CGPoint {
            let origin = viewport.artboardOrigin(viewSize: view.bounds.size,
                                                  canvasWidth: model.width, height: model.height)
            return CGPoint(
                x: (point.x - origin.x) / viewport.zoom,
                y: (origin.y + CGFloat(model.height) * viewport.zoom - point.y) / viewport.zoom
            )
        }
    }
}

enum CanvasCursorKind: Hashable {
    case arrow, paint, smudge, eraser, fill, eyedropper, selection
    case move, resizeHorizontal, resizeVertical, resizeDiagonal, rotate
    case panOpen, panClosed

    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .paint: return Self.symbolCursor("paintbrush.pointed", fallback: .crosshair)
        case .smudge: return Self.symbolCursor("hand.draw", fallback: .openHand)
        case .eraser: return Self.symbolCursor("eraser", fallback: .disappearingItem)
        case .fill: return Self.symbolCursor("paint.bucket", fallback: .pointingHand)
        case .eyedropper: return Self.symbolCursor("eyedropper", fallback: .crosshair)
        case .selection: return Self.symbolCursor("lasso", fallback: .crosshair)
        case .move: return .openHand
        case .resizeHorizontal: return .resizeLeftRight
        case .resizeVertical: return .resizeUpDown
        case .resizeDiagonal: return Self.symbolCursor("arrow.up.left.and.arrow.down.right", fallback: .crosshair)
        case .rotate: return Self.symbolCursor("rotate.right", fallback: .pointingHand)
        case .panOpen: return .openHand
        case .panClosed: return .closedHand
        }
    }

    private static func symbolCursor(_ name: String, fallback: NSCursor) -> NSCursor {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return fallback }
        image.size = NSSize(width: 24, height: 24)
        return NSCursor(image: image, hotSpot: CGPoint(x: 3, y: 3))
    }
}

/// Pure cursor routing keeps tool/location decisions testable without a live
/// NSView or mouse event stream.
enum CanvasCursorPolicy {
    static func kind(tool: Tool, insideArtboard: Bool,
                     transformHandle: TransformHandle? = nil,
                     rotationHandle: Bool = false,
                     panning: Bool = false,
                     spaceDown: Bool = false) -> CanvasCursorKind {
        if spaceDown { return panning ? .panClosed : .panOpen }
        if tool == .transform {
            if rotationHandle { return .rotate }
            if let transformHandle {
                switch transformHandle {
                case .top, .bottom: return .resizeVertical
                case .left, .right: return .resizeHorizontal
                case .topLeft, .topRight, .bottomRight, .bottomLeft: return .resizeDiagonal
                }
            }
            return insideArtboard ? .move : .arrow
        }
        guard insideArtboard else { return .arrow }
        switch tool {
        case .pencil: return .paint
        case .smudge: return .smudge
        case .eraser: return .eraser
        case .fill: return .fill
        case .eyedropper: return .eyedropper
        case .selection: return .selection
        case .transform: return .move
        }
    }
}

/// NSView subclass that hosts the Core Animation canvas and routes events.
final class PixelCanvas: NSView {
    weak var coordinator: CanvasView.Coordinator?

    // Layers
    private let artboardShadowLayer = CALayer()
    private let artboardLayer = CALayer()
    private let checkerboardLayer = CALayer()
    private let onionLayer2 = CALayer()
    private let onionLayer1 = CALayer()
    private let canvasImageLayer = CALayer()
    private let pixelGridLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let selectionHandlesLayer = CAShapeLayer()
    private let rotationHandleLayer = CAShapeLayer()
    private let borderLayer = CALayer()
    /// Dark veil over the workspace; an even-odd hole lets the artboard shine.
    private let workspaceDimLayer = CAShapeLayer()

    // Grid cache
    private var lastGridZoom: CGFloat = -1
    private var lastGridWidth = -1
    private var lastGridHeight = -1
    private var lastGridStride = -1

    // Content redraw cache: lets updateCanvasContents() run cheaply from many
    // triggers (layout, viewport changes, editor publishes) while only paying
    // for a full recomposite when the pixels/background really changed.
    private var didDrawContent = false
    private var lastDrawnRevision = -1
    private var lastOnionSignature = 0

    // Re-entrancy guards
    private var isUpdatingGeometry = false
    private var isUpdatingContents = false

    // Coalesced geometry refresh (see scheduleGeometryRefresh)
    private var geometryRefreshScheduled = false

    // Gesture state
    private var spaceDown = false
    private var panning = false
    private var lastPanPoint: CGPoint = .zero
    private var lineGesture = false
    private var lineDragged = false
    private var lineStart: CGPoint = .zero
    private var selectionGesture = false
    private var transformGesture = false
    private var resizeGesture = false
    private var rotationGesture = false
    private var transformStartPoint: CGPoint = .zero
    private var didTransformDrag = false

    // Long-press Eyedropper state
    private var eyedropperGesture = false
    private var isLongPressActive = false
    private var longPressWorkItem: DispatchWorkItem?
    private var longPressStartPoint: CGPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private static let checkerboardPatternColor: CGColor = {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.55, alpha: 1.0).setFill()
            rect.fill()
            NSColor(white: 0.40, alpha: 1.0).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: img).cgColor
    }()

    private func setupLayers() {
        wantsLayer = true
        guard let root = layer else { return }

        // Workspace background: Procreate dark workspace (#121316)
        root.backgroundColor = NSColor(red: 0.07, green: 0.073, blue: 0.085, alpha: 1.0).cgColor

        // Artboard shadow layer
        artboardShadowLayer.shadowColor = NSColor.black.cgColor
        artboardShadowLayer.shadowOpacity = 0.45
        artboardShadowLayer.shadowRadius = 14
        artboardShadowLayer.shadowOffset = CGSize(width: 0, height: -2)
        artboardShadowLayer.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        root.addSublayer(artboardShadowLayer)

        // Artboard layer: geometry is flipped so that (0,0) is at top-left inside it
        artboardLayer.isGeometryFlipped = true
        artboardLayer.masksToBounds = false
        root.addSublayer(artboardLayer)

        // Sublayers inside artboard
        checkerboardLayer.backgroundColor = Self.checkerboardPatternColor
        artboardLayer.addSublayer(checkerboardLayer)

        // Onion skin layers (nearest-neighbour)
        onionLayer2.magnificationFilter = .nearest
        onionLayer2.minificationFilter = .nearest
        onionLayer2.isHidden = true
        artboardLayer.addSublayer(onionLayer2)

        onionLayer1.magnificationFilter = .nearest
        onionLayer1.minificationFilter = .nearest
        onionLayer1.isHidden = true
        artboardLayer.addSublayer(onionLayer1)

        // Main artwork layer (nearest-neighbour)
        canvasImageLayer.magnificationFilter = .nearest
        canvasImageLayer.minificationFilter = .nearest
        artboardLayer.addSublayer(canvasImageLayer)

        // Pixel grid layer
        pixelGridLayer.strokeColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        pixelGridLayer.lineWidth = 1.0
        pixelGridLayer.fillColor = nil
        pixelGridLayer.isHidden = true
        artboardLayer.addSublayer(pixelGridLayer)

        // Selection / Transform highlight layer
        selectionLayer.strokeColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.95).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [4, 4]
        selectionLayer.fillColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.14).cgColor
        selectionLayer.isHidden = true
        artboardLayer.addSublayer(selectionLayer)

        // Transform handles (only while the transform tool is active).
        selectionHandlesLayer.fillColor = NSColor.white.cgColor
        selectionHandlesLayer.strokeColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.95).cgColor
        selectionHandlesLayer.lineWidth = 1.25
        selectionHandlesLayer.isHidden = true
        artboardLayer.addSublayer(selectionHandlesLayer)

        // Gold rotation stem + pointer, matching the familiar Procreate
        // transform affordance and kept separate from resize handles so its
        // hit target remains unambiguous.
        rotationHandleLayer.fillColor = NSColor(red: 1.0, green: 0.78, blue: 0.12, alpha: 1).cgColor
        rotationHandleLayer.strokeColor = NSColor(red: 0.12, green: 0.10, blue: 0.05, alpha: 0.9).cgColor
        rotationHandleLayer.lineWidth = 1.25
        rotationHandleLayer.lineCap = .round
        rotationHandleLayer.isHidden = true
        artboardLayer.addSublayer(rotationHandleLayer)

        // Hairline artboard border
        borderLayer.borderColor = NSColor(white: 1.0, alpha: 0.20).cgColor
        borderLayer.borderWidth = 1.0
        artboardLayer.addSublayer(borderLayer)

        // Workspace dim: darkens everything except the artboard, so the work
        // area "pops" (Photoshop/Procreate focus mode). Hole punches in the
        // even-odd path follow the artboard each pan/zoom.
        workspaceDimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        workspaceDimLayer.fillRule = .evenOdd
        root.addSublayer(workspaceDimLayer)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 40 && bounds.height > 40 else { return }
        if let coordinator {
            coordinator.viewport.lastViewSize = bounds.size
            if !coordinator.viewport.didFit {
                coordinator.viewport.zoomToFit(viewSize: bounds.size, canvasWidth: coordinator.model.width, height: coordinator.model.height)
            }
        }
        updateArtboardGeometry()
        updateCanvasContents()
    }
    /// Redraw selection/handles geometry on the next main-queue tick, coalescing
    /// bursts of model publishes into a single update.
    func scheduleGeometryRefresh() {
        guard !geometryRefreshScheduled else { return }
        geometryRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.geometryRefreshScheduled = false
            self?.updateArtboardGeometry()
        }
    }

    func updateArtboardGeometry() {
        guard !isUpdatingGeometry else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }
        guard let coordinator else { return }
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let viewport = coordinator.viewport
        let model = coordinator.model

        let origin = viewport.artboardOrigin(viewSize: bounds.size, canvasWidth: model.width, height: model.height)
        let artboardW = CGFloat(model.width) * viewport.zoom
        let artboardH = CGFloat(model.height) * viewport.zoom
        let artboardFrame = CGRect(x: origin.x, y: origin.y, width: artboardW, height: artboardH)
        let artboardBounds = CGRect(x: 0, y: 0, width: artboardW, height: artboardH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        artboardShadowLayer.frame = artboardFrame
        artboardShadowLayer.shadowPath = CGPath(rect: artboardBounds, transform: nil)

        artboardLayer.frame = artboardFrame
        borderLayer.frame = artboardBounds
        checkerboardLayer.frame = artboardBounds
        onionLayer2.frame = artboardBounds
        onionLayer1.frame = artboardBounds
        canvasImageLayer.frame = artboardBounds
        pixelGridLayer.frame = artboardBounds
        selectionLayer.frame = artboardBounds
        selectionHandlesLayer.frame = artboardBounds
        rotationHandleLayer.frame = artboardBounds

        // Workspace dim veil: hole over the artboard, everything else fades.
        workspaceDimLayer.frame = CGRect(origin: .zero, size: bounds.size)
        let dimPath = CGMutablePath()
        dimPath.addRect(CGRect(origin: .zero, size: bounds.size))
        dimPath.addRect(artboardFrame)
        workspaceDimLayer.path = dimPath

        // Drawing guide uses an adaptive stride so it remains visible at
        // overview zoom without overwhelming the canvas with thousands of
        // one-pixel paths.
        if viewport.showGrid {
            pixelGridLayer.isHidden = false
            let stride = CanvasGridMetrics.lineStride(width: model.width, height: model.height, zoom: viewport.zoom)
            if lastGridZoom != viewport.zoom || lastGridWidth != model.width || lastGridHeight != model.height || lastGridStride != stride {
                pixelGridLayer.path = makeGridPath(width: model.width, height: model.height, zoom: viewport.zoom, stride: stride)
                lastGridZoom = viewport.zoom
                lastGridWidth = model.width
                lastGridHeight = model.height
                lastGridStride = stride
            }
        } else {
            pixelGridLayer.isHidden = true
        }

        // Selection / Transform rect overlay
        if let rect = model.transformRect ?? model.selectionRect {
            let scaledRect = CGRect(
                x: rect.origin.x * viewport.zoom,
                y: rect.origin.y * viewport.zoom,
                width: rect.width * viewport.zoom,
                height: rect.height * viewport.zoom
            )
            selectionLayer.isHidden = false
            selectionLayer.path = CGPath(rect: scaledRect, transform: nil)
            // Handles appear only with the transform tool.
            if model.tool == .transform {
                selectionHandlesLayer.isHidden = false
                selectionHandlesLayer.path = transformHandlePath(for: scaledRect)
                rotationHandleLayer.isHidden = false
                rotationHandleLayer.path = rotationHandlePath(for: scaledRect, zoom: viewport.zoom)
            } else {
                selectionHandlesLayer.isHidden = true
                selectionHandlesLayer.path = nil
                rotationHandleLayer.isHidden = true
                rotationHandleLayer.path = nil
            }
        } else {
            selectionLayer.isHidden = true
            selectionLayer.path = nil
            selectionHandlesLayer.isHidden = true
            selectionHandlesLayer.path = nil
            rotationHandleLayer.isHidden = true
            rotationHandleLayer.path = nil
        }

        CATransaction.commit()
        updateCursor()
    }

    /// Eight small squares centred on the corners and edge midpoints of the
    /// scaled selection rect, sized in view points so they stay readable.
    private func transformHandlePath(for rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let handles: [(CGPoint, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 9),
            (CGPoint(x: rect.midX, y: rect.minY), 7),
            (CGPoint(x: rect.maxX, y: rect.minY), 9),
            (CGPoint(x: rect.maxX, y: rect.midY), 7),
            (CGPoint(x: rect.maxX, y: rect.maxY), 9),
            (CGPoint(x: rect.midX, y: rect.maxY), 7),
            (CGPoint(x: rect.minX, y: rect.maxY), 9),
            (CGPoint(x: rect.minX, y: rect.midY), 7)
        ]
        for (point, size) in handles {
            let corner = point
            path.addRect(CGRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size))
        }
        return path
    }

    private func rotationHandlePath(for rect: CGRect, zoom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let stemDistance = max(18 * zoom, min(36 * zoom, rect.height * 0.3))
        let stemEnd = CGPoint(x: rect.midX, y: rect.minY - stemDistance)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: stemEnd)
        path.addEllipse(in: CGRect(x: stemEnd.x - 6, y: stemEnd.y - 6, width: 12, height: 12))
        return path
    }

    func updateCanvasContents() {
        guard !isUpdatingContents else { return }
        isUpdatingContents = true
        defer { isUpdatingContents = false }

        guard let coordinator else { return }
        let model = coordinator.model
        let viewport = coordinator.viewport

        let revision = model.canvasRevision
        let onionSignature = self.onionSignature()
        let needBase = !didDrawContent || revision != lastDrawnRevision
        let needOnion = needBase || onionSignature != lastOnionSignature
        guard needBase || needOnion else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if needBase {
            // Background color / checkerboard
            if model.showBackgroundColor {
                checkerboardLayer.backgroundColor = model.canvasBackgroundColor.cgColor
            } else {
                checkerboardLayer.backgroundColor = Self.checkerboardPatternColor
            }

            // Canvas image content
            let pixels = model.compositeCurrentFrame()
            canvasImageLayer.contents = makeCGImage(pixels: pixels, width: model.width, height: model.height)
        }

        // Onion skinning content
        if needOnion {
            if viewport.onionSkin && model.frame > 0 {
                let p1 = model.compositeFrame(model.frame - 1)
                onionLayer1.contents = makeCGImage(pixels: p1, width: model.width, height: model.height)
                onionLayer1.opacity = Float(viewport.onionOpacity)
                onionLayer1.isHidden = false
            } else {
                onionLayer1.isHidden = true
                onionLayer1.contents = nil
            }

            if viewport.onionSkin && viewport.onionFrames >= 2 && model.frame > 1 {
                let p2 = model.compositeFrame(model.frame - 2)
                onionLayer2.contents = makeCGImage(pixels: p2, width: model.width, height: model.height)
                onionLayer2.opacity = Float(viewport.onionOpacity * 0.5)
                onionLayer2.isHidden = false
            } else {
                onionLayer2.isHidden = true
                onionLayer2.contents = nil
            }
        }

        lastDrawnRevision = revision
        lastOnionSignature = onionSignature
        didDrawContent = true

        CATransaction.commit()
    }

    private func onionSignature() -> Int {
        var signature = coordinator?.model.frame ?? 0
        signature = signature &* 131_071
        signature = signature ^ (coordinator?.viewport.onionSkin == true ? 1 : 0)
        signature = signature &* 31
        signature = signature ^ ((coordinator?.viewport.onionFrames ?? 1) & 3)
        signature = signature &* 31
        signature = signature ^ Int(((coordinator?.viewport.onionOpacity ?? 0) * 1000).rounded())
        return signature
    }

    private func makeGridPath(width: Int, height: Int, zoom: CGFloat, stride: Int) -> CGPath {
        let path = CGMutablePath()
        let totalW = CGFloat(width) * zoom
        let totalH = CGFloat(height) * zoom
        for x in Swift.stride(from: max(1, stride), to: width, by: max(1, stride)) {
            let xPos = CGFloat(x) * zoom
            path.move(to: CGPoint(x: xPos, y: 0))
            path.addLine(to: CGPoint(x: xPos, y: totalH))
        }
        for y in Swift.stride(from: max(1, stride), to: height, by: max(1, stride)) {
            let yPos = CGFloat(y) * zoom
            path.move(to: CGPoint(x: 0, y: yPos))
            path.addLine(to: CGPoint(x: totalW, y: yPos))
        }
        return path
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.png]) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let coordinator, let data = sender.draggingPasteboard.data(forType: .png),
              data.count <= 32_000_000 else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        guard let pixel = coordinator.viewport.viewToDoc(point, viewSize: bounds.size,
                width: coordinator.model.width, height: coordinator.model.height) else { return false }
        coordinator.model.placeAsset(data, name: "Placed asset", x: pixel.x, y: pixel.y)
        return coordinator.model.operationError == nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Tracking areas (cursor updates)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: CGPoint? = nil) {
        guard let coordinator else { return }
        let point = point ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        let insideArtboard = coordinator.viewport.viewToDoc(
            point,
            viewSize: bounds.size,
            width: coordinator.model.width,
            height: coordinator.model.height
        ) != nil
        var transformHandle: TransformHandle?
        var rotationHandle = false
        if coordinator.model.tool == .transform {
            let documentPoint = coordinator.documentPoint(point, in: self)
            let tolerance = 8.0 / coordinator.viewport.zoom
            rotationHandle = coordinator.model.hitRotationHandle(
                x: documentPoint.x, y: documentPoint.y, tolerance: tolerance
            )
            if !rotationHandle {
                transformHandle = coordinator.model.hitTransformHandle(
                    x: documentPoint.x, y: documentPoint.y, tolerance: tolerance
                )
            }
        }
        CanvasCursorPolicy.kind(
            tool: coordinator.model.tool,
            insideArtboard: insideArtboard,
            transformHandle: transformHandle,
            rotationHandle: rotationHandle,
            panning: panning,
            spaceDown: spaceDown
        ).cursor.set()
    }

    // MARK: - Painting / panning gestures

    /// A press outside the artboard still begins a marquee, anchored at the
    /// nearest canvas edge, so full-canvas selections can be drawn by dragging
    /// from anywhere in the surrounding workspace.
    private func marqueeStart(_ point: CGPoint, in coordinator: CanvasView.Coordinator) -> (x: Int, y: Int)? {
        let viewport = coordinator.viewport
        return viewport.viewToDoc(point, viewSize: bounds.size, width: coordinator.model.width, height: coordinator.model.height, clamp: true)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceDown {
            panning = true
            lastPanPoint = convert(event.locationInWindow, from: nil)
            updateCursor(at: lastPanPoint)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let coordinator {
            if coordinator.model.tool == .eyedropper {
                eyedropperGesture = true
                isLongPressActive = false
                longPressWorkItem?.cancel()
                longPressWorkItem = nil
                let swiftUIPoint = CGPoint(x: point.x, y: bounds.height - point.y)
                if let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                    coordinator.model.startEyedropperSession(at: pixel, viewPosition: swiftUIPoint, sourceTool: .eyedropper)
                }
                return
            }
            if coordinator.model.tool == .selection {
                selectionGesture = true
                // A marquee may begin just outside the artboard so full-canvas
                // selections are easy to start.
                if let pixel = coordinator.pixelCoordinate(point, in: self) {
                    coordinator.model.beginSelection(x: pixel.x, y: pixel.y)
                } else if let clamped = marqueeStart(point, in: coordinator) {
                    coordinator.model.beginSelection(x: clamped.x, y: clamped.y)
                }
                return
            }
            if coordinator.model.tool == .transform, let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                let viewport = coordinator.viewport
                let tolerance = 8.0 / viewport.zoom
                let documentPoint = coordinator.documentPoint(point, in: self)
                if coordinator.model.hitRotationHandle(x: documentPoint.x, y: documentPoint.y, tolerance: tolerance) {
                    coordinator.model.beginRotation(x: documentPoint.x, y: documentPoint.y)
                    rotationGesture = true
                    transformGesture = false
                    resizeGesture = false
                    transformStartPoint = point
                    didTransformDrag = false
                } else if let handle = coordinator.model.hitTransformHandle(x: CGFloat(pixel.x), y: CGFloat(pixel.y), tolerance: tolerance) {
                    let uniform = coordinator.model.uniformTransform || event.modifierFlags.contains(.shift)
                    coordinator.model.beginResize(handle: handle, x: pixel.x, y: pixel.y, uniform: uniform)
                    resizeGesture = true
                    transformGesture = false
                    rotationGesture = false
                    transformStartPoint = point
                    didTransformDrag = false
                } else if coordinator.model.grabTransform(x: pixel.x, y: pixel.y) {
                    transformGesture = true
                    resizeGesture = false
                    rotationGesture = false
                    transformStartPoint = point
                    didTransformDrag = false
                }
                return
            }
        }
        // Shift+draw paints a straight line with the current brush.
        if event.modifierFlags.contains(.shift),
           let tool = coordinator?.model.tool, tool == .pencil || tool == .eraser {
            lineGesture = true
            lineDragged = false
            lineStart = point
            return
        }
        coordinator?.begin(at: point, in: self)

        // Long-press detection for Procreate-style canvas color picking
        if let coordinator, coordinator.model.tool == .pencil || coordinator.model.tool == .eraser || coordinator.model.tool == .smudge {
            longPressStartPoint = point
            isLongPressActive = false
            longPressWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self, weak coordinator] in
                guard let self, let coordinator else { return }
                guard !self.panning, !self.lineGesture, !self.selectionGesture, !self.transformGesture, !self.resizeGesture else { return }
                coordinator.model.abortStroke()
                self.isLongPressActive = true
                let swiftUIPoint = CGPoint(x: self.longPressStartPoint.x, y: self.bounds.height - self.longPressStartPoint.y)
                if let pixel = coordinator.pixelCoordinate(self.longPressStartPoint, in: self, clamp: true) {
                    coordinator.model.startEyedropperSession(
                        at: pixel,
                        viewPosition: swiftUIPoint,
                        sourceTool: coordinator.model.tool
                    )
                }
            }
            longPressWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: workItem)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if eyedropperGesture || isLongPressActive {
            let swiftUIPoint = CGPoint(x: point.x, y: bounds.height - point.y)
            if let coordinator, let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                coordinator.model.updateEyedropperSession(at: pixel, viewPosition: swiftUIPoint)
            }
            return
        }

        if let item = longPressWorkItem, !item.isCancelled {
            let dx = point.x - longPressStartPoint.x
            let dy = point.y - longPressStartPoint.y
            if hypot(dx, dy) > 4.0 {
                item.cancel()
                longPressWorkItem = nil
            }
        }

        if panning {
            coordinator?.viewport.panBy(dx: point.x - lastPanPoint.x, dy: point.y - lastPanPoint.y)
            lastPanPoint = point
            return
        }
        if lineGesture {
            lineDragged = true
            return
        }
        if selectionGesture {
            // Clamp while dragging so a marquee extends to the canvas edge when
            // the cursor leaves the artboard.
            if let coordinator, let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                coordinator.model.updateSelection(x: pixel.x, y: pixel.y)
            }
            return
        }
        if rotationGesture {
            if let coordinator {
                let documentPoint = coordinator.documentPoint(point, in: self)
                coordinator.model.updateRotation(x: documentPoint.x, y: documentPoint.y)
                if !didTransformDrag {
                    let dx = point.x - transformStartPoint.x
                    let dy = point.y - transformStartPoint.y
                    didTransformDrag = hypot(dx, dy) > 2
                }
            }
            return
        }
        if transformGesture {
            if let coordinator, let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                coordinator.model.updateTransform(x: pixel.x, y: pixel.y)
                if !didTransformDrag {
                    let start = coordinator.viewport.viewToDoc(transformStartPoint, viewSize: bounds.size,
                        width: coordinator.model.width, height: coordinator.model.height, clamp: true)
                    didTransformDrag = start.map { $0.x != pixel.x || $0.y != pixel.y } ?? false
                }
            }
            return
        }
        if resizeGesture {
            if let coordinator, let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                coordinator.model.updateResize(x: pixel.x, y: pixel.y)
                if !didTransformDrag {
                    let start = coordinator.viewport.viewToDoc(transformStartPoint, viewSize: bounds.size,
                        width: coordinator.model.width, height: coordinator.model.height, clamp: true)
                    didTransformDrag = start.map { $0.x != pixel.x || $0.y != pixel.y } ?? false
                }
            }
            return
        }
        coordinator?.drag(at: point, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil

        if eyedropperGesture {
            eyedropperGesture = false
            coordinator?.model.commitEyedropperSession()
            return
        }

        if isLongPressActive {
            isLongPressActive = false
            coordinator?.model.commitEyedropperSession()
            return
        }

        if panning {
            panning = false
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }
        if lineGesture {
            lineGesture = false
            coordinator?.commitLine(from: lineStart, to: convert(event.locationInWindow, from: nil),
                                    dragged: lineDragged, in: self)
            return
        }
        if selectionGesture {
            selectionGesture = false
            coordinator?.model.endSelection()
            return
        }
        if transformGesture {
            transformGesture = false
            // Only commit when the user actually dragged; a plain click keeps the
            // current preview (rotation / repositioning) uncommitted.
            if didTransformDrag {
                coordinator?.model.commitTransform()
            }
            return
        }
        if rotationGesture {
            rotationGesture = false
            coordinator?.model.endRotation(commit: didTransformDrag)
            return
        }
        if resizeGesture {
            resizeGesture = false
            coordinator?.model.endResize()
            if didTransformDrag {
                coordinator?.model.commitTransform()
            }
            return
        }
        coordinator?.end(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        panning = true
        lastPanPoint = convert(event.locationInWindow, from: nil)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard panning, event.buttonNumber == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.viewport.panBy(dx: point.x - lastPanPoint.x, dy: point.y - lastPanPoint.y)
        lastPanPoint = point
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        panning = false
    }

    // MARK: - Trackpad pan & zoom

    override func scrollWheel(with event: NSEvent) {
        guard let viewport = coordinator?.viewport else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            // ⌘-scroll zooms around the cursor, like Photoshop.
            let speed: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            viewport.zoomBy(pow(1.0025, CGFloat(event.scrollingDeltaY) * speed),
                            anchor: point, viewSize: bounds.size)
        } else {
            viewport.panBy(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.viewport.zoomBy(1 + event.magnification, anchor: point, viewSize: bounds.size)
    }

    override func smartMagnify(with event: NSEvent) {
        guard let model = coordinator?.model else { return }
        coordinator?.viewport.zoomToFit(viewSize: bounds.size, canvasWidth: model.width, height: model.height)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return }
        let viewport = coordinator.viewport
        let model = coordinator.model

        if model.tool == .transform {
            switch event.keyCode {
            case 123: model.nudgeTransform(dx: -1, dy: 0); return
            case 124: model.nudgeTransform(dx: 1, dy: 0); return
            case 125: model.nudgeTransform(dx: 0, dy: 1); return
            case 126: model.nudgeTransform(dx: 0, dy: -1); return
            default: break
            }
        }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": viewport.zoomIn()
            case "-": viewport.zoomOut()
            case "0": viewport.zoomToFit(viewSize: bounds.size, canvasWidth: model.width, height: model.height)
            default: super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 49: // space — hold to pan
            if !spaceDown { spaceDown = true; updateCursor() }
        default:
            switch event.charactersIgnoringModifiers {
            case "p": model.selectTool(.pencil)
            case "e": model.selectTool(.eraser)
            case "f": model.selectTool(.fill)
            case "i": model.selectTool(.eyedropper)
            case "s": model.selectTool(.selection)
            case "t": model.selectTool(.transform)
            case "[": model.brushSize = max(1, model.brushSize - 1)
            case "]": model.brushSize = min(32, model.brushSize + 1)
            case "g": viewport.showGrid.toggle()
            default: super.keyDown(with: event)
            }
        }

        if event.keyCode == 53 {
            if coordinator.model.eyedropperSession?.isActive == true {
                longPressWorkItem?.cancel()
                longPressWorkItem = nil
                isLongPressActive = false
                eyedropperGesture = false
                coordinator.model.cancelEyedropperSession()
                return
            }
            model.clearSelection()
        }
        if event.keyCode == 36, model.tool == .transform { model.commitTransform() }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            panning = false
            updateCursor()
        } else {
            super.keyUp(with: event)
        }
    }
}
