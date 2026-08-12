//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  CompressionTests.swift
//
//  Created by Joseph Ross on 7/16/14.
//  Copyright © 2017 Joseph Ross.
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

@Suite
struct CompressionTests {
    @Test
    func `Basic compression round trip`() throws {
        let compressor = try #require(Compressor(windowBits: 15))
        let decompressor = try #require(Decompressor(windowBits: 15))

        let rawData = Data("Hello, World! Hello, World! Hello, World! Hello, World! Hello, World!".utf8)

        let compressed = try compressor.compress(rawData)
        let uncompressed = try decompressor.decompress(compressed, finish: true)

        #expect(rawData == uncompressed)
    }

    @Test
    func `Large random payload round trip`() throws {
        let compressor = try #require(Compressor(windowBits: 15))
        let decompressor = try #require(Decompressor(windowBits: 15))

        var rawData = Data(repeating: 0, count: 0x80000)
        rawData.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            arc4random_buf(buffer.baseAddress, buffer.count)
        }

        let compressed = try compressor.compress(rawData)
        let uncompressed = try decompressor.decompress(compressed, finish: true)

        #expect(rawData == uncompressed)
    }

    @Test
    func `Negotiates permessage-deflate case-insensitively`() throws {
        let compression = WSCompression()

        #expect(compression.load(headers: [
            "sec-websocket-extensions": "PerMessage-Deflate; client_max_window_bits=15; server_max_window_bits=15",
        ]))

        let message = Data("a negotiated compressed message".utf8)
        let compressed = try #require(compression.compress(data: message))
        #expect(try compression.decompress(data: compressed, isFinal: true) == message)
    }

    @Test
    func `Negotiates quoted and escaped window bits`() throws {
        let compression = WSCompression()

        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits=\"1\\5\"; server_max_window_bits=\"15\"",
        ]))

        let message = Data("quoted extension parameters".utf8)
        let compressed = try #require(compression.compress(data: message))
        #expect(try compression.decompress(data: compressed, isFinal: true) == message)
    }

    @Test
    func `Unknown extension does not enable compression`() {
        let compression = WSCompression()

        #expect(!compression.load(headers: [
            "Sec-WebSocket-Extensions": "x-unknown-extension",
        ]))
        #expect(compression.compress(data: Data("message".utf8)) == nil)
        #expect(throws: (any Error).self) {
            try compression.decompress(data: Data([0x00]), isFinal: true)
        }
    }

    @Test(arguments: [
        "permessage-deflate; unknown_parameter",
        "permessage-deflate; server_max_window_bits=15; server_max_window_bits=14",
        "permessage-deflate; client_no_context_takeover=true",
        "permessage-deflate; client_max_window_bits=\"15 15\"",
    ])
    func `Invalid parameters reject negotiation`(header: String) {
        let compression = WSCompression()

        #expect(!compression.load(headers: ["Sec-WebSocket-Extensions": header]))
    }

    @Test
    func `Missing negotiation response clears previous connection state`() {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate",
        ]))
        #expect(compression.compress(data: Data("first connection".utf8)) != nil)

        #expect(!compression.load(headers: [:]))

        #expect(compression.compress(data: Data("second connection".utf8)) == nil)
        #expect(throws: (any Error).self) {
            try compression.decompress(data: Data([0x00]), isFinal: true)
        }
    }

    @Test
    func `Explicit reset clears negotiated state`() {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate",
        ]))

        compression.reset()

        #expect(compression.compress(data: Data("message".utf8)) == nil)
        #expect(throws: (any Error).self) {
            try compression.decompress(data: Data([0x00]), isFinal: true)
        }
    }

    @Test
    func `Server no-context-takeover resets only after final fragment`() throws {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate; server_no_context_takeover",
        ]))

        let firstMessage = Data(String(repeating: "fragmented-", count: 80).utf8)
        let firstCompressor = try #require(Compressor(windowBits: 15))
        let firstCompressed = try firstCompressor.compress(firstMessage)
        let split = max(1, firstCompressed.count / 2)
        var firstDecoded = try compression.decompress(
            data: Data(firstCompressed.prefix(split)),
            isFinal: false
        )
        firstDecoded.append(try compression.decompress(
            data: Data(firstCompressed.dropFirst(split)),
            isFinal: true
        ))
        #expect(firstDecoded == firstMessage)

        // An independently compressed second message requires the inflater to
        // reset exactly at the preceding message boundary.
        let secondMessage = Data(String(repeating: "next-message-", count: 40).utf8)
        let secondCompressor = try #require(Compressor(windowBits: 15))
        let secondCompressed = try secondCompressor.compress(secondMessage)
        #expect(try compression.decompress(data: secondCompressed, isFinal: true) == secondMessage)
    }

    @Test
    func `Client no-context-takeover produces independent messages`() throws {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate; client_no_context_takeover",
        ]))

        let messages = [
            Data(String(repeating: "repeated-prefix-", count: 30).utf8),
            Data(String(repeating: "repeated-prefix-", count: 30).utf8),
        ]
        let compressedMessages = try messages.map {
            try #require(compression.compress(data: $0))
        }

        for (message, compressed) in zip(messages, compressedMessages) {
            let independentDecompressor = try #require(Decompressor(windowBits: 15))
            #expect(try independentDecompressor.decompress(compressed, finish: true) == message)
        }
    }

    @Test
    func `Default context takeover supports consecutive messages`() throws {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate",
        ]))

        for message in [
            Data(String(repeating: "shared-dictionary-", count: 40).utf8),
            Data(String(repeating: "shared-dictionary-", count: 40).utf8),
        ] {
            let compressed = try #require(compression.compress(data: message))
            #expect(try compression.decompress(data: compressed, isFinal: true) == message)
        }
    }

    @Test
    func `Empty compressed message round trips`() throws {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate",
        ]))

        let compressed = try #require(compression.compress(data: Data()))

        #expect(compressed.isEmpty)
        #expect(try compression.decompress(data: compressed, isFinal: true).isEmpty)
    }

    @Test
    func `Empty non-final compressed fragment does not fail`() throws {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate",
        ]))
        let message = Data("payload after an empty fragment".utf8)
        let compressor = try #require(Compressor(windowBits: 15))
        let compressed = try compressor.compress(message)

        #expect(try compression.decompress(data: Data(), isFinal: false).isEmpty)
        #expect(try compression.decompress(data: compressed, isFinal: true) == message)
    }

    @Test
    func `Corrupt compressed stream throws`() throws {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate",
        ]))

        let error = #expect(throws: (any Error).self) {
            try compression.decompress(
                data: Data([0xFF, 0xFF, 0xFF, 0xFF]),
                isFinal: true
            )
        }
        let webSocketError = try #require(error as? WSError)
        #expect(webSocketError.type == .compressionError)
    }

    @Test
    func `Decompression stops when the configured message limit is exceeded`() throws {
        let compression = WSCompression(maximumDecompressedMessageSize: 4)
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate",
        ]))
        let compressor = try #require(Compressor(windowBits: 15))
        let compressed = try compressor.compress(Data("12345".utf8))

        let error = #expect(throws: (any Error).self) {
            try compression.decompress(data: compressed, isFinal: true)
        }
        let webSocketError = try #require(error as? WSError)
        #expect(webSocketError.code == CloseCode.messageTooBig.rawValue)
    }

    @Test
    func `Concurrent no-context compression is serialized safely`() {
        let compression = WSCompression()
        #expect(compression.load(headers: [
            "Sec-WebSocket-Extensions": "permessage-deflate; client_no_context_takeover",
        ]))
        let results = Locked<[Bool]>([])

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let message = Data(String(repeating: "message-\(index)-", count: 20).utf8)
            let matches: Bool
            if let compressed = compression.compress(data: message),
               let decompressor = Decompressor(windowBits: 15),
               let decoded = try? decompressor.decompress(compressed, finish: true) {
                matches = decoded == message
            } else {
                matches = false
            }
            results.withLock { $0.append(matches) }
        }

        #expect(results.withLock { $0.count } == 40)
        #expect(results.withLock { $0.allSatisfy { $0 } })
    }
}
