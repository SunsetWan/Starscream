//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FuzzingTests.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/28/19.
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
import Testing
@testable import Starscream

@Suite("RFC 6455 echo boundaries")
struct FuzzingTests {
    enum MessageKind: String, Sendable, CustomTestStringConvertible {
        case text
        case binary

        var testDescription: String { rawValue }
    }

    struct EchoCase: Sendable, CustomTestStringConvertible {
        let kind: MessageKind
        let length: Int

        var testDescription: String { "\(kind.rawValue)-\(length)-bytes" }
    }

    private static let cases = [0, 125, 126, 127, 128, 65_535, 65_536].flatMap { length in
        [
            EchoCase(kind: .text, length: length),
            EchoCase(kind: .binary, length: length),
        ]
    }

    @Test("Echoes RFC payload length boundaries", arguments: cases)
    func echoBoundary(testCase: EchoCase) async throws {
        let payload = Data(repeating: 0x2A, count: testCase.length)
        let opcode: FrameOpCode = testCase.kind == .text ? .textFrame : .binaryFrame
        let outcome = try await runEcho(payload: payload, opcode: opcode)

        switch outcome {
        case .text(let value):
            #expect(testCase.kind == .text)
            #expect(Data(value.utf8) == payload)
        case .binary(let value):
            #expect(testCase.kind == .binary)
            #expect(value == payload)
        case .unexpected(let description):
            Issue.record("Unexpected server event: \(description)")
        }
    }

    private func runEcho(payload: Data, opcode: FrameOpCode) async throws -> EchoOutcome {
        let server = MockServer()
        _ = server.start(address: "", port: 0)
        let transport = MockTransport(server: server)
        let request = URLRequest(url: URL(string: "http://vluxe.io/ws")!)
        let webSocket = WebSocket(
            request: request,
            engine: WSEngine(transport: transport)
        )

        let (events, continuation) = AsyncStream<EchoOutcome>.makeStream()
        server.onEvent = { event in
            switch event {
            case .connected(let connection, _):
                connection.write(data: payload, opcode: opcode)
            case .text(_, let text):
                continuation.yield(.text(text))
                continuation.finish()
            case .binary(_, let data):
                continuation.yield(.binary(data))
                continuation.finish()
            case .disconnected:
                break
            case .pong:
                continuation.yield(.unexpected("pong"))
                continuation.finish()
            case .ping:
                continuation.yield(.unexpected("ping"))
                continuation.finish()
            }
        }

        webSocket.onEvent = { event in
            switch event {
            case .text(let string):
                webSocket.write(string: string)
            case .binary(let data):
                webSocket.write(data: data)
            case .error(let error):
                continuation.yield(.unexpected("client error: \(String(describing: error))"))
                continuation.finish()
            default:
                break
            }
        }
        webSocket.connect()

        return try await withThrowingTaskGroup(of: EchoOutcome.self) { group in
            group.addTask {
                for await event in events {
                    return event
                }
                throw EchoTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw EchoTestError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            webSocket.forceDisconnect()
            return result
        }
    }
}

private enum EchoOutcome: Sendable {
    case text(String)
    case binary(Data)
    case unexpected(String)
}

private enum EchoTestError: Error {
    case streamEnded
    case timedOut
}
