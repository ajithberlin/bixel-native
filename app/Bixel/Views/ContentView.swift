// ContentView.swift
//
// Top-level layout: top bar, tool rail, canvas, right panel, timeline — a
// canvas-centric studio shell in the spirit of Procreate / Procreate Dreams.

import SwiftUI

struct ContentView: View {
    @StateObject private var projects = ProjectStore()
    @State private var showProjects = false
    @Environment(\.scenePhase) private var scenePhase
    private var model: EditorModel { projects.editor }
    @State private var showAI = true
    @State private var assistantExpanded = false
    private var assistant: AssistantSession { projects.assistant }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { showProjects = true } label: {
                    Label(projects.current?.name ?? "Projects", systemImage: "folder")
                        .lineLimit(1).frame(maxWidth: 200)
                }
                .padding(.leading, 12)
                TopBar(model: model, showAI: $showAI)
            }

            HStack(spacing: 0) {
                ToolRail(model: model)

                CanvasView(model: model)
                    .id(projects.current?.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioTheme.canvasBackground)

                if !showAI { RightPanel(model: model) }

                AIPanel(model: model, session: assistant, onClose: { showAI = false },
                        expanded: assistantExpanded, onExpand: { assistantExpanded.toggle() })
                    .id(projects.current?.id)
                    .frame(width: showAI ? (assistantExpanded ? 540 : 390) : 0)
                    .clipped()
                    .opacity(showAI ? 1 : 0)
                    .allowsHitTesting(showAI)
                    .accessibilityHidden(!showAI)
            }

            TimelineBar(model: model)
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .disabled(projects.current == nil)
        .overlay {
            if projects.current == nil {
                Button("Create or Open Project") { showProjects = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $showProjects) { ProjectPicker(store: projects) }
        .onAppear { showProjects = projects.current == nil }
        .onChange(of: scenePhase) { phase in
            if phase != .active { flushProject() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flushProject() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in flushProject() }
        .alert("Project could not be saved or opened", isPresented: Binding(get: { projects.error != nil }, set: { if !$0 { projects.error = nil } })) {
            Button("OK") { projects.error = nil }
        } message: { Text(projects.error ?? "") }

    }

    private func flushProject() {
        do { try projects.flush() } catch { projects.error = error.localizedDescription }
    }
}
