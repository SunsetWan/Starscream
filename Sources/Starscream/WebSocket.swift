//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Websocket.swift
//  Starscream
//
//  Created by Dalton Cherry on 7/16/14.
//  Copyright (c) 2014-2019 Dalton Cherry.
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

public enum ErrorType: Error, Sendable {
    case compressionError
    case securityError
    case protocolError //There was an error parsing the WebSocket frames
    case serverError
}

public struct WSError: Error, Sendable {
    public let type: ErrorType
    public let message: String
    public let code: UInt16

    public init(type: ErrorType, message: String, code: UInt16) {
        self.type = type
        self.message = message
        self.code = code
    }
}

public protocol WebSocketClient: AnyObject {
    func connect()
    func disconnect(closeCode: UInt16)
    func write(string: String, completion: (@Sendable () -> Void)?)
    func write(stringData: Data, completion: (@Sendable () -> Void)?)
    func write(data: Data, completion: (@Sendable () -> Void)?)
    func write(ping: Data, completion: (@Sendable () -> Void)?)
    func write(pong: Data, completion: (@Sendable () -> Void)?)
}

//implements some of the base behaviors
extension WebSocketClient {
    public func write(string: String) {
        write(string: string, completion: nil)
    }
    
    public func write(data: Data) {
        write(data: data, completion: nil)
    }
    
    public func write(ping: Data) {
        write(ping: ping, completion: nil)
    }
    
    public func write(pong: Data) {
        write(pong: pong, completion: nil)
    }
    
    public func disconnect() {
        disconnect(closeCode: CloseCode.normal.rawValue)
    }
}

public enum WebSocketEvent: Sendable {
    case connected([String: String])
    case disconnected(String, UInt16)
    case text(String)
    case binary(Data)
    case pong(Data?)
    case ping(Data?)
    case error(Error?)
    case viabilityChanged(Bool)
    case reconnectSuggested(Bool)
    case cancelled
    case peerClosed
}

public protocol WebSocketDelegate: AnyObject {
    func didReceive(event: WebSocketEvent, client: WebSocketClient)
}

/// Thread-safe WebSocket facade.
///
/// Mutable public configuration is protected by `state`. The unchecked conformance is required
/// because weak delegates and DispatchQueue do not model their thread-safety in Swift's type
/// system. The class is final and its engine is `Sendable`, so subclasses and unsynchronized
/// custom engines cannot invalidate this guarantee.
public final class WebSocket: WebSocketClient, EngineDelegate, @unchecked Sendable {
    private struct State {
        var request: URLRequest
        var delegate = WeakReference<any WebSocketDelegate>()
        var onEvent: (@Sendable (WebSocketEvent) -> Void)?
        var callbackQueue = DispatchQueue.main
    }

    private let engine: any Engine
    private let state: Locked<State>

    public weak var delegate: (any WebSocketDelegate)? {
        get { state.withLock { $0.delegate.value } }
        set { state.withLock { $0.delegate = WeakReference(newValue) } }
    }

    public var onEvent: (@Sendable (WebSocketEvent) -> Void)? {
        get { state.withLock { $0.onEvent } }
        set { state.withLock { $0.onEvent = newValue } }
    }

    public var request: URLRequest {
        get { state.withLock { $0.request } }
        set { state.withLock { $0.request = newValue } }
    }

    // Where the callback is executed. It defaults to the main UI thread queue.
    public var callbackQueue: DispatchQueue {
        get { state.withLock { $0.callbackQueue } }
        set { state.withLock { $0.callbackQueue = newValue } }
    }
    public var respondToPingWithPong: Bool {
        set {
            guard let e = engine as? WSEngine else { return }
            e.respondToPingWithPong = newValue
        }
        get {
            guard let e = engine as? WSEngine else { return true }
            return e.respondToPingWithPong
        }
    }
    
    public init(request: URLRequest, engine: any Engine) {
        self.engine = engine
        state = Locked(State(request: request))
    }

    public convenience init(
        request: URLRequest,
        certPinner: (any CertificatePinning)? = FoundationSecurity(),
        compressionHandler: (any CompressionHandler)? = nil,
        useCustomEngine: Bool = true
    ) {
        self.init(
            request: request,
            certPinner: certPinner,
            compressionHandler: compressionHandler,
            proxy: nil,
            clientIdentity: nil,
            useCustomEngine: useCustomEngine
        )
    }

    public convenience init(
        request: URLRequest,
        certPinner: (any CertificatePinning)? = FoundationSecurity(),
        compressionHandler: (any CompressionHandler)? = nil,
        clientIdentity: WebSocketClientIdentity,
        useCustomEngine: Bool = true
    ) {
        self.init(
            request: request,
            certPinner: certPinner,
            compressionHandler: compressionHandler,
            proxy: nil,
            clientIdentity: clientIdentity,
            useCustomEngine: useCustomEngine
        )
    }

    public convenience init(
        request: URLRequest,
        certPinner: (any CertificatePinning)? = FoundationSecurity(),
        compressionHandler: (any CompressionHandler)? = nil,
        proxy: WebSocketProxy?,
        clientIdentity: WebSocketClientIdentity? = nil,
        useCustomEngine: Bool = true
    ) {
        let needsLegacyProxyEngine: Bool
        if proxy != nil {
            if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
                needsLegacyProxyEngine = false
            } else {
                needsLegacyProxyEngine = true
            }
        } else {
            needsLegacyProxyEngine = false
        }

        if !useCustomEngine || needsLegacyProxyEngine {
            self.init(
                request: request,
                engine: NativeEngine(
                    certificatePinning: certPinner,
                    proxy: proxy,
                    clientIdentity: clientIdentity
                )
            )
        } else {
            self.init(
                request: request,
                engine: WSEngine(
                    transport: TCPTransport(proxy: proxy, clientIdentity: clientIdentity),
                    certPinner: certPinner,
                    compressionHandler: compressionHandler
                )
            )
        }
    }
    
    public func connect() {
        engine.register(delegate: self)
        engine.start(request: state.withLock { $0.request })
    }
    
    public func disconnect(closeCode: UInt16 = CloseCode.normal.rawValue) {
        engine.stop(closeCode: closeCode)
    }
    
    public func forceDisconnect() {
        engine.forceStop()
    }
    
    public func write(data: Data, completion: (@Sendable () -> Void)?) {
         write(data: data, opcode: .binaryFrame, completion: completion)
    }
    
    public func write(string: String, completion: (@Sendable () -> Void)?) {
        engine.write(string: string, completion: completion)
    }
    
    public func write(stringData: Data, completion: (@Sendable () -> Void)?) {
        write(data: stringData, opcode: .textFrame, completion: completion)
    }
    
    public func write(ping: Data, completion: (@Sendable () -> Void)?) {
        write(data: ping, opcode: .ping, completion: completion)
    }
    
    public func write(pong: Data, completion: (@Sendable () -> Void)?) {
        write(data: pong, opcode: .pong, completion: completion)
    }
    
    private func write(data: Data, opcode: FrameOpCode, completion: (@Sendable () -> Void)?) {
        engine.write(data: data, opcode: opcode, completion: completion)
    }
    
    // MARK: - EngineDelegate
    public func didReceive(event: WebSocketEvent) {
        let queue = state.withLock { $0.callbackQueue }
        queue.async { [weak self] in
            guard let self else { return }
            let callbacks = self.state.withLock {
                ($0.delegate.value, $0.onEvent)
            }
            callbacks.0?.didReceive(event: event, client: self)
            callbacks.1?(event)
        }
    }
}
