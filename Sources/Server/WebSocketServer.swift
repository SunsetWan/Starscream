//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  WebSocketServer.swift
//  Starscream
//
//  Created by Dalton Cherry on 4/5/19.
//  Copyright © 2019 Vluxe. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

#if canImport(Network)
import Foundation
import Network

public enum ServerConnectionError: Error, Sendable {
    case notOpen
    case invalidUpgradeResponse
}

/// WebSocketServer is a Network.framework implementation of a WebSocket server.
///
/// Listener callbacks and connection callbacks may arrive on different queues. All mutable server
/// state is kept inside `Locked`, which is the safety invariant for this Sendable conformance.
@available(watchOS, unavailable)
@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
public final class WebSocketServer: Server, ConnectionDelegate, @unchecked Sendable {
    private struct State {
        var connections = [String: ServerConnection]()
        var listener: NWListener?
        var onEvent: ((ServerEvent) -> Void)?
    }

    private let state = Locked(State())
    private let queue = DispatchQueue(label: "com.vluxe.starscream.server.networkstream")
    private let callbackQueue = DispatchQueue(label: "com.vluxe.starscream.server.callbacks")

    public var onEvent: ((ServerEvent) -> Void)? {
        get { state.withLock { $0.onEvent } }
        set { state.withLock { $0.onEvent = newValue } }
    }

    public init() {}

    public func start(address: String, port: UInt16) -> Error? {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host.name(address, nil),
            port: endpointPort
        )

        guard let listener = try? NWListener(using: parameters, on: endpointPort) else {
            return WSError(
                type: .serverError,
                message: "unable to start the listener at: \(address):\(port)",
                code: 0
            )
        }
        listener.newConnectionHandler = { [weak self] networkConnection in
            guard let self else {
                networkConnection.cancel()
                return
            }
            let connection = ServerConnection(transport: TCPTransport(connection: networkConnection))
            connection.delegate = self
            self.register(connection)
        }
        state.withLock { $0.listener = listener }
        listener.start(queue: queue)
        return nil
    }

    public func didReceive(event: ServerEvent) {
        if case .disconnected(let connection, _, _) = event,
           let serverConnection = connection as? ServerConnection {
            state.withLock { $0.connections.removeValue(forKey: serverConnection.uuid) }
        }
        let delivery = ServerEventDelivery(event)
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.state.withLock { $0.onEvent }?(delivery.event)
        }
    }

    func register(_ connection: ServerConnection) {
        state.withLock { $0.connections[connection.uuid] = connection }
    }

    var connectionCount: Int {
        state.withLock { $0.connections.count }
    }
}

/// A server-side RFC 6455 connection.
///
/// Input and protocol events are serialized by `inputQueue`, writes by `outputQueue`, and the small
/// amount of state observed by both queues is protected by `Locked`. Those invariants are why this
/// callback-driven class can safely cross Network.framework's Sendable closures.
@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
public final class ServerConnection: Connection, HTTPServerDelegate, FramerEventClient,
    FrameCollectorDelegate, TransportEventClient, @unchecked Sendable {

    private enum Phase {
        case handshaking
        case upgrading
        case open
        case closing
        case closed
    }

    private struct CloseContext {
        let reason: String
        let code: UInt16
    }

    private struct State {
        var phase: Phase = .handshaking
        var pendingData = Data()
        var closeContext: CloseContext?
        var closeGeneration: UInt64 = 0
        var delegate = WeakReference<any ConnectionDelegate>()
        var onEvent: ((ConnectionEvent) -> Void)?
    }

    let transport: any Transport
    private let httpHandler: any HTTPServerHandler
    private let framer: any Framer
    private let frameHandler = FrameCollector()
    private let state = Locked(State())
    private let inputQueue: DispatchQueue
    private let outputQueue: DispatchQueue
    private let id: String
    private let closeTimeout: TimeInterval

    public var onEvent: ((ConnectionEvent) -> Void)? {
        get { state.withLock { $0.onEvent } }
        set { state.withLock { $0.onEvent = newValue } }
    }

    public var delegate: ConnectionDelegate? {
        get { state.withLock { $0.delegate.value } }
        set { state.withLock { $0.delegate = WeakReference(newValue) } }
    }

    var uuid: String { id }

    init(
        transport: any Transport,
        httpHandler: any HTTPServerHandler = FoundationHTTPServerHandler(),
        framer: any Framer = WSFramer(isServer: true),
        closeTimeout: TimeInterval = 5
    ) {
        let id = UUID().uuidString
        self.id = id
        self.transport = transport
        self.httpHandler = httpHandler
        self.framer = framer
        self.closeTimeout = max(0, closeTimeout)
        inputQueue = DispatchQueue(label: "com.vluxe.starscream.server.connection.input.\(id)")
        outputQueue = DispatchQueue(label: "com.vluxe.starscream.server.connection.output.\(id)")

        transport.register(delegate: self)
        httpHandler.register(delegate: self)
        framer.register(delegate: self)
        frameHandler.delegate = self
    }

    public func write(data: Data, opcode: FrameOpCode) {
        write(data: data, opcode: opcode) { [weak self] error in
            guard let error else { return }
            self?.inputQueue.async { [weak self] in
                self?.emit(error: error)
            }
        }
    }

    public func write(
        data: Data,
        opcode: FrameOpCode,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let completion = CompletionOnce(completion)
        outputQueue.async { [weak self] in
            guard let self else {
                completion.call(ServerConnectionError.notOpen)
                return
            }
            if opcode == .connectionClose {
                self.performLocalCloseWrite(data: data, completion: completion)
            } else {
                guard self.state.withLock({ $0.phase == .open }) else {
                    completion.call(ServerConnectionError.notOpen)
                    return
                }
                self.performFrameWrite(data: data, opcode: opcode, completion: completion.call)
            }
        }
    }

    // MARK: - TransportEventClient

    public func connectionChanged(state: ConnectionState) {
        inputQueue.async { [weak self] in
            self?.handleConnectionState(state)
        }
    }

    private func handleConnectionState(_ connectionState: ConnectionState) {
        switch connectionState {
        case .connected, .waiting, .viability, .shouldReconnect:
            break
        case .receive(let data):
            enum Destination {
                case http
                case frame
                case buffered
                case ignored
            }
            let destination = state.withLock { state -> Destination in
                switch state.phase {
                case .handshaking:
                    return .http
                case .upgrading:
                    state.pendingData.append(data)
                    return .buffered
                case .open, .closing:
                    return .frame
                case .closed:
                    return .ignored
                }
            }
            switch destination {
            case .http:
                httpHandler.parse(data: data)
            case .frame:
                framer.add(data: data)
            case .buffered, .ignored:
                break
            }
        case .failed(let error):
            if let error { emit(error: error) }
            finishDisconnect(reason: "Connection failed", code: 1006)
        case .cancelled:
            finishDisconnect(reason: "Connection cancelled", code: 1006)
        case .peerClosed:
            let context = state.withLock { $0.closeContext }
                ?? CloseContext(reason: "Connection closed by peer", code: 1006)
            finishDisconnect(reason: context.reason, code: context.code)
        }
    }

    // MARK: - HTTPServerDelegate

    public func didReceive(event: HTTPEvent) {
        switch event {
        case .success(let headers, let leftover):
            let shouldUpgrade = state.withLock { state -> Bool in
                guard state.phase == .handshaking else { return false }
                state.phase = .upgrading
                state.pendingData.append(leftover)
                return true
            }
            guard shouldUpgrade else { return }

            let response = httpHandler.createResponse(headers: [:])
            guard !response.isEmpty else {
                emit(error: ServerConnectionError.invalidUpgradeResponse)
                finishDisconnect(reason: "Invalid WebSocket upgrade response", code: 1006)
                return
            }
            writeRaw(response) { [weak self] error in
                self?.inputQueue.async { [weak self] in
                    self?.finishUpgrade(headers: headers, error: error)
                }
            }
        case .failure(let error):
            if isUnsupportedWebSocketVersion(error) {
                emit(error: error)
                writeRaw(Self.unsupportedVersionResponse) { [weak self] writeError in
                    self?.inputQueue.async { [weak self] in
                        guard let self else { return }
                        if let writeError { self.emit(error: writeError) }
                        self.finishDisconnect(reason: "Unsupported WebSocket version", code: 1006)
                    }
                }
            } else {
                emit(error: error)
                finishDisconnect(reason: "Invalid WebSocket upgrade request", code: 1006)
            }
        }
    }

    private func finishUpgrade(headers: [String: String], error: Error?) {
        if let error {
            emit(error: error)
            finishDisconnect(reason: "Failed to write WebSocket upgrade response", code: 1006)
            return
        }
        let pendingData = state.withLock { state -> Data? in
            guard state.phase == .upgrading else { return nil }
            state.phase = .open
            defer { state.pendingData.removeAll(keepingCapacity: true) }
            return state.pendingData
        }
        guard let pendingData else { return }
        emit(connectionEvent: .connected(headers), serverEvent: .connected(self, headers))
        if !pendingData.isEmpty {
            framer.add(data: pendingData)
        }
    }

    // MARK: - FramerEventClient

    public func frameProcessed(event: FrameEvent) {
        inputQueue.async { [weak self] in
            self?.handleFrameEvent(event)
        }
    }

    private func handleFrameEvent(_ event: FrameEvent) {
        let phase = state.withLock { $0.phase }
        guard phase == .open || phase == .closing else { return }
        switch event {
        case .frame(let frame):
            if frame.opcode == .connectionClose {
                handlePeerClose(frame, phase: phase)
            } else if phase == .open {
                frameHandler.add(frame: frame)
            } else if frame.opcode == .ping {
                writeFrame(data: frame.payload, opcode: .pong) { _ in }
            }
        case .error(let error):
            if phase == .open {
                failWebSocket(with: error)
            } else {
                finishDisconnect(reason: "WebSocket protocol error while closing", code: 1006)
            }
        }
    }

    // MARK: - FrameCollectorDelegate

    public func didForm(event: FrameCollector.Event) {
        guard state.withLock({ $0.phase == .open }) else { return }
        switch event {
        case .text(let string):
            emit(connectionEvent: .text(string), serverEvent: .text(self, string))
        case .binary(let data):
            emit(connectionEvent: .binary(data), serverEvent: .binary(self, data))
        case .pong(let data):
            emit(connectionEvent: .pong(data), serverEvent: .pong(self, data))
        case .ping(let data):
            emit(connectionEvent: .ping(data), serverEvent: .ping(self, data))
            writeFrame(data: data ?? Data(), opcode: .pong) { [weak self] error in
                guard let error else { return }
                self?.inputQueue.async { [weak self] in
                    self?.failWebSocket(with: error)
                }
            }
        case .closed(let reason, let code):
            initiateClose(reason: reason, code: code, payload: closePayload(code: code, reason: Data(reason.utf8)))
        case .error(let error):
            failWebSocket(with: error)
        }
    }

    public func decompress(data: Data, isFinal: Bool) throws -> Data {
        throw WSError(
            type: .protocolError,
            message: "compression was not negotiated for this server connection",
            code: CloseCode.protocolError.rawValue
        )
    }

    private func handlePeerClose(_ frame: Frame, phase: Phase) {
        let reason: String
        if frame.payload.isEmpty {
            reason = "Connection closed by peer"
        } else if let decodedReason = String(data: frame.payload, encoding: .utf8) {
            reason = decodedReason
        } else {
            failWebSocket(with: WSError(
                type: .protocolError,
                message: "close reason is not valid UTF-8",
                code: CloseCode.encoding.rawValue
            ))
            return
        }
        if phase == .closing {
            finishDisconnect(reason: reason, code: frame.closeCode)
            return
        }

        let payload = frame.closeCode == CloseCode.noStatusReceived.rawValue
            ? Data()
            : closePayload(code: frame.closeCode, reason: frame.payload)
        initiateClose(reason: reason, code: frame.closeCode, payload: payload)
    }

    private func failWebSocket(with error: Error) {
        emit(error: error)
        let code = sendableCloseCode(from: error)
        initiateClose(
            reason: "WebSocket protocol error",
            code: code,
            payload: closePayload(code: code, reason: Data())
        )
    }

    private func initiateClose(reason: String, code: UInt16, payload: Data) {
        let generation = state.withLock { state -> UInt64? in
            guard state.phase == .open else { return nil }
            state.phase = .closing
            state.closeContext = CloseContext(reason: reason, code: code)
            state.closeGeneration &+= 1
            return state.closeGeneration
        }
        guard let generation else { return }

        writeFrame(data: payload, opcode: .connectionClose) { [weak self] error in
            self?.inputQueue.async { [weak self] in
                guard let self else { return }
                if let error { self.emit(error: error) }
                self.finishDisconnect(reason: reason, code: code)
            }
        }
        scheduleCloseTimeout(generation: generation)
    }

    private func finishDisconnect(reason: String, code: UInt16) {
        let callbacks = state.withLock { state -> (ConnectionDelegate?, ((ConnectionEvent) -> Void)?)? in
            guard state.phase != .closed else { return nil }
            state.phase = .closed
            state.closeGeneration &+= 1
            state.pendingData.removeAll(keepingCapacity: false)
            return (state.delegate.value, state.onEvent)
        }
        guard let callbacks else { return }
        transport.disconnect()
        callbacks.0?.didReceive(event: .disconnected(self, reason, code))
        callbacks.1?(.disconnected(reason, code))
    }

    private func emit(error: Error) {
        let callback = state.withLock { $0.onEvent }
        callback?(.error(error))
    }

    private func emit(connectionEvent: ConnectionEvent, serverEvent: ServerEvent) {
        let callbacks = state.withLock { ($0.delegate.value, $0.onEvent) }
        callbacks.0?.didReceive(event: serverEvent)
        callbacks.1?(connectionEvent)
    }

    private func writeRaw(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let completion = CompletionOnce(completion)
        outputQueue.async { [weak self] in
            guard let self else {
                completion.call(ServerConnectionError.notOpen)
                return
            }
            self.transport.write(data: data, completion: completion.call)
        }
    }

    private func writeFrame(
        data: Data,
        opcode: FrameOpCode,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let completion = CompletionOnce(completion)
        outputQueue.async { [weak self] in
            guard let self else {
                completion.call(ServerConnectionError.notOpen)
                return
            }
            self.performFrameWrite(data: data, opcode: opcode, completion: completion.call)
        }
    }

    /// Must only be called on `outputQueue`, so validation and transport ordering stay atomic with
    /// respect to every other server write.
    private func performFrameWrite(
        data: Data,
        opcode: FrameOpCode,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        switch framer.createWriteFrameResult(
            opcode: opcode,
            payload: data,
            isCompressed: false
        ) {
        case .success(let frame):
            transport.write(data: frame, completion: completion)
        case .failure(let error):
            completion(error)
        }
    }

    /// Sends an application-initiated close exactly once, then waits for the peer response or a
    /// bounded timeout. This is distinct from echoing a peer close, which disconnects after the
    /// echo has reached the transport.
    private func performLocalCloseWrite(data: Data, completion: CompletionOnce) {
        switch framer.createWriteFrameResult(
            opcode: .connectionClose,
            payload: data,
            isCompressed: false
        ) {
        case .failure(let error):
            completion.call(error)
        case .success(let frame):
            let closeContext = Self.closeContext(from: data)
            let generation = state.withLock { state -> UInt64? in
                guard state.phase == .open else { return nil }
                state.phase = .closing
                state.closeContext = closeContext
                state.closeGeneration &+= 1
                return state.closeGeneration
            }
            guard let generation else {
                completion.call(ServerConnectionError.notOpen)
                return
            }
            transport.write(data: frame) { [weak self] error in
                completion.call(error)
                guard let self else { return }
                self.inputQueue.async { [weak self] in
                    guard let self else { return }
                    if let error {
                        self.emit(error: error)
                        self.finishDisconnect(reason: "Failed to write WebSocket close", code: 1006)
                    }
                }
            }
            inputQueue.async { [weak self] in
                self?.scheduleCloseTimeout(generation: generation)
            }
        }
    }

    private func scheduleCloseTimeout(generation: UInt64) {
        inputQueue.asyncAfter(deadline: .now() + closeTimeout) { [weak self] in
            guard let self else { return }
            let context = self.state.withLock { state -> CloseContext? in
                guard state.phase == .closing, state.closeGeneration == generation else { return nil }
                return state.closeContext
            }
            guard let context else { return }
            self.finishDisconnect(reason: "Close handshake timed out", code: context.code)
        }
    }

    private static func closeContext(from payload: Data) -> CloseContext {
        guard payload.count >= 2 else {
            return CloseContext(reason: "", code: CloseCode.noStatusReceived.rawValue)
        }
        let bytes = [UInt8](payload)
        let code = bytes.readUint16(offset: 0)
        let reason = String(data: Data(bytes.dropFirst(2)), encoding: .utf8) ?? ""
        return CloseContext(reason: reason, code: code)
    }

    private func isUnsupportedWebSocketVersion(_ error: Error) -> Bool {
        guard case HTTPUpgradeError.invalidHandshake(let validationError) = error,
              case WebSocketHandshake.ValidationError.invalidHeader(let name) = validationError else {
            return false
        }
        return name.caseInsensitiveCompare(HTTPWSHeader.versionName) == .orderedSame
    }

    private static let unsupportedVersionResponse = Data((
        "HTTP/1.1 426 Upgrade Required\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "Connection: close\r\n\r\n"
    ).utf8)

    private func closePayload(code: UInt16, reason: Data) -> Data {
        var bytes = [UInt8](repeating: 0, count: MemoryLayout<UInt16>.size)
        writeUint16(&bytes, offset: 0, value: code)
        var payload = Data(bytes)
        payload.append(reason)
        return payload
    }

    private func sendableCloseCode(from error: Error) -> UInt16 {
        guard let webSocketError = error as? WSError else {
            return CloseCode.internalServerError.rawValue
        }
        let code = webSocketError.code
        if (1000...1014).contains(code), code != 1004, code != 1005, code != 1006 {
            return code
        }
        if (3000...4999).contains(code) {
            return code
        }
        return CloseCode.internalServerError.rawValue
    }
}

/// `ServerEvent` retains an existential `Connection` for source compatibility. Delivery is boxed
/// while crossing the server's private serial callback queue; the connection implementations
/// supplied by Starscream are internally synchronized.
private final class ServerEventDelivery: @unchecked Sendable {
    let event: ServerEvent

    init(_ event: ServerEvent) {
        self.event = event
    }
}

/// Guards all public and internal write completions against accidental duplicate transport calls.
private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private let completion: @Sendable (Error?) -> Void

    init(_ completion: @escaping @Sendable (Error?) -> Void) {
        self.completion = completion
    }

    func call(_ error: Error?) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        lock.unlock()
        completion(error)
    }
}
#endif
