//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FrameCollector.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/24/19.
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

public protocol FrameCollectorDelegate: AnyObject {
    func didForm(event: FrameCollector.Event)
    func decompress(data: Data, isFinal: Bool) throws -> Data
}

public class FrameCollector {
    public enum Event: Sendable {
        case text(String)
        case binary(Data)
        case pong(Data?)
        case ping(Data?)
        case error(Error)
        case closed(String, UInt16)
    }
    weak var delegate: FrameCollectorDelegate?
    var buffer = Data()
    var frameCount = 0
    var isText = false //was the first frame a text frame or a binary frame?
    var needsDecompression = false
    var activeMaximumMessageSize: Int?
    private let maximumMessageSize: Int

    public init(maximumMessageSize: Int = WebSocketLimits.default.maximumMessageSize) {
        self.maximumMessageSize = max(0, maximumMessageSize)
    }
    
    public func add(frame: Frame) {
        // Control frames may appear between fragments and must not alter the
        // message being collected.
        if frame.opcode == .connectionClose {
            let code = frame.closeCode
            var reason = ""
            if !frame.payload.isEmpty {
                guard let customCloseReason = String(data: frame.payload, encoding: .utf8) else {
                    fail(
                        message: "close reason is not valid UTF-8",
                        code: CloseCode.encoding.rawValue
                    )
                    return
                }
                reason = customCloseReason
            }
            reset()
            delegate?.didForm(event: .closed(reason, code))
            return
        } else if frame.opcode == .pong {
            delegate?.didForm(event: .pong(frame.payload))
            return
        } else if frame.opcode == .ping {
            delegate?.didForm(event: .ping(frame.payload))
            return
        } else if frame.opcode == .continueFrame && frameCount == 0 {
            fail(message: "first frame can't be a continue frame")
            return
        } else if frameCount > 0 && frame.opcode != .continueFrame {
            fail(message: "second and later fragments must use the continuation opcode")
            return
        } else if frame.opcode == .continueFrame && frame.needsDecompression {
            fail(message: "continuation frames cannot set RSV1")
            return
        } else if frame.opcode != .textFrame && frame.opcode != .binaryFrame && frame.opcode != .continueFrame {
            fail(message: "unexpected data opcode: \(frame.opcode.rawValue)")
            return
        }

        if frameCount == 0 {
            isText = frame.opcode == .textFrame
            needsDecompression = frame.needsDecompression
            activeMaximumMessageSize = min(maximumMessageSize, frame.maximumMessageSize)
        }
        
        let payload: Data
        if needsDecompression {
            guard let delegate else {
                fail(message: "compressed frame received without a decompressor")
                return
            }
            do {
                payload = try delegate.decompress(data: frame.payload, isFinal: frame.isFin)
            } catch {
                let details = String(describing: error)
                reset()
                if let webSocketError = error as? WSError {
                    delegate.didForm(event: .error(webSocketError))
                } else {
                    delegate.didForm(event: .error(WSError(
                        type: .compressionError,
                        message: "failed to decompress WebSocket payload: \(details)",
                        code: CloseCode.protocolError.rawValue
                    )))
                }
                return
            }
        } else {
            payload = frame.payload
        }
        let messageLimit = activeMaximumMessageSize ?? maximumMessageSize
        guard buffer.count <= messageLimit,
              payload.count <= messageLimit - buffer.count else {
            fail(
                message: "message exceeds the configured maximum of \(messageLimit) bytes",
                code: CloseCode.messageTooBig.rawValue
            )
            return
        }
        buffer.append(payload)
        frameCount += 1

        if frame.isFin {
            let event: Event
            if isText {
                if let string = String(data: buffer, encoding: .utf8) {
                    event = .text(string)
                } else {
                    fail(message: "text message is not valid UTF-8", code: CloseCode.encoding.rawValue)
                    return
                }
            } else {
                event = .binary(buffer)
            }
            reset()
            delegate?.didForm(event: event)
        }
    }
    
    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        frameCount = 0
        isText = false
        needsDecompression = false
        activeMaximumMessageSize = nil
    }

    private func fail(message: String, code: UInt16 = CloseCode.protocolError.rawValue) {
        reset()
        delegate?.didForm(event: .error(WSError(
            type: .protocolError,
            message: message,
            code: code
        )))
    }
}
