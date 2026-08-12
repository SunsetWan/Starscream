//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  WSEngine.swift
//  Starscream
//
//  Created by Dalton Cherry on 6/15/19
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

import Foundation

/// The custom RFC 6455 engine.
///
/// All mutable connection state, parser calls, compression calls, and delegate delivery are
/// confined to `eventQueue`. The unchecked conformance bridges callback-based system APIs whose
/// queue isolation cannot be expressed in Swift's type system; public entry points only enqueue
/// work and synchronous reads use the same queue.
public final class WSEngine: Engine, TransportEventClient, FramerEventClient,
FrameCollectorDelegate, HTTPHandlerDelegate, @unchecked Sendable {
    private enum Phase: Equatable {
        case idle
        case connecting
        case open
        case closing
        case closed
    }

    /// The collaborator protocols predate connection-scoped callbacks, so each registration gets
    /// a proxy carrying the attempt that installed it. A collaborator that retained an older
    /// delegate can then finish its work without mutating a newer connection.
    private final class TransportDelegateProxy: TransportEventClient {
        weak var engine: WSEngine?
        let generation: UInt64

        init(engine: WSEngine, generation: UInt64) {
            self.engine = engine
            self.generation = generation
        }

        func connectionChanged(state: ConnectionState) {
            engine?.connectionChanged(state: state, generation: generation)
        }
    }

    private final class HTTPDelegateProxy: HTTPHandlerDelegate {
        weak var engine: WSEngine?
        let generation: UInt64

        init(engine: WSEngine, generation: UInt64) {
            self.engine = engine
            self.generation = generation
        }

        func didReceiveHTTP(event: HTTPEvent) {
            engine?.didReceiveHTTP(event: event, generation: generation)
        }
    }

    private final class FramerDelegateProxy: FramerEventClient {
        weak var engine: WSEngine?
        let generation: UInt64

        init(engine: WSEngine, generation: UInt64) {
            self.engine = engine
            self.generation = generation
        }

        func frameProcessed(event: FrameEvent) {
            engine?.frameProcessed(event: event, generation: generation)
        }
    }

    private final class CollectorDelegateProxy: FrameCollectorDelegate {
        weak var engine: WSEngine?
        let generation: UInt64

        init(engine: WSEngine, generation: UInt64) {
            self.engine = engine
            self.generation = generation
        }

        func didForm(event: FrameCollector.Event) {
            engine?.didForm(event: event, generation: generation)
        }

        func decompress(data: Data, isFinal: Bool) throws -> Data {
            guard let engine else {
                throw WSError(
                    type: .compressionError,
                    message: "the WebSocket connection attempt has ended",
                    code: CloseCode.protocolError.rawValue
                )
            }
            return try engine.decompress(data: data, isFinal: isFinal, generation: generation)
        }
    }

    private struct State {
        var phase: Phase = .idle
        var request: URLRequest?
        var offer: WebSocketHandshake.ClientOffer?
        var delegate = WeakReference<any EngineDelegate>()
        var respondToPingWithPong = true
        var attemptGeneration: UInt64 = 0
        var closeGeneration: UInt64 = 0
        var closeCode = CloseCode.normal.rawValue
        var receivedClose = false
        var terminalEventDelivered = false
        var transportDelegate: TransportDelegateProxy?
        var httpDelegate: HTTPDelegateProxy?
        var framerDelegate: FramerDelegateProxy?
        var collectorDelegate: CollectorDelegateProxy?
    }

    private let transport: any Transport
    private let framer: any Framer
    private let httpHandler: any HTTPHandler
    private let compressionHandler: (any CompressionHandler)?
    private let certPinner: (any CertificatePinning)?
    private let headerChecker: any HeaderValidator
    private let frameHandler = FrameCollector()
    private let eventQueue = DispatchQueue(label: "com.vluxe.starscream.engine")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let closeTimeout: TimeInterval
    private var state = State()

    public var respondToPingWithPong: Bool {
        get { syncOnEventQueue { state.respondToPingWithPong } }
        set { performOnEventQueue { self.state.respondToPingWithPong = newValue } }
    }

    public convenience init(
        transport: any Transport,
        certPinner: (any CertificatePinning)? = nil,
        headerValidator: any HeaderValidator = FoundationSecurity(),
        httpHandler: any HTTPHandler = FoundationHTTPHandler(),
        framer: any Framer = WSFramer(),
        compressionHandler: (any CompressionHandler)? = nil
    ) {
        self.init(
            transport: transport,
            certPinner: certPinner,
            headerValidator: headerValidator,
            httpHandler: httpHandler,
            framer: framer,
            compressionHandler: compressionHandler,
            closeTimeout: 5
        )
    }

    public init(
        transport: any Transport,
        certPinner: (any CertificatePinning)? = nil,
        headerValidator: any HeaderValidator = FoundationSecurity(),
        httpHandler: any HTTPHandler = FoundationHTTPHandler(),
        framer: any Framer = WSFramer(),
        compressionHandler: (any CompressionHandler)? = nil,
        closeTimeout: TimeInterval
    ) {
        self.transport = transport
        self.framer = framer
        self.httpHandler = httpHandler
        self.certPinner = certPinner
        self.headerChecker = headerValidator
        self.compressionHandler = compressionHandler
        self.closeTimeout = max(0, closeTimeout)
        eventQueue.setSpecific(key: queueKey, value: 1)
    }

    public func register(delegate: any EngineDelegate) {
        performOnEventQueue {
            self.state.delegate = WeakReference(delegate)
        }
    }

    public func start(request: URLRequest) {
        performOnEventQueue {
            guard self.state.phase == .idle || self.state.phase == .closed else { return }
            self.state.attemptGeneration &+= 1
            let generation = self.state.attemptGeneration
            self.resetConnectionState()
            self.state.phase = .connecting
            self.state.request = request
            guard let url = request.url else {
                self.failBeforeUpgrade(WSError(
                    type: .protocolError,
                    message: "a WebSocket request requires a URL",
                    code: CloseCode.protocolError.rawValue
                ), generation: generation)
                return
            }

            self.installAttemptDelegates(generation: generation)
            self.transport.connect(
                url: url,
                timeout: request.timeoutInterval,
                certificatePinning: self.certPinner
            )
        }
    }

    public func stop(closeCode: UInt16 = CloseCode.normal.rawValue) {
        performOnEventQueue {
            switch self.state.phase {
            case .open:
                self.beginClosing(
                    code: closeCode,
                    reason: nil,
                    generation: self.state.attemptGeneration
                )
            case .connecting:
                self.state.phase = .closed
                self.resetConnectionModules()
                self.releaseAttemptDelegates()
                self.transport.disconnect()
            case .idle, .closing, .closed:
                break
            }
        }
    }

    public func forceStop() {
        performOnEventQueue {
            guard self.state.phase != .closed else { return }
            self.state.phase = .closed
            self.resetConnectionModules()
            self.releaseAttemptDelegates()
            self.transport.disconnect()
            self.deliverTerminal(.cancelled)
        }
    }

    public func write(string: String, completion: (@Sendable () -> Void)?) {
        guard let data = string.data(using: .utf8) else {
            completion?()
            return
        }
        write(data: data, opcode: .textFrame, completion: completion)
    }

    public func write(
        data: Data,
        opcode: FrameOpCode,
        completion: (@Sendable () -> Void)?
    ) {
        performOnEventQueue {
            guard self.state.phase == .open else {
                completion?()
                return
            }
            if opcode == .textFrame, String(data: data, encoding: .utf8) == nil {
                let error = WSError(
                    type: .protocolError,
                    message: "text messages must contain valid UTF-8",
                    code: CloseCode.encoding.rawValue
                )
                completion?()
                self.handleProtocolError(error, generation: self.state.attemptGeneration)
                return
            }
            self.sendFrame(data: data, opcode: opcode, allowCompression: true, completion: completion)
        }
    }

    // MARK: - TransportEventClient

    public func connectionChanged(state: ConnectionState) {
        performOnEventQueue {
            self.processConnectionState(state, generation: self.state.attemptGeneration)
        }
    }

    private func connectionChanged(state: ConnectionState, generation: UInt64) {
        performOnEventQueue {
            self.processConnectionState(state, generation: generation)
        }
    }

    private func processConnectionState(_ connectionState: ConnectionState, generation: UInt64) {
        guard isCurrentAttempt(generation) else { return }
        switch connectionState {
        case .connected:
            guard state.phase == .connecting,
                  state.offer == nil,
                  let request = state.request else { return }
            let key = HTTPWSHeader.generateWebSocketKey()
            let upgradedRequest = HTTPWSHeader.createUpgrade(
                request: request,
                supportsCompression: compressionHandler != nil,
                secKeyValue: key
            )
            do {
                state.offer = try WebSocketHandshake.clientOffer(for: upgradedRequest, key: key)
            } catch {
                failBeforeUpgrade(error, generation: generation)
                return
            }
            let data = httpHandler.convert(request: upgradedRequest)
            guard !data.isEmpty else {
                failBeforeUpgrade(HTTPUpgradeError.invalidData, generation: generation)
                return
            }
            transport.write(data: data) { [weak self] error in
                guard let self, let error else { return }
                self.performOnEventQueue {
                    self.failBeforeUpgrade(error, generation: generation)
                }
            }

        case .waiting:
            break

        case .failed(let error):
            failConnection(error ?? WSError(
                type: .serverError,
                message: "the transport failed",
                code: CloseCode.abnormalClosure
            ), generation: generation)

        case .viability(let isViable):
            broadcast(.viabilityChanged(isViable))

        case .shouldReconnect(let status):
            broadcast(.reconnectSuggested(status))

        case .receive(let data):
            switch state.phase {
            case .connecting:
                _ = httpHandler.parse(data: data)
            case .open, .closing:
                framer.add(data: data)
            case .idle, .closed:
                break
            }

        case .cancelled:
            guard state.phase != .closed else { return }
            state.phase = .closed
            resetConnectionModules()
            releaseAttemptDelegates()
            deliverTerminal(.cancelled)

        case .peerClosed:
            guard state.phase != .closed else { return }
            state.phase = .closed
            resetConnectionModules()
            releaseAttemptDelegates()
            deliverTerminal(.peerClosed)
        }
    }

    // MARK: - HTTPHandlerDelegate

    public func didReceiveHTTP(event: HTTPEvent) {
        performOnEventQueue {
            self.processHTTPEvent(event, generation: self.state.attemptGeneration)
        }
    }

    private func didReceiveHTTP(event: HTTPEvent, generation: UInt64) {
        performOnEventQueue {
            self.processHTTPEvent(event, generation: generation)
        }
    }

    private func processHTTPEvent(_ event: HTTPEvent, generation: UInt64) {
        guard isCurrentAttempt(generation), state.phase == .connecting else { return }
        switch event {
        case .success(let headers, let leftover):
            guard let offer = state.offer else {
                failBeforeUpgrade(HTTPUpgradeError.invalidData, generation: generation)
                return
            }
            do {
                try WebSocketHandshake.validateServerResponse(
                    statusCode: HTTPWSHeader.switchProtocolCode,
                    headers: headers,
                    offer: offer
                )
            } catch let validationError as WebSocketHandshake.ValidationError {
                failBeforeUpgrade(
                    HTTPUpgradeError.invalidHandshake(validationError),
                    generation: generation
                )
                return
            } catch {
                failBeforeUpgrade(error, generation: generation)
                return
            }
            if let error = headerChecker.validate(headers: headers, key: offer.key) {
                failBeforeUpgrade(error, generation: generation)
                return
            }

            let selectedExtension = WebSocketHandshake.header(
                named: HTTPWSHeader.extensionName,
                in: headers
            )
            let compressionEnabled: Bool
            if let selectedExtension {
                guard let compressionHandler,
                      compressionHandler.load(headers: headers) else {
                    failBeforeUpgrade(
                        HTTPUpgradeError.invalidHandshake(
                            .invalidExtension(selectedExtension)
                        ),
                        generation: generation
                    )
                    return
                }
                compressionEnabled = true
            } else {
                compressionHandler?.reset()
                compressionEnabled = false
            }

            framer.updateCompression(supports: compressionEnabled)
            state.phase = .open
            if let url = state.request?.url {
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
            broadcast(.connected(headers))
            if !leftover.isEmpty {
                framer.add(data: leftover)
            }

        case .failure(let error):
            failBeforeUpgrade(error, generation: generation)
        }
    }

    // MARK: - FramerEventClient

    public func frameProcessed(event: FrameEvent) {
        performOnEventQueue {
            self.processFrameEvent(event, generation: self.state.attemptGeneration)
        }
    }

    private func frameProcessed(event: FrameEvent, generation: UInt64) {
        performOnEventQueue {
            self.processFrameEvent(event, generation: generation)
        }
    }

    private func processFrameEvent(_ event: FrameEvent, generation: UInt64) {
        guard isCurrentAttempt(generation),
              state.phase == .open || state.phase == .closing else { return }
        switch event {
        case .frame(let frame):
            frameHandler.add(frame: frame)
        case .error(let error):
            handleProtocolError(error, generation: generation)
        }
    }

    // MARK: - FrameCollectorDelegate

    public func decompress(data: Data, isFinal: Bool) throws -> Data {
        try syncOnEventQueue {
            try self.decompress(
                data: data,
                isFinal: isFinal,
                generation: self.state.attemptGeneration
            )
        }
    }

    private func decompress(data: Data, isFinal: Bool, generation: UInt64) throws -> Data {
        guard isCurrentAttempt(generation),
              state.phase == .open || state.phase == .closing else {
            throw WSError(
                type: .compressionError,
                message: "the WebSocket connection attempt has ended",
                code: CloseCode.protocolError.rawValue
            )
        }
        guard let compressionHandler else {
            throw WSError(
                type: .compressionError,
                message: "received a compressed frame without a negotiated extension",
                code: CloseCode.protocolError.rawValue
            )
        }
        return try compressionHandler.decompress(data: data, isFinal: isFinal)
    }

    public func didForm(event: FrameCollector.Event) {
        performOnEventQueue {
            self.processCollectorEvent(event, generation: self.state.attemptGeneration)
        }
    }

    private func didForm(event: FrameCollector.Event, generation: UInt64) {
        performOnEventQueue {
            self.processCollectorEvent(event, generation: generation)
        }
    }

    private func processCollectorEvent(_ event: FrameCollector.Event, generation: UInt64) {
        guard isCurrentAttempt(generation) else { return }
        switch event {
        case .text(let string):
            guard state.phase == .open else { return }
            broadcast(.text(string))

        case .binary(let data):
            guard state.phase == .open else { return }
            broadcast(.binary(data))

        case .pong(let data):
            guard state.phase == .open else { return }
            broadcast(.pong(data))

        case .ping(let data):
            guard state.phase == .open || (state.phase == .closing && !state.receivedClose) else {
                return
            }
            broadcast(.ping(data))
            if state.respondToPingWithPong {
                sendFrame(
                    data: data ?? Data(),
                    opcode: .pong,
                    allowCompression: false,
                    completion: nil
                )
            }

        case .closed(let reason, let code):
            receiveClose(reason: reason, code: code, generation: generation)

        case .error(let error):
            handleProtocolError(error, generation: generation)
        }
    }

    private func receiveClose(reason: String, code: UInt16, generation: UInt64) {
        guard isCurrentAttempt(generation) else { return }
        state.receivedClose = true
        switch state.phase {
        case .open:
            state.phase = .closing
            state.closeCode = code
            deliverTerminal(.disconnected(reason, code))
            let payload = closePayload(code: code, reason: code == CloseCode.noStatusReceived.rawValue ? nil : reason)
            sendFrame(data: payload, opcode: .connectionClose, allowCompression: false) { [weak self] in
                guard let self else { return }
                self.performOnEventQueue {
                    self.finishDisconnect(generation: generation)
                }
            }
            scheduleCloseTimeout(generation: generation)

        case .closing:
            deliverTerminal(.disconnected(reason, code))
            finishDisconnect(generation: generation)

        case .idle, .connecting, .closed:
            break
        }
    }

    private func beginClosing(code: UInt16, reason: String?, generation: UInt64) {
        guard isCurrentAttempt(generation), state.phase == .open else { return }
        state.phase = .closing
        state.closeCode = code
        let payload = closePayload(code: code, reason: reason)
        sendFrame(data: payload, opcode: .connectionClose, allowCompression: false, completion: nil)
        scheduleCloseTimeout(generation: generation)
    }

    private func scheduleCloseTimeout(generation: UInt64) {
        guard isCurrentAttempt(generation) else { return }
        state.closeGeneration &+= 1
        let closeGeneration = state.closeGeneration
        eventQueue.asyncAfter(deadline: .now() + closeTimeout) { [weak self] in
            guard let self,
                  self.isCurrentAttempt(generation),
                  self.state.phase == .closing,
                  self.state.closeGeneration == closeGeneration else { return }
            self.deliverTerminal(.disconnected("close handshake timed out", self.state.closeCode))
            self.finishDisconnect(generation: generation)
        }
    }

    private func sendFrame(
        data: Data,
        opcode: FrameOpCode,
        allowCompression: Bool,
        completion: (@Sendable () -> Void)?
    ) {
        let generation = state.attemptGeneration
        let isDataFrame = opcode == .textFrame || opcode == .binaryFrame
        var payload = data
        var isCompressed = false
        if allowCompression,
           isDataFrame,
           framer.supportsCompression(),
           let compressed = compressionHandler?.compress(data: data) {
            payload = compressed
            isCompressed = true
        }

        switch framer.createWriteFrameResult(
            opcode: opcode,
            payload: payload,
            isCompressed: isCompressed
        ) {
        case .success(let frameData):
            transport.write(data: frameData) { [weak self] error in
                guard let self else {
                    completion?()
                    return
                }
                self.performOnEventQueue {
                    if self.isCurrentAttempt(generation), let error {
                        self.failConnection(error, generation: generation)
                    }
                    completion?()
                }
            }

        case .failure(let error):
            completion?()
            handleProtocolError(error, generation: generation)
        }
    }

    private func handleProtocolError(_ error: any Error, generation: UInt64) {
        guard isCurrentAttempt(generation) else { return }
        guard state.phase == .open || state.phase == .closing else {
            failBeforeUpgrade(error, generation: generation)
            return
        }
        broadcast(.error(error))
        guard state.phase == .open else {
            finishDisconnect(generation: generation)
            return
        }
        let closeCode = (error as? WSError)?.code ?? CloseCode.protocolError.rawValue
        beginClosing(code: closeCode, reason: nil, generation: generation)
    }

    private func failBeforeUpgrade(_ error: any Error, generation: UInt64) {
        guard isCurrentAttempt(generation), state.phase != .closed else { return }
        state.phase = .closed
        broadcast(.error(error))
        resetConnectionModules()
        releaseAttemptDelegates()
        transport.disconnect()
    }

    private func failConnection(_ error: any Error, generation: UInt64) {
        guard isCurrentAttempt(generation), state.phase != .closed else { return }
        broadcast(.error(error))
        state.phase = .closed
        resetConnectionModules()
        releaseAttemptDelegates()
        transport.disconnect()
    }

    private func finishDisconnect(generation: UInt64) {
        guard isCurrentAttempt(generation), state.phase != .closed else { return }
        state.phase = .closed
        resetConnectionModules()
        releaseAttemptDelegates()
        transport.disconnect()
    }

    private func closePayload(code: UInt16, reason: String?) -> Data {
        guard code != CloseCode.noStatusReceived.rawValue else { return Data() }
        var bytes = [UInt8](repeating: 0, count: MemoryLayout<UInt16>.size)
        writeUint16(&bytes, offset: 0, value: code)
        var payload = Data(bytes)
        if let reason {
            payload.append(Data(reason.utf8))
        }
        return payload
    }

    private func resetConnectionState() {
        releaseAttemptDelegates()
        state.closeGeneration &+= 1
        state.offer = nil
        state.receivedClose = false
        state.closeCode = CloseCode.normal.rawValue
        state.terminalEventDelivered = false
        resetConnectionModules()
    }

    private func installAttemptDelegates(generation: UInt64) {
        let transportDelegate = TransportDelegateProxy(engine: self, generation: generation)
        let httpDelegate = HTTPDelegateProxy(engine: self, generation: generation)
        let framerDelegate = FramerDelegateProxy(engine: self, generation: generation)
        let collectorDelegate = CollectorDelegateProxy(engine: self, generation: generation)
        state.transportDelegate = transportDelegate
        state.httpDelegate = httpDelegate
        state.framerDelegate = framerDelegate
        state.collectorDelegate = collectorDelegate
        transport.register(delegate: transportDelegate)
        httpHandler.register(delegate: httpDelegate)
        framer.register(delegate: framerDelegate)
        frameHandler.delegate = collectorDelegate
    }

    private func releaseAttemptDelegates() {
        state.transportDelegate = nil
        state.httpDelegate = nil
        state.framerDelegate = nil
        state.collectorDelegate = nil
        frameHandler.delegate = nil
    }

    private func isCurrentAttempt(_ generation: UInt64) -> Bool {
        state.attemptGeneration == generation
    }

    private func resetConnectionModules() {
        framer.reset()
        framer.updateCompression(supports: false)
        frameHandler.reset()
        compressionHandler?.reset()
        httpHandler.reset()
    }

    private func deliverTerminal(_ event: WebSocketEvent) {
        guard !state.terminalEventDelivered else { return }
        state.terminalEventDelivered = true
        broadcast(event)
    }

    private func broadcast(_ event: WebSocketEvent) {
        state.delegate.value?.didReceive(event: event)
    }

    private func performOnEventQueue(_ action: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            action()
        } else {
            eventQueue.async(execute: action)
        }
    }

    private func syncOnEventQueue<Result>(_ action: () throws -> Result) rethrows -> Result {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try action()
        }
        return try eventQueue.sync(execute: action)
    }
}

private extension CloseCode {
    /// 1006 is a local sentinel and must never be placed on the wire.
    static let abnormalClosure: UInt16 = 1006
}
