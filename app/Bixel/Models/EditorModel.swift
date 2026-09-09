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
    case pencil, eraser, fill, eyedropper
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pencil: return "pencil.tip"
        case .eraser: return "eraser"
        case .fill: return "paintbrush.pointed.fill"
        case .eyedropper: return "eyedropper"
        }
    }

    var label: String { rawValue.capitalized }
}

struct LayerInfo: Identifiable {
    let index: Int
    var name: String
    var visible: Bool
    var opacity: Double
    var id: Int { index }
}

final class EditorModel: ObservableObject {
    let document: Document
    let timeline: Timeline
    var assetKind: AssetKind = .sprite
    var cellWidth = 16
    var cellHeight = 16
    @Published var operationError: String?
    @Published var tileName: String?
    private var tileStamp: (rgba: [UInt8], width: Int, height: Int)?
    private var lastTile: (x: Int, y: Int)?

    // Tool + brush state
    @Published var tool: Tool = .pencil
    @Published var brushSize: Double = 3
    @Published var opacity: Double = 1.0
    @Published var currentColor: BixelColor = BixelColor(r: 24, g: 24, b: 24, a: 255)

    // Document state
    @Published var frame: Int = 0 { didSet { canvasChanged.send() } }
    @Published var playing: Bool = false
    @Published var activeLayer: Int = 0
    @Published var layers: [LayerInfo] = []

    // Playback settings
    @Published var fps: Double = 12 {
        didSet { timeline.setFPS(Float(fps)) }
    }
    @Published var loopMode: LoopMode = .forward {
        didSet { timeline.setLoopMode(loopMode) }
    }

    let canvasChanged = PassthroughSubject<Void, Never>()
    var onDocumentChanged: (() -> Void)?
    private var frameCache: [Int: [UInt8]] = [:]
    private var strokeChanged = false

    private func pixelsChanged(allFrames: Bool = false) {
        if allFrames { frameCache.removeAll() } else { frameCache[frame] = nil }
        thumbCache.removeAll()
        canvasChanged.send()
    }

    private func commitChange(allFrames: Bool = false) {
        pixelsChanged(allFrames: allFrames)
        objectWillChange.send()
        onDocumentChanged?()
    }

    private var playbackTimer: Timer?
    private var lastPoint: (x: Int, y: Int)?

    init(width: Int = 32, height: Int = 32, document restored: Document? = nil) {
        let document = restored ?? Document(width: width, height: height)
        self.document = document
        self.timeline = Timeline(document: document)
        reloadLayers()
    }

    // MARK: - Layer list

    func reloadLayers() {
        layers = (0..<document.layerCount).map { i in
            LayerInfo(index: i, name: document.layerName(i), visible: document.isLayerVisible(i),
                      opacity: Double(document.layerOpacity(i)))
        }
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
        document.removeLayer(activeLayer)
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
        activeLayer = to
        reloadLayers()
        commitChange(allFrames: true)
    }

    /// Thumbnail pixels for a layer at the current frame, cached per frame.
    func layerThumbnail(_ layer: Int) -> [UInt8] {
        let key = layer * 1_000_000 + frame
        if let cached = thumbCache[key] { return cached }
        let pixels = document.celRGBA(layer: layer, frame: frame)
        if thumbCache.count > 64 { thumbCache.removeAll() }
        thumbCache[key] = pixels
        return pixels
    }

    private var thumbCache: [Int: [UInt8]] = [:]

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
        if assetKind == .map, tileStamp != nil, tool == .pencil {
            document.snapshot()
            lastTile = nil
            paintTile(x: x, y: y)
            return
        }
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
        }
    }

    func continueStroke(x: Int, y: Int) {
        if assetKind == .map, tileStamp != nil, tool == .pencil { paintTile(x: x, y: y); return }
        guard let last = lastPoint, last.x != x || last.y != y else { return }
        switch tool {
        case .pencil, .eraser:
            document.stroke(layer: activeLayer, frame: frame, points: [last, (x, y)], color: strokeColor, radius: brushRadius)
            lastPoint = (x, y)
            strokeChanged = true
            pixelsChanged()
        default:
            break
        }
    }

    func endStroke(x: Int, y: Int) {
        if tool == .pencil || tool == .eraser { continueStroke(x: x, y: y) }
        lastPoint = nil
        lastTile = nil
        if strokeChanged {
            strokeChanged = false
            lastStrokeEnd = (x, y)
            commitChange()
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

    func pick(x: Int, y: Int) {
        let c = document.getPixel(layer: activeLayer, frame: frame, x: x, y: y)
        if c.a > 0 {
            currentColor = c
            opacity = 1.0
        }
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

    func removeFrame() {
        guard document.frameCount > 1 else { return }
        document.snapshot()
        document.removeFrame(frame)
        frame = min(frame, document.frameCount - 1)
        commitChange(allFrames: true)
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
        let px = x ?? max(0, (width - image.width) / 2)
        let py = y ?? max(0, (height - image.height) / 2)
        let snapX = assetKind == .map ? (px / max(1, cellWidth)) * cellWidth : px
        let snapY = assetKind == .map ? (py / max(1, cellHeight)) * cellHeight : py
        do {
            activeLayer = try document.placeImageData(image.rgba, width: image.width, height: image.height,
                                                       x: snapX, y: snapY, frame: frame, name: name)
            reloadLayers(); commitChange(allFrames: true)
        } catch { operationError = error.localizedDescription }
    }

    func importSheet(_ data: Data, name: String) {
        guard let image = AIService.pngToRGBA(data) else { operationError = "Could not decode the sheet."; return }
        do {
            activeLayer = try document.importSheetData(image.rgba, width: image.width, height: image.height,
                                                       cellWidth: width, cellHeight: height, name: name)
            frame = 0; reloadLayers(); commitChange(allFrames: true)
        } catch { operationError = error.localizedDescription }
    }

    func selectTile(_ data: Data, name: String) {
        guard let image = AIService.pngToRGBA(data), image.width == cellWidth, image.height == cellHeight else {
            operationError = "Select a tile matching this map's cell dimensions."; return
        }
        tileStamp = image; tileName = name; tool = .pencil
    }

    func clearTile() { tileStamp = nil; tileName = nil; lastTile = nil }

    private func paintTile(x: Int, y: Int) {
        guard let tileStamp else { return }
        let tile = (x: x / max(1, cellWidth), y: y / max(1, cellHeight))
        if let lastTile, tile == lastTile { return }
        do {
            try document.stampImageData(tileStamp.rgba, width: tileStamp.width, height: tileStamp.height,
                                        x: tile.x * cellWidth, y: tile.y * cellHeight, layer: activeLayer, frame: frame)
            lastTile = tile; strokeChanged = true; pixelsChanged()
        } catch { operationError = error.localizedDescription }
    }

    /// Image frames must match this document; generation must never resize it.
    func applyImageToNewFrame(_ rgba: [UInt8], width: Int, height: Int) {
        guard width == self.width, height == self.height else {
            operationError = "This image is \(width) × \(height). Prepare it to \(self.width) × \(self.height), or open it as its own document from the library."
            return
        }
        document.snapshot()
        let newFrame = document.addFrame(durationMs: 125)
        document.loadImageData(rgba, width: width, height: height, layer: 0, frame: newFrame)
        frame = newFrame; reloadLayers(); commitChange(allFrames: true)
    }

    func applyImageToCurrentFrame(_ rgba: [UInt8], width: Int, height: Int) {
        guard width == self.width, height == self.height else { operationError = "Image dimensions must match this document."; return }
        document.snapshot()
        document.loadImageData(rgba, width: width, height: height, layer: activeLayer, frame: frame)
        commitChange(allFrames: true)
    }
}
