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
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Selection Tool", shortcut: "V", details: "Switch to rectangular or lasso marquee selection", isSelected: model.tool == .selection)
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button { model.selectTool(.transform) } label: { Label("Transform", systemImage: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Transform Tool", shortcut: "T", details: "Engage bounding box handles to move, scale, and rotate", isSelected: model.tool == .transform)
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Freeform") { model.snapping = false; model.uniformTransform = false }
                .buttonStyle(.plain)
                .foregroundColor(!model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Freeform Transform", details: "Scale width and height independently without locked proportions")
            Button("Uniform") { model.snapping = true; model.uniformTransform = true }
                .buttonStyle(.plain)
                .foregroundColor(model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Uniform Transform", details: "Lock aspect ratio while scaling to maintain sprite proportions")
            Button { model.rotateSelection() } label: { Label("Rotate 90°", systemImage: "rotate.right") }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Rotate 90°", details: "Rotate the current selection clockwise by 90 degrees")
            Divider().frame(height: 22).padding(.horizontal, 8)
            Toggle("Snapping", isOn: $model.snapping).toggleStyle(.button)
                .help("Pixel Grid Snapping\nSnap transform corner coordinates to integer pixel boundaries")
            Button("Fit to Canvas") { model.fitSelectionToCanvas() }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Fit to Canvas", details: "Scale the selection to fit document canvas dimensions")
            Button { model.resetTransform() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Reset Transform", details: "Discard all rotation and scaling applied to the selection")
            if let rect = model.transformRect {
                Divider().frame(height: 22).padding(.horizontal, 8)
                Text("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                    .help("Current transform bounds width and height in pixels")
            }
        }
    }

    private func floatingImportControls(_ image: FloatingImageImport) -> some View {
        let size = image.geometry.size
        return HStack(spacing: 0) {
            Label("Floating", systemImage: "square.dashed.inset.filled")
                .padding(.horizontal, 4)
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Freeform") { model.snapping = false; model.uniformTransform = false }
                .buttonStyle(.plain)
                .foregroundColor(!model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Freeform Scaling", details: "Scale imported image dimensions freely")
            Button("Uniform") { model.snapping = true; model.uniformTransform = true }
                .buttonStyle(.plain)
                .foregroundColor(model.uniformTransform ? StudioTheme.accent : StudioTheme.textSecondary)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Uniform Scaling", details: "Constrain aspect ratio of imported image")
            Button { rotateFloatingImport90() } label: { Label("Rotate 90°", systemImage: "rotate.right") }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .toolHoverEffect(name: "Rotate 90°", details: "Rotate imported image 90 degrees clockwise")
            Divider().frame(height: 22).padding(.horizontal, 8)
            Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)
                .help("Pending import dimensions in pixels")
            Divider().frame(height: 22).padding(.horizontal, 8)
            Button("Place") { model.commitFloatingImport() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .toolHoverEffect(name: "Place Image (Return)", details: "Commit floating image permanently to active layer")
            Button("Cancel", role: .cancel) { model.cancelFloatingImport() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .toolHoverEffect(name: "Cancel Import (Esc)", details: "Discard pending imported image without placing")
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
