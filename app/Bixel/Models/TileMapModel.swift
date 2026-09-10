// TileMapModel.swift
//
// Observable application state for the Tilemap Designer (.map documents).
// Mirrors EditorModel's conventions: owns the Rust-backed TileMap + tool/brush
// state, a 60 Hz coalescing refresh timer, per-layer metadata loaded in bulk,
// and export/import entry points. The whole map (Tiled JSON) is the document;
// tileset PNGs are project assets referenced by relative path.

import Foundation
import AppKit
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

    var isObjectActive: Bool {
        activeLayer < layers.count && layers[activeLayer].type == "object"
    }

    var activeIsTile: Bool { !isObjectActive }

    init(width: Int, height: Int, tileWidth: Int = 16, tileHeight: Int = 16) {
        self.map = TileMap(width: width, height: height, tileWidth: tileWidth, tileHeight: tileHeight)
        reloadLayers()
        registerTilesets()
    }

    init(map restored: TileMap) {
        self.map = restored
        reloadLayers()
        registerTilesets()
    }

    init(json: String) throws {
        self.map = try TileMap(json: json)
        reloadLayers()
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

    var isActiveLayerTile: Bool {
        guard activeLayer < layers.count else { return true }
        return layers[activeLayer].type == "tile"
    }

    var canPaint: Bool {
        guard map.layerCount > 0, activeLayer < map.layerCount else { return false }
        if isObjectActive { return false }
        return activeLayer < layers.count
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
        for info in tilesetList where tilesetImages[info.index] == nil {
            let rgba = map.tilesetPixels(index: info.index)
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
    func uploadTileset(_ index: Int, cgImage: CGImage, rgba: [UInt8]) {
        _ = map.setTilesetPixels(index, rgba: rgba)
        tilesetImages[index] = cgImage
        registerTilesets()
    }

    func tilesetDisplayImage(_ index: Int) -> CGImage? {
        tilesetImages[index]
    }

    func removeTileset(_ index: Int) {
        map.snapshot()
        map.removeTileset(index)
        tilesetImages[index] = nil
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
        guard x >= 0, y >= 0, x < width, y < height else { return }
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
        guard x >= 0, y >= 0, x < width, y < height else { return }
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
                    let px = CGFloat(selection.x * map.cellWidth + map.cellWidth / 2)
                    let py = CGFloat(selection.y * map.cellHeight + map.cellHeight / 2)
                    selectObject(at: px, y: py)
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
            guard !pattern.isEmpty else { return }
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
            hoverPixel = (anchorX * map.cellWidth, anchorY * map.cellHeight)
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
        var minX = width, minY = height, maxX = -1, maxY = -1
        var idx = 0
        for row in 0..<height {
            for col in 0..<width {
                if mask[idx] {
                    minX = min(minX, col); maxX = max(maxX, col)
                    minY = min(minY, row); maxY = max(maxY, row)
                }
                idx += 1
            }
        }
        selection = MapCellRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        objectWillChange.send()
    }

    // MARK: - Selection clipboard

    func copySelection() {
        guard let rect = selection, isActiveLayerTile else { return }
        clipboard = map.readRegion(layer: activeLayer, x: rect.x, y: rect.y, w: rect.width, h: rect.height)
        // A crop of the composite also lands on the pasteboard as a PNG.
        if let png = croppedCompositePNG(rect) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
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

    func cropOfComposite(_ rect: MapCellRect) -> [UInt8] {
        let pixels = map.compositeRGBA()
        let fullW = map.pixelWidth
        let cropW = rect.width * map.cellWidth
        let cropH = rect.height * map.cellHeight
        guard fullW > 0, cropW > 0, cropH > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: cropW * cropH * 4)
        let startX = rect.x * map.cellWidth
        let startY = rect.y * map.cellHeight
        for row in 0..<cropH {
            let src = ((startY + row) * fullW + startX) * 4
            let dst = row * cropW * 4
            for i in 0..<cropW * 4 {
                out[dst + i] = pixels[src + i]
            }
        }
        return out
    }

    private func croppedCompositePNG(_ rect: MapCellRect) -> Data? {
        let rgba = cropOfComposite(rect)
        guard let cg = makeCGImage(pixels: rgba, width: rect.width * map.cellWidth,
                                   height: rect.height * map.cellHeight) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
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
        let px = Double(x) * Double(map.cellWidth)
        let py = Double(y) * Double(map.cellHeight)
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
        let px = Double(x) * Double(map.cellWidth)
        let py = Double(y) * Double(map.cellHeight)
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
            registerTilesets()
            commitChange()
        }
    }

    func redo() {
        if map.redo() {
            reloadLayers()
            registerTilesets()
            commitChange()
        }
    }

    func resize(width: Int, height: Int) {
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
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * scale * 4, bitsPerPixel: 32),
              let bitmap = rep.bitmapData else { return }
        scaled.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(bitmap, base, scaled.count)
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "map-\(w)x\(h)@\(scale)x.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }

    /// Save the map itself as a Tiled JSON file.
    func exportTiledJSON() {
        let text = map.toJSON()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "map.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Write one `.csv` file per tile layer into a chosen folder.
    func exportCSV() {
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
