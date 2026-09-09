// ToolRail.swift
//
// Procreate-style vertical brush dock floating on the left edge:
// - Top slider: Brush Size
// - Center button: Quick Eyedropper square button
// - Bottom slider: Brush Opacity
// - Attached underneath: Undo and Redo buttons

import SwiftUI

struct LeftBrushDock: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 14) {
            // Main vertical slider capsule
            VStack(spacing: 12) {
                // Brush size slider
                ProcreateVerticalSlider(
                    value: $model.brushSize,
                    range: 1...64,
                    formatValue: { "\(Int($0)) px" },
                    title: "Size"
                )

                // Middle square button (Quick Eyedropper)
                Button {
                    model.selectTool((model.tool == .eyedropper) ? .pencil : .eyedropper)
                } label: {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(model.tool == .eyedropper ? StudioTheme.accent : Color.white.opacity(0.45), lineWidth: 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(model.tool == .eyedropper ? StudioTheme.accentSoft : Color.white.opacity(0.08))
                        )
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Eyedropper tool")

                // Brush opacity slider
                ProcreateVerticalSlider(
                    value: $model.opacity,
                    range: 0...1,
                    formatValue: { "\(Int(($0 * 100).rounded()))%" },
                    title: "Opacity"
                )
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(width: 38)
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(StudioTheme.procreateGlass)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 20, y: 6)

            // Undo & Redo buttons directly underneath the dock
            VStack(spacing: 4) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(model.document.canUndo ? Color.white.opacity(0.85) : Color.white.opacity(0.22))
                        .frame(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!model.document.canUndo)
                .help("Undo (⌘Z)")

                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(model.document.canRedo ? Color.white.opacity(0.85) : Color.white.opacity(0.22))
                        .frame(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!model.document.canRedo)
                .help("Redo (⇧⌘Z)")
            }
        }
    }
}

/// Backward compatibility alias for any existing references
typealias ToolRail = LeftBrushDock
typealias BrushSliders = LeftBrushDock

// MARK: - Procreate Vertical Slider

struct ProcreateVerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let formatValue: (Double) -> String
    let title: String

    @State private var isDragging = false

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let thumbHeight: CGFloat = 8
            let thumbWidth: CGFloat = 18
            let travel = max(1, trackHeight - thumbHeight)
            let thumbY = (1 - fraction) * travel

            ZStack(alignment: .top) {
                // Background Track
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 22, height: trackHeight)

                // Fill level
                VStack {
                    Spacer()
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 22, height: max(6, trackHeight * fraction))
                }
                .frame(width: 22, height: trackHeight)
                .clipShape(Capsule(style: .continuous))

                // Draggable Thumb Knob
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(y: thumbY)
            }
            .frame(width: geo.size.width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let clampedY = min(max(g.location.y - thumbHeight / 2, 0), travel)
                        let f = 1 - clampedY / travel
                        value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .overlay(alignment: .trailing) {
                if isDragging {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.6))
                        Text(formatValue(value))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(white: 0.12).opacity(0.92))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
                    .fixedSize()
                    .offset(x: 82, y: thumbY - trackHeight / 2 + thumbHeight / 2)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 24, height: 74)
    }
}
