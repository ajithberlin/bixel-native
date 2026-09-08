// AIPanel.swift
//
// Sheet exposing the AI skills: generate art, predict next frame, remove
// background and compress. Model-backed skills run off the main thread and
// apply their result back into the document.

import SwiftUI

struct AIPanel: View {
    @ObservedObject var model: EditorModel
    @State private var prompt = "a small green slime monster, walking"
    @State private var status = ""
    @State private var running = false
    @State private var bits = 4.0

    @State private var chatMessages: [ChatMessage] = []
    @State private var chatInput = ""
    @State private var chatBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !AIService.available() {
                notice
            }

            promptField

            HStack(spacing: 10) {
                SkillButton(title: "Generate art", icon: "photo.badge.plus") {
                    runGenerateArt()
                }
                SkillButton(title: "Next frame", icon: "forward.frame.fill") {
                    runNextFrame()
                }
            }

            HStack(spacing: 10) {
                SkillButton(title: "Remove background", icon: "wand.and.stars") {
                    runRemoveBackground()
                }
                SkillButton(title: "Compress", icon: "arrow.down.right.and.arrow.up.left") {
                    runCompress()
                }
            }

            HStack(spacing: 8) {
                Text("Bit depth").font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary)
                Slider(value: $bits, in: 1...8, step: 1)
                Text("\(Int(bits))-bit").font(.system(size: 11, design: .monospaced)).foregroundColor(StudioTheme.textSecondary)
            }

            Divider().overlay(StudioTheme.panelElevated)

            chatSection

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(StudioTheme.panel)
        .preferredColorScheme(.dark)
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundColor(StudioTheme.accent)
                Text("Chat").font(.system(size: 12, weight: .semibold)).foregroundColor(StudioTheme.textPrimary)
                Spacer()
                if !chatMessages.isEmpty {
                    Button("Clear") { clearChat() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundColor(StudioTheme.textSecondary)
                }
                if chatBusy { ProgressView().controlSize(.small) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chatMessages) { msg in
                        chatBubble(msg)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioTheme.canvasBackground.opacity(0.4)))

            HStack(spacing: 8) {
                TextField("Ask Bixel…", text: $chatInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendChat() }
                Button("Send") { sendChat() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatBusy)
            }
        }
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(msg.role == .user ? "You" : "Bixel")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(msg.role == .user ? StudioTheme.accent : StudioTheme.textSecondary)
                .frame(width: 38, alignment: .leading)
            Text(msg.text)
                .font(.system(size: 12))
                .foregroundColor(StudioTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles").foregroundColor(StudioTheme.accent)
            Text("AI Assistant").font(.headline).foregroundColor(StudioTheme.textPrimary)
            Spacer()
            if running { ProgressView().controlSize(.small) }
        }
    }

    private var notice: some View {
        Text("No OpenRouter key configured. Add one to `.env` (OPENROUTER_API_KEY) and relaunch. Local skills (remove background, compress) still work.")
            .font(.system(size: 11))
            .foregroundColor(StudioTheme.textSecondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.08)))
    }

    private var promptField: some View {
        TextField("Describe what to generate…", text: $prompt)
            .textFieldStyle(.roundedBorder)
    }

    private func run(_ work: @escaping () -> String) {
        guard !running else { return }
        running = true
        status = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                status = result
                running = false
            }
        }
    }

    private func clearChat() {
        chatMessages.removeAll()
        AIService.resetChat()
    }

    private func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chatBusy else { return }
        chatInput = ""
        chatMessages.append(ChatMessage(role: .user, text: text))
        chatBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = AIService.chat(prompt: text) ?? "Chat failed — check key / model."
            DispatchQueue.main.async {
                chatMessages.append(ChatMessage(role: .assistant, text: reply))
                chatBusy = false
            }
        }
    }

    private func runGenerateArt() {
        run {
            guard let png = AIService.generateArt(prompt: prompt) else {
                return "Generate art failed — check key / model."
            }
            guard let decoded = AIService.pngToRGBA(png) else { return "Could not decode generated image." }
            DispatchQueue.main.async {
                model.applyImageToNewFrame(decoded.rgba, width: decoded.width, height: decoded.height)
            }
            return "Generated \(decoded.width)×\(decoded.height) art into a new frame."
        }
    }

    private func runNextFrame() {
        let current = model.compositeCurrentFrame()
        let (w, h) = (model.width, model.height)
        guard let png = AIService.rgbaToPNG(current, width: w, height: h) else {
            status = "Could not encode current frame."
            return
        }
        run {
            guard let out = AIService.nextFrame(png: png, prompt: "continue: \(prompt)") else {
                return "Next-frame prediction failed — check key / model."
            }
            guard let decoded = AIService.pngToRGBA(out) else { return "Could not decode predicted frame." }
            DispatchQueue.main.async {
                model.applyImageToNewFrame(decoded.rgba, width: decoded.width, height: decoded.height)
            }
            return "Added predicted next frame (\(decoded.width)×\(decoded.height))."
        }
    }

    private func runRemoveBackground() {
        let current = model.compositeCurrentFrame()
        let (w, h) = (model.width, model.height)
        run {
            let out = AIService.removeBackground(current, width: w, height: h, tolerance: 32)
            DispatchQueue.main.async {
                model.applyImageToCurrentFrame(out, width: w, height: h)
            }
            return "Removed background from the current frame."
        }
    }

    private func runCompress() {
        let current = model.compositeCurrentFrame()
        let (w, h) = (model.width, model.height)
        run {
            let out = AIService.compress(current, width: w, height: h, bits: UInt8(bits))
            DispatchQueue.main.async {
                model.applyImageToCurrentFrame(out, width: w, height: h)
            }
            return "Compressed to \(Int(bits))-bit (\(1 << Int(bits)) colors)."
        }
    }
}

private struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

private struct SkillButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.panelElevated))
            .foregroundColor(StudioTheme.textPrimary)
        }
        .buttonStyle(.plain)
    }
}
