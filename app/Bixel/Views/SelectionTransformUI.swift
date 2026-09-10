import SwiftUI

struct SelectionTransformToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Group {
            if let image = model.floatingImport {
                floatingImportControls(image)
            } else {
                selectionControls
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(StudioTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private var selectionControls: some View {
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
            if let rect = model.transformRect {
                Divider().frame(height: 22).padding(.horizontal, 8)
                Text("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                    .help("Current transform bounds")
            }
        }
    }

    private func floatingImportControls(_ image: FloatingImageImport) -> some View {
        let size = image.geometry.size
        return HStack(spacing: 0) {
            Label("Floating", systemImage: "square.dashed.inset.filled")
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Freeform") { model.snapping = false; model.uniformTransform = false }
                .foregroundColor(!model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
            Button("Uniform") { model.snapping = true; model.uniformTransform = true }
                .foregroundColor(model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
            Button { rotateFloatingImport90() } label: { Label("Rotate 90°", systemImage: "rotate.right") }
            Divider().frame(height: 22).padding(.horizontal, 8)
            Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)
                .help("Pending import dimensions")
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Place") { model.commitFloatingImport() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Cancel", role: .cancel) { model.cancelFloatingImport() }
                .keyboardShortcut(.escape, modifiers: [])
        }
    }

    /// Reuse the model's continuous rotation gesture API so toolbar rotation
    /// remains a non-destructive floating transform until the user places it.
    private func rotateFloatingImport90() {
        guard let image = model.floatingImport else { return }
        model.beginFloatingRotation(x: image.center.x + 1, y: image.center.y)
        model.updateFloatingRotation(x: image.center.x, y: image.center.y + 1)
        model.endFloatingRotation(commit: true)
    }
}
