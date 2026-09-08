// ContentView.swift
//
// Top-level layout: top bar, tool rail, canvas, right panel, timeline — a
// canvas-centric studio shell in the spirit of Procreate / Procreate Dreams.

import SwiftUI

struct ContentView: View {
    @StateObject private var model = EditorModel(width: 32, height: 32)
    @State private var showAI = true
    @State private var assistantExpanded = false
    @StateObject private var assistant = AssistantSession()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, showAI: $showAI)

            HStack(spacing: 0) {
                ToolRail(model: model)

                CanvasView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioTheme.canvasBackground)

                if !showAI { RightPanel(model: model) }

                AIPanel(model: model, session: assistant, onClose: { showAI = false },
                        expanded: assistantExpanded, onExpand: { assistantExpanded.toggle() })
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

    }
}
