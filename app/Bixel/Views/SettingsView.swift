// SettingsView.swift
//
// The app-universal Settings window, in the spirit of macOS System Settings:
// a sidebar of panes over a grouped detail. It owns the provider connection,
// the goose skill catalog, MCP server management, app preferences, and the
// About/version pane. Every AI setting here writes through to goose's own
// config store under the app-owned GOOSE_PATH_ROOT, so the CLI and the agent
// see the same state.

import SwiftUI
import AppKit

enum AppSettingsRoute: Equatable {
    case swiftUI
    case legacySelector(String)
}

/// Opens the app-universal Settings window from anywhere (AI panel, canvas,
/// image-generation prompts) instead of presenting a separate provider sheet.
enum AppSettings {
    static let openRequest = Notification.Name("BixelOpenAppSettings")

    static func route(for version: OperatingSystemVersion) -> AppSettingsRoute {
        if version.majorVersion >= 14 { return .swiftUI }
        if version.majorVersion >= 13 { return .legacySelector("showSettingsWindow:") }
        return .legacySelector("showPreferencesWindow:")
    }

    static func requestOpen() {
        NotificationCenter.default.post(name: openRequest, object: nil)
    }

    @discardableResult
    static func openLegacy() -> Bool {
        guard case .legacySelector(let name) = route(for: ProcessInfo.processInfo.operatingSystemVersion) else {
            return false
        }
        return NSApp.sendAction(Selector(name), to: nil, from: nil)
    }
}

/// Uses SwiftUI's supported Settings presentation on macOS 14+, with the
/// scene action selectors retained for older macOS releases.
struct AppSettingsButton<Label: View>: View {
    private let label: Label

    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { label }
        } else {
            Button(action: { _ = AppSettings.openLegacy() }) { label }
        }
    }
}

/// A zero-size bridge for non-View callbacks that need to open the Settings
/// scene, such as the assistant's initial connection prompt.
struct AppSettingsOpener: View {
    var openOnAppear = false

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                ModernAppSettingsOpener(openOnAppear: openOnAppear)
            } else {
                LegacyAppSettingsOpener(openOnAppear: openOnAppear)
            }
        }
        .frame(width: 0, height: 0)
    }
}

@available(macOS 14.0, *)
private struct ModernAppSettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    let openOnAppear: Bool

    var body: some View {
        Color.clear
            .onAppear {
                if openOnAppear { openSettings() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AppSettings.openRequest)) { _ in
                openSettings()
            }
    }
}

private struct LegacyAppSettingsOpener: View {
    let openOnAppear: Bool

    var body: some View {
        Color.clear
            .onAppear {
                if openOnAppear { _ = AppSettings.openLegacy() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AppSettings.openRequest)) { _ in
                _ = AppSettings.openLegacy()
            }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case provider
    case skills
    case mcp
    case general
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider: return "Provider"
        case .skills: return "Skills"
        case .mcp: return "MCP Servers"
        case .general: return "General"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .provider: return "sparkles"
        case .skills: return "square.stack.3d.up"
        case .mcp: return "server.rack"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .provider: return StudioTheme.accent
        case .skills: return StudioTheme.bixelGreen
        case .mcp: return .orange
        case .general: return .gray
        case .about: return .teal
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane? = .provider

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            Group {
                switch pane ?? .provider {
                case .provider: ProviderSettingsPane().padding(20)
                case .skills: SkillsSettingsPane()
                case .mcp: MCPSettingsPane()
                case .general: GeneralSettingsPane()
                case .about: AboutSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioTheme.background)
            .navigationTitle((pane ?? .provider).title)
        }
        .frame(minWidth: 780, minHeight: 560)
        .foregroundColor(StudioTheme.textPrimary)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Shared building blocks

/// A titled, hairline-bordered card used to group settings rows.
struct SettingsSection<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(StudioTheme.textPrimary)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .studioSurface()
            if let footer {
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var tint: Color = StudioTheme.textSecondary
    var showsDivider: Bool = true
    @ViewBuilder var trailing: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(StudioTheme.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            }
        }
    }
}

/// A small rounded capability/kind badge.
struct SettingsBadge: View {
    let text: String
    var color: Color = StudioTheme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }
}

// MARK: - Skills

struct SkillsSettingsPane: View {
    @State private var skills: [AIService.InstalledSkillInfo] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?

    private var enabledCount: Int { skills.filter(\.enabled).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader(
                    "Skills",
                    subtitle: "Agent skills installed under goose's global skills directory. Disabled skills are hidden from the assistant's catalog."
                )

                if let error {
                    banner(error, color: .orange, icon: "exclamationmark.triangle")
                }

                SettingsSection(title: "Installed Skills", systemImage: "square.stack.3d.up",
                                footer: "\(enabledCount) of \(skills.count) enabled. Bundled skills are re-synced on launch.") {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("Loading skills…").font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary) }
                            .padding(.vertical, 10)
                    } else if skills.isEmpty {
                        Text("No skills installed.")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.textDisabled)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                            skillRow(skill, showsDivider: index < skills.count - 1)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        revealSkillsFolder()
                    } label: {
                        Label("Reveal Skills Folder", systemImage: "folder")
                    }
                    .controlSize(.small)

                    Button {
                        load()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(loading || busy)
                    Spacer()
                }
            }
            .padding(20)
        }
        .onAppear(perform: load)
    }

    private func skillRow(_ skill: AIService.InstalledSkillInfo, showsDivider: Bool) -> some View {
        SettingsRow(
            title: skill.name,
            subtitle: skill.description,
            systemImage: "doc.text",
            tint: skill.enabled ? StudioTheme.bixelGreen : StudioTheme.textDisabled,
            showsDivider: showsDivider
        ) {
            HStack(spacing: 8) {
                if skill.source == "builtin skill" {
                    SettingsBadge(text: "Built-in", color: StudioTheme.accent)
                } else {
                    SettingsBadge(text: skill.global ? "Global" : "Project",
                                  color: skill.global ? StudioTheme.textSecondary : StudioTheme.bixelGreen)
                }
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { toggle(skill, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(busy)
            }
        }
    }

    private func toggle(_ skill: AIService.InstalledSkillInfo, _ enabled: Bool) {
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.setSkillEnabled(name: skill.name, enabled: enabled)
            DispatchQueue.main.async {
                busy = false
                if let result { error = result } else { load() }
            }
        }
    }

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.listInstalledSkills(base: "")
            DispatchQueue.main.async {
                skills = result
                loading = false
            }
        }
    }

    private func revealSkillsFolder() {
        guard let path = AIService.appPaths()?.skills_dir, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - MCP servers

struct MCPSettingsPane: View {
    @State private var servers: [AIService.MCPExtensionInfo] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var editing: AIService.MCPExtensionInfo?
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader(
                    "MCP Servers",
                    subtitle: "Model Context Protocol extensions Goose starts with each session. Credentials stay in Goose's config store."
                )

                if let error {
                    banner(error, color: .orange, icon: "exclamationmark.triangle")
                }

                SettingsSection(title: "Configured Servers", systemImage: "server.rack",
                                footer: "Disabled servers are not started. Bundled/platform extensions are managed by Goose.") {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("Loading servers…").font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary) }
                            .padding(.vertical, 10)
                    } else if servers.isEmpty {
                        Text("No MCP servers configured.")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.textDisabled)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                            serverRow(server, showsDivider: index < servers.count - 1)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        editing = nil
                        showEditor = true
                    } label: {
                        Label("Add Server…", systemImage: "plus")
                    }
                    .controlSize(.small)

                    Button {
                        load()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(loading || busy)
                    Spacer()
                }
            }
            .padding(20)
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showEditor) {
            MCPServerEditor(server: editing, onSave: { spec in save(spec) })
        }
    }

    private func serverRow(_ server: AIService.MCPExtensionInfo, showsDivider: Bool) -> some View {
        SettingsRow(
            title: server.display_name ?? server.name,
            subtitle: server.summary,
            systemImage: server.type == "streamable_http" ? "network" : "terminal",
            tint: server.enabled ? StudioTheme.bixelGreen : StudioTheme.textDisabled,
            showsDivider: showsDivider
        ) {
            HStack(spacing: 8) {
                SettingsBadge(text: server.transportLabel,
                              color: server.type == "stdio" ? .orange : StudioTheme.accent)
                if !server.bundled {
                    Toggle("", isOn: Binding(
                        get: { server.enabled },
                        set: { setEnabled(server, $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(busy)

                    Button {
                        editing = server
                        showEditor = true
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(StudioTheme.textSecondary)

                    Button {
                        remove(server)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.orange)
                    .disabled(busy)
                } else {
                    SettingsBadge(text: "Managed", color: StudioTheme.textSecondary)
                }
            }
        }
    }

    private func save(_ spec: [String: Any]) {
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.saveMCP(spec)
            DispatchQueue.main.async {
                busy = false
                if let result { error = result } else { load() }
            }
        }
    }

    private func remove(_ server: AIService.MCPExtensionInfo) {
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.removeMCP(key: server.key)
            DispatchQueue.main.async {
                busy = false
                if let result { error = result } else { load() }
            }
        }
    }

    private func setEnabled(_ server: AIService.MCPExtensionInfo, _ enabled: Bool) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AIService.setMCPEnabled(key: server.key, enabled: enabled)
            DispatchQueue.main.async {
                busy = false
                load()
            }
        }
    }

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.listMCP()
            DispatchQueue.main.async {
                servers = result
                loading = false
            }
        }
    }
}

/// Add/edit sheet for a stdio or streamable-HTTP MCP server.
struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    var server: AIService.MCPExtensionInfo?
    var onSave: ([String: Any]) -> Void

    @State private var name = ""
    @State private var kind = "stdio"
    @State private var command = ""
    @State private var args = ""
    @State private var uri = ""
    @State private var headers = ""
    @State private var env = ""
    @State private var timeout = ""
    @State private var enabled = true
    @State private var error: String?

    private var isEditing: Bool { server != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isEditing ? "Edit MCP Server" : "Add MCP Server")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button("Cancel") { dismiss() }.controlSize(.small)
            }
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Name", text: $name, placeholder: "firecrawl")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transport").font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
                        Picker("", selection: $kind) {
                            Text("stdio").tag("stdio")
                            Text("Streamable HTTP").tag("streamable_http")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if kind == "stdio" {
                        field("Command", text: $command, placeholder: "npx", mono: true)
                        field("Arguments (one per line)", text: $args, placeholder: "-y\nfirecrawl-mcp", mono: true, multiline: true)
                    } else {
                        field("Server URI", text: $uri, placeholder: "https://example.com/mcp", mono: true)
                        field("Headers (KEY=VALUE per line)", text: $headers, placeholder: "Authorization=Bearer …", mono: true, multiline: true)
                    }

                    field("Environment (KEY=VALUE per line)", text: $env, placeholder: "API_KEY=…", mono: true, multiline: true)
                    if isEditing {
                        Text("Existing secret values are kept automatically — list a variable name to keep it, or add KEY=VALUE to replace it.")
                            .font(.system(size: 9))
                            .foregroundColor(StudioTheme.textDisabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    field("Timeout (seconds)", text: $timeout, placeholder: "300", mono: true)

                    Toggle("Enabled", isOn: $enabled)
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    if let error {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 12)
            }

            HStack {
                Spacer()
                Button(isEditing ? "Save" : "Add") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.accent)
                    .controlSize(.small)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(StudioTheme.hairline).frame(height: 1) }
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .foregroundColor(StudioTheme.textPrimary)
        .background(StudioTheme.background)
        .onAppear(perform: populate)
    }

    private func populate() {
        guard let server else { return }
        name = server.name
        kind = server.type == "streamable_http" ? "streamable_http" : "stdio"
        command = server.command ?? ""
        args = server.args.joined(separator: "\n")
        uri = server.uri ?? ""
        env = server.env_keys.joined(separator: "\n")
        timeout = server.timeout.map(String.init) ?? ""
        enabled = server.enabled
    }

    private func save() {
        var spec: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "type": kind,
            "enabled": enabled,
        ]
        if !timeout.trimmingCharacters(in: .whitespaces).isEmpty {
            spec["timeout"] = Int(timeout.trimmingCharacters(in: .whitespaces)) ?? 300
        }
        let envMap = parsePairs(env)
        spec["env"] = envMap
        if kind == "stdio" {
            spec["command"] = command.trimmingCharacters(in: .whitespaces)
            spec["args"] = args.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            spec["uri"] = uri.trimmingCharacters(in: .whitespaces)
            spec["headers"] = parsePairs(headers)
        }
        onSave(spec)
        dismiss()
    }

    private func parsePairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String = "", mono: Bool = false, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
            if multiline {
                TextEditor(text: text)
                    .font(.system(size: 11, design: mono ? .monospaced : .default))
                    .frame(minHeight: 54)
                    .padding(4)
                    .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: mono ? .monospaced : .default))
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @AppStorage("bixel.openAssistantOnLaunch") private var openAssistantOnLaunch = false
    @AppStorage("bixel.defaultSnapping") private var defaultSnapping = true
    @AppStorage("bixel.defaultFrameRate") private var defaultFrameRate = 12.0

    private let frameRates: [Double] = [4, 8, 12, 24, 30, 60]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader("General", subtitle: "Studio-wide defaults, saved for this Mac and applied the next time the app launches.")

                SettingsSection(title: "Assistant", systemImage: "sparkles") {
                    SettingsRow(title: "Open assistant on launch", subtitle: "Show the AI panel when a project opens.", systemImage: "sidebar.right", showsDivider: false) {
                        Toggle("", isOn: $openAssistantOnLaunch).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                }

                SettingsSection(title: "Editor Defaults", systemImage: "paintbrush") {
                    SettingsRow(title: "Snapping", subtitle: "Snap transforms and selections to whole pixels.", systemImage: "dot.squareshape.split.2x2") {
                        Toggle("", isOn: $defaultSnapping).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    SettingsRow(title: "Default frame rate", subtitle: "Animation playback speed for new workspaces.", systemImage: "timer", showsDivider: false) {
                        Picker("", selection: $defaultFrameRate) {
                            ForEach(frameRates, id: \.self) { Text("\(Int($0)) FPS").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .controlSize(.small)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - About

struct AboutSettingsPane: View {
    @State private var paths: AIService.AppPathsInfo?

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Bixel Studio"
    }

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    appIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Version \(version) (\(build))")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.textSecondary)
                        Text("2D pixel-art game-asset studio for macOS.")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.textDisabled)
                    }
                    Spacer()
                }

                SettingsSection(title: "Build", systemImage: "hammer") {
                    aboutRow("Version", "\(version) (\(build))")
                    aboutRow("AI engine", AIService.available() ? "Goose agent · connected" : "Goose agent · idle")
                    aboutRow("Platform", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", showsDivider: false)
                }

                SettingsSection(title: "Storage", systemImage: "internaldrive",
                                footer: "Goose owns provider credentials in its secret store; the app only ever sees a masked key.") {
                    pathRow("Goose root", paths?.goose_root)
                    pathRow("Config file", paths?.goose_config)
                    pathRow("Skills folder", paths?.skills_dir)
                    pathRow("Python venv", paths?.venv_dir)
                    aboutRow("Secrets", paths?.secrets ?? "goose secret store", showsDivider: false)
                }

                HStack {
                    Spacer()
                    Text("© \(Calendar.current.component(.year, from: Date())) Bixel Studio")
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textDisabled)
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = AIService.appPaths()
                DispatchQueue.main.async { paths = result }
            }
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StudioTheme.accentSoft)
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "paintbrush.pointed.fill").font(.system(size: 26)).foregroundColor(StudioTheme.accent))
            }
        }
    }

    private func aboutRow(_ title: String, _ value: String, showsDivider: Bool = true) -> some View {
        SettingsRow(title: title, subtitle: value, showsDivider: showsDivider) { EmptyView() }
    }

    private func pathRow(_ title: String, _ value: String?) -> some View {
        SettingsRow(title: title, subtitle: value?.isEmpty == false ? value : "—", systemImage: "folder") {
            Button {
                if let value, !value.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)])
                }
            } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(StudioTheme.textSecondary)
            .disabled(value?.isEmpty != false)
        }
    }
}

// MARK: - Pane helpers

@ViewBuilder
private func paneHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
        Text(subtitle)
            .font(.system(size: 11))
            .foregroundColor(StudioTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@ViewBuilder
private func banner(_ message: String, color: Color, icon: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
        Image(systemName: icon).foregroundColor(color)
        Text(message)
            .font(.system(size: 11))
            .foregroundColor(StudioTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
    }
    .padding(10)
    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
}
