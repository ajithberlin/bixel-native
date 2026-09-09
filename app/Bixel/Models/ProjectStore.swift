import Foundation
import Combine

struct StudioProject: Codable, Identifiable {
    let id: String
    var name: String
    let schema: Int
    let created: Double
}

/// Uses the platform's Documents container, including on a future iPad host.
/// All actual filesystem access goes through the Rust path gateway.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [StudioProject] = []
    @Published private(set) var current: StudioProject?
    @Published private(set) var editor = EditorModel()
    @Published var error: String?
    @Published private(set) var saving = false
    let assistant = AssistantSession()
    let root: URL
    private let saves = DispatchQueue(label: "studio.bixel.project-storage", qos: .utility)
    private var saveGeneration = 0
    private var pendingSave: DispatchWorkItem?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bixel/Projects", isDirectory: true)
        refresh()
        do {
            if let id = try ProjectStorage.read(base: self.root, path: "active.txt"),
               let project = projects.first(where: { $0.id == id }) { try open(project) }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        do {
            let value = try ProjectStorage.request(base: root, ["op": "list"]) ?? []
            projects = try JSONDecoder().decode([StudioProject].self, from: JSONSerialization.data(withJSONObject: value))
        } catch { self.error = error.localizedDescription }
    }

    func create(name: String) {
        guard !assistant.busy else { return }
        do {
            let value = try ProjectStorage.request(base: root, ["op": "create", "id": UUID().uuidString, "name": name])!
            let project = try JSONDecoder().decode(StudioProject.self, from: JSONSerialization.data(withJSONObject: value))
            refresh()
            try open(project)
            saveDocument()
        } catch { self.error = error.localizedDescription }
    }

    func select(_ project: StudioProject) {
        do { try open(project) } catch { self.error = error.localizedDescription }
    }

    private func open(_ project: StudioProject) throws {
        guard !assistant.busy else { throw StorageError.message("Wait for the assistant to finish before switching projects.") }
        if current?.id == project.id { return }
        try flush()
        let json = try ProjectStorage.read(base: root, path: "\(project.id)/document.json")
        let document = try json.map { try Document(json: $0) }
        let transcript = try ProjectStorage.read(base: root, path: "\(project.id)/assistant.json")
        let state = try transcript.map { try JSONDecoder().decode(AssistantSavedState.self, from: Data($0.utf8)) }
        editor.pause()
        editor.onDocumentChanged = nil
        let editor = EditorModel(document: document)
        self.editor = editor
        self.current = project
        assistant.configure(projectRoot: root.appendingPathComponent(project.id), state: state)
        assistant.onPersist = { [weak self] in self?.saveAssistant() }
        editor.onDocumentChanged = { [weak self] in self?.saveDocument() }
        _ = try ProjectStorage.request(base: root, ["op": "write", "path": "active.txt", "text": project.id])
    }

    func saveDocument() {
        guard let project = current else { return }
        let document = editor.document, root = root
        saveGeneration += 1
        let generation = saveGeneration
        saving = true
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            let result = Result { try document.save(base: root, path: "\(project.id)/document.json") }
            DispatchQueue.main.async {
                if generation == self.saveGeneration { self.saving = false }
                if case .failure(let error) = result { self.error = error.localizedDescription }
            }
        }
        pendingSave = work
        saves.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveAssistant() {
        guard let project = current else { return }
        let state = assistant.savedState, root = root
        saves.async {
            do {
                let data = try JSONEncoder().encode(state)
                try ProjectStorage.write(base: root, path: "\(project.id)/assistant.json", data: data)
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }

    /// Finish queued writes before switching or allowing the window to close.
    func flush() throws {
        guard let project = current else { return }
        pendingSave?.cancel()
        let data = try JSONEncoder().encode(assistant.savedState)
        let root = root, document = editor.document
        try saves.sync {
            try document.save(base: root, path: "\(project.id)/document.json")
            try ProjectStorage.write(base: root, path: "\(project.id)/assistant.json", data: data)
        }
    }
}
