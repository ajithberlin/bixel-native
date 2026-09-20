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
    var onShowHelp: (() -> Void)? = nil
    /// Non-nil when the active document is a `.map` opened in the designer.
    var mapModel: TileMapModel? = nil
    var onImportTiledMap: (() -> Void)? = nil

    @State private var showActions = false
    @State private var showSelectPopover = false
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    #if os(iOS)
    /// Observing the client lets the AI entry point appear on iPad once a Mac
    /// is connected (the assistant runs on the Mac).
    @ObservedObject private var remote = RemoteClient.shared
    #endif

    private var isMap: Bool { mapModel != nil }

    /// The agentic assistant is always available on macOS; on iPad it requires a
    /// connected Mac.
    private var assistantAvailable: Bool {
        #if os(macOS)
        return true
        #else
        return remote.state.isConnected
        #endif
    }

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
            .toolHoverEffect(
                name: "Home Gallery",
                details: "Return to Bixel project gallery and home dashboard",
                cornerRadius: 6
            )

            // Actions (Wrench)
            ToolHoverButton(
                isSelected: showActions,
                selectedColor: StudioTheme.accent,
                tooltipName: "Actions & Canvas Settings",
                tooltipDescription: "Canvas sizing, grid guide, onion skin, zoom, and export commands",
                width: 28,
                height: 28,
                action: {
                    showActions.toggle()
                    if showActions {
                        showLayers = false
                        showColor = false
                        showAI = false
                    }
                }
            ) { isSel, _ in
                Image(systemName: "wrench")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))
            }
            .popover(isPresented: $showActions, arrowEdge: .bottom) {
                ActionsPopover(
                    model: model,
                    viewport: viewport,
                    showTimeline: $showTimeline,
                    onShowProjects: onShowProjects,
                    onNewDocument: onNewDocument,
                    mapModel: mapModel,
                    onImportTiledMap: onImportTiledMap,
                    onShowHelp: onShowHelp
                )
            }

            if !isMap {
                // Selection (Lasso)
                ToolHoverButton(
                    isSelected: model.tool == .selection,
                    selectedColor: StudioTheme.accent,
                    tooltipName: "Selection Tool",
                    shortcut: "V",
                    tooltipDescription: "Select pixel regions freehand or rectangularly to edit, move, or transform",
                    width: 28,
                    height: 28,
                    action: {
                        showLayers = false
                        showColor = false
                        model.selectTool((model.tool == .selection) ? .pencil : .selection)
                    }
                ) { isSel, _ in
                    Image(systemName: "lasso")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))
                }

                // Transform
                ToolHoverButton(
                    isSelected: model.tool == .transform,
                    selectedColor: StudioTheme.accent,
                    tooltipName: "Transform Tool",
                    shortcut: "T",
                    tooltipDescription: "Move, scale, stretch, flip, and rotate the active selection or layer",
                    width: 28,
                    height: 28,
                    action: {
                        showLayers = false
                        showColor = false
                        model.selectTool((model.tool == .transform) ? .pencil : .transform)
                    }
                ) { isSel, _ in
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))
                }
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

    // MARK: Sprite right cluster (brush/smudge/eraser/layers/color/timeline/assets/ai/help)

    private var spriteRightCluster: some View {
        HStack(spacing: 14) {
            ToolHoverButton(
                isSelected: model.tool == .pencil,
                selectedColor: StudioTheme.accent,
                tooltipName: "Paint Brush (Pencil)",
                shortcut: "B",
                tooltipDescription: "Draw individual pixels or strokes with current palette color and brush size",
                width: 28,
                height: 28,
                action: {
                    showLayers = false
                    showColor = false
                    model.selectTool(.pencil)
                }
            ) { isSel, _ in
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))
            }

            ToolHoverButton(
                isSelected: model.tool == .smudge,
                selectedColor: StudioTheme.accent,
                tooltipName: "Smudge Tool",
                shortcut: "S",
                tooltipDescription: "Blend and smear adjacent pixels together with smooth organic texture",
                width: 28,
                height: 28,
                action: {
                    showLayers = false
                    showColor = false
                    model.selectTool(.smudge)
                }
            ) { isSel, _ in
                Image(systemName: "hand.draw")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))
            }

            ToolHoverButton(
                isSelected: model.tool == .eraser,
                selectedColor: StudioTheme.accent,
                tooltipName: "Eraser Tool",
                shortcut: "E",
                tooltipDescription: "Erase pixels on the active layer back to transparency",
                width: 28,
                height: 28,
                action: {
                    showLayers = false
                    showColor = false
                    model.selectTool(.eraser)
                }
            ) { isSel, _ in
                Image(systemName: "eraser")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))
            }

            layersToggle
            colorToggle(isSpriteColor: true)
            animationAssistToggle
            assetLibraryToggle
            // Always on macOS; on iPad once a Mac is connected.
            if assistantAvailable {
                AICopilotButton(isPresented: showAI) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAI.toggle()
                        if showAI {
                            showLayers = false
                            showColor = false
                            showAssets = false
                            showActions = false
                        }
                    }
                }
            }
            helpButton
        }
    }

    // MARK: Map right cluster (tool palette)

    private func mapRightCluster(_ mapModel: TileMapModel) -> some View {
        HStack(spacing: 8) {
            ForEach(MapTool.toolbar) { tool in
                mapTool(mapModel, tool, tool.symbol)
            }

            Divider().frame(height: 20).overlay(StudioTheme.hairlineStrong)

            layersToggle
            assetLibraryToggle
            // Always on macOS; on iPad once a Mac is connected.
            if assistantAvailable {
                AICopilotButton(isPresented: showAI) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAI.toggle()
                        if showAI {
                            showLayers = false
                            showColor = false
                            showAssets = false
                            showActions = false
                        }
                    }
                }
            }
            helpButton
        }
    }

    private func shortcut(for tool: MapTool) -> String {
        switch tool {
        case .stamp: return "P"
        case .terrain: return "T"
        case .eraser: return "E"
        case .bucket: return "G"
        case .rectFill: return "F"
        case .line: return "L"
        case .select: return "V"
        case .move: return "M"
        case .tilePicker: return "I"
        case .wand: return "W"
        }
    }

    private func mapToolDescription(for tool: MapTool) -> String {
        switch tool {
        case .stamp: return "Place active tile or tile pattern onto the current tilemap layer"
        case .terrain: return "Paint autotile terrain with automatic corner and border transitions"
        case .eraser: return "Erase tiles on the active map layer"
        case .bucket: return "Flood-fill contiguous matching tiles with the selected tile brush"
        case .rectFill: return "Drag to fill a rectangular area with the selected tile pattern"
        case .line: return "Draw a straight line of tiles between two points"
        case .select: return "Select a region of tiles to copy, stamp, or manipulate"
        case .move: return "Drag selected tiles to reposition them, or drag empty space to pan"
        case .tilePicker: return "Sample an existing tile from the map into your brush"
        case .wand: return "Select all matching adjacent tiles"
        }
    }

    @ViewBuilder
    private func mapTool(_ mapModel: TileMapModel, _ tool: MapTool, _ symbol: String) -> some View {
        if tool == .select {
            ToolHoverButton(
                isSelected: mapModel.tool == .select,
                selectedColor: StudioTheme.accent,
                tooltipName: "Select Tool",
                shortcut: shortcut(for: tool),
                tooltipDescription: "Select tiles with Replace, Add, Subtract, Intersect modes. Click to open options.",
                width: 26,
                height: 26,
                action: {
                    showLayers = false
                    showColor = false
                    if mapModel.tool == .select {
                        showSelectPopover.toggle()
                    } else {
                        mapModel.tool = .select
                        showSelectPopover = true
                    }
                }
            ) { isSel, _ in
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: mapModel.selectionMode == .replace ? symbol : mapModel.selectionMode.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))

                    if mapModel.selectionMode != .replace {
                        Circle()
                            .fill(StudioTheme.accent)
                            .frame(width: 4, height: 4)
                            .offset(x: 2, y: 2)
                    }
                }
            }
            .popover(isPresented: $showSelectPopover, arrowEdge: .bottom) {
                TileSelectionPopover(model: mapModel)
            }
        } else {
            ToolHoverButton(
                isSelected: mapModel.tool == tool,
                selectedColor: StudioTheme.accent,
                tooltipName: "\(tool.label)",
                shortcut: shortcut(for: tool),
                tooltipDescription: mapToolDescription(for: tool),
                width: 26,
                height: 26,
                action: {
                    showLayers = false
                    showColor = false
                    showSelectPopover = false
                    mapModel.tool = tool
                }
            ) { isSel, _ in
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSel ? StudioTheme.accent : Color.white.opacity(0.85))
            }
        }
    }

    private var layersToggle: some View {
        ToolHoverButton(
            isSelected: showLayers,
            selectedColor: StudioTheme.procreateBlue,
            tooltipName: "Layers Panel",
            shortcut: "L",
            tooltipDescription: "Manage drawing layers, blend modes, visibility, and opacity",
            width: 28,
            height: 28,
            action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showLayers.toggle()
                    if showLayers {
                        showColor = false
                        showAI = false
                        showAssets = false
                        showActions = false
                    }
                }
            }
        ) { isSel, _ in
            Image(systemName: "square.2.layers.3d")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(isSel ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: LayersButtonFrameKey.self, value: geo.frame(in: .global))
            }
        )
    }

    private var assetLibraryToggle: some View {
        ToolHoverButton(
            isSelected: showAssets,
            selectedColor: StudioTheme.procreateBlue,
            tooltipName: "Project Assets",
            tooltipDescription: "Browse project documents, source images, tilesets, and generated assets",
            width: 28,
            height: 28,
            action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showAssets.toggle()
                    if showAssets {
                        showLayers = false
                        showColor = false
                        showAI = false
                        showActions = false
                    }
                }
            }
        ) { isSel, _ in
            Image(systemName: "shippingbox")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isSel ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
        }
    }

    private var animationAssistToggle: some View {
        ToolHoverButton(
            isSelected: showTimeline,
            selectedColor: StudioTheme.procreateBlue,
            tooltipName: "Animation Assist",
            shortcut: "Space",
            tooltipDescription: "Open timeline bar to create frames, adjust FPS, onion skinning, and play animation",
            width: 28,
            height: 28,
            action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showTimeline.toggle()
                }
            }
        ) { isSel, _ in
            Image(systemName: "film.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isSel ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
        }
    }

    @ViewBuilder
    private func colorToggle(isSpriteColor: Bool) -> some View {
        ToolHoverButton(
            isSelected: showColor,
            selectedColor: StudioTheme.procreateBlue,
            tooltipName: isSpriteColor ? "Color Palette & Disc" : "Tileset Palette",
            tooltipDescription: isSpriteColor ? "Pick active color, adjust HSB/RGB sliders, and select swatches" : "Browse tiles and select tile brush pattern",
            width: 28,
            height: 28,
            action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showColor.toggle()
                    if showColor {
                        showLayers = false
                        showAI = false
                        showAssets = false
                        showActions = false
                    }
                }
            }
        ) { isSel, isHov in
            if isSpriteColor {
                ZStack {
                    Circle()
                        .fill(currentColor)
                        .frame(width: 24, height: 24)
                    Circle()
                        .strokeBorder(isSel ? StudioTheme.procreateBlue : (isHov ? Color.white.opacity(0.7) : Color.white.opacity(0.35)), lineWidth: isSel ? 2.5 : 1)
                        .frame(width: 26, height: 26)
                }
                .onDrag {
                    NSItemProvider(item: ColorDropPayload(model.currentColor).jsonData as NSData,
                                   typeIdentifier: ColorDropPayload.typeIdentifier)
                } preview: {
                    ColorDropPreview(color: model.currentColor)
                }
                .help("Drag onto the canvas to fill the active layer")
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSel ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ColorButtonFrameKey.self, value: geo.frame(in: .global))
            }
        )
    }

    private var helpButton: some View {
        ToolHoverButton(
            isSelected: false,
            tooltipName: "Tools Reference & Guide",
            shortcut: "⌘?",
            tooltipDescription: "View detailed documentation, how-to guides, and shortcuts for all Bixel tools",
            width: 28,
            height: 28,
            action: {
                if let onShowHelp {
                    onShowHelp()
                } else {
                    NotificationCenter.default.post(name: .studioShowHelp, object: nil)
                }
            }
        ) { _, isHov in
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isHov ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
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
        .toolHoverEffect(
            name: "AI Copilot & Adjustments",
            shortcut: "⌘K",
            details: "AI pixel art generation, next frame prediction, and assistant chat",
            cornerRadius: 17
        )
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
    var onShowHelp: (() -> Void)? = nil
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

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
            .help("Actions: canvas, share and project commands")

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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Layers")
                                .font(.caption)
                                .foregroundColor(StudioTheme.textSecondary)
                            Spacer()
                            Stepper("\(viewport.onionFrames)", value: $viewport.onionFrames, in: 1...5)
                        }

                        Toggle(isOn: $viewport.onionColorize) {
                            Text("Colorize Layers")
                                .font(.caption)
                                .foregroundColor(StudioTheme.textSecondary)
                        }
                        .toggleStyle(.switch)

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
                // Scene / map resize + zoom controls
                HStack {
                    Label(mapModel.isInfinite ? "Scene" : "Scene Size", systemImage: "aspectratio")
                        .font(.system(size: 12))
                    Spacer()
                    Text(mapModel.isInfinite ? "Infinite" : "\(mapModel.width) × \(mapModel.height)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                if !mapModel.isInfinite {
                    Button {
                        post(.studioMapResize)
                    } label: {
                        Label("Resize Scene…", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .help("Resize the scene dimensions")
                }
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
                    .help("Zoom out")
                Button {
                    if let mapModel {
                        if mapModel.isInfinite {
                            viewport.zoomToFitInfinite(viewSize: viewport.lastViewSize,
                                                       contentBounds: mapModel.contentPixelBounds())
                        } else {
                            viewport.zoomToFitCurrent(canvasWidth: mapModel.map.pixelWidth,
                                                     height: mapModel.map.pixelHeight)
                        }
                    } else {
                        viewport.zoomToFitCurrent(canvasWidth: model.width, height: model.height)
                    }
                } label: {
                    Text("\(Int((viewport.zoom * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                }
                .controlSize(.small)
                .help("Zoom to fit")
                Button { viewport.zoomIn() } label: { Label("Zoom +", systemImage: "plus.magnifyingglass") }
                    .controlSize(.small)
                    .help("Zoom in")
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
                .help("Export the map as a Tiled JSON file")

                Button {
                    mapModel.exportCSV()
                } label: {
                    Label("CSV (one file per tile layer)…", systemImage: "tablecells")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .help("Export each tile layer as a CSV file")

                Button {
                    mapModel.exportPNG(scale: 4)
                } label: {
                    Label("PNG (4× composite)…", systemImage: "photo")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .help("Export a 4× PNG of the composited map")

                if let onImportTiledMap {
                    Divider().overlay(StudioTheme.hairline)
                    Button {
                        onImportTiledMap()
                    } label: {
                        Label("Import Tiled Map…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .help("Import a Tiled JSON map into this project")
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
                    .help("Export a \(scale)× PNG")
                }

                Divider().overlay(StudioTheme.hairline)

                Text("Share Animation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(StudioTheme.textSecondary)

                Button {
                    model.exportGIF()
                } label: {
                    Label("Animated GIF…", systemImage: "play.rectangle")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .help("Export the animation as an animated GIF")

                Button {
                    model.exportVideo()
                } label: {
                    Label("MP4 Video…", systemImage: "video")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .help("Export the animation as an MP4 video")

                Button {
                    model.exportSpriteSheet()
                } label: {
                    Label("Animated Sprite Sheet…", systemImage: "square.grid.3x2")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .help("Export all frames as an animated sprite sheet")
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
                .help("Create a new document")
            }

            Button {
                onShowProjects()
            } label: {
                Label("Project Gallery", systemImage: "square.grid.3x3")
            }
            .buttonStyle(.plain)
            .help("Open the project gallery")

            Button {
                if let onShowHelp {
                    onShowHelp()
                } else {
                    post(.studioShowHelp)
                }
            } label: {
                Label("Tools Guide & Help…", systemImage: "questionmark.circle")
            }
            .buttonStyle(.plain)
            .help("Open detailed tools reference, guide, and shortcuts")

            Divider().overlay(StudioTheme.hairline)

            if !subscriptionManager.isAdFree {
                Button {
                    post(.studioUnlockLifetime)
                } label: {
                    Label("Unlock Lifetime Ad-Free…", systemImage: "crown")
                }
                .buttonStyle(.plain)
                .help("Unlock lifetime ad-free")
            }

            Button {
                post(.studioCustomerCenter)
            } label: {
                Label("Manage Purchases…", systemImage: "person.crop.circle")
            }
            .buttonStyle(.plain)
            .help("Manage your purchases")

            Divider().overlay(StudioTheme.hairline)

            Button {
                AppSettings.requestOpen()
            } label: {
                Label("AI & App Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Open AI provider, skills, and app preferences")
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
        #if os(macOS)
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
        #elseif os(iOS)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windowScene.windows.first?.rootViewController else { return }
        let alert = UIAlertController(title: "Resize Map", message: "Re-grids every tile layer, anchored to the top-left.", preferredStyle: .alert)
        alert.addTextField { $0.text = "\(self.model.width)"; $0.placeholder = "Columns"; $0.keyboardType = .numberPad }
        alert.addTextField { $0.text = "\(self.model.height)"; $0.placeholder = "Rows"; $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Resize", style: .default) { [weak model] _ in
            guard let model else { return }
            let w = Int(alert.textFields?[0].text ?? "") ?? model.width
            let h = Int(alert.textFields?[1].text ?? "") ?? model.height
            model.resize(width: max(1, w), height: max(1, h))
        })
        rootVC.present(alert, animated: true)
        #endif
    }
}
