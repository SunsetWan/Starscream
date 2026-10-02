//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Engine.swift
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

public protocol EngineDelegate: AnyObject, Sendable {
    func didReceive(event: WebSocketEvent)
}

/// A WebSocket engine may be called from arbitrary tasks and queues.
///
/// Custom engines must synchronize their mutable state before conforming.
public protocol Engine: Sendable {
    func register(delegate: EngineDelegate)
    func start(request: URLRequest)
    func stop(closeCode: UInt16)
    func forceStop()
    func write(data: Data, opcode: FrameOpCode, completion: (@Sendable () -> Void)?)
    func write(string: String, completion: (@Sendable () -> Void)?)
}
