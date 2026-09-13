// HomePageView.swift
//
// Native macOS Home Page & Dashboard for Bixel Studio:
// - Top Bar: Bixel logo, search bar with ⌘K
// - Hero Banner: Pixel art forest scene with glowing moon, headline, and quick action bar
// - AI Studio Creator: Prompt composer with size/style controls, preview, and project-or-gallery handoff
// - Recent Projects Grid: Pixel art thumbnail previews, tag badges, dimensions, and click-to-open
// - Templates & Inspirations: "Pixel Village", "Character Base", "RPG Icons" + Quote box

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct HomePageView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var aiGallery: AIGalleryStore
    let onOpenProject: (StudioProject) -> Void
    let onOpenWithAIPrompt: (AICreationRequest) -> Void
    let isAIGenerating: Bool
    var onPresentPaywall: (() -> Void)? = nil
    var onPresentCustomerCenter: (() -> Void)? = nil

    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    @State private var searchText = ""
    @State private var showNewProjectSheet = false
    @State private var aiPrompt = ""
    @State private var selectedWidth: Int = 32
    @State private var selectedHeight: Int = 32
    @State private var showCustomSizePopover = false
    @State private var customWidthText = "32"
    @State private var customHeightText = "32"
    @State private var selectedStyle: String = "16-Bit Retro"
    @State private var showCustomStylePopover = false
    @State private var customStyleText = ""

    private static let retroStyles: [String] = [
        "16-Bit Retro",
        "Classic 8-Bit",
        "Game Boy (4 Colors)",
        "PICO-8 (16 Colors)",
        "Arcade Neo-Geo"
    ]
    private static let themeStyles: [String] = [
        "Fantasy RPG",
        "Cyberpunk Neon",
        "Dark Fantasy / Gothic",
        "Sci-Fi Space",
        "Post-Apocalyptic",
        "Cozy Cottagecore"
    ]
    private static let techniqueStyles: [String] = [
        "Isometric Pixel",
        "Top-Down RPG",
        "Side-Scroller Platformer",
        "Chibi / Cute Sprite",
        "Dithered Retro"
    ]
    private static var allPresetStyles: [String] {
        retroStyles + themeStyles + techniqueStyles
    }

    struct ScreenPreset: Identifiable, Hashable {
        var id: String { name }
        let w: Int
        let h: Int
        let name: String
    }

    private static let squarePresets: [Int] = [8, 16, 24, 32, 48, 64, 96, 128, 256, 512]
    private static let screenPresets: [ScreenPreset] = [
        ScreenPreset(w: 160, h: 144, name: "Game Boy"),
        ScreenPreset(w: 240, h: 160, name: "GBA"),
        ScreenPreset(w: 256, h: 224, name: "SNES"),
        ScreenPreset(w: 320, h: 180, name: "16:9"),
        ScreenPreset(w: 320, h: 240, name: "4:3"),
        ScreenPreset(w: 640, h: 360, name: "HD Screen")
    ]
    @State private var selectedGalleryItem: AIGalleryItem?
    @State private var renamingProject: StudioProject? = nil
    @State private var renameText = ""
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var promptFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // TOP HEADER BAR (Full width)
            topHeaderBar
                .frame(height: 58)
                .background(StudioTheme.homeDark)

            Divider()
                .overlay(StudioTheme.homeCardBorder)

            // SCROLLABLE DASHBOARD
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 28) {
                    // 1. Hero Banner
                    heroBanner

                    // 2. High-End AI Studio Creator (Redesigned, no extra AI Chat button)
                    aiCreatorHub

                    // 3. Middle Section: Recent Projects
                    recentProjectsSection

                    // 4. Generated images kept for later
                    if !aiGallery.items.isEmpty {
                        AIGalleryStrip(gallery: aiGallery) { item in
                            selectedGalleryItem = item
                        }
                    }

                    // 5. Bottom Section: Templates & Inspirations + Quote
                    HStack(alignment: .top, spacing: 24) {
                        templatesSection
                            .frame(maxWidth: .infinity, alignment: .leading)

                        quoteCard
                            .frame(width: 300)
                    }

                    // 6. Ad Banner (displayed only for free-tier users)
                    if !subscriptionManager.isAdFree {
                        AdBannerView {
                            onPresentPaywall?()
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 48)
            }
        }
        #if os(macOS)
        .frame(minWidth: 1060, minHeight: 720)
        #endif
        .background(StudioTheme.homeDark)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectQuickDialog(store: store) { project in
                showNewProjectSheet = false
                onOpenProject(project)
            }
        }
        .sheet(item: $renamingProject) { project in
            RenameProjectDialog(project: project, name: $renameText) { newName in
                store.renameProject(project, newName: newName)
                renamingProject = nil
            }
        }
        .sheet(item: $selectedGalleryItem) { item in
            AIGalleryImagePreview(item: item)
        }
    }

    // MARK: - Top Header Bar

    private var topHeaderBar: some View {
        ZStack {
            // Centered Search Bar with ⌘K
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)

                TextField("Search projects, templates, assets...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .focused($searchFieldFocused)

                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                // ⌘K pill badge
                Text("⌘ K")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(StudioTheme.textDisabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(StudioTheme.homeCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                    )
            )

            // Leading: Brand Logo & Title
            HStack(spacing: 10) {
                BixelSlimeLogo(size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Bixel Studio")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("PIXEL ART FOR BIG IDEAS")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                        .tracking(1.4)
                }

                Spacer()
            }
            .padding(.leading, 24)

            // Trailing: Store / Lifetime Ad-Free status
            HStack(spacing: 10) {
                Spacer()

                if subscriptionManager.isAdFree {
                    Button {
                        onPresentCustomerCenter?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(StudioTheme.bixelGreen)
                            Text("Lifetime Ad-Free")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(StudioTheme.bixelGreenSoft)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(StudioTheme.bixelGreen.opacity(0.35), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Manage account and purchases")
                } else {
                    Button {
                        onPresentPaywall?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.black)
                            Text("Unlock Lifetime")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(StudioTheme.bixelGreen)
                        )
                        .shadow(color: StudioTheme.bixelGreen.opacity(0.3), radius: 6, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("One-time lifetime purchase: Remove all ads forever")
                }

                Button {
                    AppSettings.requestOpen()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(StudioTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("AI Provider and App Settings")
            }
            .padding(.trailing, 24)
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            // Background Artwork (Pixel Forest Landscape at Night)
            HeroPixelLandscape()
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                )

            // Banner Content Overlay
            VStack(alignment: .leading, spacing: 18) {
                // Headlines
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create something\npixel perfect.")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .lineSpacing(2)

                    Text("Turn your ideas into pixel artwork, frame sequences, tilesets and more.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.85))
                }

                // Quick Action Bar
                HStack(spacing: 12) {
                    // Big Green Action Button: Create New Project
                    Button {
                        showNewProjectSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.85))
                                    .frame(width: 32, height: 32)
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(StudioTheme.bixelGreen)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Create New Project")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(.black)
                                Text("Start from a blank canvas")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color.black.opacity(0.7))
                            }

                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color.black.opacity(0.8))
                                .padding(.leading, 4)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(StudioTheme.bixelGreen)
                        )
                        .shadow(color: StudioTheme.bixelGreen.opacity(0.35), radius: 10, y: 3)
                    }
                    .buttonStyle(.plain)

                    // Secondary Quick Actions: the two workspace modes plus import.
                    heroQuickButton(title: "New Normal", subtitle: "Any pixel artwork", icon: "pencil") {
                        if let project = store.createProject(name: "New Project", mode: .normal, width: 32, height: 32) {
                            onOpenProject(project)
                        }
                    }

                    heroQuickButton(title: "New Scene", subtitle: "Stamp and design", icon: "map") {
                        if let project = store.createProject(name: "New Scene", mode: .map, width: 0, height: 0, infinite: true, orientation: .isometric) {
                            onOpenProject(project)
                        }
                    }

                    heroQuickButton(title: "Import", subtitle: "Images or files", icon: "square.and.arrow.down") {
                        importFile()
                    }
                }
            }
            .padding(24)
        }
    }

    private func heroQuickButton(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StudioTheme.homeCard.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Redesigned High-End AI Studio Creator (No extra AI Chat button)

    private var aiCreatorHub: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. Header Bar: AI badge, Mode selector pills, and Model indicator
            HStack(spacing: 14) {
                // Glow Badge
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(StudioTheme.bixelGreen)
                    Text("Bixel AI Studio")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StudioTheme.bixelGreenSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(StudioTheme.bixelGreen.opacity(0.4), lineWidth: 1)
                        )
                )

                Spacer()

                // Active Engine Indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(StudioTheme.bixelGreen)
                        .frame(width: 6, height: 6)
                    Text("PixelArt Agent Ready")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                }
            }

            // 2. Main Prompt Composer Area
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14))
                        .foregroundColor(StudioTheme.bixelGreen)
                        .padding(.top, 2)

                    TextField("Describe what you want to create or design... (e.g., 'A cyber slime monster with an electric aura', 'A dungeon crypt with stone walls and torches')", text: $aiPrompt, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .focused($promptFieldFocused)
                        .disabled(isAIGenerating)
                        .onSubmit {
                            submitAIPrompt()
                        }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                Divider()
                    .overlay(Color.white.opacity(0.06))

                // 3. Parameter Controls & Prominent "Design & Create" Action
                HStack(spacing: 10) {
                    // Size Selector Menu
                    Menu {
                        Section("Square Sizes") {
                            ForEach(Self.squarePresets, id: \.self) { size in
                                Button {
                                    selectedWidth = size
                                    selectedHeight = size
                                    customWidthText = "\(size)"
                                    customHeightText = "\(size)"
                                } label: {
                                    if selectedWidth == size && selectedHeight == size {
                                        Label("\(size) × \(size) px", systemImage: "checkmark")
                                    } else {
                                        Text("\(size) × \(size) px")
                                    }
                                }
                            }
                        }

                        Section("Retro & Screens") {
                            ForEach(Self.screenPresets) { preset in
                                Button {
                                    selectedWidth = preset.w
                                    selectedHeight = preset.h
                                    customWidthText = "\(preset.w)"
                                    customHeightText = "\(preset.h)"
                                } label: {
                                    if selectedWidth == preset.w && selectedHeight == preset.h {
                                        Label("\(preset.w) × \(preset.h) px (\(preset.name))", systemImage: "checkmark")
                                    } else {
                                        Text("\(preset.w) × \(preset.h) px (\(preset.name))")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            customWidthText = "\(selectedWidth)"
                            customHeightText = "\(selectedHeight)"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                showCustomSizePopover = true
                            }
                        } label: {
                            Label("Other (Custom W × H)…", systemImage: "slider.horizontal.below.square.filled.and.square")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "aspectratio")
                                .font(.system(size: 10))
                            Text("\(selectedWidth) × \(selectedHeight)")
                                .font(.system(size: 11, design: .monospaced))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(StudioTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(StudioTheme.homeCardBorder, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(isAIGenerating)
                    .popover(isPresented: $showCustomSizePopover, arrowEdge: .bottom) {
                        customSizePopoverContent
                    }

                    // Art Style Menu
                    Menu {
                        // 1. None Option
                        Button {
                            selectedStyle = "None"
                        } label: {
                            if selectedStyle == "None" {
                                Label("None (Freeform / No Style)", systemImage: "checkmark")
                            } else {
                                Text("None (Freeform / No Style)")
                            }
                        }

                        Divider()

                        // 2. Retro & Consoles
                        Section("Retro & Consoles") {
                            ForEach(Self.retroStyles, id: \.self) { style in
                                Button {
                                    selectedStyle = style
                                } label: {
                                    if selectedStyle == style {
                                        Label(style, systemImage: "checkmark")
                                    } else {
                                        Text(style)
                                    }
                                }
                            }
                        }

                        // 3. Game Themes
                        Section("Game Themes") {
                            ForEach(Self.themeStyles, id: \.self) { style in
                                Button {
                                    selectedStyle = style
                                } label: {
                                    if selectedStyle == style {
                                        Label(style, systemImage: "checkmark")
                                    } else {
                                        Text(style)
                                    }
                                }
                            }
                        }

                        // 4. Visual Techniques
                        Section("Visual Techniques") {
                            ForEach(Self.techniqueStyles, id: \.self) { style in
                                Button {
                                    selectedStyle = style
                                } label: {
                                    if selectedStyle == style {
                                        Label(style, systemImage: "checkmark")
                                    } else {
                                        Text(style)
                                    }
                                }
                            }
                        }

                        Divider()

                        // 5. Custom Style
                        Button {
                            if selectedStyle != "None" && !Self.allPresetStyles.contains(selectedStyle) {
                                customStyleText = selectedStyle
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                showCustomStylePopover = true
                            }
                        } label: {
                            Label("Other (Custom Style)…", systemImage: "pencil.and.outline")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 10))
                                .foregroundColor(selectedStyle == "None" ? StudioTheme.textDisabled : StudioTheme.bixelGreen)
                            Text(selectedStyle == "None" ? "No Style" : selectedStyle)
                                .font(.system(size: 11))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(StudioTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(StudioTheme.homeCardBorder, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(isAIGenerating)
                    .popover(isPresented: $showCustomStylePopover, arrowEdge: .bottom) {
                        customStylePopoverContent
                    }

                    Spacer()

                    // Clear button
                    if !aiPrompt.isEmpty {
                        Button { aiPrompt = "" } label: {
                            Text("Clear")
                                .font(.system(size: 11))
                                .foregroundColor(StudioTheme.textDisabled)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                        .disabled(isAIGenerating)
                    }

                    // Prominent "Design & Create" Action Button
                    Button {
                        submitAIPrompt()
                    } label: {
                        HStack(spacing: 7) {
                            if isAIGenerating {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.black)
                            }
                            Text(isAIGenerating ? "Generating…" : "Design & Create")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            if !isAIGenerating {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(StudioTheme.bixelGreen)
                        )
                        .shadow(color: StudioTheme.bixelGreen.opacity(0.4), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAIGenerating || aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StudioTheme.homeCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                    )
            )

        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.10, blue: 0.12),
                            Color(red: 0.11, green: 0.12, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(StudioTheme.bixelGreen.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.3), radius: 14, y: 4)
        )
    }


    private var customSizePopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "slider.horizontal.below.square.filled.and.square")
                    .foregroundColor(StudioTheme.bixelGreen)
                    .font(.system(size: 12))
                Text("Custom Canvas Size")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
            }

            // Width & Height inputs
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(StudioTheme.textSecondary)
                    HStack(spacing: 4) {
                        TextField("W", text: $customWidthText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 54)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(StudioTheme.homeCardBorder, lineWidth: 1)
                            )
                            .onSubmit { applyCustomSize() }
                        Text("px")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                }

                Text("×")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Height")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(StudioTheme.textSecondary)
                    HStack(spacing: 4) {
                        TextField("H", text: $customHeightText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 54)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(StudioTheme.homeCardBorder, lineWidth: 1)
                            )
                            .onSubmit { applyCustomSize() }
                        Text("px")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                }
            }

            // Aspect ratio shortcuts
            VStack(alignment: .leading, spacing: 6) {
                Text("Aspect Ratio")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)

                HStack(spacing: 6) {
                    Button("1:1") {
                        if let w = Int(customWidthText), w > 0 {
                            customHeightText = "\(w)"
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudioTheme.homeCardBorder, in: RoundedRectangle(cornerRadius: 4))

                    Button("4:3") {
                        if let w = Int(customWidthText), w > 0 {
                            customHeightText = "\(max(1, w * 3 / 4))"
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudioTheme.homeCardBorder, in: RoundedRectangle(cornerRadius: 4))

                    Button("16:9") {
                        if let w = Int(customWidthText), w > 0 {
                            customHeightText = "\(max(1, w * 9 / 16))"
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudioTheme.homeCardBorder, in: RoundedRectangle(cornerRadius: 4))

                    Button("Swap ⇄") {
                        let temp = customWidthText
                        customWidthText = customHeightText
                        customHeightText = temp
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudioTheme.homeCardBorder, in: RoundedRectangle(cornerRadius: 4))
                }
            }

            Divider().overlay(StudioTheme.homeCardBorder)

            HStack {
                Button("Cancel") {
                    showCustomSizePopover = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(StudioTheme.textSecondary)

                Spacer()

                Button("Apply") {
                    applyCustomSize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(StudioTheme.bixelGreen)
                .foregroundColor(.black)
            }
        }
        .padding(14)
        .frame(width: 230)
        .background(StudioTheme.homeDark)
    }

    private func applyCustomSize() {
        let rawW = Int(customWidthText) ?? selectedWidth
        let rawH = Int(customHeightText) ?? selectedHeight
        selectedWidth = min(max(1, rawW), 4096)
        selectedHeight = min(max(1, rawH), 4096)
        customWidthText = "\(selectedWidth)"
        customHeightText = "\(selectedHeight)"
        showCustomSizePopover = false
    }

    private var customStylePopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "pencil.and.outline")
                    .foregroundColor(StudioTheme.bixelGreen)
                    .font(.system(size: 12))
                Text("Custom Art Style")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Describe Style or Aesthetics")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)

                TextField("e.g. Vaporwave Pastel, Ghibli Pixel, Noir Shadow", text: $customStyleText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(StudioTheme.homeCardBorder, lineWidth: 1)
                    )
                    .onSubmit { applyCustomStyle() }
            }

            // Quick Tag Suggestions
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Ideas")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)

                let ideas = ["Vaporwave", "Steampunk", "Studio Ghibli", "Film Noir", "Pastel Anime", "Horror Dither"]
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(ideas, id: \.self) { idea in
                        Button {
                            customStyleText = idea
                        } label: {
                            Text(idea)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundColor(StudioTheme.textSecondary)
                                .background(StudioTheme.homeCard, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(StudioTheme.homeCardBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().overlay(StudioTheme.homeCardBorder)

            HStack {
                Button("Cancel") {
                    showCustomStylePopover = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(StudioTheme.textSecondary)

                Spacer()

                Button("Apply") {
                    applyCustomStyle()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(StudioTheme.bixelGreen)
                .foregroundColor(.black)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(StudioTheme.homeDark)
    }

    private func applyCustomStyle() {
        let trimmed = customStyleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            selectedStyle = trimmed
        }
        showCustomStylePopover = false
    }

    private func submitAIPrompt() {
        let text = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAIGenerating else { return }
        aiPrompt = ""
        promptFieldFocused = false
        onOpenWithAIPrompt(AICreationRequest(prompt: text, width: selectedWidth, height: selectedHeight, style: selectedStyle))
    }

    // MARK: - Recent Projects Section

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Title & "See All ->"
            HStack {
                Text("Recent Projects")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Button {} label: {
                    HStack(spacing: 4) {
                        Text("See All")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(StudioTheme.bixelGreen)
                }
                .buttonStyle(.plain)
            }

            // Filtered Projects Grid
            let list = filteredProjects
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(StudioTheme.textDisabled)
                    Text("No projects match your search.")
                        .font(.system(size: 12))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(StudioTheme.homeCard, in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(list) { project in
                        RecentProjectCard(
                            project: project,
                            metadata: store.metadata(for: project),
                            thumbnail: store.thumbnail(for: project),
                            onOpen: { onOpenProject(project) },
                            onRename: {
                                renameText = project.name
                                renamingProject = project
                            },
                            onDuplicate: { store.duplicateProject(project) },
                            onDelete: { store.deleteProject(project) }
                        )
                    }
                }
            }
        }
    }

    private var filteredProjects: [StudioProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return store.projects }
        return store.projects.filter { $0.name.lowercased().contains(query) }
    }

    // MARK: - Bottom Section: Templates & Inspirations + Quote

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Templates & Inspirations")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Button {} label: {
                    HStack(spacing: 4) {
                        Text("See All")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(StudioTheme.bixelGreen)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                ForEach(SamplePixelArt.templates) { template in
                    TemplateInspirationCard(template: template) {
                        if let project = store.createFromTemplate(templateId: template.id) {
                            onOpenProject(project)
                        }
                    }
                }
            }
        }
    }

    private var quoteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundColor(StudioTheme.textDisabled)
                .frame(height: 16)

            Text("\"A million worlds\nstart with a single pixel.\"")
                .font(.system(size: 12, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(StudioTheme.textSecondary)
                .lineSpacing(4)

            Spacer()

            HStack {
                Text("—")
                    .foregroundColor(StudioTheme.textDisabled)
                Spacer()
                Text("Bixel Studio")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(StudioTheme.textDisabled)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.homeCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private func importFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent

            var imageURL = url
            var manifest: String?
            if url.pathExtension.lowercased() == "json" {
                guard let sibling = SheetImport.siblingImage(for: url) else {
                    store.error = "Choose a PNG spritesheet, or a JSON manifest next to its image."
                    return
                }
                imageURL = sibling
                manifest = (try? Data(contentsOf: url)).flatMap(SheetImport.manifest(fromJSON:))
            } else {
                manifest = SheetImport.sidecarManifest(for: url)
            }

            guard let data = try? Data(contentsOf: imageURL) else {
                store.error = "Could not read that file."
                return
            }

            let project = manifest.map { store.importSheetProject(png: data, manifest: $0, name: name) }
                ?? store.importImageProject(png: data, name: name)
            if let project { onOpenProject(project) }
        }
        #endif
    }
}

// MARK: - Recent Project Card

struct RecentProjectCard: View {
    let project: StudioProject
    let metadata: (mode: WorkspaceMode, sizeText: String, timeText: String)
    let thumbnail: CGImage?
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                // Pixel Art Preview Thumbnail
                ProjectThumbnailThumb(thumbnail: thumbnail, fallbackName: project.name, size: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                    )

                // Project Details
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(project.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer()

                        // Context Menu button
                        Menu {
                            Button("Open", action: onOpen)
                            Button("Rename…", action: onRename)
                            Button("Duplicate", action: onDuplicate)
                            Divider()
                            Button("Delete", role: .destructive, action: onDelete)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(StudioTheme.textSecondary)
                                .frame(width: 20, height: 20)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }

                    // Tag Badge (Normal or Map)
                    tagBadge(mode: metadata.mode)

                    // Details: Dimensions & Edited time
                    Text("\(metadata.sizeText) • \(metadata.timeText)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? StudioTheme.homeCardHover : StudioTheme.homeCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isHovered ? StudioTheme.homeBorderHover : StudioTheme.homeCardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func tagBadge(mode: WorkspaceMode) -> some View {
        let (bg, fg, title) = tagInfo(for: mode)
        return Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(bg))
    }

    private func tagInfo(for mode: WorkspaceMode) -> (Color, Color, String) {
        switch mode {
        case .normal:
            return (StudioTheme.tagSpriteBg, StudioTheme.tagSpriteText, "Normal")
        case .map:
            return (StudioTheme.tagMapBg, StudioTheme.tagMapText, "Scene")
        }
    }
}

// MARK: - Template Inspiration Card

struct TemplateInspirationCard: View {
    let template: SamplePixelArt.TemplateItem
    let onUse: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Thumbnail
            PixelPreviewThumb(name: template.name, size: 90)
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                Text(template.description)
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textSecondary)
                    .lineLimit(2)
                    .frame(height: 26, alignment: .topLeading)
            }

            // Use Template Button
            Button(action: onUse) {
                Text("Use Template")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StudioTheme.bixelGreen)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? StudioTheme.homeCardHover : StudioTheme.homeCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isHovered ? StudioTheme.homeBorderHover : StudioTheme.homeCardBorder, lineWidth: 1)
                )
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Project Artwork Thumbnail

struct ProjectThumbnailThumb: View {
    let thumbnail: CGImage?
    let fallbackName: String
    let size: CGFloat

    var body: some View {
        ZStack {
            CheckerboardView(cell: 6)
                .opacity(0.35)

            if let thumbnail {
                Image(decorative: thumbnail, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: size, maxHeight: size)
            } else if let sample = SamplePixelArt.makePreviewImage(for: fallbackName) {
                Image(decorative: sample, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: size, maxHeight: size)
            } else {
                Rectangle()
                    .fill(StudioTheme.homeCard)
            }
        }
        .frame(width: size, height: size)
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - Pixel Artwork Preview Thumbnail

struct PixelPreviewThumb: View {
    let name: String
    let size: CGFloat

    var body: some View {
        if let cgImage = SamplePixelArt.makePreviewImage(for: name) {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
        } else {
            Rectangle()
                .fill(StudioTheme.homeCard)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Bixel Slime Logo

struct BixelSlimeLogo: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height

            // Slime droplet path
            var path = Path()
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.08))
            path.addCurve(
                to: CGPoint(x: w * 0.92, y: h * 0.72),
                control1: CGPoint(x: w * 0.75, y: h * 0.25),
                control2: CGPoint(x: w * 0.95, y: h * 0.50)
            )
            path.addCurve(
                to: CGPoint(x: w * 0.5, y: h * 0.94),
                control1: CGPoint(x: w * 0.90, y: h * 0.92),
                control2: CGPoint(x: w * 0.68, y: h * 0.94)
            )
            path.addCurve(
                to: CGPoint(x: w * 0.08, y: h * 0.72),
                control1: CGPoint(x: w * 0.32, y: h * 0.94),
                control2: CGPoint(x: w * 0.10, y: h * 0.92)
            )
            path.addCurve(
                to: CGPoint(x: w * 0.5, y: h * 0.08),
                control1: CGPoint(x: w * 0.05, y: h * 0.50),
                control2: CGPoint(x: w * 0.25, y: h * 0.25)
            )
            path.closeSubpath()

            context.fill(path, with: .color(StudioTheme.bixelGreen))

            // Eyes
            let eyeL = Path(ellipseIn: CGRect(x: w * 0.32, y: h * 0.52, width: w * 0.12, height: h * 0.18))
            let eyeR = Path(ellipseIn: CGRect(x: w * 0.56, y: h * 0.52, width: w * 0.12, height: h * 0.18))
            context.fill(eyeL, with: .color(Color(red: 0.10, green: 0.25, blue: 0.08)))
            context.fill(eyeR, with: .color(Color(red: 0.10, green: 0.25, blue: 0.08)))

            // Eye glints
            let glintL = Path(ellipseIn: CGRect(x: w * 0.34, y: h * 0.54, width: w * 0.04, height: h * 0.06))
            let glintR = Path(ellipseIn: CGRect(x: w * 0.58, y: h * 0.54, width: w * 0.04, height: h * 0.06))
            context.fill(glintL, with: .color(.white))
            context.fill(glintR, with: .color(.white))
        }
        .frame(width: size, height: size)
    }
}


// MARK: - Hero Pixel Landscape Graphic

struct HeroPixelLandscape: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            // Night Sky Gradient
            let sky = Gradient(colors: [
                Color(red: 0.04, green: 0.07, blue: 0.09),
                Color(red: 0.08, green: 0.14, blue: 0.16)
            ])
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

            // Glowing Pixel Moon
            let moonX = w * 0.63
            let moonY = h * 0.30
            let moonRadius: CGFloat = 16

            // Moon halo
            let moonGlow = Path(ellipseIn: CGRect(x: moonX - moonRadius * 1.6, y: moonY - moonRadius * 1.6, width: moonRadius * 3.2, height: moonRadius * 3.2))
            context.fill(moonGlow, with: .color(StudioTheme.bixelGreen.opacity(0.18)))

            // Pixel Moon Body
            let moonPath = Path(ellipseIn: CGRect(x: moonX - moonRadius, y: moonY - moonRadius, width: moonRadius * 2, height: moonRadius * 2))
            context.fill(moonPath, with: .color(Color(red: 0.82, green: 0.98, blue: 0.72)))

            // Moon craters
            let crater1 = Path(ellipseIn: CGRect(x: moonX - 4, y: moonY - 3, width: 5, height: 5))
            let crater2 = Path(ellipseIn: CGRect(x: moonX + 3, y: moonY + 2, width: 4, height: 4))
            context.fill(crater1, with: .color(Color(red: 0.70, green: 0.88, blue: 0.60)))
            context.fill(crater2, with: .color(Color(red: 0.70, green: 0.88, blue: 0.60)))

            // Background Pine Trees Silhouette
            let treeColor = Color(red: 0.05, green: 0.10, blue: 0.11)
            var forestPath = Path()
            forestPath.move(to: CGPoint(x: 0, y: h))
            forestPath.addLine(to: CGPoint(x: 0, y: h * 0.60))

            // Procedural stepped pine ridge on right half
            var px: CGFloat = w * 0.50
            while px < w {
                let treeH = CGFloat.random(in: 40...85)
                let base = h * 0.85
                forestPath.addLine(to: CGPoint(x: px, y: base))
                forestPath.addLine(to: CGPoint(x: px + 12, y: base - treeH))
                forestPath.addLine(to: CGPoint(x: px + 24, y: base))
                px += 20
            }
            forestPath.addLine(to: CGPoint(x: w, y: h))
            forestPath.closeSubpath()
            context.fill(forestPath, with: .color(treeColor))

            // Cozy Illuminated Cabin Silhouette (Right side)
            let cabinX = w * 0.78
            let cabinY = h * 0.45

            // Cabin roof & walls
            var cabin = Path()
            cabin.move(to: CGPoint(x: cabinX - 25, y: cabinY + 25))
            cabin.addLine(to: CGPoint(x: cabinX, y: cabinY))
            cabin.addLine(to: CGPoint(x: cabinX + 35, y: cabinY + 25))
            cabin.addLine(to: CGPoint(x: cabinX + 35, y: cabinY + 55))
            cabin.addLine(to: CGPoint(x: cabinX - 25, y: cabinY + 55))
            cabin.closeSubpath()
            context.fill(cabin, with: .color(Color(red: 0.04, green: 0.07, blue: 0.08)))

            // Glowing warm yellow window
            let window = Path(roundedRect: CGRect(x: cabinX + 4, y: cabinY + 24, width: 14, height: 14), cornerRadius: 1)
            context.fill(window, with: .color(Color(red: 1.0, green: 0.85, blue: 0.35)))

            // Chimney with pixel smoke
            let chimney = Path(CGRect(x: cabinX + 18, y: cabinY - 8, width: 7, height: 16))
            context.fill(chimney, with: .color(Color(red: 0.04, green: 0.07, blue: 0.08)))

            // Lake water surface reflection
            let lake = Path(CGRect(x: 0, y: h * 0.78, width: w, height: h * 0.22))
            context.fill(lake, with: .color(Color(red: 0.03, green: 0.06, blue: 0.08)))

            // Moon reflection on water
            let reflection = Path(ellipseIn: CGRect(x: moonX - 10, y: h * 0.84, width: 20, height: 6))
            context.fill(reflection, with: .color(StudioTheme.bixelGreen.opacity(0.35)))
        }
        .overlay(alignment: .topTrailing) {
            // Pixel script "Good Pixels Brighter Tomorrows."
            VStack(alignment: .trailing, spacing: 2) {
                Text("Good Pixels")
                Text("Brighter")
                Text("Tomorrows.")
            }
            .font(.system(size: 13, weight: .medium, design: .serif))
            .italic()
            .foregroundColor(Color.white.opacity(0.45))
            .padding(.trailing, 24)
            .padding(.top, 24)
        }
    }
}

// MARK: - Quick Project Creation Dialog

struct NewProjectQuickDialog: View {
    @ObservedObject var store: ProjectStore
    let onCreated: (StudioProject) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var mode: WorkspaceMode = .normal
    @State private var width = 32
    @State private var height = 32
    @State private var cellSize = 16
    @State private var sceneOrientation: MapOrientation = .orthogonal

    private static let squarePresets: [Int] = [16, 32, 48, 64, 128, 256]
    private static let screenPresets: [(w: Int, h: Int, label: String)] = [
        (160, 144, "160×144 (GB)"),
        (240, 160, "240×160 (GBA)"),
        (320, 180, "320×180 (16:9)"),
        (320, 240, "320×240 (4:3)")
    ]

    private static let mapPresets: [(cols: Int, rows: Int, label: String)] = [
        (20, 15, "Small (20×15)"),
        (40, 25, "Standard (40×25)"),
        (60, 40, "Large (60×40)"),
        (80, 50, "Epic (80×50)")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "plus.square.fill")
                    .font(.system(size: 20))
                    .foregroundColor(StudioTheme.bixelGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Project")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Configure your canvas dimensions and workspace")
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(StudioTheme.textSecondary)
                        .padding(6)
                        .background(StudioTheme.homeCard, in: Circle())
                }
                .buttonStyle(.plain)
            }

            // Project Name
            VStack(alignment: .leading, spacing: 6) {
                Text("Project Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)

                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundColor(StudioTheme.textDisabled)
                    TextField("e.g. Hero Sprite, Dungeon Level", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                    if !name.isEmpty {
                        Button { name = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(StudioTheme.textDisabled)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(StudioTheme.homeCardBorder, lineWidth: 1)
                )
            }

            // Project Type
            VStack(alignment: .leading, spacing: 6) {
                Text("Project Type")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)

                HStack(spacing: 10) {
                    modeSelectionCard(
                        title: "Pixel Art Canvas",
                        subtitle: "Frames, layers & animation",
                        icon: "paintpalette.fill",
                        targetMode: .normal
                    )
                    modeSelectionCard(
                        title: "Scene Designer",
                        subtitle: "Infinite grid & stamping",
                        icon: "square.grid.3x3.fill",
                        targetMode: .map
                    )
                }
            }

            // Dimensions and Presets
            if mode == .normal {
                normalDimensionsSection
            } else {
                mapDimensionsSection
            }

            // Canvas Summary Pill
            summaryPill

            Divider().overlay(StudioTheme.homeCardBorder)

            // Footer
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textSecondary)

                Spacer()

                Button {
                    createProjectAction()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Create Project")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StudioTheme.bixelGreen)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(mode == .normal && (width < 1 || height < 1))
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(StudioTheme.homeDark)
        .onChange(of: mode) { value in
            if value == .normal {
                width = 32
                height = 32
            }
        }
    }

    private var normalDimensionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Dimension Inputs & Aspect Ratio
            HStack(spacing: 12) {
                dimensionField(label: "Width", value: $width, unit: "px")

                Text("×")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.top, 18)

                dimensionField(label: "Height", value: $height, unit: "px")

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Aspect Ratio")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(StudioTheme.textSecondary)
                    HStack(spacing: 5) {
                        aspectButton("1:1") { height = width }
                        aspectButton("4:3") { height = max(1, width * 3 / 4) }
                        aspectButton("16:9") { height = max(1, width * 9 / 16) }
                        aspectButton("Swap ⇄") {
                            let temp = width
                            width = height
                            height = temp
                        }
                    }
                }
            }

            // Presets Rows
            VStack(alignment: .leading, spacing: 8) {
                Text("Canvas Presets")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)

                // Row 1: Squares
                HStack(spacing: 6) {
                    ForEach(Self.squarePresets, id: \.self) { sz in
                        presetPill(label: "\(sz) × \(sz)", isSelected: width == sz && height == sz) {
                            width = sz
                            height = sz
                        }
                    }
                }

                // Row 2: Screens
                HStack(spacing: 6) {
                    ForEach(Self.screenPresets, id: \.label) { p in
                        presetPill(label: p.label, isSelected: width == p.w && height == p.h) {
                            width = p.w
                            height = p.h
                        }
                    }
                }
            }
        }
    }

    private var mapDimensionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scene Type")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)
                Picker("", selection: $sceneOrientation) {
                    ForEach(MapOrientation.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tile Size")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(StudioTheme.textSecondary)
                    HStack(spacing: 5) {
                        ForEach([8, 16, 32], id: \.self) { sz in
                            presetPill(label: "\(sz)px", isSelected: cellSize == sz) {
                                cellSize = sz
                            }
                        }
                    }
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: "infinity")
                    .font(.system(size: 11))
                    .foregroundColor(StudioTheme.bixelGreen)
                Text("Infinite scene — no size to pick. Pan and paint anywhere; saved as Tiled infinite JSON with chunks.")
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textSecondary)
            }
        }
    }

    private func modeSelectionCard(title: String, subtitle: String, icon: String, targetMode: WorkspaceMode) -> some View {
        let isSelected = mode == targetMode
        return Button {
            mode = targetMode
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? StudioTheme.bixelGreen : StudioTheme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isSelected ? .white : StudioTheme.textSecondary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textDisabled)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(StudioTheme.bixelGreen)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? StudioTheme.bixelGreenSoft : StudioTheme.panelElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? StudioTheme.bixelGreen.opacity(0.8) : StudioTheme.homeCardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func dimensionField(label: String, value: Binding<Int>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(StudioTheme.textSecondary)
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 50)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textDisabled)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(StudioTheme.homeCardBorder, lineWidth: 1)
            )
        }
    }

    private func presetPill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundColor(isSelected ? StudioTheme.bixelGreen : StudioTheme.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? StudioTheme.bixelGreenSoft : StudioTheme.homeCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? StudioTheme.bixelGreen.opacity(0.8) : StudioTheme.homeCardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func aspectButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .foregroundColor(StudioTheme.textSecondary)
                .background(StudioTheme.homeCard, in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(StudioTheme.homeCardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var summaryPill: some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .map ? "square.grid.3x3.fill" : "aspectratio")
                .font(.system(size: 11))
                .foregroundColor(StudioTheme.bixelGreen)

            if mode == .map {
                Text("Infinite scene • \(cellSize)px tiles")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                Spacer()
                Text(sceneOrientation.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(StudioTheme.textDisabled)
            } else {
                Text("\(width) × \(height) px • \(aspectRatioLabel)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                Spacer()
                Text("\(width * height) px total")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(StudioTheme.textDisabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(StudioTheme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }

    private var aspectRatioLabel: String {
        if width == height { return "1:1 Square" }
        let gcdVal = gcd(width, height)
        let rw = width / gcdVal
        let rh = height / gcdVal
        if (rw == 4 && rh == 3) || (rw == 16 && rh == 9) || (rw == 3 && rh == 2) || (rw == 10 && rh == 9) {
            return "\(rw):\(rh)"
        }
        let ratio = Double(width) / Double(max(1, height))
        return String(format: "%.2f:1", ratio)
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let t = y
            y = x % y
            x = t
        }
        return max(1, x)
    }

    private func createProjectAction() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let projName = trimmed.isEmpty ? "Untitled Project" : trimmed
        if mode == .map {
            if let project = store.createProject(name: projName, mode: .map,
                                                 width: 0, height: 0,
                                                 cellWidth: max(1, cellSize), cellHeight: max(1, cellSize),
                                                 infinite: true, orientation: sceneOrientation) {
                onCreated(project)
            }
        } else if let project = store.createProject(name: projName, mode: .normal, width: max(1, width), height: max(1, height)) {
            onCreated(project)
        }
    }
}

// MARK: - Rename Project Dialog

struct RenameProjectDialog: View {
    let project: StudioProject
    @Binding var name: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Project").font(.headline)
            TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onDone(trimmed) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(StudioTheme.homeDark)
    }
}
