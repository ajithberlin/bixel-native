// ContentView.swift
//
// Canvas-centric studio shell in the spirit of Procreate:
// the infinite canvas fills the window edge-to-edge and all chrome — top bar,
// left brush dock, floating layers card, color popover, and timeline — floats over it.

import SwiftUI

enum StudioScreen {
    case home
    case project
}

struct ContentView: View {
    @StateObject private var projects = ProjectStore()
    @StateObject private var viewport = CanvasViewport()
    @State private var currentScreen: StudioScreen = .home
    @State private var showProjects = false
    @State private var showLibrary = false
    @State private var showNewDocument = false
    @State private var showAI = false
    @State private var showLayers = true
    @State private var showColor = false
    @State private var showTimeline = false
    @State private var assistantExpanded = false
    @Environment(\.scenePhase) private var scenePhase

    private var model: EditorModel { projects.editor }
    private var assistant: AssistantSession { projects.assistant }
    private var aiPanelWidth: CGFloat { assistantExpanded ? 520 : 372 }

    var body: some View {
        ZStack {
            if currentScreen == .home {
                HomePageView(
                    store: projects,
                    onOpenProject: { project in
                        projects.select(project)
                        withAnimation(.easeInOut(duration: 0.22)) {
                            currentScreen = .project
                        }
                    },
                    onOpenWithAIPrompt: { prompt in
                        let lower = prompt.lowercased()
                        let kind: AssetKind = lower.contains("tile") ? .tileset : (lower.contains("anim") || lower.contains("walk")) ? .animation : .sprite
                        let size = kind == .tileset ? 128 : (kind == .animation ? 64 : 32)
                        let name = "AI: " + String(prompt.prefix(20)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if projects.createProject(name: name, kind: kind, width: size, height: size) != nil {
                            projects.assistant.input = prompt
                            withAnimation(.easeInOut(duration: 0.22)) {
                                currentScreen = .project
                                showAI = true
                            }
                            projects.assistant.send(model: projects.editor)
                        }
                    }
                )
                .transition(.opacity)
            } else {
                projectCanvasView
                    .transition(.opacity)
            }

            // Lightweight router layers: each carries only a few handlers so the
            // root screen expression stays fast to type-check.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(NotificationCenter.default.publisher(for: .studioUndo)) { _ in performUndo() }
                .onReceive(NotificationCenter.default.publisher(for: .studioRedo)) { _ in performRedo() }
                .onReceive(NotificationCenter.default.publisher(for: .studioZoomIn)) { _ in viewport.zoomIn() }
                .onReceive(NotificationCenter.default.publisher(for: .studioZoomOut)) { _ in viewport.zoomOut() }
                .onReceive(NotificationCenter.default.publisher(for: .studioZoomFit)) { _ in performZoomFit() }

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: projects.current?.id) { _ in viewport.refit() }
                .onChange(of: projects.catalog.activeDocumentID) { _ in viewport.refit() }
                .onChange(of: scenePhase) { phase in
                    if phase != .active { flushProject() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flushProject() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in flushProject() }

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .alert("Project could not be saved or opened", isPresented: Binding(get: { projects.error != nil }, set: { if !$0 { projects.error = nil } })) {
                    Button("OK") { projects.error = nil }
                } message: { Text(projects.error ?? "") }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showAI)
        .animation(.easeInOut(duration: 0.2), value: showLayers)
        .animation(.easeInOut(duration: 0.2), value: showColor)
        .animation(.easeInOut(duration: 0.22), value: currentScreen)
        .sheet(isPresented: $showProjects) { ProjectPicker(store: projects) }
        .sheet(isPresented: $showNewDocument) { NewWorkspaceDocument(store: projects) }
        .onAppear {
            currentScreen = .home
            showLayers = true
        }
    }

    private func flushProject() {
        do { try projects.flush() } catch { projects.error = error.localizedDescription }
    }

    private func performUndo() {
        if let map = activeMap { map.undo() } else { model.undo() }
    }

    private func performRedo() {
        if let map = activeMap { map.redo() } else { model.redo() }
    }

    private func performZoomFit() {
        if let map = activeMap {
            viewport.zoomToFitCurrent(canvasWidth: map.map.pixelWidth, height: map.map.pixelHeight)
        } else {
            viewport.zoomToFitCurrent(canvasWidth: model.width, height: model.height)
        }
    }

    // MARK: - Project Canvas View

    private var projectCanvasView: some View {
        HStack(spacing: 0) {
            // Left Window: Main Editor Workspace (Canvas, top bar, layers/color popovers, timeline, dock)
            editorWorkspaceView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right Window: Full-Height Connected AI Agent Pane
            if showAI {
                Rectangle()
                    .fill(StudioTheme.hairlineStrong)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                AIPanel(
                    model: model,
                    session: assistant,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAI = false
                        }
                    },
                    expanded: assistantExpanded,
                    onExpand: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            assistantExpanded.toggle()
                        }
                    }
                )
                .id(projects.current?.id)
                .frame(width: aiPanelWidth)
                .frame(maxHeight: .infinity)
                .background(StudioTheme.panel)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var editorWorkspaceView: some View {
        if let mapModel = activeMap {
            mapWorkspace(mapModel)
        } else {
            spriteWorkspace
        }
    }

    private var activeMap: TileMapModel? {
        projects.isMapActive ? projects.mapEditor : nil
    }

    // MARK: Sprite / animation / tileset workspace

    private var spriteWorkspace: some View {
        ZStack {
            // Infinite canvas, edge to edge within this pane.
            CanvasView(model: model, viewport: viewport)
                .id(projects.catalog.activeDocumentID)
                .allowsHitTesting(projects.activeDocument != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Left vertical brush dock, vertically centered.
            HStack {
                LeftBrushDock(model: model)
                    .padding(.leading, 14)
                    .disabled(projects.activeDocument == nil)
                Spacer()
            }

            // Workspace Library (when opened)
            if showLibrary {
                HStack {
                    WorkspaceLibrary(store: projects, onClose: { showLibrary = false })
                        .id(projects.current?.id)
                        .procreatePanel(radius: 16)
                        .padding(.leading, 64)
                        .padding(.top, 64)
                        .padding(.bottom, 70)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Spacer()
                }
            }

            // Right floating popovers (Layers card & Color disc)
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Color.clear.frame(height: 52)
                    if showLayers {
                        LayersPopover(model: model)
                            .padding(.trailing, 16)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                    } else if showColor {
                        ColorPopover(model: model)
                            .padding(.trailing, 16)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    Spacer()
                }
            }

            // Top navigation bar & Bottom timeline
            spriteTopChrome
        }
        .disabled(projects.current == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var spriteTopChrome: some View {
        VStack(spacing: 0) {
            TopBar(
                model: model,
                viewport: viewport,
                projectName: projects.current?.name ?? "Bixel Project",
                onShowProjects: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        currentScreen = .home
                    }
                },
                onGoHome: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        currentScreen = .home
                    }
                },
                showLayers: $showLayers,
                showColor: $showColor,
                showAI: $showAI,
                showTimeline: $showTimeline,
                onNewDocument: { showNewDocument = true }
            )

            Spacer()

            if model.selectionRect != nil || model.transformRect != nil {
                SelectionTransformToolbar(model: model)
                    .padding(.bottom, 16)
            }

            EditorOperationFeedback(model: model)

            if showTimeline && projects.activeDocument != nil && model.assetKind != .map && model.assetKind != .tileset {
                TimelineBar(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Tilemap Designer workspace (.map documents)

    private func mapWorkspace(_ mapModel: TileMapModel) -> some View {
        ZStack {
            mapCanvas(mapModel)
            mapLeftDock(mapModel)
            mapLibrary
            mapRightPanels(mapModel)
            mapBottomOverlay(mapModel)
            mapTopChrome(mapModel)
            mapCommandSink(mapModel)
        }
        .disabled(projects.current == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Map-only menu commands (clipboard, transform, resize, export).
    private func mapCommandSink(_ mapModel: TileMapModel) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .studioCopy)) { _ in mapModel.copySelection() }
            .onReceive(NotificationCenter.default.publisher(for: .studioCut)) { _ in mapModel.cutSelection() }
            .onReceive(NotificationCenter.default.publisher(for: .studioPaste)) { _ in mapModel.beginPaste() }
            .onReceive(NotificationCenter.default.publisher(for: .studioDelete)) { _ in
                if mapModel.isObjectActive { mapModel.deleteObject() } else { mapModel.deleteSelection() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioFlipH)) { _ in mapModel.flipBrushH() }
            .onReceive(NotificationCenter.default.publisher(for: .studioFlipV)) { _ in mapModel.flipBrushV() }
            .onReceive(NotificationCenter.default.publisher(for: .studioRotate)) { _ in mapModel.rotateBrushCW() }
            .onReceive(NotificationCenter.default.publisher(for: .studioMapResize)) { _ in
                MapResizeDialog(model: mapModel).show()
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioExportTiledJSON)) { _ in mapModel.exportTiledJSON() }
            .onReceive(NotificationCenter.default.publisher(for: .studioExportCSV)) { _ in mapModel.exportCSV() }
            .onReceive(NotificationCenter.default.publisher(for: .studioExportMapPNG)) { _ in mapModel.exportPNG(scale: 4) }
    }

    private func mapCanvas(_ mapModel: TileMapModel) -> some View {
        TileMapCanvasView(model: mapModel, viewport: viewport)
            .id(projects.catalog.activeDocumentID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mapLeftDock(_ mapModel: TileMapModel) -> some View {
        HStack {
            MapLeftDock(model: mapModel)
                .padding(.leading, 14)
            Spacer()
        }
    }

    @ViewBuilder
    private var mapLibrary: some View {
        if showLibrary {
            HStack {
                WorkspaceLibrary(store: projects, onClose: { showLibrary = false })
                    .id(projects.current?.id)
                    .procreatePanel(radius: 16)
                    .padding(.leading, 64)
                    .padding(.top, 64)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Spacer()
            }
        }
    }

    private func mapRightPanels(_ mapModel: TileMapModel) -> some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing, spacing: 14) {
                Color.clear.frame(height: 52)
                if showLayers {
                    MapLayersPanel(model: mapModel)
                        .padding(.trailing, 16)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                } else if showColor {
                    TilesetPanel(store: projects, model: mapModel)
                        .padding(.trailing, 16)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                Spacer()
            }
        }
    }

    private func mapBottomOverlay(_ mapModel: TileMapModel) -> some View {
        VStack(spacing: 0) {
            Spacer()
            MapWorkspaceFeedback(model: mapModel)
                .padding(.bottom, 8)
            HStack(alignment: .bottom) {
                Spacer()
                MiniMapOverlay(model: mapModel, viewport: viewport)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private func mapTopChrome(_ mapModel: TileMapModel) -> some View {
        VStack(spacing: 0) {
            TopBar(
                model: model,
                viewport: viewport,
                projectName: projects.current?.name ?? "Bixel Project",
                onShowProjects: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        currentScreen = .home
                    }
                },
                onGoHome: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        currentScreen = .home
                    }
                },
                showLayers: $showLayers,
                showColor: $showColor,
                showAI: $showAI,
                showTimeline: $showTimeline,
                onNewDocument: { showNewDocument = true },
                mapModel: mapModel,
                onImportTiledMap: {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        projects.importTiledMap(from: url)
                    }
                }
            )
            Spacer()
        }
    }
}
extension Notification.Name {
    static let studioUndo = Notification.Name("studio.undo")
    static let studioRedo = Notification.Name("studio.redo")
    static let studioZoomIn = Notification.Name("studio.zoomIn")
    static let studioZoomOut = Notification.Name("studio.zoomOut")
    static let studioZoomFit = Notification.Name("studio.zoomFit")
    static let studioCopy = Notification.Name("studio.copy")
    static let studioCut = Notification.Name("studio.cut")
    static let studioPaste = Notification.Name("studio.paste")
    static let studioDelete = Notification.Name("studio.delete")
    static let studioFlipH = Notification.Name("studio.flipH")
    static let studioFlipV = Notification.Name("studio.flipV")
    static let studioRotate = Notification.Name("studio.rotate")
    static let studioMapResize = Notification.Name("studio.mapResize")
    static let studioExportTiledJSON = Notification.Name("studio.exportTiledJSON")
    static let studioExportCSV = Notification.Name("studio.exportCSV")
    static let studioExportMapPNG = Notification.Name("studio.exportMapPNG")
}
