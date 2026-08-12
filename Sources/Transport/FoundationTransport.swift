//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FoundationTransport.swift
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

import Foundation

public enum FoundationTransportError: Error, Sendable {
    case invalidRequest
    case invalidOutputStream
    case missingPeerTrust
    case timeout
}

public class FoundationTransport: NSObject, Transport, StreamDelegate, @unchecked Sendable {
    private struct State {
        var delegate = WeakReference<any TransportEventClient>()
        var inputStream: InputStream?
        var outputStream: OutputStream?
        var isOpen = false
        var isTLS = false
        var domain: String?
        var certPinner: (any CertificatePinning)?
        var generation: UInt64 = 0
        var hasStartedOpenValidation = false
        var hasFinishedOpenValidation = false
    }

    /// Safety invariant: stream lifecycle operations and delegate delivery are serialized by
    /// `lifecycleLock`; delayed work must match the current generation before it can act.
    private let state = Locked(State())
    private let lifecycleLock = NSRecursiveLock()
    private let workQueue = DispatchQueue(label: "com.vluxe.starscream.websocket", attributes: [])
    private let onConnect: (@Sendable (InputStream, OutputStream) -> Void)?
    
    public var usingTLS: Bool {
        state.withLock { $0.isTLS }
    }
    
    public init(streamConfiguration: (@Sendable (InputStream, OutputStream) -> Void)? = nil) {
        onConnect = streamConfiguration
        super.init()
    }
    
    deinit {
        disconnect()
    }
    
    public func connect(url: URL, timeout: Double = 10, certificatePinning: CertificatePinning? = nil) {
        withLifecycleLock {
            guard let parts = url.getParts() else {
                notify(.failed(FoundationTransportError.invalidRequest))
                return
            }
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            let host = parts.host as NSString
            CFStreamCreatePairWithSocketToHost(nil, host, UInt32(parts.port), &readStream, &writeStream)
            guard
                let inputStream = readStream?.takeRetainedValue() as InputStream?,
                let outputStream = writeStream?.takeRetainedValue() as OutputStream?
            else {
                notify(.failed(FoundationTransportError.invalidRequest))
                return
            }

            let installation = state.withLock { state -> (generation: UInt64, oldStreams: StreamPair) in
                let oldStreams = StreamPair(input: state.inputStream, output: state.outputStream)
                state.generation &+= 1
                state.certPinner = certificatePinning
                state.isTLS = parts.isTLS
                state.domain = parts.host
                state.inputStream = inputStream
                state.outputStream = outputStream
                state.isOpen = false
                state.hasStartedOpenValidation = false
                state.hasFinishedOpenValidation = false
                return (state.generation, oldStreams)
            }
            close(installation.oldStreams)

            inputStream.delegate = self
            outputStream.delegate = self

            if parts.isTLS {
                let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySocketSecurityLevel)
                CFReadStreamSetProperty(inputStream, key, kCFStreamSocketSecurityLevelNegotiatedSSL)
                CFWriteStreamSetProperty(outputStream, key, kCFStreamSocketSecurityLevelNegotiatedSSL)
            }

            onConnect?(inputStream, outputStream)
            guard isCurrent(generation: installation.generation, stream: inputStream) else { return }

            CFReadStreamSetDispatchQueue(inputStream, workQueue)
            CFWriteStreamSetDispatchQueue(outputStream, workQueue)
            inputStream.open()
            outputStream.open()

            let generation = installation.generation
            workQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.handleTimeout(generation: generation)
            }
        }
    }
    
    public func disconnect() {
        withLifecycleLock {
            close(invalidateCurrent())
        }
    }
    
    public func register(delegate: TransportEventClient) {
        state.withLock { $0.delegate = WeakReference(delegate) }
    }
    
    public func write(data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let generation = withLifecycleLock {
            state.withLock { state in
                state.outputStream == nil ? nil : state.generation
            }
        }
        workQueue.async { [weak self] in
            guard let self, let generation else {
                completion(FoundationTransportError.invalidOutputStream)
                return
            }
            let result: (any Error)? = self.withLifecycleLock {
                guard let outputStream = self.state.withLock({ state -> OutputStream? in
                    guard state.generation == generation else { return nil }
                    return state.outputStream
                }) else {
                    return FoundationTransportError.invalidOutputStream
                }

                return data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return nil
                    }
                    var total = 0
                    while total < data.count {
                        let written = outputStream.write(
                            baseAddress.advanced(by: total),
                            maxLength: data.count - total
                        )
                        guard written > 0 else {
                            return outputStream.streamError ?? FoundationTransportError.invalidOutputStream
                        }
                        total += written
                    }
                    return nil
                }
            }
            completion(result)
        }
    }
    
    private func getSecurityData(generation: UInt64) -> (SecTrust?, String?) {
        #if os(watchOS)
        return (nil, nil)
        #else
        guard let snapshot = state.withLock({ state -> (OutputStream, String?)? in
            guard state.generation == generation, let outputStream = state.outputStream else {
                return nil
            }
            return (outputStream, state.domain)
        }) else {
            return (nil, nil)
        }
        let trust: SecTrust? = conditionalCast(snapshot.0.property(
            forKey: kCFStreamPropertySSLPeerTrust as Stream.PropertyKey
        ))
        return (trust, snapshot.1)
        #endif
    }
    
    private func read(stream: InputStream, generation: UInt64) {
        guard isCurrent(generation: generation, stream: stream) else { return }
        let maxBuffer = 4096
        let buf = NSMutableData(capacity: maxBuffer)
        let buffer = UnsafeMutableRawPointer(mutating: buf!.bytes).assumingMemoryBound(to: UInt8.self)
        let length = stream.read(buffer, maxLength: maxBuffer)
        if length < 1 {
            return
        }
        let data = Data(bytes: buffer, count: length)
        notify(.receive(data), generation: generation, stream: stream)
    }
    
    // MARK: - StreamDelegate
    
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        withLifecycleLock {
            guard let identity = streamIdentity(aStream) else { return }
            switch eventCode {
            case .hasBytesAvailable:
                if identity.isInput, let inputStream = aStream as? InputStream {
                    read(stream: inputStream, generation: identity.generation)
                }
            case .errorOccurred:
                notify(.failed(aStream.streamError), generation: identity.generation, stream: aStream)
            case .endEncountered:
                if identity.isInput {
                    notify(.peerClosed, generation: identity.generation, stream: aStream)
                }
            case .openCompleted:
                if identity.isInput {
                    beginOpenValidation(generation: identity.generation)
                }
            default:
                break
            }
        }
    }

    private func beginOpenValidation(generation: UInt64) {
        let validation = state.withLock { state -> (shouldStart: Bool, pinner: (any CertificatePinning)?) in
            guard state.generation == generation, !state.hasStartedOpenValidation else {
                return (false, nil)
            }
            state.hasStartedOpenValidation = true
            return (true, state.certPinner)
        }
        guard validation.shouldStart else { return }

        let (trust, domain) = getSecurityData(generation: generation)
        if let pinner = validation.pinner {
            guard let trust else {
                finishOpenValidation(
                    .failed(FoundationTransportError.missingPeerTrust),
                    generation: generation
                )
                return
            }
            pinner.evaluateTrust(trust: trust, domain: domain) { [weak self] result in
                self?.finishOpenValidation(result, generation: generation)
            }
        } else {
            finishOpenValidation(.success, generation: generation)
        }
    }

    private func finishOpenValidation(_ result: PinningState, generation: UInt64) {
        withLifecycleLock {
            let shouldFinish = state.withLock { state -> Bool in
                guard state.generation == generation, !state.hasFinishedOpenValidation else {
                    return false
                }
                state.hasFinishedOpenValidation = true
                if case .success = result {
                    state.isOpen = true
                }
                return true
            }
            guard shouldFinish else { return }

            switch result {
            case .success:
                notify(.connected, generation: generation)
            case .failed(let error):
                notify(.failed(error), generation: generation)
                disconnectCurrent(generation: generation)
            }
        }
    }

    private func handleTimeout(generation: UInt64) {
        withLifecycleLock {
            let shouldTimeout = state.withLock { state in
                state.generation == generation && !state.isOpen
            }
            guard shouldTimeout else { return }
            notify(.failed(FoundationTransportError.timeout), generation: generation)
            disconnectCurrent(generation: generation)
        }
    }

    private struct StreamPair {
        var input: InputStream?
        var output: OutputStream?
    }

    private func invalidateCurrent(generation expectedGeneration: UInt64? = nil) -> StreamPair {
        state.withLock { state in
            if let expectedGeneration, state.generation != expectedGeneration {
                return StreamPair()
            }
            let streams = StreamPair(input: state.inputStream, output: state.outputStream)
            state.generation &+= 1
            state.isOpen = false
            state.outputStream = nil
            state.inputStream = nil
            state.certPinner = nil
            state.domain = nil
            state.hasStartedOpenValidation = false
            state.hasFinishedOpenValidation = false
            return streams
        }
    }

    private func disconnectCurrent(generation: UInt64) {
        close(invalidateCurrent(generation: generation))
    }

    private func close(_ streams: StreamPair) {
        if let inputStream = streams.input {
            inputStream.delegate = nil
            CFReadStreamSetDispatchQueue(inputStream, nil)
            inputStream.close()
        }
        if let outputStream = streams.output {
            outputStream.delegate = nil
            CFWriteStreamSetDispatchQueue(outputStream, nil)
            outputStream.close()
        }
    }

    private func streamIdentity(_ stream: Stream) -> (generation: UInt64, isInput: Bool)? {
        state.withLock { state in
            if state.inputStream === stream {
                return (state.generation, true)
            }
            if state.outputStream === stream {
                return (state.generation, false)
            }
            return nil
        }
    }

    private func isCurrent(generation: UInt64, stream: Stream? = nil) -> Bool {
        state.withLock { state in
            guard state.generation == generation else { return false }
            guard let stream else { return true }
            return state.inputStream === stream || state.outputStream === stream
        }
    }

    private func notify(
        _ event: ConnectionState,
        generation: UInt64? = nil,
        stream: Stream? = nil
    ) {
        withLifecycleLock {
            let delegate = state.withLock { state -> (any TransportEventClient)? in
                if let generation, state.generation != generation { return nil }
                if let stream,
                    state.inputStream !== stream,
                    state.outputStream !== stream
                {
                    return nil
                }
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

/// Core Foundation's imported reference types can trigger an incorrect "always succeeds"
/// diagnostic when conditionally cast at a concrete call site. Keeping the checked cast generic
/// preserves the intended fail-closed behavior without a force cast.
private func conditionalCast<Value>(_ value: Any?) -> Value? {
    value as? Value
}
