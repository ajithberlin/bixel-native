import Foundation
import Combine

struct StudioProject: Codable, Identifiable {
    let id: String
    var name: String
    let schema: Int
    let created: Double
}

/// Project catalog and independent documents; filesystem access stays in Rust.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [StudioProject] = []
    @Published private(set) var current: StudioProject?
    @Published private(set) var editor = EditorModel()
    @Published private(set) var catalog = WorkspaceCatalog()
    @Published private(set) var assets: [ProjectAssetFile] = []
    @Published var error: String?
    @Published private(set) var saving = false
    let assistant = AssistantSession()
    let root: URL
    private let saves = DispatchQueue(label: "studio.bixel.project-storage", qos: .utility)
    private var saveGeneration = 0
    private var pendingSave: DispatchWorkItem?
    var activeDocument: WorkspaceDocument? { catalog.documents.first { $0.id == catalog.activeDocumentID } }
    var projectRoot: URL? { current.map { root.appendingPathComponent($0.id) } }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bixel/Projects", isDirectory: true)
        refresh()
        bootstrapSamplesIfEmpty()
        do {
            if let id = try ProjectStorage.read(base: self.root, path: "active.txt"),
               let project = projects.first(where: { $0.id == id }) { try open(project) }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        do { projects = try decode([StudioProject].self, ProjectStorage.request(base: root, ["op": "list"]) ?? []) }
        catch { self.error = error.localizedDescription }
    }

    func create(name: String) {
        _ = createProject(name: name, kind: .sprite, width: 32, height: 32)
    }

    @discardableResult
    func createProject(name: String, kind: AssetKind = .sprite, width: Int = 32, height: Int = 32, pixels: [UInt8]? = nil) -> StudioProject? {
        guard !assistant.busy else { return nil }
        do {
            let id = UUID().uuidString
            let value = try ProjectStorage.request(base: root, ["op": "create", "id": id, "name": name])!
            let project = try decode(StudioProject.self, value)
            let base = root.appendingPathComponent(project.id)

            let doc = WorkspaceDocument(name: name, kind: kind, width: width, height: height)
            let editorModel = EditorModel(width: doc.pixelWidth, height: doc.pixelHeight)
            if let pixels, pixels.count == doc.pixelWidth * doc.pixelHeight * 4 {
                editorModel.document.loadImageData(pixels, width: doc.pixelWidth, height: doc.pixelHeight, layer: 0, frame: 0)
            }
            try editorModel.document.save(base: base, path: doc.path)

            var nextCatalog = WorkspaceCatalog()
            nextCatalog.documents = [doc]
            nextCatalog.activeDocumentID = doc.id
            try writeCatalog(nextCatalog, base: base)

            refresh()
            try open(project)
            return project
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createFromTemplate(templateId: String) -> StudioProject? {
        guard let item = SamplePixelArt.templates.first(where: { $0.id == templateId }) else { return nil }
        let pixels = SamplePixelArt.generateSampleData(for: item.name, width: item.width, height: item.height)
        return createProject(name: item.name, kind: item.kind, width: item.width, height: item.height, pixels: pixels)
    }

    func closeProject() {
        guard !assistant.busy else { return }
        do {
            try flush()
            current = nil
            catalog = WorkspaceCatalog()
            assets = []
            _ = try? ProjectStorage.request(base: root, ["op": "write", "path": "active.txt", "text": ""])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteProject(_ project: StudioProject) {
        guard !assistant.busy else { return }
        if current?.id == project.id {
            closeProject()
        }
        let base = root.appendingPathComponent(project.id)
        try? FileManager.default.removeItem(at: base)
        refresh()
    }

    func duplicateProject(_ project: StudioProject) {
        guard !assistant.busy else { return }
        let newName = "\(project.name) Copy"
        let src = root.appendingPathComponent(project.id)
        let newId = UUID().uuidString
        let dst = root.appendingPathComponent(newId)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            let meta: [String: Any] = [
                "id": newId,
                "name": newName,
                "schema": 1,
                "created": Date().timeIntervalSince1970
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta)
            try metaData.write(to: dst.appendingPathComponent("project.json"))
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func renameProject(_ project: StudioProject, newName: String) {
        let base = root.appendingPathComponent(project.id)
        let file = base.appendingPathComponent("project.json")
        do {
            let meta: [String: Any] = [
                "id": project.id,
                "name": newName,
                "schema": 1,
                "created": project.created
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta)
            try metaData.write(to: file)
            refresh()
            if current?.id == project.id {
                current?.name = newName
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func metadata(for project: StudioProject) -> (kind: AssetKind, sizeText: String, timeText: String) {
        let base = root.appendingPathComponent(project.id)
        if let json = try? ProjectStorage.read(base: base, path: "workspace.json"),
           let data = json.data(using: .utf8),
           let catalog = try? JSONDecoder().decode(WorkspaceCatalog.self, from: data),
           let active = catalog.documents.first(where: { $0.id == catalog.activeDocumentID }) ?? catalog.documents.first {
            return (active.kind, "\(active.pixelWidth) × \(active.pixelHeight)", relativeTime(since: project.created))
        }
        return (.sprite, "32 × 32", relativeTime(since: project.created))
    }

    private func relativeTime(since timestamp: Double) -> String {
        let diff = max(0, Date().timeIntervalSince1970 - timestamp)
        if diff < 3600 { return "Edited 2h ago" }
        if diff < 86400 { return "Edited \(max(1, Int(diff / 3600)))h ago" }
        if diff < 604800 { return "Edited \(max(1, Int(diff / 86400)))d ago" }
        return "Edited \(max(1, Int(diff / 604800)))w ago"
    }

    private func bootstrapSamplesIfEmpty() {
        guard projects.isEmpty else { return }
        let samples: [(name: String, kind: AssetKind, w: Int, h: Int)] = [
            ("Slime Sprite", .sprite, 32, 32),
            ("Character Walk", .animation, 64, 64),
            ("Forest Tiles", .tileset, 128, 128),
            ("Tokyo Street", .tileset, 128, 128),
            ("UI Icons", .sprite, 32, 32),
            ("NPC Portraits", .sprite, 64, 64)
        ]
        for s in samples {
            let pixels = SamplePixelArt.generateSampleData(for: s.name, width: s.w, height: s.h)
            _ = createProjectQuietly(name: s.name, kind: s.kind, width: s.w, height: s.h, pixels: pixels)
        }
        refresh()
    }

    private func createProjectQuietly(name: String, kind: AssetKind, width: Int, height: Int, pixels: [UInt8]?) -> StudioProject? {
        do {
            let id = UUID().uuidString
            let value = try ProjectStorage.request(base: root, ["op": "create", "id": id, "name": name])!
            let project = try decode(StudioProject.self, value)
            let base = root.appendingPathComponent(project.id)

            let doc = WorkspaceDocument(name: name, kind: kind, width: width, height: height)
            let editorModel = EditorModel(width: doc.pixelWidth, height: doc.pixelHeight)
            if let pixels, pixels.count == doc.pixelWidth * doc.pixelHeight * 4 {
                editorModel.document.loadImageData(pixels, width: doc.pixelWidth, height: doc.pixelHeight, layer: 0, frame: 0)
            }
            try editorModel.document.save(base: base, path: doc.path)

            var nextCatalog = WorkspaceCatalog()
            nextCatalog.documents = [doc]
            nextCatalog.activeDocumentID = doc.id
            try writeCatalog(nextCatalog, base: base)
            return project
        } catch {
            return nil
        }
    }

    func select(_ project: StudioProject) {
        do { try open(project) } catch { self.error = error.localizedDescription }
    }

    private func open(_ project: StudioProject) throws {
        guard !assistant.busy else { throw StorageError.message("Wait for the assistant to finish before switching projects.") }
        if current?.id == project.id { return }
        try flush()
        let base = root.appendingPathComponent(project.id)
        var nextCatalog = WorkspaceCatalog()
        var document: Document?
        if let json = try ProjectStorage.read(base: base, path: "workspace.json") {
            nextCatalog = try JSONDecoder().decode(WorkspaceCatalog.self, from: Data(json.utf8))
            guard nextCatalog.schema == 1, nextCatalog.documents.allSatisfy({ $0.validationError == nil }),
                  Set(nextCatalog.documents.map(\.id)).count == nextCatalog.documents.count else {
                throw StorageError.message("The workspace catalog is invalid or uses an unsupported version.")
            }
            if let id = nextCatalog.activeDocumentID {
                guard let item = nextCatalog.documents.first(where: { $0.id == id }),
                      let json = try ProjectStorage.read(base: base, path: item.path) else {
                    throw StorageError.message("The active document is missing.")
                }
                document = try Document(json: json)
            }
        } else if let json = try ProjectStorage.read(base: base, path: "document.json") {
            // Copy the legacy canvas into the catalog; retain the original file.
            let legacy = try Document(json: json)
            let item = WorkspaceDocument(name: "Original canvas", kind: legacy.frameCount > 1 ? .animation : .sprite,
                                         width: legacy.width, height: legacy.height)
            try legacy.save(base: base, path: item.path)
            nextCatalog.documents = [item]; nextCatalog.activeDocumentID = item.id
            document = legacy
        }
        let transcript = try ProjectStorage.read(base: base, path: "assistant.json")
        let state = try transcript.map { try JSONDecoder().decode(AssistantSavedState.self, from: Data($0.utf8)) }
        current = project; catalog = nextCatalog; assets = []
        installEditor(document.map { EditorModel(document: $0) } ?? EditorModel())
        assistant.configure(projectRoot: base, state: state)
        assistant.onPersist = { [weak self] in self?.saveAssistant() }
        assistant.workspaceContext = { [weak self] in self?.contextDescription ?? "" }
        try persistCatalog()
        _ = try ProjectStorage.request(base: root, ["op": "write", "path": "active.txt", "text": project.id])
        refreshAssets()
    }

    func createDocument(_ item: WorkspaceDocument) {
        guard let base = projectRoot, !assistant.busy else { return }
        do {
            if let error = item.validationError { throw StorageError.message(error) }
            try flush()
            let model = EditorModel(width: item.pixelWidth, height: item.pixelHeight)
            try model.document.save(base: base, path: item.path)
            var next = catalog
            next.documents.append(item); next.activeDocumentID = item.id
            try writeCatalog(next, base: base)
            catalog = next; installEditor(model)
        } catch { self.error = error.localizedDescription }
    }

    func openDocument(_ item: WorkspaceDocument) {
        guard let base = projectRoot, !assistant.busy, item.id != catalog.activeDocumentID else { return }
        do {
            try flush()
            guard let json = try ProjectStorage.read(base: base, path: item.path) else { throw StorageError.message("Document is missing.") }
            let model = EditorModel(document: try Document(json: json))
            var next = catalog; next.activeDocumentID = item.id
            try writeCatalog(next, base: base)
            catalog = next; installEditor(model)
        } catch { self.error = error.localizedDescription }
    }

    private func installEditor(_ model: EditorModel) {
        editor.pause(); editor.onDocumentChanged = nil
        editor = model
        model.assetKind = activeDocument?.kind ?? .image
        model.cellWidth = activeDocument?.cellWidth ?? 16
        model.cellHeight = activeDocument?.cellHeight ?? 16
        model.onDocumentChanged = { [weak self] in self?.saveDocument() }
    }

    func setStyle(_ style: String) {
        do { try flush() } catch { self.error = error.localizedDescription; return }
        let old = catalog.style
        catalog.style = String(style.prefix(4000))
        do { try persistCatalog() } catch { catalog.style = old; self.error = error.localizedDescription }
    }

    private func synchronizeDimensions() {
        guard let index = catalog.documents.firstIndex(where: { $0.id == catalog.activeDocumentID }) else { return }
        var item = catalog.documents[index]
        if item.kind.usesCells {
            if editor.width % item.cellWidth == 0 && editor.height % item.cellHeight == 0 {
                item.width = editor.width / item.cellWidth; item.height = editor.height / item.cellHeight
            } else {
                item.kind = .image; item.width = editor.width; item.height = editor.height
                editor.assetKind = .image
            }
        } else { item.width = editor.width; item.height = editor.height }
        catalog.documents[index] = item
    }

    func saveDocument() {
        guard let base = projectRoot, let item = activeDocument else { return }
        synchronizeDimensions()
        let document = editor.document, snapshot = catalog
        saveGeneration += 1
        let generation = saveGeneration
        saving = true; pendingSave?.cancel()
        let work = DispatchWorkItem {
            let result = Result {
                try document.save(base: base, path: item.path)
                try ProjectStorage.write(base: base, path: "workspace.json", data: JSONEncoder().encode(snapshot))
            }
            DispatchQueue.main.async {
                if generation == self.saveGeneration { self.saving = false }
                if case .failure(let error) = result { self.error = error.localizedDescription }
            }
        }
        pendingSave = work
        saves.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveAssistant() {
        guard let base = projectRoot else { return }
        let state = assistant.savedState
        saves.async {
            do { try ProjectStorage.write(base: base, path: "assistant.json", data: JSONEncoder().encode(state)) }
            catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
        if !assistant.busy { refreshAssets() }
    }

    func refreshAssets() {
        guard let base = projectRoot else { assets = []; return }
        do {
            let generated = try decode([ProjectAssetFile].self, ProjectStorage.request(base: base, ["op": "files", "path": ".studio/cache"]) ?? [])
            let accepted = try decode([ProjectAssetFile].self, ProjectStorage.request(base: base, ["op": "files", "path": "assets"]) ?? [])
            assets = accepted + generated
        } catch { self.error = error.localizedDescription }
    }

    func assetData(_ asset: ProjectAssetFile) throws -> Data {
        guard let base = projectRoot, asset.bytes <= 32_000_000 else { throw StorageError.message("Choose an asset smaller than 32 MB.") }
        guard let value = try ProjectStorage.request(base: base, ["op": "read_bytes", "path": asset.path]) else {
            throw StorageError.message("This asset is missing.")
        }
        return Data(try decode([UInt8].self, value))
    }

    func acceptAsset(_ asset: ProjectAssetFile) {
        guard let base = projectRoot else { return }
        do {
            let data = try assetData(asset)
            try ProjectStorage.write(base: base, path: "assets/\(UUID().uuidString)-\(asset.name)", data: data)
            refreshAssets()
        } catch { self.error = error.localizedDescription }
    }

    func openImageAsset(_ asset: ProjectAssetFile) {
        guard !assistant.busy, let base = projectRoot else { return }
        do {
            let data = try assetData(asset)
            guard let image = AIService.pngToRGBA(data), image.width <= 4096, image.height <= 4096 else {
                throw StorageError.message("Choose an image up to 4096 × 4096 pixels.")
            }
            try flush()
            let item = WorkspaceDocument(name: asset.name, kind: .image, width: image.width, height: image.height, sourcePath: asset.path)
            let model = EditorModel(width: image.width, height: image.height)
            model.document.loadImageData(image.rgba, width: image.width, height: image.height, layer: 0, frame: 0)
            try model.document.save(base: base, path: item.path)
            var next = catalog; next.documents.append(item); next.activeDocumentID = item.id
            try writeCatalog(next, base: base)
            catalog = next; installEditor(model)
        } catch { self.error = error.localizedDescription }
    }

    var contextDescription: String {
        let document = activeDocument.map { "Active document: \($0.name), kind=\($0.kind.rawValue), \($0.summary)." } ?? "No document open. Ask what asset the user wants to create."
        let list = catalog.documents.prefix(40).map { "\($0.name): \($0.kind.rawValue), \($0.summary)" }.joined(separator: "\n")
        let files = assets.prefix(40).map(\.path).joined(separator: "\n")
        return "Project: \(current?.name ?? "Untitled"). Shared style: \(catalog.style.isEmpty ? "Not set" : catalog.style)\n\(document)\nProject documents:\n\(list)\nProject asset paths (relative to project root, not conversation workspace):\n\(files)"
    }

    func flush() throws {
        guard let base = projectRoot else { return }
        pendingSave?.cancel(); synchronizeDimensions()
        let state = assistant.savedState, snapshot = catalog, document = editor.document, item = activeDocument
        try saves.sync {
            if let item { try document.save(base: base, path: item.path) }
            try ProjectStorage.write(base: base, path: "workspace.json", data: JSONEncoder().encode(snapshot))
            try ProjectStorage.write(base: base, path: "assistant.json", data: JSONEncoder().encode(state))
        }
        saveGeneration += 1; saving = false
    }

    private func persistCatalog() throws {
        guard let base = projectRoot else { return }
        try writeCatalog(catalog, base: base)
    }
    private func writeCatalog(_ value: WorkspaceCatalog, base: URL) throws {
        try saves.sync { try ProjectStorage.write(base: base, path: "workspace.json", data: JSONEncoder().encode(value)) }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}
