import SwiftUI
import UniformTypeIdentifiers

/// A project contains documents with independent sizes and reusable assets.
struct WorkspaceLibrary: View {
    @ObservedObject var store: ProjectStore
    @State private var showNew = false
    @State private var selected: ProjectAssetFile?
    @State private var selectedData: Data?
    @State private var style = ""
    @State private var search = ""
    @State private var showSources = false
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Project library", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            HStack {
                TextField("Search documents and assets", text: $search).textFieldStyle(.roundedBorder)
                Button { store.refreshAssets() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh project assets")
            }
            HStack {
                Text("Documents").font(.subheadline.bold())
                Spacer()
                Button { showNew = true } label: { Label("New", systemImage: "plus") }.disabled(store.assistant.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.catalog.documents.filter { matches($0.name) }) { item in
                        Button { store.openDocument(item) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.kind.symbol).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.system(size: 12, weight: .medium))
                                    Text("\(item.kind.title) · \(item.summary)").font(.system(size: 10)).foregroundColor(.secondary)
                                }
                                Spacer()
                                if item.id == store.catalog.activeDocumentID { Image(systemName: "checkmark").font(.caption) }
                            }.padding(8).contentShape(Rectangle())
                                .background(item.id == store.catalog.activeDocumentID ? StudioTheme.accent.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(store.assistant.busy)
                    }
                    if store.catalog.documents.isEmpty {
                        Text("Create a sprite, animation, tileset, map, or image. Each has its own dimensions.")
                            .font(.caption).foregroundColor(.secondary).padding(.vertical, 6)
                    }
                }
            }.frame(maxHeight: 190)
            Divider()
            HStack {
                Text("Assets").font(.subheadline.bold())
                Spacer()
                Toggle("Sources", isOn: $showSources).toggleStyle(.checkbox).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(store.assets.filter { matches($0.name) && (showSources || !$0.isSource) }) { asset in
                        Button {
                            selected = asset
                            do { selectedData = try store.assetData(asset) }
                            catch { store.error = error.localizedDescription; selectedData = nil }
                        } label: {
                            HStack {
                                Image(systemName: asset.isImage ? "photo" : "doc.text")
                                Text(asset.name).lineLimit(1)
                                Spacer()
                                if asset.path.hasPrefix("assets/") { Image(systemName: "checkmark.seal") }
                            }.font(.caption).padding(7).contentShape(Rectangle())
                                .background(selected?.id == asset.id ? StudioTheme.accent.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                    if store.assets.isEmpty {
                        Text("Generated images and code appear here. Use the assistant to create your first asset.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }.frame(minHeight: 70, maxHeight: .infinity)
            if let selected, let data = selectedData {
                AssetPreview(asset: selected, data: data, store: store)
                    .id(selected.id)
            }
            DisclosureGroup("Project style") {
                TextField("e.g. top-down woodland, muted palette", text: $style, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                Button("Save style") { store.setStyle(style) }.font(.caption)
            }.font(.caption)
        }
        .padding(14).frame(width: 340)
        .onAppear { style = store.catalog.style; store.refreshAssets() }
        .sheet(isPresented: $showNew) { NewWorkspaceDocument(store: store) }
    }
    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }
}

private struct AssetPreview: View {
    let asset: ProjectAssetFile
    let data: Data
    @ObservedObject var store: ProjectStore
    @State private var tileX = 0
    @State private var tileY = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if asset.isImage, let bitmap = NSBitmapImageRep(data: data), let cg = bitmap.cgImage {
                Image(nsImage: NSImage(cgImage: cg, size: .zero))
                    .resizable().interpolation(.none).scaledToFit().frame(maxWidth: .infinity, maxHeight: 130)
                    .background(StudioTheme.background)
                    .onDrag { imageProvider(data) }
                    .help("Drag onto the canvas to place as a new layer")
                Text("\(cg.width) × \(cg.height) px · Drag to canvas").font(.caption2).foregroundColor(.secondary)
                HStack {
                    Button("Open image") { store.openImageAsset(asset) }.disabled(store.assistant.busy)
                    Button("Add layer") { store.editor.placeAsset(data, name: asset.name) }.disabled(store.activeDocument == nil)
                    Button("Use as reference") {
                        guard store.assistant.attachments.count < 4 else { return }
                        store.assistant.attachments.append(AssistantAttachment(name: asset.name, data: data, text: nil))
                    }.disabled(data.count > 5_000_000 || store.assistant.busy || store.assistant.attachments.count >= 4)
                }.font(.caption2)
                if let document = store.activeDocument, document.kind == .map {
                    HStack {
                        Stepper("Column \(tileX + 1)", value: $tileX, in: 0...max(0, cg.width / document.cellWidth - 1))
                        Stepper("Row \(tileY + 1)", value: $tileY, in: 0...max(0, cg.height / document.cellHeight - 1))
                    }.font(.caption2)
                    Button("Paint with this tile") {
                        let rect = CGRect(x: tileX * document.cellWidth, y: tileY * document.cellHeight,
                                          width: document.cellWidth, height: document.cellHeight)
                        if let tile = cg.cropping(to: rect), let png = NSBitmapImageRep(cgImage: tile).representation(using: .png, properties: [:]) {
                            store.editor.selectTile(png, name: asset.name)
                        }
                    }.font(.caption).disabled(cg.width < document.cellWidth || cg.height < document.cellHeight)
                }
                if let document = store.activeDocument, document.kind == .animation || document.kind == .sprite {
                    Button("Slice into \(store.editor.width) × \(store.editor.height) animation frames") {
                        store.editor.importSheet(data, name: asset.name)
                    }.font(.caption).disabled(cg.width % store.editor.width != 0 || cg.height % store.editor.height != 0)
                }
            } else if let text = String(data: data, encoding: .utf8) {
                ScrollView { Text(String(text.prefix(4000))).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }.frame(height: 100)
            }
            if !asset.path.hasPrefix("assets/") {
                Button("Keep in project assets") { store.acceptAsset(asset) }.font(.caption)
            }
        }.padding(8).background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
    }
}

func imageProvider(_ data: Data) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
        completion(data, nil); return nil
    }
    return provider
}

struct NewWorkspaceDocument: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: AssetKind = .sprite
    @State private var width = 32
    @State private var height = 32
    @State private var cellWidth = 16
    @State private var cellHeight = 16
    private var item: WorkspaceDocument { WorkspaceDocument(name: name, kind: kind, width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New document").font(.title2.bold())
            Text("Choose dimensions for this asset. Other documents in your project can use different sizes.").foregroundColor(.secondary)
            TextField("Document name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Asset type", selection: $kind) {
                ForEach(AssetKind.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                dimension(kind.usesCells ? "Columns" : "Width (px)", value: $width)
                dimension(kind.usesCells ? "Rows" : "Height (px)", value: $height)
            }
            if kind.usesCells {
                HStack { dimension("Cell width (px)", value: $cellWidth); dimension("Cell height (px)", value: $cellHeight) }
            }
            Text("\(item.pixelWidth) × \(item.pixelHeight) pixels total").font(.caption).foregroundColor(.secondary)
            if kind == .map { Text("Paint tiles on layers. The canvas snaps placed assets to the cell grid.").font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create document") {
                    let before = store.catalog.documents.count
                    store.createDocument(item)
                    if store.catalog.documents.count > before { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(item.validationError != nil || store.assistant.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 480)
        .onChange(of: kind) { value in
            width = value == .map ? 40 : value.usesCells ? 4 : 32
            height = value == .map ? 25 : value.usesCells ? 4 : 32
        }
    }
    private func dimension(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder) }
    }
}
