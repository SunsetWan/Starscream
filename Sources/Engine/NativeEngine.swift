//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  NativeEngine.swift
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
import Network
@preconcurrency import Security

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public class NativeEngine: NSObject, Engine, URLSessionDataDelegate, URLSessionWebSocketDelegate,
@unchecked Sendable {
    struct Connection: Sendable {
        let session: URLSession
        let task: URLSessionWebSocketTask
    }

    /// System operations are injected as a single value so lifecycle behavior can be tested
    /// deterministically without opening a socket. The live implementation remains URLSession.
    struct Dependencies: Sendable {
        var makeConnection: @Sendable (
            URLSessionConfiguration,
            NativeEngine,
            URLRequest
        ) -> Connection
        var resume: @Sendable (URLSessionWebSocketTask) -> Void
        var cancel: @Sendable (URLSessionWebSocketTask) -> Void
        var cancelWithCloseCode: @Sendable (
            URLSessionWebSocketTask,
            URLSessionWebSocketTask.CloseCode
        ) -> Void
        var invalidate: @Sendable (URLSession) -> Void
        var send: @Sendable (
            URLSessionWebSocketTask,
            URLSessionWebSocketTask.Message
        ) async throws -> Void
        var sendPing: @Sendable (URLSessionWebSocketTask) async throws -> Void
        var receive: @Sendable (
            URLSessionWebSocketTask
        ) async throws -> URLSessionWebSocketTask.Message

        static let live = Dependencies(
            makeConnection: { configuration, delegate, request in
                let session = URLSession(
                    configuration: configuration,
                    delegate: delegate,
                    delegateQueue: nil
                )
                return Connection(session: session, task: session.webSocketTask(with: request))
            },
            resume: { $0.resume() },
            cancel: { $0.cancel() },
            cancelWithCloseCode: { task, closeCode in
                task.cancel(with: closeCode, reason: nil)
            },
            invalidate: { $0.invalidateAndCancel() },
            send: { task, message in
                try await task.send(message)
            },
            sendPing: { task in
                try await withCheckedThrowingContinuation { continuation in
                    task.sendPing { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            },
            receive: { task in
                try await task.receive()
            }
        )
    }

    private enum Phase {
        case idle
        case connecting
        case open
        case closing
        case terminal
    }

    private struct State {
        var generation: UInt64 = 0
        var phase: Phase = .idle
        var requestedCloseCode = UInt16(URLSessionWebSocketTask.CloseCode.normalClosure.rawValue)
        var terminalEventDelivered = false
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var receiveTask: Task<Void, Never>?
        var delegate = WeakReference<any EngineDelegate>()
    }

    private struct Resources {
        let session: URLSession?
        let task: URLSessionWebSocketTask?
        let receiveTask: Task<Void, Never>?
    }

    /// `eventQueue` is the sole isolation domain for mutable lifecycle state and delegate delivery.
    /// The unchecked conformance bridges URLSession delegate callbacks, whose executor cannot be
    /// expressed in Swift's type system. No access to `state` occurs outside this queue.
    private let eventQueue = DispatchQueue(label: "com.vluxe.starscream.native-engine")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var state = State()
    private let certificatePinning: (any CertificatePinning)?
    private let proxy: WebSocketProxy?
    private let clientIdentity: WebSocketClientIdentity?
    private let dependencies: Dependencies

    public override init() {
        certificatePinning = nil
        proxy = nil
        clientIdentity = nil
        dependencies = .live
        super.init()
        eventQueue.setSpecific(key: queueKey, value: 1)
    }

    public init(
        certificatePinning: (any CertificatePinning)?,
        proxy: WebSocketProxy?,
        clientIdentity: WebSocketClientIdentity?
    ) {
        self.certificatePinning = certificatePinning
        self.proxy = proxy
        self.clientIdentity = clientIdentity
        dependencies = .live
        super.init()
        eventQueue.setSpecific(key: queueKey, value: 1)
    }

    init(
        certificatePinning: (any CertificatePinning)? = nil,
        proxy: WebSocketProxy? = nil,
        clientIdentity: WebSocketClientIdentity? = nil,
        dependencies: Dependencies
    ) {
        self.certificatePinning = certificatePinning
        self.proxy = proxy
        self.clientIdentity = clientIdentity
        self.dependencies = dependencies
        super.init()
        eventQueue.setSpecific(key: queueKey, value: 1)
    }

    public func register(delegate: any EngineDelegate) {
        performOnEventQueue {
            self.state.delegate = WeakReference(delegate)
        }
    }

    public func start(request: URLRequest) {
        performOnEventQueue {
            self.startOnEventQueue(request: request)
        }
    }

    private func startOnEventQueue(request: URLRequest) {
        let retired = detachResources()
        state.generation &+= 1
        let generation = state.generation
        state.phase = .connecting
        state.requestedCloseCode = UInt16(URLSessionWebSocketTask.CloseCode.normalClosure.rawValue)
        state.terminalEventDelivered = false
        tearDown(retired)

        let configuration = URLSessionConfiguration.default
        if let proxy {
            if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
                do {
                    configuration.proxyConfigurations = [try proxy.networkConfiguration()]
                } catch {
                    finish(generation: generation, event: .error(error))
                    return
                }
            } else if let legacyConfiguration = proxy.legacyURLSessionDictionary {
                configuration.connectionProxyDictionary = legacyConfiguration
            } else {
                finish(
                    generation: generation,
                    event: .error(WebSocketProxyError.unsupportedOnThisOS)
                )
                return
            }
        }

        let connection = dependencies.makeConnection(configuration, self, request)
        guard generation == state.generation, state.phase == .connecting else {
            dependencies.cancel(connection.task)
            dependencies.invalidate(connection.session)
            return
        }

        state.session = connection.session
        state.task = connection.task
        let receive = dependencies.receive
        let receiveTask = Task { [weak self, weak webSocketTask = connection.task] in
            guard let webSocketTask else { return }
            while !Task.isCancelled {
                do {
                    let message = try await receive(webSocketTask)
                    guard !Task.isCancelled, let self else { return }
                    let shouldContinue = await self.processReceivedMessage(
                        message,
                        from: webSocketTask,
                        generation: generation
                    )
                    guard shouldContinue else { return }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.performOnEventQueue {
                        self.processReceiveFailure(
                            error,
                            from: webSocketTask,
                            generation: generation
                        )
                    }
                    return
                }
            }
        }
        state.receiveTask = receiveTask
        dependencies.resume(connection.task)
    }

    public func stop(closeCode: UInt16) {
        performOnEventQueue {
            guard self.state.phase == .connecting || self.state.phase == .open else { return }
            let nativeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(closeCode))
                ?? .normalClosure
            self.state.phase = .closing
            self.state.requestedCloseCode = UInt16(nativeCode.rawValue)
            self.state.receiveTask?.cancel()
            self.state.receiveTask = nil
            guard let task = self.state.task else {
                self.finish(
                    generation: self.state.generation,
                    event: .disconnected("", self.state.requestedCloseCode)
                )
                return
            }
            self.dependencies.cancelWithCloseCode(task, nativeCode)
        }
    }

    public func forceStop() {
        performOnEventQueue {
            guard self.state.phase == .connecting
                    || self.state.phase == .open
                    || self.state.phase == .closing else { return }
            self.finish(generation: self.state.generation, event: .cancelled)
        }
    }

    public func write(string: String, completion: (@Sendable () -> Void)?) {
        send(.string(string), completion: completion)
    }

    private func send(
        _ message: URLSessionWebSocketTask.Message,
        completion: (@Sendable () -> Void)?
    ) {
        performOnEventQueue {
            guard self.state.phase == .open, let task = self.state.task else {
                completion?()
                return
            }
            let generation = self.state.generation
            let send = self.dependencies.send
            Task { [weak self, weak task] in
                guard let task else {
                    completion?()
                    return
                }
                let failure: Error?
                do {
                    try await send(task, message)
                    failure = nil
                } catch {
                    failure = error
                }
                guard let self else {
                    completion?()
                    return
                }
                self.performOnEventQueue {
                    if let failure {
                        self.processWriteFailure(failure, task: task, generation: generation)
                    }
                    completion?()
                }
            }
        }
    }

    public func write(data: Data, opcode: FrameOpCode, completion: (@Sendable () -> Void)?) {
        switch opcode {
        case .binaryFrame:
            send(.data(data), completion: completion)

        case .textFrame:
            guard let text = String(data: data, encoding: .utf8) else {
                performOnEventQueue {
                    guard self.state.phase == .open else {
                        completion?()
                        return
                    }
                    self.finish(
                        generation: self.state.generation,
                        event: .error(WSError(
                            type: .protocolError,
                            message: "text messages must contain valid UTF-8",
                            code: CloseCode.encoding.rawValue
                        ))
                    )
                    completion?()
                }
                return
            }
            write(string: text, completion: completion)

        case .ping:
            guard data.count <= 125 else {
                completion?()
                return
            }
            sendPing(completion: completion)

        default:
            completion?()
        }
    }

    private func sendPing(completion: (@Sendable () -> Void)?) {
        performOnEventQueue {
            guard self.state.phase == .open, let task = self.state.task else {
                completion?()
                return
            }
            let generation = self.state.generation
            let sendPing = self.dependencies.sendPing
            Task { [weak self, weak task] in
                guard let task else {
                    completion?()
                    return
                }
                let failure: Error?
                do {
                    try await sendPing(task)
                    failure = nil
                } catch {
                    failure = error
                }
                guard let self else {
                    completion?()
                    return
                }
                self.performOnEventQueue {
                    if let failure {
                        self.processWriteFailure(failure, task: task, generation: generation)
                    }
                    completion?()
                }
            }
        }
    }

    private func processReceivedMessage(
        _ message: URLSessionWebSocketTask.Message,
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            performOnEventQueue {
                guard self.isCurrent(task: task, generation: generation),
                      self.state.phase == .open else {
                    continuation.resume(returning: false)
                    return
                }
                switch message {
                case .string(let string):
                    self.broadcast(.text(string))
                case .data(let data):
                    self.broadcast(.binary(data))
                @unknown default:
                    break
                }
                continuation.resume(returning: true)
            }
        }
    }

    private func processReceiveFailure(
        _ error: any Error,
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) {
        guard isCurrent(task: task, generation: generation) else { return }
        guard state.phase != .closing else { return }
        finish(generation: generation, event: .error(error))
    }

    private func processWriteFailure(
        _ error: any Error,
        task: URLSessionWebSocketTask,
        generation: UInt64
    ) {
        guard isCurrent(task: task, generation: generation) else { return }
        guard state.phase != .closing else { return }
        finish(generation: generation, event: .error(error))
    }

    private func broadcast(_ event: WebSocketEvent) {
        state.delegate.value?.didReceive(event: event)
    }

    private func finish(generation: UInt64, event: WebSocketEvent) {
        guard generation == state.generation,
              state.phase != .idle,
              state.phase != .terminal,
              !state.terminalEventDelivered else { return }
        state.terminalEventDelivered = true
        state.phase = .terminal
        let resources = detachResources()
        tearDown(resources)
        broadcast(event)
    }

    private func detachResources() -> Resources {
        let resources = Resources(
            session: state.session,
            task: state.task,
            receiveTask: state.receiveTask
        )
        state.session = nil
        state.task = nil
        state.receiveTask = nil
        return resources
    }

    private func tearDown(_ resources: Resources) {
        resources.receiveTask?.cancel()
        if let task = resources.task {
            dependencies.cancel(task)
        }
        if let session = resources.session {
            dependencies.invalidate(session)
        }
    }

    private func isCurrent(
        session: URLSession,
        task: URLSessionTask? = nil
    ) -> Bool {
        guard state.session === session else { return false }
        if let task {
            return state.task === task
        }
        return true
    }

    private func isCurrent(task: URLSessionWebSocketTask, generation: UInt64) -> Bool {
        generation == state.generation && state.task === task
    }

    private func isCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    private func performOnEventQueue(_ operation: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            eventQueue.async(execute: operation)
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        performOnEventQueue {
            guard self.isCurrent(session: session, task: webSocketTask),
                  self.state.phase == .connecting else { return }
            self.state.phase = .open
            let selectedProtocol = `protocol` ?? ""
            self.broadcast(.connected([HTTPWSHeader.protocolName: selectedProtocol]))
        }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        performOnEventQueue {
            guard self.isCurrent(session: session, task: webSocketTask) else { return }
            let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.finish(
                generation: self.state.generation,
                event: .disconnected(reasonString, UInt16(closeCode.rawValue))
            )
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        performOnEventQueue {
            guard self.isCurrent(session: session, task: task) else { return }
            let generation = self.state.generation
            if let error {
                if self.state.phase == .closing, self.isCancellation(error) {
                    self.finish(
                        generation: generation,
                        event: .disconnected("", self.state.requestedCloseCode)
                    )
                } else {
                    self.finish(generation: generation, event: .error(error))
                }
            } else if self.state.phase == .closing {
                self.finish(
                    generation: generation,
                    event: .disconnected("", self.state.requestedCloseCode)
                )
            } else {
                self.finish(generation: generation, event: .peerClosed)
            }
        }
    }

    // MARK: - URLSession authentication

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        performOnEventQueue {
            guard self.isCurrent(session: session),
                  self.state.phase != .terminal else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let generation = self.state.generation
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodServerTrust:
                guard
                    let trust = challenge.protectionSpace.serverTrust,
                    let certificatePinning = self.certificatePinning
                else {
                    completionHandler(.performDefaultHandling, nil)
                    return
                }
                certificatePinning.evaluateTrust(
                    trust: trust,
                    domain: challenge.protectionSpace.host
                ) { [weak self] result in
                    guard let self else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        return
                    }
                    self.performOnEventQueue {
                        guard generation == self.state.generation,
                              self.isCurrent(session: session),
                              self.state.phase != .terminal else {
                            completionHandler(.cancelAuthenticationChallenge, nil)
                            return
                        }
                        switch result {
                        case .success:
                            completionHandler(.useCredential, URLCredential(trust: trust))
                        case .failed:
                            completionHandler(.cancelAuthenticationChallenge, nil)
                        }
                    }
                }

            case NSURLAuthenticationMethodClientCertificate:
                guard let clientIdentity = self.clientIdentity else {
                    completionHandler(.performDefaultHandling, nil)
                    return
                }
                do {
                    let identity = try clientIdentity.makeIdentity()
                    let credential = URLCredential(
                        identity: identity,
                        certificates: nil,
                        persistence: .forSession
                    )
                    completionHandler(.useCredential, credential)
                } catch {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    self.finish(generation: generation, event: .error(error))
                }

            default:
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
