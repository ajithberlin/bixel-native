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
    var viewport: CanvasViewport? = nil

    @State private var isDraggingEyedropper = false

    private var isEyedropperActive: Bool {
        model.tool == .eyedropper || model.eyedropperSession?.isActive == true
    }

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

                // Middle Modify / Eyedropper button (Procreate style)
                modifyButton

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

    private var modifyButton: some View {
        Button {
            model.selectTool((model.tool == .eyedropper) ? .pencil : .eyedropper)
        } label: {
            ZStack {
                // Outer container background
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isEyedropperActive ? StudioTheme.accentSoft : Color.white.opacity(0.08))
                    .frame(width: 24, height: 24)

                // Outer border
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isEyedropperActive ? StudioTheme.accent : Color.white.opacity(0.35),
                        lineWidth: isEyedropperActive ? 1.5 : 1.0
                    )
                    .frame(width: 24, height: 24)

                // Inner rounded rectangle icon (Procreate modify button icon)
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(
                        isEyedropperActive ? StudioTheme.accent : Color.white.opacity(0.65),
                        lineWidth: 1.2
                    )
                    .frame(width: 12, height: 12)
            }
            .shadow(color: isEyedropperActive ? StudioTheme.accent.opacity(0.4) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help("Modify / Eyedropper: tap to toggle or drag onto canvas to pick color")
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("CanvasCoordinateSpace"))
                .onChanged { gesture in
                    isDraggingEyedropper = true
                    guard let viewport else { return }
                    let point = gesture.location
                    let appKitPoint = CGPoint(x: point.x, y: viewport.lastViewSize.height - point.y)
                    if let pixel = viewport.viewToDoc(appKitPoint, viewSize: viewport.lastViewSize,
                                                      width: model.width, height: model.height, clamp: true) {
                        if model.eyedropperSession?.isActive != true {
                            model.startEyedropperSession(at: pixel, viewPosition: point, sourceTool: model.tool)
                        } else {
                            model.updateEyedropperSession(at: pixel, viewPosition: point)
                        }
                    }
                }
                .onEnded { _ in
                    if isDraggingEyedropper {
                        isDraggingEyedropper = false
                        model.commitEyedropperSession()
                    }
                }
        )
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
