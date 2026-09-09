// ContentView.swift
//
// Canvas-centric studio shell in the spirit of Procreate / Procreate Dreams:
// the infinite canvas fills the window edge-to-edge and all chrome — top bar,
// tool rail, color/layers panel, timeline, assistant — floats over it as
// translucent capsules and panels.

import SwiftUI

struct ContentView: View {
    @StateObject private var projects = ProjectStore()
    @StateObject private var viewport = CanvasViewport()
    @State private var showProjects = false
    @State private var showLibrary = true
    @State private var showNewDocument = false
    @State private var showAI = true
    @State private var showPanel = true
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

                SelectionOverlay(model: model, viewport: viewport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Left tool rail + brush sliders, vertically centered.
                if !showLibrary {
                HStack(alignment: .center, spacing: 8) {
                    ToolRail(model: model)
                    BrushSliders(model: model)
                    Spacer()
                }
                .padding(.leading, 14)
                .disabled(projects.activeDocument == nil)
                }

                if showLibrary {
                    HStack {
                        WorkspaceLibrary(store: projects, onClose: { showLibrary = false })
                            .id(projects.current?.id)
                            .studioPanel().padding(.leading, 14).padding(.top, 106).padding(.bottom, 100)
                        Spacer()
                    }
                }

                // Right side: assistant, or the color/layers panel.
                HStack {
                    Spacer()
                    if showAI {
                        AIPanel(model: model, session: assistant, onClose: { showAI = false },
                                expanded: assistantExpanded, onExpand: { assistantExpanded.toggle() })
                            .id(projects.current?.id)
                            .frame(width: assistantExpanded ? 540 : 390)
                            .frame(maxHeight: .infinity)
                            .studioPanel()
                            .padding(.trailing, 14)
                            .padding(.top, 64)
                            .padding(.bottom, 84)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if showPanel {
                        RightPanel(model: model)
                            .padding(.trailing, 14)
                            .padding(.top, 64)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                // Top capsule + bottom timeline.
                VStack {
                    TopBar(
                        model: model,
                        viewport: viewport,
                        projectName: projects.current?.name ?? "Bixel",
                        onShowProjects: { showProjects = true },
                        showPanel: $showPanel,
                        showAI: $showAI
                    )
                    .padding(.top, 10)
                    HStack {
                        Button { showLibrary.toggle() } label: { Label("Library", systemImage: "square.stack.3d.up") }
                        Button { showNewDocument = true } label: { Image(systemName: "plus") }.help("New document")
                            .disabled(assistant.busy)
                        if let item = projects.activeDocument {
                            Text("\(item.name) · \(item.kind.title)").font(.caption.bold())
                            Text(item.summary).font(.caption).foregroundColor(.secondary)
                        } else { Text("Add a document to start creating").font(.caption) }
                        Spacer()
                    }.padding(.horizontal, 24).padding(.top, 6)

                    Spacer()

                    if model.selectionRect != nil || model.transformRect != nil {
                        SelectionTransformToolbar(model: model)
                            .padding(.bottom, 70)
                    }

                    EditorOperationFeedback(model: model)
                    if projects.activeDocument != nil && model.assetKind != .map && model.assetKind != .tileset {
                    TimelineBar(model: model, collapsed: $timelineCollapsed)
                        .padding(.horizontal, 16)
                        .padding(.bottom, timelineCollapsed ? 4 : 12)
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
        .animation(.easeInOut(duration: 0.2), value: showPanel)
        .sheet(isPresented: $showProjects) { ProjectPicker(store: projects) }
        .sheet(isPresented: $showNewDocument) { NewWorkspaceDocument(store: projects) }
        .onAppear { showProjects = projects.current == nil }
        .onChange(of: projects.current?.id) { _ in viewport.refit(); showLibrary = true }
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
