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
            guard let cell = cellCoordinate(point, in: view) else { return }
            model.beginStroke(x: cell.x, y: cell.y)
        }

        func drag(at point: CGPoint, in view: UIView) {
            guard let cell = cellCoordinate(point, in: view, clamp: true) else { return }
            model.continueStroke(x: cell.x, y: cell.y)
        }

        func end(at point: CGPoint, in view: UIView) {
            guard let cell = cellCoordinate(point, in: view, clamp: true) else { return }
            model.endStroke(x: cell.x, y: cell.y)
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
    private let overlayLayer = CAShapeLayer()

    // Geometry caches
    private var isUpdatingGeometry = false
    private var isUpdatingContents = false
    private var geometryRefreshScheduled = false

    // Gestures
    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var panRecognizer: UIPanGestureRecognizer!

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
        overlayLayer.frame = localFrame

        updateCellGrid()
        CATransaction.commit()
    }

    func updateCanvasContents() {
        guard !isUpdatingContents, let coordinator else { return }
        isUpdatingContents = true
        defer { isUpdatingContents = false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let cgImage = coordinator.model.compositeCGImage() {
            wholeMapLayer.contents = cgImage
        }

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
    }

    private func updateCellGrid() {
        guard let coordinator else { return }
        let model = coordinator.model
        let viewport = coordinator.viewport
        let zoom = viewport.zoom

        guard viewport.showGrid, zoom >= 2.0 else {
            cellGridLayer.isHidden = true
            return
        }

        let tw = CGFloat(model.map.cellWidth) * zoom
        let th = CGFloat(model.map.cellHeight) * zoom
        guard tw > 0, th > 0 else { return }

        let totalW = CGFloat(model.map.pixelWidth) * zoom
        let totalH = CGFloat(model.map.pixelHeight) * zoom

        let path = CGMutablePath()
        for x in Swift.stride(from: tw, to: totalW, by: tw) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: totalH))
        }
        for y in Swift.stride(from: th, to: totalH, by: th) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: totalW, y: y))
        }

        cellGridLayer.path = path
        cellGridLayer.isHidden = false
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.count == 1, let touch = touches.first, let coordinator else { return }
        coordinator.begin(at: touch.location(in: self), in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.count == 1, let touch = touches.first, let coordinator else { return }
        coordinator.drag(at: touch.location(in: self), in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let coordinator else { return }
        coordinator.end(at: touch.location(in: self), in: self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let coordinator else { return }
        coordinator.end(at: touch.location(in: self), in: self)
    }
}
#endif
