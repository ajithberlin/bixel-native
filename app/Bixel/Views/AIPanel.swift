import SwiftUI
import UniformTypeIdentifiers

struct AIPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: AssistantSession
    @ObservedObject var store: ProjectStore
    var onClose: () -> Void
    var expanded: Bool
    var onExpand: () -> Void
    @State private var showHistory = false
    @State private var showModel = false
    @State private var showCommands = false
    @State private var dropTarget = false
    @State private var archived: AssistantConversation?
    @State private var historySearch = ""
    @State private var commandIndex = 0
    @State private var pickerSearch = ""

    private var activeQuery: String {
        (session.query ?? pickerSearch).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var commands: [AssistantCommand] {
        let q = activeQuery
        if q.isEmpty {
            return session.commands
        }
        return session.commands.compactMap { cmd -> (AssistantCommand, Int)? in
            guard let score = cmd.matchScore(for: q) else { return nil }
            return (cmd, score)
        }
        .sorted { $0.1 > $1.1 }
        .map { $0.0 }
    }
    private var commandMenuVisible: Bool { showCommands || session.query != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            if showHistory { history } else { transcript }
            if let error = session.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundColor(.orange).padding(14)
            }
            VStack(spacing: 9) {
                if commandMenuVisible { commandPicker }
                if session.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(session.activity).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(session.startedAt, style: .relative).monospacedDigit()
                    }.font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary).padding(.horizontal, 6)
                }
                composer
            }.padding(.horizontal, 14).padding(.bottom, 10)
            HStack {
                Text("↵ Send   ⇧↵ New line")
                Spacer()
                Text(session.tokenCount > 0 ? "\(session.tokenCount.formatted()) tokens" : "Made for your canvas")
            }.font(.system(size: 9)).foregroundColor(StudioTheme.textDisabled).padding(.horizontal, 22).padding(.bottom, 10)
        }
        .foregroundColor(StudioTheme.textPrimary)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            for provider in providers.prefix(4) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in session.attach(url) } }
                }
            }
            return !providers.isEmpty
        }
        .overlay {
            if dropTarget {
                Rectangle().fill(StudioTheme.accentSoft)
                    .overlay(Rectangle().strokeBorder(StudioTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6])))
                    .overlay(Label("Drop files to attach", systemImage: "paperclip")).padding(8).allowsHitTesting(false)
            }
        }
        .background(AppSettingsOpener(openOnAppear: !session.status.connected))
        .onAppear {
            if session.commands.isEmpty {
                session.refreshCommands()
            }
        }
    }

    private func roleDot(_ role: String) -> Color {
        guard let readiness = session.status.readiness[role] else { return StudioTheme.textDisabled }
        return readiness.ready ? .green : .orange
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundColor(StudioTheme.textSecondary).font(.system(size: 17))
            Text("Bixel").font(.system(size: 14, weight: .semibold))
            Text("Agent").font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 4).background(StudioTheme.panelElevated, in: Capsule())
            Spacer(minLength: 0)
            iconButton("Recent chats", "clock.arrow.circlepath") { showHistory.toggle() }
            iconButton("New chat", "square.and.pencil") { session.newChat(); showHistory = false; archived = nil }.disabled(session.busy)
            iconButton(expanded ? "Reduce sidebar" : "Expand sidebar", expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: onExpand)
            iconButton("AI Settings", "gearshape") { AppSettings.requestOpen() }
            iconButton("Close assistant", "xmark", action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 52)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(StudioTheme.procreateGlass))
        )
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView { transcriptContent }
                .onChange(of: session.messages.count) { count in
                    if count == 0 { proxy.scrollTo("welcome", anchor: .top) }
                    else { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.messages.last?.blocks.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var transcriptContent: some View {
        LazyVStack(alignment: .leading, spacing: 25) {
            if session.messages.isEmpty { welcome.id("welcome") }
            ForEach(session.messages) { message in
                AssistantMessageView(message: message, commands: session.commands, model: model, store: store)
            }
            Color.clear.frame(height: 1).id("bottom")
        }.padding(18)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 28, weight: .ultraLight)).foregroundColor(StudioTheme.textDisabled)
            Text("Let’s make something.").font(.system(size: 22, weight: .medium))
            Text("Describe an idea, drop in a reference, or add a skill with /.")
                .font(.system(size: 13)).lineSpacing(4).foregroundColor(StudioTheme.textSecondary)
        }.padding(.top, 55).padding(.bottom, 40)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let archived {
                Button { self.archived = nil } label: { Label("Recent chats", systemImage: "chevron.left") }.buttonStyle(.plain)
                Text(archived.title).font(.system(size: 13, weight: .semibold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(archived.messages) { AssistantMessageView(message: $0, commands: session.commands, model: model, store: store) }
                    }
                }
            } else {
                TextField("Search recent chats", text: $historySearch).textFieldStyle(.roundedBorder)
                Text("This project").font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Button { showHistory = false } label: { Label("Current conversation", systemImage: "bubble.left").frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                            .buttonStyle(.plain)
                        ForEach(session.history.filter { historySearch.isEmpty || $0.title.localizedCaseInsensitiveContains(historySearch) }) { chat in
                            Button { archived = chat } label: { Label(chat.title, systemImage: "text.bubble").lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.font(.system(size: 12)).padding(18).frame(maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(session.attachments) { file in
                            AssistantAttachmentThumbnail(file: file) { session.attachments.removeAll { $0.id == file.id } }
                        }
                    }.padding(.top, 3)
                }
            }
            AssistantTextInput(text: $session.input, commands: session.commands, onQuery: { value in
                DispatchQueue.main.async {
                    if session.query != value { session.query = value; commandIndex = 0 }
                }
            }, onSubmit: submitComposer, onMove: { offset in
                guard commandMenuVisible, !commands.isEmpty else { return false }
                commandIndex = (commandIndex + offset + commands.count) % commands.count; return true
            }, onEscape: { session.query = nil; showCommands = false; pickerSearch = "" })
                .frame(height: session.attachments.isEmpty ? 90 : 70)
            HStack(spacing: 8) {
                Menu {
                    Button("Attach files…", systemImage: "paperclip") { session.attachFiles() }
                    Button("Attach current frame", systemImage: "photo") { session.attachCanvas(model) }
                    Divider()
                    Button("Add skill…", systemImage: "shippingbox") { showCommands.toggle() }
                } label: { Image(systemName: "plus").font(.system(size: 18)).frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Attach files, canvas, or skills")
                iconButton("Add skills", "shippingbox") { showCommands.toggle() }
                    .foregroundColor(commandMenuVisible ? StudioTheme.accent : StudioTheme.textSecondary)
                Rectangle().fill(StudioTheme.hairlineStrong).frame(width: 1, height: 16)
                Spacer(minLength: 0)
                Button { showModel.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(session.modelLabel).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary)
                }.buttonStyle(.plain).popover(isPresented: $showModel) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("AI models").font(.headline)
                            Spacer()
                            if !session.status.connected {
                                Circle().fill(StudioTheme.textDisabled).frame(width: 7, height: 7)
                            }
                        }
                        ForEach(["text", "vision", "image"], id: \.self) { role in
                            HStack(spacing: 7) {
                                Circle().fill(roleDot(role)).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(role.capitalized).font(.system(size: 10)).foregroundColor(.secondary)
                                    Text(session.models[role] ?? "Not configured").font(.system(size: 12)).textSelection(.enabled)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        Text("Configured in AI settings. Image attachments are described by the vision model when that role is ready.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        AppSettingsButton { Text("Open AI settings…") }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(StudioTheme.accent)
                    }.padding(18).frame(width: 280)
                }
                Button {
                    if session.busy { session.stop() } else { send() }
                } label: {
                    Image(systemName: session.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: session.busy ? 12 : 18, weight: .medium))
                        .foregroundColor(session.canSend || session.busy ? StudioTheme.panel : StudioTheme.textDisabled)
                        .frame(width: 34, height: 34)
                        .background(session.canSend || session.busy ? Color.white.opacity(0.86) : StudioTheme.hairlineStrong, in: Circle())
                }.buttonStyle(.plain).disabled((!session.canSend && !session.busy) || session.stopping)
                    .help(session.busy ? "Stop at the next event" : "Send message").accessibilityLabel(session.busy ? "Stop response" : "Send message")
            }
        }.padding(15)
        .background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
    }

    private var pickerTitle: String {
        let q = activeQuery
        if commands.isEmpty {
            return q.isEmpty ? "No skills installed" : "No matching skills for \"\(q)\""
        }
        if !q.isEmpty {
            return "Skills matching \"\(q)\""
        }
        return "Add a skill"
    }

    private var commandPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pickerTitle).font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary)
                Spacer()
                iconButton("Close skill menu", "xmark") {
                    showCommands = false
                    session.query = nil
                    pickerSearch = ""
                }
            }.padding(.horizontal, 8)
            if session.query == nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.textSecondary)
                    TextField("Search skills…", text: $pickerSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.textPrimary)
                    if !pickerSearch.isEmpty {
                        Button { pickerSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(StudioTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 4)
            }
            if !commands.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                Button { insert(command) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "shippingbox").foregroundColor(StudioTheme.accent)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(command.title).font(.system(size: 12, weight: .medium))
                                                if command.origin == .agent {
                                                    Text("/\(command.id)")
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundColor(StudioTheme.accent.opacity(0.8))
                                                }
                                            }
                                            Text(command.detail).font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary).lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(index == commandIndex ? StudioTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).id(index)
                            }
                        }
                    }.frame(maxHeight: 190)
                        .onChange(of: commandIndex) { index in proxy.scrollTo(index) }
                }
            }
        }.padding(8).background(StudioTheme.panelElevated, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1))
    }
    private func insert(_ command: AssistantCommand) {
        NotificationCenter.default.post(name: .assistantInsertCommand, object: command)
        showCommands = false; session.query = nil; pickerSearch = ""
    }
    private func submitComposer() {
        if commandMenuVisible, !commands.isEmpty {
            let index = max(0, min(commandIndex, commands.count - 1))
            insert(commands[index])
        } else {
            send()
        }
    }
    private func send() { showHistory = false; session.send(model: model) }
    private func iconButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13)).frame(width: 24, height: 27).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct AssistantAttachmentThumbnail: View {
    let file: AssistantAttachment
    var remove: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = file.image {
                        Image(platformImage: image).resizable().interpolation(.none).scaledToFill()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.system(size: 22))
                            Text(file.subtitle).font(.system(size: 9))
                        }.foregroundColor(StudioTheme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(StudioTheme.background)
                    }
                }.frame(width: 78, height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                if let remove {
                    Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.black).frame(width: 18, height: 18).background(Color.white.opacity(0.85), in: Circle()) }
                        .buttonStyle(.plain).padding(4).help("Remove \(file.name)")
                }
            }
            Text(file.name).font(.system(size: 9)).foregroundColor(StudioTheme.textSecondary).lineLimit(1).frame(width: 78)
        }
    }
}

private struct AssistantMessageView: View {
    let message: AssistantMessage
    let commands: [AssistantCommand]
    @ObservedObject var model: EditorModel
    @ObservedObject var store: ProjectStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.isUser {
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(message.attachments) { AssistantAttachmentThumbnail(file: $0) } }
                    }
                }
                Text(inlineText).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
            } else {
                ForEach(message.blocks) { block in AssistantActivityNode(block: block, commands: commands, model: model, store: store) }
                if !message.blocks.isEmpty && !message.blocks.contains(where: \.running) {
                    Button {
                        PlatformPasteboard.copy(string: message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n"))
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(StudioTheme.textSecondary) }
                        .buttonStyle(.plain).help("Copy response")
                }
            }
        }.padding(message.isUser ? 12 : 0).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.isUser ? StudioTheme.panelElevated.opacity(0.65) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }
    private var inlineText: AttributedString {
        var text = message.text
        for command in commands { text = text.replacingOccurrences(of: command.marker, with: "◈ \(command.title)") }
        var result = AttributedString(text)
        for command in commands {
            if let range = result.range(of: "◈ \(command.title)") { result[range].foregroundColor = StudioTheme.accent; result[range].font = .system(size: 13, weight: .medium) }
        }
        return result
    }
}

private struct AssistantActivityNode: View {
    let block: AssistantBlock
    let commands: [AssistantCommand]
    @ObservedObject var model: EditorModel
    @ObservedObject var store: ProjectStore
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch block.kind {
            case .text: AssistantMarkdown(text: block.text)
            case .error:
                Label(block.text, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundColor(.orange).textSelection(.enabled)
            case .thinking, .tool:
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        if block.running { ProgressView().controlSize(.mini) }
                        else { Image(systemName: block.failed ? "exclamationmark.circle" : block.kind == .thinking ? "sparkle" : "checkmark").frame(width: 12) }
                        Text(title).lineLimit(1)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                        Spacer(minLength: 0)
                    }.font(.system(size: 12)).foregroundColor(block.failed ? .orange : StudioTheme.textSecondary).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(title), \(expanded ? "collapse" : "expand")")
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        if !block.arguments.isEmpty {
                            Text(prettyArguments).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !block.text.isEmpty { AssistantMarkdown(text: block.text) }
                        else if block.kind == .thinking {
                            Text(block.running ? "Waiting for the model’s reasoning or response…" : "The model did not return a reasoning summary.").font(.system(size: 11)).foregroundColor(StudioTheme.textSecondary)
                        }
                    }.padding(.leading, 20).overlay(alignment: .leading) { Rectangle().fill(StudioTheme.hairlineStrong).frame(width: 1).padding(.leading, 5) }
                }
            }
            ForEach(block.artifacts) { artifact in AssistantArtifactCard(artifact: artifact, model: model, store: store) }
        }
    }
    private var title: String {
        if block.kind == .thinking { return block.running ? "Thinking" : "Thought" }
        let name = commands.first(where: { $0.id == block.title })?.title ?? block.title.replacingOccurrences(of: "_", with: " ")
        return block.running ? "Running \(name)" : name
    }
    private var prettyArguments: String {
        guard let data = block.arguments.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else { return block.arguments }
        return text
    }
}

private struct AssistantArtifactCard: View {
    let artifact: AssistantArtifact
    @ObservedObject var model: EditorModel
    @ObservedObject var store: ProjectStore
    @State private var showImage = false
    @State private var applied = false

    private var isSpriteSheet: Bool {
        if artifact.atlas != nil { return true }
        if let meta = artifact.frameMeta, meta.count > 1 { return true }
        return artifact.width > model.width && artifact.height == model.height && artifact.width % model.width == 0
    }

    private var provenanceLabel: String { artifact.isSource ? "Original" : "Prepared" }
    private var addLabel: String { artifact.isSource ? "Add original" : "Add prepared" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = makePlatformImage(data: artifact.data) {
                Button { showImage = true } label: {
                    Image(platformImage: image).resizable().interpolation(.none).scaledToFit().frame(maxWidth: .infinity, maxHeight: 230)
                        .padding(8).background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).help("View image or drag onto the canvas")
                .onDrag { imageProvider(artifact.data) }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    if artifact.width > 0 { Text("\(artifact.width) × \(artifact.height)").font(.system(size: 9)).foregroundColor(StudioTheme.textSecondary) }
                }
                Spacer(minLength: 4)

                Text(provenanceLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(artifact.isSource ? StudioTheme.accent : StudioTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background((artifact.isSource ? StudioTheme.accentSoft : StudioTheme.panelElevated), in: Capsule())

                Button("View") { showImage = true }.buttonStyle(.plain).font(.system(size: 10))

                if store.isMapActive {
                    Button("Add as tileset") {
                        store.requestTileset(name: artifact.name, data: artifact.data)
                    }
                    .font(.system(size: 10))
                    .help("Slice this image into a tileset you can paint with on the map")
                }

                if isSpriteSheet {
                    Button(applied ? "Added" : "Add as animation") {
                        model.addSheetAsAnimation(artifact.data, manifest: artifact.atlas, name: artifact.name)
                        applied = true
                    }
                    .font(.system(size: 10))
                    .disabled(applied)
                    .help("Add every frame from this spritesheet to the animation timeline")
                }

                Button(applied ? "Added" : addLabel) {
                    if let decoded = AIService.pngToRGBA(artifact.data) {
                        model.applyImageToNewFrame(decoded.rgba, width: decoded.width, height: decoded.height)
                        applied = true
                    }
                }
                .font(.system(size: 10))
                .disabled(applied)
                .help(artifact.width > 0 && (artifact.width != model.width || artifact.height != model.height) ?
                      "Add at native size; larger images are center-cropped and ready for manual transform" :
                      "Add as a new frame without changing pixels")
            }
        }.padding(10).background(StudioTheme.panelElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showImage) {
            VStack(spacing: 12) {
                HStack { Text(artifact.name).font(.headline); Spacer(); Button("Done") { showImage = false } }
                if let image = makePlatformImage(data: artifact.data) { Image(platformImage: image).resizable().interpolation(.none).scaledToFit() }
            }.padding(20).frame(minWidth: 500, idealWidth: 700, minHeight: 400, idealHeight: 600).background(StudioTheme.background)
        }
    }
}
