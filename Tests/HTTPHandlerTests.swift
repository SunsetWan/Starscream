//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  HTTPHandlerTests.swift
//  Starscream
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Starscream

@Suite("Client HTTP handlers")
struct HTTPHandlerTests {
    enum HandlerKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case foundation
        case string

        var testDescription: String { rawValue }

        func makeHandler() -> any HTTPHandler {
            switch self {
            case .foundation:
                FoundationHTTPHandler()
            case .string:
                StringHTTPHandler()
            }
        }
    }

    struct InvalidResponseCase: Sendable, CustomTestStringConvertible {
        let name: String
        let response: String

        var testDescription: String { name }
    }

    private static let response = """
    HTTP/1.1 101 Switching Protocols\r
    uPgRaDe: WebSocket\r
    CONNECTION: keep-alive, Upgrade\r
    Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
    \r\n
    """

    private static let invalidResponses = [
        InvalidResponseCase(
            name: "non-101 status",
            response: "HTTP/1.1 200 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        ),
        InvalidResponseCase(
            name: "missing Upgrade header",
            response: "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n\r\n"
        ),
        InvalidResponseCase(
            name: "Connection does not contain Upgrade",
            response: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive\r\n\r\n"
        ),
        InvalidResponseCase(
            name: "obsolete folded header",
            response: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n Connection: Upgrade\r\n\r\n"
        ),
    ]

    @Test(arguments: HandlerKind.allCases)
    func `Client parser preserves leftover across every header split`(_ handlerKind: HandlerKind) throws {
        let headerData = Data(Self.response.utf8)
        let frame = Data([0x81, 0x02, 0x68, 0x69])

        for split in 0..<headerData.count {
            let handler = handlerKind.makeHandler()
            let delegate = ClientHTTPDelegate()
            handler.register(delegate: delegate)

            #expect(handler.parse(data: Data(headerData.prefix(split))) == -1)
            #expect(delegate.events.isEmpty)

            var finalChunk = Data(headerData.dropFirst(split))
            finalChunk.append(frame)
            #expect(handler.parse(data: finalChunk) == headerData.count - split)

            let (headers, leftover) = try success(from: delegate.events)
            #expect(WebSocketHandshake.headerContainsToken(named: "Upgrade", token: "websocket", in: headers))
            #expect(WebSocketHandshake.headerContainsToken(named: "Connection", token: "upgrade", in: headers))
            #expect(leftover == frame)
        }
    }

    @Test(arguments: HandlerKind.allCases, invalidResponses)
    func `Client parser rejects invalid upgrade response`(
        _ handlerKind: HandlerKind,
        _ testCase: InvalidResponseCase
    ) throws {
        let handler = handlerKind.makeHandler()
        let delegate = ClientHTTPDelegate()
        handler.register(delegate: delegate)
        _ = handler.parse(data: Data(testCase.response.utf8))

        #expect(delegate.events.count == 1)
        #expect(isFailure(try #require(delegate.events.first)))
    }

    @Test(arguments: HandlerKind.allCases)
    func `Client parser waits for an incomplete upgrade response`(_ handlerKind: HandlerKind) {
        let handler = handlerKind.makeHandler()
        let delegate = ClientHTTPDelegate()
        handler.register(delegate: delegate)

        #expect(handler.parse(data: Data("HTTP/1.1 101 Switching".utf8)) == -1)
        #expect(delegate.events.isEmpty)
    }

    @Test(arguments: HandlerKind.allCases)
    func `Client parser bounds incomplete header memory`(_ handlerKind: HandlerKind) throws {
        var oversized = Data("HTTP/1.1 101 Switching Protocols\r\nX-Fill: ".utf8)
        oversized.append(Data(repeating: 0x61, count: 64 * 1024))
        let handler = handlerKind.makeHandler()
        let delegate = ClientHTTPDelegate()
        handler.register(delegate: delegate)

        _ = handler.parse(data: oversized)

        #expect(delegate.events.count == 1)
        #expect(isFailure(try #require(delegate.events.first)))
    }

    @Test(arguments: HandlerKind.allCases)
    func `Client request adapter serializes origin form and required headers`(
        _ handlerKind: HandlerKind
    ) throws {
        var source = URLRequest(url: try #require(URL(string: "wss://example.com/chat?room=blue")))
        source.httpMethod = "POST"
        source.setValue("chat, superchat", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let request = HTTPWSHeader.createUpgrade(
            request: source,
            supportsCompression: true,
            secKeyValue: "dGhlIHNhbXBsZSBub25jZQ=="
        )

        let serialized = try #require(
            String(data: handlerKind.makeHandler().convert(request: request), encoding: .utf8)
        )
        #expect(serialized.hasPrefix("GET /chat?room=blue HTTP/1.1\r\n"))
        #expect(serialized.localizedCaseInsensitiveContains("Host: example.com\r\n"))
        #expect(serialized.localizedCaseInsensitiveContains("Upgrade: websocket\r\n"))
        #expect(serialized.localizedCaseInsensitiveContains("Connection: Upgrade\r\n"))
        #expect(serialized.localizedCaseInsensitiveContains("Sec-WebSocket-Version: 13\r\n"))
        #expect(
            serialized.localizedCaseInsensitiveContains(
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            )
        )
    }
}

@Suite("Server HTTP handler")
struct HTTPServerHandlerTests {
    struct InvalidRequestCase: Sendable, CustomTestStringConvertible {
        let name: String
        let request: String

        var testDescription: String { name }
    }

    struct InvalidSelectionCase: Sendable, CustomTestStringConvertible {
        let name: String
        let headers: [String: String]

        var testDescription: String { name }
    }

    private static let request = """
    GET /chat HTTP/1.1\r
    host: server.example.com\r
    Upgrade: websocket\r
    Connection: keep-alive, Upgrade\r
    Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
    Sec-WebSocket-Version: 13\r
    Sec-WebSocket-Protocol: chat, superchat\r
    Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r
    \r\n
    """

    private static let invalidRequests = [
        InvalidRequestCase(
            name: "non-GET method",
            request: request.replacingOccurrences(of: "GET /chat HTTP/1.1", with: "POST /chat HTTP/1.1")
        ),
        InvalidRequestCase(
            name: "HTTP/1.0",
            request: request.replacingOccurrences(of: "GET /chat HTTP/1.1", with: "GET /chat HTTP/1.0")
        ),
        InvalidRequestCase(
            name: "missing Host",
            request: request.replacingOccurrences(of: "host: server.example.com\r\n", with: "")
        ),
        InvalidRequestCase(
            name: "invalid Upgrade token",
            request: request.replacingOccurrences(of: "Upgrade: websocket", with: "Upgrade: h2c")
        ),
        InvalidRequestCase(
            name: "missing Connection Upgrade token",
            request: request.replacingOccurrences(
                of: "Connection: keep-alive, Upgrade",
                with: "Connection: keep-alive"
            )
        ),
        InvalidRequestCase(
            name: "unsupported WebSocket version",
            request: request.replacingOccurrences(of: "Sec-WebSocket-Version: 13", with: "Sec-WebSocket-Version: 12")
        ),
        InvalidRequestCase(
            name: "invalid key",
            request: request.replacingOccurrences(of: "dGhlIHNhbXBsZSBub25jZQ==", with: "aW52YWxpZA==")
        ),
    ]

    private static let invalidSelections = [
        InvalidSelectionCase(
            name: "unoffered protocol",
            headers: ["Sec-WebSocket-Protocol": "not-offered"]
        ),
        InvalidSelectionCase(
            name: "unoffered extension",
            headers: ["Sec-WebSocket-Extensions": "x-unknown"]
        ),
    ]

    @Test
    func `Server parser validates incremental request and preserves leftover`() throws {
        let requestData = Data(Self.request.utf8)
        let frame = Data([0x81, 0x80, 0, 0, 0, 0])

        for split in 0..<requestData.count {
            let handler = FoundationHTTPServerHandler()
            let delegate = ServerHTTPDelegate()
            handler.register(delegate: delegate)
            handler.parse(data: Data(requestData.prefix(split)))
            #expect(delegate.events.isEmpty)

            var finalChunk = Data(requestData.dropFirst(split))
            finalChunk.append(frame)
            handler.parse(data: finalChunk)

            let (headers, leftover) = try success(from: delegate.events)
            #expect(WebSocketHandshake.header(named: "Host", in: headers) == "server.example.com")
            #expect(leftover == frame)
        }
    }

    @Test
    func `Server creates complete RFC 6455 response`() throws {
        let handler = parsedServerHandler()
        let responseData = handler.createResponse(headers: [
            "Sec-WebSocket-Protocol": "chat",
            "Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits=15",
        ])
        let response = try #require(String(data: responseData, encoding: .utf8))

        #expect(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        #expect(response.localizedCaseInsensitiveContains("Upgrade: websocket\r\n"))
        #expect(response.localizedCaseInsensitiveContains("Connection: Upgrade\r\n"))
        #expect(
            response.localizedCaseInsensitiveContains(
                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
            )
        )
        #expect(response.localizedCaseInsensitiveContains("Sec-WebSocket-Protocol: chat\r\n"))
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test(arguments: invalidRequests)
    func `Server rejects invalid request`(_ testCase: InvalidRequestCase) throws {
        let handler = FoundationHTTPServerHandler()
        let delegate = ServerHTTPDelegate()
        handler.register(delegate: delegate)
        handler.parse(data: Data(testCase.request.utf8))

        #expect(delegate.events.count == 1)
        #expect(isFailure(try #require(delegate.events.first)))
    }

    @Test(arguments: invalidSelections)
    func `Server rejects invalid selection`(_ testCase: InvalidSelectionCase) {
        #expect(parsedServerHandler().createResponse(headers: testCase.headers).isEmpty)
    }

    private func parsedServerHandler() -> FoundationHTTPServerHandler {
        let handler = FoundationHTTPServerHandler()
        let delegate = ServerHTTPDelegate()
        handler.register(delegate: delegate)
        handler.parse(data: Data(Self.request.utf8))
        return handler
    }
}

private func success(from events: [HTTPEvent]) throws -> ([String: String], Data) {
    let value = events.first.flatMap { event -> ([String: String], Data)? in
        guard case let .success(headers: headers, leftover: leftover) = event else { return nil }
        return (headers, leftover)
    }
    return try #require(value, "Expected leftover-aware success event")
}

private func isFailure(_ event: HTTPEvent) -> Bool {
    if case .failure = event { return true }
    return false
}

private final class ClientHTTPDelegate: HTTPHandlerDelegate {
    var events = [HTTPEvent]()

    func didReceiveHTTP(event: HTTPEvent) {
        events.append(event)
    }
}

private final class ServerHTTPDelegate: HTTPServerDelegate {
    var events = [HTTPEvent]()

    func didReceive(event: HTTPEvent) {
        events.append(event)
    }
}
