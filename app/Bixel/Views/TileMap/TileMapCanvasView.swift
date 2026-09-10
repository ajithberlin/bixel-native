// TileMapCanvasView.swift
//
// CALayer-backed infinite canvas for the Tilemap Designer, modeled on the
// sprite PixelCanvas: workspace background, artboard shadow, checkerboard,
// whole-map composite (nearest-neighbour), cell grid, selection marquee,
// object overlay and a paste/brush ghost. Gestures are shared with the sprite
// canvas: drag paint, Shift straight lines, space/middle-drag pan, scroll pan,
// ⌘-scroll / pinch zoom and smart-magnify fit — all via the CanvasViewport.

import SwiftUI
import AppKit
import QuartzCore
import Combine

struct TileMapCanvasView: NSViewRepresentable {
    @ObservedObject var model: TileMapModel
    @ObservedObject var viewport: CanvasViewport

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, viewport: viewport)
    }

    func makeNSView(context: Context) -> MapCanvas {
        let view = MapCanvas()
        view.coordinator = context.coordinator
        context.coordinator.connect(view)
        return view
    }

    func updateNSView(_ view: MapCanvas, context: Context) {
        context.coordinator.model = model
        context.coordinator.viewport = viewport
        view.updateArtboardGeometry()
    }

    final class Coordinator: NSObject {
        var model: TileMapModel
        var viewport: CanvasViewport
        private var observations: [AnyCancellable] = []

        init(model: TileMapModel, viewport: CanvasViewport) {
            self.model = model
            self.viewport = viewport
        }

        func connect(_ view: MapCanvas) {
            model.canvasChanged.sink { [weak view] in
                view?.updateCanvasContents()
                view?.updateOverlays()
            }.store(in: &observations)

            model.objectWillChange.sink { [weak view] in
                view?.scheduleGeometryRefresh()
            }.store(in: &observations)

            viewport.objectWillChange.sink { [weak view] in
                view?.updateArtboardGeometry()
                view?.updateOverlays()
            }.store(in: &observations)
        }

        func hover(at pixel: (x: Int, y: Int)?) {
            if let pixel {
                if let old = model.hoverPixel {
                    if old.x == pixel.x && old.y == pixel.y { return }
                }
                model.hoverPixel = pixel
            } else if model.hoverPixel != nil {
                model.hoverPixel = nil
            }
        }

        func begin(at point: CGPoint, in view: MapCanvas) {
            guard let cell = cellCoordinate(point, in: view) else { return }
            model.beginStroke(x: cell.x, y: cell.y)
        }

        func drag(at point: CGPoint, in view: MapCanvas) {
            guard let cell = cellCoordinate(point, in: view, clamp: true) else { return }
            model.continueStroke(x: cell.x, y: cell.y)
        }

        func end(at point: CGPoint, in view: MapCanvas) {
            guard let cell = cellCoordinate(point, in: view, clamp: true) else { return }
            model.endStroke(x: cell.x, y: cell.y)
        }

        func commitLine(from startView: CGPoint, to endView: CGPoint, dragged: Bool, in view: MapCanvas) {
            guard model.activeIsTile, let end = cellCoordinate(endView, in: view, clamp: true) else { return }
            guard dragged, let start = cellCoordinate(startView, in: view, clamp: true) else { return }
            model.strokeLine(from: start, to: end)
        }

        fileprivate func cellCoordinate(_ point: CGPoint, in view: MapCanvas, clamp: Bool = false) -> (x: Int, y: Int)? {
            guard let pixel = viewport.viewToDoc(point, viewSize: view.bounds.size,
                                                 width: model.map.pixelWidth, height: model.map.pixelHeight, clamp: clamp) else { return nil }
            return (pixel.x / max(1, model.map.cellWidth), pixel.y / max(1, model.map.cellHeight))
        }

        fileprivate func cellOrigin(_ cell: (x: Int, y: Int), in view: MapCanvas) -> (x: Int, y: Int) {
            (cell.x * model.map.cellWidth, cell.y * model.map.cellHeight)
        }
    }
}

/// NSView hosting the map's Core Animation layers and routing events.
final class MapCanvas: NSView {
    weak var coordinator: TileMapCanvasView.Coordinator?

    private let artboardShadowLayer = CALayer()
    private let artboardLayer = CALayer()
    private let checkerboardLayer = CALayer()
    private let compositeLayer = CALayer()
    private let gridLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let objectLayer = CAShapeLayer()
    private let ghostLayer = CAShapeLayer()
    private let borderLayer = CALayer()

    private var lastGridZoom: CGFloat = -1
    private var lastGridColumns = -1
    private var lastGridRows = -1
    private var didDrawContent = false
    private var lastDrawnRevision = -1
    private var isUpdatingGeometry = false
    private var isUpdatingContents = false
    private var geometryRefreshScheduled = false

    private var spaceDown = false
    private var panning = false
    private var lastPanPoint: CGPoint = .zero
    private var lineGesture = false
    private var lineDragged = false
    private var lineStart: CGPoint = .zero

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor(red: 0.07, green: 0.073, blue: 0.085, alpha: 1.0).cgColor

        artboardShadowLayer.shadowColor = NSColor.black.cgColor
        artboardShadowLayer.shadowOpacity = 0.45
        artboardShadowLayer.shadowRadius = 14
        artboardShadowLayer.shadowOffset = CGSize(width: 0, height: -2)
        artboardShadowLayer.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        root.addSublayer(artboardShadowLayer)

        artboardLayer.isGeometryFlipped = true
        artboardLayer.masksToBounds = false
        root.addSublayer(artboardLayer)

        checkerboardLayer.backgroundColor = Self.checkerboardPatternColor
        artboardLayer.addSublayer(checkerboardLayer)

        compositeLayer.magnificationFilter = .nearest
        compositeLayer.minificationFilter = .nearest
        artboardLayer.addSublayer(compositeLayer)

        gridLayer.strokeColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        gridLayer.lineWidth = 1.0
        gridLayer.fillColor = nil
        gridLayer.isHidden = true
        artboardLayer.addSublayer(gridLayer)

        selectionLayer.strokeColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.95).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [4, 4]
        selectionLayer.fillColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.12).cgColor
        selectionLayer.isHidden = true
        artboardLayer.addSublayer(selectionLayer)

        objectLayer.strokeColor = NSColor(red: 0.95, green: 0.4, blue: 0.2, alpha: 0.95).cgColor
        objectLayer.lineWidth = 1.5
        objectLayer.fillColor = NSColor(red: 0.95, green: 0.4, blue: 0.2, alpha: 0.12).cgColor
        objectLayer.isHidden = true
        artboardLayer.addSublayer(objectLayer)

        ghostLayer.strokeColor = NSColor(white: 1.0, alpha: 0.9).cgColor
        ghostLayer.lineWidth = 1.5
        ghostLayer.lineDashPattern = [2, 3]
        ghostLayer.fillColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        ghostLayer.isHidden = true
        artboardLayer.addSublayer(ghostLayer)

        borderLayer.borderColor = NSColor(white: 1.0, alpha: 0.20).cgColor
        borderLayer.borderWidth = 1.0
        artboardLayer.addSublayer(borderLayer)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 40 && bounds.height > 40 else { return }
        if let coordinator {
            coordinator.viewport.lastViewSize = bounds.size
            if !coordinator.viewport.didFit {
                coordinator.viewport.zoomToFit(viewSize: bounds.size,
                                               canvasWidth: coordinator.model.map.pixelWidth,
                                               height: coordinator.model.map.pixelHeight)
            }
        }
        updateArtboardGeometry()
        updateOverlays()
    }

    func scheduleGeometryRefresh() {
        guard !geometryRefreshScheduled else { return }
        geometryRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.geometryRefreshScheduled = false
            self?.updateOverlays()
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
        let docW = model.map.pixelWidth
        let docH = model.map.pixelHeight

        let origin = viewport.artboardOrigin(viewSize: bounds.size, canvasWidth: docW, height: docH)
        let artboardFrame = CGRect(x: origin.x, y: origin.y, width: CGFloat(docW) * viewport.zoom,
                                   height: CGFloat(docH) * viewport.zoom)
        let artboardBounds = CGRect(x: 0, y: 0, width: artboardFrame.width, height: artboardFrame.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artboardShadowLayer.frame = artboardFrame
        artboardShadowLayer.shadowPath = CGPath(rect: artboardBounds, transform: nil)
        artboardLayer.frame = artboardFrame
        borderLayer.frame = artboardBounds
        checkerboardLayer.frame = artboardBounds
        compositeLayer.frame = artboardBounds
        gridLayer.frame = artboardBounds
        selectionLayer.frame = artboardBounds
        objectLayer.frame = artboardBounds
        ghostLayer.frame = artboardBounds

        // Cell grid (visible when cells are ~6 pt wide on screen).
        let cellPoints = CGFloat(model.map.cellWidth) * viewport.zoom
        if viewport.showGrid && cellPoints >= 6 {
            gridLayer.isHidden = false
            if lastGridZoom != viewport.zoom || lastGridColumns != model.map.columns || lastGridRows != model.map.rows {
                gridLayer.path = makeGridPath(model: model, zoom: viewport.zoom)
                lastGridZoom = viewport.zoom
                lastGridColumns = model.map.columns
                lastGridRows = model.map.rows
            }
        } else {
            gridLayer.isHidden = true
        }
        CATransaction.commit()
        updateOverlays()
    }

    private func makeGridPath(model: TileMapModel, zoom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let step = CGFloat(model.map.cellWidth) * zoom
        let totalW = CGFloat(model.map.pixelWidth) * zoom
        let totalH = CGFloat(model.map.pixelHeight) * zoom
        var x = step
        while x < totalW {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: totalH))
            x += step
        }
        var y = step
        while y < totalH {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: totalW, y: y))
            y += step
        }
        return path
    }

    func updateCanvasContents() {
        guard !isUpdatingContents else { return }
        isUpdatingContents = true
        defer { isUpdatingContents = false }
        guard let coordinator else { return }
        let model = coordinator.model
        let revision = model.canvasRevision
        guard !didDrawContent || revision != lastDrawnRevision else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Reuse the revision-cached CGImage (shared with the minimap) instead of
        // re-compositing and re-wrapping the whole map on every stroke.
        compositeLayer.contents = model.compositeCGImage()
        lastDrawnRevision = revision
        didDrawContent = true
        CATransaction.commit()
    }

    /// Redraw the selection, object and ghost overlays from the model.
    func updateOverlays() {
        guard let coordinator else { return }
        let model = coordinator.model
        let zoom = coordinator.viewport.zoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Selection marquee (tile selection or wand region).
        if let rect = model.selection, model.activeIsTile {
            selectionLayer.isHidden = false
            let scaled = CGRect(x: CGFloat(rect.x * model.map.cellWidth) * zoom,
                                y: CGFloat(rect.y * model.map.cellHeight) * zoom,
                                width: CGFloat(rect.width * model.map.cellWidth) * zoom,
                                height: CGFloat(rect.height * model.map.cellHeight) * zoom)
            selectionLayer.path = CGPath(rect: scaled, transform: nil)
        } else if model.tool == .select, model.isObjectActive {
            selectionLayer.isHidden = false
            selectionLayer.path = nil
        } else {
            selectionLayer.isHidden = true
            selectionLayer.path = nil
        }

        // Object rects on the active object layer.
        if model.isObjectActive {
            objectLayer.isHidden = false
            let path = CGMutablePath()
            let selected = model.selectedObjectID
            for obj in model.map.objects(layer: model.activeLayer) {
                let isSel = obj.id == selected
                let scaled = CGRect(x: CGFloat(obj.x) * zoom, y: CGFloat(obj.y) * zoom,
                                    width: CGFloat(max(1, obj.width)) * zoom,
                                    height: CGFloat(max(1, obj.height)) * zoom)
                if obj.type == "point" {
                    path.addEllipse(in: scaled.insetBy(dx: -1.5, dy: -1.5))
                } else {
                    path.addRect(scaled)
                }
                if isSel {
                    // Corner handles for the selected object.
                    let size: CGFloat = 6
                    let handles = [scaled.origin,
                                   CGPoint(x: scaled.maxX, y: scaled.minY),
                                   CGPoint(x: scaled.minX, y: scaled.maxY),
                                   CGPoint(x: scaled.maxX, y: scaled.maxY)]
                    for h in handles {
                        path.addRect(CGRect(x: h.x - size / 2, y: h.y - size / 2, width: size, height: size))
                    }
                }
            }
            objectLayer.path = path
            objectLayer.fillColor = NSColor(red: 0.95, green: 0.4, blue: 0.2, alpha: 0.10).cgColor
        } else {
            objectLayer.isHidden = true
            objectLayer.path = nil
        }

        // Paste / brush ghost anchored at the hovered cell.
        let showBrush = !model.brush.pattern.isEmpty
        let showPaste = model.hasPasteGhost && !model.brush.pattern.isEmpty
        if (showBrush || showPaste), model.activeIsTile, let hover = model.hoverPixel {
            let cellX = hover.x / max(1, model.map.cellWidth)
            let cellY = hover.y / max(1, model.map.cellHeight)
            ghostLayer.isHidden = false
            let scaled = CGRect(x: CGFloat(cellX * model.map.cellWidth) * zoom,
                                y: CGFloat(cellY * model.map.cellHeight) * zoom,
                                width: CGFloat(model.brush.pattern.width * model.map.cellWidth) * zoom,
                                height: CGFloat(model.brush.pattern.height * model.map.cellHeight) * zoom)
            ghostLayer.path = CGPath(rect: scaled, transform: nil)
        } else {
            ghostLayer.isHidden = true
            ghostLayer.path = nil
        }
        CATransaction.commit()
    }

    // MARK: - Event routing (mirrors PixelCanvas)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        refreshCursor(at: point)
        updateHover(point)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.hover(at: nil)
        updateOverlays()
        NSCursor.arrow.set()
    }

    /// Tool- and location-aware cursor: hand over the artboard for Move, arrow
    /// outside it, crosshair for paint/pick tools, closed hand while dragging.
    private func refreshCursor(at point: CGPoint?) {
        if panning { NSCursor.closedHand.set(); return }
        if spaceDown { NSCursor.openHand.set(); return }
        guard let coordinator else { NSCursor.arrow.set(); return }
        let model = coordinator.model
        let overArtboard: Bool
        if let point {
            overArtboard = coordinator.viewport.viewToDoc(point, viewSize: bounds.size,
                                                          width: model.map.pixelWidth,
                                                          height: model.map.pixelHeight) != nil
        } else {
            overArtboard = false
        }
        let cursor: NSCursor
        switch model.tool {
        case .move:
            cursor = overArtboard ? .openHand : .arrow
        case .select, .tilePicker, .wand, .stamp, .terrain, .eraser, .bucket, .rectFill, .line:
            cursor = overArtboard ? .crosshair : .arrow
        }
        cursor.set()
    }

    private func updateHover(_ point: CGPoint) {
        guard let coordinator else { return }
        let pixel = coordinator.viewport.viewToDoc(point, viewSize: bounds.size,
                                                   width: coordinator.model.map.pixelWidth,
                                                   height: coordinator.model.map.pixelHeight, clamp: true)
        coordinator.hover(at: pixel)
        if coordinator.model.brush.pattern.isEmpty == false || coordinator.model.hasPasteGhost {
            updateOverlays()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceDown {
            panning = true
            lastPanPoint = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        if shift, let tool = coordinator?.model.tool, tool == .stamp || tool == .terrain || tool == .eraser || tool == .rectFill || tool == .line {
            lineGesture = true
            lineDragged = false
            lineStart = point
            return
        }
        if coordinator?.model.tool == .move { NSCursor.closedHand.set() }
        coordinator?.begin(at: point, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if panning {
            coordinator?.viewport.panBy(dx: point.x - lastPanPoint.x, dy: point.y - lastPanPoint.y)
            lastPanPoint = point
            return
        }
        if lineGesture {
            lineDragged = true
            updateHover(point)
            return
        }
        if coordinator?.model.tool == .move { NSCursor.closedHand.set() }
        coordinator?.drag(at: point, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        if panning {
            panning = false
            refreshCursor(at: convert(event.locationInWindow, from: nil))
            return
        }
        if lineGesture {
            lineGesture = false
            coordinator?.commitLine(from: lineStart, to: convert(event.locationInWindow, from: nil),
                                    dragged: lineDragged, in: self)
            return
        }
        coordinator?.end(at: convert(event.locationInWindow, from: nil), in: self)
        refreshCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        panning = true
        lastPanPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard panning, event.buttonNumber == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.viewport.panBy(dx: point.x - lastPanPoint.x, dy: point.y - lastPanPoint.y)
        lastPanPoint = point
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            panning = false
            refreshCursor(at: convert(event.locationInWindow, from: nil))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewport = coordinator?.viewport else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
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
        coordinator?.viewport.zoomToFit(viewSize: bounds.size,
                                        canvasWidth: model.map.pixelWidth, height: model.map.pixelHeight)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return }
        let viewport = coordinator.viewport
        let model = coordinator.model

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": viewport.zoomIn()
            case "-": viewport.zoomOut()
            case "0": viewport.zoomToFit(viewSize: bounds.size,
                                         canvasWidth: model.map.pixelWidth, height: model.map.pixelHeight)
            default: super.keyDown(with: event)
            }
            return
        }

        if event.keyCode == 49 {
            spaceDown = true
            NSCursor.openHand.set()
            return
        }

        switch event.charactersIgnoringModifiers {
        case "p": model.tool = .stamp
        case "t": model.tool = .terrain
        case "e": model.tool = .eraser
        case "g": model.tool = .bucket
        case "f": model.tool = .rectFill
        case "l": model.tool = .line
        case "v": model.tool = .select
        case "m": model.tool = .move
        case "i": model.tool = .tilePicker
        case "w": model.tool = .wand
        case "x": model.flipBrushH()
        case "y": model.flipBrushV()
        case "c": model.rotateBrushCW()
        default: super.keyDown(with: event)
        }

        if event.keyCode == 53 {
            model.selection = nil
            model.selectedObjectID = nil
        }
        if event.keyCode == 51 {
            if model.isObjectActive { model.deleteObject() } else { model.deleteSelection() }
        }
        if event.keyCode == 36, model.hasPasteGhost {
            if let hover = model.hoverPixel {
                model.commitPaste(at: hover.x / max(1, model.map.cellWidth),
                                  y: hover.y / max(1, model.map.cellHeight))
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            panning = false
            refreshCursor(at: convert(event.locationInWindow, from: nil))
        } else {
            super.keyUp(with: event)
        }
    }
}

// MARK: - EditorModel-style stroke line (straight line tool)

extension TileMapModel {
    /// Shift-click / straight-line paint with the current tool.
    func strokeLine(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) {
        guard activeIsTile, canPaint else { return }
        map.snapshot()
        let changed: Bool
        switch tool {
        case .eraser:
            changed = map.paintLine(layer: activeLayer, x0: start.x, y0: start.y,
                                    x1: end.x, y1: end.y, gid: 0) > 0
        case .rectFill:
            changed = map.paintRect(layer: activeLayer, x0: start.x, y0: start.y,
                                    x1: end.x, y1: end.y, gid: brush.pattern.tiles.first ?? 0) > 0
        case .stamp, .terrain:
            if !brush.pattern.isEmpty {
                changed = paintStroke(from: start, to: end)
            } else {
                changed = false
            }
        case .line:
            changed = map.paintLine(layer: activeLayer, x0: start.x, y0: start.y,
                                    x1: end.x, y1: end.y, gid: brush.pattern.tiles.first ?? 0) > 0
        default:
            changed = false
        }
        if changed { commitChange() }
    }
}
