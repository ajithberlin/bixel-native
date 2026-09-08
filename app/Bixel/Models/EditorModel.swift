// EditorModel.swift
//
// Observable application state: owns the Rust-backed Document + Timeline, the
// current tool/brush/color, the layer list, and a playback clock that drives
// the timeline. Views observe this; drawing gestures are funneled through here
// so a whole stroke becomes a single Rust FFI call (never per-pixel).

import Foundation
import Combine

enum Tool: String, CaseIterable, Identifiable {
    case pencil, eraser, fill, eyedropper, line
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pencil: return "pencil.tip"
        case .eraser: return "eraser"
        case .fill: return "paintbrush.pointed.fill"
        case .eyedropper: return "eyedropper"
        case .line: return "line.diagonal"
        }
    }

    var label: String { rawValue.capitalized }
}

struct LayerInfo: Identifiable {
    let index: Int
    var name: String
    var visible: Bool
    var id: Int { index }
}

final class EditorModel: ObservableObject {
    let document: Document
    let timeline: Timeline

    // Tool + brush state
    @Published var tool: Tool = .pencil
    @Published var brushSize: Double = 3
    @Published var opacity: Double = 1.0
    @Published var currentColor: BixelColor = BixelColor(r: 24, g: 24, b: 24, a: 255)

    // Document state
    @Published var frame: Int = 0
    @Published var playing: Bool = false
    @Published var activeLayer: Int = 0
    @Published var layers: [LayerInfo] = []

    private var playbackTimer: Timer?
    private var lastPoint: (x: Int, y: Int)?
    private var strokeCommitted = false

    init(width: Int = 32, height: Int = 32) {
        let document = Document(width: width, height: height)
        self.document = document
        self.timeline = Timeline(document: document)
        reloadLayers()
    }

    // MARK: - Layer list

    func reloadLayers() {
        layers = (0..<document.layerCount).map { i in
            LayerInfo(index: i, name: document.layerName(i), visible: document.isLayerVisible(i))
        }
    }

    func addLayer() {
        activeLayer = document.addLayer()
        reloadLayers()
    }

    func deleteLayer() {
        guard document.layerCount > 1 else { return }
        document.removeLayer(activeLayer)
        activeLayer = max(0, activeLayer - 1)
        reloadLayers()
    }

    func toggleLayerVisibility(_ index: Int) {
        let newValue = !document.isLayerVisible(index)
        document.setLayerVisible(index, newValue)
        reloadLayers()
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
        switch tool {
        case .eyedropper:
            pick(x: x, y: y)
        case .fill:
            document.snapshot()
            document.floodFill(layer: activeLayer, frame: frame, x: x, y: y, drawColor)
            objectWillChange.send()
        case .line:
            document.snapshot()
            lastPoint = (x, y)
            strokeCommitted = false
        case .pencil, .eraser:
            document.snapshot()
            lastPoint = (x, y)
            document.stroke(layer: activeLayer, frame: frame, points: [(x, y)], color: strokeColor, radius: brushRadius)
            objectWillChange.send()
        }
    }

    func continueStroke(x: Int, y: Int) {
        guard let last = lastPoint else { return }
        switch tool {
        case .pencil, .eraser:
            document.stroke(layer: activeLayer, frame: frame, points: [last, (x, y)], color: strokeColor, radius: brushRadius)
            lastPoint = (x, y)
            objectWillChange.send()
        case .line:
            // No live preview for line; committed on end.
            break
        default:
            break
        }
    }

    func endStroke(x: Int, y: Int) {
        if tool == .line, let start = lastPoint, !strokeCommitted {
            document.stroke(layer: activeLayer, frame: frame, points: [start, (x, y)], color: strokeColor, radius: brushRadius)
            strokeCommitted = true
            objectWillChange.send()
        }
        lastPoint = nil
    }

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
    }

    func duplicateFrame() {
        // Copy the current frame's active layer cel into a brand-new frame.
        let src = document.compositeRGBA(frame: frame)
        let newFrame = document.addFrame(durationMs: 125)
        document.loadImageData(src, width: width, height: height, layer: 0, frame: newFrame)
        frame = newFrame
    }

    func undo() { _ = document.undo(); objectWillChange.send() }
    func redo() { _ = document.redo(); objectWillChange.send() }

    // MARK: - Canvas

    var width: Int { document.width }
    var height: Int { document.height }
    var frameCount: Int { document.frameCount }

    func compositeCurrentFrame() -> [UInt8] {
        document.compositeRGBA(frame: frame)
    }

    func compositeFrame(_ index: Int) -> [UInt8] {
        document.compositeRGBA(frame: index)
    }

    // MARK: - AI result application

    /// Load an RGBA buffer (e.g. an AI result) into a brand-new frame.
    func applyImageToNewFrame(_ rgba: [UInt8], width: Int, height: Int) {
        let newFrame = document.addFrame(durationMs: 125)
        document.loadImageData(rgba, width: width, height: height, layer: 0, frame: newFrame)
        frame = newFrame
        reloadLayers()
    }

    /// Replace the current frame's base layer with an RGBA buffer.
    func applyImageToCurrentFrame(_ rgba: [UInt8], width: Int, height: Int) {
        document.snapshot()
        document.loadImageData(rgba, width: width, height: height, layer: 0, frame: frame)
        objectWillChange.send()
    }
}
