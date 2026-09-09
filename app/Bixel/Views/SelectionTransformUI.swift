import SwiftUI

struct SelectionTransformToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            Button { model.selectTool(.selection) } label: { Label("Select", systemImage: "rectangle.dashed") }
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button { model.selectTool(.transform) } label: { Label("Transform", systemImage: "arrow.up.left.and.arrow.down.right") }
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Freeform") { model.snapping = false; model.uniformTransform = false }
                .foregroundColor(!model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
            Button("Uniform") { model.snapping = true; model.uniformTransform = true }
                .foregroundColor(model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
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
