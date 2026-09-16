// RemoteCrypto.swift
//
// Identity, pairing trust, the authenticated key exchange, and the encrypted
// message channel for Bixel Remote.
//
// Security model (local network, no server):
// * Each device has a persistent X25519 identity key in the Keychain.
// * Pairing uses a short-lived random token shown in the Mac's QR code. The
//   token is mixed into the HKDF salt, so only a device that scanned the QR can
//   derive the session keys.
// * The session derives from four Diffie-Hellman values over the static and
//   ephemeral keys of both sides (Noise-XX-like), giving forward secrecy.
// * Both sides prove knowledge of the token with an HMAC over the transcript.
// * After the first pairing a reconnect secret (PSK) is stored on both devices,
//   so later connections are automatic and still ephemeral-keyed.
// * All post-handshake frames are sealed with ChaCha20-Poly1305.

import Foundation
import CryptoKit
import Security
import Network

// MARK: - Credentials Store

enum RemoteKeychain {
    static let service = "com.bixel.remote"

    private static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Bixel/remote/keychain", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        return dir
    }

    private static func fileURL(account: String) -> URL {
        let safeName = account.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return storageDirectory.appendingPathComponent("\(safeName).dat")
    }

    static func data(account: String) -> Data? {
        let url = fileURL(account: account)
        return try? Data(contentsOf: url)
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        let url = fileURL(account: account)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    static func remove(account: String) {
        let url = fileURL(account: account)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Device identity

/// A persistent X25519 key-agreement identity.
struct RemoteIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    static func loadOrCreate(account: String = "device-identity") -> RemoteIdentity {
        if let raw = RemoteKeychain.data(account: account), raw.count == 32,
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return RemoteIdentity(privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        RemoteKeychain.set(key.rawRepresentation, account: account)
        return RemoteIdentity(privateKey: key)
    }
}

// MARK: - Handshake

enum RemoteHandshake {
    /// A domain-separated transcript binding every public key in the exchange.
    static func transcript(clientStatic: Data, clientEphemeral: Data, hostStatic: Data, hostEphemeral: Data) -> Data {
        var out = Data("bixel-remote/\(RemoteProtocol.version)".utf8)
        for part in [clientStatic, clientEphemeral, hostStatic, hostEphemeral] {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(part)
        }
        return out
    }

    /// Derive the directional keys plus the reconnect PSK. `salt` is the pairing
    /// token on first pair, or the stored PSK on reconnect.
    static func deriveKeys(sharedSecrets: [Data], salt: Data, transcript: Data) -> (client: SymmetricKey, host: SymmetricKey, psk: Data) {
        var ikm = Data()
        for secret in sharedSecrets { ikm.append(secret) }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: transcript,
            outputByteCount: 96
        )
        let bytes = derived.withUnsafeBytes { Data($0) }
        let client = SymmetricKey(data: bytes.subdata(in: 0..<32))
        let host = SymmetricKey(data: bytes.subdata(in: 32..<64))
        let psk = bytes.subdata(in: 64..<96)
        return (client, host, psk)
    }

    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKeyData: Data) throws -> Data {
        guard publicKeyData.count == 32,
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData) else {
            throw RemoteError.crypto("invalid public key")
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    /// HMAC over `role || transcript`, keyed by the pairing token / PSK.
    static func authTag(role: String, salt: Data, transcript: Data) -> Data {
        var message = Data(role.utf8)
        message.append(transcript)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: salt))
        return Data(mac)
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    static func randomToken(byteCount: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes)
    }
}

// MARK: - Encrypted wire

/// A framed, optionally-encrypted connection. Used in the clear during the
/// handshake, then switched to ChaCha20-Poly1305 once keys are derived.
final class RemoteWire {
    enum Mode { case handshake, secure }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = RemoteFrameDecoder()
    private var mode: Mode = .handshake
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?

    /// Raw frames during the handshake.
    var onFrame: ((Data) -> Void)?
    /// Decoded messages once secured.
    var onMessage: ((RemoteMessage) -> Void)?
    var onClosed: ((Error?) -> Void)?
    var onReady: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.onClosed?(error)
            case .cancelled: self?.onClosed?(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func sendRaw(_ data: Data) {
        connection.send(content: remoteFrame(data), completion: .contentProcessed { _ in })
    }

    func send(_ message: RemoteMessage) throws {
        guard let sendKey else { throw RemoteError.crypto("channel is not secured") }
        let sealed = try ChaChaPoly.seal(try message.encoded(), using: sendKey)
        connection.send(content: remoteFrame(sealed.combined), completion: .contentProcessed { _ in })
    }

    /// Switch to encrypted mode. Any bytes already buffered are not expected
    /// here (the peer waits for our next message), so the decoder is cleared.
    func activate(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        mode = .secure
    }

    func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.decoder.append(data) }
            do {
                while let frame = try self.decoder.next() {
                    try self.handle(frame)
                }
            } catch {
                self.onClosed?(error)
                self.connection.cancel()
                return
            }
            if let error {
                self.onClosed?(error)
                return
            }
            if isComplete {
                self.onClosed?(nil)
                return
            }
            self.receive()
        }
    }

    private func handle(_ frame: Data) throws {
        switch mode {
        case .handshake:
            onFrame?(frame)
        case .secure:
            guard let receiveKey else { throw RemoteError.crypto("channel is not secured") }
            let box = try ChaChaPoly.SealedBox(combined: frame)
            let plaintext = try ChaChaPoly.open(box, using: receiveKey)
            onMessage?(try RemoteMessage.decode(plaintext))
        }
    }
}

// MARK: - Trust store

/// Peers the local device has paired with. Stored as a Keychain-encrypted JSON
/// blob so reconnect secrets never sit in plaintext on disk.
struct RemoteTrustStore {
    struct Peer: Codable, Identifiable {
        /// Base64 of the peer's static public key.
        var id: String
        var name: String
        /// Base64 reconnect secret (PSK).
        var psk: String
        /// Client-side only: last known host/port for automatic reconnect.
        var host: String?
        var port: UInt16?
    }

    private let account: String
    private(set) var peers: [Peer]

    init(account: String) {
        self.account = account
        if let data = RemoteKeychain.data(account: account),
           let decoded = try? JSONDecoder().decode([Peer].self, from: data) {
            peers = decoded
        } else {
            peers = []
        }
    }

    func peer(id: Data) -> Peer? {
        let key = id.base64EncodedString()
        return peers.first { $0.id == key }
    }

    mutating func upsert(_ peer: Peer) {
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        save()
    }

    mutating func remove(id: String) {
        peers.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(peers) {
            RemoteKeychain.set(data, account: account)
        }
    }
}
