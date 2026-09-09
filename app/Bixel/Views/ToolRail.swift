// ToolRail.swift
//
// Floating left capsule: tool selection, a brush-size preview dot, and the
// brush size / opacity sliders, Procreate-style.

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

            Rectangle()
                .fill(StudioTheme.hairline)
                .frame(width: 28, height: 1)
                .padding(.vertical, 4)

            // Brush size preview
            Circle()
                .fill(StudioTheme.textPrimary.opacity(0.85))
                .frame(width: max(3, min(22, CGFloat(model.brushSize))), height: max(3, min(22, CGFloat(model.brushSize))))
                .frame(width: 24, height: 24)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(width: 60)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(StudioTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
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
                    .font(.system(size: 17, weight: .medium))
                Text(tool.label)
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(selected ? StudioTheme.accent : StudioTheme.textSecondary)
            .frame(width: 48, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? StudioTheme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(tool.label)
    }
}
