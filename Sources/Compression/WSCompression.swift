//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  WSCompression.swift
//
//  Created by Joseph Ross on 7/16/14.
//  Copyright © 2017 Joseph Ross & Vluxe. All rights reserved.
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

//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Compression implementation is implemented in conformance with RFC 7692 Compression Extensions
//  for WebSocket: https://tools.ietf.org/html/rfc7692
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
import zlib

public final class WSCompression: CompressionHandler {
    private struct State {
        var decompressor: Decompressor?
        var compressor: Compressor?
        var decompressorNoContextTakeover = false
        var compressorNoContextTakeover = false
        var decompressedMessageBytes = 0
    }

    private static let extensionHeaderName = "Sec-WebSocket-Extensions"
    private static let perMessageDeflate = "permessage-deflate"
    private let state = Locked(State())
    private let maximumDecompressedMessageSize: Int

    public init(
        maximumDecompressedMessageSize: Int = WebSocketLimits.default.maximumDecompressedMessageSize
    ) {
        self.maximumDecompressedMessageSize = max(0, maximumDecompressedMessageSize)
    }

    public convenience init(limits: WebSocketLimits) {
        self.init(maximumDecompressedMessageSize: limits.maximumDecompressedMessageSize)
    }
    
    @discardableResult
    public func load(headers: [String: String]) -> Bool {
        guard let extensionHeader = headers.first(where: {
            $0.key.caseInsensitiveCompare(Self.extensionHeaderName) == .orderedSame
        })?.value,
              let negotiatedState = Self.parseNegotiatedState(extensionHeader) else {
            reset()
            return false
        }

        state.withLock { $0 = negotiatedState }
        return true
    }

    public func reset() {
        state.withLock { $0 = State() }
    }

    public func decompress(data: Data, isFinal: Bool) throws -> Data {
        try state.withLock { state in
            guard let decompressor = state.decompressor else {
                throw WSError(
                    type: .compressionError,
                    message: "permessage-deflate was not negotiated",
                    code: CloseCode.protocolError.rawValue
                )
            }

            do {
                guard state.decompressedMessageBytes <= maximumDecompressedMessageSize else {
                    throw Self.messageTooBigError(maximum: maximumDecompressedMessageSize)
                }
                let remaining = maximumDecompressedMessageSize - state.decompressedMessageBytes
                let decompressedData = try decompressor.decompress(
                    data,
                    finish: isFinal,
                    maximumOutputSize: remaining
                )
                state.decompressedMessageBytes += decompressedData.count
                if state.decompressorNoContextTakeover && isFinal {
                    try decompressor.reset()
                }
                if isFinal {
                    state.decompressedMessageBytes = 0
                }
                return decompressedData
            } catch {
                // An inflater cannot be safely reused after a stream error.
                state.decompressor = nil
                state.decompressedMessageBytes = 0
                throw error
            }
        }
    }

    public func compress(data: Data) -> Data? {
        state.withLock { state in
            guard let compressor = state.compressor else { return nil }
            do {
                let compressedData = try compressor.compress(data)
                if state.compressorNoContextTakeover {
                    try compressor.reset()
                }
                return compressedData
            } catch {
                // A deflater cannot be safely reused after a stream error.
                state.compressor = nil
                return nil
            }
        }
    }

    private static func parseNegotiatedState(_ header: String) -> State? {
        let selections = header.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Starscream implements one extension. Accepting a second selection
        // would require understanding how it composes RSV bits and payload data.
        guard selections.count == 1 else { return nil }

        let parts = selections[0].split(
            separator: ";",
            omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = parts.first,
              name.caseInsensitiveCompare(perMessageDeflate) == .orderedSame else {
            return nil
        }

        var compressorWindowBits = 15
        var decompressorWindowBits = 15
        var compressorNoContextTakeover = false
        var decompressorNoContextTakeover = false
        var seenParameters = Set<String>()
        for part in parts.dropFirst() {
            let pair = part.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let rawParameter = pair.first, !rawParameter.isEmpty else {
                return nil
            }
            let parameter = rawParameter.lowercased()
            guard seenParameters.insert(parameter).inserted else {
                return nil
            }

            let normalizedValue = pair.count == 2
                ? WebSocketHandshake.normalizedExtensionParameterValue(pair[1])
                : nil
            if parameter == "server_max_window_bits", pair.count == 2,
               let normalizedValue, let val = Int(normalizedValue), (8...15).contains(val) {
                decompressorWindowBits = val
            } else if parameter == "client_max_window_bits", pair.count == 2,
                      let normalizedValue, let val = Int(normalizedValue), (8...15).contains(val) {
                compressorWindowBits = val
            } else if parameter == "client_no_context_takeover", pair.count == 1 {
                compressorNoContextTakeover = true
            } else if parameter == "server_no_context_takeover", pair.count == 1 {
                decompressorNoContextTakeover = true
            } else {
                return nil
            }
        }

        guard let compressor = Compressor(windowBits: compressorWindowBits),
              let decompressor = Decompressor(windowBits: decompressorWindowBits) else {
            return nil
        }

        return State(
            decompressor: decompressor,
            compressor: compressor,
            decompressorNoContextTakeover: decompressorNoContextTakeover,
            compressorNoContextTakeover: compressorNoContextTakeover
        )
    }

    private static func messageTooBigError(maximum: Int) -> WSError {
        WSError(
            type: .compressionError,
            message: "decompressed message exceeds the configured maximum of \(maximum) bytes",
            code: CloseCode.messageTooBig.rawValue
        )
    }
}

class Decompressor {
    private var strm = z_stream()
    private var buffer = [UInt8](repeating: 0, count: 0x2000)
    private var inflateInitialized = false
    private let windowBits: Int

    init?(windowBits: Int) {
        self.windowBits = windowBits
        guard initInflate() else { return nil }
    }

    private func initInflate() -> Bool {
        if Z_OK == inflateInit2_(&strm, -CInt(windowBits),
                                 ZLIB_VERSION, CInt(MemoryLayout<z_stream>.size))
        {
            inflateInitialized = true
            return true
        }
        return false
    }

    func reset() throws {
        teardownInflate()
        guard initInflate() else { throw WSError(type: .compressionError, message: "Error for decompressor on reset", code: 0) }
    }

    func decompress(
        _ data: Data,
        finish: Bool,
        maximumOutputSize: Int = Int.max
    ) throws -> Data {
        var decompressed = Data()
        if !data.isEmpty {
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let baseAddress = bytes.baseAddress else { return }
                try decompress(
                    bytes: baseAddress.assumingMemoryBound(to: UInt8.self),
                    count: bytes.count,
                    out: &decompressed,
                    maximumOutputSize: maximumOutputSize
                )
            }
        }

        if finish {
            let tail:[UInt8] = [0x00, 0x00, 0xFF, 0xFF]
            try decompress(
                bytes: tail,
                count: tail.count,
                out: &decompressed,
                maximumOutputSize: maximumOutputSize
            )
        }

        return decompressed
    }

    private func decompress(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        out: inout Data,
        maximumOutputSize: Int
    ) throws {
        var res: CInt = 0
        var outputCapacity = buffer.count
        strm.next_in = UnsafeMutablePointer<UInt8>(mutating: bytes)
        strm.avail_in = CUnsignedInt(count)

        repeat {
            guard out.count <= maximumOutputSize else {
                throw Self.messageTooBigError(maximum: maximumOutputSize)
            }
            let remaining = maximumOutputSize - out.count
            // Give zlib one sentinel byte beyond the limit. This distinguishes an
            // exact-boundary message from a stream that would produce more output,
            // without ever appending the excess byte to `Data`.
            outputCapacity = min(buffer.count, remaining == Int.max ? Int.max : remaining + 1)
            buffer.withUnsafeMutableBytes { (bufferPtr) in
                strm.next_out = bufferPtr.bindMemory(to: UInt8.self).baseAddress
                strm.avail_out = CUnsignedInt(outputCapacity)

                res = inflate(&strm, 0)
            }

            let byteCount = outputCapacity - Int(strm.avail_out)
            guard byteCount <= remaining else {
                throw Self.messageTooBigError(maximum: maximumOutputSize)
            }
            out.append(buffer, count: byteCount)
        } while res == Z_OK && strm.avail_out == 0

        guard (res == Z_OK && strm.avail_out > 0)
            || (res == Z_BUF_ERROR && Int(strm.avail_out) == outputCapacity)
            else {
                throw WSError(type: .compressionError, message: "Error on decompressing", code: 0)
        }
    }

    private static func messageTooBigError(maximum: Int) -> WSError {
        WSError(
            type: .compressionError,
            message: "decompressed output exceeds the configured maximum of \(maximum) bytes",
            code: CloseCode.messageTooBig.rawValue
        )
    }

    private func teardownInflate() {
        if inflateInitialized, Z_OK == inflateEnd(&strm) {
            inflateInitialized = false
        }
    }

    deinit {
        teardownInflate()
    }
}

class Compressor {
    private var strm = z_stream()
    private var buffer = [UInt8](repeating: 0, count: 0x2000)
    private var deflateInitialized = false
    private let windowBits: Int

    init?(windowBits: Int) {
        self.windowBits = windowBits
        guard initDeflate() else { return nil }
    }

    private func initDeflate() -> Bool {
        if Z_OK == deflateInit2_(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                 -CInt(windowBits), 8, Z_DEFAULT_STRATEGY,
                                 ZLIB_VERSION, CInt(MemoryLayout<z_stream>.size))
        {
            deflateInitialized = true
            return true
        }
        return false
    }

    func reset() throws {
        teardownDeflate()
        guard initDeflate() else { throw WSError(type: .compressionError, message: "Error for compressor on reset", code: 0) }
    }

    func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            // For example, PONG has no content
            return data
        }

        var compressed = Data()
        var res: CInt = 0
        data.withUnsafeBytes { (ptr:UnsafePointer<UInt8>) -> Void in
            strm.next_in = UnsafeMutablePointer<UInt8>(mutating: ptr)
            strm.avail_in = CUnsignedInt(data.count)

            repeat {
                buffer.withUnsafeMutableBytes { (bufferPtr) in
                    strm.next_out = bufferPtr.bindMemory(to: UInt8.self).baseAddress
                    strm.avail_out = CUnsignedInt(bufferPtr.count)

                    res = deflate(&strm, Z_SYNC_FLUSH)
                }

                let byteCount = buffer.count - Int(strm.avail_out)
                compressed.append(buffer, count: byteCount)
            }
            while res == Z_OK && strm.avail_out == 0

        }

        guard res == Z_OK && strm.avail_out > 0
            || (res == Z_BUF_ERROR && Int(strm.avail_out) == buffer.count)
        else {
            throw WSError(type: .compressionError, message: "Error on compressing", code: 0)
        }

        compressed.removeLast(4)
        return compressed
    }

    private func teardownDeflate() {
        if deflateInitialized, Z_OK == deflateEnd(&strm) {
            deflateInitialized = false
        }
    }

    deinit {
        teardownDeflate()
    }
}
