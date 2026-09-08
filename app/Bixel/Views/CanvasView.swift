// CanvasView.swift
//
// SwiftUI wrapper around the Metal-backed canvas. A `PixelCanvas` (MTKView
// subclass) forwards pointer events to the coordinator, which maps them to
// pixel coordinates and drives the Rust engine through `EditorModel` (a whole
// stroke becomes one FFI call per segment).

import SwiftUI
import MetalKit

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
        view.delegate = context.coordinator
        view.coordinator = context.coordinator

        context.coordinator.renderer = view.device.flatMap(MetalRenderer.init)
        return view
    }

    func updateNSView(_ view: PixelCanvas, context: Context) {
        context.coordinator.model = model
        context.coordinator.redraw(view)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var model: EditorModel
        var renderer: MetalRenderer?

        init(model: EditorModel) {
            self.model = model
        }

        func redraw(_ view: MTKView) {
            let pixels = model.compositeCurrentFrame()
            renderer?.updateCanvas(pixels: pixels, width: model.width, height: model.height)
            view.needsDisplay = true
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) { renderer?.draw(in: view) }

        // MARK: - Painting

        func begin(at point: CGPoint, in view: MTKView) {
            guard let p = pixelCoordinate(point, in: view) else { return }
            model.beginStroke(x: p.x, y: p.y)
            redraw(view)
        }

        func drag(at point: CGPoint, in view: MTKView) {
            guard let p = pixelCoordinate(point, in: view) else { return }
            model.continueStroke(x: p.x, y: p.y)
            redraw(view)
        }

        func end(at point: CGPoint, in view: MTKView) {
            guard let p = pixelCoordinate(point, in: view) else { return }
            model.endStroke(x: p.x, y: p.y)
            redraw(view)
        }

        private func pixelCoordinate(_ point: CGPoint, in view: MTKView) -> (x: Int, y: Int)? {
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return nil }
            let px = Int(point.x / size.width * CGFloat(model.width))
            let py = Int((size.height - point.y) / size.height * CGFloat(model.height))
            guard px >= 0, px < model.width, py >= 0, py < model.height else { return nil }
            return (px, py)
        }
    }
}

/// MTKView subclass that routes mouse events to the coordinator.
final class PixelCanvas: MTKView {
    weak var coordinator: CanvasView.Coordinator?

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
