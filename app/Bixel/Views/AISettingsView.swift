import SwiftUI

/// AI provider connection settings, scoped per provider the way goose sees
/// it: OpenRouter = API key + three model roles; ChatGPT (Codex) = sign-in +
/// Codex models (image skills stay offline — goose has no image-generation
/// API, so the image role needs the OpenRouter provider).
struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = AIService.connectionStatus()
    @State private var provider = "openrouter"
    @State private var apiKey = ""
    @State private var textModel = ""
    @State private var visionModel = ""
    @State private var imageModel = ""
    @State private var busy = false
    @State private var signingIn = false
    @State private var message: String?

    private static let roles = ["text", "vision", "image"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI Provider").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundColor(StudioTheme.textSecondary)
            }

            Picker("Provider", selection: $provider) {
                Text("OpenRouter").tag("openrouter")
                Text("ChatGPT (Codex)").tag("chatgpt_codex")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: provider) { newProvider in
                applyProviderDefaults(newProvider)
            }

            if provider == "chatgpt_codex" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in with your ChatGPT account (opens the browser). Tokens are cached on this Mac.")
                        .font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button(signingIn ? "Cancel sign-in" : "Sign in with ChatGPT") {
                        if signingIn { cancelSignIn() } else { signIn() }
                    }
                    .disabled(busy && !signingIn)
                }
                ModelPicker(title: "Model (chat + vision)", selection: $textModel, provider: provider)
            } else {
                field("OpenRouter API key", text: $apiKey, secure: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Models").font(.system(size: 11, weight: .medium)).foregroundColor(StudioTheme.textSecondary)
                    ModelPicker(title: "Text (chat)", selection: $textModel, provider: provider)
                    ModelPicker(title: "Vision (image input)", selection: $visionModel, provider: provider)
                    ModelPicker(title: "Image (generation)", selection: $imageModel, provider: provider)
                }
            }

            readinessList

            if let message {
                Text(message).font(.system(size: 11)).foregroundColor(message == "Connected." ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(busy ? "Connecting…" : (status.connected ? "Reconnect" : "Connect")) {
                    connect()
                }
                .disabled(busy || textModel.isEmpty || imageModel.isEmpty
                          || (provider == "openrouter" && apiKey.isEmpty && !status.connected))
                if status.connected {
                    Button("Disconnect") {
                        AIService.disconnect()
                        refresh()
                    }
                    .disabled(busy)
                }
            }

            if provider == "chatgpt_codex" {
                Text("Image-generation skills stay offline with ChatGPT — goose has no image API. Use the OpenRouter provider for those.")
                    .font(.system(size: 10)).foregroundColor(StudioTheme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Keys are stored in the system secret store and never leave the app.")
                .font(.system(size: 10)).foregroundColor(StudioTheme.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380)
        .foregroundColor(StudioTheme.textPrimary)
        .background(StudioTheme.background)
        .onAppear(perform: refresh)
        // Leaving the sheet must not leave a browser sign-in running in the
        // background — goose would hold its OAuth lock for the whole timeout.
        .onDisappear { if signingIn { AIService.cancelCodexOAuth() } }
    }

    private var readinessList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Readiness").font(.system(size: 11, weight: .medium)).foregroundColor(StudioTheme.textSecondary)
            ForEach(Self.roles, id: \.self) { role in
                HStack(spacing: 7) {
                    Circle().fill(dot(role)).frame(width: 7, height: 7)
                    Text(role.capitalized).font(.system(size: 11)).frame(width: 46, alignment: .leading)
                    Text(status.models[role] ?? "—").font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let readiness = status.readiness[role] {
                        Text(readiness.ready ? "Ready" : readiness.reason)
                            .font(.system(size: 10)).foregroundColor(readiness.ready ? .green : .orange)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func dot(_ role: String) -> Color {
        guard let readiness = status.readiness[role] else { return StudioTheme.textDisabled }
        return readiness.ready ? .green : .orange
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    /// Model defaults follow the provider, the way goose sees it: Codex
    /// models for ChatGPT (its own default first), the built-in catalog for
    /// OpenRouter.
    private func applyProviderDefaults(_ provider: String) {
        if provider == "chatgpt_codex" {
            let catalog = AIService.listModels(provider: provider)
            if !catalog.models.contains(textModel) {
                textModel = catalog.defaultModel ?? catalog.models.first ?? textModel
            }
        } else {
            let defaults = AIService.connectionStatus().models
            if textModel.isEmpty || !textModel.contains("/") { textModel = defaults["text"] ?? textModel }
            if visionModel.isEmpty { visionModel = defaults["vision"] ?? visionModel }
            if imageModel.isEmpty { imageModel = defaults["image"] ?? imageModel }
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
    }

    private func connect() {
        let provider = provider
        let key = provider == "openrouter" ? apiKey : ""
        let text = textModel
        // Codex has one model; it serves both text and vision.
        let vision = provider == "chatgpt_codex" ? textModel : visionModel
        let image = imageModel
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AIService.connect(provider: provider, apiKey: key, imageAPIKey: "",
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
            textModel = status.models["text"] ?? textModel
            visionModel = status.models["vision"] ?? visionModel
            imageModel = status.models["image"] ?? imageModel
        } else {
            if textModel.isEmpty { textModel = status.models["text"] ?? "" }
            if visionModel.isEmpty { visionModel = status.models["vision"] ?? "" }
            if imageModel.isEmpty { imageModel = status.models["image"] ?? "" }
        }
    }
}

/// A dropdown with a search field, listing the selected provider's models
/// (fetched per provider, so switching providers reloads). Falls back to the
/// current selection when the list cannot be loaded yet.
private struct ModelPicker: View {
    let title: String
    @Binding var selection: String
    let provider: String
    @State private var options: [String]?
    @State private var search = ""
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
            HStack(spacing: 6) {
                Text(selection.isEmpty ? "Choose a model" : selection)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundColor(selection.isEmpty ? StudioTheme.textDisabled : StudioTheme.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    .foregroundColor(StudioTheme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            .onChange(of: provider) { _ in options = nil }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search models", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onAppear { load() }
                    let filtered = (options ?? []).filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if !selection.isEmpty && !filtered.contains(selection) {
                                row(selection)
                            }
                            ForEach(filtered, id: \.self) { model in
                                row(model)
                            }
                            if filtered.isEmpty {
                                Text(options == nil ? "Could not load models (connect a key first)." : "No matches.")
                                    .font(.system(size: 11)).foregroundColor(StudioTheme.textDisabled)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                            }
                        }
                    }
                    .frame(minWidth: 320, idealWidth: 340, maxHeight: 260)
                }
                .padding(10)
                .foregroundColor(StudioTheme.textPrimary)
                .background(StudioTheme.background)
            }
        }
    }

    private func row(_ model: String) -> some View {
        Button {
            selection = model
            open = false
        } label: {
            HStack {
                Text(model).font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if model == selection {
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundColor(StudioTheme.accent)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(model == selection ? StudioTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard options == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let catalog = AIService.listModels(provider: provider)
            DispatchQueue.main.async { options = catalog.models.isEmpty ? nil : catalog.models }
        }
    }
}
