// BridgeClient.swift
// WebSocket client — HMAC-SHA256 handshake, reconnect loop,
// heartbeat, RPM data streaming, and local BLE frame injection.

import Foundation
import Combine

// MARK: - Connection State

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)

    var isActive: Bool {
        if case .connected = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .disconnected:          return "Disconnected"
        case .connecting:            return "Connecting..."
        case .authenticating:        return "Authenticating..."
        case .connected:             return "Connected"
        case .reconnecting(let n):   return "Reconnecting (attempt \(n))..."
        case .failed(let r):         return "Failed: \(r)"
        }
    }
}

// MARK: - BridgeClient

@MainActor
final class BridgeClient: NSObject, ObservableObject {

    // ── Published state ────────────────────────────────────────────────────
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastError:       String?          = nil
    @Published private(set) var isAuthenticated: Bool             = false

    // ── Streams ────────────────────────────────────────────────────────────
    let rpmDataSubject = PassthroughSubject<[String: Any], Never>()
    let alertSubject   = PassthroughSubject<RPMAlert, Never>()

    // ── Internal ───────────────────────────────────────────────────────────
    private let cfg:             AppConfiguration = .shared
    private let keychainService: KeychainService
    private let security:        HMACSecurityManager

    private var webSocketTask:   URLSessionWebSocketTask?
    private var urlSession:      URLSession?
    private var heartbeatTask:   Task<Void, Never>?
    private var receiveTask:     Task<Void, Never>?
    private var reconnectTask:   Task<Void, Never>?

    private var jwtToken:         String?
    private var reconnectAttempt  = 0

    // MARK: - Init

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
        self.security        = HMACSecurityManager(keychainService: keychainService)
        super.init()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = cfg.requestTimeoutSeconds
        config.timeoutIntervalForResource = 0
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Lifecycle

    func connect() {
        guard connectionState == .disconnected else { return }
        guard security.isProvisioned else {
            lastError = "HMAC secret not provisioned"
            connectionState = .failed(reason: lastError!)
            return
        }
        reconnectTask = Task { await connectionLoop() }
    }

    func disconnect() {
        reconnectTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        connectionState = .disconnected
        isAuthenticated = false
        jwtToken        = nil
    }

    // MARK: - Local BLE Frame Injection
    // Called by DevicePairingService to push BLE readings through
    // the same pipeline as hardware IoMT devices.

    func injectLocalFrame(_ frame: [String: Any]) {
        rpmDataSubject.send(frame)
    }

    // MARK: - Connection Loop

    private func connectionLoop() async {
        reconnectAttempt = 0
        while !Task.isCancelled {
            connectionState = reconnectAttempt == 0 ? .connecting
                                                     : .reconnecting(attempt: reconnectAttempt)
            do {
                try await runSession()
                break
            } catch {
                reconnectAttempt += 1
                if reconnectAttempt >= cfg.reconnectMaxAttempts {
                    connectionState = .failed(reason: "Max reconnect attempts reached")
                    break
                }
                let delay = cfg.reconnectBaseDelaySec * pow(2.0, Double(reconnectAttempt - 1))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: - Session

    private func runSession() async throws {
        guard let urlSession else { return }
        var request = URLRequest(url: cfg.backendWSURL)
        request.timeoutInterval = cfg.requestTimeoutSeconds
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        try await performHandshake(task: task)
        connectionState = .connected
        isAuthenticated = true
        lastError       = nil
        heartbeatTask   = Task { await heartbeatLoop(task: task) }
        receiveTask     = Task { await receiveLoop(task: task) }
        await receiveTask?.value
    }

    // MARK: - 3-Way HMAC Handshake

    private func performHandshake(task: URLSessionWebSocketTask) async throws {
        connectionState = .authenticating

        // Step 1 — HELLO
        try await send(WireMessage.buildJSON(
            type:     .hello,
            payload:  ["client_id": cfg.clientID, "version": "1.0"],
            senderID: cfg.clientID
        ), task: task)

        // Step 2 — CHALLENGE
        let challengeMsg = try await receive(task: task, timeout: 10)
        guard challengeMsg["type"] as? String == MsgType.challenge.rawValue,
              let payload   = challengeMsg["payload"] as? [String: Any],
              let challenge = payload["challenge"] as? String
        else { throw ProtocolError.unexpectedMessageType(challengeMsg["type"] as? String ?? "?") }

        // Step 3 — CHALLENGE_RESP
        let signature = try security.signChallenge(challenge)
        try await send(WireMessage.buildJSON(
            type:     .challengeResp,
            payload:  ["challenge": challenge, "signature": signature],
            senderID: cfg.clientID
        ), task: task)

        // Step 4 — AUTH_OK
        let authMsg = try await receive(task: task, timeout: 10)
        if authMsg["type"] as? String == MsgType.authFail.rawValue {
            throw ProtocolError.authenticationFailed("Rejected by server")
        }
        guard authMsg["type"] as? String == MsgType.authOK.rawValue else {
            throw ProtocolError.unexpectedMessageType(authMsg["type"] as? String ?? "?")
        }
        if let p = authMsg["payload"] as? [String: Any], let token = p["token"] as? String {
            jwtToken = token
            try? keychainService.save(token, for: .jwtToken)
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let t): handleText(t)
                case .data(let d):   if let t = String(data: d, encoding: .utf8) { handleText(t) }
                @unknown default:    break
                }
            } catch {
                if !Task.isCancelled {
                    connectionState = .disconnected
                    isAuthenticated = false
                }
                return
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data   = text.data(using: .utf8),
              let dict   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeStr = dict["type"] as? String,
              let msgType = MsgType(rawValue: typeStr)
        else { return }

        switch msgType {
        case .rpmData:
            if let payload = dict["payload"] as? [String: Any] {
                rpmDataSubject.send(payload)
                sendRPMAck(msgID: dict["msg_id"] as? String ?? "", task: webSocketTask)
            }
        case .heartbeat:
            sendHeartbeatAck(task: webSocketTask)
        case .disconnect:
            disconnect()
        case .error:
            let reason = (dict["payload"] as? [String: Any])?["message"] as? String ?? "Server error"
            lastError = reason
        default:
            break
        }
    }

    // MARK: - Heartbeat Loop

    private func heartbeatLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(cfg.heartbeatIntervalSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { break }
            sendHeartbeatAck(task: task)
        }
    }

    // MARK: - Helpers

    private func send(_ json: String, task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(json))
    }

    private func receive(task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProtocolError.connectionTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
        @unknown default:    text = ""
        }
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ProtocolError.deserializationFailed(text) }
        return dict
    }

    private func sendHeartbeatAck(task: URLSessionWebSocketTask?) {
        guard let task, let json = try? WireMessage.buildJSON(
            type: .heartbeatAck,
            payload: ["ts": ISO8601DateFormatter().string(from: Date())],
            senderID: cfg.clientID
        ) else { return }
        task.send(.string(json)) { _ in }
    }

    private func sendRPMAck(msgID: String, task: URLSessionWebSocketTask?) {
        guard let task, let json = try? WireMessage.buildJSON(
            type: .rpmAck,
            payload: ["msg_id": msgID],
            senderID: cfg.clientID
        ) else { return }
        task.send(.string(json)) { _ in }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension BridgeClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) { }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            self.connectionState = .disconnected
            self.isAuthenticated = false
        }
    }
}
