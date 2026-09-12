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

    @State private var hoveredLayerIndex: Int? = nil
    @State private var draggingLayerIndex: Int? = nil
    @State private var draggingUIIndex: Int? = nil
    @State private var dragTranslationY: CGFloat = 0
    @State private var targetUIIndex: Int? = nil

    private let rowHeight: CGFloat = 56
    private let rowSpacing: CGFloat = 6
    private var rowStep: CGFloat { rowHeight + rowSpacing }

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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: rowSpacing) {
                        ForEach(Array(model.layers.reversed().enumerated()), id: \.element.id) { uiIndex, layer in
                            let isSelected = layer.index == model.activeLayer
                            let isHovered = hoveredLayerIndex == layer.index && draggingLayerIndex == nil
                            let isDragging = draggingLayerIndex == layer.index
                            let isDropSlot = draggingLayerIndex != nil && targetUIIndex == uiIndex && draggingUIIndex != uiIndex

                            ZStack {
                                // Drop target slot indicator (anchored at unshifted slot position)
                                if isDropSlot {
                                    LayerDropSlotIndicator()
                                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                                }

                                ProcreateLayerRow(
                                    layer: layer,
                                    selected: isSelected,
                                    isHovered: isHovered,
                                    isDragging: isDragging,
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
                                    onSetBlendMode: { mode in model.setLayerBlendMode(layer.index, mode) },
                                    onSetOpacity: { val in model.setLayerOpacity(layer.index, val) }
                                )
                                .offset(y: rowOffsetY(for: uiIndex, layerIndex: layer.index))
                                .scaleEffect(isDragging ? 1.025 : (isHovered ? 1.008 : 1.0))
                                .shadow(
                                    color: isDragging ? Color.black.opacity(0.65) : (isHovered ? Color.black.opacity(0.35) : Color.clear),
                                    radius: isDragging ? 10 : (isHovered ? 4 : 0),
                                    x: 0,
                                    y: isDragging ? 6 : (isHovered ? 2 : 0)
                                )
                                .zIndex(rowZIndex(for: uiIndex, layerIndex: layer.index))
                            }
                            .frame(height: rowHeight)
                            .onHover { hovering in
                                if hovering {
                                    if draggingLayerIndex == nil {
                                        hoveredLayerIndex = layer.index
                                    }
                                } else if hoveredLayerIndex == layer.index {
                                    hoveredLayerIndex = nil
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 3)
                                    .onChanged { value in
                                        handleDragChanged(uiIndex: uiIndex, layerIndex: layer.index, value: value, proxy: proxy)
                                    }
                                    .onEnded { value in
                                        handleDragEnded(uiIndex: uiIndex, layerIndex: layer.index, value: value)
                                    }
                            )
                            .onTapGesture {
                                model.activeLayer = layer.index
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.layerIDs)
                }
                .frame(maxHeight: 380)
            }

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

    private func rowOffsetY(for uiIndex: Int, layerIndex: Int) -> CGFloat {
        guard let draggingLayer = draggingLayerIndex, let sourceUI = draggingUIIndex else {
            if hoveredLayerIndex == layerIndex {
                return -2
            }
            return 0
        }

        if layerIndex == draggingLayer {
            return dragTranslationY
        }

        guard let targetUI = targetUIIndex else { return 0 }

        if sourceUI < targetUI {
            if uiIndex > sourceUI && uiIndex <= targetUI {
                return -rowStep
            }
        } else if sourceUI > targetUI {
            if uiIndex >= targetUI && uiIndex < sourceUI {
                return rowStep
            }
        }

        return 0
    }

    private func rowZIndex(for uiIndex: Int, layerIndex: Int) -> Double {
        if draggingLayerIndex == layerIndex {
            return 100
        }
        if hoveredLayerIndex == layerIndex {
            return 10
        }
        return 1
    }

    private func handleDragChanged(uiIndex: Int, layerIndex: Int, value: DragGesture.Value, proxy: ScrollViewProxy) {
        guard model.layers.count > 1 else { return }

        if draggingLayerIndex == nil {
            draggingLayerIndex = layerIndex
            draggingUIIndex = uiIndex
            targetUIIndex = uiIndex
            hoveredLayerIndex = nil
        }
        dragTranslationY = value.translation.height

        let deltaSlots = Int(round(value.translation.height / rowStep))
        let rawTarget = uiIndex + deltaSlots
        let newTargetUI = min(max(rawTarget, 0), model.layers.count - 1)

        if newTargetUI != targetUIIndex {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                targetUIIndex = newTargetUI
            }
            let reversedLayers = Array(model.layers.reversed())
            if reversedLayers.indices.contains(newTargetUI) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(reversedLayers[newTargetUI].id, anchor: .center)
                }
            }
        }
    }

    private func handleDragEnded(uiIndex: Int, layerIndex: Int, value: DragGesture.Value) {
        guard let sourceLayer = draggingLayerIndex, let sourceUI = draggingUIIndex else {
            model.activeLayer = layerIndex
            return
        }
        let targetUI = targetUIIndex ?? sourceUI

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            if sourceUI != targetUI {
                let targetLayer = (model.layers.count - 1) - targetUI
                model.moveLayer(from: sourceLayer, to: targetLayer)
            } else {
                model.activeLayer = sourceLayer
            }
            draggingLayerIndex = nil
            draggingUIIndex = nil
            targetUIIndex = nil
            dragTranslationY = 0
            hoveredLayerIndex = nil
        }
    }
}

private struct LayerDropSlotIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(StudioTheme.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(StudioTheme.accent.opacity(0.12))
            )
            .frame(height: 56)
            .overlay(
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 11, weight: .bold))
                    Text("Drop layer here")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(StudioTheme.accent.opacity(0.85))
            )
    }
}

// MARK: - Procreate Layer Row

struct ProcreateLayerRow: View {
    let layer: LayerInfo
    let selected: Bool
    let isHovered: Bool
    let isDragging: Bool
    let thumbnail: CGImage?
    let thumbWidth: Int
    let thumbHeight: Int
    let canDelete: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onSetBlendMode: (String) -> Void
    let onSetOpacity: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
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
            .highPriorityGesture(TapGesture().onEnded {
                showBlendPopover = true
            })
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
            .highPriorityGesture(TapGesture().onEnded {
                onToggle()
            })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? StudioTheme.procreateBlue : (isHovered ? Color(white: 0.22, opacity: 0.75) : Color(white: 0.17, opacity: 0.65)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isDragging ? StudioTheme.accent : (selected ? Color.white.opacity(0.25) : (isHovered ? Color.white.opacity(0.18) : Color.clear)),
                    lineWidth: isDragging ? 2 : 1
                )
        )
        .contentShape(Rectangle())
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
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isDragging)
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
