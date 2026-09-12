// ToolsHelpView.swift
//
// In-App Tools Reference & Comprehensive Help Documentation for Bixel Studio.
// Provides a Procreate-style dark documentation interface detailing every
// drawing, tilemap, animation, and AI tool, their workflows, and keyboard shortcuts.

import SwiftUI
import AppKit

// MARK: - Tool Help Model

struct ToolHelpItem: Identifiable, Hashable {
    let id: String
    let name: String
    let category: ToolCategory
    let icon: String
    let shortcut: String?
    let summary: String
    let overview: String
    let howToUse: [String]
    let proTips: [String]

    enum ToolCategory: String, CaseIterable, Identifiable {
        case all = "All Tools"
        case drawing = "Drawing & Painting"
        case selection = "Selection & Transform"
        case tilemap = "Tilemap Designer"
        case layers = "Layers & Blending"
        case animation = "Animation Assist"
        case ai = "AI Copilot"
        case shortcuts = "Shortcuts Reference"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .drawing: return "paintbrush.pointed"
            case .selection: return "lasso"
            case .tilemap: return "mountain.2.fill"
            case .layers: return "square.2.layers.3d"
            case .animation: return "film.stack"
            case .ai: return "wand.and.stars"
            case .shortcuts: return "command"
            }
        }
    }
}

// MARK: - Tool Documentation Catalog

enum ToolsDocumentationCatalog {
    static let items: [ToolHelpItem] = [
        // MARK: Drawing Tools
        ToolHelpItem(
            id: "paintbrush",
            name: "Paint Brush (Pencil)",
            category: .drawing,
            icon: "paintbrush.pointed",
            shortcut: "B",
            summary: "Draw precise pixel-art strokes and lines with custom brush size and opacity.",
            overview: "The Paint Brush is Bixel's primary pixel drawing tool. It operates in pure pixel space with nearest-neighbor precision, ensuring crisp edges without blurry anti-aliasing. The brush responds to the brush size and opacity controls in the left dock.",
            howToUse: [
                "Select the Paint Brush from the top bar or press 'B'.",
                "Adjust the brush diameter using the top slider on the left dock (1px to 64px).",
                "Adjust opacity with the bottom slider on the left dock (0% to 100%).",
                "Click or drag on the canvas to draw pixels on the active layer."
            ],
            proTips: [
                "Keep brush size at 1px for classic retro pixel art, or use 2-4px for blocking in silhouettes.",
                "Draw straight lines by clicking your start point and holding Shift while clicking the destination."
            ]
        ),
        ToolHelpItem(
            id: "smudge",
            name: "Smudge Tool",
            category: .drawing,
            icon: "hand.draw",
            shortcut: "S",
            summary: "Blend and smear adjacent pixel colors together for organic transitions and textures.",
            overview: "The Smudge Tool picks up pigment from beneath the cursor and blends it into adjacent pixels as you drag. In pixel art, it is invaluable for soft smoke, fire trails, clouds, and organic lighting gradients without manual dithering.",
            howToUse: [
                "Select the Smudge Tool from the top bar or press 'S'.",
                "Press and drag across two contrasting colors to pull and blend them together.",
                "Lower opacity on the left dock for a gentler feathering effect."
            ],
            proTips: [
                "Use short, circular flick gestures to blend skin tones or highlight gradients.",
                "Pair with the Onion Skin feature in Animation Assist to create fluid animated smears."
            ]
        ),
        ToolHelpItem(
            id: "eraser",
            name: "Eraser Tool",
            category: .drawing,
            icon: "eraser",
            shortcut: "E",
            summary: "Erase pixels on the active layer back to full or partial transparency.",
            overview: "The Eraser tool removes color data from the active layer. It respects the brush size slider so you can erase single pixels with surgical precision or clear large swaths quickly.",
            howToUse: [
                "Select the Eraser from the top bar or press 'E'.",
                "Adjust brush size to fit the region you want to clean up.",
                "Drag over pixels to restore background transparency."
            ],
            proTips: [
                "Eraser only affects the currently selected layer, preserving background and sketch layers underneath.",
                "Adjust the opacity slider to create soft semi-transparent fading effects."
            ]
        ),
        ToolHelpItem(
            id: "eyedropper",
            name: "Quick Eyedropper & Loupe",
            category: .drawing,
            icon: "eyedropper",
            shortcut: "I / Space",
            summary: "Sample any pixel color directly from the canvas with a live 9x magnifying loupe.",
            overview: "The Eyedropper samples exact RGB color values from the composited canvas. Bixel features a Procreate-style Quick Eyedropper button in the center of the left brush dock, as well as a high-precision 9x magnifying loupe overlay.",
            howToUse: [
                "Tap the square modify button on the left dock to toggle the Eyedropper tool.",
                "Alternatively, drag directly from the square modify button onto the canvas to engage the live magnifying loupe.",
                "Release your drag over any pixel to instantly set it as the active color."
            ],
            proTips: [
                "The loupe shows the color name, hexadecimal code, and an enlarged grid of surrounding pixels for pixel-accurate picking.",
                "After picking with a drag gesture, Bixel automatically restores your previously active tool."
            ]
        ),
        ToolHelpItem(
            id: "fill",
            name: "Paint Bucket / Flood Fill",
            category: .drawing,
            icon: "paintbrush.pointed.fill",
            shortcut: "G",
            summary: "Flood-fill contiguous regions of matching color with your active palette color.",
            overview: "The Flood Fill tool uses an optimized scanline flood-fill algorithm in the Rust core to instantly fill enclosed shapes and contiguous colored areas in a single undoable stroke.",
            howToUse: [
                "Select your target fill color from the Color disc.",
                "Click inside an enclosed pixel boundary on the canvas.",
                "The entire contiguous area matching the clicked pixel will be replaced."
            ],
            proTips: [
                "Make sure outlines are completely closed to prevent color spilling across the entire canvas.",
                "Combine with selection bounds to restrict the flood fill to an isolated region."
            ]
        ),

        // MARK: Selection & Transform
        ToolHelpItem(
            id: "selection",
            name: "Selection Tool (Lasso & Rect)",
            category: .selection,
            icon: "lasso",
            shortcut: "V",
            summary: "Isolate regions of pixels to edit, copy, cut, flip, or transform independently.",
            overview: "The Selection tool defines an active working boundary. While a selection is active, painting and erasing are restricted to the selected region. You can easily cut (⌘X), copy (⌘C), paste (⌘V), or switch to Transform.",
            howToUse: [
                "Click the Lasso icon in the top-left cluster or press 'V'.",
                "Drag a marquee around the artwork you wish to isolate.",
                "Use the bottom floating selection bar to rotate 90°, toggle snapping, or switch to Transform."
            ],
            proTips: [
                "Press Escape or click outside the selection to deselect.",
                "Use ⌘C then ⌘V to duplicate a sprite part onto a new floating layer."
            ]
        ),
        ToolHelpItem(
            id: "transform",
            name: "Transform Tool",
            category: .selection,
            icon: "arrow.up.left.and.arrow.down.right",
            shortcut: "T / ⌘T",
            summary: "Move, scale, stretch, flip, and rotate selections or floating layers.",
            overview: "Transform equips the active selection or imported image with an 8-handle bounding box. It supports nearest-neighbor interpolation to preserve pixel-art crispness without blur.",
            howToUse: [
                "Select pixels, then click the Transform tool icon in the top-left toolbar.",
                "Drag any corner handle to scale; drag edge handles to stretch.",
                "Drag outside the bounding box to freely rotate the contents.",
                "Toggle 'Uniform' in the toolbar to lock aspect ratio, or 'Freeform' for asymmetrical scaling."
            ],
            proTips: [
                "Turn on 'Snapping' in the floating bar to snap coordinates to exact whole pixels.",
                "Click 'Fit to Canvas' in the toolbar to quickly scale a sprite to fill document dimensions."
            ]
        ),

        // MARK: Tilemap Designer Tools
        ToolHelpItem(
            id: "map_stamp",
            name: "Tile Stamp Brush",
            category: .tilemap,
            icon: "paintbrush.pointed",
            shortcut: "P",
            summary: "Stamp individual tiles or multi-tile patterned brushes onto the active tile layer.",
            overview: "The primary painting tool of the Tilemap Designer. When you select a tile (or drag a multi-tile region) in the Tileset palette, the Stamp tool places that exact pattern onto the map grid.",
            howToUse: [
                "Open a .map document in Bixel Studio.",
                "Click a tile or drag-select a block of tiles in the Tileset panel.",
                "Click or drag on the map canvas to stamp the tiles.",
                "Press 'X' to flip horizontally, 'Y' to flip vertically, or 'C' to rotate 90°."
            ],
            proTips: [
                "Multi-tile brushes allow stamping whole trees, buildings, or furniture in a single click.",
                "Use the left dock buttons to mirror or rotate tile patterns before stamping."
            ]
        ),
        ToolHelpItem(
            id: "map_terrain",
            name: "Terrain Autotile Tool",
            category: .tilemap,
            icon: "mountain.2.fill",
            shortcut: "T",
            summary: "Paint intelligent terrain with automated 9-slice and 47-tile bitmask corner transitions.",
            overview: "Terrain painting eliminates the manual labor of placing corners, inner borders, and edges for grass, water, dirt, and paths. Bixel's engine calculates bitmask adjacencies and resolves correct border tiles in real-time.",
            howToUse: [
                "In the Tileset panel, configure your terrain slots (Center, Edges, Corners).",
                "Select the Terrain tool from the top bar or press 'T'.",
                "Paint freely across the map; borders, corners, and junctions resolve automatically."
            ],
            proTips: [
                "Paint with the right mouse button or holding Option to erase terrain while keeping neighboring borders intact."
            ]
        ),
        ToolHelpItem(
            id: "map_eraser",
            name: "Tile Eraser",
            category: .tilemap,
            icon: "eraser",
            shortcut: "E",
            summary: "Erase placed tiles from the active tile layer back to empty cells.",
            overview: "Clears GIDs from the active layer's grid without modifying tiles on underlying or overlying layers.",
            howToUse: [
                "Click the Eraser icon in the map toolbar or press 'E'.",
                "Click or drag over tiles to clear them from the current layer."
            ],
            proTips: [
                "To clear an entire region at once, use the Select tool (V) to highlight cells, then press Delete."
            ]
        ),
        ToolHelpItem(
            id: "map_bucket",
            name: "Tile Bucket Fill",
            category: .tilemap,
            icon: "drop.fill",
            shortcut: "G",
            summary: "Flood-fill connected cells sharing the same tile ID with your selected tile.",
            overview: "Quickly fill ground, backgrounds, water bodies, or ceilings across large tilemap areas.",
            howToUse: [
                "Select the Bucket tool from the map toolbar or press 'G'.",
                "Arm your brush with the desired tile.",
                "Click any cell on the map to flood-fill contiguous matching tiles."
            ],
            proTips: [
                "Works seamlessly on empty cells to rapidly block in the base layer of a new map."
            ]
        ),
        ToolHelpItem(
            id: "map_rect",
            name: "Rectangle Fill",
            category: .tilemap,
            icon: "square.on.square",
            shortcut: "F",
            summary: "Drag to fill rectangular areas with the active tile pattern.",
            overview: "Draws solid or repeating rectangular tile zones with a single mouse drag.",
            howToUse: [
                "Select the Rectangle tool (F).",
                "Click and drag from one corner of the desired rectangle to the opposite corner.",
                "Release to fill the grid cells within the bounding box."
            ],
            proTips: [
                "Perfect for constructing walls, floors, platforms, and dungeon chambers."
            ]
        ),
        ToolHelpItem(
            id: "map_line",
            name: "Line Tool",
            category: .tilemap,
            icon: "line.diagonal",
            shortcut: "L",
            summary: "Draw straight tile lines between two points using Bresenham's algorithm.",
            overview: "Ensures contiguous, gapless tile placement when creating roads, fences, wires, and corridors.",
            howToUse: [
                "Select the Line tool (L).",
                "Click the starting cell and drag to the ending cell.",
                "Release to commit the line of tiles."
            ],
            proTips: [
                "Line supercover algorithm ensures no diagonal gaps occur that characters could slip through."
            ]
        ),
        ToolHelpItem(
            id: "map_select_move",
            name: "Tile Select & Move",
            category: .tilemap,
            icon: "lasso",
            shortcut: "V / M",
            summary: "Select, cut, copy, and translate blocks of tiles across layers.",
            overview: "Provides rectangular cell selection for moving chunks of your level design around.",
            howToUse: [
                "Select (V): Drag a marquee around the tiles you want to manipulate.",
                "Move (M): Drag selected tiles to shift their position on the grid.",
                "Press ⌘C / ⌘V to copy and paste tile sections."
            ],
            proTips: [
                "Use the Minimap in the bottom-right corner to jump across large maps quickly."
            ]
        ),
        ToolHelpItem(
            id: "map_tilepicker",
            name: "Tile Picker (Eyedropper)",
            category: .tilemap,
            icon: "eyedropper",
            shortcut: "I",
            summary: "Sample any placed tile directly from the map canvas into your active brush.",
            overview: "Inspects the cell under the cursor and sets the matching tile ID as your current stamp brush.",
            howToUse: [
                "Select the Tile Picker from the toolbar or press 'I'.",
                "Click any tile on the map.",
                "Your brush is now armed with that exact tile, ready for stamping."
            ],
            proTips: [
                "Hold Option while using the Stamp tool to temporarily activate the Tile Picker."
            ]
        ),

        // MARK: Layers & Animation
        ToolHelpItem(
            id: "layers_panel",
            name: "Layers Panel & Blending",
            category: .layers,
            icon: "square.2.layers.3d",
            shortcut: "L",
            summary: "Organize artwork across non-destructive layers with blend modes and opacity.",
            overview: "Layers allow separating character outlines, color fills, highlights, shadows, and reference sketches. Bixel supports industry-standard blend modes: Normal, Multiply, Screen, Overlay, Darken, and Lighten.",
            howToUse: [
                "Click the Layers button in the top bar to toggle the floating card.",
                "Click '+' to add a new layer.",
                "Drag layer rows vertically to reorder stacking hierarchy.",
                "Click the checkbox to toggle visibility; adjust the slider for layer opacity."
            ],
            proTips: [
                "Use 'Multiply' mode on shadow layers and 'Screen' on glow/lighting layers.",
                "Keep background and foreground elements on separate layers to make animating easier."
            ]
        ),
        ToolHelpItem(
            id: "animation_assist",
            name: "Animation Assist & Onion Skin",
            category: .animation,
            icon: "film.stack",
            shortcut: "Space / ⌘N",
            summary: "Create multi-frame animations with timeline playback, onion skinning, and tags.",
            overview: "Animation Assist transforms Bixel into a powerful 2D sprite animator. The bottom timeline provides instant frame scrubbing, playback controls, adjustable FPS (1-60 fps), and customizable onion skin ghosting.",
            howToUse: [
                "Toggle the Film icon in the top bar to open the Timeline.",
                "Click 'Add Frame' (⇧⌘N) or 'Duplicate Frame' (⌘D) to create new animation cels.",
                "Press Space to play / pause the animation loop.",
                "Toggle Onion Skin in Actions (Wrench) to see ghosted outlines of adjacent frames."
            ],
            proTips: [
                "Onion skin ghost opacity can be adjusted in the Actions menu.",
                "Use Tags to delineate separate animation states like 'idle', 'run', 'jump', and 'attack'."
            ]
        ),

        // MARK: AI Copilot
        ToolHelpItem(
            id: "ai_copilot",
            name: "AI Copilot & Assistant",
            category: .ai,
            icon: "wand.and.stars",
            shortcut: "⌘K",
            summary: "Generate pixel art, predict next animation frames, and automate asset pipelines.",
            overview: "Bixel embeds an autonomous AI agent powered by Goose and OpenRouter. It can generate brand new pixel sprites from text prompts, predict walk-cycle frames, remove backgrounds, downsample palettes, and slice sprite sheets.",
            howToUse: [
                "Click the glowing Wand button in the top bar to open the AI panel.",
                "Type a prompt such as '16-bit cybernetic ninja jumping with katana'.",
                "Use '[[skill:next_frame]] walk' in the timeline to auto-predict the next animation step.",
                "Generated artwork can be placed directly onto the active canvas or saved to your gallery."
            ],
            proTips: [
                "Configure your OpenRouter API key or ChatGPT Codex connection in Settings (⌘,).",
                "Bixel skills auto-install into your system's isolated skill environment."
            ]
        )
    ]

    static let keyboardShortcuts: [(key: String, label: String, category: String)] = [
        ("B", "Paint Brush / Pencil Tool", "Drawing"),
        ("S", "Smudge Tool", "Drawing"),
        ("E", "Eraser Tool", "Drawing"),
        ("G", "Fill Bucket", "Drawing"),
        ("I", "Eyedropper / Color Picker", "Drawing"),
        ("V", "Selection Tool (Lasso)", "Selection"),
        ("T", "Transform Tool", "Selection"),
        ("P", "Stamp Brush (Tilemap)", "Tilemap"),
        ("T", "Terrain Tool (Tilemap)", "Tilemap"),
        ("F", "Rectangle Fill (Tilemap)", "Tilemap"),
        ("L", "Line Tool (Tilemap)", "Tilemap"),
        ("M", "Move Tool (Tilemap)", "Tilemap"),
        ("Space", "Play / Pause Animation", "Timeline"),
        ("⌘N", "New Document", "File"),
        ("⌘Z", "Undo", "Edit"),
        ("⇧⌘Z", "Redo", "Edit"),
        ("⌘X", "Cut Selection", "Edit"),
        ("⌘C", "Copy Selection / Frame", "Edit"),
        ("⌘V", "Paste Selection / Frame", "Edit"),
        ("Delete", "Delete Selection / Frame", "Edit"),
        ("⌘D", "Duplicate Frame", "Timeline"),
        ("⇧⌘N", "Add Frame", "Timeline"),
        ("⌘,", "Previous Frame", "Timeline"),
        ("⌘.", "Next Frame", "Timeline"),
        ("⌘+", "Zoom In", "View"),
        ("⌘-", "Zoom Out", "View"),
        ("⌘0", "Zoom to Fit", "View"),
        ("⌘?", "Tools Documentation & Help", "Help")
    ]
}

// MARK: - Tools Help View

struct ToolsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: ToolHelpItem.ToolCategory = .all
    @State private var searchQuery: String = ""
    @State private var selectedToolId: String = "paintbrush"

    private var filteredItems: [ToolHelpItem] {
        ToolsDocumentationCatalog.items.filter { item in
            let matchesCategory = (selectedCategory == .all) || (item.category == selectedCategory)
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return matchesCategory
            }
            let query = searchQuery.lowercased()
            let matchesSearch = item.name.lowercased().contains(query) ||
                                item.summary.lowercased().contains(query) ||
                                item.overview.lowercased().contains(query) ||
                                (item.shortcut?.lowercased().contains(query) ?? false)
            return matchesCategory && matchesSearch
        }
    }

    private var activeTool: ToolHelpItem? {
        if let found = filteredItems.first(where: { $0.id == selectedToolId }) {
            return found
        }
        return filteredItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(StudioTheme.hairlineStrong)

            if selectedCategory == .shortcuts {
                shortcutsReferenceView
            } else {
                HStack(spacing: 0) {
                    sidebarList
                        .frame(width: 280)
                    Divider().overlay(StudioTheme.hairlineStrong)
                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "book.pages")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(StudioTheme.procreateBlue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bixel Studio Tools Reference")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Complete documentation, tips, and keyboard shortcuts for all tools")
                    .font(.system(size: 11))
                    .foregroundColor(StudioTheme.textSecondary)
            }

            Spacer()

            // Search Field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textSecondary)
                TextField("Search tools & shortcuts…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 170)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(StudioTheme.hairline, lineWidth: 1)
            )

            // Category Picker
            Picker("", selection: $selectedCategory) {
                ForEach(ToolHelpItem.ToolCategory.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(StudioTheme.procreateBlue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(StudioTheme.panel)
    }

    // MARK: - Sidebar Tool List

    private var sidebarList: some View {
        ScrollView {
            VStack(spacing: 4) {
                if filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 28))
                            .foregroundColor(StudioTheme.textDisabled)
                        Text("No matching tools found")
                            .font(.system(size: 12))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(filteredItems) { item in
                        toolRow(item)
                    }
                }
            }
            .padding(10)
        }
        .background(StudioTheme.panel.opacity(0.6))
    }

    private func toolRow(_ item: ToolHelpItem) -> some View {
        let isSelected = (activeTool?.id == item.id)
        return Button {
            selectedToolId = item.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? StudioTheme.procreateBlue : Color.white.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? StudioTheme.accentSoft : Color.white.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .foregroundColor(.white)
                        Spacer()
                        if let shortcut = item.shortcut {
                            Text(shortcut)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(StudioTheme.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }

                    Text(item.summary)
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? StudioTheme.panelElevated : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? StudioTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        Group {
            if let tool = activeTool {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Title header
                        HStack(spacing: 14) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(StudioTheme.procreateBlue)
                                .frame(width: 52, height: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(StudioTheme.accentSoft)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(StudioTheme.accent.opacity(0.4), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(tool.name)
                                        .font(.system(size: 19, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)

                                    if let shortcut = tool.shortcut {
                                        Text("Key: \(shortcut)")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundColor(StudioTheme.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(StudioTheme.accentSoft)
                                            )
                                    }
                                }

                                Text(tool.category.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(StudioTheme.textSecondary)
                            }
                            Spacer()
                        }

                        // Summary callout
                        Text(tool.summary)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.9))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(StudioTheme.hairline, lineWidth: 1)
                            )

                        // Overview section
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Overview", systemImage: "info.circle")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(StudioTheme.procreateBlue)

                            Text(tool.overview)
                                .font(.system(size: 12))
                                .foregroundColor(StudioTheme.textPrimary)
                                .lineSpacing(3)
                        }

                        // How to Use section
                        VStack(alignment: .leading, spacing: 8) {
                            Label("How to Use", systemImage: "hand.tap")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(StudioTheme.bixelGreen)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(tool.howToUse.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(index + 1).")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(StudioTheme.bixelGreen)
                                            .frame(width: 18, alignment: .leading)
                                        Text(step)
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.white.opacity(0.85))
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(StudioTheme.panel)
                            )
                        }

                        // Pro Tips section
                        if !tool.proTips.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Pro Tips", systemImage: "lightbulb.max")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.yellow)

                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(tool.proTips, id: \.self) { tip in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "sparkle")
                                                .font(.system(size: 10))
                                                .foregroundColor(.yellow)
                                                .padding(.top, 2)
                                            Text(tip)
                                                .font(.system(size: 11))
                                                .foregroundColor(Color.white.opacity(0.82))
                                        }
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.yellow.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.yellow.opacity(0.18), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(24)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 36))
                        .foregroundColor(StudioTheme.textDisabled)
                    Text("Select a tool from the left to view its documentation")
                        .font(.system(size: 13))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Shortcuts Reference View

    private var shortcutsReferenceView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keyboard Shortcuts Cheat Sheet")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Speed up your pixel art and tilemap workflow with single-key shortcuts.")
                            .font(.system(size: 12))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                    Spacer()
                }

                let categories = ["Drawing", "Selection", "Tilemap", "Timeline", "File", "Edit", "View", "Help"]

                ForEach(categories, id: \.self) { cat in
                    let shortcuts = ToolsDocumentationCatalog.keyboardShortcuts.filter { $0.category == cat }
                    if !shortcuts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(cat.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(StudioTheme.procreateBlue)

                            VStack(spacing: 1) {
                                ForEach(shortcuts, id: \.key) { shortcut in
                                    HStack {
                                        Text(shortcut.label)
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.white.opacity(0.9))
                                        Spacer()
                                        Text(shortcut.key)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color.white.opacity(0.12))
                                            )
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(StudioTheme.panel)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(StudioTheme.hairline, lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
