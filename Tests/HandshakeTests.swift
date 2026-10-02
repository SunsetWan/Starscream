//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  HandshakeTests.swift
//  Starscream
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
import Testing
@testable import Starscream

@Suite("WebSocket handshake")
struct WebSocketHandshakeTests {
    struct InvalidServerResponseCase: Sendable, CustomTestStringConvertible {
        let name: String
        let statusCode: Int
        let headers: [String: String]

        var testDescription: String { name }
    }

    struct InvalidServerRequestCase: Sendable, CustomTestStringConvertible {
        let name: String
        let method: String
        let version: String
        let headers: [String: String]

        var testDescription: String { name }
    }

    private static let offer = WebSocketHandshake.ClientOffer(
        key: "dGhlIHNhbXBsZSBub25jZQ==",
        protocols: ["chat"],
        extensions: ["permessage-deflate"]
    )

    private static let validRequestHeaders = [
        "Host": "server.example.com",
        "Upgrade": "websocket",
        "Connection": "Upgrade",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
    ]

    private static let invalidServerResponses = [
        InvalidServerResponseCase(
            name: "non-101 status",
            statusCode: 200,
            headers: [:]
        ),
        InvalidServerResponseCase(
            name: "missing Upgrade",
            statusCode: 101,
            headers: [
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            ]
        ),
        InvalidServerResponseCase(
            name: "Connection does not contain Upgrade",
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "keep-alive",
                "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            ]
        ),
        InvalidServerResponseCase(
            name: "missing Accept",
            statusCode: 101,
            headers: ["Upgrade": "websocket", "Connection": "Upgrade"]
        ),
        InvalidServerResponseCase(
            name: "invalid Accept",
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": "invalid",
            ]
        ),
        InvalidServerResponseCase(
            name: "unoffered protocol",
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                "Sec-WebSocket-Protocol": "not-offered",
            ]
        ),
        InvalidServerResponseCase(
            name: "multiple selected protocols",
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                "Sec-WebSocket-Protocol": "chat, chat",
            ]
        ),
        InvalidServerResponseCase(
            name: "unoffered extension",
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                "Sec-WebSocket-Extensions": "x-unknown",
            ]
        ),
    ]

    private static let invalidServerRequests = [
        InvalidServerRequestCase(
            name: "non-GET method",
            method: "POST",
            version: "HTTP/1.1",
            headers: validRequestHeaders
        ),
        InvalidServerRequestCase(
            name: "HTTP/1.0",
            method: "GET",
            version: "HTTP/1.0",
            headers: validRequestHeaders
        ),
        InvalidServerRequestCase(
            name: "missing Host",
            method: "GET",
            version: "HTTP/1.1",
            headers: removing("Host", from: validRequestHeaders)
        ),
        InvalidServerRequestCase(
            name: "invalid Upgrade token",
            method: "GET",
            version: "HTTP/1.1",
            headers: replacing("Upgrade", with: "h2c", in: validRequestHeaders)
        ),
        InvalidServerRequestCase(
            name: "missing Connection Upgrade token",
            method: "GET",
            version: "HTTP/1.1",
            headers: replacing("Connection", with: "keep-alive", in: validRequestHeaders)
        ),
        InvalidServerRequestCase(
            name: "unsupported WebSocket version",
            method: "GET",
            version: "HTTP/1.1",
            headers: replacing("Sec-WebSocket-Version", with: "12", in: validRequestHeaders)
        ),
        InvalidServerRequestCase(
            name: "key is not sixteen bytes",
            method: "GET",
            version: "HTTP/1.1",
            headers: replacing(
                "Sec-WebSocket-Key",
                with: Data(repeating: 0, count: 15).base64EncodedString(),
                in: validRequestHeaders
            )
        ),
        InvalidServerRequestCase(
            name: "invalid protocol list",
            method: "GET",
            version: "HTTP/1.1",
            headers: replacing("Sec-WebSocket-Protocol", with: "chat, ", in: validRequestHeaders)
        ),
        InvalidServerRequestCase(
            name: "invalid extension parameter",
            method: "GET",
            version: "HTTP/1.1",
            headers: replacing(
                "Sec-WebSocket-Extensions",
                with: "permessage-deflate; =bad",
                in: validRequestHeaders
            )
        ),
        InvalidServerRequestCase(
            name: "quoted extension parameter does not normalize to a token",
            method: "GET",
            version: "HTTP/1.1",
            headers: replacing(
                "Sec-WebSocket-Extensions",
                with: "permessage-deflate; client_max_window_bits=\"15 15\"",
                in: validRequestHeaders
            )
        ),
    ]

    @Test("Accept value matches the RFC 6455 example")
    func acceptValueMatchesRFC6455Example() {
        #expect(
            WebSocketHandshake.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
                == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    @Test("Generated client key decodes to sixteen bytes")
    func generatedClientKeyDecodesToSixteenBytes() throws {
        let decoded = try #require(Data(base64Encoded: HTTPWSHeader.generateWebSocketKey()))
        #expect(decoded.count == 16)
    }

    @Test("Header lookup and tokens are case insensitive")
    func headerLookupAndTokensAreCaseInsensitive() {
        let headers = [
            "uPgRaDe": "WebSocket",
            "CONNECTION": "keep-alive, Upgrade",
        ]

        #expect(WebSocketHandshake.header(named: "upgrade", in: headers) == "WebSocket")
        #expect(WebSocketHandshake.headerContainsToken(named: "connection", token: "upgrade", in: headers))
        #expect(!WebSocketHandshake.headerContainsToken(named: "connection", token: "close", in: headers))
    }

    @Test("Validates server response and negotiated values")
    func validatesServerResponseAndNegotiatedValues() throws {
        let offer = WebSocketHandshake.ClientOffer(
            key: "dGhlIHNhbXBsZSBub25jZQ==",
            protocols: ["chat", "superchat"],
            extensions: ["permessage-deflate; client_max_window_bits"]
        )
        let headers = [
            "Upgrade": "websocket",
            "Connection": "keep-alive, Upgrade",
            "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            "Sec-WebSocket-Protocol": "superchat",
            "Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits=15",
        ]

        try WebSocketHandshake.validateServerResponse(statusCode: 101, headers: headers, offer: offer)
    }

    @Test("Quoted extension values are unescaped before validation")
    func acceptsQuotedExtensionValues() throws {
        let offer = WebSocketHandshake.ClientOffer(
            key: "dGhlIHNhbXBsZSBub25jZQ==",
            extensions: [
                "permessage-deflate; client_max_window_bits; server_max_window_bits=15",
            ]
        )
        let headers = validServerResponseHeaders(
            extensions: "permessage-deflate; client_max_window_bits=\"1\\5\"; server_max_window_bits=\"15\""
        )

        try WebSocketHandshake.validateServerResponse(
            statusCode: 101,
            headers: headers,
            offer: offer
        )
    }

    @Test("Rejects client window bits that were not offered")
    func rejectsUnofferedClientWindowBits() {
        let headers = validServerResponseHeaders(
            extensions: "permessage-deflate; client_max_window_bits=15"
        )

        #expect(throws: WebSocketHandshake.ValidationError.self) {
            try WebSocketHandshake.validateServerResponse(
                statusCode: 101,
                headers: headers,
                offer: Self.offer
            )
        }
    }

    @Test("Rejects a server window larger than the offered maximum")
    func rejectsServerWindowLargerThanOffer() {
        let offer = WebSocketHandshake.ClientOffer(
            key: "dGhlIHNhbXBsZSBub25jZQ==",
            extensions: ["permessage-deflate; server_max_window_bits=10"]
        )
        let headers = validServerResponseHeaders(
            extensions: "permessage-deflate; server_max_window_bits=11"
        )

        #expect(throws: WebSocketHandshake.ValidationError.self) {
            try WebSocketHandshake.validateServerResponse(
                statusCode: 101,
                headers: headers,
                offer: offer
            )
        }
    }

    @Test("Client window offer values are hints, not response ceilings")
    func acceptsClientWindowLargerThanHint() throws {
        let offer = WebSocketHandshake.ClientOffer(
            key: "dGhlIHNhbXBsZSBub25jZQ==",
            extensions: ["permessage-deflate; client_max_window_bits=10"]
        )
        let headers = validServerResponseHeaders(
            extensions: "permessage-deflate; client_max_window_bits=15"
        )

        try WebSocketHandshake.validateServerResponse(
            statusCode: 101,
            headers: headers,
            offer: offer
        )
    }

    @Test("Rejects invalid server responses", arguments: invalidServerResponses)
    func rejectsInvalidServerResponse(_ testCase: InvalidServerResponseCase) {
        #expect(throws: WebSocketHandshake.ValidationError.self) {
            try WebSocketHandshake.validateServerResponse(
                statusCode: testCase.statusCode,
                headers: testCase.headers,
                offer: Self.offer
            )
        }
    }

    @Test("Validates server requests case insensitively")
    func validatesServerRequestCaseInsensitively() throws {
        let request = try WebSocketHandshake.validateServerRequest(
            method: "GET",
            httpVersion: "HTTP/1.1",
            headers: [
                "host": "server.example.com",
                "uPgRaDe": "WebSocket",
                "CONNECTION": "keep-alive, Upgrade",
                "sec-websocket-version": "13",
                "SEC-WEBSOCKET-KEY": "dGhlIHNhbXBsZSBub25jZQ==",
                "Sec-WebSocket-Protocol": "chat, superchat",
                "Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits",
            ]
        )

        #expect(request.key == "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(request.protocols == ["chat", "superchat"])
        #expect(request.extensions == ["permessage-deflate; client_max_window_bits"])
    }

    @Test("Rejects invalid server requests", arguments: invalidServerRequests)
    func rejectsInvalidServerRequest(_ testCase: InvalidServerRequestCase) {
        #expect(throws: WebSocketHandshake.ValidationError.self) {
            try WebSocketHandshake.validateServerRequest(
                method: testCase.method,
                httpVersion: testCase.version,
                headers: testCase.headers
            )
        }
    }

    @Test("Builds complete server response and validates selections")
    func buildsCompleteServerResponseAndValidatesSelections() throws {
        let request = WebSocketHandshake.ServerRequest(
            key: "dGhlIHNhbXBsZSBub25jZQ==",
            protocols: ["chat", "superchat"],
            extensions: ["permessage-deflate; client_max_window_bits"]
        )

        let headers = try WebSocketHandshake.serverResponseHeaders(
            for: request,
            selectedProtocol: "chat",
            selectedExtensions: ["permessage-deflate; client_max_window_bits=15"]
        )

        #expect(WebSocketHandshake.header(named: "Upgrade", in: headers) == "websocket")
        #expect(WebSocketHandshake.header(named: "Connection", in: headers) == "Upgrade")
        #expect(
            WebSocketHandshake.header(named: "Sec-WebSocket-Accept", in: headers)
                == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
        #expect(WebSocketHandshake.header(named: "Sec-WebSocket-Protocol", in: headers) == "chat")
        #expect(
            WebSocketHandshake.header(named: "Sec-WebSocket-Extensions", in: headers)
                == "permessage-deflate; client_max_window_bits=15"
        )

        #expect(throws: WebSocketHandshake.ValidationError.self) {
            try WebSocketHandshake.serverResponseHeaders(for: request, selectedProtocol: "other")
        }
        #expect(throws: WebSocketHandshake.ValidationError.self) {
            try WebSocketHandshake.serverResponseHeaders(for: request, selectedExtensions: ["x-unknown"])
        }
    }

    private static func replacing(
        _ key: String,
        with value: String,
        in headers: [String: String]
    ) -> [String: String] {
        var result = headers
        result[key] = value
        return result
    }

    private static func removing(_ key: String, from headers: [String: String]) -> [String: String] {
        var result = headers
        result.removeValue(forKey: key)
        return result
    }

    private func validServerResponseHeaders(extensions: String) -> [String: String] {
        [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            "Sec-WebSocket-Extensions": extensions,
        ]
    }
}
