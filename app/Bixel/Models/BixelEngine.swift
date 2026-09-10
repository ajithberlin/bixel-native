// BixelEngine.swift
//
// Swift wrapper over the Rust engine's C ABI (generated/bixel.h).
// This is the ONLY place raw C pointers cross the boundary: everything else in
// the app talks to typed Swift objects. Bulk pixel data is copied into
// caller-owned buffers exactly once per frame, matching the
// "Swift sends a command, Rust processes a whole buffer" contract.

import Foundation
import CoreGraphics

// MARK: - Document

/// A sprite document backed by a Rust `AsepriteDoc`.
// The handle is immutable; Rust serializes every document access with a mutex.
final class Document: @unchecked Sendable {
    fileprivate let handle: UnsafeMutablePointer<BixelDoc>?

    init(width: Int, height: Int) {
        handle = bixel_doc_new(UInt32(width), UInt32(height))
    }

    init(json: String) throws {
        guard let restored = bixel_doc_from_json(json) else { throw StorageError.message("The saved document is invalid or uses an unsupported version.") }
        handle = restored
    }

    func save(base: URL, path: String) throws {
        if let error = bixel_doc_save(handle, base.path, path) {
            defer { bixel_string_free(error) }
            throw StorageError.message(String(cString: error))
        }
    }

    deinit {
        if let handle { bixel_doc_free(handle) }
    }

    var width: Int { Int(bixel_doc_width(handle)) }
    var height: Int { Int(bixel_doc_height(handle)) }
    var frameCount: Int { Int(bixel_doc_frame_count(handle)) }
    var layerCount: Int { Int(bixel_doc_layer_count(handle)) }

    var bytesPerFrame: Int { width * height * 4 }

    func setPixel(layer: Int, frame: Int, x: Int, y: Int, _ c: BixelColor) {
        bixel_doc_set_pixel(handle, UInt32(layer), UInt32(frame), UInt32(x), UInt32(y), c)
    }

    func getPixel(layer: Int, frame: Int, x: Int, y: Int) -> BixelColor {
        bixel_doc_get_pixel(handle, UInt32(layer), UInt32(frame), UInt32(x), UInt32(y))
    }

    /// Rasterise a polyline stroke with a round brush (one FFI call per gesture).
    func stroke(layer: Int, frame: Int, points: [(x: Int, y: Int)], color: BixelColor, radius: UInt32) {
        let xs = points.map { UInt32($0.x) }
        let ys = points.map { UInt32($0.y) }
        xs.withUnsafeBufferPointer { xbuf in
            ys.withUnsafeBufferPointer { ybuf in
                bixel_doc_stroke(
                    handle,
                    UInt32(layer), UInt32(frame),
                    xbuf.baseAddress, ybuf.baseAddress, UInt32(points.count),
                    color, radius
                )
            }
        }
    }

    @discardableResult
    func floodFill(layer: Int, frame: Int, x: Int, y: Int, _ c: BixelColor) -> Int {
        Int(bixel_doc_flood_fill(handle, UInt32(layer), UInt32(frame), UInt32(x), UInt32(y), c))
    }

    func addLayer(_ name: String? = nil) -> Int {
        Int(bixel_doc_add_layer(handle, name))
    }

    func removeLayer(_ index: Int) {
        bixel_doc_remove_layer(handle, UInt32(index))
    }

    func layerName(_ index: Int) -> String {
        let ptr = bixel_doc_layer_name(handle, UInt32(index))
        defer { bixel_string_free(ptr) }
        return ptr.map { String(cString: $0) } ?? ""
    }

    func isLayerVisible(_ index: Int) -> Bool {
        bixel_doc_layer_visible(handle, UInt32(index))
    }

    func setLayerVisible(_ index: Int, _ visible: Bool) {
        bixel_doc_set_layer_visible(handle, UInt32(index), visible)
    }

    /// Load RGBA pixel data into `(layer, frame)`, resizing the document first.
    func loadImageData(_ data: [UInt8], width: Int, height: Int, layer: Int, frame: Int) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                bixel_doc_load_image(
                    handle, base.assumingMemoryBound(to: UInt8.self),
                    UInt32(width), UInt32(height), UInt32(layer), UInt32(frame)
                )
            }
        }
    }

    /// Export every composited frame into a row-major sheet with transparent padding.
    func packFrames(columns: Int) throws -> (rgba: [UInt8], width: Int, height: Int) {
        guard let cols = UInt32(exactly: columns), cols > 0, frameCount > 0 else {
            throw StorageError.message("Choose at least one column for the sprite sheet.")
        }
        let frames = frameCount
        let rows = frames / columns + (frames % columns == 0 ? 0 : 1)
        let (sheetWidth, widthOverflow) = width.multipliedReportingOverflow(by: columns)
        let (sheetHeight, heightOverflow) = height.multipliedReportingOverflow(by: rows)
        let (pixels, pixelOverflow) = sheetWidth.multipliedReportingOverflow(by: sheetHeight)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !widthOverflow, !heightOverflow, !pixelOverflow, !byteOverflow,
              bytes > 0, bytes <= 256 * 1024 * 1024 else {
            throw StorageError.message("The exported sprite sheet exceeds 256 MB.")
        }
        var rgba = [UInt8](repeating: 0, count: bytes)
        let succeeded = rgba.withUnsafeMutableBufferPointer {
            bixel_doc_pack_frames(handle, cols, $0.baseAddress, UInt($0.count))
        }
        guard succeeded else { throw StorageError.message("Cannot pack the document frames into a sprite sheet.") }
        return (rgba, sheetWidth, sheetHeight)
    }

    /// Place an image on a new layer, clipped to this canvas, in one undo step.
    @discardableResult
    func placeImageData(_ data: [UInt8], width: Int, height: Int, x: Int, y: Int,
                        frame: Int, name: String) throws -> Int {
        guard let w = UInt32(exactly: width), let h = UInt32(exactly: height),
              let px = Int32(exactly: x), let py = Int32(exactly: y),
              let f = UInt32(exactly: frame), w > 0, h > 0 else {
            throw StorageError.message("Invalid image placement dimensions or coordinates.")
        }
        let index = data.withUnsafeBufferPointer {
            bixel_doc_place_image(handle, $0.baseAddress, UInt($0.count), w, h, px, py, f, name)
        }
        guard index >= 0 else {
            throw StorageError.message("Cannot place this image. Check its pixel data, destination frame, and canvas overlap.")
        }
        return Int(index)
    }

    /// Replace a tile-sized region. The caller snapshots once at stroke start.
    func stampImageData(_ data: [UInt8], width: Int, height: Int, x: Int, y: Int,
                        layer: Int, frame: Int) throws {
        guard let w = UInt32(exactly: width), let h = UInt32(exactly: height),
              let px = Int32(exactly: x), let py = Int32(exactly: y),
              let l = UInt32(exactly: layer), let f = UInt32(exactly: frame), w > 0, h > 0 else {
            throw StorageError.message("Invalid tile placement dimensions or coordinates.")
        }
        let succeeded = data.withUnsafeBufferPointer {
            bixel_doc_stamp_image(handle, $0.baseAddress, UInt($0.count), w, h, px, py, l, f)
        }
        guard succeeded else {
            throw StorageError.message("Cannot stamp this tile. Check the image, canvas overlap, and destination layer lock.")
        }
    }

    func transformRect(layer: Int, frame: Int, source: CGRect, destination: CGRect,
                       rotation: Int = 0) throws {
        guard source.origin.x >= 0, source.origin.y >= 0,
              source.width >= 1, source.height >= 1,
              destination.width >= 1, destination.height >= 1,
              let sx = UInt32(exactly: Int(source.origin.x)),
              let sy = UInt32(exactly: Int(source.origin.y)),
              let sw = UInt32(exactly: Int(source.width)),
              let sh = UInt32(exactly: Int(source.height)),
              let dx = Int32(exactly: Int(destination.origin.x)),
              let dy = Int32(exactly: Int(destination.origin.y)),
              let dw = UInt32(exactly: Int(destination.width)),
              let dh = UInt32(exactly: Int(destination.height)),
              let l = UInt32(exactly: layer), let f = UInt32(exactly: frame) else {
            throw StorageError.message("Invalid selection transform dimensions.")
        }
        guard bixel_doc_transform_rect(handle, l, f, sx, sy, sw, sh, dx, dy, dw, dh,
                                       UInt32((rotation % 4 + 4) % 4)) else {
            throw StorageError.message("The selection could not be transformed.")
        }
    }

    func transformRectAngle(layer: Int, frame: Int, source: CGRect, destination: CGRect,
                            angle: Double) throws {
        guard source.origin.x >= 0, source.origin.y >= 0,
              source.width >= 1, source.height >= 1,
              destination.width >= 1, destination.height >= 1,
              let sx = UInt32(exactly: Int(source.origin.x.rounded())),
              let sy = UInt32(exactly: Int(source.origin.y.rounded())),
              let sw = UInt32(exactly: Int(source.width.rounded())),
              let sh = UInt32(exactly: Int(source.height.rounded())),
              let dx = Int32(exactly: Int(destination.origin.x.rounded())),
              let dy = Int32(exactly: Int(destination.origin.y.rounded())),
              let dw = UInt32(exactly: Int(destination.width.rounded())),
              let dh = UInt32(exactly: Int(destination.height.rounded())),
              let l = UInt32(exactly: layer), let f = UInt32(exactly: frame),
              angle.isFinite else {
            throw StorageError.message("Invalid selection transform dimensions.")
        }
        guard bixel_doc_transform_rect_angle(handle, l, f, sx, sy, sw, sh, dx, dy, dw, dh, angle) else {
            throw StorageError.message("The selection could not be transformed.")
        }
    }

    /// Import sheet cells into a new layer from frame zero without resizing.
    @discardableResult
    func importSheetData(_ data: [UInt8], width: Int, height: Int,
                         cellWidth: Int, cellHeight: Int, name: String) throws -> Int {
        guard let w = UInt32(exactly: width), let h = UInt32(exactly: height),
              let cw = UInt32(exactly: cellWidth), let ch = UInt32(exactly: cellHeight),
              cw > 0, ch > 0, cellWidth == self.width, cellHeight == self.height else {
            throw StorageError.message("Sheet cell dimensions must match the canvas dimensions.")
        }
        guard w > 0, h > 0, w % cw == 0, h % ch == 0 else {
            throw StorageError.message("Sheet dimensions must be divisible by the cell size.")
        }
        let index = data.withUnsafeBufferPointer {
            bixel_doc_import_sheet(handle, $0.baseAddress, UInt($0.count), w, h, cw, ch, name)
        }
        guard index >= 0 else {
            throw StorageError.message("Cannot import this sheet. Check its pixel data and limit it to 4096 frames and 256 MB.")
        }
        return Int(index)
    }

    @discardableResult
    func addFrame(durationMs: Int) -> Int {
        Int(bixel_doc_add_frame(handle, UInt32(durationMs)))
    }

    func reorderFrame(from: Int, to: Int) {
        bixel_doc_reorder_frame(handle, UInt32(from), UInt32(to))
    }

    func removeFrame(_ index: Int) {
        bixel_doc_remove_frame(handle, UInt32(index))
    }

    func renameLayer(_ index: Int, name: String) {
        bixel_doc_rename_layer(handle, UInt32(index), name)
    }

    func resize(width: Int, height: Int) {
        bixel_doc_resize(handle, UInt32(width), UInt32(height))
    }

    func reorderLayer(from: Int, to: Int) {
        bixel_doc_reorder_layer(handle, UInt32(from), UInt32(to))
    }

    func layerOpacity(_ index: Int) -> Float {
        bixel_doc_layer_opacity(handle, UInt32(index))
    }

    func setLayerOpacity(_ index: Int, _ opacity: Float) {
        bixel_doc_set_layer_opacity(handle, UInt32(index), opacity)
    }

    /// Raw RGBA of a single layer's cel at `frame` (transparent when empty).
    func celRGBA(layer: Int, frame: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: bytesPerFrame)
        buf.withUnsafeMutableBytes {
            bixel_doc_cel_rgba(handle, UInt32(layer), UInt32(frame), $0.baseAddress)
        }
        return buf
    }

    func frameDuration(_ index: Int) -> Int {
        Int(bixel_doc_frame_duration(handle, UInt32(index)))
    }

    func setFrameDuration(_ index: Int, ms: Int) {
        bixel_doc_set_frame_duration(handle, UInt32(index), UInt32(ms))
    }

    func snapshot() { bixel_doc_snapshot(handle) }
    @discardableResult
    func undo() -> Bool { bixel_doc_undo(handle) }
    @discardableResult
    func redo() -> Bool { bixel_doc_redo(handle) }
    var canUndo: Bool { bixel_doc_can_undo(handle) }
    var canRedo: Bool { bixel_doc_can_redo(handle) }

    /// Composite a frame into a caller-owned RGBA buffer.
    func composite(frame: Int, into buffer: UnsafeMutableRawPointer) {
        bixel_doc_composite(handle, UInt32(frame), buffer.assumingMemoryBound(to: UInt8.self))
    }

    /// Composite a frame into a fresh `[UInt8]` (convenience).
    func compositeRGBA(frame: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: bytesPerFrame)
        buf.withUnsafeMutableBytes { composite(frame: frame, into: $0.baseAddress!) }
        return buf
    }
}

// MARK: - Timeline

/// Animation playback controller sharing the document's Rust state.
final class Timeline {
    private var handle: UnsafeMutablePointer<BixelTimeline>?
    private let document: Document

    init(document: Document) {
        self.document = document
        handle = bixel_timeline_new(document.handle)
    }

    deinit {
        if let handle { bixel_timeline_free(handle) }
    }

    var currentFrame: Int { Int(bixel_timeline_current_frame(handle)) }

    @discardableResult
    func update(deltaMs: Float) -> Int { Int(bixel_timeline_update(handle, deltaMs)) }
    @discardableResult
    func next() -> Int { Int(bixel_timeline_next(handle)) }
    @discardableResult
    func previous() -> Int { Int(bixel_timeline_prev(handle)) }
    @discardableResult
    func goTo(_ frame: Int) -> Int { Int(bixel_timeline_go_to(handle, UInt32(frame))) }

    func setFPS(_ fps: Float) { bixel_timeline_set_fps(handle, fps) }
    func setLoopMode(_ mode: LoopMode) { bixel_timeline_set_loop_mode(handle, mode.rawValue) }
    func setActiveTag(_ name: String?) { bixel_timeline_set_active_tag(handle, name) }
    func play() { bixel_timeline_play(handle) }
    func pause() { bixel_timeline_pause(handle) }
}

enum LoopMode: UInt32 {
    case forward = 0
    case reverse = 1
    case pingPong = 2
}

// MARK: - Palette

enum PaletteKind: UInt32 {
    case db32 = 0
    case pico8 = 1
    case gameboy = 2
}

enum Palette {
    static func size(_ kind: PaletteKind) -> Int { Int(bixel_palette_size(kind.rawValue)) }

    static func rgba(_ kind: PaletteKind) -> [BixelColor] {
        let count = size(kind)
        var out = [UInt8](repeating: 0, count: count * 4)
        out.withUnsafeMutableBytes { bixel_palette_rgba(kind.rawValue, $0.baseAddress!) }
        return stride(from: 0, to: out.count, by: 4).map { i in
            BixelColor(r: out[i], g: out[i + 1], b: out[i + 2], a: out[i + 3])
        }
    }

    static func nearest(_ hex: String, in kind: PaletteKind) -> BixelColor {
        bixel_nearest_color(hex, kind.rawValue)
    }
}

// MARK: - Color helpers

extension BixelColor: Equatable {
    public static func == (lhs: BixelColor, rhs: BixelColor) -> Bool {
        lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b && lhs.a == rhs.a
    }
}

extension BixelColor {
    var hex: String {
        let ptr = bixel_rgba_to_hex(self)
        defer { bixel_string_free(ptr) }
        return String(cString: ptr!)
    }

    init(hex: String) {
        self = bixel_hex_to_rgba(hex)
    }

    var cgColor: CGColor {
        CGColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}

/// Convert a raw RGBA byte buffer into an un-interpolated CGImage for pixel-art display.
func makeCGImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

// MARK: - Tile layer

/// A tile map layer backed by a Rust `TileLayer`.
final class TileLayer {
    private var handle: UnsafeMutablePointer<BixelTileLayer>?

    init(width: Int, height: Int) {
        handle = bixel_tilelayer_new(UInt32(width), UInt32(height))
    }

    deinit {
        if let handle { bixel_tilelayer_free(handle) }
    }

    func get(x: Int, y: Int) -> UInt32 { bixel_tilelayer_get(handle, Int32(x), Int32(y)) }
    @discardableResult
    func set(x: Int, y: Int, _ raw: UInt32) -> Bool { bixel_tilelayer_set(handle, Int32(x), Int32(y), raw) }
    @discardableResult
    func flood(x: Int, y: Int, _ raw: UInt32) -> Int { Int(bixel_tilelayer_flood(handle, Int32(x), Int32(y), raw)) }
}


// MARK: - Tile map

/// A raw-GID rectangle brush / clipboard payload for tile maps.
struct MapTilePattern {
    var width: Int = 0
    var height: Int = 0
    var tiles: [UInt32] = []
    var isEmpty: Bool { width <= 0 || height <= 0 || tiles.isEmpty }

    init(width: Int, height: Int, tiles: [UInt32]) {
        self.width = width
        self.height = height
        self.tiles = tiles
    }

    init() {}

    // MARK: Orientation-aware transforms
    //
    // Flipping/rotating a multi-tile stamp must transform the *whole block*:
    // the tiles change position AND each tile's own orientation flags are
    // updated so the artwork mirrors/rotates as one image (matching Tiled).

    private static let flagBits: UInt32 = GIDFlag.horizontal | GIDFlag.vertical | GIDFlag.diagonal
    private static let gidMask: UInt32 = ~flagBits

    /// A 2×2 signed permutation acting on pixel coordinates.
    private typealias Matrix = (Int, Int, Int, Int)

    /// Every Tiled orientation as `(flags, matrix)`; flags are applied
    /// diagonal → horizontal → vertical (the engine's render order).
    private static let orientations: [(flags: UInt32, matrix: Matrix)] = {
        let identity: Matrix = (1, 0, 0, 1)
        let diagonal: Matrix = (0, 1, 1, 0)
        let horizontal: Matrix = (-1, 0, 0, 1)
        let vertical: Matrix = (1, 0, 0, -1)
        func multiply(_ r: Matrix, _ m: Matrix) -> Matrix {
            (r.0 * m.0 + r.1 * m.2, r.0 * m.1 + r.1 * m.3,
             r.2 * m.0 + r.3 * m.2, r.2 * m.1 + r.3 * m.3)
        }
        var table: [(flags: UInt32, matrix: Matrix)] = []
        for d in 0..<2 {
            for h in 0..<2 {
                for v in 0..<2 {
                    var m = identity
                    if d == 1 { m = multiply(diagonal, m) }
                    if h == 1 { m = multiply(horizontal, m) }
                    if v == 1 { m = multiply(vertical, m) }
                    var flags: UInt32 = 0
                    if d == 1 { flags |= GIDFlag.diagonal }
                    if h == 1 { flags |= GIDFlag.horizontal }
                    if v == 1 { flags |= GIDFlag.vertical }
                    table.append((flags, m))
                }
            }
        }
        return table
    }()

    /// Apply an additional block-level transform to one GID's orientation.
    private static func oriented(_ gid: UInt32, by transform: Matrix) -> UInt32 {
        let base = gid & gidMask
        let flags = gid & flagBits
        guard let current = orientations.first(where: { $0.flags == flags }) else { return gid }
        let m = (
            transform.0 * current.matrix.0 + transform.1 * current.matrix.2,
            transform.0 * current.matrix.1 + transform.1 * current.matrix.3,
            transform.2 * current.matrix.0 + transform.3 * current.matrix.2,
            transform.2 * current.matrix.1 + transform.3 * current.matrix.3
        )
        guard let updated = orientations.first(where: { $0.matrix == m }) else { return gid }
        return base | updated.flags
    }

    private mutating func orientAll(_ transform: Matrix) {
        for i in tiles.indices { tiles[i] = Self.oriented(tiles[i], by: transform) }
    }

    /// Flip the whole pattern horizontally (mirror positions + tile artwork).
    mutating func flipH() {
        guard width > 0, height > 0 else { return }
        orientAll((-1, 0, 0, 1))
        for y in 0..<height {
            for x in 0..<(width / 2) {
                let a = y * width + x
                let b = y * width + (width - 1 - x)
                tiles.swapAt(a, b)
            }
        }
    }

    /// Flip the whole pattern vertically (mirror positions + tile artwork).
    mutating func flipV() {
        guard width > 0, height > 0 else { return }
        orientAll((1, 0, 0, -1))
        for x in 0..<width {
            for y in 0..<(height / 2) {
                let a = y * width + x
                let b = (height - 1 - y) * width + x
                tiles.swapAt(a, b)
            }
        }
    }

    /// Rotate the whole pattern clockwise (rotate positions + tile artwork).
    mutating func rotateCW() {
        guard width > 0, height > 0 else { return }
        orientAll((0, -1, 1, 0))
        var out = [UInt32](repeating: 0, count: width * height)
        let (w, h) = (width, height)
        for y in 0..<h {
            for x in 0..<w {
                out[x * h + (h - 1 - y)] = tiles[y * w + x]
            }
        }
        tiles = out
        swap(&width, &height)
    }

    /// Rotate the whole pattern counter-clockwise (rotate positions + artwork).
    mutating func rotateCCW() {
        guard width > 0, height > 0 else { return }
        orientAll((0, 1, -1, 0))
        var out = [UInt32](repeating: 0, count: width * height)
        let (w, h) = (width, height)
        for y in 0..<h {
            for x in 0..<w {
                out[(w - 1 - x) * h + y] = tiles[y * w + x]
            }
        }
        tiles = out
        swap(&width, &height)
    }
}

/// Tileset metadata surfaced to the tileset panel.
struct MapTilesetInfo: Codable {
    var index: Int
    var firstGid: UInt32
    var name: String
    var image: String
    var imageWidth: Int
    var imageHeight: Int
    var tileWidth: Int
    var tileHeight: Int
    var margin: Int
    var spacing: Int
    var columns: Int
    var tileCount: Int
}

/// One row for the map layers panel (tile or object layer).
struct MapLayerRow: Codable, Identifiable {
    var index: Int
    var id: Int
    var name: String
    var visible: Bool
    var opacity: Double
    var type: String
    var width: Int?
    var height: Int?
    var objectCount: Int?
}

/// One map object on an object layer (rect or point, in tile-pixels).
struct MapObjectRow: Codable {
    var id: Int
    var name: String
    var type: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var visible: Bool
}

/// Tiled GID flip flags mirrored from `crates/bixel-core/src/map.rs`.
enum GIDFlag {
    static let horizontal: UInt32 = 0x8000_0000
    static let vertical: UInt32 = 0x4000_0000
    static let diagonal: UInt32 = 0x2000_0000
}

/// A tile map document backed by a Rust `TileMap` (Tiled 1.10 JSON on disk).
final class TileMap: @unchecked Sendable {
    fileprivate let handle: UnsafeMutablePointer<BixelMap>?

    init(width: Int, height: Int, tileWidth: Int, tileHeight: Int) {
        handle = bixel_map_new(UInt32(max(1, width)), UInt32(max(1, height)),
                               UInt32(max(1, tileWidth)), UInt32(max(1, tileHeight)))
    }

    init(json: String) throws {
        guard let restored = bixel_map_from_json(json) else {
            let detail = bixel_map_validate_json(json).map { ptr -> String in
                defer { bixel_string_free(ptr) }
                return String(cString: ptr)
            }
            throw StorageError.message(detail?.isEmpty == false ? detail! : "The saved map is invalid or uses an unsupported Tiled version.")
        }
        handle = restored
    }

    func save(base: URL, path: String) throws {
        if let error = bixel_map_save(handle, base.path, path) {
            defer { bixel_string_free(error) }
            throw StorageError.message(String(cString: error))
        }
    }

    deinit {
        if let handle { bixel_map_free(handle) }
    }

    func toJSON() -> String {
        let ptr = bixel_map_to_json(handle)
        defer { bixel_string_free(ptr) }
        return ptr.map { String(cString: $0) } ?? ""
    }

    var cellWidth: Int { Int(bixel_map_cell_width(handle)) }
    var cellHeight: Int { Int(bixel_map_cell_height(handle)) }
    var columns: Int { Int(bixel_map_cell_count_x(handle)) }
    var rows: Int { Int(bixel_map_cell_count_y(handle)) }
    var pixelWidth: Int { Int(bixel_map_pixel_width(handle)) }
    var pixelHeight: Int { Int(bixel_map_pixel_height(handle)) }

    // MARK: Tilesets

    @discardableResult
    func addTileset(name: String, image: String, rgba: [UInt8],
                    imageWidth: Int, imageHeight: Int,
                    tileWidth: Int, tileHeight: Int,
                    margin: Int = 0, spacing: Int = 0) throws -> Int {
        let index = rgba.withUnsafeBufferPointer { raw in
            bixel_map_add_tileset(handle, name, image,
                                  raw.baseAddress,
                                  UInt32(imageWidth), UInt32(imageHeight),
                                  UInt32(tileWidth), UInt32(tileHeight),
                                  UInt32(margin), UInt32(spacing))
        }
        guard index >= 0 else {
            throw StorageError.message("Cannot add this tileset. Check the image size against the tile size, margin and spacing.")
        }
        return Int(index)
    }

    func setTilesetPixels(_ index: Int, rgba: [UInt8]) -> Bool {
        rgba.withUnsafeBufferPointer { raw in
            bixel_map_set_tileset_pixels(handle, UInt32(index), raw.baseAddress, UInt(raw.count))
        }
    }

    func removeTileset(_ index: Int) {
        bixel_map_remove_tileset(handle, UInt32(index))
    }

    /// Read a tileset's RGBA pixels back out of the engine (for the panel after
    /// an undo/redo or a freshly parsed file whose image the host uploaded).
    func tilesetPixels(index: Int) -> [UInt8] {
        let info = tilesetsInfo()
        guard index >= 0, index < info.count else { return [] }
        let w = info[index].imageWidth, h = info[index].imageHeight
        guard w > 0, h > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBufferPointer {
            bixel_map_tileset_pixels(handle, UInt32(index), $0.baseAddress, UInt($0.count))
        }
        return ok ? buf : []
    }

    var tilesetCount: Int { Int(bixel_map_tileset_count(handle)) }

    func tilesetsInfo() -> [MapTilesetInfo] {
        let ptr = bixel_map_tilesets_json(handle)
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8),
              let list = try? JSONDecoder().decode([MapTilesetInfo].self, from: data) else { return [] }
        return list
    }

    func setAutotile(tileset: Int, mask: Int, local: Int32?) {
        bixel_map_set_autotile(handle, UInt32(tileset), UInt8(mask), local ?? -1)
    }

    /// The 16 autotile slots as local tile ids (nil = empty slot).
    func autotileSlots(tileset: Int) -> [Int32?] {
        var slots = [Int64](repeating: -1, count: 16)
        let count = slots.withUnsafeMutableBufferPointer {
            bixel_map_autotile_slots(handle, UInt32(tileset), $0.baseAddress, UInt($0.count))
        }
        _ = count
        return slots.map { $0 >= 0 ? Int32($0) : nil }
    }

    @discardableResult
    func autotile(layer: Int, tileset: Int, x: Int, y: Int, w: Int, h: Int) -> Int {
        Int(bixel_map_autotile(handle, UInt32(layer), UInt32(tileset),
                               UInt32(x), UInt32(y), UInt32(w), UInt32(h)))
    }

    // MARK: Layers

    var layerCount: Int { Int(bixel_map_layer_count(handle)) }

    @discardableResult
    func addLayer(_ name: String? = nil) -> Int {
        Int(bixel_map_add_layer(handle, name))
    }

    @discardableResult
    func addObjectLayer(_ name: String? = nil) -> Int {
        Int(bixel_map_add_object_layer(handle, name))
    }

    func removeLayer(_ index: Int) {
        bixel_map_remove_layer(handle, UInt32(index))
    }

    func renameLayer(_ index: Int, name: String) {
        bixel_map_rename_layer(handle, UInt32(index), name)
    }

    func reorderLayer(from: Int, to: Int) {
        bixel_map_reorder_layer(handle, UInt32(from), UInt32(to))
    }

    func setLayerVisible(_ index: Int, _ visible: Bool) {
        bixel_map_set_layer_visible(handle, UInt32(index), visible)
    }

    func setLayerOpacity(_ index: Int, _ opacity: Double) {
        bixel_map_set_layer_opacity(handle, UInt32(index), Float(opacity))
    }

    func layersInfo() -> [MapLayerRow] {
        let ptr = bixel_map_layers_json(handle)
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8),
              let list = try? JSONDecoder().decode([MapLayerRow].self, from: data) else { return [] }
        return list
    }

    // MARK: Tile editing

    @discardableResult
    func setTile(layer: Int, x: Int, y: Int, gid: UInt32) -> Bool {
        bixel_map_set_tile(handle, UInt32(layer), Int32(x), Int32(y), gid)
    }

    func getTile(layer: Int, x: Int, y: Int) -> UInt32 {
        bixel_map_get_tile(handle, UInt32(layer), Int32(x), Int32(y))
    }

    @discardableResult
    func stamp(layer: Int, x: Int, y: Int, pattern: MapTilePattern, skipEmpty: Bool) -> Int {
        pattern.tiles.withUnsafeBufferPointer { raw in
            Int(bixel_map_stamp(handle, UInt32(layer), Int32(x), Int32(y),
                                raw.baseAddress, UInt32(pattern.width), UInt32(pattern.height), skipEmpty))
        }
    }

    @discardableResult
    func fill(layer: Int, x: Int, y: Int, gid: UInt32) -> Int {
        Int(bixel_map_fill(handle, UInt32(layer), Int32(x), Int32(y), gid))
    }

    @discardableResult
    func paintRect(layer: Int, x0: Int, y0: Int, x1: Int, y1: Int, gid: UInt32) -> Int {
        Int(bixel_map_paint_rect(handle, UInt32(layer), Int32(x0), Int32(y0), Int32(x1), Int32(y1), gid))
    }

    @discardableResult
    func paintLine(layer: Int, x0: Int, y0: Int, x1: Int, y1: Int, gid: UInt32) -> Int {
        Int(bixel_map_paint_line(handle, UInt32(layer), Int32(x0), Int32(y0), Int32(x1), Int32(y1), gid))
    }

    /// Copy a rectangular region into a raw-GID pattern.
    func readRegion(layer: Int, x: Int, y: Int, w: Int, h: Int) -> MapTilePattern {
        guard w > 0, h > 0 else { return MapTilePattern() }
        var tiles = [UInt32](repeating: 0, count: w * h)
        let written = tiles.withUnsafeMutableBufferPointer {
            bixel_map_read_region(handle, UInt32(layer), UInt32(x), UInt32(y),
                                  UInt32(w), UInt32(h), $0.baseAddress)
        }
        if Int(written) < tiles.count { tiles.removeSubrange(Int(written)...tiles.count - 1) }
        return MapTilePattern(width: w, height: h, tiles: tiles)
    }

    @discardableResult
    func replace(layer: Int, x: Int, y: Int, w: Int, h: Int, from: UInt32, to: UInt32) -> Int {
        Int(bixel_map_replace(handle, UInt32(layer), UInt32(x), UInt32(y), UInt32(w), UInt32(h), from, to))
    }

    /// Same-tile region mask (magic wand). Returns a row-major `[Bool]`.
    func wandMask(layer: Int, x: Int, y: Int) -> [Bool] {
        var mask = [UInt8](repeating: 0, count: columns * rows)
        let count = mask.withUnsafeMutableBufferPointer {
            bixel_map_wand_mask(handle, UInt32(layer), Int32(x), Int32(y), $0.baseAddress, UInt($0.count))
        }
        _ = count
        return mask.map { $0 != 0 }
    }

    // MARK: Object layers

    @discardableResult
    func addObject(layer: Int, name: String, kind: String, x: Double, y: Double, w: Double, h: Double) -> Int64 {
        bixel_map_add_object(handle, UInt32(layer), name, kind, x, y, w, h)
    }

    func removeObject(layer: Int, objectID: Int) {
        bixel_map_remove_object(handle, UInt32(layer), UInt32(objectID))
    }

    func setObject(layer: Int, objectID: Int, name: String, kind: String,
                   x: Double, y: Double, w: Double, h: Double) {
        bixel_map_set_object(handle, UInt32(layer), UInt32(objectID), name, kind, x, y, w, h)
    }

    func objects(layer: Int) -> [MapObjectRow] {
        let ptr = bixel_map_objects_json(handle, UInt32(layer))
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8),
              let list = try? JSONDecoder().decode([MapObjectRow].self, from: data) else { return [] }
        return list
    }

    // MARK: Properties

    /// `target`: 0 map, 1 layer, 2 object.
    func setProperties(target: Int, layer: Int?, objectID: Int?, properties: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: properties)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        let ok = bixel_map_set_properties(handle, UInt8(target),
                                          Int32(layer ?? -1), Int64(objectID ?? -1), json)
        guard ok else { throw StorageError.message("Could not update the properties.") }
    }

    func properties(target: Int, layer: Int?, objectID: Int?) -> [[String: Any]] {
        let ptr = bixel_map_properties_json(handle, UInt8(target), Int32(layer ?? -1), Int64(objectID ?? -1))
        defer { bixel_string_free(ptr) }
        guard let ptr, let data = String(cString: ptr).data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    // MARK: Resize / history / render

    func resize(width: Int, height: Int) {
        bixel_map_resize(handle, UInt32(max(1, width)), UInt32(max(1, height)))
    }

    func snapshot() { bixel_map_snapshot(handle) }
    @discardableResult
    func undo() -> Bool { bixel_map_undo(handle) }
    @discardableResult
    func redo() -> Bool { bixel_map_redo(handle) }
    var canUndo: Bool { bixel_map_can_undo(handle) }
    var canRedo: Bool { bixel_map_can_redo(handle) }

    /// Composite visible tile layers into a caller-owned RGBA buffer.
    func composite(into buffer: UnsafeMutableRawPointer, capacity: Int) -> Bool {
        bixel_map_composite(handle, buffer.assumingMemoryBound(to: UInt8.self), UInt(capacity))
    }

    func compositeRGBA() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        buf.withUnsafeMutableBytes { raw in
            _ = composite(into: raw.baseAddress!, capacity: raw.count)
        }
        return buf
    }

    func layerCSV(layer: Int) -> String {
        let ptr = bixel_map_layer_csv(handle, UInt32(layer))
        defer { bixel_string_free(ptr) }
        return ptr.map { String(cString: $0) } ?? ""
    }

    // MARK: GID helpers

    static func encodeGID(_ localTile: UInt32, firstGID: UInt32, flags: UInt32 = 0) -> UInt32 {
        (firstGID + localTile) | (flags & (GIDFlag.horizontal | GIDFlag.vertical | GIDFlag.diagonal))
    }
}

// MARK: - Project filesystem gateway

enum StorageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ProjectStorage {
    static func request(base: URL, _ request: [String: Any]) throws -> Any? {
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8), let ptr = bixel_storage_request(base.path, text) else {
            throw StorageError.message("Storage request failed.")
        }
        defer { bixel_string_free(ptr) }
        let result = try JSONSerialization.jsonObject(with: Data(String(cString: ptr).utf8)) as? [String: Any]
        if let error = result?["error"] as? String { throw StorageError.message(error) }
        return result?["value"]
    }

    static func read(base: URL, path: String) throws -> String? {
        try request(base: base, ["op": "read", "path": path]) as? String
    }

    static func write(base: URL, path: String, data: Data) throws {
        let error = data.withUnsafeBytes { raw in
            bixel_storage_write(base.path, path, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt64(data.count))
        }
        if let error {
            defer { bixel_string_free(error) }
            throw StorageError.message(String(cString: error))
        }
    }
}
