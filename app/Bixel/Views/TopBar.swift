// TopBar.swift
//
// Procreate-style top navigation bar:
// - Left group: Gallery, Actions (wrench), Adjustments/AI (wand), Selection (lasso), Transform (arrow)
// - Right group: Brush, Smudge, Eraser, Layers (square layers icon with blue highlight), Color disc swatch

import SwiftUI

struct TopBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport
    let projectName: String
    let onShowProjects: () -> Void
    var onGoHome: (() -> Void)? = nil
    @Binding var showLayers: Bool
    @Binding var showColor: Bool
    @Binding var showAI: Bool
    @Binding var showTimeline: Bool
    var onNewDocument: (() -> Void)? = nil

    @State private var showActions = false

    var body: some View {
        HStack {
            // LEFT CLUSTER: Home, Wrench, AI Chat, Selection, Transform
            HStack(spacing: 14) {
                // Home button with Bixel Slime logo
                Button {
                    if let onGoHome { onGoHome() } else { onShowProjects() }
                } label: {
                    HStack(spacing: 6) {
                        BixelSlimeLogo(size: 18)
                        Text("Home")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .help("Return to Bixel Home Gallery")

                // Actions (Wrench)
                Button {
                    showActions.toggle()
                } label: {
                    Image(systemName: "wrench")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(showActions ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Actions & Canvas settings")
                .popover(isPresented: $showActions, arrowEdge: .bottom) {
                    ActionsPopover(
                        model: model,
                        viewport: viewport,
                        showTimeline: $showTimeline,
                        onShowProjects: onShowProjects,
                        onNewDocument: onNewDocument
                    )
                }

                // AI Copilot (Wand)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAI.toggle()
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(showAI ? StudioTheme.bixelGreen : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(
                            showAI ? RoundedRectangle(cornerRadius: 6).fill(StudioTheme.bixelGreenSoft) : nil
                        )
                }
                .buttonStyle(.plain)
                .help("AI Copilot & Adjustments")

                // Selection (Lasso)
                Button {
                    model.selectTool((model.tool == .selection) ? .pencil : .selection)
                } label: {
                    Image(systemName: "lasso")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(model.tool == .selection ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Selection tool")

                // Transform
                Button {
                    model.selectTool((model.tool == .transform) ? .pencil : .transform)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(model.tool == .transform ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Transform tool")
            }

            Spacer()

            // CENTER: Project Title & Dimensions
            HStack(spacing: 8) {
                Text(projectName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("\(model.width) × \(model.height)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.white.opacity(0.06))
                    )
            }

            Spacer()
            HStack(spacing: 16) {
                // Brush (Paint)
                Button {
                    model.selectTool(.pencil)
                } label: {
                    Image(systemName: "paintbrush.pointed")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(model.tool == .pencil ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Paint brush")

                // Smudge
                Button {
                    model.selectTool(.smudge)
                } label: {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(model.tool == .smudge ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Smudge tool")

                // Eraser
                Button {
                    model.selectTool(.eraser)
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(model.tool == .eraser ? StudioTheme.accent : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Eraser")

                // Layers button (Vibrant blue highlight when open!)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showLayers.toggle()
                        if showLayers { showColor = false }
                    }
                } label: {
                    Image(systemName: "square.2.layers.3d")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(showLayers ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(
                            showLayers ? RoundedRectangle(cornerRadius: 6).fill(StudioTheme.accentSoft) : nil
                        )
                }
                .buttonStyle(.plain)
                .help("Layers panel")

                // Color Circle Button
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showColor.toggle()
                        if showColor { showLayers = false }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(currentColor)
                            .frame(width: 24, height: 24)
                        Circle()
                            .strokeBorder(showColor ? StudioTheme.procreateBlue : Color.white.opacity(0.35), lineWidth: showColor ? 2.5 : 1)
                            .frame(width: 26, height: 26)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Colors")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(StudioTheme.procreateGlass))
                .overlay(
                    Rectangle()
                        .fill(StudioTheme.hairline)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private var currentColor: Color {
        Color(
            red: Double(model.currentColor.r) / 255,
            green: Double(model.currentColor.g) / 255,
            blue: Double(model.currentColor.b) / 255
        )
    }
}

// MARK: - Actions Popover (Wrench menu)

struct ActionsPopover: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var viewport: CanvasViewport
    @Binding var showTimeline: Bool
    let onShowProjects: () -> Void
    var onNewDocument: (() -> Void)?

    @State private var tab: ActionTab = .canvas

    enum ActionTab: String, CaseIterable {
        case canvas = "Canvas"
        case share = "Share"
        case project = "Project"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tab Picker
            Picker("", selection: $tab) {
                ForEach(ActionTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Divider().overlay(StudioTheme.hairline)

            switch tab {
            case .canvas:
                VStack(alignment: .leading, spacing: 10) {
                    // Animation assist (Timeline toggle)
                    Toggle(isOn: $showTimeline) {
                        Label("Animation Assist", systemImage: "film")
                    }
                    .toggleStyle(.switch)

                    // Pixel Grid toggle
                    Toggle(isOn: $viewport.showGrid) {
                        Label("Drawing Guide / Grid", systemImage: "grid")
                    }
                    .toggleStyle(.switch)

                    // Onion Skin toggle
                    Toggle(isOn: $viewport.onionSkin) {
                        Label("Onion Skin", systemImage: "circle.dashed.inset.filled")
                    }
                    .toggleStyle(.switch)

                    if viewport.onionSkin {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Ghost Opacity")
                                    .font(.caption)
                                    .foregroundColor(StudioTheme.textSecondary)
                                Spacer()
                                Text("\(Int((viewport.onionOpacity * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                            }
                            Slider(value: $viewport.onionOpacity, in: 0.1...0.8)
                                .controlSize(.mini)
                        }
                        .padding(.leading, 8)
                    }

                    Divider().overlay(StudioTheme.hairline)

                    // Canvas dimensions
                    HStack {
                        Label("Canvas Size", systemImage: "aspectratio")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(model.width) × \(model.height)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(StudioTheme.textSecondary)
                    }

                    // Zoom controls
                    HStack(spacing: 8) {
                        Button { viewport.zoomOut() } label: { Label("Zoom -", systemImage: "minus.magnifyingglass") }
                            .controlSize(.small)
                        Button {
                            viewport.zoomToFitCurrent(canvasWidth: model.width, height: model.height)
                        } label: {
                            Text("\(Int((viewport.zoom * 100).rounded()))%")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .controlSize(.small)
                        Button { viewport.zoomIn() } label: { Label("Zoom +", systemImage: "plus.magnifyingglass") }
                            .controlSize(.small)
                    }
                }

            case .share:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Share Image")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(StudioTheme.textSecondary)

                    ForEach([1, 2, 4, 8], id: \.self) { scale in
                        Button {
                            model.exportPNG(scale: scale)
                        } label: {
                            HStack {
                                Label("PNG (\(scale)×)", systemImage: "photo")
                                Spacer()
                                Text("\(model.width * scale) × \(model.height * scale)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(StudioTheme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }

                    Divider().overlay(StudioTheme.hairline)

                    Button {
                        model.exportSpriteSheet()
                    } label: {
                        Label("Animated Sprite Sheet…", systemImage: "square.grid.3x2")
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }

            case .project:
                VStack(alignment: .leading, spacing: 10) {
                    if let onNew = onNewDocument {
                        Button {
                            onNew()
                        } label: {
                            Label("New Document…", systemImage: "plus.square")
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onShowProjects()
                    } label: {
                        Label("Project Gallery", systemImage: "square.grid.3x3")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 250)
    }
}
