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

            Spacer(minLength: 0)

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
