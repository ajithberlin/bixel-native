// ContentView.swift
//
// Top-level layout: top bar, tool rail, canvas, right panel, timeline — a
// canvas-centric studio shell in the spirit of Procreate / Procreate Dreams.

import SwiftUI

struct ContentView: View {
    @StateObject private var model = EditorModel(width: 32, height: 32)
    @State private var showAI = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, showAI: $showAI)

            HStack(spacing: 0) {
                ToolRail(model: model)

                CanvasView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioTheme.canvasBackground)

                RightPanel(model: model)
            }

            TimelineBar(model: model)
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAI) {
            AIPanel(model: model)
                .frame(width: 640, height: 560)
        }
    }
}
