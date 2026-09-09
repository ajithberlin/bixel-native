// TimelineBar.swift
//
// Floating bottom timeline, Procreate Dreams-style: playback controls, a strip
// of frame thumbnails with duration badges and per-frame context actions
// (duration, duplicate, delete), plus FPS and loop-mode settings.

import SwiftUI

struct TimelineBar: View {
    @ObservedObject var model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed {
                HStack(spacing: 12) {
                    playbackControls
                    divider
                    frameStrip
                    divider
                    frameActions
                    divider
                    playbackSettings
                }
                // ScrollViews are greedy; without a fixed height the bar
                // stretches to fill the whole window.
                .frame(height: 76)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(StudioTheme.hairline, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(StudioTheme.textSecondary)
                    .frame(width: 40, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(StudioTheme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .offset(y: collapsed ? 0 : -8)
            .help(collapsed ? "Show timeline" : "Hide timeline")
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private var divider: some View {
        Rectangle().fill(StudioTheme.hairline).frame(width: 1, height: 48)
    }

    // MARK: - Playback

    private var playbackControls: some View {
        HStack(spacing: 4) {
            Button { model.goTo(0) } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("First frame")
            Button { model.goTo(max(0, model.frame - 1)) } label: {
                Image(systemName: "backward.frame.fill")
            }
            .help("Previous frame")
            Button { model.togglePlayback() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 30)
            }
            .help("Play / pause")
            Button { model.goTo(min(model.frameCount - 1, model.frame + 1)) } label: {
                Image(systemName: "forward.frame.fill")
            }
            .help("Next frame")
            Button { model.goTo(model.frameCount - 1) } label: {
                Image(systemName: "forward.end.fill")
            }
            .help("Last frame")
        }
        .buttonStyle(.plain)
        .foregroundColor(StudioTheme.textPrimary)
    }

    // MARK: - Frame strip

    private var frameStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<model.frameCount, id: \.self) { index in
                        FrameCell(
                            index: index,
                            selected: index == model.frame,
                            durationMs: model.frameDuration(index),
                            image: model.compositeFrame(index),
                            width: model.width,
                            height: model.height
                        )
                        .id(index)
                        .onTapGesture { model.goTo(index) }
                        .contextMenu { frameMenu(for: index) }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .onChange(of: model.frame) { idx in
                withAnimation { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func frameMenu(for index: Int) -> some View {
        Menu("Duration") {
            ForEach([50, 100, 125, 250, 500, 1000], id: \.self) { ms in
                Button("\(ms) ms") { model.setFrameDuration(index, ms: ms) }
            }
        }
        Button("Duplicate Frame") { model.goTo(index); model.duplicateFrame() }
        Divider()
        Button("Delete Frame", role: .destructive) {
            model.goTo(index)
            model.removeFrame()
        }
        .disabled(model.frameCount <= 1)
    }

    // MARK: - Frame actions

    private var frameActions: some View {
        HStack(spacing: 4) {
            Button { model.addFrame() } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .help("Add frame")
            Button { model.duplicateFrame() } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Duplicate frame")
            Button { model.removeFrame() } label: {
                Image(systemName: "trash")
            }
            .disabled(model.frameCount <= 1)
            .foregroundColor(model.frameCount > 1 ? StudioTheme.textSecondary : StudioTheme.textDisabled)
            .help("Delete frame")
        }
        .buttonStyle(.plain)
        .foregroundColor(StudioTheme.textSecondary)
    }

    // MARK: - Playback settings

    private var playbackSettings: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach([4, 8, 12, 24, 30, 60], id: \.self) { fps in
                    Button("\(fps) FPS") { model.fps = Double(fps) }
                }
            } label: {
                Text("\(Int(model.fps)) FPS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed (rescales frame durations)")

            Menu {
                Button { model.loopMode = .forward } label: {
                    Label("Loop forward", systemImage: model.loopMode == .forward ? "checkmark" : "")
                }
                Button { model.loopMode = .reverse } label: {
                    Label("Reverse", systemImage: model.loopMode == .reverse ? "checkmark" : "")
                }
                Button { model.loopMode = .pingPong } label: {
                    Label("Ping-pong", systemImage: model.loopMode == .pingPong ? "checkmark" : "")
                }
            } label: {
                Image(systemName: loopIcon)
                    .font(.system(size: 11))
                    .foregroundColor(StudioTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Loop mode")
        }
    }

    private var loopIcon: String {
        switch model.loopMode {
        case .forward: return "repeat"
        case .reverse: return "arrow.uturn.backward.circle"
        case .pingPong: return "arrow.left.arrow.right"
        }
    }
}

// MARK: - Frame cell

private struct FrameCell: View {
    let index: Int
    let selected: Bool
    let durationMs: Int
    let image: [UInt8]
    let width: Int
    let height: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            PixelImageView(image: image, width: width, height: height)
                .frame(width: 56, height: 56)
                .background(CheckerboardView(cell: 5))

            Text("\(index + 1)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.65))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(3)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(durationLabel)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.65))
                        .foregroundColor(.white.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(3)
                }
            }
        }
        .frame(width: 56, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? StudioTheme.accent : StudioTheme.hairlineStrong, lineWidth: selected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .scaleEffect(selected ? 1.04 : 1)
        .animation(.easeInOut(duration: 0.12), value: selected)
    }

    private var durationLabel: String {
        durationMs >= 1000 ? String(format: "%gs", Double(durationMs) / 1000) : "\(durationMs)ms"
    }
}

/// Renders an RGBA buffer as a small bitmap image.
struct PixelImageView: NSViewRepresentable {
    let image: [UInt8]
    let width: Int
    let height: Int

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard let rep = bitmapRep else { return }
        let nsImage = NSImage(size: NSSize(width: width, height: height))
        nsImage.addRepresentation(rep)
        nsView.image = nsImage
    }

    private var bitmapRep: NSBitmapImageRep? {
        guard let dataProvider = CGDataProvider(data: Data(image) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
}
