// TileMapModel.swift
//
// Observable application state for the Tilemap Designer (.map documents).
// Mirrors EditorModel's conventions: owns the Rust-backed TileMap + tool/brush
// state, a 60 Hz coalescing refresh timer, per-layer metadata loaded in bulk,
// and export/import entry points. The whole map (Tiled JSON) is the document;
// tileset PNGs are project assets referenced by relative path.

import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers
import Combine

enum MapTool: String, CaseIterable, Identifiable {
    case stamp, terrain, eraser, bucket, rectFill, line, select, move, tilePicker, wand
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .stamp: return "paintbrush.pointed"
        case .terrain: return "mountain.2.fill"
        case .eraser: return "eraser"
        case .bucket: return "drop.fill"
        case .rectFill: return "square.on.square"
        case .line: return "line.diagonal"
        case .select: return "lasso"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .tilePicker: return "eyedropper"
        case .wand: return "wand.and.rays"
        }
    }

    var label: String {
        switch self {
        case .stamp: return "Stamp"
        case .terrain: return "Terrain"
        case .eraser: return "Eraser"
        case .bucket: return "Fill"
        case .rectFill: return "Rectangle"
        case .line: return "Line"
        case .select: return "Select"
        case .move: return "Move"
        case .tilePicker: return "Pick tile"
        case .wand: return "Magic wand"
        }
    }

    /// Tools surfaced in the map top bar (wand stays available by shortcut only).
    static let toolbar: [MapTool] = [.stamp, .terrain, .eraser, .bucket, .rectFill, .line, .select, .move, .tilePicker]
}

/// A cell-aligned selection rectangle (inclusive corners → width/height ≥ 1).
struct MapCellRect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var isEmpty: Bool { width <= 0 || height <= 0 }

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    static func between(_ a: (x: Int, y: Int), _ b: (x: Int, y: Int)) -> MapCellRect {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        return MapCellRect(x: x0, y: y0, width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)
    }
}

/// The armed brush: a raw-GID pattern plus the tileset it came from.
struct MapBrush {
    var pattern: MapTilePattern
    /// Index of the source tileset when this brush was drag-selected there.
    var tilesetIndex: Int? = nil
    /// Local tile id used as the "ground" for autotile painting.
    var groundTile: UInt32? = nil

    var isEraser: Bool { pattern.tiles.allSatisfy { $0 == 0 } }
}

final class TileMapModel: ObservableObject {
    let map: TileMap

    @Published var operationError: String?

    // Tool + brush state
    @Published var tool: MapTool = .stamp
    @Published var brush = MapBrush(pattern: MapTilePattern())
    @Published var clipboard: MapTilePattern? = nil
    @Published var selection: MapCellRect?
    @Published var activeLayer: Int = 0
    @Published var layers: [MapLayerRow] = []
    @Published var tileName: String?
    @Published var autotileEnabled = false

    // Projection (mirrors the Rust TileMap; kept in sync via reloadGeometry).
    @Published var orientation: MapOrientation = .orthogonal
    @Published var renderOrder: MapRenderOrder = .rightDown
    @Published var staggerAxis: MapStaggerAxis = .y
    @Published var staggerIndex: MapStaggerIndex = .odd

    /// True while the paste ghost is floating (committed on the next stamp).
    @Published var hasPasteGhost = false

    /// Last pointer position in whole-map tile pixels (for ghost overlays).
    /// Deliberately not `@Published`: hover changes are pushed straight to the
    /// canvas overlay so mouse movement never triggers a SwiftUI body pass.
    var hoverPixel: (x: Int, y: Int)?

    /// Tileset metadata + display images for the tileset panel.
    @Published var tilesetList: [MapTilesetInfo] = []
    private var tilesetImages: [Int: CGImage] = [:]
    private var tilesetAutotileCache: [Int: [Int32?]] = [:]

    /// Host hook to persist a dropped/picked image into the project's assets and
    /// return its workspace-relative path, so image layers survive save/reload.
    /// Wired by ProjectStore; nil falls back to an in-memory-only layer.
    var persistAssetData: ((Data, String) -> String?)?

    /// Object editing state (phase 2): the object under the pointer, if any.
    @Published var selectedObjectID: Int?

    let canvasChanged = PassthroughSubject<Void, Never>()
    private(set) var canvasRevision = 0
    var onDocumentChanged: (() -> Void)?

    private var lastCell: (x: Int, y: Int)?
    private var strokeChanged = false
    private var moveOrigin: (x: Int, y: Int)?
    private var moveGrab: (x: Int, y: Int)?

    var width: Int { map.columns }
    var height: Int { map.rows }

    /// True for an unbounded Tiled infinite scene (chunked storage).
    var isInfinite: Bool { map.isInfinite }

    var isObjectActive: Bool {
        activeLayer < layers.count && layers[activeLayer].type == "object"
    }

    var activeIsTile: Bool { !isObjectActive }

    init(width: Int, height: Int, tileWidth: Int = 16, tileHeight: Int = 16) {
        self.map = TileMap(width: width, height: height, tileWidth: tileWidth, tileHeight: tileHeight)
        reloadLayers()
        reloadGeometry()
        registerTilesets()
    }

    /// Create an unbounded Tiled infinite scene (chunked on save). No size.
    init(infiniteOrientation orientation: MapOrientation, tileWidth: Int = 16, tileHeight: Int = 16) {
        self.map = TileMap(infiniteTileWidth: tileWidth, tileHeight: tileHeight, orientation: orientation)
        reloadLayers()
        reloadGeometry()
        registerTilesets()
    }

    init(map restored: TileMap) {
        self.map = restored
        reloadLayers()
        reloadGeometry()
        registerTilesets()
    }

    init(json: String) throws {
        self.map = try TileMap(json: json)
        reloadLayers()
        reloadGeometry()
        registerTilesets()
    }

    // MARK: - Change plumbing (mirrors EditorModel)

    private func notifyCanvasChanged() {
        canvasRevision += 1
        canvasChanged.send()
    }

    private func flushCanvasRefreshNow() {
        notifyCanvasChanged()
    }

    func commitChange() {
        objectWillChange.send()
        onDocumentChanged?()
        flushCanvasRefreshNow()
    }

    // MARK: - Layer list

    func reloadLayers() {
        layers = map.layersInfo()
        if layers.isEmpty {
            activeLayer = 0
        } else {
            activeLayer = min(max(0, activeLayer), layers.count - 1)
        }
    }

    /// Pull the projection settings back out of the engine (after load/undo).
    func reloadGeometry() {
        orientation = map.orientation
        renderOrder = map.renderOrder
        staggerAxis = map.staggerAxis
        staggerIndex = map.staggerIndex
    }

    // MARK: - Projection

    func setOrientation(_ value: MapOrientation) {
        guard value != map.orientation else { return }
        map.snapshot()
        map.setOrientation(value)
        reloadGeometry()
        selection = nil
        commitChange()
    }

    func setRenderOrder(_ value: MapRenderOrder) {
        guard value != map.renderOrder else { return }
        map.snapshot()
        map.setRenderOrder(value)
        reloadGeometry()
        commitChange()
    }

    func setStaggerAxis(_ value: MapStaggerAxis) {
        guard value != map.staggerAxis else { return }
        map.snapshot()
        map.setStaggerAxis(value)
        reloadGeometry()
        commitChange()
    }

    func setStaggerIndex(_ value: MapStaggerIndex) {
        guard value != map.staggerIndex else { return }
        map.snapshot()
        map.setStaggerIndex(value)
        reloadGeometry()
        commitChange()
    }

    /// Top-left screen pixel of a cell's tile image.
    func cellOrigin(_ x: Int, _ y: Int) -> (x: Int, y: Int) {
        map.cellOrigin(x: x, y: y)
    }

    /// Centre of a cell's tile image.
    func cellCenter(_ x: Int, _ y: Int) -> (x: Int, y: Int) {
        map.cellCenter(x: x, y: y)
    }

    /// Whole-map pixel -> cell. Returns nil off the artboard unless `clamp`.
    func cell(atPixel pixel: (x: Int, y: Int), clamp: Bool = false) -> (x: Int, y: Int)? {
        let hit = map.pixelToCell(x: Double(pixel.x), y: Double(pixel.y))
        if clamp {
            let cx = min(max(0, hit.x), max(0, width - 1))
            let cy = min(max(0, hit.y), max(0, height - 1))
            return (cx, cy)
        }
        guard hit.inside else { return nil }
        return (hit.x, hit.y)
    }

    /// Projected cell for a pixel, even far outside finite bounds (infinite maps).
    func rawCell(atPixel pixel: (x: Int, y: Int)) -> (x: Int, y: Int) {
        let hit = map.pixelToCell(x: Double(pixel.x), y: Double(pixel.y))
        return (hit.x, hit.y)
    }

    /// Whether a Move gesture starting at this cell should manipulate the
    /// current tile selection. Empty scene space belongs to camera panning.
    func canMoveSelection(at x: Int, y: Int) -> Bool {
        guard isActiveLayerTile, let rect = selection, !rect.isEmpty,
              x >= rect.x, x < rect.x + rect.width,
              y >= rect.y, y < rect.y + rect.height else { return false }
        let pattern = map.readRegion(layer: activeLayer, x: rect.x, y: rect.y,
                                     w: rect.width, h: rect.height)
        return pattern.tiles.contains { $0 != 0 }
    }

    /// World-pixel bounds of the content (infinite maps), matching the
    /// whole-content composite returned by `compositeRGBA()`.
    func contentPixelBounds() -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let cb = map.contentBounds else { return nil }
        let corners = [(cb.minX, cb.minY), (cb.maxX, cb.minY), (cb.minX, cb.maxY), (cb.maxX, cb.maxY)]
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for corner in corners {
            let origin = map.cellOrigin(x: corner.0, y: corner.1)
            minX = min(minX, origin.x)
            minY = min(minY, origin.y)
            maxX = max(maxX, origin.x + map.cellWidth)
            maxY = max(maxY, origin.y + map.cellHeight)
        }
        return (minX, minY, max(0, maxX - minX), max(0, maxY - minY))
    }

    var isActiveLayerTile: Bool {
        guard activeLayer < layers.count else { return true }
        return layers[activeLayer].type == "tile"
    }

    var canPaint: Bool {
        guard map.layerCount > 0, activeLayer < layers.count else { return false }
        return layers[activeLayer].type == "tile"
    }

    func addLayer() {
        map.snapshot()
        activeLayer = map.addLayer()
        reloadLayers()
        commitChange()
    }

    func addObjectLayer() {
        map.snapshot()
        activeLayer = map.addObjectLayer()
        reloadLayers()
        commitChange()
    }

    func deleteLayer() {
        guard map.layerCount > 1 else { return }
        map.snapshot()
        map.removeLayer(activeLayer)
        activeLayer = max(0, activeLayer - 1)
        selectedObjectID = nil
        reloadLayers()
        commitChange()
    }

    func renameLayer(_ index: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        map.snapshot()
        map.renameLayer(index, name: trimmed)
        reloadLayers()
        objectWillChange.send()
        onDocumentChanged?()
    }

    func toggleLayerVisibility(_ index: Int) {
        map.setLayerVisible(index, !(layers[index].visible))
        reloadLayers()
        commitChange()
    }

    func setLayerOpacity(_ index: Int, _ value: Double) {
        map.setLayerOpacity(index, value)
        reloadLayers()
        commitChange()
    }

    func moveLayer(from: Int, to: Int) {
        guard from != to, from >= 0, to >= 0, from < map.layerCount, to < map.layerCount else { return }
        map.snapshot()
        map.reorderLayer(from: from, to: to)
        activeLayer = to
        reloadLayers()
        commitChange()
    }

    // MARK: - Brush

    /// Arm a single-tile brush from a local tile id of the given tileset.
    func armTile(tilesetIndex: Int, localTile: UInt32) {
        let ts = tileset(tilesetIndex)
        let gid = TileMap.encodeGID(localTile, firstGID: ts.firstGid)
        brush = MapBrush(pattern: MapTilePattern(width: 1, height: 1, tiles: [gid]),
                         tilesetIndex: tilesetIndex, groundTile: localTile)
        tool = .stamp
        tileName = ts.name
    }

    /// Arm a multi-tile brush from a drag-selected region of a tileset image,
    /// anchored at the top-left cell the drag started on.
    func armRegion(tilesetIndex: Int, startCol: Int, startRow: Int, cols: Int, rows: Int) {
        let ts = tileset(tilesetIndex)
        var gids: [UInt32] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let local = UInt32((startRow + row) * ts.columns + (startCol + col))
                gids.append(TileMap.encodeGID(local, firstGID: ts.firstGid))
            }
        }
        brush = MapBrush(pattern: MapTilePattern(width: cols, height: rows, tiles: gids),
                         tilesetIndex: tilesetIndex, groundTile: gids.first)
        tool = .stamp
        tileName = ts.name
    }

    func clearBrush() {
        brush = MapBrush(pattern: MapTilePattern())
        tileName = nil
        autotileEnabled = false
    }

    func flipBrushH() { brush.pattern.flipH(); objectWillChange.send() }
    func flipBrushV() { brush.pattern.flipV(); objectWillChange.send() }
    func rotateBrushCW() { brush.pattern.rotateCW(); objectWillChange.send() }
    func rotateBrushCCW() { brush.pattern.rotateCCW(); objectWillChange.send() }

    // MARK: - Tileset registry

    /// Record a loaded tileset image and rebuild the panel metadata.
    func registerTilesets() {
        tilesetList = map.tilesetsInfo()
        // Build display images for any tileset whose pixels Rust still holds.
        // Pass the parsed info so each tileset doesn't re-parse the FFI JSON.
        for info in tilesetList where tilesetImages[info.index] == nil {
            let rgba = map.tilesetPixels(info: info)
            if let cg = makeCGImage(pixels: rgba, width: info.imageWidth, height: info.imageHeight) {
                tilesetImages[info.index] = cg
            }
        }
        tilesetAutotileCache = [:]
    }

    /// Decoded tileset pixels were already pushed into the FFI by the host;
    /// keep the CGImage for the panel and refresh the tile palette.
    func attachTilesetImage(_ index: Int, cgImage: CGImage) {
        tilesetImages[index] = cgImage
        registerTilesets()
    }

    /// Push decoded tileset RGBA into the engine and cache its display image.
    /// Does not re-parse the tileset list — the host uploads many in a row.
    func uploadTileset(_ index: Int, cgImage: CGImage, rgba: [UInt8]) {
        _ = map.setTilesetPixels(index, rgba: rgba)
        tilesetImages[index] = cgImage
        objectWillChange.send()
    }

    /// Bump the canvas revision once after a batch of host-side mutations
    /// (e.g. uploading every tileset) so the map composites exactly once.
    func refreshCanvas() {
        notifyCanvasChanged()
    }

    func tilesetDisplayImage(_ index: Int) -> CGImage? {
        tilesetImages[index]
    }

    // MARK: - Brush preview

    private var brushPreviewCache: CGImage?
    private var brushPreviewKey = ""

    /// Compose the armed brush pattern into one image (source tiles, with Tiled
    /// orientation flags applied) for the low-opacity hover ghost, so the user
    /// can see exactly which tile(s) will be stamped.
    func brushPreviewImage() -> CGImage? {
        let pattern = brush.pattern
        guard !pattern.isEmpty else { return nil }
        let cw = map.cellWidth
        let ch = map.cellHeight
        guard cw > 0, ch > 0 else { return nil }
        let key = "\(pattern.width)x\(pattern.height)|\(cw)x\(ch)|\(tilesetList.count)|"
            + pattern.tiles.map(String.init).joined(separator: ",")
        if key == brushPreviewKey { return brushPreviewCache }
        brushPreviewKey = key
        brushPreviewCache = composeBrushPreview(pattern: pattern, cellWidth: cw, cellHeight: ch)
        return brushPreviewCache
    }

    private func composeBrushPreview(pattern: MapTilePattern, cellWidth cw: Int, cellHeight ch: Int) -> CGImage? {
        let w = pattern.width * cw
        let h = pattern.height * ch
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        for row in 0..<pattern.height {
            for col in 0..<pattern.width {
                let gid = pattern.tiles[row * pattern.width + col]
                guard let (info, local) = tilesetAndLocal(forGID: gid), local != 0,
                      info.columns > 0, info.tileWidth > 0, info.tileHeight > 0,
                      let source = tilesetDisplayImage(info.index) else { continue }
                let stride = info.tileWidth + info.spacing
                let tcol = Int(local) % info.columns
                let trow = Int(local) / info.columns
                let crop = CGRect(x: info.margin + tcol * stride,
                                  y: info.margin + trow * stride,
                                  width: info.tileWidth, height: info.tileHeight)
                guard let tile = source.cropping(to: crop) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(col * cw) + CGFloat(cw) / 2,
                                y: CGFloat(h - (row + 1) * ch) + CGFloat(ch) / 2)
                if gid & GIDFlag.diagonal != 0 {
                    ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
                }
                if gid & GIDFlag.horizontal != 0 {
                    ctx.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0))
                }
                if gid & GIDFlag.vertical != 0 {
                    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
                }
                ctx.draw(tile, in: CGRect(x: -CGFloat(cw) / 2, y: -CGFloat(ch) / 2,
                                          width: CGFloat(cw), height: CGFloat(ch)))
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }

    /// Resolve a raw GID to its tileset and local tile id (flags stripped).
    private func tilesetAndLocal(forGID gid: UInt32) -> (MapTilesetInfo, UInt32)? {
        let base = gid & ~(GIDFlag.horizontal | GIDFlag.vertical | GIDFlag.diagonal)
        guard base != 0 else { return nil }
        var match: MapTilesetInfo?
        for info in tilesetList {
            if base >= info.firstGid { match = info } else { break }
        }
        guard let info = match, base >= info.firstGid else { return nil }
        return (info, base - info.firstGid)
    }

    // MARK: - Image layers

    /// Add a decoded RGBA image as a real map layer: it appears in the layers
    /// panel, is composited by the engine, saved with the map and can be
    /// reordered/hidden/deleted or covered by tile layers above it.
    @discardableResult
    func addImageLayer(rgba: [UInt8], width: Int, height: Int, name: String, imagePath: String) -> Bool {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return false }
        map.snapshot()
        let index = map.addImageLayer(name: name, image: imagePath, rgba: rgba,
                                      imageWidth: width, imageHeight: height)
        guard index >= 0 else { return false }
        // New image layers start at the bottom so tile layers drawn afterwards
        // (or already present) cover them — an image layer is a backdrop by
        // default, but stays fully reorderable in the layers panel.
        if index > 0 { map.reorderLayer(from: index, to: 0) }
        activeLayer = 0
        reloadLayers()
        commitChange()
        return true
    }

    /// Decode dropped/picked image data and add it as an image layer, persisting
    /// the bytes into the project assets when a host hook is installed.
    @discardableResult
    func addImageLayer(data: Data, name: String) -> Bool {
        guard let image = AIService.pngToRGBA(data) else {
            operationError = "Could not decode that image."
            return false
        }
        let path = persistAssetData?(data, name) ?? ""
        return addImageLayer(rgba: image.rgba, width: image.width, height: image.height,
                             name: name, imagePath: path)
    }

    /// Push decoded image-layer pixels into the engine after a project reload.
    func uploadImageLayer(_ index: Int, rgba: [UInt8]) {
        _ = map.setImageLayerPixels(index, rgba: rgba)
        objectWillChange.send()
    }

    func removeTileset(_ index: Int) {
        map.snapshot()
        map.removeTileset(index)
        // Indices shift down and later GIDs are remapped, so drop every cached
        // image and rebuild from the engine's (still valid) pixel buffers.
        tilesetImages.removeAll()
        tilesetAutotileCache.removeAll()
        registerTilesets()
        if brush.tilesetIndex == index { clearBrush() }
        commitChange()
    }

    func tilesetAutotile(_ index: Int) -> [Int32?] {
        if let cached = tilesetAutotileCache[index] { return cached }
        let slots = map.autotileSlots(tileset: index)
        tilesetAutotileCache[index] = slots
        return slots
    }

    func setTilesetAutotile(tileset: Int, mask: Int, local: Int32?) {
        map.snapshot()
        map.setAutotile(tileset: tileset, mask: mask, local: local)
        tilesetAutotileCache[tileset] = nil
        commitChange()
    }

    private func tileset(_ index: Int) -> MapTilesetInfo {
        let info = map.tilesetsInfo()
        if index >= 0 && index < info.count {
            return info[index]
        }
        return info.first ?? MapTilesetInfo(index: 0, firstGid: 1, name: "", image: "",
                                           imageWidth: 0, imageHeight: 0, tileWidth: 16,
                                           tileHeight: 16, margin: 0, spacing: 0, columns: 1, tileCount: 1)
    }

    // MARK: - Painting gestures (cells)

    func beginStroke(x: Int, y: Int) {
        if !isInfinite { guard x >= 0, y >= 0, x < width, y < height else { return } }
        if hasPasteGhost {
            commitPaste(at: x, y: y)
            return
        }
        lastCell = (x, y)
        strokeChanged = false
        switch tool {
        case .select:
            selection = MapCellRect(x: x, y: y, width: 1, height: 1)
            hasPasteGhost = false
        case .move:
            beginMove(x: x, y: y)
        case .tilePicker:
            pickTile(x: x, y: y)
        case .wand:
            applyWand(x: x, y: y)
        default:
            if isObjectActive {
                beginObjectTool(x: x, y: y)
                return
            }
            guard canPaint else { return }
            map.snapshot()
            strokeChanged = paintCell(x: x, y: y)
        }
    }

    func continueStroke(x: Int, y: Int) {
        if !isInfinite { guard x >= 0, y >= 0, x < width, y < height else { return } }
        switch tool {
        case .select:
            guard let start = selection else { return }
            let rect = MapCellRect.between((start.x, start.y), (x, y))
            selection = rect
            return
        case .move:
            continueMove(x: x, y: y)
            return
        case .tilePicker:
            return
        case .wand:
            return
        default:
            if isObjectActive {
                continueObjectTool(x: x, y: y)
                return
            }
            guard canPaint else { return }
            let last = lastCell ?? (x, y)
            guard last.x != x || last.y != y else { return }
            strokeChanged = paintStroke(from: last, to: (x, y)) || strokeChanged
            lastCell = (x, y)
        }
    }

    func endStroke(x: Int, y: Int) {
        if strokeChanged {
            strokeChanged = false
            commitChange()
        }
        if tool == .select, let selection {
            if selection.width == 1 && selection.height == 1 {
                // A plain click on an object layer selects an object instead.
                if isObjectActive {
                    let center = map.cellCenter(x: selection.x, y: selection.y)
                    selectObject(at: CGFloat(center.x), y: CGFloat(center.y))
                }
            }
        }
        if tool == .move {
            finishMove(x: x, y: y)
        }
        finishObjectTool()
        lastCell = nil
        objectWillChange.send()
    }

    // MARK: - Move tool

    /// Grab the current selection (or start a new one) to reposition a block.
    private func beginMove(x: Int, y: Int) {
        if isObjectActive {
            beginObjectTool(x: x, y: y)
            return
        }
        guard isActiveLayerTile else { return }
        if let rect = selection,
           x >= rect.x, x < rect.x + rect.width,
           y >= rect.y, y < rect.y + rect.height {
            let pattern = map.readRegion(layer: activeLayer, x: rect.x, y: rect.y, w: rect.width, h: rect.height)
            guard pattern.tiles.contains(where: { $0 != 0 }) else { return }
            map.snapshot()
            map.paintRect(layer: activeLayer, x0: rect.x, y0: rect.y,
                          x1: rect.x + rect.width - 1, y1: rect.y + rect.height - 1, gid: 0)
            clipboard = pattern
            brush = MapBrush(pattern: pattern)
            hasPasteGhost = true
            moveOrigin = (rect.x, rect.y)
            moveGrab = (x, y)
            // Reflect the lifted block immediately so the source empties as the
            // ghost starts following the pointer.
            commitChange()
        } else {
            selection = MapCellRect(x: x, y: y, width: 1, height: 1)
            moveOrigin = nil
            moveGrab = nil
        }
    }

    private func continueMove(x: Int, y: Int) {
        if hasPasteGhost, let origin = moveOrigin, let grab = moveGrab {
            let anchorX = origin.x + (x - grab.x)
            let anchorY = origin.y + (y - grab.y)
            let width = clipboard?.width ?? 1
            let height = clipboard?.height ?? 1
            selection = MapCellRect(x: anchorX, y: anchorY, width: width, height: height)
            // The map projection may offset or skew a cell (isometric and
            // staggered scenes), so the ghost must follow the engine's
            // orientation-aware origin rather than raw orthogonal math.
            hoverPixel = map.cellOrigin(x: anchorX, y: anchorY)
        } else if let start = selection {
            selection = MapCellRect.between((start.x, start.y), (x, y))
        }
    }

    private func finishMove(x: Int, y: Int) {
        defer { moveOrigin = nil; moveGrab = nil }
        guard hasPasteGhost, let origin = moveOrigin, let grab = moveGrab else { return }
        let anchorX = origin.x + (x - grab.x)
        let anchorY = origin.y + (y - grab.y)
        map.stamp(layer: activeLayer, x: anchorX, y: anchorY, pattern: brush.pattern, skipEmpty: false)
        hasPasteGhost = false
        selection = MapCellRect(x: anchorX, y: anchorY,
                                width: brush.pattern.width, height: brush.pattern.height)
        commitChange()
    }

    func eraseSelection() {
        guard let rect = selection, isActiveLayerTile else { return }
        map.snapshot()
        map.paintRect(layer: activeLayer, x0: rect.x, y0: rect.y,
                      x1: rect.x + rect.width - 1, y1: rect.y + rect.height - 1, gid: 0)
        selection = nil
        commitChange()
    }

    // MARK: - Tile painting helpers

    func paintCell(x: Int, y: Int) -> Bool {
        if tool == .eraser {
            map.setTile(layer: activeLayer, x: x, y: y, gid: 0)
            return true
        }
        let pattern = brush.pattern
        if pattern.isEmpty {
            return false
        }
        if pattern.width == 1 && pattern.height == 1 {
            let gid = pattern.tiles.first ?? 0
            map.setTile(layer: activeLayer, x: x, y: y, gid: gid)
            if (autotileEnabled || tool == .terrain), let ts = brush.tilesetIndex, gid != 0 {
                _ = map.autotile(layer: activeLayer, tileset: ts, x: x, y: y, w: 1, h: 1)
            }
            return true
        }
        return map.stamp(layer: activeLayer, x: x, y: y, pattern: pattern, skipEmpty: true) > 0
    }

    /// Paint a stroke segment so fast strokes never skip cells.
    func paintStroke(from a: (x: Int, y: Int), to b: (x: Int, y: Int)) -> Bool {
        let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1
        let sy = a.y < b.y ? 1 : -1
        var err = dx - dy
        var (cx, cy) = (a.x, a.y)
        var changed = false
        while true {
            if paintCell(x: cx, y: cy) { changed = true }
            if cx == b.x && cy == b.y { break }
            let e2 = 2 * err
            if e2 > -dy { err -= dy; cx += sx }
            if e2 < dx { err += dx; cy += sy }
        }
        return changed
    }

    func pickTile(x: Int, y: Int) {
        guard isActiveLayerTile else { return }
        let gid = map.getTile(layer: activeLayer, x: x, y: y)
        if gid != 0 {
            brush = MapBrush(pattern: MapTilePattern(width: 1, height: 1, tiles: [gid]), tilesetIndex: nil)
            tileName = nil
            tool = .stamp
        }
    }

    func fill(x: Int, y: Int, gid: UInt32? = nil) {
        guard isActiveLayerTile else { return }
        let gid = gid ?? brush.pattern.tiles.first ?? 0
        map.snapshot()
        _ = map.fill(layer: activeLayer, x: x, y: y, gid: gid)
        commitChange()
    }

    func applyWand(x: Int, y: Int) {
        guard isActiveLayerTile else { return }
        let mask = map.wandMask(layer: activeLayer, x: x, y: y)
        guard mask.contains(true) else { return }
        let cols = map.columns
        let rows = map.rows
        let ox = map.originX
        let oy = map.originY
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var idx = 0
        for row in 0..<rows {
            for col in 0..<cols {
                if mask[idx] {
                    let wx = col + ox
                    let wy = row + oy
                    minX = min(minX, wx); maxX = max(maxX, wx)
                    minY = min(minY, wy); maxY = max(maxY, wy)
                }
                idx += 1
            }
        }
        guard maxX >= minX, maxY >= minY else { return }
        selection = MapCellRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        objectWillChange.send()
    }

    // MARK: - Selection clipboard

    func copySelection() {
        guard let rect = selection, isActiveLayerTile else { return }
        clipboard = map.readRegion(layer: activeLayer, x: rect.x, y: rect.y, w: rect.width, h: rect.height)
        // A crop of the composite also lands on the pasteboard as a PNG.
        if let png = croppedCompositePNG(rect) {
            PlatformPasteboard.copy(pngData: png)
        }
    }

    func cutSelection() {
        copySelection()
        eraseSelection()
    }

    func deleteSelection() {
        eraseSelection()
    }

    func beginPaste() {
        guard let clip = clipboard, !clip.isEmpty else { return }
        brush = MapBrush(pattern: clip)
        hasPasteGhost = true
        tool = .stamp
        tileName = "Paste"
    }

    func commitPaste(at x: Int, y: Int) {
        guard hasPasteGhost, !brush.pattern.isEmpty else { return }
        map.snapshot()
        _ = map.stamp(layer: activeLayer, x: x, y: y, pattern: brush.pattern, skipEmpty: false)
        hasPasteGhost = false
        commitChange()
    }

    /// Clamped pixel bounds of a cell selection in the composite. For isometric
    /// maps this is the parallelogram's axis-aligned bounding box.
    func compositeCropBounds(_ rect: MapCellRect) -> (x: Int, y: Int, width: Int, height: Int) {
        let corners = [
            (rect.x, rect.y),
            (rect.x + rect.width - 1, rect.y),
            (rect.x, rect.y + rect.height - 1),
            (rect.x + rect.width - 1, rect.y + rect.height - 1),
        ]
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for corner in corners {
            let origin = map.cellOrigin(x: corner.0, y: corner.1)
            minX = min(minX, origin.x)
            minY = min(minY, origin.y)
            maxX = max(maxX, origin.x + map.cellWidth)
            maxY = max(maxY, origin.y + map.cellHeight)
        }
        let startX = max(0, minX)
        let startY = max(0, minY)
        let width = min(map.pixelWidth, maxX) - startX
        let height = min(map.pixelHeight, maxY) - startY
        return (startX, startY, max(0, width), max(0, height))
    }

    func cropOfComposite(_ rect: MapCellRect) -> [UInt8] {
        guard !isInfinite else { return [] }
        let pixels = map.compositeRGBA()
        let fullW = map.pixelWidth
        let bounds = compositeCropBounds(rect)
        guard fullW > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: bounds.width * bounds.height * 4)
        for row in 0..<bounds.height {
            let src = ((bounds.y + row) * fullW + bounds.x) * 4
            let dst = row * bounds.width * 4
            for i in 0..<bounds.width * 4 {
                out[dst + i] = pixels[src + i]
            }
        }
        return out
    }

    private func croppedCompositePNG(_ rect: MapCellRect) -> Data? {
        let bounds = compositeCropBounds(rect)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rgba = cropOfComposite(rect)
        guard let cg = makeCGImage(pixels: rgba, width: bounds.width, height: bounds.height) else { return nil }
        return pngData(from: cg)
    }

    // MARK: - Objects

    private var objectDrag: (objectID: Int, startX: Double, startY: Double, mode: ObjectDragMode)?
    private enum ObjectDragMode { case none, move, create, resizeCorner }

    private func objectsOnActiveLayer() -> [MapObjectRow] {
        map.objects(layer: activeLayer)
    }

    private func object(at point: CGPoint) -> MapObjectRow? {
        for obj in objectsOnActiveLayer().reversed() {
            if obj.type == "point" {
                let hit = (obj.x...obj.x + 8).contains(Double(point.x)) && (obj.y...obj.y + 8).contains(Double(point.y))
                if hit { return obj }
            } else {
                let rect = CGRect(x: obj.x, y: obj.y, width: max(8, obj.width), height: max(8, obj.height))
                if rect.contains(point) { return obj }
            }
        }
        return nil
    }

    func selectObject(at px: CGFloat, y py: CGFloat) {
        guard isObjectActive else { selectedObjectID = nil; return }
        selectedObjectID = object(at: CGPoint(x: px, y: py))?.id
        objectWillChange.send()
    }

    private func beginObjectTool(x: Int, y: Int) {
        guard isObjectActive else { return }
        let center = map.cellCenter(x: x, y: y)
        let px = Double(center.x)
        let py = Double(center.y)
        if let hit = object(at: CGPoint(x: px, y: py)) {
            selectedObjectID = hit.id
            objectDrag = (hit.id, px, py, .move)
            return
        }
        // Click on empty space creates a new rect (drag to size).
        map.snapshot()
        let id = map.addObject(layer: activeLayer, name: "", kind: "rect", x: px, y: py, w: 0, h: 0)
        selectedObjectID = id > 0 ? Int(id) : nil
        objectDrag = (Int(id), px, py, .create)
        objectWillChange.send()
    }

    private func continueObjectTool(x: Int, y: Int) {
        guard let drag = objectDrag else { return }
        let center = map.cellCenter(x: x, y: y)
        let px = Double(center.x)
        let py = Double(center.y)
        let objects = objectsOnActiveLayer()
        guard let row = objects.first(where: { $0.id == drag.objectID }) else { return }
        switch drag.mode {
        case .move:
            map.setObject(layer: activeLayer, objectID: drag.objectID, name: row.name, kind: row.type,
                          x: row.x + (px - drag.startX), y: row.y + (py - drag.startY),
                          w: row.width, h: row.height)
        case .create:
            let minX = min(px, drag.startX), minY = min(py, drag.startY)
            map.setObject(layer: activeLayer, objectID: drag.objectID, name: "Object", kind: "rect",
                          x: minX, y: minY,
                          w: max(Double(map.cellWidth), abs(px - drag.startX)),
                          h: max(Double(map.cellHeight), abs(py - drag.startY)))
        case .resizeCorner:
            break
        case .none:
            break
        }
        objectWillChange.send()
    }

    private func finishObjectTool() {
        guard objectDrag != nil else { return }
        objectDrag = nil
        commitChange()
    }

    func deleteObject(_ objectID: Int? = nil) {
        guard isObjectActive else { return }
        let id = objectID ?? selectedObjectID
        guard let id else { return }
        map.snapshot()
        map.removeObject(layer: activeLayer, objectID: id)
        selectedObjectID = nil
        commitChange()
    }

    // MARK: - Undo / redo / resize

    func undo() {
        if map.undo() {
            reloadLayers()
            reloadGeometry()
            registerTilesets()
            commitChange()
        }
    }

    func redo() {
        if map.redo() {
            reloadLayers()
            reloadGeometry()
            registerTilesets()
            commitChange()
        }
    }

    func resize(width: Int, height: Int) {
        guard !isInfinite else { return }
        guard width >= 1, height >= 1 else { return }
        map.snapshot()
        map.resize(width: width, height: height)
        reloadLayers()
        registerTilesets()
        commitChange()
    }

    // MARK: - Export

    func compositeRGBA() -> [UInt8] {
        map.compositeRGBA()
    }

    /// Snapshot + full UI refresh after a host-managed composite mutation
    /// (adding a tileset, an object from the inspector, etc).
    func snapshotAndRefresh() {
        map.snapshot()
        reloadLayers()
        registerTilesets()
        commitChange()
    }

    private var compositeImage: CGImage?
    private var compositeImageRevision = -1

    /// Whole-map CGImage cached per canvas revision (minimap + thumbnails).
    func compositeCGImage() -> CGImage? {
        if compositeImageRevision != canvasRevision {
            let rgba = map.compositeRGBA()
            compositeImage = makeCGImage(pixels: rgba, width: map.pixelWidth, height: map.pixelHeight)
            compositeImageRevision = canvasRevision
        }
        return compositeImage
    }

    /// Nearest-neighbour upscale of the whole composite written to a PNG.
    func exportPNG(scale: Int = 4) {
        let scale = max(1, scale)
        let pixels = map.compositeRGBA()
        let w = map.pixelWidth, h = map.pixelHeight
        var scaled = [UInt8](repeating: 0, count: w * scale * h * scale * 4)
        for y in 0..<h * scale {
            for x in 0..<w * scale {
                let src = ((y / scale) * w + x / scale) * 4
                let dst = (y * w * scale + x) * 4
                scaled[dst] = pixels[src]
                scaled[dst + 1] = pixels[src + 1]
                scaled[dst + 2] = pixels[src + 2]
                scaled[dst + 3] = pixels[src + 3]
            }
        }
        guard let png = pngData(from: scaled, width: w * scale, height: h * scale) else { return }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "map-\(w)x\(h)@\(scale)x.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
        #endif
    }

    /// Save the map itself as a Tiled JSON file.
    func exportTiledJSON() {
        #if os(macOS)
        let text = map.toJSON()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "map.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? Data(text.utf8).write(to: url)
        }
        #endif
    }

    /// Write one `.csv` file per tile layer into a chosen folder.
    func exportCSV() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export CSV files to"
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            for (i, layer) in self.layers.enumerated() where layer.type == "tile" {
                let csv = self.map.layerCSV(layer: i)
                let safe = layer.name.replacingOccurrences(of: "/", with: "_")
                let url = folder.appendingPathComponent("\(safe).csv")
                try? Data(csv.utf8).write(to: url)
            }
        }
        #endif
    }

    // MARK: - Agent control (Take Control bridge)

    /// Structured tilemap state for the agent's `editor_read` tool.
    func agentState() -> [String: Any] {
        var state: [String: Any] = [
            "cell_width": map.cellWidth,
            "cell_height": map.cellHeight,
            "columns": map.columns,
            "rows": map.rows,
            "pixel_width": map.pixelWidth,
            "pixel_height": map.pixelHeight,
            "active_layer": activeLayer,
            "infinite": map.isInfinite,
            "orientation": map.orientation.rawValue,
            "orientation_name": map.orientation.label,
            "render_order": map.renderOrder.label,
        ]
        state["layers"] = layers.map { layer -> [String: Any] in
            ["index": layer.index, "name": layer.name, "visible": layer.visible,
             "opacity": layer.opacity, "type": layer.type]
        }
        state["tilesets"] = map.tilesetsInfo().map { info -> [String: Any] in
            ["index": info.index, "name": info.name, "first_gid": Int(info.firstGid),
             "tile_width": info.tileWidth, "tile_height": info.tileHeight,
             "columns": info.columns, "tile_count": info.tileCount]
        }
        if let selection {
            state["selection"] = ["x": selection.x, "y": selection.y,
                                  "width": selection.width, "height": selection.height]
        }
        return state
    }

    /// Apply validated agent operations to the tilemap. Each op is one undo
    /// step; the layer panel and canvas refresh once at the end.
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
        registerTilesets()
        commitChange()
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
        func uint32(_ key: String) throws -> UInt32 {
            guard let value = op[key] as? Int, value >= 0 else { throw AgentOpError("'\(name)' requires a non-negative integer '\(key)'") }
            return UInt32(value)
        }
        func layer() throws -> Int {
            let index = try int("layer")
            try validateAgentLayer(index)
            return index
        }

        switch name {
        case "map_set_tile":
            let target = try layer()
            guard map.setTile(layer: target, x: try int("x"), y: try int("y"), gid: try uint32("tile")) else {
                throw AgentOpError("tile is outside the map")
            }
            return [:]

        case "map_fill":
            let count = map.fill(layer: try layer(), x: try int("x"), y: try int("y"), gid: try uint32("tile"))
            return ["cells": count]

        case "map_paint_rect":
            let count = map.paintRect(layer: try layer(), x0: try int("x0"), y0: try int("y0"),
                                      x1: try int("x1"), y1: try int("y1"), gid: try uint32("tile"))
            return ["cells": count]

        case "map_paint_line":
            let count = map.paintLine(layer: try layer(), x0: try int("x0"), y0: try int("y0"),
                                      x1: try int("x1"), y1: try int("y1"), gid: try uint32("tile"))
            return ["cells": count]

        case "map_stamp":
            let target = try layer()
            guard let rows = op["tiles"] as? [[Any]], !rows.isEmpty else {
                throw AgentOpError("'map_stamp' requires a 'tiles' matrix")
            }
            let height = rows.count
            let width = rows[0].count
            guard width > 0, rows.allSatisfy({ $0.count == width }) else {
                throw AgentOpError("'map_stamp' rows must all share one width")
            }
            var tiles = [UInt32]()
            tiles.reserveCapacity(width * height)
            for row in rows {
                for cell in row {
                    guard let value = cell as? Int, value >= 0 else { throw AgentOpError("'map_stamp' tiles must be non-negative integers") }
                    tiles.append(UInt32(value))
                }
            }
            let pattern = MapTilePattern(width: width, height: height, tiles: tiles)
            let count = map.stamp(layer: target, x: try int("x"), y: try int("y"),
                                  pattern: pattern, skipEmpty: op["skip_empty"] as? Bool ?? true)
            return ["cells": count]

        case "map_add_layer":
            map.snapshot()
            let objectLayer = (op["layer_type"] as? String) == "object"
            let index = objectLayer ? map.addObjectLayer(op["name"] as? String) : map.addLayer(op["name"] as? String)
            activeLayer = index
            return ["index": index]

        case "map_remove_layer":
            let index = try int("index")
            guard map.layerCount > 1 else { throw AgentOpError("cannot remove the last layer") }
            try validateAgentLayer(index)
            map.snapshot()
            map.removeLayer(index)
            activeLayer = min(activeLayer, map.layerCount - 1)
            selectedObjectID = nil
            return [:]

        case "map_rename_layer":
            let index = try int("index")
            try validateAgentLayer(index)
            map.snapshot()
            map.renameLayer(index, name: try string("name"))
            return [:]

        case "map_reorder_layer":
            let from = try int("from"), to = try int("to")
            try validateAgentLayer(from)
            try validateAgentLayer(to)
            map.snapshot()
            map.reorderLayer(from: from, to: to)
            activeLayer = to
            return [:]

        case "map_set_layer_visible":
            let index = try int("index")
            try validateAgentLayer(index)
            map.snapshot()
            map.setLayerVisible(index, try bool("visible"))
            return [:]

        case "map_set_layer_opacity":
            let index = try int("index")
            try validateAgentLayer(index)
            let value = try double("opacity")
            map.snapshot()
            map.setLayerOpacity(index, min(1, max(0, value)))
            return [:]

        case "map_resize":
            let w = try int("width"), h = try int("height")
            guard w >= 1, h >= 1 else { throw AgentOpError("map_resize needs positive width and height") }
            map.snapshot()
            map.resize(width: w, height: h)
            return ["columns": map.columns, "rows": map.rows]

        case "map_set_orientation":
            let raw = try string("orientation").lowercased()
            let value: MapOrientation
            switch raw {
            case "orthogonal": value = .orthogonal
            case "isometric": value = .isometric
            case "staggered", "isometric_staggered": value = .staggered
            default: throw AgentOpError("'map_set_orientation' expects orthogonal, isometric or staggered")
            }
            map.snapshot()
            map.setOrientation(value)
            reloadGeometry()
            return ["orientation": value.label, "pixel_width": map.pixelWidth, "pixel_height": map.pixelHeight]

        case "map_set_tileset_offset":
            let index = try int("index")
            guard map.setTilesetTileOffset(index, x: try int("x"), y: try int("y")) else {
                throw AgentOpError("tileset \(index) is out of range")
            }
            registerTilesets()
            return ["index": index]

        case "map_add_object":
            let target = try layer()
            map.snapshot()
            let id = map.addObject(layer: target, name: op["name"] as? String ?? "",
                                   kind: op["kind"] as? String ?? "rect",
                                   x: try double("x"), y: try double("y"),
                                   w: op["width"] as? Double ?? 0, h: op["height"] as? Double ?? 0)
            return ["object_id": Int(id)]

        case "map_set_object":
            let target = try layer()
            map.snapshot()
            map.setObject(layer: target, objectID: try int("object_id"),
                          name: op["name"] as? String ?? "", kind: op["kind"] as? String ?? "rect",
                          x: try double("x"), y: try double("y"),
                          w: op["width"] as? Double ?? 0, h: op["height"] as? Double ?? 0)
            return [:]

        case "map_remove_object":
            let target = try layer()
            map.snapshot()
            map.removeObject(layer: target, objectID: try int("object_id"))
            if selectedObjectID == (op["object_id"] as? Int) { selectedObjectID = nil }
            return [:]

        case "map_add_tileset":
            guard let workspace else { throw AgentOpError("map_add_tileset requires a workspace") }
            let path = try string("image")
            guard let url = EditorBridge.resolve(path, in: workspace) else {
                throw AgentOpError("tileset image '\(path)' escapes the workspace")
            }
            guard let data = try? Data(contentsOf: url), let decoded = AIService.pngToRGBA(data) else {
                throw AgentOpError("could not read tileset image '\(path)'")
            }
            map.snapshot()
            let index = try map.addTileset(name: op["name"] as? String ?? "Tileset", image: path,
                                           rgba: decoded.rgba, imageWidth: decoded.width, imageHeight: decoded.height,
                                           tileWidth: try int("tile_width"), tileHeight: try int("tile_height"),
                                           margin: op["margin"] as? Int ?? 0, spacing: op["spacing"] as? Int ?? 0)
            return ["index": index]

        case "map_remove_tileset":
            map.snapshot()
            map.removeTileset(try int("index"))
            return [:]

        case "map_set_autotile":
            map.snapshot()
            map.setAutotile(tileset: try int("tileset"), mask: try int("mask"),
                            local: (op["local"] as? Int).map { Int32($0) })
            return [:]

        case "map_autotile":
            let count = map.autotile(layer: try layer(), tileset: try int("tileset"),
                                     x: try int("x"), y: try int("y"), w: try int("w"), h: try int("h"))
            return ["cells": count]

        case "map_select":
            let x = try int("x"), y = try int("y"), w = try int("width"), h = try int("height")
            guard w > 0, h > 0 else { throw AgentOpError("map_select needs a positive width and height") }
            selection = MapCellRect(x: x, y: y, width: w, height: h)
            return [:]

        case "map_clear_selection":
            selection = nil
            return [:]

        case "map_undo":
            return ["changed": map.undo()]
        case "map_redo":
            return ["changed": map.redo()]

        case "map_export_tiled":
            guard let workspace else { throw AgentOpError("map_export_tiled requires a workspace") }
            let path = try string("path")
            guard let url = EditorBridge.resolve(path, in: workspace) else {
                throw AgentOpError("export path '\(path)' escapes the workspace")
            }
            let text = map.toJSON()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return ["path": path]

        case "map_export_csv":
            guard let workspace else { throw AgentOpError("map_export_csv requires a workspace") }
            let path = try string("path")
            guard let directory = EditorBridge.resolve(path, in: workspace) else {
                throw AgentOpError("export path '\(path)' escapes the workspace")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var written = 0
            for info in map.layersInfo() where info.type == "tile" {
                let safe = info.name.replacingOccurrences(of: "/", with: "_")
                let url = directory.appendingPathComponent("\(safe).csv")
                try Data(map.layerCSV(layer: info.index).utf8).write(to: url)
                written += 1
            }
            return ["path": path, "layers": written]

        case "map_export_png":
            guard let workspace else { throw AgentOpError("map_export_png requires a workspace") }
            let path = try string("path")
            guard let url = EditorBridge.resolve(path, in: workspace) else {
                throw AgentOpError("export path '\(path)' escapes the workspace")
            }
            let scale = max(1, op["scale"] as? Int ?? 1)
            let base = map.compositeRGBA()
            let pixels = scale == 1 ? base : TileMapModel.scalePixels(base, width: map.pixelWidth, height: map.pixelHeight, scale: scale)
            guard let data = AIService.rgbaToPNG(pixels, width: map.pixelWidth * scale, height: map.pixelHeight * scale) else {
                throw AgentOpError("could not encode the PNG")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return ["path": path, "bytes": data.count]

        default:
            throw AgentOpError("unknown op '\(name)'")
        }
    }

    private func validateAgentLayer(_ index: Int) throws {
        guard index >= 0, index < map.layerCount else { throw AgentOpError("layer \(index) is out of range") }
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

// MARK: - Data copy helper

private extension Array where Element == UInt8 {
    mutating func copyFrom(_ source: [UInt8], from offset: Int) {
        guard offset >= 0, offset + count <= source.count else { return }
        for i in 0..<count {
            self[i] = source[offset + i]
        }
    }
}
