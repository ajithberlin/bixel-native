import SwiftUI

/// Goose-aligned provider settings. A provider owns its model catalog; Codex
/// exposes one primary model with hosted chat/vision/image capabilities, while
/// OpenRouter may opt into separate vision/image routing under Advanced.
///
/// The pane is embedded by the app-universal `SettingsView`; `AISettingsView`
/// is a standalone sheet wrapper kept for the AI panel's setup shortcut.
struct ProviderSettingsPane: View {
    @State private var status = AIService.connectionStatus()
    @State private var provider = "openrouter"
    @State private var apiKey = ""
    @State private var primaryModel = ""
    @State private var visionModel = ""
    @State private var imageModel = ""
    @State private var catalog = AIService.AIModelCatalog()
    @State private var loadingCatalog = false
    @State private var advancedRouting = false
    @State private var busy = false
    @State private var signingIn = false
    @State private var message: String?

    private static let roles = ["text", "vision", "image"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                providerChooser
                providerConfiguration
                modelConfiguration
                readinessList
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(message == "Connected." ? StudioTheme.bixelGreen : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .padding(.bottom, 14)
        }
        .onAppear(perform: refresh)
        .onDisappear { if signingIn { AIService.cancelCodexOAuth() } }
    }

    private var providerChooser: some View {
        HStack(spacing: 9) {
            providerCard(
                id: "chatgpt_codex",
                title: "ChatGPT (Codex)",
                detail: "OAuth · hosted image tool",
                icon: "sparkles"
            )
            providerCard(
                id: "openrouter",
                title: "OpenRouter",
                detail: "API key · routed models",
                icon: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private func providerCard(id: String, title: String, detail: String, icon: String) -> some View {
        Button {
            guard provider != id else { return }
            provider = id
            applyProviderDefaults(id)
            loadCatalog()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if provider == id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(StudioTheme.accent)
                    }
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(provider == id ? StudioTheme.textSecondary : StudioTheme.textDisabled)
            }
            .foregroundColor(provider == id ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(provider == id ? StudioTheme.accentSoft : StudioTheme.panel,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(provider == id ? StudioTheme.accent.opacity(0.7) : StudioTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var providerConfiguration: some View {
        if provider == "chatgpt_codex" {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: status.connected && status.provider == provider ? "checkmark.seal.fill" : "person.crop.circle.badge.arrow.forward")
                        .foregroundColor(status.connected && status.provider == provider ? StudioTheme.bixelGreen : StudioTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.connected && status.provider == provider ? "ChatGPT account connected" : "Connect your ChatGPT account")
                            .font(.system(size: 12, weight: .medium))
                        Text("OAuth opens in your browser. Credentials stay in Goose's secure store.")
                            .font(.system(size: 10))
                            .foregroundColor(StudioTheme.textSecondary)
                    }
                    Spacer()
                    Button(signingIn ? "Cancel" : "Sign in") {
                        if signingIn { cancelSignIn() } else { signIn() }
                    }
                    .controlSize(.small)
                    .disabled(busy && !signingIn)
                }
                .padding(11)
                .studioSurface()
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                field("OpenRouter API key", text: $apiKey, secure: true)
                Text("The key is write-only here and is stored by Goose. Connect once to load the provider model catalog.")
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelConfiguration: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Model")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if loadingCatalog {
                    ProgressView().controlSize(.small)
                } else if let selected = selectedOption {
                    Text(selected.capabilitySummary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(StudioTheme.bixelGreen)
                }
            }

            ModelPicker(
                title: provider == "chatgpt_codex" ? "Primary Goose model" : "Primary chat model",
                selection: $primaryModel,
                options: catalog.models
            )

            if provider == "chatgpt_codex" {
                capabilityExplanation
            } else {
                DisclosureGroup(isExpanded: $advancedRouting) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use these only when the primary model does not cover a capability. Leave blank to route through the primary model.")
                            .font(.system(size: 10))
                            .foregroundColor(StudioTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ModelPicker(title: "Vision override", selection: $visionModel, options: catalog.models, capability: "vision")
                        ModelPicker(title: "Image override", selection: $imageModel, options: catalog.models, capability: "image")
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Advanced routing")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.textSecondary)
                }
                .tint(StudioTheme.textSecondary)
            }
        }
        .padding(12)
        .studioSurface()
    }

    private var capabilityExplanation: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "link.circle.fill")
                .foregroundColor(StudioTheme.accent)
            Text("This selected Codex model serves chat, image input, and image generation. Image requests use Codex's hosted image tool — no Google image model is involved.")
                .font(.system(size: 10))
                .foregroundColor(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    private var readinessList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Readiness").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let source = status.imageSource {
                    Text(source == "codex_hosted" ? "Codex hosted image" : "OpenRouter image model")
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.textSecondary)
                }
            }
            ForEach(Self.roles, id: \.self) { role in
                let readiness = status.readiness[role]
                HStack(spacing: 8) {
                    Circle().fill(dot(role)).frame(width: 7, height: 7)
                    Text(role.capitalized).font(.system(size: 11)).frame(width: 48, alignment: .leading)
                    Text(status.models[role] ?? "—")
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(readiness?.ready == true ? "Ready" : (readiness?.reason ?? "Not connected"))
                        .font(.system(size: 10))
                        .foregroundColor(readiness?.ready == true ? StudioTheme.bixelGreen : StudioTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .studioSurface()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Button(busy ? "Connecting…" : (status.connected && status.provider == provider ? "Reconnect" : "Connect")) {
                    connect()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.accent)
                .disabled(busy || primaryModel.isEmpty || (provider == "openrouter" && apiKey.isEmpty && status.key == nil))

                if status.connected {
                    Button("Disconnect") {
                        AIService.disconnect()
                        refresh()
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                Spacer()
            }
            Text("Model choices and capabilities are scoped to the selected provider, like Goose ACP.")
                .font(.system(size: 10))
                .foregroundColor(StudioTheme.textDisabled)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(StudioTheme.hairline).frame(height: 1) }
    }

    private var selectedOption: AIService.AIModelOption? {
        catalog.models.first(where: { $0.id == primaryModel })
    }

    private func dot(_ role: String) -> Color {
        guard let readiness = status.readiness[role] else { return StudioTheme.textDisabled }
        return readiness.ready ? StudioTheme.bixelGreen : .orange
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
            Group {
                if secure { SecureField("sk-or-…", text: text) }
                else { TextField("", text: text) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private func applyProviderDefaults(_ newProvider: String) {
        let current = AIService.connectionStatus()
        if newProvider == "chatgpt_codex" {
            primaryModel = current.provider == newProvider ? (current.models["text"] ?? primaryModel) : primaryModel
            visionModel = ""
            imageModel = ""
        } else {
            if primaryModel.isEmpty || newProvider != current.provider {
                primaryModel = current.models["text"] ?? primaryModel
            }
            if newProvider != current.provider {
                visionModel = ""
                imageModel = ""
            } else {
                if visionModel.isEmpty { visionModel = current.models["vision"] ?? "" }
                if imageModel.isEmpty { imageModel = current.models["image"] ?? "" }
            }
        }
    }

    private func loadCatalog() {
        let selectedProvider = provider
        loadingCatalog = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.listModels(provider: selectedProvider)
            DispatchQueue.main.async {
                guard provider == selectedProvider else { return }
                catalog = result
                loadingCatalog = false
                if primaryModel.isEmpty || !result.models.contains(where: { $0.id == primaryModel }) {
                    primaryModel = result.defaultModel ?? result.models.first(where: { $0.recommended })?.id ?? result.models.first?.id ?? primaryModel
                }
            }
        }
    }

    private func signIn() {
        signingIn = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.startCodexOAuth()
            DispatchQueue.main.async {
                signingIn = false
                refresh()
                if let result { message = result }
            }
        }
    }

    private func cancelSignIn() {
        AIService.cancelCodexOAuth()
        signingIn = false
    }

    private func connect() {
        let selectedProvider = provider
        let key = selectedProvider == "openrouter" ? apiKey : ""
        let text = primaryModel
        let vision = selectedProvider == "chatgpt_codex" ? text : (visionModel.isEmpty ? text : visionModel)
        let image = selectedProvider == "chatgpt_codex" ? text : (imageModel.isEmpty ? text : imageModel)
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.connect(provider: selectedProvider, apiKey: key, imageAPIKey: "",
                                           textModel: text, visionModel: vision, imageModel: image)
            DispatchQueue.main.async {
                busy = false
                refresh()
                message = result ?? "Connected."
            }
        }
    }

    private func refresh() {
        status = AIService.connectionStatus()
        if status.connected {
            provider = status.provider
            primaryModel = status.models["text"] ?? primaryModel
            visionModel = status.models["vision"] ?? visionModel
            imageModel = status.models["image"] ?? imageModel
        } else {
            if primaryModel.isEmpty { primaryModel = status.models["text"] ?? "" }
            if visionModel.isEmpty { visionModel = status.models["vision"] ?? "" }
            if imageModel.isEmpty { imageModel = status.models["image"] ?? "" }
        }
        applyProviderDefaults(provider)
        loadCatalog()
    }
}

/// Standalone sheet wrapper around the provider pane, used by the AI panel's
/// "connect a provider" shortcut and the home screen's setup prompt.
struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Provider")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Choose the provider Goose will use for chat and image skills.")
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textSecondary)
            }
            .padding(.bottom, 17)
            ProviderSettingsPane()
        }
        .padding(20)
        .frame(width: 460, height: 650)
        .foregroundColor(StudioTheme.textPrimary)
        .background(StudioTheme.background)
    }
}

/// A searchable provider-scoped model picker with capability badges. It never
/// mixes Codex and OpenRouter options in one list.
private struct ModelPicker: View {
    let title: String
    @Binding var selection: String
    let options: [AIService.AIModelOption]
    var capability: String? = nil
    @State private var search = ""
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Text(selectedOption?.label ?? (selection.isEmpty ? "Choose a model" : selection))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundColor(selection.isEmpty ? StudioTheme.textDisabled : StudioTheme.textPrimary)
                    Spacer(minLength: 0)
                    if let option = selectedOption, !option.capabilitySummary.isEmpty {
                        Text(option.capabilitySummary).font(.system(size: 9)).foregroundColor(StudioTheme.textSecondary)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    TextField("Search models", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            let filtered = availableOptions.filter {
                                search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search)
                            }
                            ForEach(filtered) { option in row(option) }
                            if filtered.isEmpty {
                                Text(availableOptions.isEmpty ? "No models advertise this capability yet." : "No matches.")
                                    .font(.system(size: 11)).foregroundColor(StudioTheme.textDisabled)
                                    .padding(8)
                            }
                        }
                    }
                    .frame(minWidth: 350, idealWidth: 390, maxHeight: 280)
                }
                .padding(10)
                .foregroundColor(StudioTheme.textPrimary)
                .background(StudioTheme.background)
            }
        }
    }

    private var selectedOption: AIService.AIModelOption? {
        options.first(where: { $0.id == selection })
    }

    private var availableOptions: [AIService.AIModelOption] {
        guard let capability else { return options }
        return options.filter { $0.capabilities.contains(capability) }
    }

    private func row(_ option: AIService.AIModelOption) -> some View {
        Button {
            selection = option.id
            open = false
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Text(option.id).font(.system(size: 9, design: .monospaced)).foregroundColor(StudioTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Text(option.capabilitySummary).font(.system(size: 9)).foregroundColor(StudioTheme.bixelGreen)
                if option.recommended { Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(.orange) }
                if option.id == selection { Image(systemName: "checkmark").font(.system(size: 10)).foregroundColor(StudioTheme.accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(option.id == selection ? StudioTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
