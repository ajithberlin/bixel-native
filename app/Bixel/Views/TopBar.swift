// TopBar.swift
//
// Floating top capsule: project menu and canvas size on the left, zoom
// controls in the middle, undo/redo, grid, onion skin, export, panel and AI
// toggles on the right.

import SwiftUI

struct TopBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport
    let projectName: String
    let onShowProjects: () -> Void
    @Binding var showPanel: Bool
    @Binding var showAI: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Project + canvas info
            Button(action: onShowProjects) {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.3x3.fill")
                        .foregroundColor(StudioTheme.accent)
                    Text(projectName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(StudioTheme.textPrimary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Open the gallery")

            Text("\(model.width) × \(model.height)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)

            divider

            // Zoom
            HStack(spacing: 2) {
                Button { viewport.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘-)")
                Button {
                    viewport.zoomToFitCurrent(canvasWidth: model.width, height: model.height)
                } label: {
                    Text("\(Int((viewport.zoom * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(width: 44)
                }
                .help("Zoom to fit (⌘0)")
                Button { viewport.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)")
            }
            .buttonStyle(.plain)
            .foregroundColor(StudioTheme.textSecondary)

            divider

            // History
            HStack(spacing: 2) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.document.canUndo)
                    .help("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.document.canRedo)
                    .help("Redo (⇧⌘Z)")
            }
            .buttonStyle(.plain)
            .foregroundColor(StudioTheme.textPrimary)

            divider

            // Canvas aids
            HStack(spacing: 2) {
                Toggle(isOn: $viewport.showGrid) {
                    Image(systemName: "grid")
                }
                .help("Pixel grid (G)")
                Toggle(isOn: $viewport.onionSkin) {
                    Image(systemName: "circle.dashed.inset.filled")
                }
                .help("Onion skin")
            }
            .toggleStyle(.button)
            .foregroundColor(StudioTheme.textSecondary)

            divider

            // Export
            Menu {
                ForEach([1, 2, 4, 8], id: \.self) { scale in
                    Button("PNG at \(scale)× (\(model.width * scale) × \(model.height * scale))") {
                        model.exportPNG(scale: scale)
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(StudioTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("Export frame as PNG")

            divider

            // Panels
            Button { showPanel.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(showPanel ? StudioTheme.accent : StudioTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Color & layers panel")

            Button { showAI = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text("AI")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioTheme.accentSoft))
                .foregroundColor(StudioTheme.accent)
            }
            .buttonStyle(.plain)
            .help("Open the assistant")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .studioPill()
    }

    private var divider: some View {
        Rectangle()
            .fill(StudioTheme.hairline)
            .frame(width: 1, height: 18)
    }
}
