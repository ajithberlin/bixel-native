// CanvasView.swift
//
// SwiftUI wrapper around the Metal-backed canvas. A `PixelCanvas` (MTKView
// subclass) forwards pointer events to the coordinator, which maps them to
// pixel coordinates and drives the Rust engine through `EditorModel` (a whole
// stroke becomes one FFI call per segment).

import SwiftUI
import MetalKit
import Combine

struct CanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> PixelCanvas {
        let view = PixelCanvas()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1.0)
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
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var model: EditorModel
        var renderer: MetalRenderer?
        private var observation: AnyCancellable?
        private var dirty = true

        func connect(_ view: MTKView) {
            observation = model.canvasChanged.sink { [weak self, weak view] in
                self?.dirty = true
                view?.needsDisplay = true
            }
        }

        init(model: EditorModel) {
            self.model = model
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }
        func draw(in view: MTKView) {
            if dirty {
                let pixels = model.compositeCurrentFrame()
                renderer?.updateCanvas(pixels: pixels, width: model.width, height: model.height)
                dirty = false
            }
            renderer?.draw(in: view)
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
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return nil }
            let px = Int(floor(point.x / size.width * CGFloat(model.width)))
            let py = Int(floor((size.height - point.y) / size.height * CGFloat(model.height)))
            if clamp { return (min(max(px, 0), model.width - 1), min(max(py, 0), model.height - 1)) }
            guard px >= 0, px < model.width, py >= 0, py < model.height else { return nil }
            return (px, py)
        }
    }
}

/// MTKView subclass that routes mouse events to the coordinator.
final class PixelCanvas: MTKView {
    weak var coordinator: CanvasView.Coordinator?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        coordinator?.begin(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.drag(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.end(at: convert(event.locationInWindow, from: nil), in: self)
    }
}
