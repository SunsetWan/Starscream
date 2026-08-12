//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  MockTransport.swift
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

public final class MockTransport: Transport, @unchecked Sendable {
    private struct State {
        var delegate = WeakReference<any TransportEventClient>()
        var server = WeakReference<MockServer>()
    }

    private let state: Locked<State>

    public var usingTLS: Bool {
        return false
    }
    private let id: String
    var uuid: String {
        return id
    }
    
    public init(server: MockServer) {
        self.id = UUID().uuidString
        state = Locked(State(server: WeakReference(server)))
    }
    
    public func register(delegate: TransportEventClient) {
        state.withLock { $0.delegate = WeakReference(delegate) }
    }
    
    public func connect(url: URL, timeout: Double, certificatePinning: CertificatePinning?) {
        let callbacks = state.withLock { ($0.server.value, $0.delegate.value) }
        callbacks.0?.connect(transport: self)
        callbacks.1?.connectionChanged(state: .connected)
    }
    
    public func disconnect() {
        state.withLock { $0.server.value }?.disconnect(uuid: uuid)
    }
    
    public func write(data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        state.withLock { $0.server.value }?.write(data: data, uuid: uuid)
        completion(nil)
    }
    
    public func received(data: Data) {
        state.withLock { $0.delegate.value }?.connectionChanged(state: .receive(data))
    }
    
    public func getSecurityData() -> (SecTrust?, String?) {
        return (nil, nil)
    }
}

public final class MockSecurity: CertificatePinning, HeaderValidator, @unchecked Sendable {
    
    public func evaluateTrust(
        trust: SecTrust,
        domain: String?,
        completion: @escaping @Sendable (PinningState) -> Void
    ) {
        completion(.success)
    }

    public func validate(headers: [String: String], key: String) -> Error? {
        return nil
    }
}
