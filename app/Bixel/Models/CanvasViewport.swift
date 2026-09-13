// CanvasViewport.swift
//
// Camera for the infinite canvas: a zoom factor (view points per document
// pixel) and a pan offset (points, relative to the view center, y-up). The
// document is a bounded artboard floating on an endless dark workspace, like
// Photoshop / Procreate. All conversions between view and document pixel
// coordinates live here so the Metal renderer and the event coordinator agree.

import SwiftUI
import Combine

final class CanvasViewport: ObservableObject {
    /// View points per document pixel (1 = native size, 16 = zoomed in).
    /// Callers must clamp through `CanvasViewport.clampZoom` — mutating the
    /// property from its own `didSet` recurses infinitely.
    @Published var zoom: CGFloat = 8
    /// Offset of the artboard center from the view center, in view points (y-up).
    @Published var pan: CGPoint = .zero
    @Published var showGrid = true
    @Published var onionSkin = false
    /// Ghost opacity for the most recent previous frame (0...1).
    @Published var onionOpacity: Double = 0.32
    /// How many previous frames to ghost (1 or 2; the older one fades more).
    @Published var onionFrames: Int = 1
    /// Width (points) reserved on the right by a docked side panel. The camera
    /// centres within the remaining area instead of the full view.
    var rightInset: CGFloat = 0

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 64

    /// Set on the first layout so the artboard starts zoomed-to-fit.
    private(set) var didFit = false

    /// Last laid-out view size; lets menu commands fit without view access.
    var lastViewSize: CGSize = .zero

    /// Forget the fit so the next draw re-centers (e.g. after switching project).
    func refit() { didFit = false }

    /// Reserve horizontal room for a docked side panel and re-centre the
    /// artwork within the remaining area (canvas itself is not resized).
    func setRightInset(_ inset: CGFloat) {
        let clamped = max(0, inset)
        let delta = clamped - rightInset
        guard delta != 0 else { return }
        rightInset = clamped
        pan = CGPoint(x: pan.x - delta / 2, y: pan.y)
    }

    /// Zoom to fit using the last known view size.
    func zoomToFitCurrent(canvasWidth w: Int, height h: Int) {
        zoomToFit(viewSize: lastViewSize, canvasWidth: w, height: h)
    }

    /// Zoom an infinite scene to fit its projected content and centre the
    /// content's actual world-pixel bounds. An empty scene has no bounds to
    /// fit, so it starts at a readable 1:1 scale around the world origin.
    func zoomToFitInfinite(
        viewSize: CGSize,
        contentBounds: (x: Int, y: Int, width: Int, height: Int)?
    ) {
        guard viewSize.width > 40, viewSize.height > 40 else { return }
        let availW = viewSize.width - 260 - rightInset
        let availH = viewSize.height - 220
        guard availW > 40, availH > 40 else { return }

        guard let contentBounds,
              contentBounds.width > 0,
              contentBounds.height > 0 else {
            zoom = Self.clampZoom(1)
            pan = .zero
            didFit = true
            return
        }

        zoom = Self.clampZoom(min(availW / CGFloat(contentBounds.width),
                                  availH / CGFloat(contentBounds.height)))
        let centerX = Double(contentBounds.x) + Double(contentBounds.width) / 2
        let centerY = Double(contentBounds.y) + Double(contentBounds.height) / 2
        // `unboundedOrigin` already centres within the usable view. Move the
        // world-content centre onto that origin after changing the scale.
        pan = CGPoint(x: -CGFloat(centerX) * zoom,
                      y: CGFloat(centerY) * zoom)
        didFit = true
    }

    static func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, minZoom), maxZoom)
    }

    // MARK: - Geometry

    /// Bottom-left corner of the artboard in view points (AppKit coords, y-up).
    func artboardOrigin(viewSize: CGSize, canvasWidth w: Int, height h: Int) -> CGPoint {
        CGPoint(
            x: (viewSize.width - rightInset) / 2 + pan.x - CGFloat(w) * zoom / 2,
            y: viewSize.height / 2 + pan.y - CGFloat(h) * zoom / 2
        )
    }

    /// Map a view point (y-up) to document pixel coordinates (y = 0 is the top
    /// row). Returns nil outside the artboard unless `clamp` is set.
    func viewToDoc(_ point: CGPoint, viewSize: CGSize, width w: Int, height h: Int, clamp: Bool = false) -> (x: Int, y: Int)? {
        let origin = artboardOrigin(viewSize: viewSize, canvasWidth: w, height: h)
        let px = Int(floor((point.x - origin.x) / zoom))
        let py = Int(floor((origin.y + CGFloat(h) * zoom - point.y) / zoom))
        if clamp { return (min(max(px, 0), w - 1), min(max(py, 0), h - 1)) }
        guard px >= 0, px < w, py >= 0, py < h else { return nil }
        return (px, py)
    }

    // MARK: - Unbounded (infinite map) coordinates

    /// View point (y-up) of document pixel (0, 0) for an unbounded canvas.
    func unboundedOrigin(viewSize: CGSize) -> CGPoint {
        CGPoint(x: (viewSize.width - rightInset) / 2 + pan.x,
                y: viewSize.height / 2 + pan.y)
    }

    /// Document pixel (may be negative/fractional) → view point (y-up).
    func docToView(x: Double, y: Double, viewSize: CGSize) -> CGPoint {
        let origin = unboundedOrigin(viewSize: viewSize)
        return CGPoint(x: origin.x + CGFloat(x) * zoom, y: origin.y - CGFloat(y) * zoom)
    }

    /// View point (y-up) → document pixel (may be negative/fractional).
    func viewToDocF(_ point: CGPoint, viewSize: CGSize) -> (x: Double, y: Double) {
        let origin = unboundedOrigin(viewSize: viewSize)
        return (Double((point.x - origin.x) / zoom), Double((origin.y - point.y) / zoom))
    }

    // MARK: - Zoom

    func zoomToFit(viewSize: CGSize, canvasWidth w: Int, height h: Int) {
        guard viewSize.width > 40, viewSize.height > 40, w > 0, h > 0 else { return }
        // Leave room for the floating chrome (top capsule, tool rail, panels,
        // timeline, docked AI sidebar) so the artboard never starts hidden.
        let availW = viewSize.width - 260 - rightInset
        let availH = viewSize.height - 220
        guard availW > 40, availH > 40 else { return }
        zoom = Self.clampZoom(min(availW / CGFloat(w), availH / CGFloat(h)))
        pan = .zero
        didFit = true
    }

    func zoomIn() { zoomBy(1.25) }
    func zoomOut() { zoomBy(1 / 1.25) }

    /// Zoom keeping the document point under `anchor` (view points, y-up) fixed.
    func zoomBy(_ factor: CGFloat, anchor: CGPoint? = nil, viewSize: CGSize = .zero) {
        let newZoom = Self.clampZoom(zoom * factor)
        guard newZoom != zoom else { return }
        if let anchor, viewSize.width > 0 {
            let center = CGPoint(x: (viewSize.width - rightInset) / 2,
                                 y: viewSize.height / 2)
            let rel = CGPoint(x: anchor.x - center.x, y: anchor.y - center.y)
            let ratio = newZoom / zoom
            pan = CGPoint(x: rel.x - (rel.x - pan.x) * ratio,
                          y: rel.y - (rel.y - pan.y) * ratio)
        }
        zoom = newZoom
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        pan = CGPoint(x: pan.x + dx, y: pan.y + dy)
    }
}
