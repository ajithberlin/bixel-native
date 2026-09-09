// CanvasView.swift
//
// SwiftUI wrapper around the Metal-backed infinite canvas. A `PixelCanvas`
// (MTKView subclass) forwards pointer/trackpad/keyboard events to the
// coordinator: left-drag paints, trackpad scroll pans, pinch or ⌘-scroll
// zooms around the cursor, and holding space turns the pointer into a hand.
// Painting gestures are mapped through `CanvasViewport` and funneled to the
// Rust engine via `EditorModel` (a whole stroke becomes one FFI call per
// segment).

import SwiftUI
import MetalKit
import Combine

struct CanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, viewport: viewport)
    }

    func makeNSView(context: Context) -> PixelCanvas {
        let view = PixelCanvas()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.07, green: 0.073, blue: 0.085, alpha: 1.0)
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = context.coordinator
        view.coordinator = context.coordinator

        context.coordinator.connect(view)
        context.coordinator.renderer = view.device.flatMap(MetalRenderer.init)
        return view
    }

    func updateNSView(_ view: PixelCanvas, context: Context) {
        context.coordinator.model = model
        context.coordinator.viewport = viewport
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var model: EditorModel
        var viewport: CanvasViewport
        var renderer: MetalRenderer?
        private var observations: [AnyCancellable] = []
        private var canvasDirty = true
        private var onionDirty = true
        private var lastOnionSkin = false

        init(model: EditorModel, viewport: CanvasViewport) {
            self.model = model
            self.viewport = viewport
        }

        func connect(_ view: MTKView) {
            model.canvasChanged.sink { [weak self, weak view] in
                self?.canvasDirty = true
                self?.onionDirty = true
                view?.needsDisplay = true
            }.store(in: &observations)
            viewport.objectWillChange.sink { [weak self, weak view] in
                if self?.lastOnionSkin != self?.viewport.onionSkin {
                    self?.onionDirty = true
                }
                view?.needsDisplay = true
            }.store(in: &observations)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            viewport.lastViewSize = bounds.size
            if !viewport.didFit {
                viewport.zoomToFit(viewSize: bounds.size, canvasWidth: model.width, height: model.height)
            }

            if canvasDirty {
                let pixels = model.compositeCurrentFrame()
                renderer?.updateCanvas(pixels: pixels, width: model.width, height: model.height)
                canvasDirty = false
            }
            var onionAlpha: Float = 0
            if viewport.onionSkin, model.frame > 0 {
                if onionDirty {
                    renderer?.updateOnion(pixels: model.compositeFrame(model.frame - 1),
                                          width: model.width, height: model.height)
                    onionDirty = false
                }
                onionAlpha = 0.35
            } else if onionDirty {
                renderer?.updateOnion(pixels: nil, width: 0, height: 0)
                onionDirty = false
            }
            lastOnionSkin = viewport.onionSkin

            let sf = view.drawableSize.width / max(1, bounds.width)
            let origin = viewport.artboardOrigin(viewSize: bounds.size,
                                                 canvasWidth: model.width, height: model.height)
            let uniforms = ViewportUniforms(
                viewSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                canvasSize: SIMD2(Float(model.width), Float(model.height)),
                origin: SIMD2(Float(origin.x * sf), Float(origin.y * sf)),
                scale: Float(viewport.zoom * sf),
                gridAlpha: viewport.showGrid ? 1 : 0,
                onionAlpha: onionAlpha
            )
            renderer?.draw(in: view, uniforms: uniforms)
        }

        // MARK: - Painting

        func begin(at point: CGPoint, in view: MTKView) {
            guard let p = pixelCoordinate(point, in: view) else { return }
            model.beginStroke(x: p.x, y: p.y)
        }

        func drag(at point: CGPoint, in view: MTKView) {
            guard let p = pixelCoordinate(point, in: view) else { return }
            model.continueStroke(x: p.x, y: p.y)
        }

        func end(at point: CGPoint, in view: MTKView) {
            guard let p = pixelCoordinate(point, in: view, clamp: true) else { return }
            model.endStroke(x: p.x, y: p.y)
        }

        private func pixelCoordinate(_ point: CGPoint, in view: MTKView, clamp: Bool = false) -> (x: Int, y: Int)? {
            viewport.viewToDoc(point, viewSize: view.bounds.size,
                               width: model.width, height: model.height, clamp: clamp)
        }
    }
}

/// MTKView subclass that routes mouse, trackpad and keyboard events.
final class PixelCanvas: MTKView {
    weak var coordinator: CanvasView.Coordinator?

    private var spaceDown = false
    private var panning = false
    private var lastPanPoint: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Tracking areas (cursor updates)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        (spaceDown ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        (spaceDown ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    // MARK: - Painting / panning gestures

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceDown {
            panning = true
            lastPanPoint = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
            return
        }
        coordinator?.begin(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if panning {
            coordinator?.viewport.panBy(dx: point.x - lastPanPoint.x, dy: point.y - lastPanPoint.y)
            lastPanPoint = point
            return
        }
        coordinator?.drag(at: point, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        if panning {
            panning = false
            (spaceDown ? NSCursor.openHand : NSCursor.crosshair).set()
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
            if !spaceDown { spaceDown = true; NSCursor.openHand.set() }
        default:
            switch event.charactersIgnoringModifiers {
            case "p": model.tool = .pencil
            case "e": model.tool = .eraser
            case "f": model.tool = .fill
            case "i": model.tool = .eyedropper
            case "l": model.tool = .line
            case "[": model.brushSize = max(1, model.brushSize - 1)
            case "]": model.brushSize = min(32, model.brushSize + 1)
            case "g": viewport.showGrid.toggle()
            default: super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            panning = false
            NSCursor.crosshair.set()
        } else {
            super.keyUp(with: event)
        }
    }
}
