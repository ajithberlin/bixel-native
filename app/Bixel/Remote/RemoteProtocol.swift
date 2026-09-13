// RemoteProtocol.swift
//
// Wire protocol for Bixel Remote: the Mac (host) and iPad (client) exchange
// length-prefixed JSON messages over an encrypted local-network connection.
// The framing and envelope are deliberately tiny and transport-agnostic so the
// same messages can later ride a relay if needed.

import Foundation

enum RemoteProtocol {
    /// Bump on incompatible envelope/framing changes.
    static let version = 1
    /// Bonjour service type advertised by the host and browsed by clients.
    static let serviceType = "_bixel-remote._tcp"
    /// Upper bound on a single framed message (guards against bad lengths).
    static let maxFrameBytes = 64 * 1024 * 1024
}

enum RemoteError: LocalizedError, Equatable {
    case protocolViolation(String)
    case pairingExpired
    case notTrusted(String)
    case crypto(String)
    case disconnected(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .protocolViolation(let text): return "Remote protocol error: \(text)"
        case .pairingExpired: return "That pairing code has expired. Show a new code on your Mac."
        case .notTrusted(let text): return "This Mac is not paired: \(text)"
        case .crypto(let text): return "Secure channel error: \(text)"
        case .disconnected(let text): return text
        case .unsupported(let text): return text
        }
    }
}

/// One logical message. `payload` is arbitrary JSON so phases can add fields
/// without changing the envelope.
struct RemoteMessage {
    var type: String
    var id: String
    var replyTo: String?
    var payload: [String: Any]

    init(type: String, id: String = UUID().uuidString, replyTo: String? = nil, payload: [String: Any] = [:]) {
        self.type = type
        self.id = id
        self.replyTo = replyTo
        self.payload = payload
    }

    func encoded() throws -> Data {
        var object: [String: Any] = [
            "v": RemoteProtocol.version,
            "type": type,
            "id": id,
            "payload": payload,
        ]
        if let replyTo { object["replyTo"] = replyTo }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func decode(_ data: Data) throws -> RemoteMessage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw RemoteError.protocolViolation("malformed message")
        }
        return RemoteMessage(
            type: type,
            id: object["id"] as? String ?? UUID().uuidString,
            replyTo: object["replyTo"] as? String,
            payload: object["payload"] as? [String: Any] ?? [:]
        )
    }
}

/// Length-prefixed framing: a big-endian `UInt32` byte count followed by the
/// payload. Stateful because a stream may deliver partial frames.
struct RemoteFrameDecoder {
    private var buffer = Data()
    private let maxBytes: Int

    init(maxBytes: Int = RemoteProtocol.maxFrameBytes) {
        self.maxBytes = maxBytes
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame, or nil when more bytes are needed.
    mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            for byte in raw { value = (value << 8) | UInt32(byte) }
            return value
        }
        guard length <= UInt32(maxBytes) else {
            throw RemoteError.protocolViolation("frame exceeds \(maxBytes) bytes")
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let start = buffer.index(buffer.startIndex, offsetBy: 4)
        let end = buffer.index(buffer.startIndex, offsetBy: total)
        let frame = Data(buffer[start..<end])
        buffer.removeSubrange(buffer.startIndex..<end)
        return frame
    }
}

/// Frame raw bytes with the 4-byte length prefix.
func remoteFrame(_ data: Data) -> Data {
    var out = Data()
    var length = UInt32(data.count).bigEndian
    withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
    out.append(data)
    return out
}

/// A one-shot pairing offer encoded in the QR code shown by the host. The
/// token is valid for `expiry` (unix seconds) only.
struct RemotePairingOffer: Codable, Equatable {
    var name: String
    var host: String
    var port: UInt16
    /// Base64 of the host's static X25519 public key (pinned by the client).
    var hostKey: String
    /// Base64 of the one-time pairing token (also the HKDF salt).
    var token: String
    var expiry: UInt64

    var isExpired: Bool { UInt64(Date().timeIntervalSince1970) > expiry }

    /// `bixel://pair?...` URL scanned from the QR code.
    func urlString() -> String {
        var components = URLComponents()
        components.scheme = "bixel"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "key", value: hostKey),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "exp", value: String(expiry)),
        ]
        return components.url?.absoluteString ?? ""
    }

    static func parse(_ string: String) -> RemotePairingOffer? {
        guard let components = URLComponents(string: string),
              components.scheme == "bixel", components.host == "pair" else { return nil }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let name = items["name"], let host = items["host"],
              let portText = items["port"], let port = UInt16(portText),
              let key = items["key"], let token = items["token"],
              let expiryText = items["exp"], let expiry = UInt64(expiryText) else { return nil }
        return RemotePairingOffer(name: name, host: host, port: port, hostKey: key, token: token, expiry: expiry)
    }
}
