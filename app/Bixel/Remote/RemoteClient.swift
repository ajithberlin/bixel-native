// RemoteClient.swift
//
// The iPad side of Bixel Remote: connects to a Mac either by scanning its
// pairing QR or by reconnecting to a trusted Mac, runs the handshake, and
// keeps an encrypted session. Later phases route AI and sync over `send`.

import Foundation
import Network
import CryptoKit

final class RemoteClient: ObservableObject {
    static let shared = RemoteClient()

    enum State: Equatable {
        case idle
        case connecting
        case connected(name: String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }
        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected(let name): return "Connected to \(name)"
            case .failed(let text): return text
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var trustedHosts: [RemoteTrustStore.Peer] = []

    /// Secured inbound messages (delivered on the client queue).
    var onMessage: ((RemoteMessage) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let identity = RemoteIdentity.loadOrCreate()
    private let queue = DispatchQueue(label: "studio.bixel.remote.client")
    private var trust = RemoteTrustStore(account: "trust.client")
    private var wire: RemoteWire?
    private var pending: Pending?
    private var reconnectTarget: (host: String, port: UInt16)?
    private var lastPeer: RemoteTrustStore.Peer?
    private var manualDisconnect = false
    private var reconnectWork: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var lastPong = Date()

    private struct Pending {
        var expectedHostStatic: Data
        var hostStatic: Data
        var clientEphemeral: Curve25519.KeyAgreement.PrivateKey
        var salt: Data
        var transcript: Data
        var clientKey: SymmetricKey
        var hostKey: SymmetricKey
        var psk: Data
        var name: String
        var isNewPairing: Bool
        var host: String
        var port: UInt16
    }

    init() {
        trustedHosts = trust.peers
        lastPeer = trust.peers.last
    }

    // MARK: - Public entry points

    /// Pair with a Mac using a scanned QR offer.
    func pair(offer: RemotePairingOffer) {
        guard !offer.isExpired else {
            update(.failed(RemoteError.pairingExpired.localizedDescription))
            return
        }
        guard let hostKey = Data(base64Encoded: offer.hostKey),
              let token = Data(base64Encoded: offer.token) else {
            update(.failed(RemoteError.protocolViolation("invalid pairing code").localizedDescription))
            return
        }
        connect(host: offer.host, port: offer.port, hostStatic: hostKey, salt: token,
                name: offer.name, isNewPairing: true)
    }

    /// Reconnect to a previously paired Mac without a QR code.
    func reconnect(to peer: RemoteTrustStore.Peer) {
        guard let host = peer.host, let port = peer.port,
              let hostKey = Data(base64Encoded: peer.id),
              let psk = Data(base64Encoded: peer.psk) else {
            update(.failed(RemoteError.notTrusted("missing saved address").localizedDescription))
            return
        }
        connect(host: host, port: port, hostStatic: hostKey, salt: psk,
                name: peer.name, isNewPairing: false)
    }

    func disconnect() {
        manualDisconnect = true
        reconnectWork?.cancel()
        reconnectWork = nil
        wire?.close()
        wire = nil
        pending = nil
        reconnectTarget = nil
        update(.idle)
    }

    /// Re-establish the last trusted Mac after a drop or app foreground.
    func reconnectIfNeeded() {
        guard !manualDisconnect, !state.isConnected else { return }
        if case .connecting = state { return }
        if let peer = lastPeer { reconnect(to: peer) }
    }

    func forget(_ peer: RemoteTrustStore.Peer) {
        trust.remove(id: peer.id)
        trustedHosts = trust.peers
    }

    func send(_ message: RemoteMessage) throws {
        guard let wire, case .connected = state else {
            throw RemoteError.disconnected("Not connected to a Mac.")
        }
        try wire.send(message)
    }

    // MARK: - Connection

    private func connect(host: String, port: UInt16, hostStatic: Data, salt: Data,
                         name: String, isNewPairing: Bool) {
        manualDisconnect = false
        reconnectWork?.cancel()
        reconnectWork = nil
        wire?.onClosed = nil
        wire?.close()
        wire = nil
        update(.connecting)
        reconnectTarget = (host, port)

        let clientEphemeral = Curve25519.KeyAgreement.PrivateKey()
        pending = Pending(
            expectedHostStatic: hostStatic,
            hostStatic: hostStatic,
            clientEphemeral: clientEphemeral,
            salt: salt,
            transcript: Data(),
            clientKey: SymmetricKey(size: .bits256),
            hostKey: SymmetricKey(size: .bits256),
            psk: Data(),
            name: name,
            isNewPairing: isNewPairing,
            host: host,
            port: port
        )

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            update(.failed("Invalid port"))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let wire = RemoteWire(connection: connection, queue: queue)
        self.wire = wire

        wire.onReady = { [weak self] in self?.sendHello() }
        wire.onFrame = { [weak self] data in self?.handleHandshakeFrame(data) }
        wire.onMessage = { [weak self] message in
            guard let self else { return }
            if message.type == RemoteMessageType.pong {
                self.lastPong = Date()
                return
            }
            self.onMessage?(message)
        }
        wire.onClosed = { [weak self] error in
            guard let self else { return }
            let wasConnected = { if case .connected = self.state { return true }; return false }()
            if self.manualDisconnect {
                self.update(.idle)
            } else if wasConnected {
                // Seamless recovery: the socket dropped, so retry the last Mac.
                self.update(.connecting)
                self.scheduleReconnect()
            } else if let error {
                self.update(.failed(error.localizedDescription))
            } else {
                self.update(.idle)
            }
        }
        wire.start()
    }

    private func scheduleReconnect() {
        guard let peer = lastPeer else { update(.idle); return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconnect(to: peer) }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func sendHello() {
        guard let wire, let pending else { return }
        let hello = RemoteMessage(type: RemoteMessageType.hello, payload: [
            "clientStatic": identity.publicKey.base64EncodedString(),
            "clientEphemeral": pending.clientEphemeral.publicKey.rawRepresentation.base64EncodedString(),
            "name": RemoteNetwork.deviceName(),
        ])
        wire.sendRaw((try? hello.encoded()) ?? Data())
    }

    private func handleHandshakeFrame(_ data: Data) {
        guard let message = try? RemoteMessage.decode(data), let wire, var pending else { return }
        switch message.type {
        case RemoteMessageType.challenge:
            guard let hostStaticText = message.payload["hostStatic"] as? String,
                  let hostEphemeralText = message.payload["hostEphemeral"] as? String,
                  let authText = message.payload["auth"] as? String,
                  let hostStatic = Data(base64Encoded: hostStaticText),
                  let hostEphemeral = Data(base64Encoded: hostEphemeralText),
                  let auth = Data(base64Encoded: authText) else {
                wire.close()
                update(.failed(RemoteError.protocolViolation("bad challenge").localizedDescription))
                return
            }
            guard RemoteHandshake.constantTimeEquals(hostStatic, pending.expectedHostStatic) else {
                wire.close()
                update(.failed(RemoteError.crypto("the Mac's identity changed").localizedDescription))
                return
            }
            do {
                let dh1 = try RemoteHandshake.dh(pending.clientEphemeral, hostStatic)
                let dh2 = try RemoteHandshake.dh(identity.privateKey, hostEphemeral)
                let dh3 = try RemoteHandshake.dh(pending.clientEphemeral, hostEphemeral)
                let dh4 = try RemoteHandshake.dh(identity.privateKey, hostStatic)
                let transcript = RemoteHandshake.transcript(
                    clientStatic: identity.publicKey,
                    clientEphemeral: pending.clientEphemeral.publicKey.rawRepresentation,
                    hostStatic: hostStatic,
                    hostEphemeral: hostEphemeral
                )
                let keys = RemoteHandshake.deriveKeys(sharedSecrets: [dh1, dh2, dh3, dh4], salt: pending.salt, transcript: transcript)
                let expectedHostAuth = RemoteHandshake.authTag(role: "host", salt: pending.salt, transcript: transcript)
                guard RemoteHandshake.constantTimeEquals(auth, expectedHostAuth) else {
                    wire.close()
                    update(.failed(RemoteError.pairingExpired.localizedDescription))
                    return
                }
                pending.hostStatic = hostStatic
                pending.transcript = transcript
                pending.clientKey = keys.client
                pending.hostKey = keys.host
                pending.psk = keys.psk
                self.pending = pending

                let clientAuth = RemoteHandshake.authTag(role: "client", salt: pending.salt, transcript: transcript)
                let confirm = RemoteMessage(type: RemoteMessageType.confirm, replyTo: message.id, payload: [
                    "auth": clientAuth.base64EncodedString(),
                ])
                wire.sendRaw(try confirm.encoded())
                wire.activate(sendKey: keys.client, receiveKey: keys.host)

                // Remember this Mac for seamless reconnects.
                let peer = RemoteTrustStore.Peer(
                    id: hostStatic.base64EncodedString(),
                    name: pending.name,
                    psk: keys.psk.base64EncodedString(),
                    host: pending.host,
                    port: pending.port
                )
                trust.upsert(peer)
                lastPeer = peer
                DispatchQueue.main.async { self.trustedHosts = self.trust.peers }
                update(.connected(name: pending.name))
            } catch {
                wire.close()
                update(.failed(error.localizedDescription))
            }
        case RemoteMessageType.rejected:
            wire.close()
            update(.failed("The Mac rejected the connection."))
        default:
            break
        }
    }

    private func update(_ next: State) {
        DispatchQueue.main.async {
            self.state = next
            if case .connected = next {
                self.startHeartbeat()
            } else {
                self.stopHeartbeat()
            }
            self.onStateChange?(next)
        }
    }

    /// Keep the link honest: a half-open socket would otherwise leave sync and
    /// chat hanging until their timeouts. A missed pong forces a reconnect.
    private func startHeartbeat() {
        stopHeartbeat()
        lastPong = Date()
        DispatchQueue.main.async {
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPong) > 36 {
                    self.update(.connecting)
                    self.scheduleReconnect()
                    return
                }
                try? self.send(RemoteMessage(type: RemoteMessageType.ping))
            }
        }
    }

    private func stopHeartbeat() {
        DispatchQueue.main.async {
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
        }
    }
}
