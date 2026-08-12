//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Framer.swift
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

let FinMask: UInt8          = 0x80
let OpCodeMask: UInt8       = 0x0F
let RSVMask: UInt8          = 0x70
let RSV1Mask: UInt8         = 0x40
let MaskMask: UInt8         = 0x80
let PayloadLenMask: UInt8   = 0x7F
let MaxFrameSize: Int       = 32

/// Resource limits applied before WebSocket payload bytes are accumulated.
public struct WebSocketLimits: Sendable, Equatable {
    /// A conservative default that still accommodates ordinary binary WebSocket traffic.
    public static let `default` = WebSocketLimits()

    public let maximumFrameSize: Int
    public let maximumMessageSize: Int
    public let maximumDecompressedMessageSize: Int

    public init(
        maximumFrameSize: Int = 16 * 1024 * 1024,
        maximumMessageSize: Int = 64 * 1024 * 1024,
        maximumDecompressedMessageSize: Int = 64 * 1024 * 1024
    ) {
        self.maximumFrameSize = max(0, maximumFrameSize)
        self.maximumMessageSize = max(0, maximumMessageSize)
        self.maximumDecompressedMessageSize = max(0, maximumDecompressedMessageSize)
    }
}

// Standard WebSocket close codes
public enum CloseCode: UInt16, Sendable {
    case normal                 = 1000
    case goingAway              = 1001
    case protocolError          = 1002
    case protocolUnhandledType  = 1003
    // 1004 reserved.
    case noStatusReceived       = 1005
    //1006 reserved.
    case encoding               = 1007
    case policyViolated         = 1008
    case messageTooBig          = 1009
    case mandatoryExtension     = 1010
    case internalServerError    = 1011
    case serviceRestart         = 1012
    case tryAgainLater          = 1013
    case badGateway             = 1014
}

public enum FrameOpCode: UInt8, Sendable {
    case continueFrame = 0x0
    case textFrame = 0x1
    case binaryFrame = 0x2
    // 3-7 are reserved.
    case connectionClose = 0x8
    case ping = 0x9
    case pong = 0xA
    // B-F reserved.
    case unknown = 100
}

public struct Frame: Sendable {
    let isFin: Bool
    let needsDecompression: Bool
    let isMasked: Bool
    let opcode: FrameOpCode
    let payloadLength: UInt64
    let payload: Data
    let closeCode: UInt16 //only used by connectionClose opcode
    let maximumMessageSize: Int

    init(
        isFin: Bool,
        needsDecompression: Bool,
        isMasked: Bool,
        opcode: FrameOpCode,
        payloadLength: UInt64,
        payload: Data,
        closeCode: UInt16,
        maximumMessageSize: Int = WebSocketLimits.default.maximumMessageSize
    ) {
        self.isFin = isFin
        self.needsDecompression = needsDecompression
        self.isMasked = isMasked
        self.opcode = opcode
        self.payloadLength = payloadLength
        self.payload = payload
        self.closeCode = closeCode
        self.maximumMessageSize = maximumMessageSize
    }
}

public enum FrameEvent: Sendable {
    case frame(Frame)
    case error(Error)
}

public protocol FramerEventClient: AnyObject {
    func frameProcessed(event: FrameEvent)
}

public protocol Framer {
    func add(data: Data)
    func register(delegate: FramerEventClient)
    func createWriteFrame(opcode: FrameOpCode, payload: Data, isCompressed: Bool) -> Data
    func createWriteFrameResult(opcode: FrameOpCode, payload: Data, isCompressed: Bool) -> Result<Data, Error>
    func updateCompression(supports: Bool)
    func supportsCompression() -> Bool
    func reset()
}

public extension Framer {
    func createWriteFrameResult(opcode: FrameOpCode, payload: Data, isCompressed: Bool) -> Result<Data, Error> {
        .success(createWriteFrame(opcode: opcode, payload: payload, isCompressed: isCompressed))
    }

    func reset() {}
}

public class WSFramer: Framer {
    private struct State {
        weak var delegate: FramerEventClient?
        var buffer = Data()
        var compressionEnabled = false
    }

    private let queue = DispatchQueue(label: "com.vluxe.starscream.wsframer", attributes: [])
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let state = Locked(State())
    private let isServer: Bool
    private let limits: WebSocketLimits

    public var compressionEnabled: Bool {
        get { state.withLock { $0.compressionEnabled } }
        set { state.withLock { $0.compressionEnabled = newValue } }
    }
    
    public init(isServer: Bool = false, limits: WebSocketLimits = .default) {
        self.isServer = isServer
        self.limits = limits
        queue.setSpecific(key: queueKey, value: 1)
    }
    
    public func updateCompression(supports: Bool) {
        compressionEnabled = supports
    }
    
    public func supportsCompression() -> Bool {
        return compressionEnabled
    }
    
    enum ProcessEvent {
        case needsMoreData
        case processedFrame(Frame, Int)
        case failed(Error)
    }
    
    public func add(data: Data) {
        let state = self.state
        let isServer = self.isServer
        let limits = self.limits
        queue.async {
            state.withLock { $0.buffer.append(data) }
            while true {
                var delegate: FramerEventClient?
                var shouldContinue = false
                let event = state.withLock { state in
                    let event = Self.process(
                        buffer: state.buffer,
                        compressionEnabled: state.compressionEnabled,
                        isServer: isServer,
                        limits: limits
                    )
                    delegate = state.delegate
                    switch event {
                    case .needsMoreData:
                        break
                    case .processedFrame(let frame, let split):
                        shouldContinue = frame.opcode != .connectionClose && split < state.buffer.count
                        if shouldContinue {
                            state.buffer.removeFirst(split)
                        } else {
                            state.buffer.removeAll(keepingCapacity: true)
                        }
                    case .failed:
                        state.buffer.removeAll(keepingCapacity: true)
                    }
                    return event
                }

                switch event {
                case .needsMoreData:
                    return
                case .processedFrame(let frame, _):
                    delegate?.frameProcessed(event: .frame(frame))
                    if !shouldContinue { return }
                case .failed(let error):
                    delegate?.frameProcessed(event: .error(error))
                    return
                }
            }
        }
    }

    public func register(delegate: FramerEventClient) {
        syncOnQueue {
            state.withLock { $0.delegate = delegate }
        }
    }

    public func reset() {
        syncOnQueue {
            state.withLock { $0.buffer.removeAll(keepingCapacity: true) }
        }
    }

    private func syncOnQueue<Result>(_ operation: () throws -> Result) rethrows -> Result {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
    
    private static func process(
        buffer: Data,
        compressionEnabled: Bool,
        isServer: Bool,
        limits: WebSocketLimits
    ) -> ProcessEvent {
        if buffer.count < 2 {
            return .needsMoreData
        }
        let pointer = [UInt8](buffer)

        let isFin = (FinMask & pointer[0]) != 0
        let opcodeRawValue = OpCodeMask & pointer[0]
        let opcode = FrameOpCode(rawValue: opcodeRawValue) ?? .unknown
        let isMasked = (MaskMask & pointer[1]) != 0
        let payloadLengthMarker = PayloadLenMask & pointer[1]
        let hasRSV1 = (RSV1Mask & pointer[0]) != 0
        let hasRSV2OrRSV3 = (pointer[0] & (RSVMask ^ RSV1Mask)) != 0

        guard opcode != .unknown else {
            return protocolFailure("unknown or reserved opcode: \(opcodeRawValue)")
        }
        guard isMasked == isServer else {
            return protocolFailure(isServer
                ? "client-to-server frames must be masked"
                : "server-to-client frames must not be masked")
        }

        let isControlFrame = opcode.isControlFrame
        if hasRSV2OrRSV3 {
            return protocolFailure("RSV2 and RSV3 must be zero without a negotiated extension")
        }
        if hasRSV1 && (!compressionEnabled || isControlFrame || opcode == .continueFrame) {
            return protocolFailure("RSV1 is only valid on an initial compressed data frame")
        }
        if isControlFrame && !isFin {
            return protocolFailure("control frames can't be fragmented")
        }
        if isControlFrame && payloadLengthMarker > 125 {
            return protocolFailure("control frame payloads must use a length no greater than 125")
        }

        var offset = 2
        let dataLength: UInt64
        switch payloadLengthMarker {
        case 126:
            let size = MemoryLayout<UInt16>.size
            guard pointer.count - offset >= size else { return .needsMoreData }
            dataLength = UInt64(pointer.readUint16(offset: offset))
            offset += size
            if dataLength < 126 {
                return protocolFailure("payload length was not encoded in its shortest form")
            }
        case 127:
            let size = MemoryLayout<UInt64>.size
            guard pointer.count - offset >= size else { return .needsMoreData }
            if pointer[offset] & 0x80 != 0 {
                return protocolFailure("the most significant bit of a 64-bit payload length must be zero")
            }
            dataLength = pointer.readUint64(offset: offset)
            offset += size
            if dataLength <= UInt64(UInt16.max) {
                return protocolFailure("payload length was not encoded in its shortest form")
            }
        default:
            dataLength = UInt64(payloadLengthMarker)
        }

        guard dataLength <= UInt64(Int.max) else {
            return protocolFailure("payload length exceeds this platform's supported size")
        }
        guard dataLength <= UInt64(limits.maximumFrameSize) else {
            return messageTooBigFailure(
                "frame payload exceeds the configured maximum of \(limits.maximumFrameSize) bytes"
            )
        }

        var maskStart: Int?
        if isMasked {
            let size = MemoryLayout<UInt32>.size
            guard pointer.count - offset >= size else { return .needsMoreData }
            maskStart = offset
            offset += size
        }

        let readableLength = Int(dataLength)
        guard readableLength <= pointer.count - offset else {
            return .needsMoreData
        }

        let rawPayload: Data
        if let maskStart {
            rawPayload = pointer.unmaskData(maskStart: maskStart, offset: offset, length: readableLength)
        } else {
            rawPayload = Data(pointer[offset..<(offset + readableLength)])
        }
        offset += readableLength

        let payload: Data
        let reportedPayloadLength: UInt64
        let closeCode: UInt16
        if opcode == .connectionClose {
            switch rawPayload.count {
            case 0:
                closeCode = CloseCode.noStatusReceived.rawValue
                payload = Data()
            case 1:
                return protocolFailure("close frames cannot contain a one-byte payload")
            default:
                let closeBytes = [UInt8](rawPayload)
                let candidate = closeBytes.readUint16(offset: 0)
                guard isValidCloseCode(candidate, sentByServer: !isServer) else {
                    return protocolFailure("invalid close code: \(candidate)")
                }
                closeCode = candidate
                payload = Data(closeBytes.dropFirst(MemoryLayout<UInt16>.size))
            }
            reportedPayloadLength = UInt64(payload.count)
        } else {
            closeCode = CloseCode.normal.rawValue
            payload = rawPayload
            reportedPayloadLength = dataLength
        }

        let frame = Frame(
            isFin: isFin,
            needsDecompression: hasRSV1,
            isMasked: isMasked,
            opcode: opcode,
            payloadLength: reportedPayloadLength,
            payload: payload,
            closeCode: closeCode,
            maximumMessageSize: limits.maximumMessageSize
        )
        return .processedFrame(frame, offset)
    }
    
    public func createWriteFrame(opcode: FrameOpCode, payload: Data, isCompressed: Bool) -> Data {
        switch createWriteFrameResult(opcode: opcode, payload: payload, isCompressed: isCompressed) {
        case .success(let frame):
            return frame
        case .failure:
            return Data()
        }
    }

    public func createWriteFrameResult(opcode: FrameOpCode, payload: Data, isCompressed: Bool) -> Result<Data, Error> {
        if let error = validateWriteFrame(opcode: opcode, payload: payload, isCompressed: isCompressed) {
            return .failure(error)
        }

        let payloadLength = payload.count
        let capacity = payloadLength + MaxFrameSize
        var pointer = [UInt8](repeating: 0, count: capacity)
        
        //set the framing info
        pointer[0] = FinMask | opcode.rawValue
        if isCompressed {
            pointer[0] |= RSV1Mask
        }
        
        var offset = 2 //skip pass the framing info
        if payloadLength < 126 {
            pointer[1] = UInt8(payloadLength)
        } else if payloadLength <= Int(UInt16.max) {
            pointer[1] = 126
            writeUint16(&pointer, offset: offset, value: UInt16(payloadLength))
            offset += MemoryLayout<UInt16>.size
        } else {
            pointer[1] = 127
            writeUint64(&pointer, offset: offset, value: UInt64(payloadLength))
            offset += MemoryLayout<UInt64>.size
        }
        
        //clients are required to mask the payload data, but server don't according to the RFC
        if !isServer {
            pointer[1] |= MaskMask
            
            //write the random mask key in
            let maskKey: UInt32 = UInt32.random(in: 0...UInt32.max)
            
            writeUint32(&pointer, offset: offset, value: maskKey)
            let maskStart = offset
            offset += MemoryLayout<UInt32>.size
            
            //now write the payload data in
            for (index, byte) in payload.enumerated() {
                pointer[offset] = byte ^ pointer[maskStart + (index % MemoryLayout<UInt32>.size)]
                offset += 1
            }
        } else {
            for byte in payload {
                pointer[offset] = byte
                offset += 1
            }
        }
        return .success(Data(pointer[0..<offset]))
    }

    private func validateWriteFrame(opcode: FrameOpCode, payload: Data, isCompressed: Bool) -> WSError? {
        guard opcode != .unknown else {
            return Self.makeProtocolError("cannot write a reserved or unknown opcode")
        }
        guard payload.count <= Int.max - MaxFrameSize else {
            return WSError(
                type: .protocolError,
                message: "payload is too large to frame on this platform",
                code: CloseCode.messageTooBig.rawValue
            )
        }
        let maximumPayloadSize = min(limits.maximumFrameSize, limits.maximumMessageSize)
        guard payload.count <= maximumPayloadSize else {
            return WSError(
                type: .protocolError,
                message: "payload exceeds the configured maximum of \(maximumPayloadSize) bytes",
                code: CloseCode.messageTooBig.rawValue
            )
        }
        if isCompressed {
            guard compressionEnabled else {
                return Self.makeProtocolError("cannot set RSV1 without compression support")
            }
            if opcode != .textFrame && opcode != .binaryFrame {
                return Self.makeProtocolError("only text and binary frames may set RSV1")
            }
        } else if opcode == .textFrame && String(data: payload, encoding: .utf8) == nil {
            return WSError(
                type: .protocolError,
                message: "text frame payload must be valid UTF-8",
                code: CloseCode.encoding.rawValue
            )
        }
        if opcode.isControlFrame && payload.count > 125 {
            return Self.makeProtocolError("control frame payloads cannot exceed 125 bytes")
        }
        if opcode == .connectionClose {
            switch payload.count {
            case 0:
                break
            case 1:
                return Self.makeProtocolError("close frames cannot contain a one-byte payload")
            default:
                let bytes = [UInt8](payload)
                let code = bytes.readUint16(offset: 0)
                guard Self.isValidCloseCode(code, sentByServer: isServer) else {
                    return Self.makeProtocolError("invalid close code: \(code)")
                }
                let reason = Data(bytes.dropFirst(MemoryLayout<UInt16>.size))
                guard String(data: reason, encoding: .utf8) != nil else {
                    return WSError(
                        type: .protocolError,
                        message: "close reason must be valid UTF-8",
                        code: CloseCode.encoding.rawValue
                    )
                }
            }
        }
        return nil
    }

    private static func isValidCloseCode(_ code: UInt16, sentByServer: Bool) -> Bool {
        if sentByServer && code == CloseCode.mandatoryExtension.rawValue {
            return false
        }
        if (1000...1014).contains(code) {
            return code != 1004 && code != 1005 && code != 1006
        }
        return (3000...4999).contains(code)
    }

    private static func protocolFailure(_ message: String) -> ProcessEvent {
        .failed(makeProtocolError(message))
    }

    private static func messageTooBigFailure(_ message: String) -> ProcessEvent {
        .failed(WSError(
            type: .protocolError,
            message: message,
            code: CloseCode.messageTooBig.rawValue
        ))
    }

    private static func makeProtocolError(_ message: String) -> WSError {
        WSError(type: .protocolError, message: message, code: CloseCode.protocolError.rawValue)
    }
}

private extension FrameOpCode {
    var isControlFrame: Bool {
        self == .connectionClose || self == .ping || self == .pong
    }
}

/// MARK: - functions for simpler array buffer reading and writing

public protocol MyWSArrayType {}
extension UInt8: MyWSArrayType {}

public extension Array where Element: MyWSArrayType & UnsignedInteger {
    
    /**
     Read a UInt16 from a buffer.
     - parameter offset: is the offset index to start the read from (e.g. buffer[0], buffer[1], etc).
     - returns: a UInt16 of the value from the buffer
     */
    func readUint16(offset: Int) -> UInt16 {
        return (UInt16(self[offset + 0]) << 8) | UInt16(self[offset + 1])
    }
    
    /**
     Read a UInt64 from a buffer.
     - parameter offset: is the offset index to start the read from (e.g. buffer[0], buffer[1], etc).
     - returns: a UInt64 of the value from the buffer
     */
    func readUint64(offset: Int) -> UInt64 {
        var value = UInt64(0)
        for i in 0...7 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        return value
    }
    
    func unmaskData(maskStart: Int, offset: Int, length: Int) -> Data {
        var unmaskedBytes = [UInt8](repeating: 0, count: length)
        let maskSize = MemoryLayout<UInt32>.size
        for i in 0..<length {
            unmaskedBytes[i] = UInt8(self[offset + i] ^ self[maskStart + (i % maskSize)])
        }
        return Data(unmaskedBytes)
    }
}

/**
 Write a UInt16 to the buffer. It fills the 2 array "slots" of the UInt8 array.
 - parameter buffer: is the UInt8 array (pointer) to write the value too.
 - parameter offset: is the offset index to start the write from (e.g. buffer[0], buffer[1], etc).
 */
public func writeUint16( _ buffer: inout [UInt8], offset: Int, value: UInt16) {
    buffer[offset + 0] = UInt8(value >> 8)
    buffer[offset + 1] = UInt8(value & 0xff)
}

/**
 Write a UInt32 to the buffer. It fills the 4 array "slots" of the UInt8 array.
 - parameter buffer: is the UInt8 array (pointer) to write the value too.
 - parameter offset: is the offset index to start the write from (e.g. buffer[0], buffer[1], etc).
 */
public func writeUint32( _ buffer: inout [UInt8], offset: Int, value: UInt32) {
    for i in 0...3 {
        buffer[offset + i] = UInt8((value >> (8*UInt32(3 - i))) & 0xff)
    }
}

/**
 Write a UInt64 to the buffer. It fills the 8 array "slots" of the UInt8 array.
 - parameter buffer: is the UInt8 array (pointer) to write the value too.
 - parameter offset: is the offset index to start the write from (e.g. buffer[0], buffer[1], etc).
 */
public func writeUint64( _ buffer: inout [UInt8], offset: Int, value: UInt64) {
    for i in 0...7 {
        buffer[offset + i] = UInt8((value >> (8*UInt64(7 - i))) & 0xff)
    }
}
