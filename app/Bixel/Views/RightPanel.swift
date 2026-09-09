// RightPanel.swift
//
// Floating right panel: brush settings on top, then "Color" (disc + preset
// swatches) and "Layers" tabs. Layers support inline rename (double-click).

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
        .frame(width: 260, height: 520)
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

    private var layersTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LAYERS").font(.system(size: 10, weight: .semibold)).foregroundColor(StudioTheme.textSecondary)
                Spacer()
                Button { model.addLayer() } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                    .foregroundColor(StudioTheme.textPrimary)
                    .help("Add layer")
                Button { model.deleteLayer() } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    .foregroundColor(model.document.layerCount > 1 ? StudioTheme.textPrimary : StudioTheme.textDisabled)
                    .disabled(model.document.layerCount <= 1)
                    .help("Delete layer")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 4) {
                    // Topmost layer first.
                    ForEach(model.layers.reversed()) { layer in
                        LayerRow(
                            name: layer.name,
                            visible: layer.visible,
                            selected: layer.index == model.activeLayer,
                            onSelect: { model.activeLayer = layer.index },
                            onToggle: { model.toggleLayerVisibility(layer.index) },
                            onRename: { model.renameLayer(layer.index, name: $0) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private func color(_ c: BixelColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

private struct LayerRow: View {
    let name: String
    let visible: Bool
    let selected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onRename: (String) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: visible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundColor(visible ? StudioTheme.textPrimary : StudioTheme.textDisabled)
            }
            .buttonStyle(.plain)

            if editing {
                TextField("", text: $draft, onCommit: {
                    onRename(draft)
                    editing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(StudioTheme.textPrimary)
            } else {
                Text(name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draft = name
                        editing = true
                    }
                    .onTapGesture(count: 1, perform: onSelect)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? StudioTheme.accentSoft : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
