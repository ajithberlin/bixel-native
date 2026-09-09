// HomePageView.swift
//
// Native macOS Home Page & Dashboard for Bixel Studio:
// - Top Bar: Bixel logo, search bar with ⌘K, cloud sync status, notifications, settings, avatar
// - Left Sidebar: Home, Projects, Templates, Assets, Trash
// - Hero Banner: Pixel art forest scene with glowing moon, headline, and quick action bar
// - AI Creator Bar: "Ask Bixel AI to create, design..." with quick prompt chips
// - Recent Projects Grid: Pixel art thumbnail previews, tag badges, dimensions, and click-to-open
// - Right Column: Sync & Storage card, Recent Activity card
// - Templates & Inspirations: "Pixel Village", "Character Base", "RPG Icons" + Quote box

import SwiftUI
import AppKit

enum HomeNavTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case projects = "Projects"
    case templates = "Templates"
    case assets = "Assets"
    case trash = "Trash"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .projects: return "folder.fill"
        case .templates: return "cube.fill"
        case .assets: return "shippingbox.fill"
        case .trash: return "trash"
        }
    }
}

struct HomePageView: View {
    @ObservedObject var store: ProjectStore
    let onOpenProject: (StudioProject) -> Void
    let onOpenWithAIPrompt: (String) -> Void

    @State private var selectedTab: HomeNavTab = .home
    @State private var searchText = ""
    @State private var showNewProjectSheet = false
    @State private var showSettingsSheet = false
    @State private var showAIChatSheet = false
    @State private var aiPrompt = ""
    @State private var renamingProject: StudioProject? = nil
    @State private var renameText = ""
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // 1. LEFT SIDEBAR
            sidebar
                .frame(width: 140)
                .background(StudioTheme.homeDark)

            Divider()
                .overlay(StudioTheme.homeCardBorder)

            // 2. MAIN CONTENT AREA
            VStack(spacing: 0) {
                // TOP HEADER BAR
                topHeaderBar
                    .frame(height: 56)
                    .background(StudioTheme.homeDark)

                Divider()
                    .overlay(StudioTheme.homeCardBorder)

                // SCROLLABLE DASHBOARD
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 24) {
                        // Hero Banner
                        heroBanner

                        // AI Creator & Design Prompt Bar
                        aiCreatorBar

                        // Middle Section: Recent Projects & Right Column (Storage + Activity)
                        HStack(alignment: .top, spacing: 20) {
                            // Recent Projects Grid
                            recentProjectsSection
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // Right Column (Sync & Storage + Activity)
                            VStack(spacing: 16) {
                                syncStorageCard
                                recentActivityCard
                            }
                            .frame(width: 280)
                        }

                        // Bottom Section: Templates & Inspirations + Quote
                        HStack(alignment: .top, spacing: 20) {
                            templatesSection
                                .frame(maxWidth: .infinity, alignment: .leading)

                            quoteCard
                                .frame(width: 280)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
            .background(StudioTheme.homeDark)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectQuickDialog(store: store) { project in
                showNewProjectSheet = false
                onOpenProject(project)
            }
        }
        .sheet(isPresented: $showAIChatSheet) {
            HomeAIChatDialog(session: store.assistant) { prompt in
                showAIChatSheet = false
                onOpenWithAIPrompt(prompt)
            }
        }
        .sheet(item: $renamingProject) { project in
            RenameProjectDialog(project: project, name: $renameText) { newName in
                store.renameProject(project, newName: newName)
                renamingProject = nil
            }
        }
    }

    // MARK: - Top Header Bar

    private var topHeaderBar: some View {
        HStack(spacing: 16) {
            // Brand Logo & Title
            HStack(spacing: 10) {
                BixelSlimeLogo(size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Bixel Studio")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("PIXEL ART FOR BIG IDEAS")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(StudioTheme.textSecondary)
                        .tracking(1.2)
                }
            }
            .padding(.leading, 12)

            Spacer()

            // Search Bar with ⌘K
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
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(StudioTheme.homeCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                    )
            )

            Spacer()

            // Status & User Actions
            HStack(spacing: 12) {
                // Cloud Sync Status
                HStack(spacing: 6) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 13))
                        .foregroundColor(StudioTheme.textSecondary)
                    Circle()
                        .fill(StudioTheme.bixelGreen)
                        .frame(width: 6, height: 6)
                }
                .help("Storage synced to local library")

                // Notification Bell
                Button {} label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .font(.system(size: 14))
                            .foregroundColor(StudioTheme.textSecondary)
                        Circle()
                            .fill(StudioTheme.bixelGreen)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -2)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                // Settings
                Button { showSettingsSheet.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(StudioTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettingsSheet) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bixel Studio").font(.headline)
                        Text("Native macOS Pixel Art Studio").font(.caption).foregroundColor(.secondary)
                        Divider()
                        Text("Version 0.1.0 (Metal + Rust)").font(.caption2).foregroundColor(.secondary)
                        Text("Storage: ~/Documents/Bixel/Projects").font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(16)
                    .frame(width: 240)
                }

                // Pixel Avatar
                PixelAvatarView(size: 28)
            }
            .padding(.trailing, 16)
        }
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Navigation Links
            VStack(spacing: 4) {
                ForEach(HomeNavTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 12) {
                            // Active pill on left edge
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(StudioTheme.bixelGreen)
                                    .frame(width: 3, height: 18)
                            } else {
                                Color.clear
                                    .frame(width: 3, height: 18)
                            }

                            Image(systemName: tab.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(selectedTab == tab ? StudioTheme.bixelGreen : StudioTheme.textSecondary)
                                .frame(width: 18)

                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundColor(selectedTab == tab ? .white : StudioTheme.textSecondary)

                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .background(
                            selectedTab == tab ?
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)) :
                                nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 16)

            Spacer()

            // Sidebar Footer Text: "SMALL PIXELS BIG WORLDS ."
            VStack(alignment: .leading, spacing: 3) {
                Text("SMALL")
                Text("PIXELS")
                Text("BIG")
                Text("WORLDS")
                Text(".")
                    .foregroundColor(StudioTheme.bixelGreen)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(StudioTheme.textDisabled)
            .lineSpacing(2)
            .padding(.leading, 18)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            // Background Artwork (Pixel Forest Landscape at Night)
            HeroPixelLandscape()
                .frame(height: 230)
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
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .lineSpacing(2)

                    Text("Turn your ideas into sprites, animations, tilesets and more.")
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

                    // Secondary Quick Actions: Sprite, Animation, Tileset, Import
                    heroQuickButton(title: "New Sprite", subtitle: "Single frame", icon: "pencil") {
                        if let project = store.createProject(name: "New Sprite", kind: .sprite, width: 32, height: 32) {
                            onOpenProject(project)
                        }
                    }

                    heroQuickButton(title: "New Animation", subtitle: "Multiple frames", icon: "square.stack.3d.down.right.fill") {
                        if let project = store.createProject(name: "New Animation", kind: .animation, width: 64, height: 64) {
                            onOpenProject(project)
                        }
                    }

                    heroQuickButton(title: "New Tileset", subtitle: "Tile map", icon: "squareshape.split.2x2") {
                        if let project = store.createProject(name: "New Tileset", kind: .tileset, width: 128, height: 128) {
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

    // MARK: - AI Creator & Design Prompt Bar ("add tai chat to create, design")

    private var aiCreatorBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // AI Sparkle badge
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(StudioTheme.bixelGreen)
                    Text("Bixel AI")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StudioTheme.bixelGreenSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(StudioTheme.bixelGreen.opacity(0.35), lineWidth: 1)
                        )
                )

                // Prompt Input Box
                HStack(spacing: 8) {
                    TextField("Ask AI to create or design... (e.g., 'A 32x32 cyber ninja sprite', 'Dungeon crypt tileset')", text: $aiPrompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .onSubmit {
                            submitAIPrompt()
                        }

                    if !aiPrompt.isEmpty {
                        Button { aiPrompt = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(StudioTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // Send / Generate Button
                    Button {
                        submitAIPrompt()
                    } label: {
                        HStack(spacing: 5) {
                            Text("Design")
                                .font(.system(size: 11, weight: .bold))
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 14))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(StudioTheme.bixelGreen)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StudioTheme.homeCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                        )
                )

                // Open AI Chat Button
                Button {
                    showAIChatSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 12))
                        Text("AI Chat")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(StudioTheme.homeCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Chat with Bixel AI Agent to brainstorm and plan game assets")
            }

            // Quick Prompt Suggestion Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    promptChip("✨ Slime Sprite (32×32)") {
                        aiPrompt = "Create a cute 32x32 animated slime sprite with bounce frames"
                        submitAIPrompt()
                    }
                    promptChip("🏰 Dungeon Tileset (128×128)") {
                        aiPrompt = "Design a 128x128 dungeon crypt tileset with stone walls and torches"
                        submitAIPrompt()
                    }
                    promptChip("⚔️ RPG Weapon Icons") {
                        aiPrompt = "Generate 32x32 fantasy RPG items: sword, magic shield, ruby potion"
                        submitAIPrompt()
                    }
                    promptChip("🏃 64×64 Character Walk") {
                        aiPrompt = "Design a 64x64 pixel art character walk cycle animation"
                        submitAIPrompt()
                    }
                    promptChip("🌆 Tokyo Cyberpunk Alley") {
                        aiPrompt = "Create a futuristic Tokyo cyberpunk street tileset with neon lights"
                        submitAIPrompt()
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.homeCard.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(StudioTheme.bixelGreen.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func promptChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(StudioTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.white.opacity(0.06))
                        .overlay(Capsule().strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func submitAIPrompt() {
        let text = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        aiPrompt = ""
        onOpenWithAIPrompt(text)
    }

    // MARK: - Recent Projects Section

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Title & "See All ->"
            HStack {
                Text("Recent Projects")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Button {
                    selectedTab = .projects
                } label: {
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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(list) { project in
                        RecentProjectCard(
                            project: project,
                            metadata: store.metadata(for: project),
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

    // MARK: - Right Column: Sync & Storage + Recent Activity

    private var syncStorageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title & Status
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(StudioTheme.homeCardBorder)
                        .frame(width: 32, height: 32)
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 14))
                        .foregroundColor(StudioTheme.textSecondary)
                    Circle()
                        .fill(StudioTheme.bixelGreen)
                        .frame(width: 6, height: 6)
                        .offset(x: 10, y: -8)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Sync & Storage")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Text("Synced just now")
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textSecondary)
                }

                Spacer()
            }

            // Storage Progress Bar
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 6)

                        Capsule()
                            .fill(StudioTheme.bixelGreen)
                            .frame(width: geo.size.width * 0.24, height: 6)
                    }
                }
                .frame(height: 6)

                Text("2.4 GB of 10 GB used")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
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

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(StudioTheme.textSecondary)
                Text("Recent Activity")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }

            // Items
            VStack(spacing: 10) {
                ForEach(SamplePixelArt.sampleActivities) { item in
                    HStack(spacing: 10) {
                        // Mini thumbnail preview
                        PixelPreviewThumb(name: item.projectName, size: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.action)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(item.timeAgo)
                                .font(.system(size: 10))
                                .foregroundColor(StudioTheme.textDisabled)
                        }

                        Spacer()
                    }
                }
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

    // MARK: - Bottom Section: Templates & Inspirations + Quote

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Templates & Inspirations")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Button {
                    selectedTab = .templates
                } label: {
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

            HStack(spacing: 14) {
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            if let project = store.createProject(name: name, kind: .image, width: 64, height: 64) {
                onOpenProject(project)
            }
        }
    }
}

// MARK: - Recent Project Card

struct RecentProjectCard: View {
    let project: StudioProject
    let metadata: (kind: AssetKind, sizeText: String, timeText: String)
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                // Pixel Art Preview Thumbnail
                PixelPreviewThumb(name: project.name, size: 76)
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

                    // Tag Badge (Sprite, Animation, Tileset)
                    tagBadge(kind: metadata.kind)

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

    private func tagBadge(kind: AssetKind) -> some View {
        let (bg, fg, title) = tagInfo(for: kind)
        return Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(bg))
    }

    private func tagInfo(for kind: AssetKind) -> (Color, Color, String) {
        switch kind {
        case .sprite, .image:
            return (StudioTheme.tagSpriteBg, StudioTheme.tagSpriteText, "Sprite")
        case .animation:
            return (StudioTheme.tagAnimationBg, StudioTheme.tagAnimationText, "Animation")
        case .tileset, .map, .spritesheet:
            return (StudioTheme.tagTilesetBg, StudioTheme.tagTilesetText, "Tileset")
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

// MARK: - Pixel Avatar View

struct PixelAvatarView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.2, green: 0.35, blue: 0.25))
                .frame(width: size, height: size)

            if let img = SamplePixelArt.makePreviewImage(for: "portrait", width: 24, height: 24) {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .clipShape(Circle())
                    .frame(width: size - 2, height: size - 2)
            }
        }
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
    @State private var kind: AssetKind = .sprite
    @State private var width = 32
    @State private var height = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create New Project")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                Text("Project Name").font(.caption).foregroundColor(StudioTheme.textSecondary)
                TextField("e.g. Hero Sprite, Dungeon Map", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Asset Type").font(.caption).foregroundColor(StudioTheme.textSecondary)
                Picker("", selection: $kind) {
                    Text("Sprite").tag(AssetKind.sprite)
                    Text("Animation").tag(AssetKind.animation)
                    Text("Tileset").tag(AssetKind.tileset)
                    Text("Image").tag(AssetKind.image)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width (px)").font(.caption).foregroundColor(StudioTheme.textSecondary)
                    TextField("", value: $width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Height (px)").font(.caption).foregroundColor(StudioTheme.textSecondary)
                    TextField("", value: $height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                Spacer()

                // Quick presets
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Presets").font(.caption).foregroundColor(StudioTheme.textSecondary)
                    HStack(spacing: 6) {
                        presetButton("16²") { width = 16; height = 16 }
                        presetButton("32²") { width = 32; height = 32 }
                        presetButton("64²") { width = 64; height = 64 }
                        presetButton("128²") { width = 128; height = 128 }
                    }
                }
            }

            Divider().overlay(StudioTheme.homeCardBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Project") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let projName = trimmed.isEmpty ? "Untitled Project" : trimmed
                    if let project = store.createProject(name: projName, kind: kind, width: width, height: height) {
                        onCreated(project)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.bixelGreen)
                .foregroundColor(.black)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(StudioTheme.homeDark)
    }

    private func presetButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(StudioTheme.homeCard, in: RoundedRectangle(cornerRadius: 4))
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

// MARK: - Home AI Chat Dialog

struct HomeAIChatDialog: View {
    @ObservedObject var session: AssistantSession
    let onStartDesign: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var promptText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    BixelSlimeLogo(size: 20)
                    Text("Bixel AI Assistant")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(StudioTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Text("Describe what you want to create or design. Bixel AI will create the project, configure layers, and start painting.")
                .font(.system(size: 12))
                .foregroundColor(StudioTheme.textSecondary)

            TextEditor(text: $promptText)
                .font(.system(size: 13))
                .frame(height: 120)
                .padding(8)
                .background(StudioTheme.homeCard, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onStartDesign(trimmed)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("Create & Design")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.bixelGreen)
                .foregroundColor(.black)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(StudioTheme.homeDark)
    }
}
