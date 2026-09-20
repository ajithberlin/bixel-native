// RemoteSync.swift
//
// P2: project replication. The iPad drives a per-project sync against the Mac:
// both sides scan a content-addressed manifest (bixel_core::sync), the client
// computes a three-way plan, transfers only changed files, and resolves
// conflicts by preserving both copies (the Mac stays authoritative for the
// primary file). Regenerable caches are excluded from manifests.

import Foundation

enum RemoteSyncType {
    static let list = "sync.list"
    static let manifest = "sync.manifest"
    static let fetch = "sync.fetch"
    static let file = "sync.file"
    static let push = "sync.push"
    static let delete = "sync.delete"
    static let commit = "sync.commit"
    static let done = "sync.done"
}

extension Notification.Name {
    /// Posted on the client after a sync so the project list can refresh.
    static let bixelRemoteSyncCompleted = Notification.Name("bixel.remote.syncCompleted")
}

enum RemoteJSON {
    static func object<T: Encodable>(_ value: T) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }
}

// MARK: - Client request/response broker

final class RemoteRequestBroker {
    static let shared = RemoteRequestBroker()

    private let lock = NSLock()
    private var pending: [String: (Result<RemoteMessage, Error>) -> Void] = [:]

    func send(type: String, payload: [String: Any], timeout: TimeInterval = 30,
              completion: @escaping (Result<RemoteMessage, Error>) -> Void) {
        let message = RemoteMessage(type: type, payload: payload)
        lock.lock(); pending[message.id] = completion; lock.unlock()
        do {
            try RemoteClient.shared.send(message)
        } catch {
            lock.lock(); pending.removeValue(forKey: message.id); lock.unlock()
            completion(.failure(error))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let handler = self.pending.removeValue(forKey: message.id); self.lock.unlock()
            handler?(.failure(RemoteError.disconnected("The Mac did not respond.")))
        }
    }

    /// Route a reply to its waiting request. Returns true when consumed.
    @discardableResult
    func resolve(_ message: RemoteMessage) -> Bool {
        guard let replyTo = message.replyTo else { return false }
        lock.lock(); let handler = pending.removeValue(forKey: replyTo); lock.unlock()
        guard let handler else { return false }
        handler(.success(message))
        return true
    }
}

// MARK: - Host (Mac) file server

final class RemoteHostSyncBridge {
    static let shared = RemoteHostSyncBridge()

    private let root = ProjectStore.defaultRoot

    func handle(_ message: RemoteMessage, session: RemoteSession) {
        switch message.type {
        case RemoteSyncType.list: replyList(message, session)
        case RemoteSyncType.manifest: replyManifest(message, session)
        case RemoteSyncType.fetch: replyFile(message, session)
        case RemoteSyncType.push: applyPush(message, session)
        case RemoteSyncType.delete: applyDelete(message, session)
        case RemoteSyncType.commit: applyCommit(message, session)
        default: break
        }
    }

    private func projectRoot(_ id: String) -> URL? {
        guard !id.isEmpty, !id.contains("/"), !id.contains(".."), id.count <= 120 else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    private func replyList(_ message: RemoteMessage, _ session: RemoteSession) {
        var projects: [[String: Any]] = []
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? ProjectStorage.readBytes(base: entry, path: "project.json"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["name"] as? String else { continue }
            projects.append(["id": entry.lastPathComponent, "name": name])
        }
        try? session.send(RemoteMessage(type: RemoteSyncType.list, replyTo: message.id, payload: ["projects": projects]))
    }

    private func replyManifest(_ message: RemoteMessage, _ session: RemoteSession) {
        guard let id = message.payload["projectId"] as? String, let projectRoot = projectRoot(id) else { return }
        let manifest = (try? ProjectSync.manifest(projectRoot: projectRoot, projectID: id)) ?? ProjectSync.Manifest(projectID: id)
        guard let object = RemoteJSON.object(manifest) else { return }
        try? session.send(RemoteMessage(type: RemoteSyncType.manifest, replyTo: message.id,
                                        payload: ["projectId": id, "manifest": object]))
    }

    private func replyFile(_ message: RemoteMessage, _ session: RemoteSession) {
        guard let id = message.payload["projectId"] as? String,
              let path = message.payload["path"] as? String,
              let projectRoot = projectRoot(id) else { return }
        guard let data = try? ProjectStorage.readBytes(base: projectRoot, path: path) else {
            try? session.send(RemoteMessage(type: RemoteSyncType.file, replyTo: message.id,
                                            payload: ["projectId": id, "path": path, "missing": true]))
            return
        }
        try? session.send(RemoteMessage(type: RemoteSyncType.file, replyTo: message.id, payload: [
            "projectId": id, "path": path, "data": data.base64EncodedString(),
        ]))
    }

    private func applyPush(_ message: RemoteMessage, _ session: RemoteSession) {
        guard let id = message.payload["projectId"] as? String,
              let path = message.payload["path"] as? String,
              let base64 = message.payload["data"] as? String,
              let data = Data(base64Encoded: base64),
              let projectRoot = projectRoot(id) else { return }
        let result: Result<Void, Error>
        do {
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            try ProjectStorage.write(base: projectRoot, path: path, data: data)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        ack(message, session, result)
    }

    private func applyDelete(_ message: RemoteMessage, _ session: RemoteSession) {
        guard let id = message.payload["projectId"] as? String,
              let path = message.payload["path"] as? String,
              let projectRoot = projectRoot(id) else { return }
        let result: Result<Void, Error>
        do {
            let target = projectRoot.appendingPathComponent(path).standardizedFileURL
            guard target.path.hasPrefix(projectRoot.standardizedFileURL.path) else {
                throw RemoteError.protocolViolation("path escapes project")
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        ack(message, session, result)
    }

    private func applyCommit(_ message: RemoteMessage, _ session: RemoteSession) {
        guard let id = message.payload["projectId"] as? String,
              let object = message.payload["manifest"],
              let manifest = RemoteJSON.decode(ProjectSync.Manifest.self, object),
              let projectRoot = projectRoot(id) else { return }
        let result: Result<Void, Error>
        do {
            var stored = manifest
            stored.projectID = id
            stored.device = "mac"
            try ProjectSync.writeManifest(projectRoot: projectRoot, manifest: stored)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        ack(message, session, result)
    }

    private func ack(_ message: RemoteMessage, _ session: RemoteSession, _ result: Result<Void, Error>) {
        switch result {
        case .success:
            try? session.send(RemoteMessage(type: RemoteSyncType.done, replyTo: message.id, payload: ["ok": true]))
        case .failure(let error):
            try? session.send(RemoteMessage(type: RemoteSyncType.done, replyTo: message.id,
                                            payload: ["ok": false, "error": error.localizedDescription]))
        }
    }
}

// MARK: - History + space reclamation

/// One synced revision: the previous content hash of every file the sync
/// replaced or deleted, so a version can be restored and both sides stay lean.
struct RemoteHistoryEntry: Codable {
    var revision: UInt64
    var timestamp: UInt64
    var device: String
    /// project-relative path → `blake3:<hex>` of the previous content.
    var files: [String: String]
}

final class RemoteHistoryStore {
    static let shared = RemoteHistoryStore()

    private let relativePath = ".studio/sync/history.json"
    private let limit = 10

    func entries(projectRoot: URL) -> [RemoteHistoryEntry] {
        guard let text = try? ProjectStorage.read(base: projectRoot, path: relativePath),
              let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RemoteHistoryEntry].self, from: data)) ?? []
    }

    func append(projectRoot: URL, entry: RemoteHistoryEntry) {
        var list = entries(projectRoot: projectRoot)
        list.append(entry)
        if list.count > limit { list.removeFirst(list.count - limit) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? ProjectStorage.write(base: projectRoot, path: relativePath, data: data)
    }
}

/// Reclaims space by deleting content-addressed blobs no history entry
/// references (regenerable caches are already excluded from sync entirely).
enum RemoteStorageGC {
    @discardableResult
    static func pruneBlobs() -> Int {
        let root = ProjectStore.defaultRoot
        let blobs = root.appendingPathComponent(".studio/sync/blobs", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobs.path) else { return 0 }

        var referenced = Set<String>()
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            for entry in RemoteHistoryStore.shared.entries(projectRoot: project) {
                for (_, hash) in entry.files {
                    referenced.insert(hash.replacingOccurrences(of: "blake3:", with: ""))
                }
            }
        }

        var removed = 0
        for name in names where !referenced.contains(name) {
            if (try? FileManager.default.removeItem(at: blobs.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }
}

// MARK: - Client (iPad) sync engine

final class RemoteClientSyncEngine: ObservableObject {
    static let shared = RemoteClientSyncEngine()

    @Published private(set) var isSyncing = false
    @Published private(set) var status = "Not synced"

    private let root = ProjectStore.defaultRoot
    private let queue = DispatchQueue(label: "studio.bixel.remote.sync", qos: .utility)
    private let deviceName = "ipad"

    /// Sync every project the Mac knows about, plus any local-only project.
    func syncAll() {
        guard RemoteClient.shared.state.isConnected, !isSyncing else { return }
        isSyncing = true
        status = "Syncing…"
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let remoteList = try self.requestProjects()
                var remoteByID: [String: String] = [:]
                for project in remoteList {
                    if let id = project["id"] as? String {
                        remoteByID[id] = project["name"] as? String ?? id
                    }
                }
                let localIDs = Set(self.localProjectIDs())
                var allIDs = Set(remoteByID.keys)
                allIDs.formUnion(localIDs)

                var failures = 0
                var firstError: String?
                for id in allIDs.sorted() {
                    do {
                        try self.sync(projectID: id)
                    } catch {
                        failures += 1
                        if firstError == nil { firstError = "\(id): \(error.localizedDescription)" }
                        NSLog("Bixel remote sync failed for %@: %@", id, error.localizedDescription)
                    }
                }
                DispatchQueue.main.async {
                    self.isSyncing = false
                    if failures == 0 {
                        self.status = "Synced \(allIDs.count) project\(allIDs.count == 1 ? "" : "s")"
                    } else {
                        self.status = "Sync failed — \(firstError ?? "\(failures) project(s)")"
                    }
                    NotificationCenter.default.post(name: .bixelRemoteSyncCompleted, object: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    // MARK: Sync one project

    private func sync(projectID id: String) throws {
        let projectRoot = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let local = try ProjectSync.manifest(projectRoot: projectRoot, projectID: id)
        let remote = try requestManifest(projectID: id)
        let base = readBase(projectRoot: projectRoot)
        let plan = try ProjectSync.plan(base: base, local: local, remote: remote)

        // Snapshot the previous content of anything this sync overwrites or
        // deletes so it can be restored from the bounded history.
        var preserved: [String: String] = [:]
        func preserve(_ path: String) {
            guard preserved[path] == nil,
                  let data = try? ProjectStorage.readBytes(base: projectRoot, path: path),
                  let hash = try? ProjectSync.storeBlob(projectsRoot: root, data: data) else { return }
            preserved[path] = hash
        }

        // Pull changed/new files from the Mac.
        for path in plan.pull {
            preserve(path)
            guard let data = try fetchFile(projectID: id, path: path) else { continue }
            try ProjectStorage.write(base: projectRoot, path: path, data: data)
        }
        // Push local changes to the Mac.
        for path in plan.push {
            guard let data = try ProjectStorage.readBytes(base: projectRoot, path: path) else { continue }
            try pushFile(projectID: id, path: path, data: data)
        }
        // Propagate deletes.
        for path in plan.deleteLocal {
            preserve(path)
            let target = projectRoot.appendingPathComponent(path).standardizedFileURL
            if target.path.hasPrefix(projectRoot.standardizedFileURL.path),
               FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
        }
        for path in plan.deleteRemote {
            try deleteRemote(projectID: id, path: path)
        }
        // Conflicts: keep both. Preserve the local copy under a conflict name,
        // then take the Mac's version as primary and mirror the copy back.
        for conflict in plan.conflicts {
            let conflictPath = ProjectSync.conflictName(path: conflict.path, device: deviceName)
            let localData = try ProjectStorage.readBytes(base: projectRoot, path: conflict.path)
            if let localData {
                try ProjectStorage.write(base: projectRoot, path: conflictPath, data: localData)
            }
            if conflict.remoteHash != nil, let remoteData = try fetchFile(projectID: id, path: conflict.path) {
                preserve(conflict.path)
                try ProjectStorage.write(base: projectRoot, path: conflict.path, data: remoteData)
            }
            if let localData, conflict.remoteHash != nil {
                try pushFile(projectID: id, path: conflictPath, data: localData)
            }
            if let localData, conflict.remoteHash == nil {
                // Mac deleted it; local wins to avoid losing work.
                try pushFile(projectID: id, path: conflict.path, data: localData)
            }
        }

        // Commit the merged manifest to both sides and remember it as the base.
        var merged = try ProjectSync.manifest(projectRoot: projectRoot, projectID: id)
        merged.revision = max(local.revision, remote.revision) + 1
        merged.device = deviceName
        try ProjectSync.writeManifest(projectRoot: projectRoot, manifest: merged)
        try commit(projectID: id, manifest: merged)
        writeBase(projectRoot: projectRoot, manifest: merged)

        if !preserved.isEmpty {
            RemoteHistoryStore.shared.append(projectRoot: projectRoot, entry: RemoteHistoryEntry(
                revision: merged.revision,
                timestamp: UInt64(Date().timeIntervalSince1970),
                device: deviceName,
                files: preserved
            ))
        }
    }

    // MARK: Helpers

    private func localProjectIDs() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  FileManager.default.fileExists(atPath: entry.appendingPathComponent("project.json").path) else { return nil }
            return entry.lastPathComponent
        }
    }

    private func request(_ type: String, _ payload: [String: Any]) throws -> RemoteMessage {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<RemoteMessage, Error>?
        RemoteRequestBroker.shared.send(type: type, payload: payload, timeout: 30) { value in
            result = value
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            throw RemoteError.disconnected("The Mac did not respond.")
        }
        return try (result ?? .failure(RemoteError.disconnected("No response"))).get()
    }

    private func requestProjects() throws -> [[String: Any]] {
        let reply = try request(RemoteSyncType.list, [:])
        return reply.payload["projects"] as? [[String: Any]] ?? []
    }

    private func requestManifest(projectID: String) throws -> ProjectSync.Manifest {
        let reply = try request(RemoteSyncType.manifest, ["projectId": projectID])
        guard let object = reply.payload["manifest"],
              let manifest = RemoteJSON.decode(ProjectSync.Manifest.self, object) else {
            throw RemoteError.protocolViolation("missing manifest")
        }
        return manifest
    }

    private func fetchFile(projectID: String, path: String) throws -> Data? {
        let reply = try request(RemoteSyncType.fetch, ["projectId": projectID, "path": path])
        if reply.payload["missing"] as? Bool == true { return nil }
        guard let base64 = reply.payload["data"] as? String else { return nil }
        return Data(base64Encoded: base64)
    }

    private func pushFile(projectID: String, path: String, data: Data) throws {
        _ = try request(RemoteSyncType.push, ["projectId": projectID, "path": path, "data": data.base64EncodedString()])
    }

    private func deleteRemote(projectID: String, path: String) throws {
        _ = try request(RemoteSyncType.delete, ["projectId": projectID, "path": path])
    }

    private func commit(projectID: String, manifest: ProjectSync.Manifest) throws {
        guard let object = RemoteJSON.object(manifest) else { return }
        _ = try request(RemoteSyncType.commit, ["projectId": projectID, "manifest": object])
    }

    private let basePath = ".studio/sync/base.json"

    private func readBase(projectRoot: URL) -> ProjectSync.Manifest? {
        guard let text = try? ProjectStorage.read(base: projectRoot, path: basePath),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProjectSync.Manifest.self, from: data)
    }

    private func writeBase(projectRoot: URL, manifest: ProjectSync.Manifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? ProjectStorage.write(base: projectRoot, path: basePath, data: data)
    }
}
