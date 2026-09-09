// TileMapPanels.swift
//
// Floating chrome for the Tilemap Designer, reusing the Procreate design
// system: TilesetPanel (tile palette + slicing + autotile slots), MapLayersPanel
// (tile + object layers), a left dock with undo/redo and the armed brush, a
// minimap overlay, a properties editor, and workspace feedback capsule.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - Left dock (undo / redo / brush)

struct MapLeftDock: View {
    @ObservedObject var model: TileMapModel
    @State private var showProperties = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(model.map.canUndo ? Color.white.opacity(0.9) : Color.white.opacity(0.22))
                        .frame(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!model.map.canUndo)
                .help("Undo (⌘Z)")

                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(model.map.canRedo ? Color.white.opacity(0.9) : Color.white.opacity(0.22))
                        .frame(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!model.map.canRedo)
                .help("Redo (⇧⌘Z)")
            }

            if !model.brush.pattern.isEmpty {
                Divider().frame(width: 26).overlay(StudioTheme.hairline)
                VStack(spacing: 8) {
                    Text("Brush")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(StudioTheme.textSecondary)
                    Text("\(model.brush.pattern.width)×\(model.brush.pattern.height)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Button { model.flipBrushH() } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Flip horizontal (X)")
                    Button { model.flipBrushV() } label: {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Flip vertical (Y)")
                    Button { model.rotateBrushCW() } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Rotate clockwise (C)")
                    Button { model.clearBrush() } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.6))
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Clear brush")
                }
            }

            Divider().frame(width: 26).overlay(StudioTheme.hairline)

            Button { showProperties = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(.plain)
            .help("Map properties")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(width: 46)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(StudioTheme.procreateGlass))
        )
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 6)
        .sheet(isPresented: $showProperties) {
            MapPropertiesEditor(model: model, target: .map)
                .frame(width: 320, height: 380)
        }
    }
}

// MARK: - Tileset panel

struct TilesetPanel: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: TileMapModel
    @State private var showAddSheet = false
    @State private var pendingAdd: AddTilesetSource?
    @State private var autotileEditing = false

    private var tileset: MapTilesetInfo? {
        model.tilesetList.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tileset")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.92))
                Spacer()
                if model.tilesetList.count > 1 {
                    Text("\(model.tilesetList.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Button { pickImage() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Add tileset image")
                if let ts = tileset {
                    Button { model.removeTileset(ts.index) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Remove tileset")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let cg = tileset.flatMap({ model.tilesetDisplayImage($0.index) }), let ts = tileset {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        TileSheetView(
                            cgImage: cg,
                            tileset: ts,
                            onPickSingle: { local in model.armTile(tilesetIndex: ts.index, localTile: local) },
                            onPickRegion: { cols, rows in model.armRegion(tilesetIndex: ts.index, cols: cols, rows: rows) },
                            assignSlot: autotileEditing ? autotileSlotToAssign : nil,
                            onAssign: { local in
                                if let mask = autotileSlotToAssign {
                                    model.setTilesetAutotile(tileset: ts.index, mask: mask, local: Int32(local))
                                    model.autotileEnabled = true
                                    autotileEditing = false
                                }
                            }
                        )
                        .frame(maxWidth: .infinity)
                        .background(CheckerboardView(cell: 5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
                        .help("Click to arm a tile; drag to arm a multi-tile brush")

                        Text("\(ts.imageWidth) × \(ts.imageHeight) px · \(ts.tileWidth)×\(ts.tileHeight) tiles")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 340)

                // Autotile slot editor
                autotileSection(ts: ts)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(.white.opacity(0.25))
                    Text("Add a tileset PNG to start painting.")
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.textSecondary)
                    Button {
                        pickImage()
                    } label: {
                        Label("Choose image…", systemImage: "photo")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            }
        }
        .frame(width: 236)
        .procreatePanel(radius: 16)
        .sheet(isPresented: $showAddSheet) {
            if let pending = pendingAdd {
                AddTilesetSheet(
                    source: pending,
                    defaultTileWidth: model.map.cellWidth,
                    defaultTileHeight: model.map.cellHeight,
                    onCancel: { showAddSheet = false },
                    onConfirm: { tw, th, margin, spacing in
                        commitTileset(pending, tw: tw, th: th, margin: margin, spacing: spacing)
                        showAddSheet = false
                    }
                )
                .frame(width: 420, height: 440)
            }
        }
    }

    @State private var autotileSlotToAssign: Int?

    private func autotileSection(ts: MapTilesetInfo) -> some View {
        let slots = model.tilesetAutotile(ts.index)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Autotile", isOn: Binding(
                    get: { model.autotileEnabled },
                    set: { model.autotileEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

                Spacer()

                Button(autotileEditing ? "Done" : "Set slots…") {
                    autotileEditing.toggle()
                    autotileSlotToAssign = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(autotileEditing ? StudioTheme.accent : .secondary)
            }
            .padding(.horizontal, 12)

            if autotileEditing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(autotileSlotToAssign.map { "Assigning mask \($0) — click a tile" } ?? "Pick a mask slot, then click its tile")
                        .font(.system(size: 10))
                        .foregroundColor(autotileSlotToAssign != nil ? StudioTheme.accent : StudioTheme.textSecondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 4), count: 8), spacing: 4) {
                        ForEach(0..<16, id: \.self) { mask in
                            let local = slots[mask]
                            Button {
                                if let local {
                                    model.setTilesetAutotile(tileset: ts.index, mask: mask, local: nil)
                                } else {
                                    autotileSlotToAssign = autotileSlotToAssign == mask ? nil : mask
                                }
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(autotileSlotToAssign == mask ? StudioTheme.accent.opacity(0.35) : Color.white.opacity(0.08))
                                    if let local, let thumb = tileThumb(ts: ts, local: UInt32(local)) {
                                        Image(nsImage: NSImage(cgImage: thumb, size: .zero))
                                            .interpolation(.none)
                                            .resizable()
                                    }
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(autotileSlotToAssign == mask ? StudioTheme.accent : StudioTheme.hairlineStrong, lineWidth: 1)
                                }
                                .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help(maskLabel(mask))
                        }
                    }
                    Text("Slots are the 4-bit N/E/S/W border masks. Empty = leave tile.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .padding(.bottom, 8)
    }

    private func maskLabel(_ mask: Int) -> String {
        var parts: [String] = []
        if mask & 1 != 0 { parts.append("N") }
        if mask & 2 != 0 { parts.append("E") }
        if mask & 4 != 0 { parts.append("S") }
        if mask & 8 != 0 { parts.append("W") }
        return parts.isEmpty ? "isolated (mask 0)" : "mask \(parts.joined()) (\(mask))"
    }

    /// Small nearest-neighbour thumbnail of one tile from the tileset image.
    private func tileThumb(ts: MapTilesetInfo, local: UInt32) -> CGImage? {
        guard let cg = model.tilesetDisplayImage(ts.index) else { return nil }
        let stride = ts.tileWidth + ts.spacing
        let col = Int(local) % ts.columns
        let row = Int(local) / ts.columns
        let rect = CGRect(x: ts.margin + col * stride,
                          y: ts.margin + row * stride,
                          width: ts.tileWidth, height: ts.tileHeight)
        return cg.cropping(to: rect)
    }

    // MARK: Add tileset flow

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url),
                  let image = AIService.pngToRGBA(data) else {
                store.error = "Could not decode that tileset image."
                return
            }
            guard let cg = makeCGImage(pixels: image.rgba, width: image.width, height: image.height) else {
                store.error = "Unsupported tileset image."
                return
            }
            pendingAdd = AddTilesetSource(name: url.deletingPathExtension().lastPathComponent,
                                          data: data, cgImage: cg,
                                          rgba: image.rgba, width: image.width, height: image.height)
            showAddSheet = true
        }
    }

    private func commitTileset(_ source: AddTilesetSource, tw: Int, th: Int, margin: Int, spacing: Int) {
        guard let rel = store.persistImageAsset(data: source.data, name: source.name) else {
            store.error = "Could not copy the tileset into the project."
            return
        }
        do {
            let index = try model.map.addTileset(name: source.name, image: rel,
                                                 rgba: source.rgba,
                                                 imageWidth: source.width, imageHeight: source.height,
                                                 tileWidth: tw, tileHeight: th, margin: margin, spacing: spacing)
            model.attachTilesetImage(index, cgImage: source.cgImage)
            model.snapshotAndRefresh()
            if model.tilesetList.count == 1 { model.autotileEnabled = false }
        } catch {
            store.error = error.localizedDescription
        }
    }
}

private struct AddTilesetSource {
    let name: String
    let data: Data
    let cgImage: CGImage
    let rgba: [UInt8]
    let width: Int
    let height: Int
}

// MARK: - Tileset sheet view (click / drag-select)

private struct SheetCell {
    var x: Int
    var y: Int
}

private struct TileSheetView: View {
    let cgImage: CGImage
    let tileset: MapTilesetInfo
    let onPickSingle: (UInt32) -> Void
    let onPickRegion: (Int, Int) -> Void
    var assignSlot: Int? = nil
    var onAssign: (UInt32) -> Void

    @State private var dragStart: SheetCell?

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(cgImage.width),
                            geo.size.height / CGFloat(cgImage.height))
            let w = CGFloat(cgImage.width) * scale
            let h = CGFloat(cgImage.height) * scale
            let x0 = (geo.size.width - w) / 2
            let y0 = (geo.size.height - h) / 2
            ZStack {
                Image(nsImage: NSImage(cgImage: cgImage, size: .zero))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: w, height: h)
                    .position(x: x0 + w / 2, y: y0 + h / 2)

                // Cell grid overlay
                Canvas { ctx, size in
                    var path = Path()
                    let strideX = CGFloat(tileset.tileWidth + tileset.spacing) * scale
                    let strideY = CGFloat(tileset.tileHeight + tileset.spacing) * scale
                    let marginX = CGFloat(tileset.margin) * scale
                    let marginY = CGFloat(tileset.margin) * scale
                    var cx = marginX
                    while cx <= w {
                        path.move(to: CGPoint(x: x0 + cx, y: y0))
                        path.addLine(to: CGPoint(x: x0 + cx, y: y0 + h))
                        cx += strideX
                    }
                    var cy = marginY
                    while cy <= h {
                        path.move(to: CGPoint(x: x0, y: y0 + cy))
                        path.addLine(to: CGPoint(x: x0 + w, y: y0 + cy))
                        cy += strideY
                    }
                    ctx.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = cell(at: value.location, x0: x0, y0: y0, w: w, h: h, scale: scale)
                        }
                    }
                    .onEnded { value in
                        defer { dragStart = nil }
                        guard let start = dragStart,
                              let end = cell(at: value.location, x0: x0, y0: y0, w: w, h: h, scale: scale) else { return }
                        let x0c = min(start.x, end.x), y0c = min(start.y, end.y)
                        let x1c = max(start.x, end.x), y1c = max(start.y, end.y)
                        let cols = x1c - x0c + 1
                        let rows = y1c - y0c + 1
                        let anchor = start
                        if let _ = assignSlot {
                            let local = UInt32(anchor.y * tileset.columns + anchor.x)
                            onAssign(local)
                        } else if cols == 1 && rows == 1 {
                            onPickSingle(UInt32(anchor.y * tileset.columns + anchor.x))
                        } else {
                            onPickRegion(cols, rows)
                        }
                    }
            )
        }
    }

    private func cell(at point: CGPoint, x0: CGFloat, y0: CGFloat, w: CGFloat, h: CGFloat, scale: CGFloat) -> SheetCell? {
        let px = point.x - x0
        let py = point.y - y0
        guard px >= 0, py >= 0, px <= w, py <= h else { return nil }
        let strideX = CGFloat(tileset.tileWidth + tileset.spacing) * scale
        let strideY = CGFloat(tileset.tileHeight + tileset.spacing) * scale
        let col = Int((px - CGFloat(tileset.margin) * scale) / strideX)
        let row = Int((py - CGFloat(tileset.margin) * scale) / strideY)
        guard col >= 0, row >= 0, col < tileset.columns, row * tileset.columns + col < tileset.tileCount else { return nil }
        return SheetCell(x: col, y: row)
    }
}

// MARK: - Add tileset sheet

private struct AddTilesetSheet: View {
    let source: AddTilesetSource
    let defaultTileWidth: Int
    let defaultTileHeight: Int
    let onCancel: () -> Void
    let onConfirm: (Int, Int, Int, Int) -> Void

    @State private var tileWidth = 16
    @State private var tileHeight = 16
    @State private var margin = 0
    @State private var spacing = 0

    private var slicing: (columns: Int, tiles: Int) {
        let tw = max(1, tileWidth), th = max(1, tileHeight)
        let numW = source.width - 2 * margin + spacing
        let numH = source.height - 2 * margin + spacing
        let cols = numW > 0 ? numW / (tw + spacing) : 0
        let rows = numH > 0 ? numH / (th + spacing) : 0
        return (max(0, cols), max(0, cols * rows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add tileset")
                .font(.title3.bold())
            HStack(spacing: 12) {
                Image(nsImage: NSImage(cgImage: source.cgImage, size: .zero))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 110)
                    .background(CheckerboardView(cell: 5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(source.width) × \(source.height) px")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(slicing.columns) columns · \(slicing.tiles) tiles")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(slicing.tiles > 0 ? StudioTheme.accent : .red)
                }
            }
            .padding(10)
            .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 10))

            Group {
                stepperRow("Tile width", value: $tileWidth, in: 1...256)
                stepperRow("Tile height", value: $tileHeight, in: 1...256)
                stepperRow("Margin", value: $margin, in: 0...64)
                stepperRow("Spacing", value: $spacing, in: 0...64)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add tileset") { onConfirm(tileWidth, tileHeight, margin, spacing) }
                    .buttonStyle(.borderedProminent)
                    .disabled(slicing.tiles == 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .onAppear {
            tileWidth = defaultTileWidth
            tileHeight = defaultTileHeight
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Stepper(value: value, in: range) { Text("\(value.wrappedValue)").frame(width: 36, alignment: .trailing) }
        }
    }
}

// MARK: - Map layers panel

struct MapLayersPanel: View {
    @ObservedObject var model: TileMapModel
    @State private var showAddMenu = false
    @State private var editingLayer: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Map Layers")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.92))
                Spacer()
                Menu {
                    Button("Tile layer") { model.addLayer() }
                    Button("Object layer") { model.addObjectLayer() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add layer")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.layers.reversed()) { layer in
                        row(layer)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)

            if model.isObjectActive, let row = model.layers.first(where: { $0.index == model.activeLayer }) {
                objectInspector(layerIndex: row.index)
            }
        }
        .frame(width: 280)
        .procreatePanel(radius: 16)
    }

    private func row(_ layer: MapLayerRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: layer.type == "tile" ? "square.grid.3x3" : "mappin")
                .font(.system(size: 11))
                .foregroundColor(layer.index == model.activeLayer ? .white : Color.white.opacity(0.5))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                if editingLayer == layer.index {
                    TextField("", text: Binding(
                        get: { layer.name },
                        set: { _ in }
                    ), onCommit: {
                        // Commit via the shared model method below.
                        if let edited = editingLayer, let row = model.layers.first(where: { $0.index == edited }) {
                            model.renameLayer(row.index, name: editingDraft)
                        }
                        editingLayer = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .onAppear { editingDraft = layer.name }
                } else {
                    Text(layer.name)
                        .font(.system(size: 13, weight: layer.index == model.activeLayer ? .semibold : .regular))
                        .foregroundColor(layer.index == model.activeLayer ? .white : Color.white.opacity(0.88))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            editingDraft = layer.name
                            editingLayer = layer.index
                        }
                }
                if layer.type == "object", let count = layer.objectCount {
                    Text("\(count) object\(count == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.45))
                }
            }

            Spacer(minLength: 4)

            if layer.type == "tile" {
                Button {
                    model.setLayerOpacity(layer.index, 1.0)
                } label: {
                    Image(systemName: layer.opacity >= 1 ? "circle" : "circle.dotted")
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Opacity \(Int((layer.opacity * 100).rounded()))% — click to reset")
            }

            ProcreateCheckbox(
                isChecked: layer.visible,
                isOnBlue: layer.index == model.activeLayer,
                action: { model.toggleLayerVisibility(layer.index) }
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(layer.index == model.activeLayer ? StudioTheme.procreateBlue : Color(white: 0.17, opacity: 0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(layer.index == model.activeLayer ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.activeLayer = layer.index
            model.selectedObjectID = nil
        }
        .draggable(String(layer.index))
        .dropDestination(for: String.self, action: { items, _ in
            guard let raw = items.first, let from = Int(raw), from != layer.index else { return false }
            model.moveLayer(from: from, to: layer.index)
            return true
        }, isTargeted: { _ in })
        .contextMenu {
            Button("Rename") {
                editingDraft = layer.name
                editingLayer = layer.index
            }
            if layer.type == "object" {
                Button("Add object layer") { model.addObjectLayer() }
            } else {
                Button("Add tile layer") { model.addLayer() }
            }
            Divider()
            Button("Delete", role: .destructive) {
                model.activeLayer = layer.index
                model.deleteLayer()
            }
            .disabled(model.layers.count <= 1)
        }
    }

    @State private var editingDraft = ""

    // MARK: Object inspector (numeric resize + object rows)

    private func objectInspector(layerIndex: Int) -> some View {
        let objects = model.map.objects(layer: layerIndex)
        return VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(StudioTheme.hairline)
            HStack {
                Text("Objects")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    model.snapshotAndRefresh()
                    _ = model.map.addObject(layer: layerIndex, name: "Object", kind: "rect",
                                            x: 16, y: 16, w: 32, h: 32)
                    model.selectedObjectID = nil
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)

            if objects.isEmpty {
                Text("Click on the canvas to place a rectangle.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ForEach(objects, id: \.id) { obj in
                    HStack(spacing: 8) {
                        Button {
                            model.selectedObjectID = (model.selectedObjectID == obj.id) ? nil : obj.id
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: obj.type == "point" ? "plus" : "rectangle.dashed")
                                    .font(.system(size: 10))
                                Text(obj.name.isEmpty ? "Object \(obj.id)" : obj.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Int(obj.x)),\(Int(obj.y))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(model.selectedObjectID == obj.id ? StudioTheme.accent.opacity(0.28) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.deleteObject(obj.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Workspace feedback capsule

struct MapWorkspaceFeedback: View {
    @ObservedObject var model: TileMapModel
    var body: some View {
        Group {
            if !model.brush.pattern.isEmpty || model.hasPasteGhost {
                HStack(spacing: 10) {
                    if let name = model.tileName, !model.hasPasteGhost {
                        Label("Tile brush: \(name)", systemImage: "square.grid.2x2")
                    } else if model.hasPasteGhost {
                        Label("Paste — click to place", systemImage: "doc.on.clipboard")
                    } else {
                        Label("\(model.brush.pattern.width)×\(model.brush.pattern.height) brush", systemImage: "square.grid.2x2")
                    }
                    if model.autotileEnabled {
                        Text("Autotile")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(StudioTheme.bixelGreen.opacity(0.2)))
                    }
                    Button("Clear brush") { model.clearBrush(); model.hasPasteGhost = false }
                        .font(.caption)
                    if model.hasPasteGhost {
                        Button("Cancel") {
                            model.hasPasteGhost = false
                            model.clearBrush()
                        }
                        .font(.caption)
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
            } else {
                Color.clear.frame(height: 1)
            }
        }
    }
}

// MARK: - Minimap overlay

struct MiniMapOverlay: View {
    @ObservedObject var model: TileMapModel
    @ObservedObject var viewport: CanvasViewport

    private let boxSize: CGFloat = 164

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Map")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text("\(model.width)×\(model.height) cells")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                let mapW = CGFloat(model.map.pixelWidth)
                let mapH = CGFloat(model.map.pixelHeight)
                let inner = geo.size
                let scale = min(inner.width / max(1, mapW), inner.height / max(1, mapH))
                let imgW = mapW * scale
                let imgH = mapH * scale
                let ox = (inner.width - imgW) / 2
                let oy = (inner.height - imgH) / 2
                ZStack {
                    Color.clear
                        .background(CheckerboardView(cell: 4))
                    if let cg = model.compositeCGImage() {
                        Image(nsImage: NSImage(cgImage: cg, size: .zero))
                            .resizable()
                            .interpolation(.none)
                            .frame(width: imgW, height: imgH)
                            .position(x: ox + imgW / 2, y: oy + imgH / 2)
                    }
                    viewportRect(scale: scale, ox: ox, oy: oy, mapW: mapW, mapH: mapH, imgW: imgW, imgH: imgH)
                        .position(x: ox + imgW / 2, y: oy + imgH / 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        let x = value.location.x - ox
                        let y = value.location.y - oy
                        guard x >= 0, y >= 0, x <= imgW, y <= imgH else { return }
                        jump(toDocX: x / scale, y: y / scale)
                    }
                )
            }
            .frame(width: boxSize, height: boxSize)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
            .help("Click to centre the canvas on that area")
        }
        .padding(10)
        .frame(width: boxSize + 20)
        .procreatePanel(radius: 12)
    }

    @ViewBuilder
    private func viewportRect(scale: CGFloat, ox: CGFloat, oy: CGFloat, mapW: CGFloat, mapH: CGFloat, imgW: CGFloat, imgH: CGFloat) -> some View {
        let viewSize = viewport.lastViewSize
        if viewSize.width <= 0 { EmptyView() } else {
            // Visible viewport rectangle in document pixel space (y-up AppKit).
            let vw = min(mapW, viewSize.width / viewport.zoom)
            let vh = min(mapH, viewSize.height / viewport.zoom)
            // Artboard origin in view points; top-left doc corner in view space.
            let origin = viewport.artboardOrigin(viewSize: viewSize, canvasWidth: model.map.pixelWidth, height: model.map.pixelHeight)
            let leftDoc = max(0, -origin.x / viewport.zoom)
            let topDoc = max(0, (viewSize.height - (origin.y + mapH * viewport.zoom)) / viewport.zoom)
            let rightDoc = min(mapW, leftDoc + vw)
            let bottomDoc = min(mapH, topDoc + vh)
            let rect = CGRect(x: ox + leftDoc * scale, y: oy + topDoc * scale,
                              width: (rightDoc - leftDoc) * scale, height: (bottomDoc - topDoc) * scale)
            Rectangle()
                .strokeBorder(StudioTheme.accent.opacity(0.9), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX - imgW / 2, y: rect.minY - imgH / 2)
        }
    }

    private func jump(toDocX px: CGFloat, y py: CGFloat) {
        let zoom = viewport.zoom
        let mapW = CGFloat(model.map.pixelWidth)
        let mapH = CGFloat(model.map.pixelHeight)
        viewport.pan = CGPoint(x: zoom * (mapW / 2 - px), y: zoom * (py - mapH / 2))
    }
}

// MARK: - Properties editor

enum MapPropertiesTarget: Equatable {
    case map
    case layer(Int)
    case object(layer: Int, objectID: Int)

    var code: Int {
        switch self {
        case .map: return 0
        case .layer: return 1
        case .object: return 2
        }
    }

    var layerIndex: Int? {
        switch self {
        case .layer(let i): return i
        case .object(let layer, _): return layer
        case .map: return nil
        }
    }

    var objectID: Int? {
        switch self {
        case .object(_, let id): return id
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .map: return "Map properties"
        case .layer: return "Layer properties"
        case .object: return "Object properties"
        }
    }
}

struct MapPropertiesEditor: View {
    @ObservedObject var model: TileMapModel
    let target: MapPropertiesTarget

    @State private var props: [[String: Any]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(target.title).font(.headline)
                Spacer()
                Button("Revert") { reload() }.font(.caption)
                Button("Save") { save() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            if props.isEmpty {
                Text("No custom properties yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(props.indices, id: \.self) { i in
                        propertyRow(i)
                    }
                }
            }
            Button {
                props.append(["name": "property", "type": "string", "value": ""])
            } label: {
                Label("Add property", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .onAppear { reload() }
    }

    private func reload() {
        props = model.map.properties(target: target.code, layer: target.layerIndex, objectID: target.objectID)
    }

    private func save() {
        do {
            try model.map.setProperties(target: target.code, layer: target.layerIndex,
                                        objectID: target.objectID, properties: props)
            model.commitChange()
        } catch {
            model.operationError = error.localizedDescription
        }
    }

    private func propertyRow(_ i: Int) -> some View {
        HStack(spacing: 6) {
            TextField("Name", text: textBinding($props[i], key: "name"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Picker("", selection: menuBinding($props[i], key: "type")) {
                ForEach(["string", "int", "float", "bool"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 72)
            valueEditor($props[i])
            Button {
                props.remove(at: i)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func valueEditor(_ binding: Binding<[String: Any]>) -> some View {
        let type = binding.wrappedValue["type"] as? String ?? "string"
        switch type {
        case "bool":
            Toggle("", isOn: boolBinding(binding))
                .labelsHidden()
                .frame(width: 50)
        default:
            TextField("Value", text: valueTextBinding(binding, type: type))
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
        }
    }

    private func textBinding(_ dict: Binding<[String: Any]>, key: String) -> Binding<String> {
        Binding<String>(
            get: { dict.wrappedValue[key] as? String ?? "" },
            set: { dict.wrappedValue[key] = $0 }
        )
    }

    private func menuBinding(_ dict: Binding<[String: Any]>, key: String) -> Binding<String> {
        Binding<String>(
            get: { (dict.wrappedValue[key] as? String) ?? "string" },
            set: { value in
                dict.wrappedValue[key] = value
                if dict.wrappedValue["value"] == nil { dict.wrappedValue["value"] = "" }
            }
        )
    }

    private func valueTextBinding(_ dict: Binding<[String: Any]>, type: String) -> Binding<String> {
        Binding<String>(
            get: {
                let value = dict.wrappedValue["value"]
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return n.stringValue }
                return ""
            },
            set: { newValue in
                if type == "int" {
                    dict.wrappedValue["value"] = Int(newValue) ?? 0
                } else if type == "float" {
                    dict.wrappedValue["value"] = Double(newValue) ?? 0
                } else {
                    dict.wrappedValue["value"] = newValue
                }
            }
        )
    }

    private func boolBinding(_ dict: Binding<[String: Any]>) -> Binding<Bool> {
        Binding<Bool>(
            get: { (dict.wrappedValue["value"] as? Bool) ?? false },
            set: { dict.wrappedValue["value"] = $0 }
        )
    }
}
