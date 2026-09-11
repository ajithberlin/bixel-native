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
    /// Non-nil exactly when the active document is a `.map` opened in the
    /// Tilemap Designer. The sprite `editor` stays installed as a fallback for
    /// the assistant but never writes files while a map is active.
    @Published private(set) var mapEditor: TileMapModel?
    @Published private(set) var catalog = WorkspaceCatalog()
    @Published private(set) var assets: [ProjectAssetFile] = []
    @Published var error: String?
    @Published private(set) var saving = false
    let assistant = AssistantSession()
    let root: URL
    let aiGallery: AIGalleryStore
    private let saves = DispatchQueue(label: "studio.bixel.project-storage", qos: .utility)
    private var saveGeneration = 0
    private var pendingSave: DispatchWorkItem?
    var activeDocument: WorkspaceDocument? { catalog.documents.first { $0.id == catalog.activeDocumentID } }
    var projectRoot: URL? { current.map { root.appendingPathComponent($0.id) } }
    var isMapActive: Bool { activeDocument?.mode == .map }

    init(root: URL? = nil) {
        let resolvedRoot = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bixel/Projects", isDirectory: true)
        self.root = resolvedRoot
        self.aiGallery = AIGalleryStore(root: resolvedRoot)
        EditorBridge.shared.attach(store: self)
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
        _ = createProject(name: name, mode: .normal, width: 32, height: 32)
    }

    @discardableResult
    func createProject(name: String, mode: WorkspaceMode = .normal, width: Int = 32, height: Int = 32,
                       pixels: [UInt8]? = nil, cellWidth: Int = 16, cellHeight: Int = 16) -> StudioProject? {
        guard !assistant.busy else { return nil }
        do {
            let id = UUID().uuidString
            let value = try ProjectStorage.request(base: root, ["op": "create", "id": id, "name": name])!
            let project = try decode(StudioProject.self, value)
            let base = root.appendingPathComponent(project.id)

            if mode == .map {
                // A Map project opens straight into the Tilemap Designer: width
                // and height are treated as cells at the given cell size.
                let doc = WorkspaceDocument(name: name, mode: .map,
                                            width: max(1, width), height: max(1, height),
                                            cellWidth: cellWidth, cellHeight: cellHeight)
                let mapModel = TileMapModel(width: doc.width, height: doc.height,
                                            tileWidth: doc.cellWidth, tileHeight: doc.cellHeight)
                try mapModel.map.save(base: base, path: doc.path)
                var nextCatalog = WorkspaceCatalog()
                nextCatalog.documents = [doc]
                nextCatalog.activeDocumentID = doc.id
                try writeCatalog(nextCatalog, base: base)
                refresh()
                try open(project)
                return project
            }

            let doc = WorkspaceDocument(name: name, mode: .normal, width: width, height: height)
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
        return createProject(name: item.name, mode: .normal, width: item.width, height: item.height, pixels: pixels)
    }

    /// Import a single image as a new project (canvas = image size, one frame).
    @discardableResult
    func importImageProject(png: Data, name: String) -> StudioProject? {
        guard !assistant.busy else { return nil }
        guard let image = AIService.pngToRGBA(png), image.width > 0, image.height > 0,
              image.width <= 4096, image.height <= 4096 else {
            self.error = "Choose an image up to 4096 × 4096 pixels."
            return nil
        }
        return createImportedProject(name: name) { _ in
            let doc = Document(width: image.width, height: image.height)
            doc.loadImageData(image.rgba, width: image.width, height: image.height, layer: 0, frame: 0)
            return (doc, WorkspaceDocument(name: name, mode: .normal, width: image.width, height: image.height))
        }
    }

    /// Import a spritesheet PNG + manifest as a new animation project: the
    /// canvas becomes the sheet's frame size and every frame/tag lands on the
    /// timeline.
    @discardableResult
    func importSheetProject(png: Data, manifest: String, name: String) -> StudioProject? {
        guard !assistant.busy else { return nil }
        guard let image = AIService.pngToRGBA(png) else {
            self.error = "Could not decode the spritesheet."
            return nil
        }
        return createImportedProject(name: name) { _ in
            let doc = try Document.fromSheet(rgba: image.rgba, width: image.width, height: image.height,
                                             manifest: manifest, layerName: "Sprites")
            return (doc, WorkspaceDocument(name: name, mode: .normal, width: doc.width, height: doc.height))
        }
    }

    private func createImportedProject(
        name: String,
        make: (URL) throws -> (Document, WorkspaceDocument)
    ) -> StudioProject? {
        do {
            let id = UUID().uuidString
            let value = try ProjectStorage.request(base: root, ["op": "create", "id": id, "name": name])!
            let project = try decode(StudioProject.self, value)
            let base = root.appendingPathComponent(project.id)
            let (doc, item) = try make(base)
            try doc.save(base: base, path: item.path)
            var nextCatalog = WorkspaceCatalog()
            nextCatalog.documents = [item]
            nextCatalog.activeDocumentID = item.id
            try writeCatalog(nextCatalog, base: base)
            refresh()
            try open(project)
            return project
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func closeProject() {
        guard !assistant.busy else { return }
        do {
            try flush()
            current = nil
            catalog = WorkspaceCatalog()
            assets = []
            mapEditor?.onDocumentChanged = nil
            mapEditor = nil
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

    func metadata(for project: StudioProject) -> (mode: WorkspaceMode, sizeText: String, timeText: String) {
        let base = root.appendingPathComponent(project.id)
        if let json = try? ProjectStorage.read(base: base, path: "workspace.json"),
           let data = json.data(using: .utf8),
           let catalog = try? JSONDecoder().decode(WorkspaceCatalog.self, from: data),
           let active = catalog.documents.first(where: { $0.id == catalog.activeDocumentID }) ?? catalog.documents.first {
            let sizeText = active.mode == .map
                ? "\(active.width) × \(active.height) cells"
                : "\(active.pixelWidth) × \(active.pixelHeight)"
            return (active.mode, sizeText, relativeTime(since: project.created))
        }
        return (.normal, "32 × 32", relativeTime(since: project.created))
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
        let samples: [(name: String, w: Int, h: Int)] = [
            ("Slime Sprite", 32, 32),
            ("Character Walk", 64, 64),
            ("Forest Tiles", 128, 128),
            ("Tokyo Street", 128, 128),
            ("UI Icons", 32, 32),
            ("NPC Portraits", 64, 64)
        ]
        for s in samples {
            let pixels = SamplePixelArt.generateSampleData(for: s.name, width: s.w, height: s.h)
            _ = createProjectQuietly(name: s.name, width: s.w, height: s.h, pixels: pixels)
        }
        refresh()
    }

    private func createProjectQuietly(name: String, width: Int, height: Int, pixels: [UInt8]?) -> StudioProject? {
        do {
            let id = UUID().uuidString
            let value = try ProjectStorage.request(base: root, ["op": "create", "id": id, "name": name])!
            let project = try decode(StudioProject.self, value)
            let base = root.appendingPathComponent(project.id)

            let doc = WorkspaceDocument(name: name, mode: .normal, width: width, height: height)
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
        var mapDocument: TileMapModel?
        if let json = try ProjectStorage.read(base: base, path: "workspace.json") {
            nextCatalog = try JSONDecoder().decode(WorkspaceCatalog.self, from: Data(json.utf8))
            guard (nextCatalog.schema == 1 || nextCatalog.schema == 2), nextCatalog.documents.allSatisfy({ $0.validationError == nil }),
                  Set(nextCatalog.documents.map(\.id)).count == nextCatalog.documents.count else {
                throw StorageError.message("The workspace catalog is invalid or uses an unsupported version.")
            }
            if let id = nextCatalog.activeDocumentID {
                guard let item = nextCatalog.documents.first(where: { $0.id == id }),
                      let json = try ProjectStorage.read(base: base, path: item.path) else {
                    throw StorageError.message("The active document is missing.")
                }
                if item.mode == .map {
                    let model = try TileMapModel(json: json)
                    loadMapTilesetImages(model, base: base)
                    mapDocument = model
                } else {
                    document = try Document(json: json)
                }
            }
        } else if let json = try ProjectStorage.read(base: base, path: "document.json") {
            // Copy the legacy canvas into the catalog; retain the original file.
            let legacy = try Document(json: json)
            let item = WorkspaceDocument(name: "Original canvas", mode: .normal,
                                         width: legacy.width, height: legacy.height)
            try legacy.save(base: base, path: item.path)
            nextCatalog.documents = [item]; nextCatalog.activeDocumentID = item.id
            document = legacy
        }
        let transcript = try ProjectStorage.read(base: base, path: "assistant.json")
        let state = try transcript.map { try JSONDecoder().decode(AssistantSavedState.self, from: Data($0.utf8)) }
        current = project; catalog = nextCatalog; assets = []
        if let mapDocument {
            installEditor(EditorModel())
            installMapEditor(mapDocument)
        } else {
            installEditor(document.map { EditorModel(document: $0) } ?? EditorModel())
        }
        assistant.configure(projectRoot: base, state: state)
        assistant.onPersist = { [weak self] in self?.saveAssistant() }
        assistant.onArtifactPersisted = { [weak self] in self?.refreshAssets() }
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
            if item.mode == .map {
                let model = TileMapModel(width: item.width, height: item.height,
                                         tileWidth: item.cellWidth, tileHeight: item.cellHeight)
                try model.map.save(base: base, path: item.path)
                var next = catalog
                next.documents.append(item); next.activeDocumentID = item.id
                try writeCatalog(next, base: base)
                catalog = next
                installEditor(EditorModel(width: item.pixelWidth, height: item.pixelHeight))
                installMapEditor(model)
            } else {
                let model = EditorModel(width: item.pixelWidth, height: item.pixelHeight)
                try model.document.save(base: base, path: item.path)
                var next = catalog
                next.documents.append(item); next.activeDocumentID = item.id
                try writeCatalog(next, base: base)
                catalog = next; installEditor(model)
            }
        } catch { self.error = error.localizedDescription }
    }

    func openDocument(_ item: WorkspaceDocument) {
        guard let base = projectRoot, !assistant.busy, item.id != catalog.activeDocumentID else { return }
        do {
            try flush()
            guard let json = try ProjectStorage.read(base: base, path: item.path) else { throw StorageError.message("Document is missing.") }
            if item.mode == .map {
                let model = try TileMapModel(json: json)
                loadMapTilesetImages(model, base: base)
                var next = catalog; next.activeDocumentID = item.id
                try writeCatalog(next, base: base)
                catalog = next
                installEditor(EditorModel())
                installMapEditor(model)
            } else {
                let model = EditorModel(document: try Document(json: json))
                var next = catalog; next.activeDocumentID = item.id
                try writeCatalog(next, base: base)
                catalog = next; installEditor(model)
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Keep the sprite editor alive for assistant flows but detach its saves
    /// while a map owns the active document.
    private func installMapEditor(_ model: TileMapModel) {
        mapEditor?.onDocumentChanged = nil
        mapEditor = model
        model.onDocumentChanged = { [weak self] in self?.saveDocument() }
        model.persistAssetData = { [weak self] data, name in
            self?.persistImageAsset(data: data, name: name)
        }
        model.registerTilesets()
        editor.onDocumentChanged = nil
        if mapEditor == nil {
            editor.onDocumentChanged = { [weak self] in self?.saveDocument() }
        }
    }

    /// Decode and upload every tileset PNG referenced by a freshly parsed map so
    /// compositing works and the palette shows real thumbnails. Also restores
    /// image-layer pixels from their referenced asset files.
    func loadMapTilesetImages(_ model: TileMapModel, base: URL) {
        model.registerTilesets()
        for info in model.map.tilesetsInfo() where !info.image.isEmpty {
            if model.tilesetDisplayImage(info.index) != nil { continue }
            do {
                guard let data = try ProjectStorage.readBytes(base: base, path: info.image) else { continue }
                guard let image = AIService.pngToRGBA(data),
                      image.width == info.imageWidth, image.height == info.imageHeight,
                      let cg = makeCGImage(pixels: image.rgba, width: image.width, height: image.height) else { continue }
                model.uploadTileset(info.index, cgImage: cg, rgba: image.rgba)
            } catch {
                continue
            }
        }
        for layer in model.layers where layer.type == "image" {
            guard let path = layer.image, !path.isEmpty,
                  let w = layer.imageWidth, let h = layer.imageHeight, w > 0, h > 0 else { continue }
            do {
                guard let data = try ProjectStorage.readBytes(base: base, path: path) else { continue }
                guard let image = AIService.pngToRGBA(data),
                      image.width == w, image.height == h else { continue }
                model.uploadImageLayer(layer.index, rgba: image.rgba)
            } catch {
                continue
            }
        }
        model.refreshCanvas()
    }

    /// Persist a decoded image into `assets/` and return its workspace-relative
    /// path (used by the tileset importer so the map JSON references the file).
    func persistImageAsset(data: Data, name: String) -> String? {
        guard let base = projectRoot else { return nil }
        let stem = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let path = "assets/\(UUID().uuidString.prefix(8))-\(stem).png"
        do {
            try ProjectStorage.write(base: base, path: path, data: data)
            refreshAssets()
            return path
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Create a brand-new map document from an imported Tiled JSON file and open
    /// it (round-trip: export → reimport must reopen identically).
    func importTiledMap(from url: URL) {
        guard let base = projectRoot, !assistant.busy else { return }
        do {
            let sourceData = try Data(contentsOf: url)
            let preparedJSON = try TileMapImport.prepareMapJSON(
                sourceData,
                sourceDirectory: url.deletingLastPathComponent()
            ) { [weak self] data, name in
                guard let self, let path = self.persistImageAsset(data: data, name: name) else {
                    throw StorageError.message("Could not copy imported tileset image into the project.")
                }
                return path
            }
            let json = preparedJSON
            let model = try TileMapModel(json: json)
            try flush()
            let name = url.deletingPathExtension().lastPathComponent
            let item = WorkspaceDocument(name: name, mode: .map,
                                         width: model.map.columns, height: model.map.rows,
                                         cellWidth: model.map.cellWidth, cellHeight: model.map.cellHeight)
            try model.map.save(base: base, path: item.path)
            var next = catalog
            next.documents.append(item); next.activeDocumentID = item.id
            try writeCatalog(next, base: base)
            catalog = next
            installEditor(EditorModel(width: item.pixelWidth, height: item.pixelHeight))
            installMapEditor(model)
            loadMapTilesetImages(model, base: base)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func installEditor(_ model: EditorModel) {
        editor.pause(); editor.onDocumentChanged = nil
        mapEditor?.onDocumentChanged = nil
        mapEditor = nil
        editor = model
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
        if item.mode == .map {
            if let model = mapEditor {
                item.width = model.map.columns
                item.height = model.map.rows
                item.cellWidth = model.map.cellWidth
                item.cellHeight = model.map.cellHeight
            }
        } else { item.width = editor.width; item.height = editor.height }
        catalog.documents[index] = item
    }

    func saveDocument() {
        guard let base = projectRoot, let item = activeDocument else { return }
        synchronizeDimensions()
        saveGeneration += 1
        let generation = saveGeneration
        saving = true; pendingSave?.cancel()
        let snapshot = catalog
        let isMap = item.mode == .map
        let mapDoc = mapEditor?.map
        let spriteDoc = editor.document
        let work = DispatchWorkItem {
            let result: Result<Void, Error>
            if isMap {
                guard let mapDoc else {
                    result = .failure(StorageError.message("The map is not loaded."))
                    DispatchQueue.main.async {
                        if generation == self.saveGeneration { self.saving = false }
                        if case .failure(let error) = result { self.error = error.localizedDescription }
                    }
                    return
                }
                result = Result {
                    try mapDoc.save(base: base, path: item.path)
                    try ProjectStorage.write(base: base, path: "workspace.json", data: JSONEncoder().encode(snapshot))
                }
            } else {
                result = Result {
                    try spriteDoc.save(base: base, path: item.path)
                    try ProjectStorage.write(base: base, path: "workspace.json", data: JSONEncoder().encode(snapshot))
                }
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
        guard let base = projectRoot else { throw StorageError.message("This asset is missing.") }
        return try readProjectAssetData(base: base, path: asset.path, bytes: asset.bytes)
    }

    /// Decode an asset without making the synchronous FFI read block the main
    /// actor. The project root, path, and size are copied before the task is
    /// detached so no actor-isolated store state crosses the boundary.
    func assetDataAsync(_ asset: ProjectAssetFile) async throws -> Data {
        guard let base = projectRoot else { throw StorageError.message("This asset is missing.") }
        let path = asset.path
        let bytes = asset.bytes
        return try await Task.detached(priority: .utility) {
            try readProjectAssetData(base: base, path: path, bytes: bytes)
        }.value
    }

    func acceptAsset(_ asset: ProjectAssetFile) {
        guard let base = projectRoot else { return }
        do {
            let data = try assetData(asset)
            try ProjectStorage.write(base: base, path: "assets/\(UUID().uuidString)-\(asset.name)", data: data)
            refreshAssets()
        } catch { self.error = error.localizedDescription }
    }

    /// Place an image from the library onto the active map as a real image
    /// layer (composited, saved with the map and editable in the layers panel).
    func placeImageOnMap(_ asset: ProjectAssetFile) {
        guard isMapActive, let map = mapEditor else { return }
        do {
            let data = try assetData(asset)
            guard let image = AIService.pngToRGBA(data) else {
                throw StorageError.message("Could not decode that image.")
            }
            map.addImageLayer(rgba: image.rgba, width: image.width, height: image.height,
                              name: asset.name, imagePath: asset.path)
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
            let item = WorkspaceDocument(name: asset.name, mode: .normal, width: image.width, height: image.height, sourcePath: asset.path)
            let model = EditorModel(width: image.width, height: image.height)
            model.document.loadImageData(image.rgba, width: image.width, height: image.height, layer: 0, frame: 0)
            try model.document.save(base: base, path: item.path)
            var next = catalog; next.documents.append(item); next.activeDocumentID = item.id
            try writeCatalog(next, base: base)
            catalog = next; installEditor(model)
        } catch { self.error = error.localizedDescription }
    }

    var contextDescription: String {
        let document = activeDocument.map { "Active document: \($0.name), mode=\($0.mode.rawValue), \($0.summary)." } ?? "No document open. Ask what asset the user wants to create."
        let list = catalog.documents.prefix(40).map { "\($0.name): \($0.mode.rawValue), \($0.summary)" }.joined(separator: "\n")
        let files = assets.prefix(40).map(\.path).joined(separator: "\n")
        return "Project: \(current?.name ?? "Untitled"). Shared style: \(catalog.style.isEmpty ? "Not set" : catalog.style)\n\(document)\nProject documents:\n\(list)\nProject asset paths (relative to project root, not conversation workspace):\n\(files)"
    }

    func flush() throws {
        guard let base = projectRoot else { return }
        pendingSave?.cancel(); synchronizeDimensions()
        let state = assistant.savedState, snapshot = catalog, item = activeDocument
        let isMap = item?.mode == .map
        let mapDoc = mapEditor?.map
        let document = editor.document
        try saves.sync {
            if let item {
                if isMap, let mapDoc {
                    try mapDoc.save(base: base, path: item.path)
                } else {
                    try document.save(base: base, path: item.path)
                }
            }
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

private func readProjectAssetData(base: URL, path: String, bytes: Int) throws -> Data {
    guard bytes <= 32_000_000 else { throw StorageError.message("Choose an asset smaller than 32 MB.") }
    guard let data = try ProjectStorage.readBytes(base: base, path: path) else {
        throw StorageError.message("This asset is missing.")
    }
    return data
}
