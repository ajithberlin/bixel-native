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

#if os(macOS)
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
                     floatingBody: Bool = false,
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
            return insideArtboard || floatingBody ? .move : .arrow
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

/// Caches the rasterized preview by its immutable source rather than by layer
/// occupancy. Geometry refreshes may be coalesced across a cancel/import pair,
/// so the current layer contents alone cannot identify the pending source.
struct FloatingImageContentsCache {
    private var sourceID: UUID?

    mutating func update(layer: CALayer, source: FloatingImageImport) {
        guard sourceID != source.sourceID else { return }
        guard let contents = makeCGImage(pixels: source.rgba, width: source.width, height: source.height) else {
            layer.contents = nil
            sourceID = nil
            return
        }
        layer.contents = contents
        sourceID = source.sourceID
    }

    mutating func clear(layer: CALayer) {
        layer.contents = nil
        sourceID = nil
    }
}

/// NSView subclass that hosts the Core Animation canvas and routes events.
final class PixelCanvas: NSView {
    weak var coordinator: CanvasView.Coordinator?

    static let workspaceBaseColor = NSColor(red: 32.0 / 255.0,
                                            green: 34.0 / 255.0,
                                            blue: 38.0 / 255.0,
                                            alpha: 1.0)
    static let workspaceDimAlpha: CGFloat = 0.22

    // Layers
    private let artboardShadowLayer = CALayer()
    private let artboardLayer = CALayer()
    private let checkerboardLayer = CALayer()
    private static let maxOnionLayers = 5
    private let onionLayers: [CALayer] = (0..<5).map { _ in CALayer() }
    private let canvasImageLayer = CALayer()
    private let pixelGridLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let selectionHandlesLayer = CAShapeLayer()
    private let rotationHandleLayer = CAShapeLayer()
    private let borderLayer = CALayer()
    /// Dark veil over the workspace; an even-odd hole lets the artboard shine.
    private let workspaceDimLayer = CAShapeLayer()
    /// Pending imports deliberately live at the workspace root rather than in
    /// `artboardLayer`: their native-size source and controls may extend beyond
    /// the fixed export canvas until the user places them.
    private let floatingImageLayer = CALayer()
    private let floatingOutlineLayer = CAShapeLayer()
    private let floatingHandlesLayer = CAShapeLayer()
    private let floatingRotationLayer = CAShapeLayer()
    private var floatingImageContentsCache = FloatingImageContentsCache()

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

        // Workspace background: graphite gray (#202226)
        root.backgroundColor = Self.workspaceBaseColor.cgColor
        root.masksToBounds = true

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
        // Added in reverse so closest frame (distance 1) is above older frames
        for layer in onionLayers.reversed() {
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            layer.isHidden = true
            artboardLayer.addSublayer(layer)
        }

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
        workspaceDimLayer.fillColor = NSColor.black.withAlphaComponent(Self.workspaceDimAlpha).cgColor
        workspaceDimLayer.fillRule = .evenOdd
        root.addSublayer(workspaceDimLayer)

        // These are root siblings above the dim veil, so an oversized source
        // remains visible and interactive throughout the surrounding workspace.
        floatingImageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        floatingImageLayer.magnificationFilter = .nearest
        floatingImageLayer.minificationFilter = .nearest
        floatingImageLayer.isHidden = true
        root.addSublayer(floatingImageLayer)

        floatingOutlineLayer.strokeColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.95).cgColor
        floatingOutlineLayer.lineWidth = 1.5
        floatingOutlineLayer.lineDashPattern = [4, 4]
        floatingOutlineLayer.fillColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.14).cgColor
        floatingOutlineLayer.isHidden = true
        root.addSublayer(floatingOutlineLayer)

        floatingHandlesLayer.fillColor = NSColor.white.cgColor
        floatingHandlesLayer.strokeColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.95).cgColor
        floatingHandlesLayer.lineWidth = 1.25
        floatingHandlesLayer.isHidden = true
        root.addSublayer(floatingHandlesLayer)

        floatingRotationLayer.fillColor = NSColor(red: 1.0, green: 0.78, blue: 0.12, alpha: 1).cgColor
        floatingRotationLayer.strokeColor = NSColor(red: 0.12, green: 0.10, blue: 0.05, alpha: 0.9).cgColor
        floatingRotationLayer.lineWidth = 1.25
        floatingRotationLayer.lineCap = .round
        floatingRotationLayer.isHidden = true
        root.addSublayer(floatingRotationLayer)
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
        for layer in onionLayers {
            layer.frame = artboardBounds
        }
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

        // Selection / Transform overlay. The artboard is flipped, so document
        // coordinates scale directly within it; the shared builders keep the
        // ordinary and floating controls on the same oriented geometry.
        if let geometry = ordinaryTransformGeometry(for: model) {
            selectionLayer.isHidden = false
            selectionLayer.path = orientedOutlinePath(for: geometry) { point in
                CGPoint(x: point.x * viewport.zoom, y: point.y * viewport.zoom)
            }
            // Handles appear only with the transform tool.
            if model.tool == .transform {
                selectionHandlesLayer.isHidden = false
                selectionHandlesLayer.path = transformHandlePath(for: geometry) { point in
                    CGPoint(x: point.x * viewport.zoom, y: point.y * viewport.zoom)
                }
                rotationHandleLayer.isHidden = false
                rotationHandleLayer.path = rotationHandlePath(for: geometry) { point in
                    CGPoint(x: point.x * viewport.zoom, y: point.y * viewport.zoom)
                }
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

        updateFloatingImportGeometry()

        CATransaction.commit()
        updateCursor()
    }

    private func ordinaryTransformGeometry(for model: EditorModel) -> TransformGeometry? {
        model.transformGeometry
    }

    private func documentPointToView(_ point: CGPoint, coordinator: CanvasView.Coordinator) -> CGPoint {
        let viewport = coordinator.viewport
        let origin = viewport.artboardOrigin(viewSize: bounds.size,
                                              canvasWidth: coordinator.model.width,
                                              height: coordinator.model.height)
        return CGPoint(x: origin.x + point.x * viewport.zoom,
                       y: origin.y + (CGFloat(coordinator.model.height) - point.y) * viewport.zoom)
    }

    private func orientedOutlinePath(for geometry: TransformGeometry,
                                     map: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        let corners = geometry.corners.map(map)
        guard let first = corners.first else { return path }
        path.move(to: first)
        for corner in corners.dropFirst() { path.addLine(to: corner) }
        path.closeSubpath()
        return path
    }

    /// Eight small squares centred on the rotated corners and edge midpoints,
    /// sized in view points so they stay readable at every zoom.
    private func transformHandlePath(for geometry: TransformGeometry,
                                     map: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        for handle in TransformHandle.allCases {
            let point = map(geometry.point(for: handle))
            let size: CGFloat = handle.isCorner ? 9 : 7
            path.addRect(CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        }
        return path
    }

    private func rotationHandlePath(for geometry: TransformGeometry,
                                    map: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        let edge = map(geometry.point(for: .top))
        let handle = map(geometry.rotationHandlePoint)
        path.move(to: edge)
        path.addLine(to: handle)
        path.addEllipse(in: CGRect(x: handle.x - 6, y: handle.y - 6, width: 12, height: 12))
        return path
    }

    /// Refreshes only CALayer geometry during gestures. The CGImage is rebuilt
    /// only when the immutable pending source changes, then cleared on dismissal.
    private func updateFloatingImportGeometry() {
        guard let coordinator, let image = coordinator.model.floatingImport,
              let geometry = coordinator.model.floatingTransformGeometry else {
            floatingImageContentsCache.clear(layer: floatingImageLayer)
            floatingImageLayer.isHidden = true
            floatingOutlineLayer.path = nil
            floatingOutlineLayer.isHidden = true
            floatingHandlesLayer.path = nil
            floatingHandlesLayer.isHidden = true
            floatingRotationLayer.path = nil
            floatingRotationLayer.isHidden = true
            return
        }

        let rootFrame = CGRect(origin: .zero, size: bounds.size)
        floatingOutlineLayer.frame = rootFrame
        floatingHandlesLayer.frame = rootFrame
        floatingRotationLayer.frame = rootFrame
        floatingImageContentsCache.update(layer: floatingImageLayer, source: image)
        floatingImageLayer.bounds = CGRect(x: 0, y: 0,
                                           width: CGFloat(image.width) * coordinator.viewport.zoom,
                                           height: CGFloat(image.height) * coordinator.viewport.zoom)
        floatingImageLayer.position = documentPointToView(image.center, coordinator: coordinator)
        floatingImageLayer.setAffineTransform(
            CGAffineTransform(scaleX: image.scaleX, y: image.scaleY).rotated(by: -image.angle)
        )
        floatingImageLayer.isHidden = false

        let map: (CGPoint) -> CGPoint = { [weak self, weak coordinator] point in
            guard let self, let coordinator else { return .zero }
            return self.documentPointToView(point, coordinator: coordinator)
        }
        floatingOutlineLayer.path = orientedOutlinePath(for: geometry, map: map)
        floatingOutlineLayer.isHidden = false
        floatingHandlesLayer.path = transformHandlePath(for: geometry, map: map)
        floatingHandlesLayer.isHidden = false
        floatingRotationLayer.path = rotationHandlePath(for: geometry, map: map)
        floatingRotationLayer.isHidden = false
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
            let state = OnionSkinRenderState(
                currentFrame: model.frame,
                frameCount: model.frameCount,
                enabled: viewport.onionSkin,
                frameCountToShow: viewport.onionFrames,
                opacity: viewport.onionOpacity,
                colorize: viewport.onionColorize
            )
            let specs = state.layers
            for i in 0..<onionLayers.count {
                let layer = onionLayers[i]
                if i < specs.count {
                    let spec = specs[i]
                    let pixels = model.compositeFrame(spec.frameIndex)
                    if let tint = spec.tintColor {
                        layer.contents = makeTintedCGImage(pixels: pixels, width: model.width, height: model.height, tint: tint)
                    } else {
                        layer.contents = makeCGImage(pixels: pixels, width: model.width, height: model.height)
                    }
                    layer.opacity = Float(spec.opacity)
                    layer.isHidden = false
                } else {
                    layer.isHidden = true
                    layer.contents = nil
                }
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
        signature = signature ^ ((coordinator?.viewport.onionFrames ?? 1) & 7)
        signature = signature &* 31
        signature = signature ^ (coordinator?.viewport.onionColorize == true ? 1 : 0)
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
        let documentPoint = coordinator.documentPoint(point, in: self)
        let tolerance = 8.0 / coordinator.viewport.zoom
        let floatingGeometry = coordinator.model.floatingTransformGeometry
        if let floatingGeometry {
            // A floating import owns transform affordances even if its controls
            // lie outside the export canvas or another tool was selected.
            rotationHandle = hitRotationHandle(at: documentPoint, geometry: floatingGeometry, tolerance: tolerance)
            if !rotationHandle {
                transformHandle = hitTransformHandle(at: documentPoint, geometry: floatingGeometry, tolerance: tolerance)
            }
            CanvasCursorPolicy.kind(
                tool: .transform,
                insideArtboard: insideArtboard,
                transformHandle: transformHandle,
                rotationHandle: rotationHandle,
                floatingBody: floatingGeometry.contains(documentPoint),
                panning: panning,
                spaceDown: spaceDown
            ).cursor.set()
            return
        }
        if coordinator.model.tool == .transform, let geometry = ordinaryTransformGeometry(for: coordinator.model) {
            rotationHandle = hitRotationHandle(at: documentPoint, geometry: geometry, tolerance: tolerance)
            if !rotationHandle {
                transformHandle = hitTransformHandle(at: documentPoint, geometry: geometry, tolerance: tolerance)
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

    private func hitTransformHandle(at point: CGPoint, geometry: TransformGeometry,
                                    tolerance: CGFloat) -> TransformHandle? {
        TransformHandle.allCases.first { handle in
            hypot(point.x - geometry.point(for: handle).x,
                  point.y - geometry.point(for: handle).y) <= tolerance
        }
    }

    private func hitRotationHandle(at point: CGPoint, geometry: TransformGeometry,
                                   tolerance: CGFloat) -> Bool {
        hypot(point.x - geometry.rotationHandlePoint.x,
              point.y - geometry.rotationHandlePoint.y) <= tolerance
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
            // Floating controls are tested before converting to a clamped
            // integer pixel, because their source and handles may live outside
            // the artboard. All of their gestures use continuous document space.
            if let geometry = coordinator.model.floatingTransformGeometry {
                let documentPoint = coordinator.documentPoint(point, in: self)
                let tolerance = 8.0 / coordinator.viewport.zoom
                transformStartPoint = point
                didTransformDrag = false
                if hitRotationHandle(at: documentPoint, geometry: geometry, tolerance: tolerance) {
                    coordinator.model.beginFloatingRotation(x: documentPoint.x, y: documentPoint.y)
                    rotationGesture = true
                    transformGesture = false
                    resizeGesture = false
                } else if let handle = hitTransformHandle(at: documentPoint, geometry: geometry, tolerance: tolerance) {
                    coordinator.model.beginFloatingResize(
                        handle: handle, x: documentPoint.x, y: documentPoint.y,
                        uniform: event.modifierFlags.contains(.shift)
                    )
                    resizeGesture = true
                    transformGesture = false
                    rotationGesture = false
                } else if coordinator.model.beginFloatingMove(x: documentPoint.x, y: documentPoint.y) {
                    transformGesture = true
                    resizeGesture = false
                    rotationGesture = false
                } else {
                    // Clicking away from the floating source is the natural
                    // placement gesture. Transform mouse-up remains
                    // non-destructive, but an outside press explicitly ends
                    // the pending import so the rest of the editor is usable.
                    coordinator.model.commitFloatingImport()
                }
                return
            }
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
                let geometry = ordinaryTransformGeometry(for: coordinator.model)
                if let geometry, hitRotationHandle(at: documentPoint, geometry: geometry, tolerance: tolerance) {
                    coordinator.model.beginRotation(x: documentPoint.x, y: documentPoint.y)
                    rotationGesture = true
                    transformGesture = false
                    resizeGesture = false
                    transformStartPoint = point
                    didTransformDrag = false
                } else if let geometry, let handle = hitTransformHandle(at: documentPoint, geometry: geometry, tolerance: tolerance) {
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
                if coordinator.model.floatingImport != nil {
                    coordinator.model.updateFloatingRotation(x: documentPoint.x, y: documentPoint.y)
                } else {
                    coordinator.model.updateRotation(x: documentPoint.x, y: documentPoint.y)
                }
                if !didTransformDrag {
                    let dx = point.x - transformStartPoint.x
                    let dy = point.y - transformStartPoint.y
                    didTransformDrag = hypot(dx, dy) > 2
                }
            }
            return
        }
        if transformGesture {
            if let coordinator {
                if coordinator.model.floatingImport != nil {
                    let documentPoint = coordinator.documentPoint(point, in: self)
                    coordinator.model.updateFloatingMove(x: documentPoint.x, y: documentPoint.y)
                    if !didTransformDrag {
                        let dx = point.x - transformStartPoint.x
                        let dy = point.y - transformStartPoint.y
                        didTransformDrag = hypot(dx, dy) > 2
                    }
                } else if let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                    coordinator.model.updateTransform(x: pixel.x, y: pixel.y)
                    if !didTransformDrag {
                        let start = coordinator.viewport.viewToDoc(transformStartPoint, viewSize: bounds.size,
                            width: coordinator.model.width, height: coordinator.model.height, clamp: true)
                        didTransformDrag = start.map { $0.x != pixel.x || $0.y != pixel.y } ?? false
                    }
                }
            }
            return
        }
        if resizeGesture {
            if let coordinator {
                if coordinator.model.floatingImport != nil {
                    let documentPoint = coordinator.documentPoint(point, in: self)
                    coordinator.model.updateFloatingResize(x: documentPoint.x, y: documentPoint.y)
                    if !didTransformDrag {
                        let dx = point.x - transformStartPoint.x
                        let dy = point.y - transformStartPoint.y
                        didTransformDrag = hypot(dx, dy) > 2
                    }
                } else if let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                    coordinator.model.updateResize(x: pixel.x, y: pixel.y)
                    if !didTransformDrag {
                        let start = coordinator.viewport.viewToDoc(transformStartPoint, viewSize: bounds.size,
                            width: coordinator.model.width, height: coordinator.model.height, clamp: true)
                        didTransformDrag = start.map { $0.x != pixel.x || $0.y != pixel.y } ?? false
                    }
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
            // Floating imports remain editable after a move. Rasterization is
            // explicit (Place/Enter), whereas an ordinary selection commits a
            // completed drag into its document-backed source.
            if didTransformDrag, coordinator?.model.floatingImport == nil {
                coordinator?.model.commitTransform()
            }
            return
        }
        if rotationGesture {
            rotationGesture = false
            if coordinator?.model.floatingImport != nil {
                coordinator?.model.endFloatingRotation(commit: didTransformDrag)
            } else {
                coordinator?.model.endRotation(commit: didTransformDrag)
            }
            return
        }
        if resizeGesture {
            resizeGesture = false
            if coordinator?.model.floatingImport == nil {
                coordinator?.model.endResize()
                if didTransformDrag {
                    coordinator?.model.commitTransform()
                }
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

        if model.floatingImport != nil {
            switch event.keyCode {
            case 123: model.nudgeFloatingImport(dx: -1, dy: 0); return
            case 124: model.nudgeFloatingImport(dx: 1, dy: 0); return
            case 125: model.nudgeFloatingImport(dx: 0, dy: 1); return
            case 126: model.nudgeFloatingImport(dx: 0, dy: -1); return
            case 36: model.commitFloatingImport(); return
            case 53: model.cancelFloatingImport(); return
            default: break
            }
        }

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

        // Frame navigation and deletion when no selection/transform is active.
        if model.selectionRect == nil, model.transformRect == nil, model.floatingImport == nil {
            if event.keyCode == 51 || event.keyCode == 117 {
                model.removeFrame()
                return
            }
            switch event.charactersIgnoringModifiers {
            case ",": model.pause(); model.goTo(model.frame - 1); return
            case ".": model.pause(); model.goTo(model.frame + 1); return
            default: break
            }
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
#endif
