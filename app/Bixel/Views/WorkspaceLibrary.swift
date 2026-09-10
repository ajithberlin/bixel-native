import SwiftUI
import UniformTypeIdentifiers

/// Always-visible project asset rail. It is intentionally independent from the
/// AI pane so the project stays browsable while the assistant is open.
struct ProjectAssetsPanel: View {
    @ObservedObject var store: ProjectStore
    @State private var showNew = false
    @State private var selected: ProjectAssetFile?
    @State private var selectedData: Data?
    @State private var style = ""
    @State private var search = ""
    @State private var filter: AssetFilter = .all
    @State private var showSources = false

    private enum AssetFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case images = "Images"
        case files = "Files"
        var id: String { rawValue }
    }

    private var visibleAssets: [ProjectAssetFile] {
        store.assets.filter { asset in
            guard matches(asset.name), (showSources || !asset.isSource) else { return false }
            switch filter {
            case .all: return true
            case .images: return asset.isImage
            case .files: return !asset.isImage
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StudioTheme.accent.opacity(0.18))
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(StudioTheme.accent)
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Project Assets")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(store.current?.name ?? "Open a project")
                            .font(.system(size: 10))
                            .foregroundColor(StudioTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(store.assets.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                    Button { store.refreshAssets() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh project assets")
                }

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(StudioTheme.textDisabled)
                    TextField("Search assets and documents", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundColor(StudioTheme.textDisabled)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(StudioTheme.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Picker("Asset filter", selection: $filter) {
                    ForEach(AssetFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().overlay(StudioTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("DOCUMENTS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(StudioTheme.textSecondary)
                        Spacer()
                        Button { showNew = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("New document")
                        .disabled(store.assistant.busy)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.catalog.documents.filter { matches($0.name) }) { item in
                            Button { store.openDocument(item) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: item.kind.symbol)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(item.id == store.catalog.activeDocumentID ? StudioTheme.accent : StudioTheme.textSecondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Text("\(item.kind.title) · \(item.summary)")
                                            .font(.system(size: 9))
                                            .foregroundColor(StudioTheme.textDisabled)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    if item.id == store.catalog.activeDocumentID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(StudioTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .background(item.id == store.catalog.activeDocumentID ? StudioTheme.accent.opacity(0.13) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(store.assistant.busy)
                        }
                        if store.catalog.documents.isEmpty {
                            Text("Create a sprite, animation, tileset, map, or image.")
                                .font(.caption)
                                .foregroundColor(StudioTheme.textSecondary)
                                .padding(.vertical, 4)
                        }
                    }

                    Divider().overlay(StudioTheme.hairline)

                    HStack(alignment: .firstTextBaseline) {
                        Text("ASSETS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(StudioTheme.textSecondary)
                        Spacer()
                        HStack(spacing: 8) {
                            Toggle("Sources", isOn: $showSources)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 9))
                            Text("Drag image → canvas")
                                .font(.system(size: 9))
                                .foregroundColor(StudioTheme.textDisabled)
                        }
                    }

                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(visibleAssets) { asset in
                            ProjectAssetRow(
                                asset: asset,
                                store: store,
                                selected: selected?.id == asset.id,
                                onSelect: {
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
                            )
                        }
                        if visibleAssets.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Image(systemName: filter == .images ? "photo.on.rectangle.angled" : "tray")
                                    .font(.system(size: 18))
                                    .foregroundColor(StudioTheme.textDisabled)
                                Text(store.assets.isEmpty ? "Generated images and files will appear here." : "No assets match this filter.")
                                    .font(.caption)
                                    .foregroundColor(StudioTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                        }
                    }

                    if let selected, let data = selectedData {
                        AssetPreview(asset: selected, data: data, store: store)
                            .id(selected.id)
                    }

                    DisclosureGroup("Project style") {
                        TextField("e.g. top-down woodland, muted palette", text: $style, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        Button("Save style") { store.setStyle(style) }
                            .font(.caption)
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 292)
        .frame(maxHeight: .infinity)
        .background(StudioTheme.panel)
        .onAppear { style = store.catalog.style; store.refreshAssets() }
        .onChange(of: store.current?.id) { _ in
            selected = nil
            selectedData = nil
            style = store.catalog.style
            store.refreshAssets()
        }
        .sheet(isPresented: $showNew) { NewWorkspaceDocument(store: store) }
    }

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }
}

private struct ProjectAssetRow: View {
    let asset: ProjectAssetFile
    @ObservedObject var store: ProjectStore
    let selected: Bool
    let onSelect: () -> Void
    @State private var previewData: Data?

    var body: some View {
        rowContent
            .task(id: asset.id) {
                guard asset.isImage else { return }
                let data = try? await store.assetDataAsync(asset)
                guard !Task.isCancelled else { return }
                previewData = data
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        let row = HStack(spacing: 9) {
            assetThumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(asset.locationLabel)
                    if asset.isImage { Text("IMAGE") }
                }
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundColor(asset.isGenerated ? StudioTheme.bixelGreen : StudioTheme.textDisabled)
            }
            Spacer(minLength: 4)
            if asset.isImage {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(StudioTheme.textDisabled)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? StudioTheme.accent.opacity(0.16) : Color.white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: onSelect)

        if asset.isImage, let data = previewData {
            row.onDrag { imageProvider(data) }
        } else {
            row
        }
    }

    private var assetThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(StudioTheme.background)
            if let previewData, let image = NSImage(data: previewData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: asset.isImage ? "photo" : "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(StudioTheme.textDisabled)
            }
        }
        .frame(width: 38, height: 38)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(StudioTheme.hairline, lineWidth: 1))
    }

}

private struct AssetPreview: View {
    let asset: ProjectAssetFile
    let data: Data
    @ObservedObject var store: ProjectStore
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
                    Button("Add layer") { store.editor.placeAsset(data, name: asset.name) }.disabled(store.activeDocument == nil || store.isMapActive)
                    Button("Use as reference") {
                        guard store.assistant.attachments.count < 4 else { return }
                        store.assistant.attachments.append(AssistantAttachment(name: asset.name, data: data, text: nil))
                    }.disabled(data.count > 5_000_000 || store.assistant.busy || store.assistant.attachments.count >= 4)
                }.font(.caption2)
                if let document = store.activeDocument, document.kind == .sprite || document.kind == .animation {
                    Button("Slice into \(store.editor.width) × \(store.editor.height) animation frames") {
                        store.editor.importSheet(data, name: asset.name)
                    }.font(.caption).disabled(cg.width % store.editor.width != 0 || cg.height % store.editor.height != 0)
                }
            } else if let text = String(data: data, encoding: .utf8) {
                ScrollView { Text(String(text.prefix(4000))).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }.frame(height: 100)
            }
            if asset.isCached {
                Button("Keep in project assets") { store.acceptAsset(asset) }.font(.caption)
            }
        }.padding(8).background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
    }
}

func imageProvider(_ data: Data) -> NSItemProvider {
    let provider = NSItemProvider()
    let pngData: Data = {
        guard let bitmap = NSBitmapImageRep(data: data),
              let converted = bitmap.representation(using: .png, properties: [:]) else { return data }
        return converted
    }()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
        completion(pngData, nil); return nil
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
