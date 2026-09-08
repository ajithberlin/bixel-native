// TopBar.swift
//
// Thin top bar: document info, undo/redo, onion-skin toggle and the AI button.

import SwiftUI

struct TopBar: View {
    @ObservedObject var model: EditorModel
    @State private var onionSkin = false
    @Binding var showAI: Bool

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundColor(StudioTheme.accent)
                Text("Bixel")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(StudioTheme.textPrimary)
            }

            Text("\(model.width) × \(model.height)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)

            Spacer()

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.document.canUndo)

            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.document.canRedo)

            Divider().overlay(StudioTheme.hairline).frame(height: 18)

            Toggle(isOn: $onionSkin) {
                Image(systemName: "circle.dashed.inset.filled")
            }
            .toggleStyle(.button)
            .help("Onion skinning")

            Button {
                showAI = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("AI")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(StudioTheme.accentSoft))
                .foregroundColor(StudioTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(StudioTheme.panel.opacity(0.55))
    }
}
