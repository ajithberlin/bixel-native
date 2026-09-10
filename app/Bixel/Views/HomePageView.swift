// HomePageView.swift
//
// Native macOS Home Page & Dashboard for Bixel Studio:
// - Top Bar: Bixel logo, search bar with ⌘K
// - Hero Banner: Pixel art forest scene with glowing moon, headline, and quick action bar
// - AI Studio Creator: High-end conversational AI prompt composer with modes, sizes, and instant creation
// - Recent Projects Grid: Pixel art thumbnail previews, tag badges, dimensions, and click-to-open
// - Templates & Inspirations: "Pixel Village", "Character Base", "RPG Icons" + Quote box

import SwiftUI
import AppKit

struct HomePageView: View {
    @ObservedObject var store: ProjectStore
    let onOpenProject: (StudioProject) -> Void
    let onOpenWithAIPrompt: (String) -> Void
    var onPresentPaywall: (() -> Void)? = nil
    var onPresentCustomerCenter: (() -> Void)? = nil

    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    @State private var searchText = ""
    @State private var showNewProjectSheet = false
    @State private var aiPrompt = ""
    @State private var selectedSize: Int = 32
    @State private var selectedStyle: String = "16-Bit Retro"
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

                    // 4. Bottom Section: Templates & Inspirations + Quote
                    HStack(alignment: .top, spacing: 24) {
                        templatesSection
                            .frame(maxWidth: .infinity, alignment: .leading)

                        quoteCard
                            .frame(width: 300)
                    }

                    // 5. Ad Banner (displayed only for free-tier users)
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
        .frame(minWidth: 1060, minHeight: 720)
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

                    heroQuickButton(title: "New Map", subtitle: "Stamp and design", icon: "map") {
                        if let project = store.createProject(name: "New Map", mode: .map, width: 40, height: 25) {
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

                    TextField("Describe what you want to create or design... (e.g., 'A 32x32 cyber slime monster with electric aura and idle bounce', 'Dungeon crypt tileset with stone walls and torches')", text: $aiPrompt, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .focused($promptFieldFocused)
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
                        Button("16 × 16 px") { selectedSize = 16 }
                        Button("32 × 32 px") { selectedSize = 32 }
                        Button("64 × 64 px") { selectedSize = 64 }
                        Button("128 × 128 px") { selectedSize = 128 }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "aspectratio")
                                .font(.system(size: 10))
                            Text("\(selectedSize) × \(selectedSize)")
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

                    // Art Style Menu
                    Menu {
                        Button("16-Bit Retro") { selectedStyle = "16-Bit Retro" }
                        Button("Classic 8-Bit") { selectedStyle = "Classic 8-Bit" }
                        Button("Cyberpunk Neon") { selectedStyle = "Cyberpunk Neon" }
                        Button("Fantasy RPG") { selectedStyle = "Fantasy RPG" }
                        Button("Game Boy (4 Colors)") { selectedStyle = "Game Boy (4 Colors)" }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 10))
                            Text(selectedStyle)
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
                    }

                    // Prominent "Design & Create" Action Button
                    Button {
                        submitAIPrompt()
                    } label: {
                        HStack(spacing: 7) {
                            Text("Design & Create")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 14, weight: .bold))
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
                    .disabled(aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            if let project = store.createProject(name: name, mode: .normal, width: 64, height: 64) {
                onOpenProject(project)
            }
        }
    }
}

// MARK: - Recent Project Card

struct RecentProjectCard: View {
    let project: StudioProject
    let metadata: (mode: WorkspaceMode, sizeText: String, timeText: String)
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
            return (StudioTheme.tagMapBg, StudioTheme.tagMapText, "Map")
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
                Text("Project Type").font(.caption).foregroundColor(StudioTheme.textSecondary)
                Picker("", selection: $mode) {
                    Text("Normal").tag(WorkspaceMode.normal)
                    Text("Map").tag(WorkspaceMode.map)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode == .map ? "Columns" : "Width (px)")
                        .font(.caption).foregroundColor(StudioTheme.textSecondary)
                    TextField("", value: $width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode == .map ? "Rows" : "Height (px)")
                        .font(.caption).foregroundColor(StudioTheme.textSecondary)
                    TextField("", value: $height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                if mode == .map {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tile (px)").font(.caption).foregroundColor(StudioTheme.textSecondary)
                        TextField("", value: $cellSize, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                }

                Spacer()

                // Quick presets
                if mode != .map {
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
            }

            Divider().overlay(StudioTheme.homeCardBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Project") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let projName = trimmed.isEmpty ? "Untitled Project" : trimmed
                    if mode == .map {
                        if let project = store.createProject(name: projName, mode: .map,
                                                             width: max(1, width), height: max(1, height),
                                                             cellWidth: max(1, cellSize), cellHeight: max(1, cellSize)) {
                            onCreated(project)
                        }
                    } else if let project = store.createProject(name: projName, mode: .normal, width: width, height: height) {
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
        .onChange(of: mode) { value in
            if value == .map {
                width = 40
                height = 25
            } else if width == 40 && height == 25 {
                width = 32
                height = 32
            }
        }
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
