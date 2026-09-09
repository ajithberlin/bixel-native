import SwiftUI

struct SelectionTransformToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            Button { model.tool = .selection } label: { Label("Select", systemImage: "rectangle.dashed") }
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button { model.tool = .transform } label: { Label("Transform", systemImage: "arrow.up.left.and.arrow.down.right") }
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Freeform") { model.tool = .transform }
                .foregroundColor(model.tool == .transform ? StudioTheme.accent : StudioTheme.textSecondary)
            Button("Uniform") { model.snapping = true }
            Button { model.rotateSelection() } label: { Label("Rotate 90°", systemImage: "rotate.right") }
            Divider().frame(height: 22).padding(.horizontal, 8)
            Toggle("Snapping", isOn: $model.snapping).toggleStyle(.button)
            Button("Fit to Canvas") { model.fitSelectionToCanvas() }
            Button { model.resetTransform() } label: { Image(systemName: "arrow.counterclockwise") }.help("Reset transform")
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Cancel") { model.clearSelection() }
            Button("Apply") { model.commitTransform() }.buttonStyle(.borderedProminent)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(StudioTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

struct SelectionOverlay: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport

    var body: some View {
        GeometryReader { geometry in
            if let rect = model.transformRect ?? model.selectionRect, model.tool == .selection || model.tool == .transform {
                let origin = viewport.artboardOrigin(viewSize: geometry.size, canvasWidth: model.width, height: model.height)
                let frame = CGRect(x: origin.x + rect.minX * viewport.zoom,
                                   y: origin.y + (CGFloat(model.height) - rect.maxY) * viewport.zoom,
                                   width: rect.width * viewport.zoom,
                                   height: rect.height * viewport.zoom)
                ZStack(alignment: .topLeading) {
                    Path { path in path.addRect(frame) }
                        .stroke(StudioTheme.accent, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    if model.tool == .transform {
                        ForEach(corners(of: frame), id: \.self) { point in
                            Circle().fill(.white).frame(width: 8, height: 8).position(point)
                                .overlay(Circle().stroke(StudioTheme.accent, lineWidth: 1))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }
}
