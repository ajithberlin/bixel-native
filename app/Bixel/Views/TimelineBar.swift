// TimelineBar.swift
// Compact animation assist: controls above a draggable strip of frames.

import SwiftUI

struct TimelineBar: View {
    @ObservedObject var model: EditorModel
    var onPredictNextFrame: (String) -> Void
    @State private var dropTarget: Int?
    @State private var showPredict = false
    @State private var predictText = ""

    private var dragPrefix: String {
        "bixel-frame:\(ObjectIdentifier(model.document)):\(model.frameCount):"
    }

    private let stripAnimation = Animation.spring(response: 0.34, dampingFraction: 0.82)

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
                Button("Add Frame") {
                    withAnimation(stripAnimation) { model.pause(); model.addFrame() }
                }
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
            let cells = CGFloat(model.frameCount + 1)
            let contentWidth = cells * cellWidth + max(0, cells - 1) * spacing
            // Centre the strip when it fits; when it overflows the padding drops
            // to zero and the row scrolls horizontally instead.
            let pad = max(0, (geo.size.width - contentWidth) / 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(Array(model.frameIDs.enumerated()), id: \.element) { index, id in
                            FrameCell(
                                selected: index == model.frame,
                                targeted: dropTarget == index,
                                image: model.frameThumbnailCGImage(index),
                                width: model.width,
                                height: model.height
                            )
                            .id(id)
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
                                withAnimation(stripAnimation) { model.reorderFrame(from: source, to: index) }
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTarget = index }
                                else if dropTarget == index { dropTarget = nil }
                            }
                            .accessibilityLabel("Frame \(index + 1), \(model.frameDuration(index)) milliseconds")
                            .accessibilityAddTraits(index == model.frame ? [.isSelected] : [])
                            .accessibilityAction(named: "Move earlier") {
                                withAnimation(stripAnimation) { model.reorderFrame(from: index, to: index - 1) }
                            }
                            .accessibilityAction(named: "Move later") {
                                withAnimation(stripAnimation) { model.reorderFrame(from: index, to: index + 1) }
                            }
                            .help("Frame \(index + 1) · \(model.frameDuration(index)) ms — drag to arrange; right-click for options")
                        }
                        aiFrameCell
                    }
                    .padding(.horizontal, pad)
                    .animation(stripAnimation, value: model.frameIDs)
                }
                .onChange(of: model.frame) { index in
                    guard model.frameIDs.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(model.frameIDs[index], anchor: .center)
                    }
                }
            }
        }
    }

    /// A trailing "AI" tile: type the motion and the current frame is sent to the
    /// assistant to predict the next frame.
    private var aiFrameCell: some View {
        Button {
            predictText = ""
            showPredict = true
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(StudioTheme.accentSoft)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(StudioTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(StudioTheme.accent)
                }
                .frame(width: 40, height: 40)
                Capsule().fill(Color.clear).frame(height: 3)
            }
            .frame(width: 40, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Predict the next frame with AI")
        .accessibilityLabel("Predict the next frame with AI")
        .popover(isPresented: $showPredict, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Predict next frame")
                    .font(.system(size: 12, weight: .semibold))
                Text("Describe the motion. The current frame is sent as the reference so the style and canvas stay consistent.")
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("e.g. walk forward one step", text: $predictText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitPredict)
                HStack {
                    Spacer()
                    Button("Predict", action: submitPredict)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    private func submitPredict() {
        let action = predictText.trimmingCharacters(in: .whitespacesAndNewlines)
        showPredict = false
        onPredictNextFrame(action.isEmpty ? "continue the motion" : action)
    }

    @ViewBuilder
    private func frameMenu(for index: Int) -> some View {
        Menu("Hold duration") {
            ForEach([50, 100, 125, 250, 500, 1000], id: \.self) { ms in
                Button("\(ms) ms") { model.setFrameDuration(index, ms: ms) }
            }
        }
        Button("Duplicate") {
            withAnimation(stripAnimation) { model.pause(); model.goTo(index); model.duplicateFrame() }
        }
        Button("Delete", role: .destructive) {
            withAnimation(stripAnimation) {
                model.pause()
                model.goTo(index)
                model.removeFrame()
            }
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
                .scaleEffect(targeted ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: targeted)
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
