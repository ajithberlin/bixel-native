// TileMapCanvasView.iOS.swift
//
// CALayer-backed infinite canvas for the Tilemap Designer on iPadOS / iOS.
// Supports multi-touch pan & pinch-zoom, Apple Pencil and touch tile painting,
// cell grid, selection marquee, and real-time chunked map compositing.

#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore
import Combine

struct TileMapCanvasView: UIViewRepresentable {
    @ObservedObject var model: TileMapModel
    @ObservedObject var viewport: CanvasViewport

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, viewport: viewport)
    }

    func makeUIView(context: Context) -> MapCanvasUIView {
        let view = MapCanvasUIView()
        view.coordinator = context.coordinator
        context.coordinator.connect(view)
        return view
    }

    func updateUIView(_ view: MapCanvasUIView, context: Context) {
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

        func connect(_ view: MapCanvasUIView) {
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

        func cellCoordinate(_ point: CGPoint, in view: UIView, clamp: Bool = false) -> (x: Int, y: Int)? {
            let viewSize = view.bounds.size
            guard viewSize.width > 0, viewSize.height > 0 else { return nil }

            if model.isInfinite {
                let originX = (viewSize.width - viewport.rightInset) / 2 + viewport.pan.x
                let originY = viewSize.height / 2 - viewport.pan.y
                let docX = (point.x - originX) / viewport.zoom
                let docY = (point.y - originY) / viewport.zoom
                return model.rawCell(atPixel: (Int(floor(docX)), Int(floor(docY))))
            }

            let mapW = model.map.pixelWidth
            let mapH = model.map.pixelHeight
            guard mapW > 0, mapH > 0 else { return nil }

            let appKitOrigin = viewport.artboardOrigin(viewSize: viewSize, canvasWidth: mapW, height: mapH)
            let scaledW = CGFloat(mapW) * viewport.zoom
            let scaledH = CGFloat(mapH) * viewport.zoom
            let artboardTopLeftX = appKitOrigin.x
            let artboardTopLeftY = viewSize.height - (appKitOrigin.y + scaledH)

            let px = Int(floor((point.x - artboardTopLeftX) / viewport.zoom))
            let py = Int(floor((point.y - artboardTopLeftY) / viewport.zoom))

            let pixel: (x: Int, y: Int)
            if clamp {
                pixel = (min(max(px, 0), mapW - 1), min(max(py, 0), mapH - 1))
            } else {
                guard px >= 0, px < mapW, py >= 0, py < mapH else { return nil }
                pixel = (px, py)
            }
            return model.cell(atPixel: pixel, clamp: clamp)
        }

        func begin(at point: CGPoint, in view: UIView) {
            if (model.tool == .move || model.tool == .select),
               let pixel = documentPoint(point, in: view),
               model.beginImageTransform(at: pixel, zoom: viewport.zoom,
                                         preserveAspect: !model.imageFreeformResize) {
                return
            }
            guard let cell = cellCoordinate(point, in: view) else { return }
            model.beginStroke(x: cell.x, y: cell.y)
        }

        func drag(at point: CGPoint, in view: UIView) {
            if model.isTransformingImage, let pixel = documentPoint(point, in: view) {
                model.continueImageTransform(to: pixel)
                return
            }
            guard let cell = cellCoordinate(point, in: view, clamp: true) else { return }
            model.continueStroke(x: cell.x, y: cell.y)
        }

        func end(at point: CGPoint, in view: UIView) {
            if model.isTransformingImage {
                model.endImageTransform()
                return
            }
            guard let cell = cellCoordinate(point, in: view, clamp: true) else { return }
            model.endStroke(x: cell.x, y: cell.y)
        }

        private func documentPoint(_ point: CGPoint, in view: UIView) -> CGPoint? {
            let viewSize = view.bounds.size
            guard viewSize.width > 0, viewSize.height > 0 else { return nil }
            if model.isInfinite {
                let originX = (viewSize.width - viewport.rightInset) / 2 + viewport.pan.x
                let originY = viewSize.height / 2 - viewport.pan.y
                return CGPoint(x: (point.x - originX) / viewport.zoom,
                               y: (point.y - originY) / viewport.zoom)
            }
            let mapW = CGFloat(model.map.pixelWidth)
            let mapH = CGFloat(model.map.pixelHeight)
            let appKitOrigin = viewport.artboardOrigin(viewSize: viewSize,
                                                       canvasWidth: Int(mapW), height: Int(mapH))
            let topLeftX = appKitOrigin.x
            let topLeftY = viewSize.height - (appKitOrigin.y + mapH * viewport.zoom)
            return CGPoint(x: (point.x - topLeftX) / viewport.zoom,
                           y: (point.y - topLeftY) / viewport.zoom)
        }
    }
}

final class MapCanvasUIView: UIView, UIGestureRecognizerDelegate {
    weak var coordinator: TileMapCanvasView.Coordinator?

    static let workspaceBaseColor = UIColor(red: 26.0 / 255.0,
                                            green: 28.0 / 255.0,
                                            blue: 32.0 / 255.0,
                                            alpha: 1.0)

    // Layers
    private let artboardShadowLayer = CALayer()
    private let artboardLayer = CALayer()
    private let checkerboardLayer = CALayer()
    private let wholeMapLayer = CALayer()
    private let cellGridLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let imageTransformLayer = CAShapeLayer()
    private let overlayLayer = CAShapeLayer()

    // Geometry caches
    private var isUpdatingGeometry = false
    private var isUpdatingContents = false
    private var geometryRefreshScheduled = false

    // Gestures
    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var panRecognizer: UIPanGestureRecognizer!
    private var twoFingerTapRecognizer: UITapGestureRecognizer!
    private var threeFingerTapRecognizer: UITapGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private static let checkerboardPatternColor: CGColor = {
        let size = CGSize(width: 16, height: 16)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(white: 0.22, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.16, alpha: 1.0).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            ctx.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        }
        return UIColor(patternImage: image).cgColor
    }()

    private func setup() {
        isMultipleTouchEnabled = true
        backgroundColor = Self.workspaceBaseColor
        layer.masksToBounds = true

        // Shadow
        artboardShadowLayer.shadowColor = UIColor.black.cgColor
        artboardShadowLayer.shadowOpacity = 0.55
        artboardShadowLayer.shadowRadius = 18
        artboardShadowLayer.shadowOffset = CGSize(width: 0, height: -2)
        artboardShadowLayer.backgroundColor = UIColor(white: 0.08, alpha: 1.0).cgColor
        layer.addSublayer(artboardShadowLayer)

        // Artboard
        artboardLayer.masksToBounds = false
        layer.addSublayer(artboardLayer)

        // Checkerboard
        checkerboardLayer.backgroundColor = Self.checkerboardPatternColor
        artboardLayer.addSublayer(checkerboardLayer)

        // Whole map composite
        wholeMapLayer.magnificationFilter = .nearest
        wholeMapLayer.minificationFilter = .nearest
        artboardLayer.addSublayer(wholeMapLayer)

        // Grid
        cellGridLayer.strokeColor = UIColor(white: 1.0, alpha: 0.14).cgColor
        cellGridLayer.lineWidth = 1.0
        cellGridLayer.fillColor = nil
        cellGridLayer.isHidden = true
        artboardLayer.addSublayer(cellGridLayer)

        // Selection
        selectionLayer.strokeColor = UIColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.95).cgColor
        selectionLayer.lineWidth = 1.0
        selectionLayer.fillColor = nil
        selectionLayer.lineDashPattern = [4, 4]
        selectionLayer.isHidden = true
        artboardLayer.addSublayer(selectionLayer)

        imageTransformLayer.strokeColor = UIColor.systemBlue.cgColor
        imageTransformLayer.lineWidth = 1.5
        imageTransformLayer.lineDashPattern = [5, 3]
        imageTransformLayer.fillColor = nil
        imageTransformLayer.isHidden = true
        artboardLayer.addSublayer(imageTransformLayer)

        // Overlays
        overlayLayer.fillColor = nil
        artboardLayer.addSublayer(overlayLayer)

        // Two-finger Pan
        panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panRecognizer.minimumNumberOfTouches = 2
        panRecognizer.maximumNumberOfTouches = 2
        panRecognizer.delegate = self
        addGestureRecognizer(panRecognizer)

        // Pinch Zoom
        pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchRecognizer.delegate = self
        addGestureRecognizer(pinchRecognizer)

        // Two-finger Tap: Undo
        twoFingerTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTapRecognizer.numberOfTouchesRequired = 2
        twoFingerTapRecognizer.numberOfTapsRequired = 1
        twoFingerTapRecognizer.delegate = self
        addGestureRecognizer(twoFingerTapRecognizer)

        // Three-finger Tap: Redo
        threeFingerTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTapRecognizer.numberOfTouchesRequired = 3
        threeFingerTapRecognizer.numberOfTapsRequired = 1
        threeFingerTapRecognizer.delegate = self
        addGestureRecognizer(threeFingerTapRecognizer)

        twoFingerTapRecognizer.require(toFail: threeFingerTapRecognizer)
        panRecognizer.require(toFail: twoFingerTapRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateArtboardGeometry()
    }

    func scheduleGeometryRefresh() {
        guard !geometryRefreshScheduled else { return }
        geometryRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryRefreshScheduled = false
            self.updateArtboardGeometry()
            self.updateCanvasContents()
        }
    }

    func updateArtboardGeometry() {
        guard !isUpdatingGeometry, let coordinator else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }

        let model = coordinator.model
        let viewport = coordinator.viewport
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        if model.isInfinite {
            let full = CGRect(origin: .zero, size: viewSize)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artboardShadowLayer.isHidden = true
            artboardShadowLayer.frame = .zero
            artboardLayer.frame = full
            checkerboardLayer.isHidden = true
            checkerboardLayer.frame = .zero
            wholeMapLayer.frame = full
            cellGridLayer.frame = full
            selectionLayer.frame = full
            imageTransformLayer.frame = full
            overlayLayer.frame = full
            updateCellGrid()
            CATransaction.commit()
            return
        }

        let mapW = CGFloat(model.map.pixelWidth)
        let mapH = CGFloat(model.map.pixelHeight)
        let appKitOrigin = viewport.artboardOrigin(viewSize: viewSize,
                                                   canvasWidth: Int(mapW),
                                                   height: Int(mapH))
        let scaledW = mapW * viewport.zoom
        let scaledH = mapH * viewport.zoom

        let artboardTopLeftX = appKitOrigin.x
        let artboardTopLeftY = viewSize.height - (appKitOrigin.y + scaledH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let artboardFrame = CGRect(x: artboardTopLeftX, y: artboardTopLeftY, width: scaledW, height: scaledH)
        artboardLayer.frame = artboardFrame
        artboardShadowLayer.frame = artboardFrame

        let localFrame = CGRect(x: 0, y: 0, width: scaledW, height: scaledH)
        checkerboardLayer.frame = localFrame
        wholeMapLayer.frame = localFrame
        cellGridLayer.frame = localFrame
        selectionLayer.frame = localFrame
        imageTransformLayer.frame = localFrame
        overlayLayer.frame = localFrame

        updateCellGrid()
        CATransaction.commit()
    }

    func updateCanvasContents() {
        guard !isUpdatingContents, let coordinator else { return }
        isUpdatingContents = true
        defer { isUpdatingContents = false }

        if coordinator.model.isInfinite {
            renderInfiniteRegion(model: coordinator.model)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let cgImage = coordinator.model.compositeCGImage() {
            wholeMapLayer.contents = cgImage
        }

        CATransaction.commit()
    }

    // MARK: - Infinite-map geometry and rendering

    /// Map a world pixel to the coordinate space of the canvas layers.
    private func canvasPoint(_ dx: Double, _ dy: Double, model: TileMapModel, viewSize: CGSize) -> CGPoint {
        let zoom = coordinator?.viewport.zoom ?? 1
        if model.isInfinite, let coordinator {
            let origin = coordinator.viewport.unboundedOrigin(viewSize: viewSize)
            return CGPoint(x: origin.x + CGFloat(dx) * zoom,
                           y: (viewSize.height - origin.y) + CGFloat(dy) * zoom)
        }
        return CGPoint(x: CGFloat(dx) * zoom, y: CGFloat(dy) * zoom)
    }

    /// Convert a canvas-layer point back to world-pixel coordinates.
    private func docFromCanvas(_ point: CGPoint, viewSize: CGSize) -> (x: Double, y: Double) {
        guard let coordinator else { return (0, 0) }
        let origin = coordinator.viewport.unboundedOrigin(viewSize: viewSize)
        let zoom = coordinator.viewport.zoom
        return (Double((point.x - origin.x) / zoom),
                Double((point.y - (viewSize.height - origin.y)) / zoom))
    }

    /// Composite just beyond the visible world region so panning does not show
    /// a seam at the edge of the current image.
    private func renderInfiniteRegion(model: TileMapModel) {
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0, let coordinator else { return }
        let zoom = coordinator.viewport.zoom
        let topLeft = docFromCanvas(.zero, viewSize: viewSize)
        let bottomRight = docFromCanvas(CGPoint(x: viewSize.width, y: viewSize.height), viewSize: viewSize)
        let margin = Double(max(model.map.cellWidth, model.map.cellHeight)) * 2 + 64
        let x0 = Int((min(topLeft.x, bottomRight.x) - margin).rounded(.down))
        let y0 = Int((min(topLeft.y, bottomRight.y) - margin).rounded(.down))
        let x1 = Int((max(topLeft.x, bottomRight.x) + margin).rounded(.up))
        let y1 = Int((max(topLeft.y, bottomRight.y) + margin).rounded(.up))
        let width = max(1, x1 - x0)
        let height = max(1, y1 - y0)

        guard width * height <= 8_000_000 else {
            wholeMapLayer.contents = nil
            return
        }
        let rgba = model.map.compositeRegionRGBA(x: x0, y: y0, w: width, h: height)
        guard !rgba.isEmpty,
              let cgImage = makeCGImage(pixels: rgba, width: width, height: height) else {
            wholeMapLayer.contents = nil
            return
        }

        let origin = canvasPoint(Double(x0), Double(y0), model: model, viewSize: viewSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wholeMapLayer.frame = CGRect(x: origin.x, y: origin.y,
                                     width: CGFloat(width) * zoom,
                                     height: CGFloat(height) * zoom)
        wholeMapLayer.contents = cgImage
        CATransaction.commit()
    }

    func updateOverlays() {
        guard let coordinator else { return }
        let model = coordinator.model
        let zoom = coordinator.viewport.zoom

        if let sel = model.selection {
            let rect = CGRect(
                x: CGFloat(sel.x * model.map.cellWidth) * zoom,
                y: CGFloat(sel.y * model.map.cellHeight) * zoom,
                width: CGFloat(sel.width * model.map.cellWidth) * zoom,
                height: CGFloat(sel.height * model.map.cellHeight) * zoom
            )
            let path = CGMutablePath()
            path.addRect(rect)
            selectionLayer.path = path
            selectionLayer.isHidden = false
        } else {
            selectionLayer.isHidden = true
            selectionLayer.path = nil
        }

        if model.activeIsImage, let frame = model.imageLayerFrame(model.activeLayer) {
            imageTransformLayer.isHidden = false
            let p = canvasPoint(frame.minX, frame.minY, model: model, viewSize: bounds.size)
            let rect = CGRect(x: p.x, y: p.y,
                              width: frame.width * zoom, height: frame.height * zoom)
            let path = CGMutablePath()
            path.addRect(rect)
            let size: CGFloat = 8
            for handle in [rect.origin,
                           CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY),
                           CGPoint(x: rect.maxX, y: rect.maxY)] {
                path.addRect(CGRect(x: handle.x - size / 2, y: handle.y - size / 2,
                                    width: size, height: size))
            }
            imageTransformLayer.path = path
        } else {
            imageTransformLayer.isHidden = true
            imageTransformLayer.path = nil
        }
    }

    private func updateCellGrid() {
        guard let coordinator else { return }
        let model = coordinator.model
        let viewport = coordinator.viewport
        let zoom = viewport.zoom

        let cellPoints = CGFloat(model.map.cellWidth) * zoom
        guard viewport.showGrid, cellPoints >= 5 else {
            cellGridLayer.isHidden = true
            return
        }

        let path = makeGridPath(model: model, viewSize: bounds.size, zoom: zoom)
        guard !path.isEmpty else {
            cellGridLayer.isHidden = true
            return
        }
        cellGridLayer.path = path
        cellGridLayer.isHidden = false
    }

    /// Build visible grid geometry for finite and infinite scenes. Infinite
    /// scenes cannot use `pixelWidth`/`pixelHeight`, because those are zero for
    /// an empty scene and only cover stored content after painting.
    private func makeGridPath(model: TileMapModel, viewSize: CGSize, zoom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let cellW = Double(model.map.cellWidth)
        let cellH = Double(model.map.cellHeight)
        guard cellW > 0, cellH > 0 else { return path }

        func add(_ a: CGPoint, _ b: CGPoint) {
            path.move(to: a)
            path.addLine(to: b)
        }

        if model.orientation == .orthogonal {
            let x0: Double, y0: Double, x1: Double, y1: Double
            if model.isInfinite {
                let topLeft = docFromCanvas(.zero, viewSize: viewSize)
                let bottomRight = docFromCanvas(CGPoint(x: viewSize.width, y: viewSize.height), viewSize: viewSize)
                x0 = min(topLeft.x, bottomRight.x)
                y0 = min(topLeft.y, bottomRight.y)
                x1 = max(topLeft.x, bottomRight.x)
                y1 = max(topLeft.y, bottomRight.y)
            } else {
                x0 = 0
                y0 = 0
                x1 = Double(model.map.pixelWidth)
                y1 = Double(model.map.pixelHeight)
            }

            let verticalStart: CGFloat = model.isInfinite ? 0 : 0
            let verticalEnd: CGFloat = model.isInfinite
                ? viewSize.height
                : CGFloat(model.map.pixelHeight) * zoom
            let horizontalStart: CGFloat = model.isInfinite ? 0 : 0
            let horizontalEnd: CGFloat = model.isInfinite
                ? viewSize.width
                : CGFloat(model.map.pixelWidth) * zoom

            var column = Int(floor(x0 / cellW))
            let lastColumn = Int(ceil(x1 / cellW))
            while column <= lastColumn {
                let worldX = Double(column) * cellW
                let screenX = canvasPoint(worldX, 0, model: model, viewSize: viewSize).x
                add(CGPoint(x: screenX, y: verticalStart),
                    CGPoint(x: screenX, y: verticalEnd))
                column += 1
            }

            var row = Int(floor(y0 / cellH))
            let lastRow = Int(ceil(y1 / cellH))
            while row <= lastRow {
                let worldY = Double(row) * cellH
                let screenY = canvasPoint(0, worldY, model: model, viewSize: viewSize).y
                add(CGPoint(x: horizontalStart, y: screenY),
                    CGPoint(x: horizontalEnd, y: screenY))
                row += 1
            }
            return path
        }

        // Isometric/staggered cells are projected diamonds/parallelograms. Only
        // generate the cells that can be visible, with a small edge margin.
        var minX = 0, minY = 0, maxX = -1, maxY = -1
        if model.isInfinite {
            let corners = [
                CGPoint.zero,
                CGPoint(x: viewSize.width, y: 0),
                CGPoint(x: 0, y: viewSize.height),
                CGPoint(x: viewSize.width, y: viewSize.height),
            ]
            var left = Int.max, top = Int.max, right = Int.min, bottom = Int.min
            for corner in corners {
                let doc = docFromCanvas(corner, viewSize: viewSize)
                let cell = model.rawCell(atPixel: (Int(floor(doc.x)), Int(floor(doc.y))))
                left = min(left, cell.x)
                top = min(top, cell.y)
                right = max(right, cell.x)
                bottom = max(bottom, cell.y)
            }
            minX = left - 2
            minY = top - 2
            maxX = right + 2
            maxY = bottom + 2
        } else {
            minX = 0
            minY = 0
            maxX = model.map.columns - 1
            maxY = model.map.rows - 1
        }

        guard maxX >= minX, maxY >= minY,
              (maxX - minX + 1) * (maxY - minY + 1) <= 65_536 else {
            return path
        }

        let tw = CGFloat(model.map.cellWidth)
        let th = CGFloat(model.map.cellHeight)
        for cy in minY...maxY {
            for cx in minX...maxX {
                let origin = model.cellOrigin(cx, cy)
                let point = canvasPoint(Double(origin.x), Double(origin.y),
                                        model: model, viewSize: viewSize)
                let top = CGPoint(x: point.x + tw * zoom / 2, y: point.y)
                let right = CGPoint(x: point.x + tw * zoom, y: point.y + th * zoom / 2)
                let bottom = CGPoint(x: point.x + tw * zoom / 2, y: point.y + th * zoom)
                let left = CGPoint(x: point.x, y: point.y + th * zoom / 2)
                path.move(to: top)
                path.addLine(to: right)
                path.addLine(to: bottom)
                path.addLine(to: left)
                path.closeSubpath()
            }
        }
        return path
    }

    // MARK: - Gestures

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let coordinator else { return }
        let translation = pan.translation(in: self)
        coordinator.viewport.panBy(dx: translation.x, dy: -translation.y)
        pan.setTranslation(.zero, in: self)
        updateArtboardGeometry()
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard let coordinator else { return }
        if pinch.state == .began || pinch.state == .changed {
            let center = pinch.location(in: self)
            let appKitAnchor = CGPoint(x: center.x, y: bounds.height - center.y)
            coordinator.viewport.zoomBy(
                pinch.scale,
                anchor: appKitAnchor,
                viewSize: bounds.size
            )
            pinch.scale = 1.0
            updateArtboardGeometry()
        }
    }

    @objc private func handleTwoFingerTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let coordinator else { return }
        coordinator.model.undo()
        triggerHapticFeedback()
    }

    @objc private func handleThreeFingerTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let coordinator else { return }
        coordinator.model.redo()
        triggerHapticFeedback()
    }

    private func triggerHapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        NotificationCenter.default.post(name: .studioDismissPopovers, object: nil)
        guard let coordinator else { return }
        if (event?.allTouches?.count ?? 0) > 1 { return }
        guard touches.count == 1, let touch = touches.first else { return }
        coordinator.begin(at: touch.location(in: self), in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let coordinator else { return }
        if (event?.allTouches?.count ?? 0) > 1 { return }
        guard touches.count == 1, let touch = touches.first else { return }
        coordinator.drag(at: touch.location(in: self), in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let coordinator else { return }
        guard (event?.allTouches?.count ?? 0) <= 1, let touch = touches.first else { return }
        coordinator.end(at: touch.location(in: self), in: self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Multi-touch cancellation does not commit stray tile edits
    }
}
#endif
