// TimelineBar.swift
//
// Bottom timeline: playback controls + frame strip, Procreate Dreams-style.

import SwiftUI

struct TimelineBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            playbackControls

            Divider().overlay(StudioTheme.hairline).frame(height: 40)

            frameStrip

            Divider().overlay(StudioTheme.hairline).frame(height: 40)

            frameActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StudioTheme.panel.opacity(0.55))
    }

    private var playbackControls: some View {
        HStack(spacing: 4) {
            Button { model.goTo(max(0, model.frame - 1)) } label: {
                Image(systemName: "backward.frame.fill")
            }
            Button { model.togglePlayback() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            Button { model.goTo(min(model.frameCount - 1, model.frame + 1)) } label: {
                Image(systemName: "forward.frame.fill")
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(StudioTheme.textPrimary)
    }

    private var frameStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(0..<model.frameCount, id: \.self) { index in
                        FrameCell(
                            index: index,
                            selected: index == model.frame,
                            image: model.compositeFrame(index),
                            width: model.width,
                            height: model.height
                        )
                        .id(index)
                        .onTapGesture { model.goTo(index) }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: model.frame) { idx in
                withAnimation { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    private var frameActions: some View {
        HStack(spacing: 4) {
            Button { model.addFrame() } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            Button { model.duplicateFrame() } label: {
                Image(systemName: "plus.square.on.square")
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(StudioTheme.textSecondary)
        .help("Add / duplicate frame")
    }
}

private struct FrameCell: View {
    let index: Int
    let selected: Bool
    let image: [UInt8]
    let width: Int
    let height: Int

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PixelImageView(image: image, width: width, height: height)
                .frame(width: 46, height: 46)
                .background(StudioTheme.canvasBackground)

            Text("\(index + 1)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.6))
                .foregroundColor(.white)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? StudioTheme.accent : StudioTheme.hairlineStrong, lineWidth: selected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
