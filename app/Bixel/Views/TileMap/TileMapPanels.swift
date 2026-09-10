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
    @State private var addSheet: TilesetAddSheet?
    @State private var autotileEditing = false
    @State private var autotileSlotToAssign: Int?
    @State private var activeTileset = 0

    private var tilesetList: [MapTilesetInfo] { model.tilesetList }

    private var tileset: MapTilesetInfo? {
        guard activeTileset < tilesetList.count else { return nil }
        return tilesetList[activeTileset]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tilesetList.count > 1 { tilesetTabs }
            if let ts = tileset, let cg = model.tilesetDisplayImage(ts.index) {
                tilesetContent(ts: ts, cg: cg)
            } else {
                emptyState
            }
            dividerAndHint
        }
        .frame(width: 288)
        .procreatePanel(radius: 16)
        .onChange(of: tilesetList.count) { _ in
            if activeTileset >= tilesetList.count { activeTileset = max(0, tilesetList.count - 1) }
        }
        .sheet(item: $addSheet) { sheet in
            switch sheet {
            case .chooser:
                ProjectTilesetPicker(
                    store: store,
                    onPick: { name, data in
                        guard let source = prepareSource(name: name, data: data) else { return }
                        addSheet = nil
                        DispatchQueue.main.async { addSheet = .configure(source) }
                    },
                    onChooseFile: {
                        addSheet = nil
                        DispatchQueue.main.async { pickImage() }
                    },
                    onCancel: { addSheet = nil }
                )
                .frame(width: 380, height: 460)
            case .configure(let source):
                AddTilesetSheet(
                    source: source,
                    defaultTileWidth: model.map.cellWidth,
                    defaultTileHeight: model.map.cellHeight,
                    onCancel: { addSheet = nil },
                    onConfirm: { tw, th, margin, spacing in
                        commitTileset(source, tw: tw, th: th, margin: margin, spacing: spacing)
                        addSheet = nil
                    }
                )
                .frame(width: 440, height: 460)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Tilesets")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.92))
            Text("\(tilesetList.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            Spacer()

            if let ts = tileset {
                Button {
                    let removing = ts.index
                    activeTileset = 0
                    model.removeTileset(removing)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Remove the selected tileset")
            }

            Menu {
                Button {
                    pickImage()
                } label: {
                    Label("Image file…", systemImage: "folder")
                }
                Button {
                    addSheet = .chooser
                } label: {
                    Label("From project assets…", systemImage: "square.stack")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a tileset (image file or an existing project asset)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var tilesetTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(tilesetList.enumerated()), id: \.element.index) { pos, ts in
                    Button {
                        activeTileset = pos
                    } label: {
                        Text(ts.name.isEmpty ? "Tileset \(pos + 1)" : ts.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .foregroundColor(pos == activeTileset ? .white : Color.white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(pos == activeTileset ? StudioTheme.accent : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private func tilesetContent(ts: MapTilesetInfo, cg: CGImage) -> some View {
        VStack(spacing: 8) {
            TileSheetView(
                cgImage: cg,
                tileset: ts,
                armed: armedRect(ts),
                onPickSingle: { local in
                    model.armTile(tilesetIndex: ts.index, localTile: local)
                },
                onPickRegion: { col, row, cols, rows in
                    model.armRegion(tilesetIndex: ts.index, startCol: col, startRow: row, cols: cols, rows: rows)
                },
                assignSlot: autotileEditing ? autotileSlotToAssign : nil,
                onAssign: { local in
                    if let mask = autotileSlotToAssign {
                        model.setTilesetAutotile(tileset: ts.index, mask: mask, local: Int32(local))
                        model.autotileEnabled = true
                        autotileEditing = false
                    }
                }
            )
            .padding(.horizontal, 10)

            brushStrip(ts: ts)

            autotileSection(ts: ts)

            Text("\(ts.imageWidth) × \(ts.imageHeight) px · \(ts.tileWidth)×\(ts.tileHeight)px tiles · \(ts.columns) cols")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    /// The armed region of this tileset, for the tile-sheet selection highlight.
    private func armedRect(_ ts: MapTilesetInfo) -> TileSheetSelection? {
        guard model.brush.tilesetIndex == ts.index,
              !model.brush.pattern.isEmpty,
              let first = model.brush.pattern.tiles.first,
              ts.columns > 0 else { return nil }
        let local = Int(first & 0x1fff_ffff) - Int(ts.firstGid)
        guard local >= 0 else { return nil }
        return TileSheetSelection(col: local % ts.columns,
                                  row: local / ts.columns,
                                  cols: model.brush.pattern.width,
                                  rows: model.brush.pattern.height)
    }

    /// Shows the currently armed brush and how to use it.
    private func brushStrip(ts: MapTilesetInfo) -> some View {
        let brush = model.brush
        return HStack(spacing: 8) {
            if !brush.pattern.isEmpty {
                brushThumbnail(ts: ts)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(brush.pattern.width)×\(brush.pattern.height) brush armed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                    Text(brush.tilesetIndex == ts.index ? "Click the canvas to paint" : "From another tileset")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Click or drag a tile above to choose a brush")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !brush.pattern.isEmpty {
                Button { model.clearBrush() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    /// The armed tile's actual pixels, or a paintbrush glyph when unavailable.
    @ViewBuilder
    private func brushThumbnail(ts: MapTilesetInfo) -> some View {
        let brush = model.brush
        Group {
            if brush.tilesetIndex == ts.index,
               let first = brush.pattern.tiles.first,
               let thumb = tileThumb(ts: ts, local: (first & 0x1fff_ffff) &- ts.firstGid) {
                Image(nsImage: NSImage(cgImage: thumb, size: .zero))
                    .interpolation(.none)
                    .resizable()
            } else {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.accent)
            }
        }
        .frame(width: 24, height: 24)
        .background(CheckerboardView(cell: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(StudioTheme.accent, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.white.opacity(0.25))
            Text("No tileset yet — add one to start painting tiles.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Menu {
                Button { pickImage() } label: { Label("Image file…", systemImage: "folder") }
                Button { addSheet = .chooser } label: { Label("From project assets…", systemImage: "square.stack") }
            } label: {
                Label("Add tileset", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 8)
    }

    private var dividerAndHint: some View {
        VStack(spacing: 0) {
            Divider().overlay(StudioTheme.hairline)
            Text("Click tile = brush · Drag = region brush · Shift-click drag area then paint")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Autotile

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
                                if local != nil {
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
        .padding(.bottom, 6)
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
        guard let cg = model.tilesetDisplayImage(ts.index), ts.columns > 0 else { return nil }
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
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else {
                store.error = "Could not read that image file."
                return
            }
            if let source = prepareSource(name: url.deletingPathExtension().lastPathComponent, data: data) {
                addSheet = .configure(source)
            }
        }
    }

    /// Decode an image into an `AddTilesetSource`, surfacing decode failures.
    private func prepareSource(name: String, data: Data) -> AddTilesetSource? {
        guard let image = AIService.pngToRGBA(data) else {
            store.error = "Could not decode that tileset image."
            return nil
        }
        guard let cg = makeCGImage(pixels: image.rgba, width: image.width, height: image.height) else {
            store.error = "Unsupported tileset image."
            return nil
        }
        return AddTilesetSource(name: name, data: data, cgImage: cg,
                                rgba: image.rgba, width: image.width, height: image.height)
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
            activeTileset = max(0, tilesetList.count - 1)
        } catch {
            store.error = error.localizedDescription
        }
    }
}

/// Lets the user pick one of the project's image assets as a tileset source,
/// or fall back to choosing an image file from disk.
private struct ProjectTilesetPicker: View {
    @ObservedObject var store: ProjectStore
    let onPick: (String, Data) -> Void
    let onChooseFile: () -> Void
    let onCancel: () -> Void
    @State private var search = ""

    private var imageAssets: [ProjectAssetFile] {
        store.assets.filter { $0.isImage && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add tileset").font(.headline)
                Spacer()
                Button { onCancel() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }

            Button { onChooseFile() } label: {
                Label("Choose image file…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Or use an image already in this project:")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Search project assets", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(imageAssets, id: \.path) { asset in
                        Button {
                            if let data = try? store.assetData(asset) {
                                onPick(asset.name, data)
                            } else {
                                store.error = "Could not read \(asset.name)."
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("\(asset.bytes / 1024) KB").font(.system(size: 9)).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundColor(StudioTheme.accent)
                            }
                            .padding(8)
                            .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                    if imageAssets.isEmpty {
                        Text(store.assets.isEmpty
                             ? "No images in this project yet. Use “Choose image file…” above, or generate art with the AI assistant."
                             : "No images match your search.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(10)
                    }
                }
            }
        }
        .padding(16)
        .background(StudioTheme.background)
        .onAppear { store.refreshAssets() }
    }
}

/// The two-step add-tileset flow: choose a source, then configure slicing.
private enum TilesetAddSheet: Identifiable {
    case chooser
    case configure(AddTilesetSource)

    var id: String {
        switch self {
        case .chooser: return "chooser"
        case .configure(let source): return "configure-\(source.name)-\(source.width)x\(source.height)"
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

private struct SheetCell: Hashable {
    var x: Int
    var y: Int
}

/// A rectangular block of tileset cells (top-left anchored).
private struct TileSheetSelection: Hashable {
    var col: Int
    var row: Int
    var cols: Int
    var rows: Int
}

private enum TileSheetZoom: String, CaseIterable, Identifiable {
    case fit, x1, x2, x4
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Fit"
        case .x1: return "1×"
        case .x2: return "2×"
        case .x4: return "4×"
        }
    }
}

/// Interactive tileset slicer: shows the whole sheet with a cell grid, lets the
/// user click a tile or drag a block, and highlights the currently armed brush.
/// Zooming beyond the viewport scrolls so large sheets stay selectable.
private struct TileSheetView: View {
    let cgImage: CGImage
    let tileset: MapTilesetInfo
    var armed: TileSheetSelection? = nil
    let onPickSingle: (UInt32) -> Void
    let onPickRegion: (Int, Int, Int, Int) -> Void
    var assignSlot: Int? = nil
    var onAssign: (UInt32) -> Void

    @State private var zoom: TileSheetZoom = .fit
    @State private var dragStart: SheetCell?
    @State private var dragCurrent: SheetCell?
    @State private var hover: SheetCell?

    private let viewportWidth: CGFloat = 260
    private let viewportHeight: CGFloat = 200

    private var imageSize: CGSize {
        CGSize(width: max(1, CGFloat(cgImage.width)), height: max(1, CGFloat(cgImage.height)))
    }

    private var displayScale: CGFloat {
        switch zoom {
        case .fit:
            let fit = min(viewportWidth / imageSize.width, viewportHeight / imageSize.height)
            return max(0.05, min(fit, 8))
        case .x1: return 1
        case .x2: return 2
        case .x4: return 4
        }
    }

    private var contentSize: CGSize {
        CGSize(width: imageSize.width * displayScale, height: imageSize.height * displayScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            viewport
            hint
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text(assignSlot.map { "Assign mask \($0)" } ?? "Tile palette")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(assignSlot != nil ? StudioTheme.accent : Color.white.opacity(0.85))
            Spacer()
            Picker("", selection: $zoom) {
                ForEach(TileSheetZoom.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .labelsHidden()
            .frame(width: 138)
        }
    }

    private var viewport: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            sheetContent
                .frame(width: contentSize.width, height: contentSize.height)
        }
        .frame(width: viewportWidth, height: viewportHeight)
        .background(CheckerboardView(cell: 6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
    }

    private var sheetContent: some View {
        Image(nsImage: NSImage(cgImage: cgImage, size: .zero))
            .interpolation(.none)
            .resizable()
            .frame(width: contentSize.width, height: contentSize.height)
            .overlay {
                Canvas { ctx, size in
                    drawGridAndSelection(ctx: &ctx, size: size)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover = cell(at: location)
                case .ended: hover = nil
                }
            }
    }

    private var hint: some View {
        Text(assignSlot != nil
             ? "Click the tile that represents this autotile mask."
             : "Click a tile to paint it · drag to grab a block")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }

    // MARK: Grid + selection rendering

    private func drawGridAndSelection(ctx: inout GraphicsContext, size: CGSize) {
        let scale = displayScale
        let strideX = CGFloat(tileset.tileWidth + tileset.spacing) * scale
        let strideY = CGFloat(tileset.tileHeight + tileset.spacing) * scale
        guard strideX > 0, strideY > 0 else { return }
        let marginX = CGFloat(tileset.margin) * scale
        let marginY = CGFloat(tileset.margin) * scale
        let cellW = CGFloat(tileset.tileWidth) * scale
        let cellH = CGFloat(tileset.tileHeight) * scale

        var grid = Path()
        var x = marginX
        while x <= size.width + 0.5 {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            x += strideX
        }
        var y = marginY
        while y <= size.height + 0.5 {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            y += strideY
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.22)), lineWidth: 1)

        func rect(_ selection: TileSheetSelection) -> CGRect {
            CGRect(
                x: marginX + CGFloat(selection.col) * strideX,
                y: marginY + CGFloat(selection.row) * strideY,
                width: CGFloat(selection.cols) * cellW + CGFloat(max(0, selection.cols - 1)) * (strideX - cellW),
                height: CGFloat(selection.rows) * cellH + CGFloat(max(0, selection.rows - 1)) * (strideY - cellH)
            )
        }

        if let armed {
            let r = rect(armed)
            ctx.fill(Path(r), with: .color(StudioTheme.accent.opacity(0.30)))
            ctx.stroke(Path(r), with: .color(StudioTheme.accent), lineWidth: 2)
        }

        if let dragStart, let dragCurrent {
            let live = TileSheetSelection(col: min(dragStart.x, dragCurrent.x),
                                          row: min(dragStart.y, dragCurrent.y),
                                          cols: abs(dragCurrent.x - dragStart.x) + 1,
                                          rows: abs(dragCurrent.y - dragStart.y) + 1)
            ctx.stroke(Path(rect(live)), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        } else if let hover, assignSlot == nil {
            ctx.stroke(Path(rect(TileSheetSelection(col: hover.x, row: hover.y, cols: 1, rows: 1))),
                       with: .color(.white.opacity(0.45)), lineWidth: 1)
        }
    }

    // MARK: Interaction

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = cell(at: value.location)
                if dragStart == nil { dragStart = current }
                dragCurrent = current
            }
            .onEnded { value in
                let start = dragStart ?? cell(at: value.location)
                let end = cell(at: value.location) ?? start
                defer { dragStart = nil; dragCurrent = nil }
                guard let start, let end else { return }
                let col0 = min(start.x, end.x), row0 = min(start.y, end.y)
                let cols = abs(end.x - start.x) + 1
                let rows = abs(end.y - start.y) + 1
                if assignSlot != nil {
                    onAssign(UInt32(start.y * tileset.columns + start.x))
                } else if cols == 1 && rows == 1 {
                    onPickSingle(UInt32(start.y * tileset.columns + start.x))
                } else {
                    onPickRegion(col0, row0, cols, rows)
                }
            }
    }

    private func cell(at point: CGPoint) -> SheetCell? {
        let scale = displayScale
        let strideX = CGFloat(tileset.tileWidth + tileset.spacing) * scale
        let strideY = CGFloat(tileset.tileHeight + tileset.spacing) * scale
        guard strideX > 0, strideY > 0, tileset.columns > 0 else { return nil }
        let col = Int(floor((point.x - CGFloat(tileset.margin) * scale) / strideX))
        let row = Int(floor((point.y - CGFloat(tileset.margin) * scale) / strideY))
        guard col >= 0, row >= 0, col < tileset.columns else { return nil }
        let local = row * tileset.columns + col
        guard local < tileset.tileCount else { return nil }
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

    // MARK: Object inspector

    /// Target for the object properties editor sheet (phase-2 properties UI).
    struct PropsTarget: Identifiable {
        let layer: Int
        let objectID: Int
        var id: Int { objectID }
    }

    @State private var propsObject: PropsTarget?

    private func addObjectOnLayer(_ layerIndex: Int, kind: String) {
        model.snapshotAndRefresh()
        let isPoint = kind == "point"
        let w = isPoint ? 0.0 : Double(model.map.cellWidth * 3)
        let h = isPoint ? 0.0 : Double(model.map.cellHeight * 3)
        let id = model.map.addObject(layer: layerIndex, name: kind == "point" ? "Point" : "Rect",
                                     kind: kind, x: 0, y: 0, w: w, h: h)
        if id > 0 { model.selectedObjectID = Int(id) }
    }

    private func objectInspector(layerIndex: Int) -> some View {
        let objects = model.map.objects(layer: layerIndex)
        return VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(StudioTheme.hairline)

            // Action bar: create objects / edit properties of the selection.
            HStack(spacing: 5) {
                Text("Objects")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                actionChip("Rect", icon: "rectangle.dashed") { addObjectOnLayer(layerIndex, kind: "rect") }
                actionChip("Point", icon: "plus.square") { addObjectOnLayer(layerIndex, kind: "point") }
            }
            .padding(.horizontal, 12)

            if objects.isEmpty {
                Text("Add a Rect or Point below, then drag it on the canvas. Give objects a type & properties for your engine.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(objects, id: \.id) { obj in
                            HStack(spacing: 6) {
                                Button {
                                    model.selectedObjectID = (model.selectedObjectID == obj.id) ? nil : obj.id
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: obj.type == "point" ? "plus" : "rectangle.dashed")
                                            .font(.system(size: 9))
                                        Text(obj.name.isEmpty ? "Object \(obj.id)" : obj.name)
                                            .font(.system(size: 10, weight: .medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(Int(obj.x)),\(Int(obj.y))")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(model.selectedObjectID == obj.id ? StudioTheme.accent.opacity(0.3) : Color.white.opacity(0.05))
                                    )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    propsObject = PropsTarget(layer: layerIndex, objectID: obj.id)
                                } label: {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.6))
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.plain)
                                .help("Object properties (name, type, custom fields)")

                                Button {
                                    model.deleteObject(obj.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.5))
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 120)

                // Selected-object inspector: name / type / geometry.
                if let selected = model.selectedObjectID,
                   let obj = objects.first(where: { $0.id == selected }) {
                    selectedObjectFields(layerIndex: layerIndex, obj: obj)
                }
            }
        }
        .sheet(item: $propsObject) { target in
            MapPropertiesEditor(model: model, target: .object(layer: target.layer, objectID: target.objectID))
                .frame(width: 340, height: 400)
        }
    }

    /// Inline editable fields for the selected object (name, type, x/y/w/h).
    private func selectedObjectFields(layerIndex: Int, obj: MapObjectRow) -> some View {
        SelectedObjectEditor(
            obj: obj,
            onName: { commitName(layerIndex, obj: obj, name: $0) },
            onKind: { commitKind(layerIndex, obj: obj, kind: $0) },
            onGeometry: { x, y, w, h in commitGeometry(layerIndex, obj: obj, x: x, y: y, w: w, h: h) }
        )
        .id(obj.id)
    }

    private func commitName(_ layer: Int, obj: MapObjectRow, name: String) {
        model.snapshotAndRefresh()
        model.map.setObject(layer: layer, objectID: obj.id, name: name, kind: obj.type,
                            x: obj.x, y: obj.y, w: obj.width, h: obj.height)
    }

    private func commitKind(_ layer: Int, obj: MapObjectRow, kind: String) {
        model.snapshotAndRefresh()
        model.map.setObject(layer: layer, objectID: obj.id, name: obj.name, kind: kind,
                            x: obj.x, y: obj.y, w: kind == "point" ? 0 : max(obj.width, 1),
                            h: kind == "point" ? 0 : max(obj.height, 1))
    }

    private func commitGeometry(_ layer: Int, obj: MapObjectRow, x: Double, y: Double, w: Double, h: Double) {
        model.snapshotAndRefresh()
        model.map.setObject(layer: layer, objectID: obj.id, name: obj.name, kind: obj.type,
                            x: x, y: y, w: w, h: h)
    }

    private func actionChip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Selected object editor

/// Name/type/geometry editor for the object currently selected in the panel.
private struct SelectedObjectEditor: View {
    let obj: MapObjectRow
    let onName: (String) -> Void
    let onKind: (String) -> Void
    let onGeometry: (Double, Double, Double, Double) -> Void

    @State private var name = ""
    @State private var x = ""
    @State private var y = ""
    @State private var w = ""
    @State private var h = ""

    private func intText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selected object")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button { onGeometry(parse(x) ?? 0, parse(y) ?? 0, parse(w) ?? 0, parse(h) ?? 0) } label: {
                    Text("Apply")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(StudioTheme.accent)
            }

            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .onSubmit { onName(name) }
                Picker("", selection: kindBinding) {
                    Text("Rect").tag("rect")
                    Text("Point").tag("point")
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }

            if obj.type != "point" {
                HStack(spacing: 6) {
                    field("x", $x)
                    field("y", $y)
                    field("w", $w)
                    field("h", $h)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StudioTheme.panelElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear {
            name = obj.name
            x = intText(obj.x); y = intText(obj.y)
            w = intText(obj.width); h = intText(obj.height)
        }
    }

    private func field(_ label: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9, design: .monospaced))
        }
    }

    private func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private var kindBinding: Binding<String> {
        Binding<String>(
            get: { obj.type == "point" ? "point" : "rect" },
            set: { onKind($0) }
        )
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
