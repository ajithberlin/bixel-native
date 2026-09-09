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

// MARK: - Vertical brush sliders

/// Procreate-style pair of vertical sliders: brush size and opacity, floating
/// next to the tool rail so size adjustments are always one drag away.
struct BrushSliders: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            VerticalSlider(
                icon: "circle.lefthalf.filled",
                value: $model.brushSize,
                range: 1...32,
                label: "\(Int(model.brushSize))px"
            )
            VerticalSlider(
                icon: "drop.halffull",
                value: $model.opacity,
                range: 0...1,
                label: "\(Int((model.opacity * 100).rounded()))%"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(height: 190)
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

private struct VerticalSlider: View {
    let icon: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(StudioTheme.textSecondary)

            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(StudioTheme.accent.opacity(0.85))
                        .frame(height: max(6, geo.size.height * fraction))
                }
                .frame(width: 7)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        let f = min(max(1 - g.location.y / geo.size.height, 0), 1)
                        value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                    }
                )
            }

            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)
        }
        .frame(width: 22)
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
