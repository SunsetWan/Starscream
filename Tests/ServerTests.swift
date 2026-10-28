//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  ServerTests.swift
//  Starscream
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
import Testing
@testable import Starscream

#if canImport(Network)
@Suite("Server connection")
struct ServerConnectionTests {
    @Test
    func `A peer close waits for the pending local close to reach the transport`() async throws {
        let transport = ServerTestTransport()
        let timeouts = TestTimeoutScheduler()
        let connection = ServerConnection(transport: transport, timeoutScheduler: timeouts.schedule)
        try await open(connection, transport: transport)
        transport.holdWriteCompletions = true
        connection.write(data: Data([0x03, 0xE9]), opcode: .connectionClose) { _ in }
        try await eventuallyForServer { transport.writes.count == 2 && timeouts.count == 1 }
        let parser = WSFramer(isServer: true)
        let recorder = ServerCloseFrameRecorder()
        parser.register(delegate: recorder)
        parser.add(data: clientFrame(opcode: .connectionClose, payload: Data([0x03, 0xE8])))
        try waitForServerEvent(recorder.ready)

        connection.frameProcessed(event: .frame(try #require(recorder.frame.withLock { $0 })))
        try timeouts.flushQueue()

        #expect(transport.disconnectCount == 0)
        transport.completeNextWrite()
        try await eventuallyForServer { transport.disconnectCount == 1 }
        #expect(transport.writes.count == 2)
    }

    @Test
    func `A client extension failure receives a legal server close`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        try await open(connection, transport: transport)
        let codes = Locked([UInt16]())
        connection.onEvent = { event in
            if case .disconnected(_, let code) = event { codes.withLock { $0.append(code) } }
        }

        transport.receive(clientFrame(opcode: .connectionClose, payload: Data([0x03, 0xF2])))
        try await eventuallyForServer { !codes.withLock { $0.isEmpty } }

        #expect(codes.withLock { $0 } == [1_010])
        #expect(transport.writes.last == Data([0x88, 0x00]))
    }

    @Test
    func `Concurrent local and peer closes complete without a timeout`() throws {
        let peerReason = String(repeating: "a", count: 123)
        let peerPayload = makeClosePayload(code: 1_000, reason: Data(peerReason.utf8))
        let localPayload = makeClosePayload(code: 1_001, reason: Data(repeating: 0x62, count: 123))
        let parser = WSFramer(isServer: true)
        let recorder = ServerCloseFrameRecorder()
        parser.register(delegate: recorder)
        parser.add(data: clientFrame(opcode: .connectionClose, payload: peerPayload))
        try waitForServerEvent(recorder.ready)
        let peerFrame = try #require(recorder.frame.withLock { $0 })
        let localQueue = DispatchQueue(label: "test.server.local-close")
        let peerQueue = DispatchQueue(label: "test.server.peer-close")
        var timeoutCount = 0

        // Exercise both orders and the gap between observing an open connection and closing it.
        for _ in 0..<200 {
            let transport = ServerTestTransport()
            let timeouts = TestTimeoutScheduler()
            let scheduled = DispatchSemaphore(value: 0)
            let connection = ServerConnection(transport: transport, timeoutScheduler: { delay, queue, action in
                timeouts.schedule(after: delay, on: queue, action: action)
                scheduled.signal()
            })
            let opened = DispatchSemaphore(value: 0)
            let localCompleted = DispatchSemaphore(value: 0)
            let peerQueued = DispatchSemaphore(value: 0)
            let reasons = Locked([String]())
            connection.onEvent = { event in
                switch event {
                case .connected: opened.signal()
                case .disconnected(let reason, _): reasons.withLock { $0.append(reason) }
                default: break
                }
            }
            transport.receive(Data(validUpgradeRequest.utf8))
            try waitForServerEvent(opened)
            let launch = DispatchSemaphore(value: 0)
            localQueue.async {
                launch.wait()
                connection.write(data: localPayload, opcode: .connectionClose) { _ in localCompleted.signal() }
            }
            peerQueue.async {
                launch.wait()
                connection.frameProcessed(event: .frame(peerFrame))
                peerQueued.signal()
            }
            launch.signal()
            launch.signal()
            try waitForServerEvent(localCompleted)
            try waitForServerEvent(peerQueued)
            try waitForServerEvent(transport.closeWritten)
            try waitForServerEvent(scheduled)
            try timeouts.fireNext()

            let observed = reasons.withLock { $0 }
            if observed != [peerReason] { timeoutCount += 1 }
            #expect(transport.disconnectCount == 1)
        }
        #expect(timeoutCount == 0)
    }

    @Test
    func `Server callbacks can safely cross concurrency domains`() {
        let connection = ServerConnection(transport: ServerTestTransport())
        let server = WebSocketServer()
        requireSendableServerCallback(connection.onEvent)
        requireSendableServerCallback(server.onEvent)
    }

    @Test
    func `Upgrade response is complete and same-read leftover is processed`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        var packet = Data(validUpgradeRequest.utf8)
        packet.append(clientFrame(opcode: .textFrame, payload: Data("hi".utf8)))

        await confirmation("connected and text", expectedCount: 2) { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    switch event {
                    case .connected:
                        confirm()
                    case .text("hi"):
                        confirm()
                    default:
                        break
                    }
                }
                transport.receive(packet)
            } isComplete: {
                transport.writes.count == 1
            }
        }

        let responseData = try #require(transport.writes.first)
        let response = try #require(String(data: responseData, encoding: .utf8))
        #expect(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        #expect(response.localizedCaseInsensitiveContains("Upgrade: websocket\r\n"))
        #expect(response.localizedCaseInsensitiveContains("Connection: Upgrade\r\n"))
        #expect(
            response.localizedCaseInsensitiveContains(
                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
            )
        )
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test
    func `Ping is reported and automatically echoed as pong`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        try await open(connection, transport: transport)
        let payload = Data("heartbeat".utf8)

        await confirmation("ping") { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    guard case .ping(let receivedPayload) = event else { return }
                    #expect(receivedPayload == payload)
                    confirm()
                }
                transport.receive(clientFrame(opcode: .ping, payload: payload))
            } isComplete: {
                transport.writes.count == 2
            }
        }

        let pong = try #require(transport.writes.last)
        #expect(pong.first == 0x8A)
        #expect(pong[1] == UInt8(payload.count))
        #expect(Data(pong.dropFirst(2)) == payload)
    }

    @Test
    func `Peer close is echoed before disconnect`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        try await open(connection, transport: transport)
        let closePayload = makeClosePayload(
            code: CloseCode.normal.rawValue,
            reason: Data("bye".utf8)
        )

        await confirmation("disconnected") { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    guard case .disconnected(let reason, let code) = event else { return }
                    #expect(reason == "bye")
                    #expect(code == CloseCode.normal.rawValue)
                    confirm()
                }
                transport.receive(clientFrame(opcode: .connectionClose, payload: closePayload))
            } isComplete: {
                transport.disconnectCount == 1
            }
        }

        #expect(transport.disconnectCount == 1)
        #expect(transport.writes.count == 2)
        let closeFrame = try #require(transport.writes.last)
        #expect(closeFrame.first == 0x88)
        #expect(Data(closeFrame.dropFirst(2)) == closePayload)
    }

    @Test
    func `Peer close without status echoes an empty close frame`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        try await open(connection, transport: transport)

        await confirmation("disconnected") { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    guard case .disconnected(_, let code) = event else { return }
                    #expect(code == CloseCode.noStatusReceived.rawValue)
                    confirm()
                }
                transport.receive(clientFrame(opcode: .connectionClose, payload: Data()))
            } isComplete: {
                transport.disconnectCount == 1
            }
        }

        #expect(transport.disconnectCount == 1)
        #expect(transport.writes.last == Data([0x88, 0x00]))
    }

    @Test
    func `Peer close disconnects after timeout when echo write never completes`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport, closeTimeout: 0.02)
        try await open(connection, transport: transport)
        transport.holdWriteCompletions = true
        let payload = makeClosePayload(
            code: CloseCode.normal.rawValue,
            reason: Data("bye".utf8)
        )

        await confirmation("timeout disconnect") { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    guard case .disconnected(let reason, let code) = event else { return }
                    #expect(reason == "Close handshake timed out")
                    #expect(code == CloseCode.normal.rawValue)
                    confirm()
                }
                transport.receive(clientFrame(opcode: .connectionClose, payload: payload))
            } isComplete: {
                transport.disconnectCount == 1
            }
        }

        #expect(transport.writes.count == 2)
        #expect(transport.disconnectCount == 1)
    }

    @Test
    func `Framer protocol error sends protocol close then disconnects`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        try await open(connection, transport: transport)

        await confirmation("error and disconnected", expectedCount: 2) { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    switch event {
                    case .error:
                        confirm()
                    case .disconnected(_, let code):
                        #expect(code == CloseCode.protocolError.rawValue)
                        confirm()
                    default:
                        break
                    }
                }
                // A client-to-server frame without the MASK bit violates RFC 6455 section 5.1.
                transport.receive(Data([0x81, 0x00]))
            } isComplete: {
                transport.disconnectCount == 1
            }
        }

        #expect(transport.disconnectCount == 1)
        #expect(serverCloseCode(try #require(transport.writes.last)) == CloseCode.protocolError.rawValue)
    }

    @Test
    func `Protocol error disconnects after timeout when close write never completes`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport, closeTimeout: 0.02)
        try await open(connection, transport: transport)
        transport.holdWriteCompletions = true

        await confirmation("error and timeout disconnect", expectedCount: 2) { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    switch event {
                    case .error:
                        confirm()
                    case .disconnected(let reason, let code):
                        #expect(reason == "Close handshake timed out")
                        #expect(code == CloseCode.protocolError.rawValue)
                        confirm()
                    default:
                        break
                    }
                }
                transport.receive(Data([0x81, 0x00]))
            } isComplete: {
                transport.disconnectCount == 1
            }
        }

        #expect(transport.writes.count == 2)
        #expect(serverCloseCode(try #require(transport.writes.last)) == CloseCode.protocolError.rawValue)
    }

    @Test
    func `Collector error sends compliant close then disconnects`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        try await open(connection, transport: transport)

        await confirmation("error and disconnected", expectedCount: 2) { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    switch event {
                    case .error, .disconnected:
                        confirm()
                    default:
                        break
                    }
                }
                transport.receive(clientFrame(opcode: .continueFrame, payload: Data("orphan".utf8)))
            } isComplete: {
                transport.disconnectCount == 1
            }
        }

        #expect(transport.disconnectCount == 1)
        #expect(serverCloseCode(try #require(transport.writes.last)) == CloseCode.protocolError.rawValue)
    }

    @Test
    func `Control frame validation and transport both complete exactly once`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        try await open(connection, transport: transport)

        let invalidCompleted = Locked(false)
        await confirmation("invalid completion") { confirm in
            await withEventPump {
                connection.write(data: Data(repeating: 0x01, count: 126), opcode: .ping) { error in
                    #expect(error != nil)
                    invalidCompleted.withLock { $0 = true }
                    confirm()
                }
            } isComplete: {
                invalidCompleted.withLock { $0 }
            }
        }
        #expect(transport.writes.count == 1, "Invalid control frame must not reach the transport")

        transport.callWriteCompletionTwice = true
        let validCompleted = Locked(false)
        await confirmation("valid completion") { confirm in
            await withEventPump {
                connection.write(data: Data("ok".utf8), opcode: .pong) { error in
                    #expect(error == nil)
                    validCompleted.withLock { $0 = true }
                    confirm()
                }
            } isComplete: {
                validCompleted.withLock { $0 }
            }
        }
        #expect(transport.writes.count == 2)
    }

    @Test
    func `Unsupported WebSocket version receives a 426 response before disconnect`() async throws {
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        let invalidRequest = validUpgradeRequest.replacingOccurrences(
            of: "Sec-WebSocket-Version: 13",
            with: "Sec-WebSocket-Version: 12"
        )

        await confirmation("error and disconnected", expectedCount: 2) { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    switch event {
                    case .error, .disconnected:
                        confirm()
                    default:
                        break
                    }
                }
                transport.receive(Data(invalidRequest.utf8))
            } isComplete: {
                transport.disconnectCount == 1 && transport.writes.count == 1
            }
        }

        let responseData = try #require(transport.writes.first)
        let response = try #require(String(data: responseData, encoding: .utf8))
        #expect(response.hasPrefix("HTTP/1.1 426 Upgrade Required\r\n"))
        #expect(response.localizedCaseInsensitiveContains("Sec-WebSocket-Version: 13\r\n"))
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test
    func `Application close waits for peer close and sends only one close frame`() async throws {
        let transport = ServerTestTransport()
        let timeouts = TestTimeoutScheduler()
        let connection = ServerConnection(transport: transport, timeoutScheduler: timeouts.schedule)
        try await open(connection, transport: transport)
        let payload = makeClosePayload(code: CloseCode.normal.rawValue, reason: Data("bye".utf8))

        await confirmation("local close write") { confirm in
            await withEventPump {
                connection.write(data: payload, opcode: .connectionClose) { error in
                    #expect(error == nil)
                    confirm()
                }
            } isComplete: {
                transport.writes.count == 2 && timeouts.count == 1
            }
        }
        #expect(transport.disconnectCount == 0)

        await confirmation("peer close") { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    guard case .disconnected(_, let code) = event else { return }
                    #expect(code == CloseCode.normal.rawValue)
                    confirm()
                }
                transport.receive(clientFrame(opcode: .connectionClose, payload: payload))
            } isComplete: {
                transport.disconnectCount == 1
            }
        }

        #expect(transport.writes.count == 2, "The peer close must not trigger a second close frame")
        try timeouts.fireNext()
        #expect(transport.disconnectCount == 1)
    }

    @Test
    func `Application close disconnects after its timeout`() async throws {
        let transport = ServerTestTransport()
        let timeouts = TestTimeoutScheduler()
        let connection = ServerConnection(transport: transport, timeoutScheduler: timeouts.schedule)
        try await open(connection, transport: transport)
        let payload = makeClosePayload(code: CloseCode.goingAway.rawValue, reason: Data())

        try await confirmation("timeout disconnect") { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    guard case .disconnected(let reason, let code) = event else { return }
                    #expect(reason == "Close handshake timed out")
                    #expect(code == CloseCode.goingAway.rawValue)
                    confirm()
                }
                connection.write(data: payload, opcode: .connectionClose) { error in
                    #expect(error == nil)
                }
            } isComplete: {
                timeouts.count == 1
            }
            #expect(transport.disconnectCount == 0)
            try timeouts.fireNext()
        }
        #expect(transport.disconnectCount == 1)
        #expect(transport.writes.count == 2)
    }

    private func open(
        _ connection: ServerConnection,
        transport: ServerTestTransport
    ) async throws {
        await confirmation("connected") { confirm in
            await withEventPump {
                connection.onEvent = { event in
                    guard case .connected = event else { return }
                    confirm()
                }
                transport.receive(Data(validUpgradeRequest.utf8))
            } isComplete: {
                transport.writes.count == 1
            }
        }
        #expect(transport.writes.count == 1)
    }
}

@Suite("WebSocket server thread safety")
struct WebSocketServerThreadSafetyTests {
    @Test
    func `Server receives events and removes closed connection`() async throws {
        let server = WebSocketServer()
        let transport = ServerTestTransport()
        let connection = ServerConnection(transport: transport)
        connection.delegate = server
        server.register(connection)

        await confirmation("connected") { confirm in
            await withEventPump {
                server.onEvent = { event in
                    guard case .connected = event else { return }
                    confirm()
                }
                transport.receive(Data(validUpgradeRequest.utf8))
            } isComplete: {
                server.connectionCount == 1 && transport.writes.count == 1
            }
        }
        #expect(server.connectionCount == 1)

        await confirmation("disconnected") { confirm in
            await withEventPump {
                server.onEvent = { event in
                    guard case .disconnected = event else { return }
                    confirm()
                }
                transport.receive(clientFrame(opcode: .connectionClose, payload: Data()))
            } isComplete: {
                server.connectionCount == 0
            }
        }
        #expect(server.connectionCount == 0)
    }

    @Test
    func `Connections can be added and removed concurrently`() {
        let server = WebSocketServer()
        let connections = (0..<64).map { _ in ServerConnection(transport: ServerTestTransport()) }

        DispatchQueue.concurrentPerform(iterations: connections.count) { index in
            server.register(connections[index])
        }
        #expect(server.connectionCount == connections.count)

        DispatchQueue.concurrentPerform(iterations: connections.count) { index in
            server.didReceive(event: .disconnected(
                connections[index],
                "test complete",
                CloseCode.normal.rawValue
            ))
        }
        #expect(server.connectionCount == 0)
    }

    @Test
    func `Events from different connections use one serial callback queue`() async throws {
        let server = WebSocketServer()
        let connections = (0..<32).map { _ in ServerConnection(transport: ServerTestTransport()) }
        let callbacks = Locked((active: 0, maximumActive: 0, delivered: 0))
        server.onEvent = { _ in
            callbacks.withLock {
                $0.active += 1
                $0.maximumActive = max($0.maximumActive, $0.active)
            }
            Thread.sleep(forTimeInterval: 0.001)
            callbacks.withLock {
                $0.active -= 1
                $0.delivered += 1
            }
        }

        DispatchQueue.concurrentPerform(iterations: connections.count) { index in
            server.didReceive(event: .text(connections[index], "event-\(index)"))
        }

        try await eventuallyForServer {
            callbacks.withLock { $0.delivered == connections.count }
        }
        #expect(callbacks.withLock { $0.maximumActive } == 1)
    }
}

private let validUpgradeRequest = """
GET /chat HTTP/1.1\r
Host: server.example.com\r
Upgrade: websocket\r
Connection: Upgrade\r
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
Sec-WebSocket-Version: 13\r
\r\n
"""

private func requireSendableServerCallback<T: Sendable>(_: T) {}

private func waitForServerEvent(_ semaphore: DispatchSemaphore) throws {
    try #require(semaphore.wait(timeout: .now() + 3) == .success)
}

private final class ServerCloseFrameRecorder: FramerEventClient, Sendable {
    let ready = DispatchSemaphore(value: 0)
    let frame = Locked<Frame?>(nil)

    func frameProcessed(event: FrameEvent) {
        if case .frame(let frame) = event {
            self.frame.withLock { $0 = frame }
        }
        ready.signal()
    }
}

private func clientFrame(opcode: FrameOpCode, payload: Data) -> Data {
    try! WSFramer(isServer: false).createWriteFrameResult(
        opcode: opcode,
        payload: payload,
        isCompressed: false
    ).get()
}

private func makeClosePayload(code: UInt16, reason: Data) -> Data {
    var bytes = [UInt8](repeating: 0, count: 2)
    writeUint16(&bytes, offset: 0, value: code)
    var payload = Data(bytes)
    payload.append(reason)
    return payload
}

private func serverCloseCode(_ frame: Data) -> UInt16 {
    [UInt8](frame).readUint16(offset: 2)
}

private func withEventPump(
    timeout: TimeInterval = 1,
    start: () -> Void,
    isComplete: @escaping @Sendable () -> Bool
) async {
    start()
    let deadline = Date().addingTimeInterval(timeout)
    var completedAt: Date?
    while Date() < deadline {
        if isComplete() {
            if let completedAt, Date().timeIntervalSince(completedAt) >= 0.01 {
                break
            }
            completedAt = completedAt ?? Date()
        } else {
            completedAt = nil
        }
        await Task.yield()
    }
    #expect(isComplete())
}

private enum ServerTestWaitError: Error {
    case timedOut
}

private func eventuallyForServer(
    attempts: Int = 300,
    condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw ServerTestWaitError.timedOut
}

private final class ServerTestTransport: Transport, @unchecked Sendable {
    private let storage = Locked(Storage())
    let closeWritten = DispatchSemaphore(value: 0)

    private struct Storage {
        var delegate = WeakReference<any TransportEventClient>()
        var writes = [Data]()
        var disconnectCount = 0
        var callWriteCompletionTwice = false
        var holdWriteCompletions = false
        var pendingWrites = [@Sendable ((any Error)?) -> Void]()
    }

    var usingTLS: Bool { false }

    var writes: [Data] {
        storage.withLock { $0.writes }
    }

    var disconnectCount: Int {
        storage.withLock { $0.disconnectCount }
    }

    var callWriteCompletionTwice: Bool {
        get { storage.withLock { $0.callWriteCompletionTwice } }
        set { storage.withLock { $0.callWriteCompletionTwice = newValue } }
    }

    var holdWriteCompletions: Bool {
        get { storage.withLock { $0.holdWriteCompletions } }
        set { storage.withLock { $0.holdWriteCompletions = newValue } }
    }

    func register(delegate: TransportEventClient) {
        storage.withLock { $0.delegate = WeakReference(delegate) }
    }

    func connect(url: URL, timeout: Double, certificatePinning: CertificatePinning?) {}

    func disconnect() {
        storage.withLock { $0.disconnectCount += 1 }
    }

    func write(data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let behavior = storage.withLock {
            $0.writes.append(data)
            if $0.holdWriteCompletions { $0.pendingWrites.append(completion) }
            return (hold: $0.holdWriteCompletions, twice: $0.callWriteCompletionTwice)
        }
        guard !behavior.hold else { return }
        completion(nil)
        if behavior.twice {
            completion(nil)
        }
        if data.first == 0x88 { closeWritten.signal() }
    }

    func completeNextWrite(error: (any Error)? = nil) {
        let completion = storage.withLock { state -> (@Sendable ((any Error)?) -> Void)? in
            state.pendingWrites.isEmpty ? nil : state.pendingWrites.removeFirst()
        }
        completion?(error)
    }

    func receive(_ data: Data) {
        storage.withLock { $0.delegate.value }?.connectionChanged(state: .receive(data))
    }
}
#endif
