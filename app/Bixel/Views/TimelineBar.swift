// TimelineBar.swift
// Compact animation assist: controls above a draggable strip of frames.

import SwiftUI

struct TimelineBar: View {
    @ObservedObject var model: EditorModel
    var onPredictNextFrame: (String) -> Void

    @State private var hoveredIndex: Int? = nil
    @State private var draggingIndex: Int? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var targetIndex: Int? = nil
    @State private var isPredictHovered = false
    @State private var showPredict = false
    @State private var predictText = ""

    private let cellWidth: CGFloat = 40
    private let spacing: CGFloat = 5
    private var slotStep: CGFloat { cellWidth + spacing }

    private let stripAnimation = Animation.spring(response: 0.34, dampingFraction: 0.82)
    private let dragSpringAnimation = Animation.spring(response: 0.28, dampingFraction: 0.8)

    var body: some View {
        VStack(spacing: 6) {
            headerControls
            frameStrip
                .frame(height: 56)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(white: 0.12).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StudioTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var headerControls: some View {
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
    }

    private var frameStrip: some View {
        GeometryReader { geo in
            let cells = CGFloat(model.frameCount + 1)
            let contentWidth = cells * cellWidth + max(0, cells - 1) * spacing
            // Centre the strip when it fits; when it overflows the padding drops
            // to zero and the row scrolls horizontally instead.
            let pad = max(0, (geo.size.width - contentWidth) / 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(Array(model.frameIDs.enumerated()), id: \.element) { index, id in
                            frameItem(at: index, id: id, scrollProxy: proxy)
                        }
                        aiFrameCell
                    }
                    .padding(.horizontal, pad)
                    .padding(.vertical, 4)
                    .animation(stripAnimation, value: model.frameIDs)
                }
                .onChange(of: model.frame) { index in
                    guard draggingIndex == nil, model.frameIDs.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(model.frameIDs[index], anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func frameItem(at index: Int, id: UUID, scrollProxy: ScrollViewProxy) -> some View {
        let isSelected = index == model.frame
        let isHovered = hoveredIndex == index && draggingIndex == nil
        let isDragging = draggingIndex == index
        let isDropSlot = draggingIndex != nil && targetIndex == index && draggingIndex != index

        ZStack {
            // Drop target slot placeholder (anchored at unshifted slot position)
            if isDropSlot {
                DropSlotIndicator()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Cell content with hover / drag offsets and animations
            FrameCell(
                selected: isSelected,
                isHovered: isHovered,
                isDragging: isDragging,
                canDelete: model.frameCount > 1,
                image: model.frameThumbnailCGImage(index),
                width: model.width,
                height: model.height,
                onDelete: {
                    withAnimation(stripAnimation) {
                        model.removeFrame(at: index)
                    }
                }
            )
            .offset(cellOffset(for: index))
            .scaleEffect(isDragging ? 1.1 : (isHovered ? 1.03 : 1.0))
            .shadow(
                color: isDragging ? Color.black.opacity(0.55) : (isHovered ? Color.black.opacity(0.35) : Color.clear),
                radius: isDragging ? 8 : (isHovered ? 5 : 0),
                x: 0,
                y: isDragging ? 6 : (isHovered ? 3 : 0)
            )
            .zIndex(cellZIndex(for: index))
        }
        .frame(width: cellWidth, height: 48)
        .id(id)
        .onHover { hovering in
            if hovering {
                if draggingIndex == nil {
                    hoveredIndex = index
                }
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    handleDragChanged(at: index, value: value, scrollProxy: scrollProxy)
                }
                .onEnded { value in
                    handleDragEnded(at: index, value: value)
                }
        )
        .onTapGesture {
            model.pause()
            model.goTo(index)
        }
        .contextMenu { frameMenu(for: index) }
        .accessibilityLabel("Frame \(index + 1), \(model.frameDuration(index)) milliseconds")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "Move earlier") {
            withAnimation(stripAnimation) { model.reorderFrame(from: index, to: index - 1) }
        }
        .accessibilityAction(named: "Move later") {
            withAnimation(stripAnimation) { model.reorderFrame(from: index, to: index + 1) }
        }
        .help("Frame \(index + 1) · \(model.frameDuration(index)) ms — drag to arrange; right-click for options")
    }

    private func cellOffset(for index: Int) -> CGSize {
        guard let dragging = draggingIndex else {
            if hoveredIndex == index {
                return CGSize(width: 0, height: -4)
            }
            return .zero
        }

        if index == dragging {
            return CGSize(width: dragTranslation, height: -6)
        }

        guard let target = targetIndex else { return .zero }

        if dragging < target {
            if index > dragging && index <= target {
                return CGSize(width: -slotStep, height: 0)
            }
        } else if dragging > target {
            if index >= target && index < dragging {
                return CGSize(width: slotStep, height: 0)
            }
        }

        return .zero
    }

    private func cellZIndex(for index: Int) -> Double {
        if draggingIndex == index {
            return 100
        }
        if hoveredIndex == index {
            return 10
        }
        return 1
    }

    private func handleDragChanged(at index: Int, value: DragGesture.Value, scrollProxy: ScrollViewProxy) {
        if draggingIndex == nil {
            model.pause()
            draggingIndex = index
            targetIndex = index
            hoveredIndex = nil
        }
        dragTranslation = value.translation.width

        let deltaSlots = Int(round(value.translation.width / slotStep))
        let rawTarget = index + deltaSlots
        let newTarget = min(max(rawTarget, 0), model.frameCount - 1)

        if newTarget != targetIndex {
            withAnimation(dragSpringAnimation) {
                targetIndex = newTarget
            }
            if model.frameIDs.indices.contains(newTarget) {
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollProxy.scrollTo(model.frameIDs[newTarget], anchor: .center)
                }
            }
        }
    }

    private func handleDragEnded(at index: Int, value: DragGesture.Value) {
        guard let source = draggingIndex else {
            model.pause()
            model.goTo(index)
            return
        }
        let destination = targetIndex ?? source

        withAnimation(stripAnimation) {
            if source != destination {
                model.reorderFrame(from: source, to: destination)
            } else {
                model.goTo(source)
            }
            draggingIndex = nil
            targetIndex = nil
            dragTranslation = 0
            hoveredIndex = nil
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
                        .fill(isPredictHovered && draggingIndex == nil ? StudioTheme.accentSoft.opacity(1.3) : StudioTheme.accentSoft)
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
            .offset(y: isPredictHovered && draggingIndex == nil ? -4 : 0)
            .scaleEffect(isPredictHovered && draggingIndex == nil ? 1.03 : 1.0)
            .shadow(color: isPredictHovered && draggingIndex == nil ? Color.black.opacity(0.35) : Color.clear, radius: 5, y: 3)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isPredictHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isPredictHovered = $0 }
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
        Divider()
        Button("Copy") { model.copyFrame(at: index) }
        Button("Cut") {
            withAnimation(stripAnimation) { _ = model.cutFrame(at: index) }
        }
        .disabled(model.frameCount <= 1)
        Button("Paste After") { model.pasteFrame(after: index) }
            .disabled(!model.canPasteFrame)
        Divider()
        Button("Delete", role: .destructive) {
            withAnimation(stripAnimation) {
                model.removeFrame(at: index)
            }
        }
        .disabled(model.frameCount <= 1)
    }
}

private struct DropSlotIndicator: View {
    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(StudioTheme.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(StudioTheme.accent.opacity(0.12))
                )
                .overlay(
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(StudioTheme.accent.opacity(0.85))
                )
                .frame(width: 40, height: 40)
            Capsule()
                .fill(Color.clear)
                .frame(height: 3)
        }
        .frame(width: 40, height: 48)
    }
}

private struct DeleteBadgeButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovered ? Color(red: 0.92, green: 0.22, blue: 0.22) : Color.black.opacity(0.85))
                Circle()
                    .strokeBorder(isHovered ? Color.white.opacity(0.85) : Color.white.opacity(0.3), lineWidth: 0.75)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 15, height: 15)
            .contentShape(Circle())
            .scaleEffect(isHovered ? 1.15 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Delete frame")
        .highPriorityGesture(TapGesture().onEnded {
            action()
        })
    }
}

private struct FrameCell: View {
    let selected: Bool
    let isHovered: Bool
    let isDragging: Bool
    let canDelete: Bool
    let image: CGImage?
    let width: Int
    let height: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                PixelImageView(cgImage: image, width: width, height: height)
                    .frame(width: 40, height: 40)
                    .background(CheckerboardView(cell: 5))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                isDragging ? StudioTheme.accent : (isHovered ? Color.white.opacity(0.4) : StudioTheme.hairlineStrong),
                                lineWidth: isDragging ? 1.5 : 1
                            )
                    )

                if isHovered && !isDragging && canDelete {
                    DeleteBadgeButton(action: onDelete)
                        .offset(x: 3, y: -3)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 40, height: 40)

            Capsule()
                .fill(selected ? StudioTheme.accent : Color.clear)
                .frame(height: 3)
        }
        .frame(width: 40, height: 48)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isDragging)
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
