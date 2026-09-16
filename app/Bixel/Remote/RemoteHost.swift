// RemoteHost.swift
//
// The Mac side of Bixel Remote: advertises a Bonjour service, runs the pairing
// handshake, and keeps encrypted sessions to paired iPads. This phase exposes
// the transport and a `ping`/`pong` + `status` exchange; later phases attach the
// AI bridge and project sync to `onMessage`.

import Foundation
import Network
import CryptoKit

/// LAN address helper used to embed a reachable host in the QR code (Bonjour
/// still works, but a direct address survives mDNS hiccups).
enum RemoteNetwork {
    static func localIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer {
            let family = interface.pointee.ifa_addr?.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if let addr = interface.pointee.ifa_addr,
                       getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                        if name == "en0" { break }
                    }
                }
            }
            pointer = interface.pointee.ifa_next
        }
        return address
    }

    static func deviceName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}

/// An accepted, secured peer connection on the host.
final class RemoteSession {
    let id: String
    let name: String
    fileprivate let wire: RemoteWire

    init(id: String, name: String, wire: RemoteWire) {
        self.id = id
        self.name = name
        self.wire = wire
    }

    func send(_ message: RemoteMessage) throws {
        try wire.send(message)
    }

    func close() {
        wire.close()
    }
}

/// The Mac host. Publish from the main queue so SwiftUI can observe it.
final class RemoteHost: ObservableObject {
    static let shared = RemoteHost()

    static let remoteEnabledKey = "bixel.remoteAccessEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.remoteEnabledKey)
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    @Published private(set) var isAdvertising = false
    @Published private(set) var status: String
    @Published private(set) var pairingOffer: RemotePairingOffer?
    @Published private(set) var pairingSecondsRemaining = 0
    @Published private(set) var peers: [String] = []

    /// Delivered on the host queue for every secured inbound message.
    var onMessage: ((RemoteMessage, RemoteSession) -> Void)?

    private let identity = RemoteIdentity.loadOrCreate()
    private let queue = DispatchQueue(label: "studio.bixel.remote.host")
    private var listener: NWListener?
    private var trust = RemoteTrustStore(account: "trust.host")
    private var sessions: [String: RemoteSession] = [:]
    private var pairingToken: Data?
    private var pairingDeadline: Date?
    private var pairingTimer: Timer?

    static let pairingTTL: TimeInterval = 120

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.remoteEnabledKey)
        self.isEnabled = enabled
        self.status = enabled ? "Starting…" : "Remote access is turned off"
        if enabled {
            start()
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: RemoteNetwork.deviceName(), type: RemoteProtocol.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self.isAdvertising = true
                        self.status = "Ready to pair"
                    }
                case .failed(let error):
                    DispatchQueue.main.async {
                        self.isAdvertising = false
                        self.status = "Sharing failed: \(error.localizedDescription)"
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DispatchQueue.main.async { self.status = "Sharing failed: \(error.localizedDescription)" }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endPairing()
        sessions.values.forEach { $0.close() }
        sessions.removeAll()
        DispatchQueue.main.async {
            self.isAdvertising = false
            self.status = self.isEnabled ? "Not sharing" : "Remote access is turned off"
            self.peers = []
        }
    }

    /// Begin a time-limited pairing window and publish the QR offer.
    func beginPairing() {
        if !isEnabled {
            isEnabled = true
        } else {
            start()
        }
        pairingToken = RemoteHandshake.randomToken()
        pairingDeadline = Date().addingTimeInterval(Self.pairingTTL)
        refreshPairingOffer()
        DispatchQueue.main.async {
            self.pairingTimer?.invalidate()
            self.pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tickPairing()
            }
            self.tickPairing()
        }
    }

    func endPairing() {
        pairingToken = nil
        pairingDeadline = nil
        DispatchQueue.main.async {
            self.pairingTimer?.invalidate()
            self.pairingTimer = nil
            self.pairingOffer = nil
            self.pairingSecondsRemaining = 0
        }
    }

    private func tickPairing() {
        guard let deadline = pairingDeadline else { return }
        let remaining = Int(deadline.timeIntervalSinceNow.rounded(.up))
        if remaining <= 0 {
            endPairing()
            status = "Pairing code expired"
            return
        }
        pairingSecondsRemaining = remaining
        refreshPairingOffer()
    }

    private func refreshPairingOffer() {
        guard let token = pairingToken, let deadline = pairingDeadline,
              let port = listener?.port?.rawValue, let host = RemoteNetwork.localIPv4() else { return }
        let offer = RemotePairingOffer(
            name: RemoteNetwork.deviceName(),
            host: host,
            port: port,
            hostKey: identity.publicKey.base64EncodedString(),
            token: token.base64EncodedString(),
            expiry: UInt64(deadline.timeIntervalSince1970)
        )
        DispatchQueue.main.async { self.pairingOffer = offer }
    }

    func forget(_ peerID: String) {
        trust.remove(id: peerID)
        if let session = sessions[peerID] {
            session.close()
            sessions.removeValue(forKey: peerID)
        }
        DispatchQueue.main.async { self.peers = self.trust.peers.map(\.name) }
    }

    // MARK: - Connection + handshake

    private func accept(_ connection: NWConnection) {
        let wire = RemoteWire(connection: connection, queue: queue)
        var pending: PendingPair?

        wire.onFrame = { [weak self] data in
            guard let self, let message = try? RemoteMessage.decode(data) else { return }
            switch message.type {
            case RemoteMessageType.hello:
                pending = self.handleHello(message, wire: wire)
            case RemoteMessageType.confirm:
                pending = self.handleConfirm(message, pending: pending, wire: wire) ?? pending
            default:
                wire.close()
            }
        }
        wire.onMessage = { [weak self] message in
            guard let self, let session = pending?.session else { return }
            self.onMessage?(message, session)
        }
        wire.onClosed = { [weak self] _ in
            guard let self else { return }
            if let id = pending?.session?.id {
                self.sessions.removeValue(forKey: id)
                DispatchQueue.main.async { self.peers = self.sessions.values.map(\.name) }
            }
        }
        wire.start()
    }

    private struct PendingPair {
        var clientStatic: Data
        var clientEphemeral: Data
        var hostEphemeral: Curve25519.KeyAgreement.PrivateKey
        var salt: Data
        var transcript: Data
        var clientKey: SymmetricKey
        var hostKey: SymmetricKey
        var psk: Data
        var name: String
        var isNewPairing: Bool
        var session: RemoteSession?
    }

    private func handleHello(_ message: RemoteMessage, wire: RemoteWire) -> PendingPair? {
        guard let clientStaticText = message.payload["clientStatic"] as? String,
              let clientEphemeralText = message.payload["clientEphemeral"] as? String,
              let clientStatic = Data(base64Encoded: clientStaticText),
              let clientEphemeral = Data(base64Encoded: clientEphemeralText) else {
            wire.close()
            return nil
        }

        // Prefer an active pairing token; otherwise require a previously paired
        // client with a stored PSK.
        let activeToken = pairingToken
        let isNewPairing = activeToken != nil
        let salt: Data
        if let activeToken {
            salt = activeToken
        } else if let peer = trust.peer(id: clientStatic), let psk = Data(base64Encoded: peer.psk) {
            salt = psk
        } else {
            wire.close()
            DispatchQueue.main.async { self.status = "Rejected an unpaired device" }
            return nil
        }

        let hostEphemeral = Curve25519.KeyAgreement.PrivateKey()
        do {
            let dh1 = try RemoteHandshake.dh(identity.privateKey, clientEphemeral)
            let dh2 = try RemoteHandshake.dh(hostEphemeral, clientStatic)
            let dh3 = try RemoteHandshake.dh(hostEphemeral, clientEphemeral)
            let dh4 = try RemoteHandshake.dh(identity.privateKey, clientStatic)
            let transcript = RemoteHandshake.transcript(
                clientStatic: clientStatic,
                clientEphemeral: clientEphemeral,
                hostStatic: identity.publicKey,
                hostEphemeral: hostEphemeral.publicKey.rawRepresentation
            )
            let keys = RemoteHandshake.deriveKeys(sharedSecrets: [dh1, dh2, dh3, dh4], salt: salt, transcript: transcript)
            let hostAuth = RemoteHandshake.authTag(role: "host", salt: salt, transcript: transcript)
            let challenge = RemoteMessage(type: RemoteMessageType.challenge, replyTo: message.id, payload: [
                "hostStatic": identity.publicKey.base64EncodedString(),
                "hostEphemeral": hostEphemeral.publicKey.rawRepresentation.base64EncodedString(),
                "auth": hostAuth.base64EncodedString(),
            ])
            wire.sendRaw(try challenge.encoded())
            return PendingPair(
                clientStatic: clientStatic,
                clientEphemeral: clientEphemeral,
                hostEphemeral: hostEphemeral,
                salt: salt,
                transcript: transcript,
                clientKey: keys.client,
                hostKey: keys.host,
                psk: keys.psk,
                name: (message.payload["name"] as? String) ?? "iPad",
                isNewPairing: isNewPairing,
                session: nil
            )
        } catch {
            wire.close()
            return nil
        }
    }

    private func handleConfirm(_ message: RemoteMessage, pending: PendingPair?, wire: RemoteWire) -> PendingPair? {
        guard var pending, let authText = message.payload["auth"] as? String,
              let auth = Data(base64Encoded: authText) else {
            wire.close()
            return nil
        }
        let expected = RemoteHandshake.authTag(role: "client", salt: pending.salt, transcript: pending.transcript)
        guard RemoteHandshake.constantTimeEquals(auth, expected) else {
            wire.close()
            DispatchQueue.main.async { self.status = "Pairing code did not match" }
            return nil
        }

        // Trust on first pair; refresh metadata on reconnect.
        trust.upsert(RemoteTrustStore.Peer(
            id: pending.clientStatic.base64EncodedString(),
            name: pending.name,
            psk: pending.psk.base64EncodedString(),
            host: nil,
            port: nil
        ))
        if pending.isNewPairing {
            endPairing()
        }

        wire.activate(sendKey: pending.hostKey, receiveKey: pending.clientKey)
        let session = RemoteSession(id: pending.clientStatic.base64EncodedString(), name: pending.name, wire: wire)
        pending.session = session
        sessions[session.id] = session
        DispatchQueue.main.async {
            self.peers = self.sessions.values.map(\.name)
            self.status = "\(self.sessions.count) device\(self.sessions.count == 1 ? "" : "s") connected"
        }
        // Greet the client so it can move to `.connected`.
        try? wire.send(RemoteMessage(type: RemoteMessageType.welcome, payload: [
            "name": RemoteNetwork.deviceName(),
            "protocol": RemoteProtocol.version,
        ]))
        return pending
    }
}

/// Message type strings shared by both ends.
enum RemoteMessageType {
    static let hello = "hello"
    static let challenge = "challenge"
    static let confirm = "confirm"
    static let welcome = "welcome"
    static let ping = "ping"
    static let pong = "pong"
    static let rejected = "rejected"
}
