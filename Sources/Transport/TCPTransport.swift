//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  HTTPTransport.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/23/19.
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
@preconcurrency import Network

public enum TCPTransportError: Error, Sendable, Hashable {
    case invalidRequest
    case proxyRequiresNewerOS
    case invalidClientIdentity(ClientIdentityError)
}

/// Bridges Security.framework's unannotated verification callback into a Sendable completion.
/// The callback is removed under the lock before invocation, so even a faulty pinner cannot
/// complete the same TLS verification more than once.
private final class SecurityVerifyCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: sec_protocol_verify_complete_t?

    init(_ callback: @escaping sec_protocol_verify_complete_t) {
        self.callback = callback
    }

    func callAsFunction(_ result: Bool) {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?(result)
    }
}

@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
public class TCPTransport: Transport, @unchecked Sendable {
    private struct State {
        var connection: NWConnection?
        var delegate = WeakReference<any TransportEventClient>()
        var isRunning = false
        var isTLS = false
        var generation: UInt64 = 0
    }

    /// Safety invariant: lifecycle transitions and callback delivery are serialized by
    /// `lifecycleLock`; every asynchronous Network callback must also match both the
    /// connection object and its generation before it may observe or mutate current state.
    private let state = Locked(State())
    private let lifecycleLock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "com.vluxe.starscream.networkstream", attributes: [])
    private let proxy: WebSocketProxy?
    private let clientIdentity: WebSocketClientIdentity?
   
    deinit {
        disconnect()
    }
 
    public var usingTLS: Bool {
        state.withLock { $0.isTLS }
    }

    public init(connection: NWConnection) {
        proxy = nil
        clientIdentity = nil
        let generation = state.withLock { state -> UInt64 in
            state.generation &+= 1
            state.connection = connection
            state.isRunning = true
            return state.generation
        }
        start(connection: connection, generation: generation)
    }

    public init() {
        proxy = nil
        clientIdentity = nil
    }

    public init(proxy: WebSocketProxy?, clientIdentity: WebSocketClientIdentity?) {
        self.proxy = proxy
        self.clientIdentity = clientIdentity
    }
    
    public func connect(url: URL, timeout: Double = 10, certificatePinning: CertificatePinning? = nil) {
        withLifecycleLock {
            guard let parts = url.getParts() else {
                notify(.failed(TCPTransportError.invalidRequest))
                return
            }

            let attempt = beginConnectionAttempt(isTLS: parts.isTLS)
            attempt.previousConnection?.cancel()

            let options = NWProtocolTCP.Options()
            options.connectionTimeout = Int(timeout.rounded(.up))

            let tlsOptions = parts.isTLS ? NWProtocolTLS.Options() : nil
            if let tlsOpts = tlsOptions {
                if let certificatePinning {
                    sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { _, secTrust, complete in
                        let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                        let completeOnce = SecurityVerifyCompletion(complete)
                        certificatePinning.evaluateTrust(trust: trust, domain: parts.host) { result in
                            switch result {
                            case .success:
                                completeOnce(true)
                            case .failed:
                                completeOnce(false)
                            }
                        }
                    }, queue)
                }
                if let clientIdentity {
                    do {
                        let identity = try clientIdentity.makeIdentity()
                        guard let protocolIdentity = sec_identity_create(identity) else {
                            notify(
                                .failed(TCPTransportError.invalidClientIdentity(.missingIdentity)),
                                generation: attempt.generation
                            )
                            return
                        }
                        sec_protocol_options_set_local_identity(tlsOpts.securityProtocolOptions, protocolIdentity)
                    } catch let error as ClientIdentityError {
                        notify(
                            .failed(TCPTransportError.invalidClientIdentity(error)),
                            generation: attempt.generation
                        )
                        return
                    } catch {
                        notify(
                            .failed(TCPTransportError.invalidClientIdentity(.missingIdentity)),
                            generation: attempt.generation
                        )
                        return
                    }
                }
            }

            let parameters = NWParameters(tls: tlsOptions, tcp: options)
            if let proxy {
                guard configure(proxy: proxy, parameters: parameters) else {
                    notify(.failed(TCPTransportError.proxyRequiresNewerOS), generation: attempt.generation)
                    return
                }
            }

            let connection = NWConnection(
                host: NWEndpoint.Host.name(parts.host, nil),
                port: NWEndpoint.Port(rawValue: UInt16(parts.port))!,
                using: parameters
            )
            guard install(connection: connection, generation: attempt.generation) else {
                connection.cancel()
                return
            }
            start(connection: connection, generation: attempt.generation)
        }
    }

    private func configure(proxy: WebSocketProxy, parameters: NWParameters) -> Bool {
        guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) else {
            return false
        }
        guard let configuration = try? proxy.networkConfiguration() else { return false }
        let context = NWParameters.PrivacyContext(description: "Starscream proxy")
        context.proxyConfigurations = [configuration]
        parameters.setPrivacyContext(context)
        return true
    }
    
    public func disconnect() {
        withLifecycleLock {
            disconnectCurrent()
        }
    }
    
    public func register(delegate: TransportEventClient) {
        state.withLock { $0.delegate = WeakReference(delegate) }
    }
    
    public func write(data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        withLifecycleLock {
            guard let connection = state.withLock({ state in
                state.isRunning ? state.connection : nil
            }) else {
                completion(TCPTransportError.invalidRequest)
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                completion(error)
            })
        }
    }
    
    private func start(connection: NWConnection, generation: UInt64) {
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let connection else { return }
            self?.handleState(newState, connection: connection, generation: generation)
        }

        connection.viabilityUpdateHandler = { [weak self, weak connection] isViable in
            guard let connection else { return }
            self?.notify(.viability(isViable), connection: connection, generation: generation)
        }

        connection.betterPathUpdateHandler = { [weak self, weak connection] isBetter in
            guard let connection else { return }
            self?.notify(.shouldReconnect(isBetter), connection: connection, generation: generation)
        }

        connection.start(queue: queue)
        readLoop(connection: connection, generation: generation)
    }

    //readLoop keeps reading from the connection to get the latest content
    private func readLoop(connection: NWConnection, generation: UInt64) {
        guard isCurrent(connection: connection, generation: generation) else { return }
        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096) {
            [weak self, weak connection] data, context, isComplete, error in
            guard let self, let connection else { return }
            self.handleReceive(
                data: data,
                context: context,
                isComplete: isComplete,
                error: error,
                connection: connection,
                generation: generation
            )
        }
    }

    private func handleState(
        _ newState: NWConnection.State,
        connection: NWConnection,
        generation: UInt64
    ) {
        withLifecycleLock {
            guard isCurrent(connection: connection, generation: generation) else { return }
            switch newState {
            case .ready:
                notify(.connected, connection: connection, generation: generation)
            case .waiting:
                notify(.waiting, connection: connection, generation: generation)
            case .cancelled:
                notify(.cancelled, connection: connection, generation: generation)
            case .failed(let error):
                notify(.failed(error), connection: connection, generation: generation)
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
    }

    private func handleReceive(
        data: Data?,
        context: NWConnection.ContentContext?,
        isComplete: Bool,
        error: NWError?,
        connection: NWConnection,
        generation: UInt64
    ) {
        withLifecycleLock {
            guard isCurrent(connection: connection, generation: generation) else { return }
            if let data {
                notify(.receive(data), connection: connection, generation: generation)
                guard isCurrent(connection: connection, generation: generation) else { return }
            }

            if let error {
                notify(.failed(error), connection: connection, generation: generation)
                return
            }

            // Refer to https://developer.apple.com/documentation/network/implementing_netcat_with_network_framework
            if let context, context.isFinal, isComplete {
                let hasDelegate = state.withLock { $0.delegate.value != nil }
                if hasDelegate {
                    notify(.peerClosed, connection: connection, generation: generation)
                } else {
                    disconnectCurrent(generation: generation)
                }
                return
            }

            readLoop(connection: connection, generation: generation)
        }
    }

    private func beginConnectionAttempt(isTLS: Bool) -> (generation: UInt64, previousConnection: NWConnection?) {
        state.withLock { state in
            let previousConnection = state.connection
            state.generation &+= 1
            state.connection = nil
            state.isRunning = false
            state.isTLS = isTLS
            return (state.generation, previousConnection)
        }
    }

    private func install(connection: NWConnection, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation, state.connection == nil else { return false }
            state.connection = connection
            state.isRunning = true
            return true
        }
    }

    private func disconnectCurrent(generation expectedGeneration: UInt64? = nil) {
        let connection = state.withLock { state -> NWConnection? in
            if let expectedGeneration, state.generation != expectedGeneration {
                return nil
            }
            let connection = state.connection
            state.generation &+= 1
            state.connection = nil
            state.isRunning = false
            return connection
        }
        connection?.cancel()
    }

    private func isCurrent(connection: NWConnection, generation: UInt64) -> Bool {
        state.withLock { state in
            state.generation == generation
                && state.isRunning
                && state.connection === connection
        }
    }

    private func notify(
        _ event: ConnectionState,
        connection: NWConnection? = nil,
        generation: UInt64? = nil
    ) {
        withLifecycleLock {
            let delegate = state.withLock { state -> (any TransportEventClient)? in
                if let generation, state.generation != generation { return nil }
                if let connection, state.connection !== connection { return nil }
                return state.delegate.value
            }
            delegate?.connectionChanged(state: event)
        }
    }

    private func withLifecycleLock<T>(_ body: () throws -> T) rethrows -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return try body()
    }
}
#else
typealias TCPTransport = FoundationTransport
#endif
