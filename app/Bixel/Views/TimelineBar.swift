// TimelineBar.swift
// Compact animation assist: controls above a draggable strip of frames.

import SwiftUI

struct TimelineBar: View {
    @ObservedObject var model: EditorModel
    @State private var dropTarget: Int?

    private var dragPrefix: String {
        "bixel-frame:\(ObjectIdentifier(model.document)):\(model.frameCount):"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                Button(model.playing ? "Pause" : "Play") { model.togglePlayback() }
                    .help("Play or pause animation")
                Spacer(minLength: 12)
                Menu {
                    Menu("Frames per second") {
                        ForEach([4, 8, 12, 24, 30, 60], id: \.self) { fps in
                            Button {
                                model.fps = Double(fps)
                            } label: {
                                if Int(model.fps) == fps {
                                    Label("\(fps) FPS", systemImage: "checkmark")
                                } else {
                                    Text("\(fps) FPS")
                                }
                            }
                        }
                    }
                    Picker("Playback", selection: $model.loopMode) {
                        Text("Loop").tag(LoopMode.forward)
                        Text("Reverse").tag(LoopMode.reverse)
                        Text("Ping-pong").tag(LoopMode.pingPong)
                    }
                } label: {
                    Text("Settings")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button("Add Frame") { model.pause(); model.addFrame() }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(StudioTheme.textSecondary)
            .buttonStyle(.plain)
            .padding(.horizontal, 3)

            frameStrip
                .frame(height: 48)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(white: 0.12).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StudioTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var frameStrip: some View {
        GeometryReader { geo in
            let cellWidth: CGFloat = 40
            let spacing: CGFloat = 5
            let count = CGFloat(model.frameCount)
            let contentWidth = count * cellWidth + max(0, count - 1) * spacing
            // Centre the strip when it fits; when it overflows the padding drops
            // to zero and the row scrolls horizontally instead.
            let pad = max(0, (geo.size.width - contentWidth) / 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(0..<model.frameCount, id: \.self) { index in
                            FrameCell(
                                selected: index == model.frame,
                                targeted: dropTarget == index,
                                image: model.frameThumbnailCGImage(index),
                                width: model.width,
                                height: model.height
                            )
                            .id(index)
                            .onTapGesture { model.pause(); model.goTo(index) }
                            .contextMenu { frameMenu(for: index) }
                            .draggable(dragPrefix + String(index))
                            .dropDestination(for: String.self) { items, _ in
                                defer { dropTarget = nil }
                                guard items.count == 1, let value = items.first,
                                      value.hasPrefix(dragPrefix),
                                      let source = Int(value.dropFirst(dragPrefix.count)),
                                      source >= 0, source < model.frameCount,
                                      source != index else { return false }
                                model.reorderFrame(from: source, to: index)
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTarget = index }
                                else if dropTarget == index { dropTarget = nil }
                            }
                            .accessibilityLabel("Frame \(index + 1), \(model.frameDuration(index)) milliseconds")
                            .accessibilityAddTraits(index == model.frame ? [.isSelected] : [])
                            .accessibilityAction(named: "Move earlier") {
                                model.reorderFrame(from: index, to: index - 1)
                            }
                            .accessibilityAction(named: "Move later") {
                                model.reorderFrame(from: index, to: index + 1)
                            }
                            .help("Frame \(index + 1) · \(model.frameDuration(index)) ms — drag to arrange; right-click for options")
                        }
                    }
                    .padding(.horizontal, pad)
                }
                .onChange(of: model.frame) { index in
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func frameMenu(for index: Int) -> some View {
        Menu("Hold duration") {
            ForEach([50, 100, 125, 250, 500, 1000], id: \.self) { ms in
                Button("\(ms) ms") { model.setFrameDuration(index, ms: ms) }
            }
        }
        Button("Duplicate") { model.pause(); model.goTo(index); model.duplicateFrame() }
        Button("Delete", role: .destructive) {
            model.pause()
            model.goTo(index)
            model.removeFrame()
        }
        .disabled(model.frameCount <= 1)
    }
}

private struct FrameCell: View {
    let selected: Bool
    let targeted: Bool
    let image: CGImage?
    let width: Int
    let height: Int

    var body: some View {
        VStack(spacing: 3) {
            PixelImageView(cgImage: image, width: width, height: height)
                .frame(width: 40, height: 40)
                .background(CheckerboardView(cell: 5))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(targeted ? StudioTheme.accent : StudioTheme.hairlineStrong,
                                  lineWidth: targeted ? 2 : 1))
            Capsule()
                .fill(selected ? StudioTheme.accent : Color.clear)
                .frame(height: 3)
        }
        .frame(width: 40, height: 48)
        .contentShape(Rectangle())
    }
}

/// High-performance Core Animation backed pixel-art thumbnail view.
final class FastPixelImageView: NSView {
    var cgImage: CGImage? {
        didSet {
            if cgImage !== oldValue {
                updateLayerContents()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateLayerContents()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateLayerContents()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateLayerContents()
    }

    private func updateLayerContents() {
        wantsLayer = true
        guard let l = layer else { return }
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.contentsGravity = .resizeAspect
        l.contents = cgImage
    }
}

/// Renders a CGImage or RGBA buffer as a crisp pixel-art thumbnail.
struct PixelImageView: NSViewRepresentable {
    var cgImage: CGImage?
    var image: [UInt8]?
    var width: Int
    var height: Int

    init(cgImage: CGImage?, width: Int = 0, height: Int = 0) {
        self.cgImage = cgImage
        self.image = nil
        self.width = width
        self.height = height
    }

    init(image: [UInt8], width: Int, height: Int) {
        self.cgImage = nil
        self.image = image
        self.width = width
        self.height = height
    }

    func makeNSView(context: Context) -> FastPixelImageView {
        let view = FastPixelImageView()
        updateImage(on: view)
        return view
    }

    func updateNSView(_ nsView: FastPixelImageView, context: Context) {
        updateImage(on: nsView)
    }

    private func updateImage(on nsView: FastPixelImageView) {
        if let cgImage = cgImage {
            nsView.cgImage = cgImage
        } else if let image = image, width > 0, height > 0 {
            nsView.cgImage = makeCGImage(pixels: image, width: width, height: height)
        } else {
            nsView.cgImage = nil
        }
    }
}
