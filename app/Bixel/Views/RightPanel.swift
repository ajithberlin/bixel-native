// RightPanel.swift
//
// Procreate-style floating panels:
// - LayersPopover: Matching Procreate's signature layers card (blue active highlight,
//   thumbnails, blend mode buttons, square checkboxes, and background color row).
// - ColorPopover: Procreate color disc (hue ring + SV square) and palette swatches.

import SwiftUI

// MARK: - Procreate Layers Popover

struct LayersPopover: View {
    @ObservedObject var model: EditorModel
    @State private var showBgColorPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header: "Layers" + "+"
            HStack {
                Text("Layers")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.92))
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.addLayer() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Add layer")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Scrollable Layer rows
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.layers.reversed()) { layer in
                        ProcreateLayerRow(
                            layer: layer,
                            selected: layer.index == model.activeLayer,
                            thumbnail: model.layerThumbnailCGImage(layer.index),
                            thumbWidth: model.width,
                            thumbHeight: model.height,
                            canDelete: model.layers.count > 1,
                            onSelect: { model.activeLayer = layer.index },
                            onToggle: { model.toggleLayerVisibility(layer.index) },
                            onRename: { model.renameLayer(layer.index, name: $0) },
                            onDelete: {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    model.activeLayer = layer.index
                                    model.deleteLayer()
                                }
                            },
                            onDuplicate: {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    model.duplicateLayer(layer.index)
                                }
                            },
                            onMoveHere: { from in
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    model.moveLayer(from: from, to: layer.index)
                                }
                            },
                            onSetBlendMode: { mode in model.setLayerBlendMode(layer.index, mode) },
                            onSetOpacity: { val in model.setLayerOpacity(layer.index, val) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 380)

            Divider().overlay(StudioTheme.hairline)

            // Bottom row: "Background color"
            HStack(spacing: 12) {
                // Background color swatch
                Button {
                    showBgColorPicker = true
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bgColor)
                        .frame(width: 44, height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showBgColorPicker, arrowEdge: .leading) {
                    VStack(spacing: 10) {
                        Text("Background Color")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(StudioTheme.textPrimary)
                        ColorDisc(color: $model.canvasBackgroundColor)
                            .frame(width: 180, height: 180)
                    }
                    .padding(14)
                    .frame(width: 210)
                }

                Text("Background color")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.85))

                Spacer()

                ProcreateCheckbox(
                    isChecked: model.showBackgroundColor,
                    isOnBlue: false,
                    action: { model.showBackgroundColor.toggle() }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 290)
        .procreatePanel(radius: 16)
    }

    private var bgColor: Color {
        Color(
            red: Double(model.canvasBackgroundColor.r) / 255,
            green: Double(model.canvasBackgroundColor.g) / 255,
            blue: Double(model.canvasBackgroundColor.b) / 255
        )
    }
}

// MARK: - Procreate Layer Row

struct ProcreateLayerRow: View {
    let layer: LayerInfo
    let selected: Bool
    let thumbnail: CGImage?
    let thumbWidth: Int
    let thumbHeight: Int
    let canDelete: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onMoveHere: (Int) -> Void
    let onSetBlendMode: (String) -> Void
    let onSetOpacity: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var showBlendPopover = false

    var body: some View {
        HStack(spacing: 10) {
            // Layer Thumbnail
            PixelImageView(cgImage: thumbnail, width: thumbWidth, height: thumbHeight)
                .frame(width: 42, height: 42)
                .background(CheckerboardView(cell: 5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selected ? Color.white.opacity(0.3) : StudioTheme.hairlineStrong, lineWidth: 1)
                )

            // Title & optional subtitle
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("", text: $draft, onCommit: {
                        onRename(draft)
                        editing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(selected ? .white : StudioTheme.textPrimary)
                } else {
                    Text(layer.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .white : Color.white.opacity(0.88))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            draft = layer.name
                            editing = true
                        }
                }

                if let sub = layer.subtitle {
                    Text(sub)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(selected ? Color.white.opacity(0.8) : Color.white.opacity(0.45))
                }
            }

            Spacer(minLength: 4)

            // Blend Mode Letter ("N", "M", etc.)
            Button {
                showBlendPopover = true
            } label: {
                Text(layer.blendLetter)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(selected ? .white : Color.white.opacity(0.65))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showBlendPopover, arrowEdge: .trailing) {
                BlendModeAndOpacityPicker(
                    blendMode: layer.blendMode,
                    opacity: layer.opacity,
                    onSelectMode: {
                        onSetBlendMode($0)
                        showBlendPopover = false
                    },
                    onSelectOpacity: onSetOpacity
                )
            }

            // Visibility Checkbox
            ProcreateCheckbox(
                isChecked: layer.visible,
                isOnBlue: selected,
                action: onToggle
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? StudioTheme.procreateBlue : Color(white: 0.17, opacity: 0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(dropTargeted ? Color.white : (selected ? Color.white.opacity(0.2) : Color.clear), lineWidth: 1.5)
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
            Button("Duplicate", action: onDuplicate)
            Divider()
            Button("Delete Layer", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        }
    }
}

// MARK: - Blend Mode & Opacity Picker

struct BlendModeAndOpacityPicker: View {
    let blendMode: String
    let opacity: Double
    let onSelectMode: (String) -> Void
    let onSelectOpacity: (Double) -> Void

    let modes = [
        "Normal", "Multiply", "Screen", "Overlay",
        "Darken", "Lighten", "Color Dodge", "Addition", "Difference"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Opacity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opacity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(StudioTheme.textSecondary)
                    Spacer()
                    Text("\(Int((opacity * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(StudioTheme.textPrimary)
                }
                Slider(value: Binding(get: { opacity }, set: onSelectOpacity), in: 0...1)
                    .controlSize(.small)
            }

            Divider().overlay(StudioTheme.hairline)

            // Blend modes list
            Text("Blend Mode")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(StudioTheme.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(modes, id: \.self) { mode in
                        Button {
                            onSelectMode(mode)
                        } label: {
                            HStack {
                                Text(mode)
                                    .font(.system(size: 12))
                                    .foregroundColor(mode.lowercased() == blendMode.lowercased() ? StudioTheme.accent : StudioTheme.textPrimary)
                                Spacer()
                                if mode.lowercased() == blendMode.lowercased() {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(StudioTheme.accent)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(mode.lowercased() == blendMode.lowercased() ? StudioTheme.accentSoft : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
        .frame(width: 190)
    }
}

// MARK: - Procreate Color Popover

struct ColorPopover: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            ColorDisc(color: $model.currentColor)
                .frame(width: 200, height: 200)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: Double(model.currentColor.r)/255, green: Double(model.currentColor.g)/255, blue: Double(model.currentColor.b)/255))
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))
                Text(model.currentColor.hex.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 16)

            // Swatches grid
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                    ForEach(Array(Palette.rgba(.db32).enumerated()), id: \.offset) { _, c in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(red: Double(c.r)/255, green: Double(c.g)/255, blue: Double(c.b)/255))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(c == model.currentColor ? Color.white : Color.white.opacity(0.12), lineWidth: c == model.currentColor ? 2 : 0.5)
                            )
                            .onTapGesture { model.currentColor = c }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 140)
        }
        .frame(width: 260)
        .procreatePanel(radius: 16)
    }
}

// MARK: - Backwards-compatible RightPanel

struct RightPanel: View {
    @ObservedObject var model: EditorModel
    @State private var tab: Tab = .layers

    enum Tab: String, CaseIterable {
        case layers = "Layers"
        case color = "Color"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(StudioTheme.hairline)

            Group {
                switch tab {
                case .layers: LayersPopover(model: model)
                case .color: ColorPopover(model: model)
                }
            }
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
