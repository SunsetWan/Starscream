//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  EngineTests.swift
//  Starscream
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Starscream

@Suite("WSEngine state machine")
struct WSEngineTests {
    struct InvalidAcceptCase: Sendable, CustomTestStringConvertible {
        enum Value: Sendable {
            case missing
            case wrong
        }

        let name: String
        let value: Value

        var testDescription: String { name }
    }

    private static let invalidAcceptCases = [
        InvalidAcceptCase(name: "missing Accept", value: .missing),
        InvalidAcceptCase(name: "wrong Accept", value: .wrong),
    ]

    @Test
    func `Write before open completes exactly once without writing a frame`() async throws {
        let fixture = ControlledEngineFixture()
        let completionCount = Locked(0)

        fixture.engine.write(data: Data("not-open".utf8), opcode: .textFrame) {
            completionCount.withLock { $0 += 1 }
        }

        try await eventually { completionCount.withLock { $0 == 1 } }
        await settle()
        #expect(completionCount.withLock { $0 } == 1)
        #expect(fixture.framer.writeCalls.isEmpty)
        #expect(fixture.transport.writes.isEmpty)
    }

    @Test
    func `Local close waits for the peer close after the write completes`() async throws {
        let fixture = ControlledEngineFixture()
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()

        fixture.engine.stop(closeCode: CloseCode.normal.rawValue)

        try await eventually {
            fixture.framer.writeCalls.count == 1 && fixture.transport.writes.count == 1
        }
        await settle()
        #expect(fixture.transport.disconnectCount == 0)
        #expect(fixture.recorder.events.isEmpty)
        #expect(fixture.framer.writeCalls.first?.opcode == .connectionClose)

        fixture.engine.didForm(event: .closed("peer acknowledged", CloseCode.normal.rawValue))

        try await eventually { fixture.transport.disconnectCount == 1 }
        #expect(
            fixture.recorder.events
                == [.disconnected("peer acknowledged", CloseCode.normal.rawValue)]
        )
    }

    @Test
    func `Local close disconnects when the close handshake times out`() async throws {
        let fixture = ControlledEngineFixture(closeTimeout: 0.02)
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()

        fixture.engine.stop(closeCode: CloseCode.goingAway.rawValue)

        try await eventually { fixture.transport.disconnectCount == 1 }
        #expect(fixture.framer.writeCalls.first?.opcode == .connectionClose)
        #expect(
            fixture.recorder.events
                == [.disconnected("close handshake timed out", CloseCode.goingAway.rawValue)]
        )
    }

    @Test
    func `Remote empty close is echoed empty and never writes status 1005`() async throws {
        let fixture = ControlledEngineFixture()
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()

        fixture.engine.didForm(event: .closed(
            "connection closed by server",
            CloseCode.noStatusReceived.rawValue
        ))

        try await eventually { fixture.transport.disconnectCount == 1 }
        let close = try #require(fixture.framer.writeCalls.first)
        #expect(close.opcode == .connectionClose)
        #expect(close.payload.isEmpty)
        #expect(close.payload != makeClosePayload(code: CloseCode.noStatusReceived.rawValue))
        #expect(fixture.transport.writes.count == 1)
    }

    @Test(arguments: invalidAcceptCases)
    func `Invalid Accept fails the handshake`(_ testCase: InvalidAcceptCase) async throws {
        let fixture = ControlledEngineFixture()
        try await fixture.start()
        let key = try #require(fixture.httpHandler.latestKey)
        var headers = validResponseHeaders(key: key)
        switch testCase.value {
        case .missing:
            headers.removeValue(forKey: "Sec-WebSocket-Accept")
        case .wrong:
            headers["Sec-WebSocket-Accept"] = "not-the-accept-value"
        }

        fixture.httpHandler.emit(.success(headers: headers, leftover: Data()))

        try await eventually {
            fixture.recorder.events.contains(.error) && fixture.transport.disconnectCount == 1
        }
        #expect(!fixture.recorder.events.contains { $0.isConnected })
        #expect(fixture.transport.writes.count == 1, "Only the opening request may be written")
    }

    @Test
    func `Handshake response and first frame in one packet both arrive`() async throws {
        let transport = EngineTestTransport()
        let recorder = EngineEventRecorder()
        let engine = WSEngine(
            transport: transport,
            headerValidator: AcceptingHeaderValidator(),
            httpHandler: FoundationHTTPHandler(),
            framer: WSFramer()
        )
        engine.register(delegate: recorder)
        engine.start(request: testRequest)

        try await eventually { transport.connectCount == 1 }
        transport.emit(.connected)
        try await eventually { transport.writes.count == 1 }
        let requestText = try #require(String(data: transport.writes[0], encoding: .utf8))
        let key = try #require(httpHeader(named: "Sec-WebSocket-Key", in: requestText))

        var packet = Data(validHTTPResponse(key: key).utf8)
        packet.append(serverFrame(opcode: .textFrame, payload: Data("first".utf8)))
        transport.emit(.receive(packet))

        try await eventually {
            recorder.events.contains(.connected) && recorder.events.contains(.text("first"))
        }
        #expect(Array(recorder.events.prefix(2)) == [.connected, .text("first")])
    }

    @Test
    func `Reconnect resets partial frame compression and HTTP accumulator state`() async throws {
        let compression = RecordingCompressionHandler()
        let fixture = ControlledEngineFixture(compressionHandler: compression)

        // Attempt 1 leaves an incomplete HTTP response in the parser.
        try await fixture.start()
        fixture.transport.emit(.receive(Data("partial HTTP response".utf8)))
        try await eventually { !fixture.httpHandler.accumulator.isEmpty }
        fixture.engine.forceStop()
        try await eventually { fixture.transport.disconnectCount == 1 }
        #expect(fixture.httpHandler.accumulator.isEmpty)

        // Attempt 2 negotiates compression and leaves half of a frame buffered.
        fixture.recorder.clear()
        try await fixture.startAndOpen(extensionSelection: "permessage-deflate")
        #expect(compression.isLoaded)
        #expect(fixture.framer.compressionEnabled)
        fixture.transport.emit(.receive(Data([0x81])))
        try await eventually { fixture.framer.bufferedData == Data([0x81]) }
        fixture.engine.forceStop()
        try await eventually { fixture.transport.disconnectCount == 2 }
        #expect(fixture.framer.bufferedData.isEmpty)
        #expect(!fixture.framer.compressionEnabled)
        #expect(!compression.isLoaded)

        // Attempt 3 opens without compression and is unaffected by either stale buffer.
        fixture.recorder.clear()
        try await fixture.startAndOpen()
        #expect(fixture.httpHandler.accumulator.isEmpty)
        #expect(fixture.framer.bufferedData.isEmpty)
        #expect(!fixture.framer.compressionEnabled)
        #expect(!compression.isLoaded)

        fixture.prepareForFrameAssertions()
        fixture.engine.write(string: "fresh") {}
        try await eventually { fixture.framer.writeCalls.count == 1 }
        #expect(fixture.framer.writeCalls[0].opcode == .textFrame)
        #expect(!fixture.framer.writeCalls[0].isCompressed)
        #expect(compression.compressCallCount == 0)
        #expect(fixture.httpHandler.resetCount >= 4)
        #expect(fixture.framer.resetCount >= 4)
        #expect(compression.resetCount >= 4)
    }

    @Test
    func `Control frames are never compressed after compression negotiation`() async throws {
        let compression = RecordingCompressionHandler()
        let fixture = ControlledEngineFixture(compressionHandler: compression)
        try await fixture.startAndOpen(extensionSelection: "permessage-deflate")
        #expect(fixture.framer.compressionEnabled)
        fixture.prepareForFrameAssertions()
        compression.clearCompressCallCount()
        let completionCount = Locked(0)

        fixture.engine.write(data: Data("ping".utf8), opcode: .ping) {
            completionCount.withLock { $0 += 1 }
        }
        fixture.engine.write(data: Data("pong".utf8), opcode: .pong) {
            completionCount.withLock { $0 += 1 }
        }
        fixture.engine.stop(closeCode: CloseCode.normal.rawValue)

        try await eventually {
            fixture.framer.writeCalls.count == 3 && completionCount.withLock { $0 == 2 }
        }
        #expect(fixture.framer.writeCalls.map(\.opcode) == [.ping, .pong, .connectionClose])
        #expect(fixture.framer.writeCalls.allSatisfy { !$0.isCompressed })
        #expect(compression.compressCallCount == 0)
    }

    @Test
    func `A stale write failure cannot close a newer connection`() async throws {
        let fixture = ControlledEngineFixture()
        fixture.transport.holdWrites = true
        try await fixture.start()

        fixture.engine.forceStop()
        try await eventually { fixture.transport.disconnectCount == 1 }

        fixture.recorder.clear()
        fixture.transport.holdWrites = false
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()

        fixture.transport.completeWrite(at: 0, error: EngineTestError.staleWrite)
        await settle()

        #expect(fixture.transport.disconnectCount == 1)
        #expect(fixture.recorder.events.isEmpty)
        fixture.engine.write(string: "new attempt is still open") {}
        try await eventually { fixture.transport.writes.count == 1 }
    }

    @Test
    func `A stale close write completion cannot disconnect a newer connection`() async throws {
        let fixture = ControlledEngineFixture(closeTimeout: 0.02)
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()
        fixture.transport.holdWrites = true

        fixture.engine.didForm(event: .closed("old attempt", CloseCode.normal.rawValue))
        try await eventually { fixture.transport.disconnectCount == 1 }

        fixture.recorder.clear()
        fixture.transport.holdWrites = false
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()

        fixture.transport.completeWrite(at: 0, error: nil)
        await settle()

        #expect(fixture.transport.disconnectCount == 1)
        #expect(fixture.recorder.events.isEmpty)
        fixture.engine.write(string: "new attempt is still open") {}
        try await eventually { fixture.transport.writes.count == 1 }
    }

    @Test
    func `Callbacks retained by an old attempt cannot mutate the new attempt`() async throws {
        let fixture = ControlledEngineFixture()
        try await fixture.startAndOpen()
        let oldTransportDelegate = try #require(fixture.transport.currentDelegate)
        let oldHTTPDelegate = try #require(fixture.httpHandler.currentDelegate)
        let oldFramerDelegate = try #require(fixture.framer.currentDelegate)

        fixture.engine.forceStop()
        try await eventually { fixture.transport.disconnectCount == 1 }
        fixture.recorder.clear()
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()

        oldTransportDelegate.connectionChanged(state: .failed(EngineTestError.staleCallback))
        oldHTTPDelegate.didReceiveHTTP(event: .failure(EngineTestError.staleCallback))
        oldFramerDelegate.frameProcessed(event: .error(EngineTestError.staleCallback))
        await settle()

        #expect(fixture.transport.disconnectCount == 1)
        #expect(fixture.recorder.events.isEmpty)
        fixture.engine.write(string: "new attempt is still open") {}
        try await eventually { fixture.transport.writes.count == 1 }
    }

    @Test
    func `Invalid selected compression parameters fail the opening handshake`() async throws {
        let compression = RecordingCompressionHandler(rejectedSelection: "unknown=1")
        let fixture = ControlledEngineFixture(compressionHandler: compression)
        try await fixture.start()
        let key = try #require(fixture.httpHandler.latestKey)

        fixture.httpHandler.emit(.success(
            headers: validResponseHeaders(
                key: key,
                extensionSelection: "permessage-deflate; unknown=1"
            ),
            leftover: Data()
        ))

        try await eventually {
            fixture.recorder.events.contains(.error) && fixture.transport.disconnectCount == 1
        }
        #expect(!fixture.recorder.events.contains { $0.isConnected })
        #expect(!fixture.framer.compressionEnabled)
    }

    @Test
    func `Opening handshake always uses GET even when the input request uses POST`() async throws {
        let fixture = ControlledEngineFixture()
        var request = testRequest
        request.httpMethod = "POST"
        fixture.engine.start(request: request)

        try await eventually { fixture.transport.connectCount == 1 }
        fixture.transport.emit(.connected)
        try await eventually { fixture.httpHandler.latestRequest != nil }

        #expect(fixture.httpHandler.latestRequest?.httpMethod == "GET")
    }

    @Test
    func `A ping received while awaiting peer close is answered with pong`() async throws {
        let fixture = ControlledEngineFixture(closeTimeout: 1)
        try await fixture.startAndOpen()
        fixture.prepareForFrameAssertions()

        fixture.engine.stop(closeCode: CloseCode.normal.rawValue)
        try await eventually { fixture.framer.writeCalls.count == 1 }
        fixture.engine.didForm(event: .ping(Data("closing ping".utf8)))

        try await eventually { fixture.framer.writeCalls.count == 2 }
        #expect(fixture.framer.writeCalls.map(\.opcode) == [.connectionClose, .pong])
        #expect(fixture.framer.writeCalls[1].payload == Data("closing ping".utf8))
    }
}

@Suite("WebSocket callback delivery")
struct WebSocketCallbackTests {
    @Test
    func `WebSocket and its engine are Sendable`() {
        let engine = CallbackTestEngine()
        let socket = WebSocket(request: testRequest, engine: engine)

        requireSendable(engine)
        requireSendable(socket)
    }

    @Test
    func `Delegate precedes onEvent and both run on callbackQueue`() async throws {
        let engine = CallbackTestEngine()
        let socket = WebSocket(request: testRequest, engine: engine)
        let callbackQueue = DispatchQueue(label: "com.vluxe.starscream.tests.callback")
        let queueProbe = QueueProbe(queue: callbackQueue)
        let deliveries = Locked([String]())
        let delegate = CallbackWebSocketDelegate(deliveries: deliveries, queueProbe: queueProbe)
        socket.callbackQueue = callbackQueue
        socket.delegate = delegate
        socket.onEvent = { event in
            let value = event.textValue ?? "unexpected"
            deliveries.withLock {
                $0.append("onEvent:\(value):\(queueProbe.isCurrent)")
            }
        }
        socket.connect()

        engine.emit(.text("callback"))

        try await eventually { deliveries.withLock { $0.count == 2 } }
        #expect(
            deliveries.withLock { $0 }
                == ["delegate:callback:true", "onEvent:callback:true"]
        )
    }
}

private func requireSendable<T: Sendable>(_: T) {}

// MARK: - Engine fixture

private final class ControlledEngineFixture: @unchecked Sendable {
    let transport: EngineTestTransport
    let httpHandler: ControllableHTTPHandler
    let framer: RecordingFramer
    let recorder: EngineEventRecorder
    let engine: WSEngine

    init(
        closeTimeout: TimeInterval = 1,
        compressionHandler: RecordingCompressionHandler? = nil
    ) {
        transport = EngineTestTransport()
        httpHandler = ControllableHTTPHandler()
        framer = RecordingFramer()
        recorder = EngineEventRecorder()
        engine = WSEngine(
            transport: transport,
            headerValidator: AcceptingHeaderValidator(),
            httpHandler: httpHandler,
            framer: framer,
            compressionHandler: compressionHandler,
            closeTimeout: closeTimeout
        )
        engine.register(delegate: recorder)
    }

    func start() async throws {
        let priorConnectCount = transport.connectCount
        let priorWriteCount = transport.writes.count
        engine.start(request: testRequest)
        try await eventually { self.transport.connectCount == priorConnectCount + 1 }
        transport.emit(.connected)
        try await eventually {
            self.transport.writes.count == priorWriteCount + 1 && self.httpHandler.latestKey != nil
        }
    }

    func startAndOpen(extensionSelection: String? = nil) async throws {
        try await start()
        let priorConnectedCount = recorder.events.filter(\EngineEventSnapshot.isConnected).count
        let key = try #require(httpHandler.latestKey)
        httpHandler.emit(.success(
            headers: validResponseHeaders(key: key, extensionSelection: extensionSelection),
            leftover: Data()
        ))
        try await eventually {
            self.recorder.events.filter(\EngineEventSnapshot.isConnected).count
                == priorConnectedCount + 1
        }
    }

    func prepareForFrameAssertions() {
        transport.clearWrites()
        framer.clearWriteCalls()
        recorder.clear()
    }
}

// MARK: - Deterministic collaborators

private enum EngineTestError: Error {
    case staleWrite
    case staleCallback
}

private final class EngineTestTransport: Transport, @unchecked Sendable {
    private typealias WriteCompletion = @Sendable ((any Error)?) -> Void

    private struct State {
        var delegate = WeakReference<any TransportEventClient>()
        var writes = [Data]()
        var pendingWriteCompletions = [WriteCompletion]()
        var holdWrites = false
        var connectCount = 0
        var disconnectCount = 0
    }

    private let state = Locked(State())

    var usingTLS: Bool { false }
    var writes: [Data] { state.withLock { $0.writes } }
    var connectCount: Int { state.withLock { $0.connectCount } }
    var disconnectCount: Int { state.withLock { $0.disconnectCount } }
    var currentDelegate: (any TransportEventClient)? { state.withLock { $0.delegate.value } }
    var holdWrites: Bool {
        get { state.withLock { $0.holdWrites } }
        set { state.withLock { $0.holdWrites = newValue } }
    }

    func register(delegate: TransportEventClient) {
        state.withLock { $0.delegate = WeakReference(delegate) }
    }

    func connect(url: URL, timeout: Double, certificatePinning: CertificatePinning?) {
        state.withLock { $0.connectCount += 1 }
    }

    func disconnect() {
        state.withLock { $0.disconnectCount += 1 }
    }

    func write(data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let shouldComplete = state.withLock { state -> Bool in
            state.writes.append(data)
            if state.holdWrites {
                state.pendingWriteCompletions.append(completion)
                return false
            }
            return true
        }
        if shouldComplete {
            completion(nil)
        }
    }

    func completeWrite(at index: Int, error: (any Error)?) {
        let completion = state.withLock { state -> WriteCompletion? in
            guard state.pendingWriteCompletions.indices.contains(index) else { return nil }
            return state.pendingWriteCompletions.remove(at: index)
        }
        completion?(error)
    }

    func emit(_ connectionState: ConnectionState) {
        state.withLock { $0.delegate.value }?.connectionChanged(state: connectionState)
    }

    func clearWrites() {
        state.withLock { $0.writes.removeAll() }
    }
}

private final class ControllableHTTPHandler: HTTPHandler, @unchecked Sendable {
    private struct State {
        var delegate = WeakReference<any HTTPHandlerDelegate>()
        var requests = [URLRequest]()
        var accumulator = Data()
        var resetCount = 0
    }

    private let state = Locked(State())

    var latestKey: String? {
        state.withLock { $0.requests.last?.value(forHTTPHeaderField: "Sec-WebSocket-Key") }
    }
    var latestRequest: URLRequest? { state.withLock { $0.requests.last } }

    var accumulator: Data { state.withLock { $0.accumulator } }
    var resetCount: Int { state.withLock { $0.resetCount } }
    var currentDelegate: (any HTTPHandlerDelegate)? { state.withLock { $0.delegate.value } }

    func register(delegate: HTTPHandlerDelegate) {
        state.withLock { $0.delegate = WeakReference(delegate) }
    }

    func convert(request: URLRequest) -> Data {
        let count = state.withLock { state -> Int in
            state.requests.append(request)
            return state.requests.count
        }
        return Data("upgrade-request-\(count)".utf8)
    }

    func parse(data: Data) -> Int {
        state.withLock { $0.accumulator.append(data) }
        return -1
    }

    func reset() {
        state.withLock {
            $0.accumulator.removeAll(keepingCapacity: false)
            $0.resetCount += 1
        }
    }

    func emit(_ event: HTTPEvent) {
        state.withLock { $0.delegate.value }?.didReceiveHTTP(event: event)
    }
}

private final class RecordingFramer: Framer, @unchecked Sendable {
    struct WriteCall: Sendable {
        let opcode: FrameOpCode
        let payload: Data
        let isCompressed: Bool
    }

    private struct State {
        var delegate = WeakReference<any FramerEventClient>()
        var bufferedData = Data()
        var writeCalls = [WriteCall]()
        var compressionEnabled = false
        var resetCount = 0
    }

    private let state = Locked(State())

    var bufferedData: Data { state.withLock { $0.bufferedData } }
    var writeCalls: [WriteCall] { state.withLock { $0.writeCalls } }
    var compressionEnabled: Bool { state.withLock { $0.compressionEnabled } }
    var resetCount: Int { state.withLock { $0.resetCount } }
    var currentDelegate: (any FramerEventClient)? { state.withLock { $0.delegate.value } }

    func add(data: Data) {
        state.withLock { $0.bufferedData.append(data) }
    }

    func register(delegate: FramerEventClient) {
        state.withLock { $0.delegate = WeakReference(delegate) }
    }

    func createWriteFrame(opcode: FrameOpCode, payload: Data, isCompressed: Bool) -> Data {
        switch createWriteFrameResult(opcode: opcode, payload: payload, isCompressed: isCompressed) {
        case .success(let data):
            return data
        case .failure:
            return Data()
        }
    }

    func createWriteFrameResult(
        opcode: FrameOpCode,
        payload: Data,
        isCompressed: Bool
    ) -> Result<Data, any Error> {
        state.withLock {
            $0.writeCalls.append(WriteCall(
                opcode: opcode,
                payload: payload,
                isCompressed: isCompressed
            ))
        }
        var result = Data([0x80 | opcode.rawValue, UInt8(min(payload.count, 125))])
        result.append(payload)
        return .success(result)
    }

    func updateCompression(supports: Bool) {
        state.withLock { $0.compressionEnabled = supports }
    }

    func supportsCompression() -> Bool {
        state.withLock { $0.compressionEnabled }
    }

    func reset() {
        state.withLock {
            $0.bufferedData.removeAll(keepingCapacity: false)
            $0.resetCount += 1
        }
    }

    func clearWriteCalls() {
        state.withLock { $0.writeCalls.removeAll() }
    }
}

private final class RecordingCompressionHandler: CompressionHandler, @unchecked Sendable {
    private struct State {
        var isLoaded = false
        var resetCount = 0
        var compressCallCount = 0
    }

    private let state = Locked(State())
    private let rejectedSelection: String?

    init(rejectedSelection: String? = nil) {
        self.rejectedSelection = rejectedSelection
    }

    var isLoaded: Bool { state.withLock { $0.isLoaded } }
    var resetCount: Int { state.withLock { $0.resetCount } }
    var compressCallCount: Int { state.withLock { $0.compressCallCount } }

    func load(headers: [String: String]) -> Bool {
        let selection = WebSocketHandshake.header(
            named: "Sec-WebSocket-Extensions",
            in: headers
        )
        let isRejected = rejectedSelection.map { selection?.contains($0) == true } ?? false
        let isLoaded = selection?.localizedCaseInsensitiveContains("permessage-deflate") == true
            && !isRejected
        state.withLock { $0.isLoaded = isLoaded }
        return isLoaded
    }

    func reset() {
        state.withLock {
            $0.isLoaded = false
            $0.resetCount += 1
        }
    }

    func decompress(data: Data, isFinal: Bool) throws -> Data {
        data
    }

    func compress(data: Data) -> Data? {
        state.withLock { state in
            state.compressCallCount += 1
            guard state.isLoaded else { return nil }
            var compressed = Data([0xCC])
            compressed.append(data)
            return compressed
        }
    }

    func clearCompressCallCount() {
        state.withLock { $0.compressCallCount = 0 }
    }
}

private final class AcceptingHeaderValidator: HeaderValidator, Sendable {
    func validate(headers: [String: String], key: String) -> Error? { nil }
}

private final class EngineEventRecorder: EngineDelegate, @unchecked Sendable {
    private let storage = Locked([EngineEventSnapshot]())

    var events: [EngineEventSnapshot] { storage.withLock { $0 } }

    func didReceive(event: WebSocketEvent) {
        storage.withLock { $0.append(EngineEventSnapshot(event)) }
    }

    func clear() {
        storage.withLock { $0.removeAll() }
    }
}

private enum EngineEventSnapshot: Sendable, Equatable {
    case connected
    case disconnected(String, UInt16)
    case text(String)
    case error
    case cancelled
    case peerClosed
    case other

    init(_ event: WebSocketEvent) {
        switch event {
        case .connected:
            self = .connected
        case .disconnected(let reason, let code):
            self = .disconnected(reason, code)
        case .text(let string):
            self = .text(string)
        case .error:
            self = .error
        case .cancelled:
            self = .cancelled
        case .peerClosed:
            self = .peerClosed
        case .binary, .pong, .ping, .viabilityChanged, .reconnectSuggested:
            self = .other
        }
    }

    var isConnected: Bool { self == .connected }
}

// MARK: - WebSocket callback collaborators

private final class CallbackTestEngine: Engine, @unchecked Sendable {
    private let delegate = Locked(WeakReference<any EngineDelegate>())

    func register(delegate: EngineDelegate) {
        self.delegate.withLock { $0 = WeakReference(delegate) }
    }

    func start(request: URLRequest) {}
    func stop(closeCode: UInt16) {}
    func forceStop() {}

    func write(data: Data, opcode: FrameOpCode, completion: (@Sendable () -> Void)?) {
        completion?()
    }

    func write(string: String, completion: (@Sendable () -> Void)?) {
        completion?()
    }

    func emit(_ event: WebSocketEvent) {
        delegate.withLock { $0.value }?.didReceive(event: event)
    }
}

private final class QueueProbe: @unchecked Sendable {
    private let key = DispatchSpecificKey<Bool>()

    init(queue: DispatchQueue) {
        queue.setSpecific(key: key, value: true)
    }

    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }
}

private final class CallbackWebSocketDelegate: WebSocketDelegate, @unchecked Sendable {
    private let deliveries: Locked<[String]>
    private let queueProbe: QueueProbe

    init(deliveries: Locked<[String]>, queueProbe: QueueProbe) {
        self.deliveries = deliveries
        self.queueProbe = queueProbe
    }

    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        let value = event.textValue ?? "unexpected"
        deliveries.withLock {
            $0.append("delegate:\(value):\(queueProbe.isCurrent)")
        }
    }
}

private extension WebSocketEvent {
    var textValue: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }
}

// MARK: - Test data and async polling

private let testRequest = URLRequest(url: URL(string: "ws://example.com/socket")!)

private func validResponseHeaders(
    key: String,
    extensionSelection: String? = nil
) -> [String: String] {
    var headers = [
        "Upgrade": "websocket",
        "Connection": "Upgrade",
        "Sec-WebSocket-Accept": WebSocketHandshake.acceptValue(forKey: key),
    ]
    if let extensionSelection {
        headers["Sec-WebSocket-Extensions"] = extensionSelection
    }
    return headers
}

private func validHTTPResponse(key: String) -> String {
    """
    HTTP/1.1 101 Switching Protocols\r
    Upgrade: websocket\r
    Connection: Upgrade\r
    Sec-WebSocket-Accept: \(WebSocketHandshake.acceptValue(forKey: key))\r
    \r\n
    """
}

private func httpHeader(named name: String, in message: String) -> String? {
    for line in message.components(separatedBy: "\r\n").dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].caseInsensitiveCompare(name) == .orderedSame {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

private func serverFrame(opcode: FrameOpCode, payload: Data) -> Data {
    try! WSFramer(isServer: true).createWriteFrameResult(
        opcode: opcode,
        payload: payload,
        isCompressed: false
    ).get()
}

private func makeClosePayload(code: UInt16) -> Data {
    var bytes = [UInt8](repeating: 0, count: 2)
    writeUint16(&bytes, offset: 0, value: code)
    return Data(bytes)
}

private func eventually(
    timeout: TimeInterval = 1,
    condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
    }
    try #require(condition(), "Timed out waiting for asynchronous state")
}

private func settle(for interval: TimeInterval = 0.02) async {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        await Task.yield()
    }
}
