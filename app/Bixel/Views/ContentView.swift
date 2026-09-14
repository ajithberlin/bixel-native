// ContentView.swift
//
// Canvas-centric studio shell in the spirit of Procreate:
// the infinite canvas fills the window edge-to-edge and all chrome — top bar,
// left brush dock, floating layers card, color popover, and timeline — floats over it.

import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showLayers = false
    @State private var showColor = false
    @State private var showTimeline = false
    @State private var showAssets = false
    @State private var layersButtonFrame: CGRect = .zero
    @State private var colorButtonFrame: CGRect = .zero
    @State private var assistantExpanded = false
    @State private var showPaywall = false
    @State private var showCustomerCenter = false
    @State private var showHelpDocument = false
    @State private var showSettings = false
    @State private var loadingProject: StudioProject? = nil
    @State private var showLoadingAd = false
    @State private var pendingPostAction: (() -> Void)? = nil
    @State private var aiCreationInProgress = false
    @State private var generatedImageDraft: AIGeneratedImageDraft?
    @State private var presentedAIDraft: AIGeneratedImageDraft?
    @State private var aiReviewCompleted = false
    @State private var aiGenerationError: String?
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.scenePhase) private var scenePhase
    /// On iPad the assistant is only offered while a Mac is connected.
    @ObservedObject private var remote = RemoteClient.shared

    private var assistantAvailable: Bool {
        #if os(macOS)
        return true
        #else
        return remote.state.isConnected
        #endif
    }

    @AppStorage("bixel.openAssistantOnLaunch") private var openAssistantOnLaunch = false
    @AppStorage("bixel.defaultSnapping") private var defaultSnapping = true
    @AppStorage("bixel.defaultFrameRate") private var defaultFrameRate = 12.0

    private var model: EditorModel { projects.editor }
    private var assistant: AssistantSession { projects.assistant }
    private var aiPanelWidth: CGFloat { assistantExpanded ? 520 : 372 }

    /// Open the assistant with the current frame attached and ask it to predict
    /// the next animation frame for `action`.
    private func predictNextFrame(_ action: String) {
        assistant.attachCanvas(model)
        assistant.input = "[[skill:next_frame]] \(action)"
        withAnimation(.easeInOut(duration: 0.2)) { showAI = true }
        assistant.send(model: model)
    }

    var body: some View {
        ZStack {
            AppSettingsOpener()

            if currentScreen == .home {
                HomePageView(
                    store: projects,
                    aiGallery: projects.aiGallery,
                    onOpenProject: { project in
                        handleOpenProject(project)
                    },
                    onOpenWithAIPrompt: { request in
                        startAIImageGeneration(request)
                    },
                    isAIGenerating: aiCreationInProgress,
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
                .onReceive(NotificationCenter.default.publisher(for: .studioShowHelp)) { _ in showHelpDocument = true }
                .onReceive(NotificationCenter.default.publisher(for: AppSettings.openRequest)) { _ in showSettings = true }
                .onReceive(NotificationCenter.default.publisher(for: .studioRestorePurchases)) { _ in
                    Task { await subscriptionManager.restorePurchases() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .studioDismissPopovers)) { _ in
                    if showLayers || showColor {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showLayers = false
                            showColor = false
                        }
                    }
                }
                .onPreferenceChange(LayersButtonFrameKey.self) { layersButtonFrame = $0 }
                .onPreferenceChange(ColorButtonFrameKey.self) { colorButtonFrame = $0 }

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: projects.current?.id) { _ in viewport.refit() }
                .onChange(of: projects.catalog.activeDocumentID) { _ in
                    viewport.refit()
                    syncAnimationAssistVisibility()
                }
                .onChange(of: scenePhase) { phase in
                    if phase != .active {
                        flushProject()
                    } else {
                        #if os(iOS)
                        RemoteClient.shared.reconnectIfNeeded()
                        #endif
                    }
                }
                #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flushProject() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in flushProject() }
                #else
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in flushProject() }
                #endif

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
                        applyEditorDefaults()
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
        #if os(macOS)
        .frame(minWidth: 1040, minHeight: 680)
        #endif
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showAI)
        .animation(.easeInOut(duration: 0.2), value: showLayers)
        .animation(.easeInOut(duration: 0.2), value: showColor)
        .animation(.easeInOut(duration: 0.2), value: showAssets)
        .animation(.easeInOut(duration: 0.22), value: currentScreen)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showProjects) {
            ProjectPicker(store: projects, onSelectProject: { project in
                handleOpenProject(project)
            })
        }
        .sheet(isPresented: $showNewDocument) { NewWorkspaceDocument(store: projects) }
        .sheet(isPresented: $showPaywall) { PaywallContainerView() }
        .sheet(isPresented: $showCustomerCenter) { CustomerCenterContainerView() }
        .sheet(isPresented: $showHelpDocument) { ToolsHelpView() }
        .sheet(item: $generatedImageDraft, onDismiss: handleGeneratedImageReviewDismissed) { draft in
            AIGeneratedImageReviewView(
                draft: draft,
                onCreateProject: { createProject(from: draft) },
                onKeepInGallery: { keepInGallery(draft) }
            )
        }
        .alert(
            "AI creation needs attention",
            isPresented: Binding(
                get: { aiGenerationError != nil },
                set: { if !$0 { aiGenerationError = nil } }
            )
        ) {
            Button("OK") { aiGenerationError = nil }
        } message: {
            Text(aiGenerationError ?? "")
        }
        .onAppear {
            currentScreen = .home
            showLayers = false
            showAssets = false
            #if os(macOS)
            if openAssistantOnLaunch { showAI = true }
            #endif
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
            applyEditorDefaults()
            withAnimation(.easeInOut(duration: 0.22)) {
                currentScreen = .project
            }
            postAction?()
        }
    }

    /// Apply the persisted General-pane defaults to the freshly opened editor.
    private func applyEditorDefaults() {
        model.snapping = defaultSnapping
        model.fps = defaultFrameRate
    }

    private func startAIImageGeneration(_ request: AICreationRequest) {
        guard !aiCreationInProgress else { return }
        guard AIService.imageGenerationIsReady(AIService.connectionStatus()) else {
            AppSettings.requestOpen()
            return
        }
        guard !projects.assistant.busy else {
            aiGenerationError = "Finish the current assistant request before generating another image."
            return
        }

        aiCreationInProgress = true
        aiGenerationError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.runSkill(
                id: "image_gen",
                params: request.imageParameters,
                prompt: request.prompt
            )
            let outcome: Result<AIGeneratedImageDraft, Error>
            do {
                outcome = .success(try AIGenerationFlow.makeDraft(request: request, result: result))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                aiCreationInProgress = false
                switch outcome {
                case .success(let draft):
                    presentedAIDraft = draft
                    aiReviewCompleted = false
                    generatedImageDraft = draft
                case .failure(let error):
                    aiGenerationError = error.localizedDescription
                }
            }
        }
    }

    private func createProject(from draft: AIGeneratedImageDraft) {
        guard let project = projects.createProject(
            name: draft.projectName,
            mode: .normal,
            width: draft.width,
            height: draft.height,
            pixels: draft.rgba
        ) else {
            aiGenerationError = projects.error ?? "The image was generated, but the project could not be created."
            return
        }
        aiReviewCompleted = true
        generatedImageDraft = nil
        handleOpenProject(project)
    }

    private func keepInGallery(_ draft: AIGeneratedImageDraft) {
        guard projects.aiGallery.save(draft) else {
            aiGenerationError = projects.aiGallery.error ?? "The image could not be saved to the AI Gallery."
            return
        }
        aiReviewCompleted = true
        generatedImageDraft = nil
    }

    private func handleGeneratedImageReviewDismissed() {
        if !aiReviewCompleted, let draft = presentedAIDraft {
            if !projects.aiGallery.save(draft) {
                aiGenerationError = projects.aiGallery.error ?? "The image could not be saved to the AI Gallery."
            }
        }
        presentedAIDraft = nil
        generatedImageDraft = nil
        aiReviewCompleted = false
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
            if map.isInfinite {
                viewport.zoomToFitInfinite(viewSize: viewport.lastViewSize,
                                           contentBounds: map.contentPixelBounds())
            } else {
                viewport.zoomToFitCurrent(canvasWidth: map.map.pixelWidth, height: map.map.pixelHeight)
            }
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
                    .zIndex(2)
            }

            // Center Window: Main Editor Workspace (Canvas, top bar, layers/color popovers, timeline, dock)
            editorWorkspaceView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // Right Window: Full-Height Connected AI Agent Pane. Always on
            // macOS; on iPad once a Mac is connected.
            if assistantAvailable && showAI {
                Rectangle()
                    .fill(StudioTheme.hairlineStrong)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)

                AIPanel(
                    model: model,
                    session: assistant,
                    store: projects,
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
                .zIndex(2)
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
                .clipped()

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
                            .background(
                                FloatingPopoverTracker(
                                    excludedFrames: [layersButtonFrame, colorButtonFrame],
                                    onDismiss: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            showLayers = false
                                        }
                                    }
                                )
                            )
                            .padding(.trailing, 16)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                    } else if showColor {
                        ColorPopover(model: model)
                            .background(
                                FloatingPopoverTracker(
                                    excludedFrames: [layersButtonFrame, colorButtonFrame],
                                    onDismiss: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            showColor = false
                                        }
                                    }
                                )
                            )
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

            spriteCommandSink
        }
        .coordinateSpace(name: "CanvasCoordinateSpace")
        .disabled(projects.current == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sprite/animation menu commands: frame clipboard plus timeline navigation.
    private var spriteCommandSink: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .studioCopy)) { _ in model.copyFrame() }
            .onReceive(NotificationCenter.default.publisher(for: .studioCut)) { _ in model.cutFrame() }
            .onReceive(NotificationCenter.default.publisher(for: .studioPaste)) { _ in model.pasteFrame() }
            .onReceive(NotificationCenter.default.publisher(for: .studioDelete)) { _ in
                guard model.selectionRect == nil, model.transformRect == nil,
                      model.floatingImport == nil else { return }
                model.removeFrame()
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioAddFrame)) { _ in
                model.pause()
                model.addFrame()
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioDuplicateFrame)) { _ in
                model.pause()
                model.duplicateFrame()
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioPrevFrame)) { _ in
                model.pause()
                model.goTo(model.frame - 1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioNextFrame)) { _ in
                model.pause()
                model.goTo(model.frame + 1)
            }
    }

    private var spriteTopChrome: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                TopBar(
                    model: model,
                    viewport: viewport,
                    projectName: projects.current?.name ?? "Bixel Project",
                    onShowProjects: {
                        try? projects.flush()
                        withAnimation(.easeInOut(duration: 0.22)) {
                            currentScreen = .home
                        }
                    },
                    onGoHome: {
                        try? projects.flush()
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
                    onShowHelp: { showHelpDocument = true }
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
                TimelineBar(model: model, viewport: viewport, onPredictNextFrame: predictNextFrame)
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
            .clipped()
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
                        .background(
                            FloatingPopoverTracker(
                                excludedFrames: [layersButtonFrame, colorButtonFrame],
                                onDismiss: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showLayers = false
                                    }
                                }
                            )
                        )
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
                    try? projects.flush()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        currentScreen = .home
                    }
                },
                onGoHome: {
                    try? projects.flush()
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
                onShowHelp: { showHelpDocument = true },
                mapModel: mapModel,
                onImportTiledMap: {
                    #if os(macOS)
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json, UTType(filenameExtension: "tmj") ?? .json]
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        projects.importTiledMap(from: url)
                    }
                    #endif
                }
            )
            Spacer()
        }
    }
}
extension Notification.Name {
    static let studioDismissPopovers = Notification.Name("studio.dismissPopovers")
    static let studioShowHelp = Notification.Name("studio.showHelp")
    static let studioUndo = Notification.Name("studio.undo")
    static let studioRedo = Notification.Name("studio.redo")
    static let studioZoomIn = Notification.Name("studio.zoomIn")
    static let studioZoomOut = Notification.Name("studio.zoomOut")
    static let studioZoomFit = Notification.Name("studio.zoomFit")
    static let studioCopy = Notification.Name("studio.copy")
    static let studioCut = Notification.Name("studio.cut")
    static let studioPaste = Notification.Name("studio.paste")
    static let studioDelete = Notification.Name("studio.delete")
    static let studioAddFrame = Notification.Name("studio.addFrame")
    static let studioDuplicateFrame = Notification.Name("studio.duplicateFrame")
    static let studioPrevFrame = Notification.Name("studio.prevFrame")
    static let studioNextFrame = Notification.Name("studio.nextFrame")
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

// MARK: - Anchor Button Frames

struct LayersButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct ColorButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Floating Popover Click Tracker

#if os(macOS)
struct FloatingPopoverTracker: NSViewRepresentable {
    var excludedFrames: [CGRect] = []
    var onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(excludedFrames: excludedFrames, onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        context.coordinator.excludedFrames = excludedFrames
        context.coordinator.onDismiss = onDismiss
        context.coordinator.attachMonitorIfNeeded(for: nsView)
    }

    static func dismantleNSView(_ nsView: TrackerView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator: NSObject {
        var excludedFrames: [CGRect]
        var onDismiss: () -> Void
        private var monitor: Any?
        private weak var trackingView: NSView?

        init(excludedFrames: [CGRect], onDismiss: @escaping () -> Void) {
            self.excludedFrames = excludedFrames
            self.onDismiss = onDismiss
        }

        func attachMonitorIfNeeded(for view: NSView) {
            trackingView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak view] event in
                guard let self, let view, let window = view.window else { return event }
                // Ignore events targeting other windows (e.g. child popover windows like blend mode picker)
                guard event.window === window else { return event }

                let clickLoc = event.locationInWindow
                let cardRect = view.convert(view.bounds, to: nil)

                // If click is inside the popover card itself, do not dismiss
                if cardRect.contains(clickLoc) {
                    return event
                }

                // Check excluded toggle button frames (converted to window coordinates)
                let windowHeight = window.contentView?.bounds.height ?? window.frame.height
                let swiftUIPoint = CGPoint(x: clickLoc.x, y: windowHeight - clickLoc.y)
                for frame in self.excludedFrames where !frame.isEmpty {
                    if frame.contains(swiftUIPoint) {
                        return event
                    }
                }

                // Click was outside the card and not on the toggle button
                DispatchQueue.main.async {
                    self.onDismiss()
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }

    final class TrackerView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                coordinator?.attachMonitorIfNeeded(for: self)
            } else {
                coordinator?.removeMonitor()
            }
        }
    }
}
#else
struct FloatingPopoverTracker: View {
    var excludedFrames: [CGRect] = []
    var onDismiss: () -> Void
    var body: some View {
        Color.clear
    }
}
#endif
