// ContentView.swift
//
// Canvas-centric studio shell in the spirit of Procreate:
// the infinite canvas fills the window edge-to-edge and all chrome — top bar,
// left brush dock, floating layers card, color popover, and timeline — floats over it.

import SwiftUI

struct ContentView: View {
    @StateObject private var projects = ProjectStore()
    @StateObject private var viewport = CanvasViewport()
    @State private var showProjects = false
    @State private var showLibrary = false
    @State private var showNewDocument = false
    @State private var showAI = false
    @State private var showLayers = true
    @State private var showColor = false
    @State private var showTimeline = false
    @State private var timelineCollapsed = false
    @State private var assistantExpanded = false
    @Environment(\.scenePhase) private var scenePhase

    private var model: EditorModel { projects.editor }
    private var assistant: AssistantSession { projects.assistant }

    var body: some View {
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

                // Right floating AI panel (when opened via wand)
                if showAI {
                    HStack {
                        Spacer()
                        AIPanel(
                            model: model,
                            session: assistant,
                            onClose: { showAI = false },
                            expanded: assistantExpanded,
                            onExpand: { assistantExpanded.toggle() }
                        )
                        .id(projects.current?.id)
                        .frame(width: assistantExpanded ? 540 : 390)
                        .frame(maxHeight: .infinity)
                        .procreatePanel(radius: 16)
                        .padding(.trailing, 16)
                        .padding(.top, 56)
                        .padding(.bottom, 70)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                // Top navigation bar & Bottom timeline
                VStack(spacing: 0) {
                    TopBar(
                        model: model,
                        viewport: viewport,
                        projectName: projects.current?.name ?? "Bixel",
                        onShowProjects: { showProjects = true },
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
                        TimelineBar(model: model, collapsed: $timelineCollapsed)
                            .padding(.horizontal, 16)
                            .padding(.bottom, timelineCollapsed ? 4 : 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .disabled(projects.current == nil)

            // Empty state.
            if projects.current == nil {
                VStack(spacing: 14) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 40))
                        .foregroundColor(StudioTheme.accent)
                    Text("Bixel Studio")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(StudioTheme.textPrimary)
                    Button("Create or Open Project") { showProjects = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioTheme.background.opacity(0.85))
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showAI)
        .animation(.easeInOut(duration: 0.2), value: showLayers)
        .animation(.easeInOut(duration: 0.2), value: showColor)
        .animation(.easeInOut(duration: 0.2), value: showTimeline)
        .sheet(isPresented: $showProjects) { ProjectPicker(store: projects) }
        .sheet(isPresented: $showNewDocument) { NewWorkspaceDocument(store: projects) }
        .onAppear {
            showProjects = projects.current == nil
            showLayers = true
        }
        .onChange(of: projects.current?.id) { _ in viewport.refit() }
        .onChange(of: projects.catalog.activeDocumentID) { _ in viewport.refit() }
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
}

extension Notification.Name {
    static let studioUndo = Notification.Name("studio.undo")
    static let studioRedo = Notification.Name("studio.redo")
    static let studioZoomIn = Notification.Name("studio.zoomIn")
    static let studioZoomOut = Notification.Name("studio.zoomOut")
    static let studioZoomFit = Notification.Name("studio.zoomFit")
}
