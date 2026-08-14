import Foundation
import Network

private final class ManagerieRemotePeer {
    let id = UUID()
    let connection: NWConnection
    var handshakeBuffer = Data()
    var frameBuffer = Data()
    var authenticated = false
    var audioStreamEnabled = false
    var awaitingPongCount = 0
    var idempotentAckByKey: [String: ManagerieRemoteFrame] = [:]
    var idempotentAckOrder: [String] = []

    init(connection: NWConnection) {
        self.connection = connection
    }
}

private struct ManagerieRemoteStoredEvent {
    let seq: Int64
    let frame: ManagerieRemoteFrame
}

private enum ManagerieRemoteBroadcastScope {
    case allAuthenticated
    case only(ManagerieRemotePeer)
    case audioSubscribers
}

final class ManagerieRemoteServer {
    private let config: ManagerieRemoteServerConfig
    private let queue = DispatchQueue(label: "managerie.remote.server")
    private let maxIdempotentAcksPerPeer = 256

    private var listener: NWListener?
    private var peers: [UUID: ManagerieRemotePeer] = [:]
    private var eventSeq: Int64 = 0
    private var replayLog: [ManagerieRemoteStoredEvent] = []
    private var heartbeatTimer: DispatchSourceTimer?

    private let snapshotProvider: ManagerieRemoteSnapshotProvider
    private let commandHandler: ManagerieRemoteCommandHandler

    init(
        config: ManagerieRemoteServerConfig,
        snapshotProvider: @escaping ManagerieRemoteSnapshotProvider,
        commandHandler: @escaping ManagerieRemoteCommandHandler
    ) {
        self.config = config
        self.snapshotProvider = snapshotProvider
        self.commandHandler = commandHandler
    }

    func start() throws {
        guard listener == nil else { return }

        if !config.isLoopback && !config.requiresAuth && !config.allowInsecureNoAuth {
            throw NSError(
                domain: "ManagerieRemote",
                code: 401,
                userInfo: [
                    NSLocalizedDescriptionKey: "Refusing non-loopback remote server without token auth (set MANAGERIE_REMOTE_TOKEN, or explicitly set MANAGERIE_REMOTE_ALLOW_INSECURE_NO_AUTH=1 for local dev only)",
                ]
            )
        }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
            throw NSError(
                domain: "ManagerieRemote",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid port \(config.port)"]
            )
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Use a dual-stack wildcard listener for 0.0.0.0/::/* so tailnet IPv4 clients
        // can connect reliably.
        let normalizedHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let listener: NWListener
        if normalizedHost == "0.0.0.0" || normalizedHost == "::" || normalizedHost == "*" {
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(config.host), port: nwPort)
            listener = try NWListener(using: parameters)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Managerie Remote: listening on \(self.config.host):\(self.config.port)")
            case .failed(let error):
                print("Managerie Remote: listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.accept(connection: connection)
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        startHeartbeatLoop()
    }

    func stop() {
        queue.async {
            self.stopLocked()
        }
    }

    private func stopLocked() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        peers.values.forEach { $0.connection.cancel() }
        peers.removeAll()

        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        replayLog.removeAll()
        eventSeq = 0
    }

    private func accept(connection: NWConnection) {
        let peer = ManagerieRemotePeer(connection: connection)
        peers[peer.id] = peer

        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            self.queue.async {
                switch state {
                case .failed, .cancelled:
                    self.drop(peer: peer)
                default:
                    break
                }
            }
        }

        connection.start(queue: queue)
        receiveHandshake(for: peer)
    }

    private func drop(peer: ManagerieRemotePeer) {
        peer.connection.cancel()
        peers.removeValue(forKey: peer.id)
    }

    private func receiveHandshake(for peer: ManagerieRemotePeer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            self.queue.async {
                if error != nil || isComplete {
                    self.drop(peer: peer)
                    return
                }

                if let data {
                    peer.handshakeBuffer.append(data)
                }

                guard let range = peer.handshakeBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                    self.receiveHandshake(for: peer)
                    return
                }

                let headerData = peer.handshakeBuffer.subdata(in: 0..<range.upperBound)
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    self.sendHttpFailureAndDrop(peer: peer, status: ManagerieWebSocketHandshakeError.badRequest.rawValue)
                    return
                }

                self.finishHandshake(peer: peer, rawHeaders: headerString)
            }
        }
    }

    private func finishHandshake(peer: ManagerieRemotePeer, rawHeaders: String) {
        switch ManagerieWebSocketHandshake.buildUpgradeResponse(from: rawHeaders) {
        case .failure(let error):
            sendHttpFailureAndDrop(peer: peer, status: error.rawValue)

        case .success(let response):
            peer.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self, weak peer] sendError in
                guard let self, let peer else { return }
                self.queue.async {
                    if sendError != nil {
                        self.drop(peer: peer)
                        return
                    }
                    self.sendHelloBanner(to: peer)
                    self.receiveFrames(for: peer)
                }
            })
        }
    }

    private func sendHelloBanner(to peer: ManagerieRemotePeer) {
        let payload = ManagerieRemoteServerHelloPayload(
            server: .init(name: "ManagerieRemote", version: "0.1.0"),
            requiresAuth: config.requiresAuth,
            eventSeq: eventSeq
        )

        let frame = ManagerieRemoteFrame.event(
            name: "server.hello",
            seq: eventSeq,
            payload: JSONValue.fromEncodable(payload)
        )
        send(frame: frame, to: peer)
    }

    private func sendHttpFailureAndDrop(peer: ManagerieRemotePeer, status: String) {
        let body = "{\"ok\":false,\"error\":\"\(status)\"}\n"
        let response = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "\r\n\(body)",
        ].joined(separator: "\r\n")

        peer.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            peer.connection.cancel()
        })
        peers.removeValue(forKey: peer.id)
    }

    private func receiveFrames(for peer: ManagerieRemotePeer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            self.queue.async {
                if error != nil || isComplete {
                    self.drop(peer: peer)
                    return
                }

                if let data {
                    peer.frameBuffer.append(data)
                    self.parseFrames(for: peer)
                }
                self.receiveFrames(for: peer)
            }
        }
    }

    private func parseFrames(for peer: ManagerieRemotePeer) {
        while true {
            guard let frame = ManagerieWebSocketCodec.readFrame(from: &peer.frameBuffer) else {
                return
            }

            switch frame.opcode {
            case 0x1, 0x2: // text or binary(json)
                handleIncomingDataFrame(frame.payload, from: peer)

            case 0x8: // close
                sendCloseFrame(to: peer)
                drop(peer: peer)
                return

            case 0x9: // ping
                sendTransportFrame(opcode: 0xA, payload: frame.payload, to: peer)

            case 0xA: // pong
                peer.awaitingPongCount = 0

            default:
                break
            }
        }
    }

    private func handleIncomingDataFrame(_ data: Data, from peer: ManagerieRemotePeer) {
        guard let frame = ManagerieRemoteFrame.decodeData(data) else {
            sendProtocolError(to: peer, code: "BAD_REQUEST", message: "invalid json frame")
            return
        }

        switch frame.type {
        case .ping:
            let pong = ManagerieRemoteFrame(
                type: .pong,
                name: frame.name ?? "ping",
                requestId: frame.requestId,
                idempotencyKey: nil,
                seq: nil,
                ts: managerieRemoteCurrentTimestampMs(),
                payload: frame.payload ?? .object([:])
            )
            send(frame: pong, to: peer)

        case .cmd:
            handleCommand(frame, from: peer)

        default:
            sendProtocolError(to: peer, code: "BAD_REQUEST", message: "unsupported frame type")
        }
    }

    private func handleCommand(_ frame: ManagerieRemoteFrame, from peer: ManagerieRemotePeer) {
        let name = frame.name ?? ""
        guard let requestId = frame.requestId, !requestId.isEmpty else {
            sendProtocolError(to: peer, code: "BAD_REQUEST", message: "requestId is required")
            return
        }

        if !peer.authenticated && name != "auth.hello" {
            sendError(name: name, requestId: requestId, code: "AUTH_REQUIRED", message: "authenticate with auth.hello first", to: peer)
            return
        }

        switch name {
        case "auth.hello":
            handleAuthHello(frame: frame, requestId: requestId, peer: peer)

        case "sessions.snapshot.get":
            let snapshot = snapshotProvider()
            let payload = JSONValue.fromEncodable(snapshot) ?? .object([:])
            sendAck(name: name, requestId: requestId, payload: payload, to: peer)

        case "session.sendText":
            handleSessionSendText(frame: frame, requestId: requestId, peer: peer)

        case "session.sendScreenshot":
            handleSessionSendScreenshot(frame: frame, requestId: requestId, peer: peer)

        case "tts.speak":
            handleTTSSpeak(frame: frame, requestId: requestId, peer: peer)

        case "tts.stop":
            handleTTSStop(frame: frame, requestId: requestId, peer: peer)

        case "audio.setStream":
            handleAudioSetStream(frame: frame, requestId: requestId, peer: peer)

        default:
            sendError(name: name, requestId: requestId, code: "UNKNOWN_COMMAND", message: "unknown command: \(name)", to: peer)
        }
    }

    private func handleAuthHello(frame: ManagerieRemoteFrame, requestId: String, peer: ManagerieRemotePeer) {
        let payload = frame.payload?.decode(ManagerieRemoteAuthHelloPayload.self)
        let providedToken = (payload?.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if config.requiresAuth && providedToken != config.token {
            sendError(name: "auth.hello", requestId: requestId, code: "AUTH_INVALID", message: "invalid token", to: peer)
            return
        }

        peer.authenticated = true

        let ackPayload = ManagerieRemoteAuthAckPayload(
            serverVersion: "0.1.0",
            sessionId: peer.id.uuidString,
            eventSeq: eventSeq,
            replay: .init(requestedFromSeq: payload?.resumeFromSeq)
        )
        sendAck(
            name: "auth.hello",
            requestId: requestId,
            payload: JSONValue.fromEncodable(ackPayload) ?? .object([:]),
            to: peer
        )

        if let resumeFromSeq = payload?.resumeFromSeq {
            replayEvents(from: resumeFromSeq, to: peer)
        } else {
            sendSnapshotEvent(to: peer)
        }
    }

    private func handleSessionSendText(frame: ManagerieRemoteFrame, requestId: String, peer: ManagerieRemotePeer) {
        let name = "session.sendText"
        guard let idempotencyKey = frame.idempotencyKey, !idempotencyKey.isEmpty else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
            return
        }

        if let previous = peer.idempotentAckByKey[idempotencyKey] {
            send(frame: previous, to: peer)
            return
        }

        guard
            let payload = frame.payload?.decode(ManagerieRemoteSessionSendTextPayload.self),
            !payload.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "sessionKey and text are required", to: peer)
            return
        }

        let command = ManagerieRemoteIncomingCommand.sendText(
            sessionKey: payload.sessionKey,
            text: payload.text,
            idempotencyKey: idempotencyKey
        )
        handleAsyncCommand(command, name: name, requestId: requestId, idempotencyKey: idempotencyKey, peer: peer)
    }

    private func handleSessionSendScreenshot(frame: ManagerieRemoteFrame, requestId: String, peer: ManagerieRemotePeer) {
        let name = "session.sendScreenshot"
        guard let idempotencyKey = frame.idempotencyKey, !idempotencyKey.isEmpty else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
            return
        }

        if let previous = peer.idempotentAckByKey[idempotencyKey] {
            send(frame: previous, to: peer)
            return
        }

        guard
            let payload = frame.payload?.decode(ManagerieRemoteSessionSendScreenshotPayload.self),
            !payload.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !payload.imageBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            payload.mimeType.hasPrefix("image/")
        else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "sessionKey, imageBase64, and image mimeType are required", to: peer)
            return
        }

        let command = ManagerieRemoteIncomingCommand.sendScreenshot(
            sessionKey: payload.sessionKey,
            imageBase64: payload.imageBase64,
            mimeType: payload.mimeType,
            note: payload.note,
            idempotencyKey: idempotencyKey
        )
        handleAsyncCommand(command, name: name, requestId: requestId, idempotencyKey: idempotencyKey, peer: peer)
    }

    private func handleTTSSpeak(frame: ManagerieRemoteFrame, requestId: String, peer: ManagerieRemotePeer) {
        let name = "tts.speak"
        guard let idempotencyKey = frame.idempotencyKey, !idempotencyKey.isEmpty else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
            return
        }

        if let previous = peer.idempotentAckByKey[idempotencyKey] {
            send(frame: previous, to: peer)
            return
        }

        guard let payload = frame.payload?.decode(ManagerieRemoteTTSSpeakPayload.self) else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "invalid speak payload", to: peer)
            return
        }

        guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "text is required", to: peer)
            return
        }

        let command = ManagerieRemoteIncomingCommand.speak(
            text: payload.text,
            voice: payload.voice,
            sourceApp: payload.sourceApp,
            sessionId: payload.sessionId,
            pid: payload.pid,
            idempotencyKey: idempotencyKey
        )
        handleAsyncCommand(command, name: name, requestId: requestId, idempotencyKey: idempotencyKey, peer: peer)
    }

    private func handleTTSStop(frame: ManagerieRemoteFrame, requestId: String, peer: ManagerieRemotePeer) {
        let name = "tts.stop"
        guard let idempotencyKey = frame.idempotencyKey, !idempotencyKey.isEmpty else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
            return
        }

        if let previous = peer.idempotentAckByKey[idempotencyKey] {
            send(frame: previous, to: peer)
            return
        }

        let payload = frame.payload?.decode(ManagerieRemoteTTSStopPayload.self)
        let command = ManagerieRemoteIncomingCommand.stop(
            scope: payload?.scope,
            idempotencyKey: idempotencyKey
        )
        handleAsyncCommand(command, name: name, requestId: requestId, idempotencyKey: idempotencyKey, peer: peer)
    }

    private func handleAudioSetStream(frame: ManagerieRemoteFrame, requestId: String, peer: ManagerieRemotePeer) {
        let name = "audio.setStream"
        guard let idempotencyKey = frame.idempotencyKey, !idempotencyKey.isEmpty else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
            return
        }

        if let previous = peer.idempotentAckByKey[idempotencyKey] {
            send(frame: previous, to: peer)
            return
        }

        guard let payload = frame.payload?.decode(ManagerieRemoteAudioSetStreamPayload.self) else {
            sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "enabled is required", to: peer)
            return
        }

        peer.audioStreamEnabled = payload.enabled
        let ackPayload: JSONValue = .object(["enabled": .bool(payload.enabled)])
        let ack = ManagerieRemoteFrame.ack(name: name, requestId: requestId, payload: ackPayload)
        storeIdempotentAck(ack, for: idempotencyKey, peer: peer)
        send(frame: ack, to: peer)
    }

    private func replayEvents(from seq: Int64, to peer: ManagerieRemotePeer) {
        let missing = replayLog.filter { $0.seq > seq }
        if missing.isEmpty {
            sendSnapshotEvent(to: peer)
            return
        }

        if let first = missing.first, first.seq != seq + 1 {
            emitEvent(
                name: "stream.reset",
                payload: .object(["reason": .string("replay-window-exceeded")]),
                scope: .only(peer)
            )
            sendSnapshotEvent(to: peer)
            return
        }

        for event in missing {
            send(frame: event.frame, to: peer)
        }
    }

    private func sendSnapshotEvent(to peer: ManagerieRemotePeer) {
        let snapshot = snapshotProvider()
        let payload = JSONValue.fromEncodable(snapshot) ?? .object([:])
        emitEvent(name: "sessions.updated", payload: payload, scope: .only(peer))
    }

    private func handleAsyncCommand(
        _ command: ManagerieRemoteIncomingCommand,
        name: String,
        requestId: String,
        idempotencyKey: String,
        peer: ManagerieRemotePeer
    ) {
        commandHandler(command) { [weak self, weak peer] result in
            guard let self, let peer else { return }
            self.queue.async {
                guard self.peers[peer.id] != nil else { return }

                if result.ok {
                    let payload = JSONValue.from(any: result.payload) ?? .object([:])
                    let ack = ManagerieRemoteFrame.ack(name: name, requestId: requestId, payload: payload)
                    self.storeIdempotentAck(ack, for: idempotencyKey, peer: peer)
                    self.send(frame: ack, to: peer)
                } else {
                    self.sendError(
                        name: name,
                        requestId: requestId,
                        code: result.code ?? "INTERNAL_ERROR",
                        message: result.message ?? "command failed",
                        to: peer
                    )
                }
            }
        }
    }

    private func storeIdempotentAck(_ frame: ManagerieRemoteFrame, for key: String, peer: ManagerieRemotePeer) {
        if peer.idempotentAckByKey[key] == nil {
            peer.idempotentAckOrder.append(key)
        }
        peer.idempotentAckByKey[key] = frame

        let overflow = peer.idempotentAckOrder.count - maxIdempotentAcksPerPeer
        if overflow > 0 {
            for _ in 0..<overflow {
                let evicted = peer.idempotentAckOrder.removeFirst()
                peer.idempotentAckByKey.removeValue(forKey: evicted)
            }
        }
    }

    private func sendAck(name: String, requestId: String, payload: JSONValue, to peer: ManagerieRemotePeer) {
        send(frame: .ack(name: name, requestId: requestId, payload: payload), to: peer)
    }

    private func sendError(name: String, requestId: String, code: String, message: String, to peer: ManagerieRemotePeer) {
        send(frame: .error(name: name, requestId: requestId, code: code, message: message), to: peer)
    }

    private func sendProtocolError(to peer: ManagerieRemotePeer, code: String, message: String) {
        send(frame: .protocolError(code: code, message: message), to: peer)
    }

    func publishSessionsUpdated(_ snapshot: ManagerieRemoteSnapshot) {
        let payload = JSONValue.fromEncodable(snapshot) ?? .object([:])
        queue.async {
            self.emitEvent(name: "sessions.updated", payload: payload)
        }
    }

    func publishPlaybackState(_ playback: ManagerieRemotePlaybackState) {
        let payload = JSONValue.fromEncodable(playback) ?? .object([:])
        queue.async {
            self.emitEvent(name: "playback.state", payload: payload)
        }
    }

    func publishHistoryAppended(_ entry: ManagerieRemoteHistoryEntry) {
        let payload = JSONValue.fromEncodable(entry) ?? .object([:])
        queue.async {
            self.emitEvent(name: "history.appended", payload: payload)
        }
    }

    func publishAudioStart(_ event: ManagerieRemoteAudioStart) {
        let payload = JSONValue.fromEncodable(event) ?? .object([:])
        queue.async {
            self.emitEvent(
                name: "audio.start",
                payload: payload,
                scope: .audioSubscribers,
                includeSequence: false,
                storeReplay: false
            )
        }
    }

    func publishAudioChunk(_ event: ManagerieRemoteAudioChunk) {
        let payload = JSONValue.fromEncodable(event) ?? .object([:])
        queue.async {
            self.emitEvent(
                name: "audio.chunk",
                payload: payload,
                scope: .audioSubscribers,
                includeSequence: false,
                storeReplay: false
            )
        }
    }

    func publishAudioEnd(_ event: ManagerieRemoteAudioEnd) {
        let payload = JSONValue.fromEncodable(event) ?? .object([:])
        queue.async {
            self.emitEvent(
                name: "audio.end",
                payload: payload,
                scope: .audioSubscribers,
                includeSequence: false,
                storeReplay: false
            )
        }
    }

    private func emitEvent(
        name: String,
        payload: JSONValue,
        scope: ManagerieRemoteBroadcastScope = .allAuthenticated,
        includeSequence: Bool = true,
        storeReplay: Bool = true
    ) {
        let seqValue: Int64?
        if includeSequence {
            eventSeq += 1
            seqValue = eventSeq
        } else {
            seqValue = nil
        }

        let frame = ManagerieRemoteFrame.event(name: name, seq: seqValue, payload: payload)

        if storeReplay, let seq = seqValue {
            replayLog.append(ManagerieRemoteStoredEvent(seq: seq, frame: frame))
            if replayLog.count > config.replayLimit {
                replayLog.removeFirst(replayLog.count - config.replayLimit)
            }
        }

        switch scope {
        case .allAuthenticated:
            for peer in peers.values where peer.authenticated {
                send(frame: frame, to: peer)
            }

        case .only(let peer):
            guard peer.authenticated else { return }
            send(frame: frame, to: peer)

        case .audioSubscribers:
            for peer in peers.values where peer.authenticated && peer.audioStreamEnabled {
                send(frame: frame, to: peer)
            }
        }
    }

    private func send(frame: ManagerieRemoteFrame, to peer: ManagerieRemotePeer) {
        guard let payload = frame.encodeData() else { return }
        sendTransportFrame(opcode: 0x1, payload: payload, to: peer)
    }

    private func sendCloseFrame(to peer: ManagerieRemotePeer) {
        sendTransportFrame(opcode: 0x8, payload: Data(), to: peer)
    }

    private func sendTransportFrame(opcode: UInt8, payload: Data, to peer: ManagerieRemotePeer) {
        let frameData = ManagerieWebSocketCodec.encodeFrame(opcode: opcode, payload: payload)
        peer.connection.send(content: frameData, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer else { return }
            if error != nil {
                self.queue.async {
                    self.drop(peer: peer)
                }
            }
        })
    }

    private func startHeartbeatLoop() {
        heartbeatTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeats()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendHeartbeats() {
        for peer in peers.values where peer.authenticated {
            peer.awaitingPongCount += 1
            if peer.awaitingPongCount > 2 {
                sendCloseFrame(to: peer)
                drop(peer: peer)
                continue
            }
            sendTransportFrame(opcode: 0x9, payload: Data("hb".utf8), to: peer)
        }
    }
}
