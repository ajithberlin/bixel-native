// EditorModel.swift
//
// Observable application state: owns the Rust-backed Document + Timeline, the
// current tool/brush/color, the layer list, and a playback clock that drives
// the timeline. Views observe this; drawing gestures are funneled through here
// so a whole stroke becomes a single Rust FFI call (never per-pixel).

import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

enum Tool: String, CaseIterable, Identifiable {
    case pencil, smudge, eraser, fill, eyedropper, selection, transform
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pencil: return "paintbrush.pointed"
        case .smudge: return "hand.draw"
        case .eraser: return "eraser"
        case .fill: return "paintbrush.pointed.fill"
        case .eyedropper: return "eyedropper"
        case .selection: return "lasso"
        case .transform: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var label: String { rawValue.capitalized }
}

struct EyedropperSession: Equatable {
    var isActive: Bool = false
    var viewPosition: CGPoint = .zero
    var docPixel: (x: Int, y: Int) = (0, 0)
    var previousColor: BixelColor = BixelColor(r: 0, g: 0, b: 0, a: 255)
    var currentColor: BixelColor = BixelColor(r: 0, g: 0, b: 0, a: 255)
    var colorName: String = ""
    var magnifiedCrop: CGImage? = nil
    var sourceTool: Tool? = nil

    static func == (lhs: EyedropperSession, rhs: EyedropperSession) -> Bool {
        lhs.isActive == rhs.isActive &&
        lhs.viewPosition == rhs.viewPosition &&
        lhs.docPixel.x == rhs.docPixel.x &&
        lhs.docPixel.y == rhs.docPixel.y &&
        lhs.previousColor == rhs.previousColor &&
        lhs.currentColor == rhs.currentColor &&
        lhs.colorName == rhs.colorName &&
        lhs.sourceTool == rhs.sourceTool
    }
}

/// The eight draggable handles of a free-transform box.
enum TransformHandle: CaseIterable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Corner position in document coordinates (y grows downward).
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        case .top, .right, .bottom, .left: return false
        }
    }
}

/// Oriented transform-box geometry in document space. Coordinates use the
/// document's y-down convention, so positive angles rotate clockwise visually.
struct TransformGeometry {
    var center: CGPoint
    var size: CGSize
    var angle: CGFloat

    var halfSize: CGSize {
        CGSize(width: size.width / 2, height: size.height / 2)
    }

    private func rotated(_ local: CGPoint, by radians: CGFloat) -> CGPoint {
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGPoint(
            x: local.x * cosine - local.y * sine,
            y: local.x * sine + local.y * cosine
        )
    }

    private func localPoint(for handle: TransformHandle) -> CGPoint {
        let half = halfSize
        switch handle {
        case .topLeft: return CGPoint(x: -half.width, y: -half.height)
        case .top: return CGPoint(x: 0, y: -half.height)
        case .topRight: return CGPoint(x: half.width, y: -half.height)
        case .right: return CGPoint(x: half.width, y: 0)
        case .bottomRight: return CGPoint(x: half.width, y: half.height)
        case .bottom: return CGPoint(x: 0, y: half.height)
        case .bottomLeft: return CGPoint(x: -half.width, y: half.height)
        case .left: return CGPoint(x: -half.width, y: 0)
        }
    }

    func point(for handle: TransformHandle) -> CGPoint {
        let point = rotated(localPoint(for: handle), by: angle)
        return CGPoint(x: center.x + point.x, y: center.y + point.y)
    }

    var corners: [CGPoint] {
        [.topLeft, .topRight, .bottomRight, .bottomLeft].map(point(for:))
    }

    /// The rotation stem extends from the local top edge by the same
    /// tiny-artwork-friendly distance used by the existing transform UI.
    var rotationHandlePoint: CGPoint {
        let distance = max(18, min(36, size.height * 0.3))
        let point = rotated(CGPoint(x: 0, y: -halfSize.height - distance), by: angle)
        return CGPoint(x: center.x + point.x, y: center.y + point.y)
    }

    func contains(_ point: CGPoint) -> Bool {
        let local = localPoint(point)
        let half = halfSize
        return abs(local.x) <= half.width && abs(local.y) <= half.height
    }

    /// Converts a document-space point into the transform box's local space.
    func localPoint(_ point: CGPoint) -> CGPoint {
        let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
        return rotated(translated, by: -angle)
    }
}

enum FloatingImportTarget: Equatable {
    case newFrame(layer: Int)
    case newLayer(frame: Int, name: String)
}

/// Native-resolution source data awaiting a user-confirmed transform. This is
/// deliberately separate from the document-backed transform selection: no
/// document pixels, frames, layers, or undo history change until commit.
struct FloatingImageImport {
    /// Identifies the immutable native source while transform fields change.
    let sourceID: UUID
    let rgba: [UInt8]
    let width: Int
    let height: Int
    let target: FloatingImportTarget
    let name: String
    var center: CGPoint
    var scaleX: CGFloat
    var scaleY: CGFloat
    var angle: CGFloat

    var geometry: TransformGeometry {
        TransformGeometry(
            center: center,
            size: CGSize(width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY),
            angle: angle
        )
    }
}

struct LayerInfo: Identifiable {
    let id: UUID
    let index: Int
    var name: String
    var visible: Bool
    var opacity: Double
    var blendMode: String = "Normal"
    var subtitle: String? = nil

    var blendLetter: String {
        switch blendMode.lowercased() {
        case "multiply": return "M"
        case "screen": return "S"
        case "overlay": return "O"
        case "darken": return "D"
        case "lighten": return "L"
        case "color dodge", "colordodge", "dodge": return "D"
        case "addition", "add": return "A"
        case "difference": return "F"
        default: return "N"
        }
    }
}

/// A frame captured for the in-app clipboard: every layer's raw RGBA plus the
/// frame's hold duration, so a paste restores the frame faithfully.
struct FrameClipboardItem {
    var layers: [[UInt8]]
    var durationMs: Int
    var width: Int
    var height: Int
}

final class EditorModel: ObservableObject {
    let document: Document
    let timeline: Timeline
    @Published var operationError: String?

    // Tool + brush state
    @Published var tool: Tool = .pencil
    @Published var brushSize: Double = 3
    @Published var opacity: Double = 1.0
    @Published var currentColor: BixelColor = BixelColor(r: 24, g: 24, b: 24, a: 255)
    @Published var eyedropperSession: EyedropperSession? = nil

    // Canvas background
    @Published var canvasBackgroundColor: BixelColor = BixelColor(r: 104, g: 178, b: 240, a: 255) {
        didSet { notifyCanvasChanged() }
    }
    @Published var showBackgroundColor: Bool = true {
        didSet { notifyCanvasChanged() }
    }

    // Document state
    @Published var frame: Int = 0 { didSet { notifyCanvasChanged() } }
    @Published var playing: Bool = false
    @Published var activeLayer: Int = 0
    @Published var layers: [LayerInfo] = []
    /// Stable identities for timeline frames so reordering animates as a move
    /// (index-keyed identities would just swap content in place).
    @Published private(set) var frameIDs: [UUID] = []
    private var layerIDs: [UUID] = []
    @Published var selectionRect: CGRect?
    @Published var transformRect: CGRect?
    /// Frames captured via copy/cut, ready to be pasted after the current frame.
    @Published private(set) var frameClipboard: [FrameClipboardItem] = []
    /// Transient clockwise rotation preview in radians. The Rust transform
    /// applies the complete angle with nearest-neighbour sampling.
    @Published var transformAngle: CGFloat = 0
    @Published var snapping = true
    /// Aspect-ratio lock for free-transform resizing (the "Uniform" toggle).
    @Published var uniformTransform = false
    @Published private(set) var floatingImport: FloatingImageImport?
    private var selectionStart: CGPoint?
    private var transformStart: CGPoint?
    private var transformOrigin: CGRect?
    private var resizeHandle: TransformHandle?
    private var resizeBase: CGRect?
    private var resizeUniform = false
    private var rotationCenter: CGPoint?
    private var rotationStartAngle: CGFloat?
    private var rotationBaseAngle: CGFloat = 0
    private var rotationBaseRect: CGRect?
    private var floatingMoveOffset: CGPoint?
    private var floatingResizeHandle: TransformHandle?
    private var floatingResizeBase: FloatingImageImport?
    private var floatingResizeUniform = false
    private var floatingRotationCenter: CGPoint?
    private var floatingRotationLastAngle: CGFloat?
    private var floatingRotationBaseAngle: CGFloat = 0
    private let minimumFloatingScale: CGFloat = 0.0001

    // Playback settings
    @Published var fps: Double = 12 {
        didSet { timeline.setFPS(Float(fps)) }
    }
    @Published var loopMode: LoopMode = .forward {
        didSet { timeline.setLoopMode(loopMode) }
    }

    let canvasChanged = PassthroughSubject<Void, Never>()
    /// Monotonic counter bumped every time pixel/appearance content changes;
    /// the canvas layer uses it to skip redundant recompositing.
    private(set) var canvasRevision = 0
    var onDocumentChanged: (() -> Void)?
    private var frameCache: [Int: [UInt8]] = [:]
    private var strokeChanged = false

    private func notifyCanvasChanged() {
        canvasRevision += 1
        canvasChanged.send()
    }

    /// Coalescing repaint scheduler. A brush stroke fires many per-move updates;
    /// without batching every move recomposites the whole frame and rebuilds a
    /// CGImage on the main thread, which tanks frame rate on larger canvases.
    /// Pixel changes are therefore coalesced to (at most) display-refresh rate.
    private var refreshTimer: Timer?

    private func scheduleCanvasRefresh() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refreshTimer = nil
            self.notifyCanvasChanged()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func flushCanvasRefreshNow() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        notifyCanvasChanged()
    }

    private func pixelsChanged(allFrames: Bool = false) {
        if allFrames {
            frameCache.removeAll()
        } else {
            frameCache[frame] = nil
        }
        // Interactive paint feedback can be slightly deferred and coalesced.
        scheduleCanvasRefresh()
    }

    private func commitChange(allFrames: Bool = false) {
        if allFrames { ensureFrameIDs() }
        pixelsChanged(allFrames: allFrames)
        if allFrames {
            thumbCache.removeAll()
            frameThumbCache.removeAll()
        } else {
            thumbCache[activeLayer] = nil
            frameThumbCache[frame] = nil
        }
        objectWillChange.send()
        onDocumentChanged?()
        // Discrete operations must be visible immediately (not deferred by a timer).
        flushCanvasRefreshNow()
    }

    private var playbackTimer: Timer?
    private var lastPoint: (x: Int, y: Int)?

    init(width: Int = 32, height: Int = 32, document restored: Document? = nil) {
        let document = restored ?? Document(width: width, height: height)
        self.document = document
        self.timeline = Timeline(document: document)
        reloadLayers()
        ensureFrameIDs()
    }

    // MARK: - Layer list

    /// Keep the parallel identity arrays aligned with the document. Lengths only
    /// change on add/delete/undo; explicit reorders permute the ids themselves.
    private func ensureFrameIDs() {
        let count = document.frameCount
        if frameIDs.count == count { return }
        if frameIDs.count < count {
            frameIDs.append(contentsOf: (frameIDs.count..<count).map { _ in UUID() })
        } else {
            frameIDs.removeLast(frameIDs.count - count)
        }
    }

    private func ensureLayerIDs() {
        let count = document.layerCount
        if layerIDs.count == count { return }
        if layerIDs.count < count {
            layerIDs.append(contentsOf: (layerIDs.count..<count).map { _ in UUID() })
        } else {
            layerIDs.removeLast(layerIDs.count - count)
        }
    }

    func reloadLayers() {
        ensureLayerIDs()
        let prev = Dictionary(uniqueKeysWithValues: layers.map { ($0.index, ($0.blendMode, $0.subtitle)) })
        layers = (0..<document.layerCount).map { i in
            let existing = prev[i]
            return LayerInfo(
                id: layerIDs[i],
                index: i,
                name: document.layerName(i),
                visible: document.isLayerVisible(i),
                opacity: Double(document.layerOpacity(i)),
                blendMode: existing?.0 ?? "Normal",
                subtitle: existing?.1
            )
        }
    }

    func setLayerBlendMode(_ index: Int, _ mode: String) {
        if let idx = layers.firstIndex(where: { $0.index == index }) {
            layers[idx].blendMode = mode
            commitChange(allFrames: true)
        }
    }

    func duplicateLayer(_ index: Int) {
        guard index >= 0, index < document.layerCount else { return }
        document.snapshot()
        let name = "\(document.layerName(index)) Copy"
        let newIdx = document.addLayer(name)
        for f in 0..<document.frameCount {
            let rgba = document.celRGBA(layer: index, frame: f)
            document.loadImageData(rgba, width: width, height: height, layer: newIdx, frame: f)
        }
        let oldOpacity = document.layerOpacity(index)
        document.setLayerOpacity(newIdx, oldOpacity)
        activeLayer = newIdx
        reloadLayers()
        if let origMode = layers.first(where: { $0.index == index })?.blendMode {
            setLayerBlendMode(newIdx, origMode)
        }
        commitChange(allFrames: true)
    }

    // MARK: - Selection and transform

    func beginSelection(x: Int, y: Int) {
        selectionStart = CGPoint(x: x, y: y)
        selectionRect = CGRect(x: x, y: y, width: 1, height: 1)
        transformRect = nil
        transformAngle = 0
        endResize()
    }

    func updateSelection(x: Int, y: Int) {
        guard let start = selectionStart else { return }
        let left = min(Int(start.x), x), top = min(Int(start.y), y)
        selectionRect = CGRect(x: left, y: top, width: max(1, abs(x - Int(start.x)) + 1), height: max(1, abs(y - Int(start.y)) + 1))
    }

    func endSelection() {
        selectionStart = nil
        guard selectionRect != nil else { return }
        transformRect = selectionRect
        // Procreate-style: finishing a marquee hands the box straight to the
        // Transform tool so its corner handles are immediately visible/draggable.
        if tool == .selection { tool = .transform }
    }

    func clearSelection() {
        selectionStart = nil; selectionRect = nil; transformRect = nil; transformAngle = 0
        transformStart = nil; transformOrigin = nil
        rotationCenter = nil; rotationStartAngle = nil; rotationBaseRect = nil
        endResize()
    }

    // MARK: - Tool selection

    /// Central tool switch. Choosing Transform with no active marquee turns the
    /// active layer's artwork into an auto-selection, exactly like Procreate,
    /// so the transform box + handles appear immediately without a click.
    func selectTool(_ newTool: Tool) {
        if floatingImport != nil && newTool != .transform {
            // Leaving the transform workflow is an intentional placement
            // boundary. Keep ordinary transform mouse-up non-destructive, but
            // do not let a pending import capture every subsequent tool.
            commitFloatingImport()
            guard floatingImport == nil else { return }
        }
        if newTool == tool {
            // Re-pressing Transform with an empty box (e.g. after Escape) should
            // re-acquire the layer's artwork rather than silently doing nothing.
            if newTool == .transform, selectionRect == nil, let content = activeLayerContentBounds() {
                selectionRect = content
                transformRect = content
            }
            return
        }
        let selectionFamily: Set<Tool> = [.selection, .transform]
        if selectionFamily.contains(tool) && !selectionFamily.contains(newTool) {
            clearSelection()
        }
        tool = newTool
        if newTool == .transform, selectionRect == nil {
            if let content = activeLayerContentBounds() {
                selectionRect = content
                transformRect = content
            }
        }
        if newTool == .selection {
            endResize()
        }
    }

    /// Non-empty bounding box of the active layer's painted pixels at the
    /// current frame (nil when the layer is empty). Used so the Transform tool
    /// can auto-select layer artwork when no marquee has been drawn.
    func activeLayerContentBounds(_ layerIndex: Int? = nil) -> CGRect? {
        let layer = layerIndex ?? activeLayer
        guard layer >= 0, layer < document.layerCount else { return nil }
        let pixels = document.celRGBA(layer: layer, frame: frame)
        guard pixels.count == width * height * 4 else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        var i = 0
        for y in 0..<height {
            for x in 0..<width {
                if pixels[i + 3] > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                i += 4
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func isPointInSelection(x: Int, y: Int) -> Bool {
        guard let rect = transformRect ?? selectionRect else { return false }
        let px = CGFloat(x), py = CGFloat(y)
        return px >= rect.minX && px < rect.maxX && py >= rect.minY && py < rect.maxY
    }

    func beginTransform(x: Int, y: Int) {
        var rect = transformRect ?? selectionRect
        if rect == nil, let content = activeLayerContentBounds() {
            selectionRect = content
            rect = content
        }
        guard let rect else { return }
        transformOrigin = rect
        transformStart = CGPoint(x: x, y: y)
    }

    /// Start a transform drag if the point grabs an existing marquee, or auto-
    /// selects the active layer's artwork when the point lands on it. Returns
    /// false when the press should not begin a transform gesture.
    @discardableResult
    func grabTransform(x: Int, y: Int) -> Bool {
        if transformRect != nil || selectionRect != nil {
            guard isPointInSelection(x: x, y: y) else { return false }
            beginTransform(x: x, y: y)
            return true
        }
        guard let content = activeLayerContentBounds() else { return false }
        let px = CGFloat(x), py = CGFloat(y)
        guard px >= content.minX, px < content.maxX, py >= content.minY, py < content.maxY else { return false }
        selectionRect = content
        beginTransform(x: x, y: y)
        return true
    }

    func updateTransform(x: Int, y: Int) {
        guard let start = transformStart, let origin = transformOrigin else { return }
        let dx = x - Int(start.x), dy = y - Int(start.y)
        let snappedX = snapping ? Int(round(Double(origin.origin.x + CGFloat(dx)))) : Int(origin.origin.x + CGFloat(dx))
        let snappedY = snapping ? Int(round(Double(origin.origin.y + CGFloat(dy)))) : Int(origin.origin.y + CGFloat(dy))
        transformRect = CGRect(x: CGFloat(snappedX), y: CGFloat(snappedY), width: origin.width, height: origin.height)
    }

    // MARK: - Free transform resizing

    /// Which transform handle (if any) is under the pointer. `tolerance` is in document
    /// pixels so the grab matches the on-screen handle size at any zoom.
    func hitTransformHandle(x: CGFloat, y: CGFloat, tolerance: CGFloat) -> TransformHandle? {
        guard let rect = transformRect ?? selectionRect else { return nil }
        let p = CGPoint(x: x, y: y)
        for handle in TransformHandle.allCases {
            let c = handle.point(in: rect)
            if abs(p.x - c.x) <= tolerance && abs(p.y - c.y) <= tolerance { return handle }
        }
        return nil
    }

    func beginResize(handle: TransformHandle, x _: Int, y _: Int, uniform: Bool) {
        guard let rect = transformRect ?? selectionRect else { return }
        resizeHandle = handle
        resizeBase = rect
        resizeUniform = uniform && handle.isCorner
    }

    func updateResize(x: Int, y: Int) {
        guard let base = resizeBase, let handle = resizeHandle else { return }
        var cx = CGFloat(x), cy = CGFloat(y)
        // Keep the dragged corner on its own side of the fixed (opposite) edge.
        switch handle {
        case .topLeft:
            cx = min(cx, base.maxX - 1); cy = min(cy, base.maxY - 1)
        case .top:
            cy = min(cy, base.maxY - 1)
        case .topRight:
            cx = max(cx, base.minX + 1); cy = min(cy, base.maxY - 1)
        case .right:
            cx = max(cx, base.minX + 1)
        case .bottomRight:
            cx = max(cx, base.minX + 1); cy = max(cy, base.minY + 1)
        case .bottom:
            cy = max(cy, base.minY + 1)
        case .bottomLeft:
            cx = min(cx, base.maxX - 1); cy = max(cy, base.minY + 1)
        case .left:
            cx = min(cx, base.maxX - 1)
        }
        var left = base.minX, right = base.maxX, top = base.minY, bottom = base.maxY
        switch handle {
        case .topLeft:
            left = cx; top = cy
        case .top:
            top = cy
        case .topRight:
            right = cx; top = cy
        case .right:
            right = cx
        case .bottomRight:
            right = cx; bottom = cy
        case .bottom:
            bottom = cy
        case .bottomLeft:
            left = cx; bottom = cy
        case .left:
            left = cx
        }
        guard resizeUniform else {
            transformRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            return
        }
        // Uniform scaling from the fixed opposite corner, keeping base aspect.
        let baseW = max(1, base.width)
        let baseH = max(1, base.height)
        let scale = max((right - left) / baseW, (bottom - top) / baseH)
        let width = max(1, (baseW * scale).rounded())
        let height = max(1, (baseH * scale).rounded())
        let movesLeft = handle == .topLeft || handle == .bottomLeft
        let movesTop = handle == .topLeft || handle == .topRight
        let originX = movesLeft ? base.maxX - width : base.minX
        let originY = movesTop ? base.maxY - height : base.minY
        transformRect = CGRect(x: originX, y: originY, width: width, height: height)
    }

    func endResize() {
        resizeHandle = nil
        resizeBase = nil
    }

    // MARK: - Rotation handle

    /// The live ordinary transform box in document space. During rotation the
    /// mutable `transformRect` holds raster bounds, while `rotationBaseRect`
    /// retains the unrotated moved/resized source used by the visual controls.
    var transformGeometry: TransformGeometry? {
        guard let rect = rotationBaseRect ?? transformRect ?? selectionRect else { return nil }
        return TransformGeometry(center: CGPoint(x: rect.midX, y: rect.midY),
                                 size: rect.size, angle: transformAngle)
    }

    /// Document-space position of the Procreate-style rotation handle above
    /// the transform box. The extra stem keeps it reachable on tiny artwork.
    var rotationHandlePoint: CGPoint? {
        guard let rect = transformRect ?? selectionRect else { return nil }
        let distance = max(18, min(36, rect.height * 0.3))
        return CGPoint(x: rect.midX, y: rect.minY - distance)
    }

    func hitRotationHandle(x: CGFloat, y: CGFloat, tolerance: CGFloat) -> Bool {
        guard let handle = rotationHandlePoint else { return false }
        return hypot(x - handle.x, y - handle.y) <= tolerance
    }

    func beginRotation(x: CGFloat, y: CGFloat) {
        guard let rect = transformRect ?? selectionRect,
              rotationHandlePoint != nil else { return }
        rotationCenter = CGPoint(x: rect.midX, y: rect.midY)
        rotationStartAngle = atan2(y - rect.midY, x - rect.midX)
        rotationBaseAngle = transformAngle
        rotationBaseRect = rect
    }

    func updateRotation(x: CGFloat, y: CGFloat) {
        guard let center = rotationCenter,
              let start = rotationStartAngle,
              let base = rotationBaseRect else { return }
        let current = atan2(y - center.y, x - center.x)
        var delta = current - start
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        transformAngle = rotationBaseAngle + delta
        transformRect = rotatedBounds(of: base, angle: transformAngle)
    }

    func endRotation(commit: Bool) {
        guard rotationCenter != nil else { return }
        if !commit {
            transformRect = rotationBaseRect
            transformAngle = rotationBaseAngle
        }
        rotationCenter = nil
        rotationStartAngle = nil
        rotationBaseRect = nil
        if commit { commitTransform() }
    }

    private func rotatedBounds(of rect: CGRect, angle: CGFloat) -> CGRect {
        let c = abs(cos(angle)), s = abs(sin(angle))
        let w = rect.width * c + rect.height * s
        let h = rect.width * s + rect.height * c
        let roundedW = max(1, w.rounded())
        let roundedH = max(1, h.rounded())
        return CGRect(x: (rect.midX - roundedW / 2).rounded(),
                      y: (rect.midY - roundedH / 2).rounded(),
                      width: roundedW, height: roundedH)
    }

    func commitTransform() {
        guard let source = selectionRect, let destination = transformRect else { return }
        let unchanged = abs(transformAngle) < 0.0001
            && destination.origin.x == source.origin.x
            && destination.origin.y == source.origin.y
            && destination.width == source.width
            && destination.height == source.height
        guard !unchanged else { return }
        do {
            try document.transformRectAngle(layer: activeLayer, frame: frame, source: source, destination: destination,
                                            angle: Double(transformAngle))
            // Only the part of the destination that overlaps the canvas was
            // actually written. Keep the marquee on-canvas so the next
            // transform has a valid (non-negative) source rectangle; the engine
            // rejects source origins outside the canvas.
            let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            let visible = destination.intersection(canvas)
            let resolved = visible.isNull || visible.isEmpty ? nil : visible
            selectionRect = resolved
            transformRect = resolved
            transformAngle = 0
            transformStart = nil; transformOrigin = nil
            endResize()
            commitChange()
        } catch { operationError = error.localizedDescription }
    }

    /// Rotate the selected artwork 90° and commit it right away (Procreate /
    /// Aseprite-style), instead of leaving a pending preview.
    func rotateSelection() {
        guard let source = selectionRect else { return }
        let current = transformRect ?? source
        transformAngle += .pi / 2
        transformRect = rotatedBounds(of: current, angle: transformAngle)
        commitTransform()
    }

    func fitSelectionToCanvas() {
        guard let source = selectionRect else { return }
        let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        if source.equalTo(full) && abs(transformAngle) < 0.0001 { return }
        transformRect = full
        transformAngle = 0
        commitTransform()
    }

    func resetTransform() { transformRect = selectionRect; transformAngle = 0; endResize() }

    func nudgeTransform(dx: Int, dy: Int) {
        guard let rect = transformRect else { return }
        // Document pixels are already the snapping grid for a 1px nudge.
        transformRect = rect.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))
    }

    func addLayer() {
        document.snapshot()
        activeLayer = document.addLayer()
        reloadLayers()
        commitChange(allFrames: true)
    }

    func deleteLayer() {
        guard document.layerCount > 1 else { return }
        document.snapshot()
        let removed = activeLayer
        document.removeLayer(activeLayer)
        if layerIDs.indices.contains(removed) { layerIDs.remove(at: removed) }
        activeLayer = max(0, activeLayer - 1)
        reloadLayers()
        commitChange(allFrames: true)
    }

    func renameLayer(_ index: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.snapshot()
        document.renameLayer(index, name: trimmed)
        reloadLayers()
        objectWillChange.send()
        onDocumentChanged?()
    }

    func toggleLayerVisibility(_ index: Int) {
        let newValue = !document.isLayerVisible(index)
        document.setLayerVisible(index, newValue)
        reloadLayers()
        commitChange(allFrames: true)
    }

    func setLayerOpacity(_ index: Int, _ value: Double) {
        document.setLayerOpacity(index, Float(value))
        if layers.indices.contains(index) { layers[index].opacity = value }
        commitChange(allFrames: true)
    }

    /// Move a layer in the stack (0 = bottom); standard remove-then-insert.
    func moveLayer(from: Int, to: Int) {
        guard from != to, from >= 0, to >= 0,
              from < document.layerCount, to < document.layerCount else { return }
        document.snapshot()
        document.reorderLayer(from: from, to: to)
        if layerIDs.indices.contains(from), layerIDs.indices.contains(to) {
            let id = layerIDs.remove(at: from)
            layerIDs.insert(id, at: to)
        }
        activeLayer = to
        reloadLayers()
        commitChange(allFrames: true)
    }

    /// Thumbnail CGImage for a layer at the current frame. Downsampled so layer
    /// panels never keep whole-canvas bitmaps alive (a 4096² layer would
    /// otherwise cache a 64 MB CGImage per row).
    func layerThumbnailCGImage(_ layer: Int) -> CGImage? {
        // Retain the current frame's small thumbnails across control changes.
        // Clearing the entire cache at a fixed layer count makes every redraw
        // copy all full-resolution cels when the document exceeds that count.
        if thumbCacheFrame != frame {
            thumbCache.removeAll(keepingCapacity: true)
            thumbCacheFrame = frame
        }
        if let cached = thumbCache[layer] { return cached }
        let pixels = document.celRGBA(layer: layer, frame: frame)
        guard let cg = downsample(pixels, width: width, height: height, maxDimension: 96) else { return nil }
        thumbCache[layer] = cg
        return cg
    }

    /// Downsampled preview of a composited frame, cached per frame. Used by the
    /// timeline strip so playback never re-rasterises full-resolution frames.
    func frameThumbnailCGImage(_ index: Int) -> CGImage? {
        if let cached = frameThumbCache[index] { return cached }
        let pixels = compositeFrame(index)
        guard let cg = downsample(pixels, width: width, height: height, maxDimension: 96) else { return nil }
        if frameThumbCache.count > 64 { frameThumbCache.removeAll(keepingCapacity: true) }
        frameThumbCache[index] = cg
        return cg
    }

    /// Raw thumbnail pixels for a layer at the current frame.
    func layerThumbnail(_ layer: Int) -> [UInt8] {
        document.celRGBA(layer: layer, frame: frame)
    }

    // At most one 96 × 96 thumbnail per layer, for one frame only.
    private var thumbCacheFrame: Int?
    private var thumbCache: [Int: CGImage] = [:]
    private var frameThumbCache: [Int: CGImage] = [:]

    /// Nearest-neighbour scale of a full-resolution RGBA buffer into a small
    /// thumbnail bitmap (the display path then magnifies it crisply).
    private func downsample(_ pixels: [UInt8], width: Int, height: Int, maxDimension: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let scale = min(1.0, CGFloat(maxDimension) / CGFloat(max(width, height)))
        guard scale < 1.0 else { return makeCGImage(pixels: pixels, width: width, height: height) }
        let tw = max(1, Int((CGFloat(width) * scale).rounded()))
        let th = max(1, Int((CGFloat(height) * scale).rounded()))
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        for y in 0..<th {
            let sy = min(height - 1, y * height / th)
            let srcRow = sy * width
            let dstRow = y * tw
            for x in 0..<tw {
                let sx = min(width - 1, x * width / tw)
                let si = (srcRow + sx) * 4
                let di = (dstRow + x) * 4
                out[di] = pixels[si]
                out[di + 1] = pixels[si + 1]
                out[di + 2] = pixels[si + 2]
                out[di + 3] = pixels[si + 3]
            }
        }
        return makeCGImage(pixels: out, width: tw, height: th)
    }

    // MARK: - Frame timing

    func frameDuration(_ index: Int) -> Int {
        document.frameDuration(index)
    }

    func setFrameDuration(_ index: Int, ms: Int) {
        guard index >= 0, index < document.frameCount else { return }
        document.snapshot()
        document.setFrameDuration(index, ms: ms)
        objectWillChange.send()
        onDocumentChanged?()
    }

    // MARK: - Drawing

    /// Effective color with opacity folded into alpha.
    private var drawColor: BixelColor {
        BixelColor(
            r: currentColor.r,
            g: currentColor.g,
            b: currentColor.b,
            a: UInt8((Float(currentColor.a) * Float(opacity)).rounded())
        )
    }

    private var brushRadius: UInt32 {
        max(0, UInt32(brushSize.rounded()) - 1)
    }

    func beginStroke(x: Int, y: Int) {
        lastPoint = nil
        strokeChanged = false
        switch tool {
        case .eyedropper:
            pick(x: x, y: y)
        case .fill:
            document.snapshot()
            document.floodFill(layer: activeLayer, frame: frame, x: x, y: y, drawColor)
            strokeChanged = true
            pixelsChanged()
        case .pencil, .eraser:
            document.snapshot()
            lastPoint = (x, y)
            document.stroke(layer: activeLayer, frame: frame, points: [(x, y)], color: strokeColor, radius: brushRadius)
            strokeChanged = true
            pixelsChanged()
        case .smudge:
            document.snapshot()
            lastPoint = (x, y)
            document.stroke(layer: activeLayer, frame: frame, points: [(x, y)], color: smudgeColor(at: x, y: y), radius: brushRadius)
            strokeChanged = true
            pixelsChanged()
        case .selection, .transform:
            break
        }
    }

    func continueStroke(x: Int, y: Int) {
        guard let last = lastPoint, last.x != x || last.y != y else { return }
        switch tool {
        case .pencil, .eraser:
            document.stroke(layer: activeLayer, frame: frame, points: [last, (x, y)], color: strokeColor, radius: brushRadius)
            lastPoint = (x, y)
            strokeChanged = true
            pixelsChanged()
        case .smudge:
            document.stroke(layer: activeLayer, frame: frame, points: [last, (x, y)], color: smudgeColor(at: x, y: y), radius: brushRadius)
            lastPoint = (x, y)
            strokeChanged = true
            pixelsChanged()
        default:
            break
        }
    }

    func endStroke(x: Int, y: Int) {
        if tool == .pencil || tool == .eraser || tool == .smudge { continueStroke(x: x, y: y) }
        lastPoint = nil
        if strokeChanged {
            strokeChanged = false
            lastStrokeEnd = (x, y)
            commitChange()
        }
    }

    /// Abort an in-flight stroke, reverting the initial snapshot dot so no
    /// stray pixels are left behind (used when transitioning to long-press eyedropper).
    func abortStroke() {
        if strokeChanged {
            document.undo()
            strokeChanged = false
            lastPoint = nil
            pixelsChanged()
        }
    }

    /// Shift-draw: a straight line with the current brush. With no drag
    /// (Shift+click), the line starts where the previous stroke ended —
    /// Photoshop-style connected lines.
    func strokeLine(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) {
        guard tool == .pencil || tool == .eraser else { return }
        document.snapshot()
        document.stroke(layer: activeLayer, frame: frame, points: [start, end], color: strokeColor, radius: brushRadius)
        lastStrokeEnd = end
        commitChange()
    }

    /// Where the last committed stroke ended; Shift+click continues from here.
    private(set) var lastStrokeEnd: (x: Int, y: Int)?

    private var strokeColor: BixelColor {
        tool == .eraser ? BixelColor(r: 0, g: 0, b: 0, a: 0) : drawColor
    }

    private func smudgeColor(at x: Int, y: Int) -> BixelColor {
        let picked = document.getPixel(layer: activeLayer, frame: frame, x: x, y: y)
        if picked.a > 0 {
            return BixelColor(r: picked.r, g: picked.g, b: picked.b, a: UInt8(max(25, Int(picked.a) / 3)))
        }
        return drawColor
    }

    // MARK: - Eyedropper & Loupe

    /// Sample the composited visible canvas pixel at `(x, y)` taking transparency
    /// and background color into account.
    func sampleCompositePixel(x: Int, y: Int) -> BixelColor {
        guard x >= 0, x < width, y >= 0, y < height else {
            return showBackgroundColor ? canvasBackgroundColor : BixelColor(r: 128, g: 128, b: 128, a: 255)
        }
        let pixels = compositeCurrentFrame()
        let idx = (y * width + x) * 4
        guard idx + 3 < pixels.count else {
            return showBackgroundColor ? canvasBackgroundColor : BixelColor(r: 128, g: 128, b: 128, a: 255)
        }
        let r = pixels[idx]
        let g = pixels[idx + 1]
        let b = pixels[idx + 2]
        let a = pixels[idx + 3]

        if a == 255 {
            return BixelColor(r: r, g: g, b: b, a: 255)
        } else if a > 0 {
            if showBackgroundColor {
                let alphaF = Double(a) / 255.0
                let bgR = Double(canvasBackgroundColor.r)
                let bgG = Double(canvasBackgroundColor.g)
                let bgB = Double(canvasBackgroundColor.b)
                let finalR = UInt8((Double(r) * alphaF + bgR * (1.0 - alphaF)).rounded())
                let finalG = UInt8((Double(g) * alphaF + bgG * (1.0 - alphaF)).rounded())
                let finalB = UInt8((Double(b) * alphaF + bgB * (1.0 - alphaF)).rounded())
                return BixelColor(r: finalR, g: finalG, b: finalB, a: 255)
            } else {
                return BixelColor(r: r, g: g, b: b, a: 255)
            }
        } else {
            return showBackgroundColor ? canvasBackgroundColor : BixelColor(r: 128, g: 128, b: 128, a: 255)
        }
    }

    /// Extract an un-interpolated (nearest-neighbor) square patch around `center`
    /// for the magnifying loupe.
    func generateLoupeCrop(around center: (x: Int, y: Int), radius: Int = 7) -> CGImage? {
        let size = radius * 2 + 1
        var cropBuffer = [UInt8](repeating: 0, count: size * size * 4)
        let pixels = compositeCurrentFrame()

        for dy in -radius...radius {
            let py = center.y + dy
            let targetRow = dy + radius
            for dx in -radius...radius {
                let px = center.x + dx
                let targetCol = dx + radius
                let destIdx = (targetRow * size + targetCol) * 4

                if px >= 0 && px < width && py >= 0 && py < height {
                    let srcIdx = (py * width + px) * 4
                    if srcIdx + 3 < pixels.count {
                        let r = pixels[srcIdx]
                        let g = pixels[srcIdx + 1]
                        let b = pixels[srcIdx + 2]
                        let a = pixels[srcIdx + 3]
                        if a == 255 {
                            cropBuffer[destIdx] = r
                            cropBuffer[destIdx + 1] = g
                            cropBuffer[destIdx + 2] = b
                            cropBuffer[destIdx + 3] = 255
                        } else if a > 0 {
                            if showBackgroundColor {
                                let alphaF = Double(a) / 255.0
                                cropBuffer[destIdx] = UInt8((Double(r) * alphaF + Double(canvasBackgroundColor.r) * (1.0 - alphaF)).rounded())
                                cropBuffer[destIdx + 1] = UInt8((Double(g) * alphaF + Double(canvasBackgroundColor.g) * (1.0 - alphaF)).rounded())
                                cropBuffer[destIdx + 2] = UInt8((Double(b) * alphaF + Double(canvasBackgroundColor.b) * (1.0 - alphaF)).rounded())
                                cropBuffer[destIdx + 3] = 255
                            } else {
                                cropBuffer[destIdx] = r
                                cropBuffer[destIdx + 1] = g
                                cropBuffer[destIdx + 2] = b
                                cropBuffer[destIdx + 3] = a
                            }
                        } else {
                            if showBackgroundColor {
                                cropBuffer[destIdx] = canvasBackgroundColor.r
                                cropBuffer[destIdx + 1] = canvasBackgroundColor.g
                                cropBuffer[destIdx + 2] = canvasBackgroundColor.b
                                cropBuffer[destIdx + 3] = 255
                            } else {
                                // Transparent checkerboard gray
                                let isEven = ((px / 4) + (py / 4)) % 2 == 0
                                let v: UInt8 = isEven ? 140 : 100
                                cropBuffer[destIdx] = v
                                cropBuffer[destIdx + 1] = v
                                cropBuffer[destIdx + 2] = v
                                cropBuffer[destIdx + 3] = 255
                            }
                        }
                    }
                } else {
                    // Out-of-bounds workspace background (~#121316)
                    cropBuffer[destIdx] = 18
                    cropBuffer[destIdx + 1] = 19
                    cropBuffer[destIdx + 2] = 22
                    cropBuffer[destIdx + 3] = 255
                }
            }
        }

        return makeCGImage(pixels: cropBuffer, width: size, height: size)
    }

    func startEyedropperSession(at docPixel: (x: Int, y: Int), viewPosition: CGPoint, sourceTool: Tool? = nil) {
        let sampled = sampleCompositePixel(x: docPixel.x, y: docPixel.y)
        let crop = generateLoupeCrop(around: docPixel)
        eyedropperSession = EyedropperSession(
            isActive: true,
            viewPosition: viewPosition,
            docPixel: docPixel,
            previousColor: currentColor,
            currentColor: sampled,
            colorName: sampled.descriptiveName,
            magnifiedCrop: crop,
            sourceTool: sourceTool ?? tool
        )
        currentColor = sampled
    }

    func updateEyedropperSession(at docPixel: (x: Int, y: Int), viewPosition: CGPoint) {
        guard var session = eyedropperSession, session.isActive else { return }
        let sampled = sampleCompositePixel(x: docPixel.x, y: docPixel.y)
        let crop = generateLoupeCrop(around: docPixel)
        session.viewPosition = viewPosition
        session.docPixel = docPixel
        session.currentColor = sampled
        session.colorName = sampled.descriptiveName
        session.magnifiedCrop = crop
        eyedropperSession = session
        currentColor = sampled
    }

    func commitEyedropperSession() {
        guard let session = eyedropperSession, session.isActive else { return }
        currentColor = session.currentColor
        opacity = 1.0
        if let src = session.sourceTool, src != .eyedropper {
            selectTool(src)
        }
        eyedropperSession = nil
    }

    func cancelEyedropperSession() {
        guard let session = eyedropperSession, session.isActive else { return }
        currentColor = session.previousColor
        if let src = session.sourceTool, src != .eyedropper {
            selectTool(src)
        }
        eyedropperSession = nil
    }

    func pick(x: Int, y: Int) {
        let c = sampleCompositePixel(x: x, y: y)
        currentColor = c
        opacity = 1.0
    }

    // MARK: - Animation

    func togglePlayback() { playing ? pause() : play() }

    func play() {
        guard !playing else { return }
        playing = true
        timeline.play()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func pause() {
        playing = false
        timeline.pause()
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func tick() {
        let next = timeline.update(deltaMs: 1000.0 / 60.0)
        if next != frame {
            frame = next
        }
    }

    func goTo(_ newFrame: Int) {
        frame = timeline.goTo(newFrame)
    }

    func addFrame() {
        frame = document.addFrame(durationMs: 125)
        commitChange(allFrames: true)
    }

    func duplicateFrame() {
        // Copy the current frame's active layer cel into a brand-new frame.
        document.snapshot()
        let src = document.compositeRGBA(frame: frame)
        let newFrame = document.addFrame(durationMs: 125)
        document.loadImageData(src, width: width, height: height, layer: 0, frame: newFrame)
        frame = newFrame
        commitChange(allFrames: true)
    }

    func reorderFrame(from: Int, to: Int) {
        guard from >= 0, to >= 0, from < frameCount, to < frameCount, from != to else { return }
        pause()
        document.snapshot()
        document.reorderFrame(from: from, to: to)
        if frameIDs.indices.contains(from), frameIDs.indices.contains(to) {
            let id = frameIDs.remove(at: from)
            frameIDs.insert(id, at: to)
        }
        // Keep the selected artwork selected as its position changes.
        let selected: Int
        if frame == from { selected = to }
        else if from < frame && frame <= to { selected = frame - 1 }
        else if to <= frame && frame < from { selected = frame + 1 }
        else { selected = frame }
        goTo(selected)
        commitChange(allFrames: true)
    }

    func removeFrame() {
        removeFrame(at: frame)
    }

    func removeFrame(at index: Int) {
        guard document.frameCount > 1, index >= 0, index < frameCount else { return }
        pause()
        document.snapshot()
        document.removeFrame(index)
        if frameIDs.indices.contains(index) { frameIDs.remove(at: index) }
        let selected: Int
        if frame == index {
            selected = min(index, document.frameCount - 1)
        } else if frame > index {
            selected = frame - 1
        } else {
            selected = frame
        }
        goTo(selected)
        commitChange(allFrames: true)
    }

    // MARK: - Frame clipboard

    var canPasteFrame: Bool { !frameClipboard.isEmpty }

    /// Capture a frame (every layer's cel + its hold duration) into the tray.
    func copyFrame(at index: Int? = nil) {
        let index = index ?? frame
        guard index >= 0, index < frameCount else { return }
        let layers = (0..<document.layerCount).map { document.celRGBA(layer: $0, frame: index) }
        frameClipboard = [FrameClipboardItem(
            layers: layers,
            durationMs: document.frameDuration(index),
            width: width,
            height: height
        )]
    }

    /// Copy the frame then delete it. The last remaining frame is never removed.
    @discardableResult
    func cutFrame(at index: Int? = nil) -> Bool {
        let index = index ?? frame
        guard frameCount > 1, index >= 0, index < frameCount else { return false }
        copyFrame(at: index)
        removeFrame(at: index)
        return true
    }

    /// Insert the clipboard frame(s) directly after `index` (default: current).
    @discardableResult
    func pasteFrame(after index: Int? = nil) -> Bool {
        guard !frameClipboard.isEmpty else { return false }
        let anchor = index ?? frame
        pause()
        document.snapshot()
        var target = min(max(anchor + 1, 0), document.frameCount)
        for clip in frameClipboard {
            let inserted = document.addFrame(durationMs: clip.durationMs)
            let dest = min(max(target, 0), document.frameCount - 1)
            if inserted != dest { document.reorderFrame(from: inserted, to: dest) }
            for (layer, data) in clip.layers.enumerated() where layer < document.layerCount {
                document.loadImageData(data, width: clip.width, height: clip.height, layer: layer, frame: dest)
            }
            target = dest + 1
        }
        frame = min(max(target - 1, 0), document.frameCount - 1)
        commitChange(allFrames: true)
        return true
    }

    /// Resize the canvas, preserving existing pixels anchored to the top-left.
    func resizeCanvas(width newWidth: Int, height newHeight: Int) {
        guard newWidth > 0, newHeight > 0, newWidth != width || newHeight != height else { return }
        document.snapshot()
        document.resize(width: newWidth, height: newHeight)
        frame = min(frame, document.frameCount - 1)
        commitChange(allFrames: true)
    }

    // MARK: - Export

    /// Render the current frame at `scale`× and offer it as a PNG via the save panel.
    func exportPNG(scale: Int = 4) {
        let scale = max(1, scale)
        let pixels = compositeCurrentFrame()
        let w = width, h = height
        var scaled = [UInt8](repeating: 0, count: w * scale * h * scale * 4)
        for y in 0..<h * scale {
            let srcRow = y / scale
            for x in 0..<w * scale {
                let src = (srcRow * w + x / scale) * 4
                let dst = (y * w * scale + x) * 4
                scaled[dst] = pixels[src]
                scaled[dst + 1] = pixels[src + 1]
                scaled[dst + 2] = pixels[src + 2]
                scaled[dst + 3] = pixels[src + 3]
            }
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w * scale,
            pixelsHigh: h * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: w * scale * 4,
            bitsPerPixel: 32
        ), let bitmap = rep.bitmapData else { return }
        scaled.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(bitmap, base, scaled.count)
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "frame-\(frame + 1)-\(w)x\(h)@\(scale)x.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }

    func undo() { if document.undo() { reloadLayers(); frame = min(frame, frameCount - 1); activeLayer = min(activeLayer, layers.count - 1); commitChange(allFrames: true) } }
    func redo() { if document.redo() { reloadLayers(); frame = min(frame, frameCount - 1); activeLayer = min(activeLayer, layers.count - 1); commitChange(allFrames: true) } }

    // MARK: - Canvas

    var width: Int { document.width }
    var height: Int { document.height }
    var frameCount: Int { document.frameCount }

    func compositeCurrentFrame() -> [UInt8] {
        compositeFrame(frame)
    }

    func compositeFrame(_ index: Int) -> [UInt8] {
        if let cached = frameCache[index] { return cached }
        let pixels = document.compositeRGBA(frame: index)
        // Bound retained full-size frames for large imported AI images.
        let limit = max(1, min(64, 32 * 1024 * 1024 / max(1, document.bytesPerFrame)))
        if frameCache.count >= limit, let oldest = frameCache.keys.first(where: { $0 != frame }) ?? frameCache.keys.first {
            frameCache[oldest] = nil
        }
        frameCache[index] = pixels
        return pixels
    }

    // MARK: - Floating image import

    var floatingTransformGeometry: TransformGeometry? { floatingImport?.geometry }

    private func validFloatingImageDimensions(width: Int, height: Int, rgbaCount: Int) -> Bool {
        guard width > 0, height > 0,
              height <= Int.max / 4,
              width <= Int.max / (height * 4) else { return false }
        return rgbaCount == width * height * 4
    }

    private func rotateFloatingPoint(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGPoint(x: point.x * cosine - point.y * sine,
                       y: point.x * sine + point.y * cosine)
    }

    private func floatingPoint(fromLocal point: CGPoint, in base: FloatingImageImport) -> CGPoint {
        let rotated = rotateFloatingPoint(point, by: base.angle)
        return CGPoint(x: base.center.x + rotated.x, y: base.center.y + rotated.y)
    }

    private func clearFloatingGestureState() {
        floatingMoveOffset = nil
        floatingResizeHandle = nil
        floatingResizeBase = nil
        floatingResizeUniform = false
        floatingRotationCenter = nil
        floatingRotationLastAngle = nil
        floatingRotationBaseAngle = 0
    }

    func beginFloatingImport(
        rgba: [UInt8], width: Int, height: Int,
        target: FloatingImportTarget, name: String,
        center: CGPoint? = nil
    ) {
        guard floatingImport == nil else {
            operationError = "Finish or cancel the current floating import first."
            return
        }
        guard validFloatingImageDimensions(width: width, height: height, rgbaCount: rgba.count) else {
            operationError = "Invalid RGBA image dimensions or buffer length."
            return
        }
        let resolvedCenter = center ?? CGPoint(x: CGFloat(self.width) / 2, y: CGFloat(self.height) / 2)
        guard resolvedCenter.x.isFinite && resolvedCenter.y.isFinite else {
            operationError = "Invalid floating import position."
            return
        }
        operationError = nil
        clearFloatingGestureState()
        floatingImport = FloatingImageImport(
            sourceID: UUID(), rgba: rgba, width: width, height: height, target: target, name: name,
            center: resolvedCenter, scaleX: 1, scaleY: 1, angle: 0
        )
        tool = .transform
    }

    func hitFloatingTransformHandle(x: CGFloat, y: CGFloat, tolerance: CGFloat) -> TransformHandle? {
        guard let geometry = floatingTransformGeometry else { return nil }
        let point = CGPoint(x: x, y: y)
        return TransformHandle.allCases.first { handle in
            hypot(point.x - geometry.point(for: handle).x, point.y - geometry.point(for: handle).y) <= tolerance
        }
    }

    func hitFloatingRotationHandle(x: CGFloat, y: CGFloat, tolerance: CGFloat) -> Bool {
        guard let geometry = floatingTransformGeometry else { return false }
        return hypot(x - geometry.rotationHandlePoint.x, y - geometry.rotationHandlePoint.y) <= tolerance
    }

    @discardableResult
    func beginFloatingMove(x: CGFloat, y: CGFloat) -> Bool {
        guard let image = floatingImport, image.geometry.contains(CGPoint(x: x, y: y)) else { return false }
        floatingMoveOffset = CGPoint(x: x - image.center.x, y: y - image.center.y)
        return true
    }

    func updateFloatingMove(x: CGFloat, y: CGFloat) {
        guard let offset = floatingMoveOffset, var image = floatingImport,
              x.isFinite, y.isFinite else { return }
        image.center = CGPoint(x: x - offset.x, y: y - offset.y)
        floatingImport = image
    }

    func beginFloatingResize(handle: TransformHandle, x _: CGFloat, y _: CGFloat, uniform: Bool) {
        guard let image = floatingImport else { return }
        floatingResizeHandle = handle
        floatingResizeBase = image
        floatingResizeUniform = handle.isCorner && (uniformTransform || uniform)
    }

    func updateFloatingResize(x: CGFloat, y: CGFloat) {
        guard let base = floatingResizeBase, let handle = floatingResizeHandle,
              x.isFinite, y.isFinite else { return }
        let local = base.geometry.localPoint(CGPoint(x: x, y: y))
        let baseSize = base.geometry.size
        let minimumWidth = max(CGFloat(base.width) * minimumFloatingScale, .leastNonzeroMagnitude)
        let minimumHeight = max(CGFloat(base.height) * minimumFloatingScale, .leastNonzeroMagnitude)

        let movesLeft = handle == .topLeft || handle == .bottomLeft || handle == .left
        let movesRight = handle == .topRight || handle == .bottomRight || handle == .right
        let movesTop = handle == .topLeft || handle == .topRight || handle == .top
        let movesBottom = handle == .bottomLeft || handle == .bottomRight || handle == .bottom

        var localCenter = CGPoint.zero
        var newWidth = baseSize.width
        var newHeight = baseSize.height

        if movesLeft {
            let fixed = baseSize.width / 2
            let dragged = min(local.x, fixed - minimumWidth)
            newWidth = fixed - dragged
            localCenter.x = (fixed + dragged) / 2
        } else if movesRight {
            let fixed = -baseSize.width / 2
            let dragged = max(local.x, fixed + minimumWidth)
            newWidth = dragged - fixed
            localCenter.x = (fixed + dragged) / 2
        }
        if movesTop {
            let fixed = baseSize.height / 2
            let dragged = min(local.y, fixed - minimumHeight)
            newHeight = fixed - dragged
            localCenter.y = (fixed + dragged) / 2
        } else if movesBottom {
            let fixed = -baseSize.height / 2
            let dragged = max(local.y, fixed + minimumHeight)
            newHeight = dragged - fixed
            localCenter.y = (fixed + dragged) / 2
        }

        if floatingResizeUniform {
            let scale = max(
                minimumFloatingScale,
                max(newWidth / max(baseSize.width, minimumWidth),
                    newHeight / max(baseSize.height, minimumHeight))
            )
            newWidth = baseSize.width * scale
            newHeight = baseSize.height * scale
            localCenter.x = movesLeft ? (baseSize.width - newWidth) / 2 : (newWidth - baseSize.width) / 2
            localCenter.y = movesTop ? (baseSize.height - newHeight) / 2 : (newHeight - baseSize.height) / 2
        }

        var image = base
        image.center = floatingPoint(fromLocal: localCenter, in: base)
        image.scaleX = max(minimumFloatingScale, newWidth / CGFloat(base.width))
        image.scaleY = max(minimumFloatingScale, newHeight / CGFloat(base.height))
        floatingImport = image
    }

    func beginFloatingRotation(x: CGFloat, y: CGFloat) {
        guard let image = floatingImport else { return }
        floatingRotationCenter = image.center
        floatingRotationLastAngle = atan2(y - image.center.y, x - image.center.x)
        floatingRotationBaseAngle = image.angle
    }

    func updateFloatingRotation(x: CGFloat, y: CGFloat) {
        guard let center = floatingRotationCenter, let last = floatingRotationLastAngle,
              var image = floatingImport else { return }
        let current = atan2(y - center.y, x - center.x)
        var delta = current - last
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        image.angle += delta
        floatingRotationLastAngle = current
        floatingImport = image
    }

    func endFloatingRotation(commit: Bool) {
        guard floatingRotationCenter != nil else { return }
        if !commit, var image = floatingImport {
            image.angle = floatingRotationBaseAngle
            floatingImport = image
        }
        floatingRotationCenter = nil
        floatingRotationLastAngle = nil
        floatingRotationBaseAngle = 0
    }

    func nudgeFloatingImport(dx: Int, dy: Int) {
        guard var image = floatingImport else { return }
        image.center.x += CGFloat(dx)
        image.center.y += CGFloat(dy)
        floatingImport = image
    }

    func commitFloatingImport() {
        guard let image = floatingImport else { return }
        let rasterized = AIService.rasterizeNativeImage(
            rgba: image.rgba, srcWidth: image.width, srcHeight: image.height,
            center: image.center, scaleX: image.scaleX, scaleY: image.scaleY,
            angle: image.angle, dstWidth: width, dstHeight: height
        )
        guard rasterized.count == width * height * 4 else {
            operationError = "Could not rasterize the floating image."
            return
        }

        do {
            switch image.target {
            case let .newFrame(layer: layer):
                guard layer >= 0 && layer < document.layerCount else {
                    throw StorageError.message("The floating import's target layer is no longer available.")
                }
                document.snapshot()
                let newFrame = document.addFrame(durationMs: 125)
                document.loadImageData(rasterized, width: width, height: height, layer: layer, frame: newFrame)
                frame = newFrame
                activeLayer = layer
            case let .newLayer(frame: targetFrame, name: name):
                guard targetFrame >= 0 && targetFrame < document.frameCount else {
                    throw StorageError.message("The floating import's target frame is no longer available.")
                }
                // `placeImageData` owns its single document snapshot. Supplying
                // the already-rasterized canvas buffer avoids a second mutation.
                activeLayer = try document.placeImageData(
                    rasterized, width: width, height: height, x: 0, y: 0,
                    frame: targetFrame, name: name
                )
                frame = targetFrame
            }
            reloadLayers()
            selectionRect = activeLayerContentBounds()
            transformRect = selectionRect
            transformAngle = 0
            clearFloatingGestureState()
            floatingImport = nil
            operationError = nil
            commitChange(allFrames: true)
        } catch {
            operationError = error.localizedDescription
        }
    }

    func cancelFloatingImport() {
        clearFloatingGestureState()
        floatingImport = nil
        operationError = nil
    }

    /// Pack the current animation with Rust and export matching frame metadata.
    func exportSpriteSheet() {
        do {
            let columns = max(1, Int(ceil(sqrt(Double(frameCount)))))
            let sheet = try document.packFrames(columns: columns)
            guard let png = AIService.rgbaToPNG(sheet.rgba, width: sheet.width, height: sheet.height) else {
                throw StorageError.message("Could not encode the sprite sheet.")
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "animation-\(width)x\(height).png"
            let metadata: [String: Any] = ["frame_width": width, "frame_height": height, "columns": columns,
                "frames": (0..<frameCount).map { ["x": ($0 % columns) * width, "y": ($0 / columns) * height,
                                                     "width": width, "height": height, "duration_ms": document.frameDuration($0)] }]
            let json = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try ProjectStorage.write(base: url.deletingLastPathComponent(), path: url.lastPathComponent, data: png)
                    try ProjectStorage.write(base: url.deletingLastPathComponent(), path: url.deletingPathExtension().lastPathComponent + ".json", data: json)
                } catch { self.operationError = error.localizedDescription }
            }
        } catch { operationError = error.localizedDescription }
    }

    // MARK: - AI result application

    func placeAsset(_ data: Data, name: String, x: Int? = nil, y: Int? = nil) {
        operationError = nil
        guard let image = AIService.pngToRGBA(data) else { operationError = "Could not decode the image."; return }
        let center = CGPoint(
            x: x.map { CGFloat($0) + CGFloat(image.width) / 2 } ?? CGFloat(width) / 2,
            y: y.map { CGFloat($0) + CGFloat(image.height) / 2 } ?? CGFloat(height) / 2
        )
        beginFloatingImport(
            rgba: image.rgba, width: image.width, height: image.height,
            target: .newLayer(frame: frame, name: name), name: name, center: center
        )
    }

    /// Append a spritesheet to the timeline as animation frames. A JSON manifest
    /// (Bixel export / atlas / grid) controls slicing, durations, and tags;
    /// without one, the sheet is sliced on the current canvas grid.
    func addSheetAsAnimation(_ data: Data, manifest: String? = nil, name: String) {
        operationError = nil
        guard let image = AIService.pngToRGBA(data) else { operationError = "Could not decode the sheet."; return }
        let manifest = manifest ?? SheetImport.gridManifest(cellWidth: width, cellHeight: height)
        do {
            let added = try document.appendSheet(
                rgba: image.rgba, width: image.width, height: image.height,
                manifest: manifest, layerName: name, replace: false
            )
            frame = max(0, document.frameCount - added)
            activeLayer = max(0, document.layerCount - 1)
            reloadLayers()
            commitChange(allFrames: true)
        } catch { operationError = error.localizedDescription }
    }

    func importSheet(_ data: Data, name: String) {
        addSheetAsAnimation(data, manifest: nil, name: name)
    }

    /// Begin a native-resolution image import for a new animation frame. The
    /// document is untouched until the user commits its floating transform.
    func applyImageToNewFrame(_ rgba: [UInt8], width: Int, height: Int) {
        beginFloatingImport(
            rgba: rgba, width: width, height: height,
            target: .newFrame(layer: activeLayer), name: "Imported Image"
        )
    }

    /// Apply an image to the active layer of current frame, auto-fitting to document dimensions if needed.
    func applyImageToCurrentFrame(_ rgba: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { operationError = "Invalid image dimensions."; return }
        let targetData: [UInt8]
        if width == self.width && height == self.height {
            targetData = rgba
        } else {
            targetData = AIService.fitToFrame(rgba: rgba, srcWidth: width, srcHeight: height, dstWidth: self.width, dstHeight: self.height)
        }
        document.snapshot()
        document.loadImageData(targetData, width: self.width, height: self.height, layer: activeLayer, frame: frame)
        commitChange(allFrames: true)
    }

    // MARK: - Agent control (Take Control bridge)

    /// Structured document state for the agent's `editor_read` tool.
    func agentState() -> [String: Any] {
        var state: [String: Any] = [
            "width": width,
            "height": height,
            "frame_count": frameCount,
            "layer_count": document.layerCount,
            "frame": frame,
            "active_layer": activeLayer,
            "tool": tool.rawValue,
            "can_undo": document.canUndo,
            "can_redo": document.canRedo,
        ]
        state["layers"] = layers.map { layer -> [String: Any] in
            ["index": layer.index, "name": layer.name, "visible": layer.visible,
             "opacity": layer.opacity, "blend_mode": layer.blendMode]
        }
        state["frames"] = (0..<frameCount).map { index -> [String: Any] in
            ["index": index, "duration_ms": document.frameDuration(index)]
        }
        state["tags"] = document.tags().map { tag -> [String: Any] in
            ["name": tag.name, "from": tag.from, "to": tag.to, "color": tag.color]
        }
        if let selection = selectionRect {
            state["selection"] = ["x": Int(selection.origin.x), "y": Int(selection.origin.y),
                                  "width": Int(selection.width), "height": Int(selection.height)]
        }
        return state
    }

    /// Apply validated agent operations. Each op is one undo step; the layer
    /// panel and canvas refresh once at the end.
    func applyAgentOps(_ ops: [[String: Any]], confirm: Bool, workspace: URL?) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for op in ops {
            let name = op["op"] as? String ?? ""
            do {
                var result = try applyAgentOp(name, op, workspace: workspace)
                result["op"] = name
                result["ok"] = true
                results.append(result)
            } catch {
                results.append(["op": name, "ok": false, "error": agentErrorDescription(error)])
            }
        }
        reloadLayers()
        commitChange(allFrames: true)
        return results
    }

    private func applyAgentOp(_ name: String, _ op: [String: Any], workspace: URL?) throws -> [String: Any] {
        func int(_ key: String) throws -> Int {
            guard let value = op[key] as? Int else { throw AgentOpError("'\(name)' requires an integer '\(key)'") }
            return value
        }
        func string(_ key: String) throws -> String {
            guard let value = op[key] as? String else { throw AgentOpError("'\(name)' requires a string '\(key)'") }
            return value
        }
        func bool(_ key: String) throws -> Bool {
            guard let value = op[key] as? Bool else { throw AgentOpError("'\(name)' requires a boolean '\(key)'") }
            return value
        }
        func double(_ key: String) throws -> Double {
            if let value = op[key] as? Double { return value }
            if let value = op[key] as? Int { return Double(value) }
            throw AgentOpError("'\(name)' requires a number '\(key)'")
        }
        func color() throws -> BixelColor { BixelColor(hex: try string("color")) }

        switch name {
        case "set_pixel":
            let layer = try int("layer"), f = try int("frame"), x = try int("x"), y = try int("y")
            try validateAgentCel(layer: layer, frame: f)
            guard x >= 0, x < width, y >= 0, y < height else { throw AgentOpError("set_pixel is outside the canvas") }
            document.snapshot()
            document.setPixel(layer: layer, frame: f, x: x, y: y, try color())
            return [:]

        case "set_pixels":
            guard let points = op["points"] as? [[String: Any]] else { throw AgentOpError("'set_pixels' requires a 'points' array") }
            document.snapshot()
            for point in points {
                guard let layer = point["layer"] as? Int, let f = point["frame"] as? Int,
                      let x = point["x"] as? Int, let y = point["y"] as? Int,
                      let hex = point["color"] as? String else { throw AgentOpError("each point needs layer, frame, x, y, color") }
                try validateAgentCel(layer: layer, frame: f)
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                document.setPixel(layer: layer, frame: f, x: x, y: y, BixelColor(hex: hex))
            }
            return ["count": points.count]

        case "stroke":
            let layer = try int("layer"), f = try int("frame")
            try validateAgentCel(layer: layer, frame: f)
            guard let raw = op["points"] as? [[String: Any]] else { throw AgentOpError("'stroke' requires a 'points' array") }
            let points: [(x: Int, y: Int)] = raw.compactMap {
                guard let x = $0["x"] as? Int, let y = $0["y"] as? Int else { return nil }
                return (x, y)
            }
            guard !points.isEmpty else { throw AgentOpError("'stroke' needs at least one point") }
            let radius = UInt32(max(0, (op["radius"] as? Int ?? 1) - 1))
            document.snapshot()
            document.stroke(layer: layer, frame: f, points: points, color: try color(), radius: radius)
            return ["count": points.count]

        case "flood_fill":
            let layer = try int("layer"), f = try int("frame"), x = try int("x"), y = try int("y")
            try validateAgentCel(layer: layer, frame: f)
            guard x >= 0, x < width, y >= 0, y < height else { throw AgentOpError("flood_fill is outside the canvas") }
            document.snapshot()
            let filled = document.floodFill(layer: layer, frame: f, x: x, y: y, try color())
            return ["pixels": filled]

        case "add_layer":
            document.snapshot()
            let index = document.addLayer(op["name"] as? String)
            activeLayer = index
            return ["index": index]

        case "remove_layer":
            let index = try int("index")
            guard document.layerCount > 1 else { throw AgentOpError("cannot remove the last layer") }
            guard index >= 0, index < document.layerCount else { throw AgentOpError("layer \(index) is out of range") }
            document.snapshot()
            document.removeLayer(index)
            activeLayer = min(activeLayer, document.layerCount - 1)
            return [:]

        case "rename_layer":
            let index = try int("index")
            guard index >= 0, index < document.layerCount else { throw AgentOpError("layer \(index) is out of range") }
            document.snapshot()
            document.renameLayer(index, name: try string("name"))
            return [:]

        case "reorder_layer":
            let from = try int("from"), to = try int("to")
            guard from >= 0, to >= 0, from < document.layerCount, to < document.layerCount else {
                throw AgentOpError("layer reorder out of range")
            }
            document.snapshot()
            document.reorderLayer(from: from, to: to)
            activeLayer = to
            return [:]

        case "set_layer_visible":
            let index = try int("index")
            guard index >= 0, index < document.layerCount else { throw AgentOpError("layer \(index) is out of range") }
            document.snapshot()
            document.setLayerVisible(index, try bool("visible"))
            return [:]

        case "set_layer_opacity":
            let index = try int("index")
            guard index >= 0, index < document.layerCount else { throw AgentOpError("layer \(index) is out of range") }
            let value = try double("opacity")
            document.snapshot()
            document.setLayerOpacity(index, Float(min(1, max(0, value))))
            return [:]

        case "add_frame":
            let duration = op["duration_ms"] as? Int ?? 125
            document.snapshot()
            let index = document.addFrame(durationMs: max(1, duration))
            frame = index
            return ["index": index]

        case "remove_frame":
            let index = try int("index")
            guard document.frameCount > 1 else { throw AgentOpError("cannot remove the last frame") }
            guard index >= 0, index < frameCount else { throw AgentOpError("frame \(index) is out of range") }
            document.snapshot()
            document.removeFrame(index)
            frame = min(frame, document.frameCount - 1)
            return [:]

        case "reorder_frame":
            let from = try int("from"), to = try int("to")
            guard from >= 0, to >= 0, from < frameCount, to < frameCount, from != to else {
                throw AgentOpError("frame reorder out of range")
            }
            document.snapshot()
            document.reorderFrame(from: from, to: to)
            frame = min(frame, frameCount - 1)
            return [:]

        case "set_frame_duration":
            let index = try int("index")
            guard index >= 0, index < frameCount else { throw AgentOpError("frame \(index) is out of range") }
            document.snapshot()
            document.setFrameDuration(index, ms: max(1, try int("ms")))
            return [:]

        case "go_to_frame":
            let index = try int("index")
            guard index >= 0, index < frameCount else { throw AgentOpError("frame \(index) is out of range") }
            frame = index
            return ["frame": frame]

        case "add_tag":
            document.snapshot()
            let ok = document.addTag(name: try string("name"), from: try int("from"), to: try int("to"),
                                     color: op["color"] as? String ?? "#7f7fff")
            guard ok else { throw AgentOpError("invalid tag range") }
            return [:]

        case "remove_tag":
            document.snapshot()
            _ = document.removeTag(name: try string("name"))
            return [:]

        case "resize":
            let w = try int("width"), h = try int("height")
            guard w > 0, h > 0 else { throw AgentOpError("resize needs positive width and height") }
            document.snapshot()
            document.resize(width: w, height: h)
            frame = min(frame, document.frameCount - 1)
            return ["width": document.width, "height": document.height]

        case "undo":
            return ["changed": document.undo()]
        case "redo":
            return ["changed": document.redo()]

        case "place_image":
            let image = try loadAgentImage(op, workspace: workspace, name: "place_image")
            let targetFrame = op["frame"] as? Int ?? frame
            guard targetFrame >= 0, targetFrame < frameCount else { throw AgentOpError("frame \(targetFrame) is out of range") }
            let index = try document.placeImageData(
                image.rgba, width: image.width, height: image.height,
                x: op["x"] as? Int ?? 0, y: op["y"] as? Int ?? 0,
                frame: targetFrame, name: op["name"] as? String ?? "AI image"
            )
            activeLayer = index
            frame = targetFrame
            return ["layer": index, "width": image.width, "height": image.height]

        case "stamp_image":
            let image = try loadAgentImage(op, workspace: workspace, name: "stamp_image")
            let layer = try int("layer"), f = try int("frame")
            try validateAgentCel(layer: layer, frame: f)
            document.snapshot()
            try document.stampImageData(image.rgba, width: image.width, height: image.height,
                                        x: try int("x"), y: try int("y"), layer: layer, frame: f)
            return [:]

        case "import_sheet":
            let image = try loadAgentImage(op, workspace: workspace, name: "import_sheet")
            let index = try document.importSheetData(
                image.rgba, width: image.width, height: image.height,
                cellWidth: width, cellHeight: height, name: op["name"] as? String ?? "Sheet"
            )
            activeLayer = index
            return ["layer": index]

        case "add_animation":
            let image = try loadAgentImage(op, workspace: workspace, name: "add_animation")
            let manifest = op["manifest"] as? String
                ?? SheetImport.gridManifest(cellWidth: width, cellHeight: height)
            let added = try document.appendSheet(
                rgba: image.rgba, width: image.width, height: image.height,
                manifest: manifest, layerName: op["name"] as? String ?? "Animation",
                replace: op["replace"] as? Bool ?? false
            )
            frame = max(0, document.frameCount - added)
            activeLayer = max(0, document.layerCount - 1)
            return ["frames_added": added]

        case "export_png":
            guard let workspace else { throw AgentOpError("export_png requires a workspace") }
            let path = try string("path")
            guard let url = EditorBridge.resolve(path, in: workspace) else {
                throw AgentOpError("export path '\(path)' escapes the workspace")
            }
            let index = op["frame"] as? Int ?? frame
            guard index >= 0, index < frameCount else { throw AgentOpError("frame \(index) is out of range") }
            let scale = max(1, op["scale"] as? Int ?? 1)
            let base = document.compositeRGBA(frame: index)
            let pixels = scale == 1 ? base : EditorModel.scalePixels(base, width: width, height: height, scale: scale)
            guard let data = AIService.rgbaToPNG(pixels, width: width * scale, height: height * scale) else {
                throw AgentOpError("could not encode the PNG")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return ["path": path, "bytes": data.count]

        default:
            throw AgentOpError("unknown op '\(name)'")
        }
    }

    private func validateAgentCel(layer: Int, frame index: Int) throws {
        guard layer >= 0, layer < document.layerCount else { throw AgentOpError("layer \(layer) is out of range") }
        guard index >= 0, index < frameCount else { throw AgentOpError("frame \(index) is out of range") }
    }

    /// Load a PNG from the conversation workspace for a placement op.
    private func loadAgentImage(_ op: [String: Any], workspace: URL?, name: String) throws -> (rgba: [UInt8], width: Int, height: Int) {
        guard let workspace else { throw AgentOpError("\(name) requires a workspace") }
        guard let path = op["path"] as? String else { throw AgentOpError("\(name) requires a 'path'") }
        guard let url = EditorBridge.resolve(path, in: workspace) else {
            throw AgentOpError("image '\(path)' escapes the workspace")
        }
        guard let data = try? Data(contentsOf: url), let decoded = AIService.pngToRGBA(data) else {
            throw AgentOpError("could not read image '\(path)' from the workspace")
        }
        return decoded
    }

    private static func scalePixels(_ pixels: [UInt8], width: Int, height: Int, scale: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * scale * height * scale * 4)
        for y in 0..<height * scale {
            let srcRow = y / scale
            for x in 0..<width * scale {
                let src = (srcRow * width + x / scale) * 4
                let dst = (y * width * scale + x) * 4
                out[dst] = pixels[src]
                out[dst + 1] = pixels[src + 1]
                out[dst + 2] = pixels[src + 2]
                out[dst + 3] = pixels[src + 3]
            }
        }
        return out
    }
}
