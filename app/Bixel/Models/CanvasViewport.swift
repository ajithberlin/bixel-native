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
    @Published var zoom: CGFloat = 8 {
        didSet { zoom = Self.clampZoom(zoom) }
    }
    /// Offset of the artboard center from the view center, in view points (y-up).
    @Published var pan: CGPoint = .zero
    @Published var showGrid = true
    @Published var onionSkin = false

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 64

    /// Set on the first layout so the artboard starts zoomed-to-fit.
    private(set) var didFit = false

    /// Last laid-out view size; lets menu commands fit without view access.
    var lastViewSize: CGSize = .zero

    /// Forget the fit so the next draw re-centers (e.g. after switching project).
    func refit() { didFit = false }

    /// Zoom to fit using the last known view size.
    func zoomToFitCurrent(canvasWidth w: Int, height h: Int) {
        zoomToFit(viewSize: lastViewSize, canvasWidth: w, height: h)
    }

    static func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, minZoom), maxZoom)
    }

    // MARK: - Geometry

    /// Bottom-left corner of the artboard in view points (AppKit coords, y-up).
    func artboardOrigin(viewSize: CGSize, canvasWidth w: Int, height h: Int) -> CGPoint {
        CGPoint(
            x: viewSize.width / 2 + pan.x - CGFloat(w) * zoom / 2,
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

    // MARK: - Zoom

    func zoomToFit(viewSize: CGSize, canvasWidth w: Int, height h: Int) {
        guard viewSize.width > 40, viewSize.height > 40, w > 0, h > 0 else { return }
        zoom = Self.clampZoom(min((viewSize.width - 64) / CGFloat(w), (viewSize.height - 64) / CGFloat(h)))
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
            let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
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
