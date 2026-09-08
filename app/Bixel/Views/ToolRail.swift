// ToolRail.swift
//
// Left tool rail: tool selection + brush size / opacity sliders, Procreate-style.

import SwiftUI

struct ToolRail: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool, selected: model.tool == tool) {
                    model.tool = tool
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                StudioSlider(icon: "circle.lefthalf.filled", value: $model.brushSize, range: 1...32)
                StudioSlider(icon: "drop.halffull", value: $model.opacity, range: 0...1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .padding(.vertical, 10)
        .frame(width: 64)
        .background(StudioTheme.panel.opacity(0.4))
    }
}

private struct ToolButton: View {
    let tool: Tool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(tool.label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(selected ? StudioTheme.accent : StudioTheme.textSecondary)
            .frame(width: 52, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? StudioTheme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(tool.label)
    }
}
