// RemoteAI.swift
//
// P1: route the assistant over the remote link. The Mac host drives the
// in-process goose agent (`bixel_ai_chat_stream`) and forwards every event; the
// iPad client sends requests and feeds the returned events into the same
// `AssistantSession` pipeline the local FFI path uses.

import Foundation

enum RemoteAIType {
    static let status = "ai.status"
    static let chat = "ai.chat"
    static let event = "ai.event"
    static let done = "ai.done"
    static let cancel = "ai.cancel"
}

// MARK: - Host (Mac)

/// Tracks one in-flight host-side agent turn so it can be cancelled.
final class RemoteAIHostRequest: @unchecked Sendable {
    let id: String
    private let session: RemoteSession
    private let lock = NSLock()
    private var cancelled = false

    init(id: String, session: RemoteSession) {
        self.id = id
        self.session = session
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// Forward one `NativeEvent` JSON to the client. Returns false to abort the
    /// agent turn (also how cancellation reaches goose).
    func forward(_ eventJSON: String) -> Bool {
        if isCancelled { return false }
        do {
            try session.send(RemoteMessage(type: RemoteAIType.event, replyTo: id, payload: ["json": eventJSON]))
        } catch {
            return false
        }
        return !isCancelled
    }

    func finish() {
        try? session.send(RemoteMessage(type: RemoteAIType.done, replyTo: id))
    }
}

/// C callback handed to `bixel_ai_chat_stream`; `context` is the request box.
func bixelRemoteAIEvent(_ pointer: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> Bool {
    guard let pointer, let context else { return false }
    let request = Unmanaged<RemoteAIHostRequest>.fromOpaque(context).takeUnretainedValue()
    return request.forward(String(cString: pointer))
}

final class RemoteHostAIBridge {
    static let shared = RemoteHostAIBridge()

    private let lock = NSLock()
    private var requests: [String: RemoteAIHostRequest] = [:]

    func handle(_ message: RemoteMessage, session: RemoteSession) {
        switch message.type {
        case RemoteAIType.status:
            guard let pointer = bixel_ai_connection_status() else { return }
            defer { bixel_string_free(pointer) }
            try? session.send(RemoteMessage(
                type: RemoteAIType.status,
                replyTo: message.id,
                payload: ["json": String(cString: pointer)]
            ))
        case RemoteAIType.chat:
            start(message, session: session)
        case RemoteAIType.cancel:
            let id = message.payload["request"] as? String ?? message.replyTo ?? ""
            lock.lock(); let request = requests[id]; lock.unlock()
            request?.cancel()
        default:
            break
        }
    }

    private func start(_ message: RemoteMessage, session: RemoteSession) {
        guard let request = message.payload["request"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return }

        let hostRequest = RemoteAIHostRequest(id: message.id, session: session)
        lock.lock(); requests[message.id] = hostRequest; lock.unlock()

        // The FFI call is blocking, so keep it off the network queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = json.withCString { pointer in
                bixel_ai_chat_stream(pointer, bixelRemoteAIEvent, Unmanaged.passUnretained(hostRequest).toOpaque())
            }
            hostRequest.finish()
            self?.lock.lock()
            self?.requests.removeValue(forKey: message.id)
            self?.lock.unlock()
        }
    }
}

// MARK: - Client (iPad)

final class RemoteClientAIBridge: ObservableObject {
    static let shared = RemoteClientAIBridge()

    @Published private(set) var status = AIService.AIConnectionStatus()

    private struct StreamSession {
        let receive: (AssistantEvent) -> Void
        let cancellation: AssistantCancellation
        let onDone: () -> Void
    }

    private let lock = NSLock()
    private var streams: [String: StreamSession] = [:]

    var isConnected: Bool { RemoteClient.shared.state.isConnected }

    func handle(_ message: RemoteMessage) {
        switch message.type {
        case RemoteAIType.status:
            guard let json = message.payload["json"] as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let decoded = AIService.decodeStatus(object)
            DispatchQueue.main.async { self.status = decoded }
        case RemoteAIType.event:
            guard let id = message.replyTo, let json = message.payload["json"] as? String else { return }
            lock.lock(); let stream = streams[id]; lock.unlock()
            guard let stream else { return }
            if stream.cancellation.isStopped {
                sendCancel(id)
                return
            }
            if let data = json.data(using: .utf8),
               let event = try? JSONDecoder().decode(AssistantEvent.self, from: data) {
                stream.receive(event)
            }
        case RemoteAIType.done:
            guard let id = message.replyTo else { return }
            lock.lock(); let stream = streams.removeValue(forKey: id); lock.unlock()
            stream?.onDone()
        default:
            break
        }
    }

    /// Ask the Mac for its current provider/model readiness.
    func refreshStatus() {
        guard isConnected else { return }
        try? RemoteClient.shared.send(RemoteMessage(type: RemoteAIType.status))
    }

    /// Run one assistant turn on the Mac. `onDone` fires when the Mac reports the
    /// turn finished (or the send fails), so callers can clear their busy state.
    func streamChat(request: [String: Any], cancellation: AssistantCancellation,
                    receive: @escaping (AssistantEvent) -> Void,
                    onDone: @escaping () -> Void) {
        let id = UUID().uuidString
        lock.lock()
        streams[id] = StreamSession(receive: receive, cancellation: cancellation, onDone: onDone)
        lock.unlock()
        do {
            try RemoteClient.shared.send(RemoteMessage(type: RemoteAIType.chat, id: id, payload: ["request": request]))
        } catch {
            lock.lock(); streams.removeValue(forKey: id); lock.unlock()
            receive(AssistantEvent(type: "error", message: error.localizedDescription))
            onDone()
        }
    }

    private func sendCancel(_ id: String) {
        try? RemoteClient.shared.send(RemoteMessage(type: RemoteAIType.cancel, payload: ["request": id]))
        lock.lock(); let stream = streams.removeValue(forKey: id); lock.unlock()
        stream?.onDone()
    }
}

// MARK: - Router installation

enum RemoteRouters {
    /// Wire the remote message streams into the per-phase handlers. Call once at
    /// launch.
    static func install() {
        #if os(macOS)
        RemoteHost.shared.onMessage = { message, session in
            if message.type.hasPrefix("ai.") {
                RemoteHostAIBridge.shared.handle(message, session: session)
            }
        }
        #else
        RemoteClient.shared.onMessage = { message in
            if message.type.hasPrefix("ai.") {
                RemoteClientAIBridge.shared.handle(message)
            }
        }
        RemoteClient.shared.onStateChange = { state in
            if state.isConnected { RemoteClientAIBridge.shared.refreshStatus() }
        }
        #endif
    }
}
