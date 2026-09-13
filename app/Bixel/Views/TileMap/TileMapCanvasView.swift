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
        view.updateCanvasContents()
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
                view?.updateCanvasContents()
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
            if model.isInfinite {
                let doc = viewport.viewToDocF(point, viewSize: view.bounds.size)
                return model.rawCell(atPixel: (Int(doc.x.rounded(.down)), Int(doc.y.rounded(.down))))
            }
            guard let pixel = viewport.viewToDoc(point, viewSize: view.bounds.size,
                                                 width: model.map.pixelWidth, height: model.map.pixelHeight, clamp: clamp) else { return nil }
            return model.cell(atPixel: pixel, clamp: clamp)
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
    private let gridMinorLayer = CAShapeLayer()
    private let gridMajorLayer = CAShapeLayer()
    private let gridAxisLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let objectLayer = CAShapeLayer()
    private let ghostLayer = CAShapeLayer()
    private let borderLayer = CALayer()

    private var lastOrientation: MapOrientation = .orthogonal
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
        root.masksToBounds = true

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

        gridMinorLayer.strokeColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        gridMinorLayer.lineWidth = 1.0
        gridMinorLayer.fillColor = nil
        gridMinorLayer.isHidden = true
        artboardLayer.addSublayer(gridMinorLayer)

        gridMajorLayer.strokeColor = NSColor(white: 1.0, alpha: 0.20).cgColor
        gridMajorLayer.lineWidth = 1.0
        gridMajorLayer.fillColor = nil
        gridMajorLayer.isHidden = true
        artboardLayer.addSublayer(gridMajorLayer)

        gridAxisLayer.strokeColor = NSColor(red: 0.35, green: 0.7, blue: 1.0, alpha: 0.5).cgColor
        gridAxisLayer.lineWidth = 1.5
        gridAxisLayer.fillColor = nil
        gridAxisLayer.isHidden = true
        artboardLayer.addSublayer(gridAxisLayer)

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
        updateCanvasContents()
        updateOverlays()
    }

    // MARK: - Drop a reference image onto the map

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImageData(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = droppedImageData(sender) else { return false }
        return coordinator?.model.addImageLayer(data: data, name: "Image") ?? false
    }

    private func droppedImageData(_ sender: NSDraggingInfo) -> Data? {
        let pasteboard = sender.draggingPasteboard
        if let data = pasteboard.data(forType: .png) { return data }
        if let data = pasteboard.data(forType: .tiff) { return data }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    func scheduleGeometryRefresh() {
        guard !geometryRefreshScheduled else { return }
        geometryRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.geometryRefreshScheduled = false
            // Orientation/resize changes alter the projected pixel bounds, so
            // recompute the artboard frame as well as the overlays.
            self?.updateArtboardGeometry()
        }
    }

    // MARK: - Coordinate helpers (finite artboard vs. infinite canvas)

    /// Map a document pixel to the coordinate space of `artboardLayer`'s
    /// sublayers. Finite maps use the artboard's local (scaled) coordinates;
    /// infinite maps use the whole view with an unbounded origin.
    private func canvasPoint(_ dx: Double, _ dy: Double, model: TileMapModel, viewSize: CGSize) -> CGPoint {
        let zoom = coordinator?.viewport.zoom ?? 1
        if model.isInfinite, let coordinator {
            let origin = coordinator.viewport.unboundedOrigin(viewSize: viewSize)
            return CGPoint(x: origin.x + CGFloat(dx) * zoom,
                           y: (viewSize.height - origin.y) + CGFloat(dy) * zoom)
        }
        return CGPoint(x: CGFloat(dx) * zoom, y: CGFloat(dy) * zoom)
    }

    /// Inverse of `canvasPoint` for infinite maps (artboard-layer point → doc px).
    private func docFromCanvas(_ point: CGPoint, viewSize: CGSize) -> (x: Double, y: Double) {
        guard let coordinator else { return (0, 0) }
        let origin = coordinator.viewport.unboundedOrigin(viewSize: viewSize)
        let zoom = coordinator.viewport.zoom
        return (Double((point.x - origin.x) / zoom),
                Double((point.y - (viewSize.height - origin.y)) / zoom))
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

        if model.isInfinite {
            // No artboard: the grid and composite fill the viewport, and the
            // document origin is free to pan anywhere.
            let full = CGRect(origin: .zero, size: bounds.size)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artboardShadowLayer.isHidden = true
            artboardShadowLayer.frame = .zero
            artboardShadowLayer.shadowPath = nil
            artboardLayer.frame = full
            borderLayer.isHidden = true
            borderLayer.frame = .zero
            checkerboardLayer.isHidden = true
            checkerboardLayer.frame = .zero
            gridMinorLayer.frame = full
            gridMajorLayer.frame = full
            gridAxisLayer.frame = full
            selectionLayer.frame = full
            objectLayer.frame = full
            ghostLayer.frame = full
            updateGrid(model: model, viewSize: bounds.size)
            CATransaction.commit()
            updateOverlays()
            return
        }

        let docW = model.map.pixelWidth
        let docH = model.map.pixelHeight

        // A projection change drastically alters the artboard bounds; refit.
        if lastOrientation != model.orientation {
            lastOrientation = model.orientation
            viewport.zoomToFit(viewSize: bounds.size, canvasWidth: docW, height: docH)
        }

        let origin = viewport.artboardOrigin(viewSize: bounds.size, canvasWidth: docW, height: docH)
        let artboardFrame = CGRect(x: origin.x, y: origin.y, width: CGFloat(docW) * viewport.zoom,
                                   height: CGFloat(docH) * viewport.zoom)
        let artboardBounds = CGRect(x: 0, y: 0, width: artboardFrame.width, height: artboardFrame.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artboardShadowLayer.isHidden = false
        artboardShadowLayer.frame = artboardFrame
        artboardShadowLayer.shadowPath = CGPath(rect: artboardBounds, transform: nil)
        artboardLayer.frame = artboardFrame
        borderLayer.isHidden = false
        borderLayer.frame = artboardBounds
        checkerboardLayer.isHidden = false
        checkerboardLayer.frame = artboardBounds
        compositeLayer.frame = artboardBounds
        gridMinorLayer.frame = artboardBounds
        gridMajorLayer.frame = artboardBounds
        gridAxisLayer.frame = artboardBounds
        selectionLayer.frame = artboardBounds
        objectLayer.frame = artboardBounds
        ghostLayer.frame = artboardBounds
        updateGrid(model: model, viewSize: bounds.size)
        CATransaction.commit()
        updateOverlays()
    }

    /// Build and install the minor/major/axis grid paths for the visible area.
    private func updateGrid(model: TileMapModel, viewSize: CGSize) {
        let zoom = coordinator?.viewport.zoom ?? 1
        let show = coordinator?.viewport.showGrid ?? true
        let cellPoints = CGFloat(model.map.cellWidth) * zoom
        guard show, cellPoints >= 5 else {
            gridMinorLayer.isHidden = true
            gridMajorLayer.isHidden = true
            gridAxisLayer.isHidden = true
            return
        }
        let (minor, major, axis) = makeGridPaths(model: model, viewSize: viewSize, zoom: zoom)
        gridMinorLayer.isHidden = false
        gridMajorLayer.isHidden = false
        gridAxisLayer.isHidden = false
        gridMinorLayer.path = minor
        gridMajorLayer.path = major
        gridAxisLayer.path = axis
    }

    private func makeGridPaths(
        model: TileMapModel,
        viewSize: CGSize,
        zoom: CGFloat
    ) -> (minor: CGPath, major: CGPath, axis: CGPath) {
        let minor = CGMutablePath()
        let major = CGMutablePath()
        let axis = CGMutablePath()
        let cellW = Double(model.map.cellWidth)
        let cellH = Double(model.map.cellHeight)
        guard cellW > 0, cellH > 0 else { return (minor, major, axis) }
        func add(_ path: CGMutablePath, _ a: CGPoint, _ b: CGPoint) {
            path.move(to: a)
            path.addLine(to: b)
        }

        if model.orientation == .orthogonal {
            let x0: Double, y0: Double, x1: Double, y1: Double
            if model.isInfinite {
                let tl = docFromCanvas(.zero, viewSize: viewSize)
                let br = docFromCanvas(CGPoint(x: viewSize.width, y: viewSize.height), viewSize: viewSize)
                x0 = min(tl.x, br.x); y0 = min(tl.y, br.y)
                x1 = max(tl.x, br.x); y1 = max(tl.y, br.y)
            } else {
                x0 = 0; y0 = 0
                x1 = Double(model.map.pixelWidth); y1 = Double(model.map.pixelHeight)
            }
            var k = Int(floor(x0 / cellW))
            let kEnd = Int(ceil(x1 / cellW))
            while k <= kEnd {
                let x = Double(k) * cellW
                let path = k == 0 ? axis : (k % 8 == 0 ? major : minor)
                add(path, canvasPoint(x, y0, model: model, viewSize: viewSize),
                    canvasPoint(x, y1, model: model, viewSize: viewSize))
                k += 1
            }
            var j = Int(floor(y0 / cellH))
            let jEnd = Int(ceil(y1 / cellH))
            while j <= jEnd {
                let y = Double(j) * cellH
                let path = j == 0 ? axis : (j % 8 == 0 ? major : minor)
                add(path, canvasPoint(x0, y, model: model, viewSize: viewSize),
                    canvasPoint(x1, y, model: model, viewSize: viewSize))
                j += 1
            }
            return (minor, major, axis)
        }

        // Isometric / staggered: outline the diamonds of the visible cells.
        var minX = 0, minY = 0, maxX = -1, maxY = -1
        if model.isInfinite {
            let corners = [
                CGPoint.zero,
                CGPoint(x: viewSize.width, y: 0),
                CGPoint(x: 0, y: viewSize.height),
                CGPoint(x: viewSize.width, y: viewSize.height),
            ]
            var a = Int.max, b = Int.max, c = Int.min, d = Int.min
            for corner in corners {
                let doc = docFromCanvas(corner, viewSize: viewSize)
                let cell = model.rawCell(atPixel: (Int(doc.x.rounded(.down)), Int(doc.y.rounded(.down))))
                a = min(a, cell.x); b = min(b, cell.y)
                c = max(c, cell.x); d = max(d, cell.y)
            }
            minX = a - 2; minY = b - 2; maxX = c + 2; maxY = d + 2
        } else {
            minX = 0; minY = 0; maxX = model.map.columns - 1; maxY = model.map.rows - 1
        }
        guard maxX >= minX, maxY >= minY,
              (maxX - minX + 1) * (maxY - minY + 1) <= 65_536 else {
            return (minor, major, axis)
        }
        let tw = CGFloat(model.map.cellWidth)
        let th = CGFloat(model.map.cellHeight)
        for cy in minY...maxY {
            for cx in minX...maxX {
                let origin = model.cellOrigin(cx, cy)
                let p = canvasPoint(Double(origin.x), Double(origin.y), model: model, viewSize: viewSize)
                let top = CGPoint(x: p.x + tw * zoom / 2, y: p.y)
                let right = CGPoint(x: p.x + tw * zoom, y: p.y + th * zoom / 2)
                let bottom = CGPoint(x: p.x + tw * zoom / 2, y: p.y + th * zoom)
                let left = CGPoint(x: p.x, y: p.y + th * zoom / 2)
                let path = (cx == 0 || cy == 0) ? axis : ((cx % 8 == 0 || cy % 8 == 0) ? major : minor)
                path.move(to: top)
                path.addLine(to: right)
                path.addLine(to: bottom)
                path.addLine(to: left)
                path.closeSubpath()
            }
        }
        return (minor, major, axis)
    }

    /// Screen path covering a rectangular cell region (diamond parallelogram for
    /// isometric/staggered maps, an axis-aligned rect otherwise).
    private func cellRegionPath(x: Int, y: Int, width: Int, height: Int, model: TileMapModel, zoom: CGFloat) -> CGPath {
        let viewSize = bounds.size
        if model.orientation == .orthogonal {
            let p = canvasPoint(Double(x) * Double(model.map.cellWidth),
                                Double(y) * Double(model.map.cellHeight),
                                model: model, viewSize: viewSize)
            return CGPath(rect: CGRect(x: p.x, y: p.y,
                                       width: CGFloat(width * model.map.cellWidth) * zoom,
                                       height: CGFloat(height * model.map.cellHeight) * zoom), transform: nil)
        }
        let tw = CGFloat(model.map.cellWidth)
        let th = CGFloat(model.map.cellHeight)
        let x1 = x + max(0, width - 1)
        let y1 = y + max(0, height - 1)
        let topLeft = model.cellOrigin(x, y)
        let topRight = model.cellOrigin(x1, y)
        let bottomRight = model.cellOrigin(x1, y1)
        let bottomLeft = model.cellOrigin(x, y1)
        func point(_ origin: (x: Int, y: Int), _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            let p = canvasPoint(Double(origin.x), Double(origin.y), model: model, viewSize: viewSize)
            return CGPoint(x: p.x + dx * zoom, y: p.y + dy * zoom)
        }
        let path = CGMutablePath()
        path.move(to: point(topLeft, tw / 2, 0))
        path.addLine(to: point(topRight, tw, th / 2))
        path.addLine(to: point(bottomRight, tw / 2, th))
        path.addLine(to: point(bottomLeft, 0, th / 2))
        path.closeSubpath()
        return path
    }

    func updateCanvasContents() {
        guard !isUpdatingContents else { return }
        isUpdatingContents = true
        defer { isUpdatingContents = false }
        guard let coordinator else { return }
        let model = coordinator.model

        if model.isInfinite {
            renderInfiniteRegion(model: model)
            return
        }

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

    /// Composite only the visible region of an infinite map and position it.
    private func renderInfiniteRegion(model: TileMapModel) {
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0, let coordinator else { return }
        let zoom = coordinator.viewport.zoom
        let tl = docFromCanvas(.zero, viewSize: viewSize)
        let br = docFromCanvas(CGPoint(x: viewSize.width, y: viewSize.height), viewSize: viewSize)
        let margin = Double(max(model.map.cellWidth, model.map.cellHeight)) * 2 + 64
        let x0 = Int((min(tl.x, br.x) - margin).rounded(.down))
        let y0 = Int((min(tl.y, br.y) - margin).rounded(.down))
        let x1 = Int((max(tl.x, br.x) + margin).rounded(.up))
        let y1 = Int((max(tl.y, br.y) + margin).rounded(.up))
        let w = max(1, x1 - x0)
        let h = max(1, y1 - y0)
        // Guard against compositing an enormous region when zoomed far out.
        guard w * h <= 8_000_000 else {
            compositeLayer.contents = nil
            return
        }
        let rgba = model.map.compositeRegionRGBA(x: x0, y: y0, w: w, h: h)
        guard !rgba.isEmpty, let cg = makeCGImage(pixels: rgba, width: w, height: h) else {
            compositeLayer.contents = nil
            return
        }
        let p = canvasPoint(Double(x0), Double(y0), model: model, viewSize: viewSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        compositeLayer.frame = CGRect(x: p.x, y: p.y, width: CGFloat(w) * zoom, height: CGFloat(h) * zoom)
        compositeLayer.contents = cg
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
            selectionLayer.path = cellRegionPath(x: rect.x, y: rect.y,
                                                 width: rect.width, height: rect.height,
                                                 model: model, zoom: zoom)
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
            let viewSize = bounds.size
            for obj in model.map.objects(layer: model.activeLayer) {
                let isSel = obj.id == selected
                let p = canvasPoint(obj.x, obj.y, model: model, viewSize: viewSize)
                let scaled = CGRect(x: p.x, y: p.y,
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
        let ghostCell: (x: Int, y: Int)? = {
            guard let hover = model.hoverPixel else { return nil }
            return model.isInfinite ? model.rawCell(atPixel: hover) : model.cell(atPixel: hover, clamp: true)
        }()
        if (showBrush || showPaste), model.activeIsTile, let cell = ghostCell {
            ghostLayer.isHidden = false
            ghostLayer.path = cellRegionPath(x: cell.x, y: cell.y,
                                             width: model.brush.pattern.width,
                                             height: model.brush.pattern.height,
                                             model: model, zoom: zoom)
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
            if model.isInfinite {
                overArtboard = true
            } else {
                overArtboard = coordinator.viewport.viewToDoc(point, viewSize: bounds.size,
                                                              width: model.map.pixelWidth,
                                                              height: model.map.pixelHeight) != nil
            }
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
        if coordinator.model.isInfinite {
            let doc = coordinator.viewport.viewToDocF(point, viewSize: bounds.size)
            coordinator.hover(at: (Int(doc.x.rounded(.down)), Int(doc.y.rounded(.down))))
        } else {
            let pixel = coordinator.viewport.viewToDoc(point, viewSize: bounds.size,
                                                       width: coordinator.model.map.pixelWidth,
                                                       height: coordinator.model.map.pixelHeight, clamp: true)
            coordinator.hover(at: pixel)
        }
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
        if event.keyCode == 36, model.hasPasteGhost, let hover = model.hoverPixel {
            let cell = model.isInfinite ? model.rawCell(atPixel: hover) : model.cell(atPixel: hover, clamp: true)
            if let cell {
                model.commitPaste(at: cell.x, y: cell.y)
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
