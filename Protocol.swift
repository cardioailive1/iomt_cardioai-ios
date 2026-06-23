// Protocol.swift
// Wire protocol types — must stay in sync with MsgType enum in
// iomt_cardioai_production.py.

import Foundation

// MARK: - Message Types

enum MsgType: String, Codable {
    case hello           = "hello"
    case challenge       = "challenge"
    case challengeResp   = "challenge_resp"
    case authOK          = "auth_ok"
    case authFail        = "auth_fail"
    case heartbeat       = "heartbeat"
    case heartbeatAck    = "heartbeat_ack"
    case deviceList      = "device_list"
    case deviceListAck   = "device_list_ack"
    case subscribe       = "subscribe"
    case subscribeAck    = "subscribe_ack"
    case unsubscribe     = "unsubscribe"
    case disconnect      = "disconnect"
    case rpmData         = "rpm_data"
    case rpmAck          = "rpm_ack"
    case error           = "error"
}

// MARK: - Wire Envelope

struct WireMessage: Codable {
    let msgID:     String
    let type:      MsgType
    let senderID:  String
    let timestamp: String
    let payload:   AnyCodable

    enum CodingKeys: String, CodingKey {
        case msgID    = "msg_id"
        case type
        case senderID = "sender_id"
        case timestamp
        case payload
    }

    static func build(
        type:      MsgType,
        payload:   [String: Any],
        senderID:  String
    ) -> [String: Any] {
        [
            "msg_id":    UUID().uuidString,
            "type":      type.rawValue,
            "sender_id": senderID,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "payload":   payload,
        ]
    }

    static func buildJSON(
        type:     MsgType,
        payload:  [String: Any],
        senderID: String
    ) throws -> String {
        let dict = build(type: type, payload: payload, senderID: senderID)
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProtocolError.serializationFailed
        }
        return json
    }
}

// MARK: - Protocol Errors

enum ProtocolError: LocalizedError {
    case serializationFailed
    case deserializationFailed(String)
    case unexpectedMessageType(String)
    case authenticationFailed(String)
    case connectionTimeout

    var errorDescription: String? {
        switch self {
        case .serializationFailed:          return "Failed to serialize message"
        case .deserializationFailed(let m): return "Failed to deserialize: \(m)"
        case .unexpectedMessageType(let t): return "Unexpected message type: \(t)"
        case .authenticationFailed(let r):  return "Auth failed: \(r)"
        case .connectionTimeout:            return "Connection timed out"
        }
    }
}

// MARK: - AnyCodable helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let d as [String: Any]:
            try container.encode(d.mapValues { AnyCodable($0) })
        case let a as [Any]:
            try container.encode(a.map { AnyCodable($0) })
        case let s as String:  try container.encode(s)
        case let n as Double:  try container.encode(n)
        case let b as Bool:    try container.encode(b)
        default: try container.encodeNil()
        }
    }
}
