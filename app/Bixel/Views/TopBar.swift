// TopBar.swift
//
// Procreate-style top navigation bar shared by the sprite editor and the
// Tilemap Designer:
// - Left group: Gallery, Actions (wrench), Selection (lasso), Transform (arrow)
// - For maps the right group becomes the map tool cluster (stamp/eraser/fill/
//   rect/line/select/pick/wand) plus layers + tileset toggles.
// - ActionsPopover gains Tiled JSON / CSV / PNG export rows for maps.

import SwiftUI

struct TopBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport
    let projectName: String
    let onShowProjects: () -> Void
    var onGoHome: (() -> Void)? = nil
    @Binding var showLayers: Bool
    @Binding var showColor: Bool
    @Binding var showAI: Bool
    @Binding var showTimeline: Bool
    @Binding var showAssets: Bool
    var onNewDocument: (() -> Void)? = nil
    /// Non-nil when the active document is a `.map` opened in the designer.
    var mapModel: TileMapModel? = nil
    var onImportTiledMap: (() -> Void)? = nil

    @State private var showActions = false

    private var isMap: Bool { mapModel != nil }

    var body: some View {
        HStack {
            leftCluster
            Spacer()
            centerTitle
            Spacer()
            if isMap, let mapModel { mapRightCluster(mapModel) } else { spriteRightCluster }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(StudioTheme.procreateGlass))
                .overlay(
                    Rectangle()
                        .fill(StudioTheme.hairline)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: Left cluster

    private var leftCluster: some View {
        HStack(spacing: 14) {
            Button {
                if let onGoHome { onGoHome() } else { onShowProjects() }
            } label: {
                HStack(spacing: 6) {
                    BixelSlimeLogo(size: 18)
                    Text("Home")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help("Return to Bixel Home Gallery")

            // Actions (Wrench)
            Button {
                showActions.toggle()
            } label: {
                Image(systemName: "wrench")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(showActions ? StudioTheme.accent : Color.white.opacity(0.85))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Actions & canvas settings")
            .popover(isPresented: $showActions, arrowEdge: .bottom) {
                ActionsPopover(
                    model: model,
                    viewport: viewport,
                    showTimeline: $showTimeline,
                    onShowProjects: onShowProjects,
                    onNewDocument: onNewDocument,
                    mapModel: mapModel,
                    onImportTiledMap: onImportTiledMap
                )
            }

            if !isMap {
                // Selection (Lasso)
                Button {
                    model.selectTool((model.tool == .selection) ? .pencil : .selection)
                } label: {
                    Image(systemName: "lasso")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(model.tool == .selection ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Selection tool")

                // Transform
                Button {
                    model.selectTool((model.tool == .transform) ? .pencil : .transform)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(model.tool == .transform ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Transform tool")
            }
        }
    }

    // MARK: Center

    private var centerTitle: some View {
        HStack(spacing: 8) {
            Text(projectName)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            if let mapModel {
                Text("\(mapModel.map.columns) × \(mapModel.map.rows) cells")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.white.opacity(0.06))
                    )
            } else {
                Text("\(model.width) × \(model.height)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.white.opacity(0.06))
                    )
            }
        }
    }

    // MARK: Sprite right cluster (brush/smudge/eraser/layers/color)

    private var spriteRightCluster: some View {
        HStack(spacing: 16) {
            Button { model.selectTool(.pencil) } label: {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(model.tool == .pencil ? StudioTheme.accent : Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Paint brush")

            Button { model.selectTool(.smudge) } label: {
                Image(systemName: "hand.draw")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(model.tool == .smudge ? StudioTheme.accent : Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Smudge tool")

            Button { model.selectTool(.eraser) } label: {
                Image(systemName: "eraser")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(model.tool == .eraser ? StudioTheme.accent : Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Eraser")

            layersToggle
            colorToggle(isSpriteColor: true)
            animationAssistToggle
            assetLibraryToggle
            AICopilotButton(isPresented: showAI) {
                withAnimation(.easeInOut(duration: 0.2)) { showAI.toggle() }
            }
        }
    }

    // MARK: Map right cluster (tool palette)

    private func mapRightCluster(_ mapModel: TileMapModel) -> some View {
        HStack(spacing: 10) {
            mapTool(mapModel, .stamp, "paintbrush.pointed", "Stamp (P)")
            mapTool(mapModel, .eraser, "eraser", "Eraser (E)")
            mapTool(mapModel, .bucket, "drop.fill", "Fill (G)")
            mapTool(mapModel, .rectFill, "rectangle", "Rectangle fill (F)")
            mapTool(mapModel, .line, "line.diagonal", "Line (L)")
            mapTool(mapModel, .select, "lasso", "Select (V)")
            mapTool(mapModel, .tilePicker, "eyedropper", "Pick tile (I)")
            mapTool(mapModel, .wand, "wand.and.rays", "Magic wand (W)")

            Divider().frame(height: 20).overlay(StudioTheme.hairlineStrong)

            layersToggle
            assetLibraryToggle
            AICopilotButton(isPresented: showAI) {
                withAnimation(.easeInOut(duration: 0.2)) { showAI.toggle() }
            }
        }
    }

    private func mapTool(_ mapModel: TileMapModel, _ tool: MapTool, _ symbol: String, _ help: String) -> some View {
        Button {
            mapModel.tool = tool
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(mapModel.tool == tool ? StudioTheme.accent : Color.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(
                    mapModel.tool == tool ? RoundedRectangle(cornerRadius: 6).fill(StudioTheme.accentSoft) : nil
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var layersToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showLayers.toggle()
                if showLayers { showColor = false }
            }
        } label: {
            Image(systemName: "square.2.layers.3d")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(showLayers ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(
                    showLayers ? RoundedRectangle(cornerRadius: 6).fill(StudioTheme.accentSoft) : nil
                )
        }
        .buttonStyle(.plain)
        .help("Layers panel")
    }

    private var assetLibraryToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showAssets.toggle()
            }
        } label: {
            Image(systemName: "shippingbox")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(showAssets ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(
                    showAssets ? RoundedRectangle(cornerRadius: 6).fill(StudioTheme.accentSoft) : nil
                )
        }
        .buttonStyle(.plain)
        .help("Project assets")
        .accessibilityLabel(showAssets ? "Hide project assets" : "Show project assets")
    }

    private var animationAssistToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showTimeline.toggle()
            }
        } label: {
            Image(systemName: "film.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(showTimeline ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(
                    showTimeline ? RoundedRectangle(cornerRadius: 6).fill(StudioTheme.accentSoft) : nil
                )
        }
        .buttonStyle(.plain)
        .help("Animation Assist")
        .accessibilityLabel(showTimeline ? "Hide Animation Assist" : "Show Animation Assist")
    }

    @ViewBuilder
    private func colorToggle(isSpriteColor: Bool) -> some View {
        if isSpriteColor {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showColor.toggle()
                    if showColor { showLayers = false }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(currentColor)
                        .frame(width: 24, height: 24)
                    Circle()
                        .strokeBorder(showColor ? StudioTheme.procreateBlue : Color.white.opacity(0.35), lineWidth: showColor ? 2.5 : 1)
                        .frame(width: 26, height: 26)
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Colors")
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showColor.toggle()
                    if showColor { showLayers = false }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(showColor ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(
                        showColor ? RoundedRectangle(cornerRadius: 6).fill(StudioTheme.accentSoft) : nil
                    )
            }
            .buttonStyle(.plain)
            .help("Tileset palette")
        }
    }

    private var currentColor: Color {
        Color(
            red: Double(model.currentColor.r) / 255,
            green: Double(model.currentColor.g) / 255,
            blue: Double(model.currentColor.b) / 255
        )
    }
}

/// The AI entry point is deliberately placed after the color/tileset control:
/// it reads as the final creative tool in the top bar and remains discoverable
/// when the assistant panel is closed.
private struct AICopilotButton: View {
    let isPresented: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill((isPresented ? StudioTheme.bixelGreen : StudioTheme.procreateBlue)
                        .opacity(pulse ? 0.25 : 0.12))
                    .frame(width: 31, height: 31)
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [StudioTheme.procreateBlue, StudioTheme.bixelGreen, StudioTheme.procreateBlue],
                            center: .center
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 29, height: 29)
                    .rotationEffect(.degrees(reduceMotion ? 0 : (pulse ? 180 : 0)))
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isPresented ? StudioTheme.bixelGreen : .white)
                    .scaleEffect(reduceMotion ? 1 : (pulse ? 1.08 : 0.94))
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .help("AI Copilot & Adjustments")
        .accessibilityLabel(isPresented ? "Hide AI Copilot" : "Show AI Copilot")
        .onAppear { startAnimationIfNeeded() }
        .onChange(of: reduceMotion) { _ in startAnimationIfNeeded() }
    }

    private func startAnimationIfNeeded() {
        guard !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Actions Popover (Wrench menu)

struct ActionsPopover: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport
    @Binding var showTimeline: Bool
    let onShowProjects: () -> Void
    var onNewDocument: (() -> Void)?
    var mapModel: TileMapModel? = nil
    var onImportTiledMap: (() -> Void)? = nil

    @State private var tab: ActionTab = .canvas

    enum ActionTab: String, CaseIterable {
        case canvas = "Canvas"
        case share = "Share"
        case project = "Project"
    }

    private var isMap: Bool { mapModel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(ActionTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Divider().overlay(StudioTheme.hairline)

            switch tab {
            case .canvas:
                canvasTab
            case .share:
                shareTab
            case .project:
                projectTab
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    private var canvasTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isMap {
                Toggle(isOn: $showTimeline) {
                    Label("Animation Assist", systemImage: "film")
                }
                .toggleStyle(.switch)
            }

            Toggle(isOn: $viewport.showGrid) {
                Label(isMap ? "Cell Grid" : "Drawing Guide / Grid", systemImage: "grid")
            }
            .toggleStyle(.switch)

            if !isMap {
                Toggle(isOn: $viewport.onionSkin) {
                    Label("Onion Skin", systemImage: "circle.dashed.inset.filled")
                }
                .toggleStyle(.switch)

                if viewport.onionSkin {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Ghost Opacity")
                                .font(.caption)
                                .foregroundColor(StudioTheme.textSecondary)
                            Spacer()
                            Text("\(Int((viewport.onionOpacity * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $viewport.onionOpacity, in: 0.1...0.8)
                            .controlSize(.mini)
                    }
                    .padding(.leading, 8)
                }
            }

            Divider().overlay(StudioTheme.hairline)

            if let mapModel {
                // Canvas / map resize + zoom controls
                HStack {
                    Label("Map Size", systemImage: "aspectratio")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(mapModel.width) × \(mapModel.height)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                Button {
                    post(.studioMapResize)
                } label: {
                    Label("Resize Map…", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Label("Canvas Size", systemImage: "aspectratio")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(model.width) × \(model.height)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                }
            }

            // Zoom controls
            HStack(spacing: 8) {
                Button { viewport.zoomOut() } label: { Label("Zoom -", systemImage: "minus.magnifyingglass") }
                    .controlSize(.small)
                Button {
                    if let mapModel {
                        viewport.zoomToFitCurrent(canvasWidth: mapModel.map.pixelWidth, height: mapModel.map.pixelHeight)
                    } else {
                        viewport.zoomToFitCurrent(canvasWidth: model.width, height: model.height)
                    }
                } label: {
                    Text("\(Int((viewport.zoom * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                }
                .controlSize(.small)
                Button { viewport.zoomIn() } label: { Label("Zoom +", systemImage: "plus.magnifyingglass") }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var shareTab: some View {
        if isMap, let mapModel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export Map")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(StudioTheme.textSecondary)

                Button {
                    mapModel.exportTiledJSON()
                } label: {
                    Label("Tiled JSON (map + tilesets)…", systemImage: "square.grid.3x2")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                Button {
                    mapModel.exportCSV()
                } label: {
                    Label("CSV (one file per tile layer)…", systemImage: "tablecells")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                Button {
                    mapModel.exportPNG(scale: 4)
                } label: {
                    Label("PNG (4× composite)…", systemImage: "photo")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                if let onImportTiledMap {
                    Divider().overlay(StudioTheme.hairline)
                    Button {
                        onImportTiledMap()
                    } label: {
                        Label("Import Tiled Map…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Share Image")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(StudioTheme.textSecondary)

                ForEach([1, 2, 4, 8], id: \.self) { scale in
                    Button {
                        model.exportPNG(scale: scale)
                    } label: {
                        HStack {
                            Label("PNG (\(scale)×)", systemImage: "photo")
                            Spacer()
                            Text("\(model.width * scale) × \(model.height * scale)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(StudioTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }

                Divider().overlay(StudioTheme.hairline)

                Button {
                    model.exportSpriteSheet()
                } label: {
                    Label("Animated Sprite Sheet…", systemImage: "square.grid.3x2")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
    }

    private var projectTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onNew = onNewDocument {
                Button {
                    onNew()
                } label: {
                    Label("New Document…", systemImage: "plus.square")
                }
                .buttonStyle(.plain)
            }

            Button {
                onShowProjects()
            } label: {
                Label("Project Gallery", systemImage: "square.grid.3x3")
            }
            .buttonStyle(.plain)

            Divider().overlay(StudioTheme.hairline)

            Button {
                post(.studioUnlockLifetime)
            } label: {
                Label("Unlock Lifetime Ad-Free…", systemImage: "crown")
            }
            .buttonStyle(.plain)

            Button {
                post(.studioCustomerCenter)
            } label: {
                Label("Manage Purchases…", systemImage: "person.crop.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

// MARK: - Map resize dialog

struct MapResizeDialog {
    let model: TileMapModel

    func show() {
        let alert = NSAlert()
        alert.messageText = "Resize Map"
        alert.informativeText = "Re-grids every tile layer, anchored to the top-left."
        let widthField = NSTextField(string: "\(model.width)")
        widthField.placeholderString = "Columns"
        let heightField = NSTextField(string: "\(model.height)")
        heightField.placeholderString = "Rows"
        let stack = NSStackView(views: [widthField, heightField])
        stack.orientation = .horizontal
        stack.spacing = 8
        alert.accessoryView = stack
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let w = Int(widthField.stringValue) ?? model.width
            let h = Int(heightField.stringValue) ?? model.height
            model.resize(width: max(1, w), height: max(1, h))
        }
    }
}
