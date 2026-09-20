// CanvasView.iOS.swift
//
// High-performance Core Animation (CALayer) infinite canvas for iPadOS / iOS.
// Supports multi-touch pan & pinch-zoom, Apple Pencil and touch pixel drawing,
// nearest-neighbour pixel-art rendering, pixel grid, onion skinning, and selections.

#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore
import Combine

struct CanvasView: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, viewport: viewport)
    }

    func makeUIView(context: Context) -> PixelCanvasUIView {
        let view = PixelCanvasUIView()
        view.coordinator = context.coordinator
        context.coordinator.connect(view)
        return view
    }

    func updateUIView(_ view: PixelCanvasUIView, context: Context) {
        context.coordinator.model = model
        context.coordinator.viewport = viewport
        view.updateArtboardGeometry()
        view.updateCanvasContents()
    }

    final class Coordinator: NSObject {
        var model: EditorModel
        var viewport: CanvasViewport
        private var observations: [AnyCancellable] = []

        init(model: EditorModel, viewport: CanvasViewport) {
            self.model = model
            self.viewport = viewport
        }

        func connect(_ view: PixelCanvasUIView) {
            model.canvasChanged.sink { [weak view] in
                view?.updateCanvasContents()
            }.store(in: &observations)

            model.objectWillChange.sink { [weak view] in
                view?.scheduleGeometryRefresh()
            }.store(in: &observations)

            viewport.objectWillChange.sink { [weak view] in
                // @Published emits objectWillChange before the new value is
                // stored. Defer the refresh so onion settings are read after
                // the toggle/slider mutation has completed.
                view?.scheduleGeometryRefresh()
            }.store(in: &observations)
        }

        func pixelCoordinate(_ point: CGPoint, in view: UIView, clamp: Bool = false) -> (x: Int, y: Int)? {
            let viewSize = view.bounds.size
            guard viewSize.width > 0, viewSize.height > 0, model.width > 0, model.height > 0 else { return nil }

            let appKitOrigin = viewport.artboardOrigin(viewSize: viewSize, canvasWidth: model.width, height: model.height)
            let scaledW = CGFloat(model.width) * viewport.zoom
            let scaledH = CGFloat(model.height) * viewport.zoom
            let artboardTopLeftX = appKitOrigin.x
            let artboardTopLeftY = viewSize.height - (appKitOrigin.y + scaledH)

            let px = Int(floor((point.x - artboardTopLeftX) / viewport.zoom))
            let py = Int(floor((point.y - artboardTopLeftY) / viewport.zoom))

            if clamp {
                return (min(max(px, 0), model.width - 1), min(max(py, 0), model.height - 1))
            }
            guard px >= 0, px < model.width, py >= 0, py < model.height else { return nil }
            return (px, py)
        }

        func documentPoint(_ point: CGPoint, in view: UIView) -> CGPoint {
            let viewSize = view.bounds.size
            let appKitOrigin = viewport.artboardOrigin(viewSize: viewSize, canvasWidth: model.width, height: model.height)
            let scaledH = CGFloat(model.height) * viewport.zoom
            let artboardTopLeftX = appKitOrigin.x
            let artboardTopLeftY = viewSize.height - (appKitOrigin.y + scaledH)
            return CGPoint(
                x: (point.x - artboardTopLeftX) / viewport.zoom,
                y: (point.y - artboardTopLeftY) / viewport.zoom
            )
        }
    }
}

final class PixelCanvasUIView: UIView, UIGestureRecognizerDelegate {
    weak var coordinator: CanvasView.Coordinator?

    static let workspaceBaseColor = UIColor(red: 32.0 / 255.0,
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
    /// Procreate-style outline shown while a palette color is dragged in.
    private let colorDropHighlightLayer = CAShapeLayer()
    private let workspaceDimLayer = CAShapeLayer()
    private let floatingImageLayer = CALayer()
    private let floatingOutlineLayer = CAShapeLayer()
    private let floatingHandlesLayer = CAShapeLayer()
    private let floatingRotationLayer = CAShapeLayer()

    // Redraw cache
    private var didDrawContent = false
    private var lastDrawnRevision = -1
    private var lastOnionState: OnionSkinRenderState?
    private var isUpdatingGeometry = false
    private var isUpdatingContents = false
    private var geometryRefreshScheduled = false

    // Grid cache
    private var lastGridZoom: CGFloat = -1
    private var lastGridWidth = -1
    private var lastGridHeight = -1
    private var lastGridStride = -1

    // Gestures
    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var panRecognizer: UIPanGestureRecognizer!
    private var twoFingerTapRecognizer: UITapGestureRecognizer!
    private var threeFingerTapRecognizer: UITapGestureRecognizer!
    private var longPressRecognizer: UILongPressGestureRecognizer!
    private var isLongPressEyedropper = false
    private let hudLabel = UILabel()

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
            UIColor(white: 0.55, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.40, alpha: 1.0).setFill()
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
        artboardShadowLayer.shadowOpacity = 0.45
        artboardShadowLayer.shadowRadius = 14
        artboardShadowLayer.shadowOffset = CGSize(width: 0, height: -2)
        artboardShadowLayer.backgroundColor = UIColor(white: 0.08, alpha: 1.0).cgColor
        layer.addSublayer(artboardShadowLayer)

        // Artboard
        artboardLayer.masksToBounds = false
        layer.addSublayer(artboardLayer)

        // Sublayers
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

        canvasImageLayer.magnificationFilter = .nearest
        canvasImageLayer.minificationFilter = .nearest
        artboardLayer.addSublayer(canvasImageLayer)

        pixelGridLayer.strokeColor = UIColor(white: 1.0, alpha: 0.16).cgColor
        pixelGridLayer.lineWidth = 1.0
        pixelGridLayer.fillColor = nil
        pixelGridLayer.isHidden = true
        artboardLayer.addSublayer(pixelGridLayer)

        selectionLayer.strokeColor = UIColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.95).cgColor
        selectionLayer.lineWidth = 1.0
        selectionLayer.fillColor = nil
        selectionLayer.lineDashPattern = [4, 4]
        selectionLayer.isHidden = true
        artboardLayer.addSublayer(selectionLayer)

        borderLayer.borderColor = UIColor(white: 1.0, alpha: 0.20).cgColor
        borderLayer.borderWidth = 1.0
        artboardLayer.addSublayer(borderLayer)

        colorDropHighlightLayer.fillColor = UIColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.12).cgColor
        colorDropHighlightLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        colorDropHighlightLayer.lineWidth = 2.0
        colorDropHighlightLayer.lineDashPattern = [7, 5]
        colorDropHighlightLayer.isHidden = true
        artboardLayer.addSublayer(colorDropHighlightLayer)

        // Procreate-style ColorDrop: flood-fill the connected region beneath
        // the palette color's drop point.
        addInteraction(UIDropInteraction(delegate: self))

        workspaceDimLayer.fillColor = UIColor.black.cgColor
        workspaceDimLayer.fillRule = .evenOdd
        workspaceDimLayer.opacity = Float(Self.workspaceDimAlpha)
        workspaceDimLayer.isHidden = true
        layer.addSublayer(workspaceDimLayer)

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

        // Long-press: Procreate-style canvas color pick with magnifying loupe.
        // Touches keep flowing so we can abort the in-flight pencil dot ourselves
        // and ignore further stroke movement while the loupe is active.
        longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressRecognizer.minimumPressDuration = 0.28
        longPressRecognizer.numberOfTouchesRequired = 1
        longPressRecognizer.cancelsTouchesInView = false
        longPressRecognizer.delegate = self
        addGestureRecognizer(longPressRecognizer)

        twoFingerTapRecognizer.require(toFail: threeFingerTapRecognizer)
        panRecognizer.require(toFail: twoFingerTapRecognizer)

        setupHUD()
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

    // MARK: - Geometry Updates

    func updateArtboardGeometry() {
        guard !isUpdatingGeometry, let coordinator else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }

        let model = coordinator.model
        let viewport = coordinator.viewport
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let appKitOrigin = viewport.artboardOrigin(viewSize: viewSize,
                                                   canvasWidth: model.width,
                                                   height: model.height)
        let scaledW = CGFloat(model.width) * viewport.zoom
        let scaledH = CGFloat(model.height) * viewport.zoom

        let artboardTopLeftX = appKitOrigin.x
        let artboardTopLeftY = viewSize.height - (appKitOrigin.y + scaledH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let artboardFrame = CGRect(x: artboardTopLeftX, y: artboardTopLeftY, width: scaledW, height: scaledH)
        artboardLayer.frame = artboardFrame
        artboardShadowLayer.frame = artboardFrame

        let localFrame = CGRect(x: 0, y: 0, width: scaledW, height: scaledH)
        checkerboardLayer.frame = localFrame
        for layer in onionLayers {
            layer.frame = localFrame
        }
        canvasImageLayer.frame = localFrame
        borderLayer.frame = localFrame
        colorDropHighlightLayer.frame = localFrame
        colorDropHighlightLayer.path = CGPath(rect: localFrame.insetBy(dx: 1, dy: 1), transform: nil)
        pixelGridLayer.frame = localFrame

        updatePixelGrid()
        updateSelectionHighlight()
        CATransaction.commit()
    }

    func updateCanvasContents() {
        guard !isUpdatingContents, let coordinator else { return }
        isUpdatingContents = true
        defer { isUpdatingContents = false }

        let model = coordinator.model
        let viewport = coordinator.viewport
        let revision = model.canvasRevision
        let onionState = OnionSkinRenderState(
            currentFrame: model.frame,
            frameCount: model.frameCount,
            enabled: viewport.onionSkin,
            frameCountToShow: viewport.onionFrames,
            opacity: viewport.onionOpacity,
            colorize: viewport.onionColorize
        )
        let needBase = !didDrawContent || revision != lastDrawnRevision
        let needOnion = needBase || onionState.needsRedraw(comparedTo: lastOnionState)
        guard needBase || needOnion else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if needBase {
            let pixels = model.compositeCurrentFrame()
            if let cgImage = makeCGImage(pixels: pixels, width: model.width, height: model.height) {
                canvasImageLayer.contents = cgImage
                didDrawContent = true
                lastDrawnRevision = revision
            }
        }

        if needOnion {
            let specs = onionState.layers
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

        lastOnionState = onionState

        CATransaction.commit()
    }

    private func updatePixelGrid() {
        guard let coordinator else { return }
        let model = coordinator.model
        let viewport = coordinator.viewport
        let zoom = viewport.zoom

        guard viewport.showGrid, zoom >= 4.0 else {
            pixelGridLayer.isHidden = true
            return
        }

        let w = model.width
        let h = model.height
        let stride = max(1, CanvasGridMetrics.lineStride(width: w, height: h, zoom: zoom))

        if zoom == lastGridZoom, w == lastGridWidth, h == lastGridHeight, stride == lastGridStride {
            pixelGridLayer.isHidden = false
            return
        }

        let path = CGMutablePath()
        let totalW = CGFloat(w) * zoom
        let totalH = CGFloat(h) * zoom

        for x in Swift.stride(from: max(1, stride), to: w, by: max(1, stride)) {
            let xPos = CGFloat(x) * zoom
            path.move(to: CGPoint(x: xPos, y: 0))
            path.addLine(to: CGPoint(x: xPos, y: totalH))
        }
        for y in Swift.stride(from: max(1, stride), to: h, by: max(1, stride)) {
            let yPos = CGFloat(y) * zoom
            path.move(to: CGPoint(x: 0, y: yPos))
            path.addLine(to: CGPoint(x: totalW, y: yPos))
        }

        pixelGridLayer.path = path
        pixelGridLayer.isHidden = false
        lastGridZoom = zoom
        lastGridWidth = w
        lastGridHeight = h
        lastGridStride = stride
    }

    private func updateSelectionHighlight() {
        guard let coordinator else { return }
        let model = coordinator.model
        let zoom = coordinator.viewport.zoom

        if let sel = model.transformRect ?? model.selectionRect {
            let rect = CGRect(
                x: sel.origin.x * zoom,
                y: sel.origin.y * zoom,
                width: sel.width * zoom,
                height: sel.height * zoom
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

    // MARK: - Gestures (Pinch, Pan, Undo, Redo)

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
        coordinator.model.abortStroke()
        coordinator.model.undo()
        triggerHapticFeedback()
        showGestureHUD("Undo")
    }

    @objc private func handleThreeFingerTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let coordinator else { return }
        coordinator.model.abortStroke()
        coordinator.model.redo()
        triggerHapticFeedback()
        showGestureHUD("Redo")
    }

    // MARK: - Long-press Eyedropper

    /// Place the loupe above the finger so it is never hidden under the touch.
    private func loupePosition(for point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: max(96, point.y - 104))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let coordinator else { return }
        let model = coordinator.model
        // Only the drawing tools long-press into the eyedropper; the eyedropper
        // tool itself picks directly from touchesBegan.
        guard model.tool == .pencil || model.tool == .eraser || model.tool == .smudge else { return }

        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            isLongPressEyedropper = true
            model.abortStroke()
            triggerHapticFeedback()
            if let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                model.startEyedropperSession(at: pixel, viewPosition: loupePosition(for: point), sourceTool: model.tool)
            }
        case .changed:
            guard isLongPressEyedropper else { return }
            if let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                model.updateEyedropperSession(at: pixel, viewPosition: loupePosition(for: point))
            }
        case .ended:
            guard isLongPressEyedropper else { return }
            isLongPressEyedropper = false
            model.commitEyedropperSession()
        case .cancelled, .failed:
            guard isLongPressEyedropper else { return }
            isLongPressEyedropper = false
            model.cancelEyedropperSession()
        default:
            break
        }
    }

    private func triggerHapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    private func setupHUD() {
        hudLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hudLabel.textColor = .white
        hudLabel.backgroundColor = UIColor(white: 0.15, alpha: 0.90)
        hudLabel.textAlignment = .center
        hudLabel.layer.cornerRadius = 14
        hudLabel.layer.masksToBounds = true
        hudLabel.alpha = 0
        addSubview(hudLabel)
    }

    private func showGestureHUD(_ text: String) {
        hudLabel.text = text
        let padding: CGFloat = 28
        let size = (text as NSString).size(withAttributes: [.font: hudLabel.font!])
        let badgeWidth = max(80, size.width + padding)
        let badgeHeight: CGFloat = 28
        hudLabel.frame = CGRect(
            x: (bounds.width - badgeWidth) / 2,
            y: safeAreaInsets.top + 16,
            width: badgeWidth,
            height: badgeHeight
        )
        bringSubviewToFront(hudLabel)
        UIView.animate(withDuration: 0.15, animations: {
            self.hudLabel.alpha = 1.0
        }) { _ in
            UIView.animate(withDuration: 0.25, delay: 0.6, options: .curveEaseOut, animations: {
                self.hudLabel.alpha = 0.0
            }, completion: nil)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Drawing Touches (Finger & Apple Pencil)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        NotificationCenter.default.post(name: .studioDismissPopovers, object: nil)
        guard let coordinator else { return }
        if isLongPressEyedropper { return }
        if (event?.allTouches?.count ?? 0) > 1 {
            coordinator.model.abortStroke()
            return
        }
        guard touches.count == 1, let touch = touches.first else { return }
        let point = touch.location(in: self)
        guard let pixel = coordinator.pixelCoordinate(point, in: self) else { return }
        // The eyedropper tool samples live with the loupe instead of drawing.
        if coordinator.model.tool == .eyedropper {
            coordinator.model.startEyedropperSession(at: pixel, viewPosition: loupePosition(for: point), sourceTool: .eyedropper)
            return
        }
        coordinator.model.beginStroke(x: pixel.x, y: pixel.y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let coordinator else { return }
        if isLongPressEyedropper { return }
        if coordinator.model.eyedropperSession?.isActive == true {
            guard touches.count == 1, let touch = touches.first else { return }
            let point = touch.location(in: self)
            if let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) {
                coordinator.model.updateEyedropperSession(at: pixel, viewPosition: loupePosition(for: point))
            }
            return
        }
        if (event?.allTouches?.count ?? 0) > 1 {
            coordinator.model.abortStroke()
            return
        }
        guard touches.count == 1, let touch = touches.first else { return }
        let point = touch.location(in: self)
        guard let pixel = coordinator.pixelCoordinate(point, in: self) else { return }
        coordinator.model.continueStroke(x: pixel.x, y: pixel.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let coordinator else { return }
        if isLongPressEyedropper { return }
        if coordinator.model.eyedropperSession?.isActive == true {
            coordinator.model.commitEyedropperSession()
            return
        }
        guard (event?.allTouches?.count ?? 0) <= 1, let touch = touches.first else {
            coordinator.model.abortStroke()
            return
        }
        let point = touch.location(in: self)
        guard let pixel = coordinator.pixelCoordinate(point, in: self, clamp: true) else { return }
        coordinator.model.endStroke(x: pixel.x, y: pixel.y)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let coordinator else { return }
        if coordinator.model.eyedropperSession?.isActive == true, coordinator.model.tool == .eyedropper {
            coordinator.model.cancelEyedropperSession()
        }
        coordinator.model.abortStroke()
    }
}

// MARK: - ColorDrop (native drop handling)

extension PixelCanvasUIView: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [ColorDropPayload.typeIdentifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        setColorDropHighlight(true)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        setColorDropHighlight(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        setColorDropHighlight(false)
        guard let item = session.items.first else { return }
        guard let coordinator,
              let pixel = coordinator.pixelCoordinate(session.location(in: self), in: self) else { return }
        item.itemProvider.loadDataRepresentation(forTypeIdentifier: ColorDropPayload.typeIdentifier) { [weak self] data, _ in
            guard let self, let data, let payload = ColorDropPayload(jsonData: data) else { return }
            DispatchQueue.main.async {
                self.coordinator?.model.dropFill(payload.color, at: pixel)
            }
        }
    }

    private func setColorDropHighlight(_ visible: Bool) {
        guard colorDropHighlightLayer.isHidden == visible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorDropHighlightLayer.isHidden = !visible
        CATransaction.commit()
    }
}
#endif
