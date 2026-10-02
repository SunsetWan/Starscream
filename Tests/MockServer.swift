//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  MockServer.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/29/19.
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
@testable import Starscream

public final class MockConnection: Connection, HTTPServerDelegate, FramerEventClient,
FrameCollectorDelegate, @unchecked Sendable {
    private struct State {
        var didUpgrade = false
        var onEvent: (@Sendable (ConnectionEvent) -> Void)?
        var delegate = WeakReference<any ConnectionDelegate>()
    }

    let transport: MockTransport
    private let httpHandler = FoundationHTTPServerHandler()
    private let framer = WSFramer(isServer: true)
    private let frameHandler = FrameCollector()
    private let state = Locked(State())

    public var onEvent: (@Sendable (ConnectionEvent) -> Void)? {
        get { state.withLock { $0.onEvent } }
        set { state.withLock { $0.onEvent = newValue } }
    }

    fileprivate weak var delegate: ConnectionDelegate? {
        get { state.withLock { $0.delegate.value } }
        set { state.withLock { $0.delegate = WeakReference(newValue) } }
    }
    
    init(transport: MockTransport) {
        self.transport = transport
        httpHandler.register(delegate: self)
        framer.register(delegate: self)
        frameHandler.delegate = self
    }
    
    func add(data: Data) {
        if !state.withLock({ $0.didUpgrade }) {
            httpHandler.parse(data: data)
        } else {
            framer.add(data: data)
        }
    }
    
    public func write(data: Data, opcode: FrameOpCode) {
        let wsData = framer.createWriteFrame(opcode: opcode, payload: data, isCompressed: false)
        transport.received(data: wsData)
    }
    
    /// MARK: - HTTPServerDelegate
    
    public func didReceive(event: HTTPEvent) {
        switch event {
        case .success(let headers, let leftover):
            state.withLock { $0.didUpgrade = true }
            let response = httpHandler.createResponse(headers: [:])
            transport.received(data: response)
            emit(server: .connected(self, headers), connection: .connected(headers))
            if !leftover.isEmpty {
                framer.add(data: leftover)
            }
        case .failure(let error):
            onEvent?(.error(error))
        }
    }
    
    /// MARK: - FrameCollectorDelegate
    
    public func frameProcessed(event: FrameEvent) {
        switch event {
        case .frame(let frame):
            frameHandler.add(frame: frame)
        case .error(let error):
            onEvent?(.error(error))
        }
    }
    
    public func didForm(event: FrameCollector.Event) {
        switch event {
        case .text(let string):
            emit(server: .text(self, string), connection: .text(string))
        case .binary(let data):
            emit(server: .binary(self, data), connection: .binary(data))
        case .pong(let data):
            emit(server: .pong(self, data), connection: .pong(data))
        case .ping(let data):
            emit(server: .ping(self, data), connection: .ping(data))
        case .closed(let reason, let code):
            emit(server: .disconnected(self, reason, code), connection: .disconnected(reason, code))
        case .error(let error):
            onEvent?(.error(error))
        }
    }
    
    public func decompress(data: Data, isFinal: Bool) throws -> Data {
        throw WSError(
            type: .protocolError,
            message: "compression was not negotiated by MockConnection",
            code: CloseCode.protocolError.rawValue
        )
    }

    private func emit(server: ServerEvent, connection: ConnectionEvent) {
        let callbacks = state.withLock { ($0.delegate.value, $0.onEvent) }
        callbacks.0?.didReceive(event: server)
        callbacks.1?(connection)
    }
}
    

public final class MockServer: Server, ConnectionDelegate, @unchecked Sendable {
    private struct State {
        var connections = [String: MockConnection]()
        var onEvent: (@Sendable (ServerEvent) -> Void)?
    }

    private let state = Locked(State())

    public var onEvent: (@Sendable (ServerEvent) -> Void)? {
        get { state.withLock { $0.onEvent } }
        set { state.withLock { $0.onEvent = newValue } }
    }
    
    public func start(address: String, port: UInt16) -> Error? {
        return nil
    }
    
    public func connect(transport: MockTransport) {
        let conn = MockConnection(transport: transport)
        conn.delegate = self
        state.withLock { $0.connections[transport.uuid] = conn }
    }
    
    public func disconnect(uuid: String) {
        state.withLock { $0.connections.removeValue(forKey: uuid) }
    }
    
    public func write(data: Data, uuid: String) {
        guard let conn = state.withLock({ $0.connections[uuid] }) else {
            return
        }
        conn.add(data: data)
    }
    
    /// MARK: - MockConnectionDelegate
    public func didReceive(event: ServerEvent) {
        state.withLock { $0.onEvent }?(event)
    }
}
