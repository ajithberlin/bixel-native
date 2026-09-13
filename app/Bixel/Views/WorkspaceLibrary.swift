import SwiftUI
import UniformTypeIdentifiers

/// Project asset rail: a thumbnail grid of the project's images that can be
/// dragged onto the canvas. Kept intentionally simple — a compact document
/// switcher plus the image grid. Files/documents and style live elsewhere.
struct ProjectAssetsPanel: View {
    @ObservedObject var store: ProjectStore
    @State private var showNew = false
    @State private var selected: ProjectAssetFile?
    @State private var selectedData: Data?
    @State private var search = ""

    private var imageAssets: [ProjectAssetFile] {
        store.assets
            .filter { $0.isImage && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider().overlay(StudioTheme.hairline)

            ScrollView {
                if imageAssets.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(imageAssets) { asset in
                            AssetTile(asset: asset, store: store, selected: selected?.id == asset.id) {
                                select(asset)
                            }
                        }
                    }
                    .padding(12)
                }
            }

            if let selected, let data = selectedData {
                Divider().overlay(StudioTheme.hairline)
                AssetPreview(asset: selected, data: data, store: store)
            }
        }
        .frame(width: 292)
        .frame(maxHeight: .infinity)
        .background(StudioTheme.panel)
        .onAppear { store.refreshAssets() }
        .onChange(of: store.current?.id) { _ in
            selected = nil
            selectedData = nil
            store.refreshAssets()
        }
        .sheet(isPresented: $showNew) { NewWorkspaceDocument(store: store) }
    }

    // MARK: Header + document switcher

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StudioTheme.accent.opacity(0.18))
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(StudioTheme.accent)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assets")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(store.current?.name ?? "Open a project")
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { store.refreshAssets() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            documentSwitcher
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var documentSwitcher: some View {
        if !store.catalog.documents.isEmpty {
            Menu {
                ForEach(store.catalog.documents) { item in
                    Button {
                        store.openDocument(item)
                    } label: {
                        if item.id == store.catalog.activeDocumentID {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
                Divider()
                Button { showNew = true } label: { Label("New document…", systemImage: "plus") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.activeDocument?.mode.symbol ?? "doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(StudioTheme.accent)
                    Text(store.activeDocument?.name ?? "Select document")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(StudioTheme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StudioTheme.hairline, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .disabled(store.assistant.busy)
            .help("Switch the active document")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(StudioTheme.textDisabled)
            TextField("Search images", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(StudioTheme.textDisabled)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(StudioTheme.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 22))
                .foregroundColor(StudioTheme.textDisabled)
            Text(store.assets.isEmpty
                 ? "No images yet. Generate art with the AI assistant, or import a project."
                 : "No images match your search.")
                .font(.caption)
                .foregroundColor(StudioTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private func select(_ asset: ProjectAssetFile) {
        selected = asset
        selectedData = nil
        Task { @MainActor in
            do {
                let data = try await store.assetDataAsync(asset)
                guard selected?.id == asset.id else { return }
                selectedData = data
            } catch {
                guard selected?.id == asset.id else { return }
                store.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Asset tile (thumbnail grid cell, draggable)

private struct AssetTile: View {
    let asset: ProjectAssetFile
    @ObservedObject var store: ProjectStore
    let selected: Bool
    let onSelect: () -> Void
    @State private var previewData: Data?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(StudioTheme.background)
                    if let previewData, let image = makePlatformImage(data: previewData) {
                        Image(platformImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(3)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(StudioTheme.textDisabled)
                    }
                }
                .frame(height: 66)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? StudioTheme.accent : StudioTheme.hairline, lineWidth: selected ? 1.5 : 1)
                )
                Text(asset.name)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Drag onto the canvas · \(asset.bytes / 1024) KB")
        .task(id: asset.id) {
            previewData = try? await store.assetDataAsync(asset)
        }
        .onDrag {
            if let previewData { return imageProvider(previewData) }
            if let data = try? store.assetData(asset) { return imageProvider(data) }
            return NSItemProvider()
        }
    }
}

// MARK: - Selected asset preview + actions

private struct AssetPreview: View {
    let asset: ProjectAssetFile
    let data: Data
    @ObservedObject var store: ProjectStore

    private var isMap: Bool { store.isMapActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let image = makePlatformImage(data: data), let cg = image.cgImageRef {
                    Image(platformImage: image)
                        .resizable().interpolation(.none).scaledToFit()
                        .frame(width: 52, height: 52)
                        .background(StudioTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("\(cg.width) × \(cg.height) px")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { store.acceptAsset(asset) } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Keep in project assets")
            }

            if isMap {
                HStack(spacing: 6) {
                    Button {
                        store.placeImageOnMap(asset)
                    } label: {
                        Label("Add as layer", systemImage: "photo.badge.plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Add this image to the map as a layer")

                    Button {
                        store.addTilesetFromAsset(asset)
                    } label: {
                        Label("Add as tileset", systemImage: "square.grid.3x3")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Slice this image into a tileset you can paint with")
                }
                .controlSize(.small)
                .disabled(store.assistant.busy)
                Text("Add as an image layer, or slice it into a paintable tileset.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 6) {
                    Button("Add layer") { store.editor.placeAsset(data, name: asset.name) }
                        .disabled(store.activeDocument == nil)
                        .help("Place this image on the canvas as a new layer")
                    Button("Open image") { store.openImageAsset(asset) }
                        .disabled(store.assistant.busy)
                        .help("Open this image as a new document")
                }
                .font(.system(size: 11))
                .controlSize(.small)
            }
        }
        .padding(12)
    }
}

func imageProvider(_ data: Data) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

struct NewWorkspaceDocument: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var mode: WorkspaceMode = .normal
    @State private var width = 32
    @State private var height = 32
    @State private var cellWidth = 16
    @State private var cellHeight = 16
    @State private var orientation: MapOrientation = .orthogonal
    private var item: WorkspaceDocument {
        if mode == .map {
            return WorkspaceDocument(name: name, mode: .map, width: 0, height: 0,
                                     cellWidth: cellWidth, cellHeight: cellHeight,
                                     infinite: true, orientation: orientation.tiled)
        }
        return WorkspaceDocument(name: name, mode: .normal, width: width, height: height)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New document").font(.title2.bold())
            Text("Choose dimensions for this asset. Other documents in your project can use different sizes.").foregroundColor(.secondary)
            TextField("Document name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Project type", selection: $mode) {
                ForEach(WorkspaceMode.allCases) { Text($0.title).tag($0) }
            }
            .help("Normal canvas or scene document")
            if mode.usesCells {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scene type").font(.caption)
                    Picker("", selection: $orientation) {
                        ForEach(MapOrientation.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                HStack { dimension("Tile width (px)", value: $cellWidth); dimension("Tile height (px)", value: $cellHeight) }
                Text("Infinite scene — pan and paint anywhere. Saved as Tiled infinite JSON with chunks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    dimension("Width (px)", value: $width)
                    dimension("Height (px)", value: $height)
                }
                Text("\(item.pixelWidth) × \(item.pixelHeight) pixels total").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Cancel creating the document")
                Button("Create document") {
                    let before = store.catalog.documents.count
                    store.createDocument(item)
                    if store.catalog.documents.count > before { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(item.validationError != nil || store.assistant.busy).keyboardShortcut(.defaultAction)
                    .help("Create this document")
            }
        }.padding(26).frame(width: 480)
        .onChange(of: mode) { value in
            if value == .normal {
                width = 32
                height = 32
            }
        }
    }
    private func dimension(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder) }
    }
}

struct EditorOperationFeedback: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Group {
            Color.clear.frame(height: 1)
        }
        .alert("Asset could not be applied", isPresented: Binding(get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } })) {
            Button("OK") { model.operationError = nil }
        } message: { Text(model.operationError ?? "") }
    }
}
