// ProjectPicker.swift
//
// Procreate-style gallery: existing projects as cards, and a "New canvas"
// flow with size templates (sprites, tiles, game screens) plus a custom size.

import SwiftUI

struct CanvasTemplate: Identifiable {
    let id: String
    let name: String
    let detail: String
    let width: Int
    let height: Int
    let icon: String

    /// A size of 0 × 0 marks the custom template.
    var isCustom: Bool { width == 0 }

    static let presets: [CanvasTemplate] = [
        .init(id: "sprite16", name: "Sprite", detail: "16 × 16", width: 16, height: 16, icon: "square.fill"),
        .init(id: "sprite32", name: "Sprite", detail: "32 × 32", width: 32, height: 32, icon: "square.fill"),
        .init(id: "char64", name: "Character", detail: "64 × 64", width: 64, height: 64, icon: "person.fill"),
        .init(id: "scene128", name: "Scene", detail: "128 × 128", width: 128, height: 128, icon: "photo"),
        .init(id: "scene256", name: "Scene HD", detail: "256 × 256", width: 256, height: 256, icon: "photo.fill"),
        .init(id: "tile8", name: "Tile", detail: "8 × 8", width: 8, height: 8, icon: "squareshape.fill"),
        .init(id: "tile16", name: "Tileset", detail: "16 × 16", width: 16, height: 16, icon: "squareshape.split.2x2"),
        .init(id: "gb", name: "Game Boy", detail: "160 × 144", width: 160, height: 144, icon: "gamecontroller"),
        .init(id: "wide320", name: "Game Screen", detail: "320 × 180", width: 320, height: 180, icon: "rectangle.fill"),
        .init(id: "wide640", name: "HD Screen", detail: "640 × 360", width: 640, height: 360, icon: "display"),
        .init(id: "custom", name: "Custom", detail: "Any size", width: 0, height: 0, icon: "slider.horizontal.below.square.filled.and.square"),
    ]
}

struct ProjectPicker: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var assistant: AssistantSession

    init(store: ProjectStore) {
        self.store = store
        self.assistant = store.assistant
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template: CanvasTemplate = CanvasTemplate.presets[1]
    @State private var customWidth = 48
    @State private var customHeight = 48

    private var canvasSize: (width: Int, height: Int) {
        template.isCustom ? (customWidth, customHeight) : (template.width, template.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            newCanvas
            projectGrid
            footer
        }
        .padding(28)
        .frame(width: 780, height: 620)
        .background(StudioTheme.background)
        .onAppear { store.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gallery")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(StudioTheme.textPrimary)
                Text("Your artwork, AI files, and conversations stay together on this device.")
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textSecondary)
            }
            Spacer()
            if store.current != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var newCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.headline)
            Text("A workspace for sprites, animations, tilesets, maps, and references. Choose sizes when you add documents.")
                .font(.caption).foregroundColor(StudioTheme.textSecondary)
            HStack {
                TextField("Project name", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
                Button("Create project", action: create).buttonStyle(.borderedProminent).disabled(!canCreate)
            }
        }
    }

    private var projectGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROJECTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(StudioTheme.textSecondary)

            if store.projects.isEmpty {
                Text("Create a project above to start building your game assets.")
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textDisabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(store.projects) { project in
                            ProjectCard(project: project, isCurrent: project.id == store.current?.id) {
                                store.select(project)
                                if store.current?.id == project.id { dismiss() }
                            }
                            .disabled(assistant.busy)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Saved in Documents / Bixel / Projects")
                .font(.caption)
                .foregroundColor(StudioTheme.textDisabled)
            Spacer()
            if let current = store.current {
                Button("AI Files") {
                    NSWorkspace.shared.open(store.root.appendingPathComponent("\(current.id)/.studio/cache/ai"))
                }
                .font(.caption)
            }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !assistant.busy
            && canvasSize.width >= 1 && canvasSize.height >= 1
            && canvasSize.width <= 4096 && canvasSize.height <= 4096
    }

    private func create() {
        guard canCreate else { return }
        let previous = store.current?.id
        let size = canvasSize
        store.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                     width: size.width, height: size.height)
        if store.current?.id != previous { dismiss() }
    }
}

// MARK: - Cards

private struct TemplateCard: View {
    let template: CanvasTemplate
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    StudioTheme.panelElevated
                    if template.isCustom {
                        Image(systemName: template.icon)
                            .font(.system(size: 20))
                            .foregroundColor(StudioTheme.textSecondary)
                    } else {
                        // Miniature artboard in the template's aspect ratio.
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(StudioTheme.textPrimary.opacity(0.85))
                            .aspectRatio(CGFloat(template.width) / CGFloat(template.height), contentMode: .fit)
                            .padding(18)
                    }
                }
                .frame(width: 88, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(spacing: 1) {
                    Text(template.name)
                        .font(.system(size: 11, weight: .semibold))
                    Text(template.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                .foregroundColor(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? StudioTheme.accentSoft : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? StudioTheme.accent : StudioTheme.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("\(template.name) \(template.detail)")
    }
}

private struct ProjectCard: View {
    let project: StudioProject
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    StudioTheme.panelElevated
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 22))
                        .foregroundColor(StudioTheme.accent.opacity(0.7))
                    if isCurrent {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(StudioTheme.accent)
                                    .padding(6)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(StudioTheme.textPrimary)
                    .lineLimit(1)
                Text(Date(timeIntervalSince1970: project.created), format: .dateTime.day().month().year())
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textSecondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(StudioTheme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isCurrent ? StudioTheme.accent : StudioTheme.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SizeField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
        }
    }
}
