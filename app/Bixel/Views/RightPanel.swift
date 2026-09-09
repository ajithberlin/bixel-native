// RightPanel.swift
//
// Floating right panel: brush settings on top, then "Color" (disc + preset
// swatches) and "Layers" tabs. Layer rows show a live thumbnail, support
// drag-to-reorder, inline rename (double-click or context menu), visibility
// toggles, and a per-layer opacity slider.

import SwiftUI

struct RightPanel: View {
    @ObservedObject var model: EditorModel
    @State private var tab: Tab = .color

    enum Tab: String, CaseIterable {
        case color = "Color"
        case layers = "Layers"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Brush
            VStack(spacing: 8) {
                StudioSlider(icon: "circle.lefthalf.filled", value: $model.brushSize, range: 1...32)
                StudioSlider(icon: "drop.halffull", value: $model.opacity, range: 0...1)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider().overlay(StudioTheme.hairline)

            Group {
                switch tab {
                case .color: colorTab
                case .layers: layersTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 268, height: 540)
        .studioPanel()
    }

    private var colorTab: some View {
        VStack(spacing: 12) {
            ColorDisc(color: $model.currentColor)
                .padding(.horizontal, 18)
                .padding(.top, 12)

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color(model.currentColor))
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioTheme.hairlineStrong, lineWidth: 1))
                Text(model.currentColor.hex.uppercased())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 18)

            swatches
        }
    }

    private var swatches: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 8), spacing: 3) {
                ForEach(Array(Palette.rgba(.db32).enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(c))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(c == model.currentColor ? Color.white : Color.white.opacity(0.12), lineWidth: c == model.currentColor ? 2 : 0.5)
                        )
                        .onTapGesture { model.currentColor = c }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Layers

    private var layersTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LAYERS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(StudioTheme.textSecondary)
                Text("\(model.layers.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(StudioTheme.textDisabled)
                Spacer()
                Button { model.addLayer() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundColor(StudioTheme.textPrimary)
                    .help("Add layer")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 4) {
                    // Topmost layer first.
                    ForEach(model.layers.reversed()) { layer in
                        LayerRow(
                            layer: layer,
                            selected: layer.index == model.activeLayer,
                            thumbnail: model.layerThumbnail(layer.index),
                            thumbWidth: model.width,
                            thumbHeight: model.height,
                            canDelete: model.layers.count > 1,
                            onSelect: { model.activeLayer = layer.index },
                            onToggle: { model.toggleLayerVisibility(layer.index) },
                            onRename: { model.renameLayer(layer.index, name: $0) },
                            onDelete: { model.activeLayer = layer.index; model.deleteLayer() },
                            onMoveHere: { model.moveLayer(from: $0, to: layer.index) }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }

            // Opacity of the active layer.
            if let active = model.layers.first(where: { $0.index == model.activeLayer }) {
                VStack(spacing: 4) {
                    Divider().overlay(StudioTheme.hairline)
                    HStack(spacing: 8) {
                        Text("Opacity")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(StudioTheme.textSecondary)
                        Slider(
                            value: Binding(
                                get: { active.opacity },
                                set: { model.setLayerOpacity(model.activeLayer, $0) }
                            ),
                            in: 0...1
                        )
                        .controlSize(.mini)
                        Text("\(Int((active.opacity * 100).rounded()))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(StudioTheme.textSecondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func color(_ c: BixelColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

// MARK: - Layer row

private struct LayerRow: View {
    let layer: LayerInfo
    let selected: Bool
    let thumbnail: [UInt8]
    let thumbWidth: Int
    let thumbHeight: Int
    let canDelete: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onMoveHere: (Int) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: layer.visible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundColor(layer.visible ? StudioTheme.textPrimary : StudioTheme.textDisabled)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(layer.visible ? "Hide layer" : "Show layer")

            PixelImageView(image: thumbnail, width: thumbWidth, height: thumbHeight)
                .frame(width: 40, height: 40)
                .background(CheckerboardView(cell: 5))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(StudioTheme.hairlineStrong, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("", text: $draft, onCommit: {
                        onRename(draft)
                        editing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(StudioTheme.textPrimary)
                } else {
                    Text(layer.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            draft = layer.name
                            editing = true
                        }
                }
                if layer.opacity < 1.0 {
                    Text("\(Int((layer.opacity * 100).rounded()))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(StudioTheme.textDisabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? StudioTheme.accentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(dropTargeted ? StudioTheme.accent : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .draggable(String(layer.index))
        .dropDestination(for: String.self, action: { items, _ in
            guard let raw = items.first, let from = Int(raw), from != layer.index else { return false }
            onMoveHere(from)
            return true
        }, isTargeted: { dropTargeted = $0 })
        .contextMenu {
            Button("Rename") {
                draft = layer.name
                editing = true
            }
            Divider()
            Button("Delete Layer", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        }
    }
}

// MARK: - Checkerboard

/// Transparency checkerboard used behind layer/frame thumbnails.
struct CheckerboardView: View {
    var cell: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let light = Color(white: 0.55)
            let dark = Color(white: 0.40)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : -cell
                while x < size.width {
                    context.fill(
                        Path(CGRect(x: x, y: y, width: cell, height: cell)),
                        with: .color(light)
                    )
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}
