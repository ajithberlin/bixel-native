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
    @State private var showNewDocument = false
    @State private var showAI = false
    @State private var showLayers = true
    @State private var showColor = false
    @State private var showTimeline = false
    @State private var showAssets = false
    @State private var assistantExpanded = false
    @State private var showPaywall = false
    @State private var showCustomerCenter = false
    @State private var loadingProject: StudioProject? = nil
    @State private var showLoadingAd = false
    @State private var pendingPostAction: (() -> Void)? = nil
    @StateObject private var subscriptionManager = SubscriptionManager.shared
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
                        handleOpenProject(project)
                    },
                    onOpenWithAIPrompt: { prompt in
                        let lower = prompt.lowercased()
                        let mode: WorkspaceMode = lower.contains("map") ? .map : .normal
                        let size = mode == .map ? 40 : 32
                        let name = "AI: " + String(prompt.prefix(20)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if let newProject = projects.createProject(name: name, mode: mode, width: size, height: mode == .map ? 25 : size) {
                            handleOpenProject(newProject) {
                                projects.assistant.input = prompt
                                showAI = true
                                projects.assistant.send(model: projects.editor)
                            }
                        }
                    },
                    onPresentPaywall: { showPaywall = true },
                    onPresentCustomerCenter: { showCustomerCenter = true }
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
                .onReceive(NotificationCenter.default.publisher(for: .studioUnlockLifetime)) { _ in showPaywall = true }
                .onReceive(NotificationCenter.default.publisher(for: .studioCustomerCenter)) { _ in showCustomerCenter = true }
                .onReceive(NotificationCenter.default.publisher(for: .studioRestorePurchases)) { _ in
                    Task { await subscriptionManager.restorePurchases() }
                }

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: projects.current?.id) { _ in viewport.refit() }
                .onChange(of: projects.catalog.activeDocumentID) { _ in
                    viewport.refit()
                    syncAnimationAssistVisibility()
                }
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

            // Interstitial Loading Ad Overlay (when opening / launching a project)
            if showLoadingAd, let project = loadingProject {
                ProjectLoadingAdView(
                    project: project,
                    onFinish: {
                        projects.select(project)
                        withAnimation(.easeInOut(duration: 0.22)) {
                            currentScreen = .project
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            showLoadingAd = false
                            loadingProject = nil
                        }
                        let action = pendingPostAction
                        pendingPostAction = nil
                        action?()
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showLoadingAd = false
                            loadingProject = nil
                        }
                        pendingPostAction = nil
                    },
                    onPresentPaywall: {
                        showPaywall = true
                    }
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showAI)
        .animation(.easeInOut(duration: 0.2), value: showLayers)
        .animation(.easeInOut(duration: 0.2), value: showColor)
        .animation(.easeInOut(duration: 0.2), value: showAssets)
        .animation(.easeInOut(duration: 0.22), value: currentScreen)
        .sheet(isPresented: $showProjects) {
            ProjectPicker(store: projects, onSelectProject: { project in
                handleOpenProject(project)
            })
        }
        .sheet(isPresented: $showNewDocument) { NewWorkspaceDocument(store: projects) }
        .sheet(isPresented: $showPaywall) { PaywallContainerView() }
        .sheet(isPresented: $showCustomerCenter) { CustomerCenterContainerView() }
        .onAppear {
            currentScreen = .home
            showLayers = true
            showAssets = false
        }
    }

    private func handleOpenProject(_ project: StudioProject, postAction: (() -> Void)? = nil) {
        if AdManager.shared.shouldShowAds {
            loadingProject = project
            pendingPostAction = postAction
            withAnimation(.easeInOut(duration: 0.2)) {
                showLoadingAd = true
            }
        } else {
            projects.select(project)
            withAnimation(.easeInOut(duration: 0.22)) {
                currentScreen = .project
            }
            postAction?()
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

    private func syncAnimationAssistVisibility() {
        guard let document = projects.activeDocument, document.mode == .normal else {
            showTimeline = false
            return
        }
        // A normal document with multiple frames is an animation workspace,
        // while one-frame artwork stays uncluttered until the user asks for it.
        showTimeline = model.frameCount > 1
    }

    // MARK: - Project Canvas View

    private var projectCanvasView: some View {
        HStack(spacing: 0) {
            // Left Window: project-wide documents and generated/source assets.
            if showAssets {
                ProjectAssetsPanel(store: projects)
                    .id(projects.current?.id)
                    .frame(width: 292)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(StudioTheme.hairlineStrong)
                            .frame(width: 1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Center Window: Main Editor Workspace (Canvas, top bar, layers/color popovers, timeline, dock)
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

            // Eyedropper Magnifying Loupe Overlay
            EyedropperOverlayView(model: model)

            // Left vertical brush dock, vertically centered.
            HStack {
                LeftBrushDock(model: model, viewport: viewport)
                    .padding(.leading, 14)
                    .disabled(projects.activeDocument == nil)
                Spacer()
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
        .coordinateSpace(name: "CanvasCoordinateSpace")
        .disabled(projects.current == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var spriteTopChrome: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
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
                    showAssets: $showAssets,
                    onNewDocument: { showNewDocument = true }
                )

                EyedropperBannerOverlay(model: model)
            }
            .animation(.easeInOut(duration: 0.18), value: model.eyedropperSession?.isActive)
            .zIndex(10)

            Spacer()

            if model.floatingImport != nil || model.selectionRect != nil || model.transformRect != nil {
                SelectionTransformToolbar(model: model)
                    .padding(.bottom, 16)
            }

            EditorOperationFeedback(model: model)

            spriteBottomChrome
        }
    }

    private var spriteBottomChrome: some View {
        VStack(spacing: 8) {
            if showTimeline && projects.activeDocument?.supportsAnimationAssist == true {
                TimelineBar(model: model)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }

            AdBannerView(onPresentPaywall: { showPaywall = true })
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: Tilemap Designer workspace (.map documents)

    private func mapWorkspace(_ mapModel: TileMapModel) -> some View {
        ZStack {
            mapCanvas(mapModel)
            mapPalette(mapModel)
            mapRightLayers(mapModel)
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

    /// Left column: tool dock + an always-visible tileset palette.
    private func mapPalette(_ mapModel: TileMapModel) -> some View {
        HStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                MapLeftDock(model: mapModel)
                TilesetPanel(store: projects, model: mapModel)
            }
            .padding(.leading, 14)
            Spacer(minLength: 0)
        }
    }

    private func mapRightLayers(_ mapModel: TileMapModel) -> some View {
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
            AdBannerView(onPresentPaywall: { showPaywall = true })
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
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
                showAssets: $showAssets,
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
    static let studioUnlockLifetime = Notification.Name("studio.unlockLifetime")
    static let studioCustomerCenter = Notification.Name("studio.customerCenter")
    static let studioRestorePurchases = Notification.Name("studio.restorePurchases")
}
