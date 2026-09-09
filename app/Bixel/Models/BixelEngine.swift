// BixelEngine.swift
//
// Swift wrapper over the Rust engine's C ABI (generated/bixel.h).
// This is the ONLY place raw C pointers cross the boundary: everything else in
// the app talks to typed Swift objects. Bulk pixel data is copied into
// caller-owned buffers exactly once per frame, matching the
// "Swift sends a command, Rust processes a whole buffer" contract.

import Foundation

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
