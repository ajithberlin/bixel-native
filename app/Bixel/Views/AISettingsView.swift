import SwiftUI

/// AI provider connection settings: provider picker (OpenRouter API key or
/// ChatGPT sign-in), the three model roles, and per-role readiness.
struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = AIService.connectionStatus()
    @State private var provider = "openrouter"
    @State private var apiKey = ""
    @State private var imageAPIKey = ""
    @State private var textModel = ""
    @State private var visionModel = ""
    @State private var imageModel = ""
    @State private var baseURL = ""
    @State private var busy = false
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

            if provider == "chatgpt_codex" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in with your ChatGPT account (opens the browser). Tokens are cached on this Mac.")
                        .font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button(busy ? "Signing in…" : "Sign in with ChatGPT") {
                        run { AIService.startCodexOAuth() }
                    }
                    .disabled(busy)
                    Text("The image role always needs an OpenRouter key — goose has no image-generation API.")
                        .font(.system(size: 10)).foregroundColor(StudioTheme.textDisabled).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if provider == "openrouter" {
                    field("OpenRouter API key", text: $apiKey, secure: true)
                } else {
                    field("OpenRouter API key (image role)", text: $imageAPIKey, secure: true)
                }
                field("OpenRouter base URL", text: $baseURL, prompt: "https://openrouter.ai/api/v1")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Models").font(.system(size: 11, weight: .medium)).foregroundColor(StudioTheme.textSecondary)
                field("Text (chat)", text: $textModel)
                field("Vision (image input)", text: $visionModel)
                field("Image (generation)", text: $imageModel)
            }

            readinessList

            if let message {
                Text(message).font(.system(size: 11)).foregroundColor(message.hasPrefix("Connected") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(busy ? "Connecting…" : (status.connected ? "Reconnect" : "Connect")) {
                    connect()
                }
                .disabled(busy || (provider == "openrouter" && apiKey.isEmpty && !status.connected))
                if status.connected {
                    Button("Disconnect") {
                        AIService.disconnect()
                        refresh()
                    }
                    .disabled(busy)
                }
            }

            Text("Keys are stored in the system secret store and never leave the app. `.env` remains the dev fallback.")
                .font(.system(size: 10)).foregroundColor(StudioTheme.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380)
        .foregroundColor(StudioTheme.textPrimary)
        .background(StudioTheme.background)
        .onAppear(perform: refresh)
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

    private func field(_ title: String, text: Binding<String>, secure: Bool = false, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
            Group {
                if secure {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private func connect() {
        let provider = provider
        let key = provider == "openrouter" ? apiKey : ""
        let imageKey = provider == "chatgpt_codex" ? imageAPIKey : ""
        let text = textModel, vision = visionModel, image = imageModel, base = baseURL
        run {
            if let error = AIService.connect(provider: provider, apiKey: key, imageAPIKey: imageKey,
                                             textModel: text, visionModel: vision, imageModel: image,
                                             baseURL: base) {
                return error
            }
            return "Connected."
        }
    }

    /// Blocking Rust calls (network probe, OAuth) run off the main thread.
    private func run(_ operation: @escaping () -> String?) {
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = operation()
            DispatchQueue.main.async {
                busy = false
                refresh()
                if let result { message = result }
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
            baseURL = status.baseURL
        } else {
            if textModel.isEmpty { textModel = status.models["text"] ?? "" }
            if visionModel.isEmpty { visionModel = status.models["vision"] ?? "" }
            if imageModel.isEmpty { imageModel = status.models["image"] ?? "" }
            if baseURL.isEmpty { baseURL = status.baseURL }
        }
    }
}
