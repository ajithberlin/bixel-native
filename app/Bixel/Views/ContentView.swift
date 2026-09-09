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
                // Enhanced Home Page Dashboard
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
                        if let project = projects.createProject(name: name, kind: kind, width: size, height: size) {
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
                // Project Canvas Editor Page
                projectCanvasView
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showAI)
        .animation(.easeInOut(duration: 0.2), value: showLayers)
        .animation(.easeInOut(duration: 0.2), value: showColor)
        .animation(.easeInOut(duration: 0.2), value: showTimeline)
        .animation(.easeInOut(duration: 0.22), value: currentScreen)
        .sheet(isPresented: $showProjects) { ProjectPicker(store: projects) }
        .sheet(isPresented: $showNewDocument) { NewWorkspaceDocument(store: projects) }
        .onAppear {
            currentScreen = .home
            showLayers = true
        }
        .onChange(of: projects.current?.id) { _ in viewport.refit() }
        .onChange(of: projects.catalog.activeDocumentID) { _ in viewport.refit() }
        .onChange(of: showAI) { isOpen in
            if isOpen {
                showLayers = false
                showColor = false
            }
            viewport.setRightInset(isOpen ? aiPanelWidth : 0)
        }
        .onChange(of: assistantExpanded) { _ in
            viewport.setRightInset(showAI ? aiPanelWidth : 0)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { flushProject() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flushProject() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in flushProject() }
        .onReceive(NotificationCenter.default.publisher(for: .studioUndo)) { _ in model.undo() }
        .onReceive(NotificationCenter.default.publisher(for: .studioRedo)) { _ in model.redo() }
        .onReceive(NotificationCenter.default.publisher(for: .studioZoomIn)) { _ in viewport.zoomIn() }
        .onReceive(NotificationCenter.default.publisher(for: .studioZoomOut)) { _ in viewport.zoomOut() }
        .onReceive(NotificationCenter.default.publisher(for: .studioZoomFit)) { _ in
            viewport.zoomToFitCurrent(canvasWidth: model.width, height: model.height)
        }
        .alert("Project could not be saved or opened", isPresented: Binding(get: { projects.error != nil }, set: { if !$0 { projects.error = nil } })) {
            Button("OK") { projects.error = nil }
        } message: { Text(projects.error ?? "") }
    }

    private func flushProject() {
        do { try projects.flush() } catch { projects.error = error.localizedDescription }
    }

    // MARK: - Project Canvas View

    private var projectCanvasView: some View {
        ZStack {
            Group {
                // Infinite canvas, edge to edge.
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
                .disabled(projects.current == nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // AI copilot docked against the right edge. It overlays the
                // canvas (which keeps its size) instead of resizing the shell.
                if showAI {
                    HStack(spacing: 0) {
                        AIPanel(
                            model: model,
                            session: assistant,
                            onClose: { showAI = false },
                            expanded: assistantExpanded,
                            onExpand: { assistantExpanded.toggle() }
                        )
                    }
                    .id(projects.current?.id)
                    .frame(width: aiPanelWidth)
                    .frame(maxHeight: .infinity)
                    .background(
                        Rectangle().fill(.ultraThinMaterial)
                            .overlay(Rectangle().fill(StudioTheme.procreateGlass))
                    )
                    .overlay(alignment: .leading) {
                        Rectangle().fill(StudioTheme.hairlineStrong).frame(width: 1)
                    }
                    .padding(.top, 52)
                    .padding(.bottom, 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
extension Notification.Name {
    static let studioUndo = Notification.Name("studio.undo")
    static let studioRedo = Notification.Name("studio.redo")
    static let studioZoomIn = Notification.Name("studio.zoomIn")
    static let studioZoomOut = Notification.Name("studio.zoomOut")
    static let studioZoomFit = Notification.Name("studio.zoomFit")
}
