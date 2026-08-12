//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  WebSocketHandshake.swift
//  Starscream
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import CryptoKit
import Foundation

/// RFC 6455 opening-handshake semantics shared by the byte-level HTTP adapters.
public enum WebSocketHandshake {
    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case invalidStatusCode(Int)
        case invalidMethod(String)
        case invalidHTTPVersion(String)
        case missingHeader(String)
        case invalidHeader(String)
        case invalidKey
        case invalidAccept
        case invalidProtocol(String)
        case invalidExtension(String)
    }

    public struct ClientOffer: Sendable, Equatable {
        public let key: String
        public let protocols: [String]
        public let extensions: [String]

        public init(key: String, protocols: [String] = [], extensions: [String] = []) {
            self.key = key
            self.protocols = protocols
            self.extensions = extensions
        }
    }

    public struct ServerRequest: Sendable, Equatable {
        public let key: String
        public let protocols: [String]
        public let extensions: [String]

        public init(key: String, protocols: [String], extensions: [String]) {
            self.key = key
            self.protocols = protocols
            self.extensions = extensions
        }
    }

    public static func acceptValue(forKey key: String) -> String {
        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
    }

    public static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public static func headerContainsToken(named name: String, token: String, in headers: [String: String]) -> Bool {
        guard let value = header(named: name, in: headers) else { return false }
        let values = commaSeparatedValues(value)
        guard values.allSatisfy(isHTTPToken) else { return false }
        return values.contains {
            $0.caseInsensitiveCompare(token) == .orderedSame
        }
    }

    static func commaSeparatedValues(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static func validateServerResponse(
        statusCode: Int,
        headers: [String: String],
        offer: ClientOffer
    ) throws {
        try validateSwitchingProtocolsResponse(statusCode: statusCode, headers: headers)
        guard let accept = header(named: HTTPWSHeader.acceptName, in: headers) else {
            throw ValidationError.missingHeader(HTTPWSHeader.acceptName)
        }
        guard accept.trimmingCharacters(in: .whitespacesAndNewlines) == acceptValue(forKey: offer.key) else {
            throw ValidationError.invalidAccept
        }

        if let selectedProtocol = header(named: HTTPWSHeader.protocolName, in: headers) {
            let selections = commaSeparatedValues(selectedProtocol)
            guard selections.count == 1,
                  isHTTPToken(selections[0]),
                  offer.protocols.contains(selections[0]) else {
                throw ValidationError.invalidProtocol(selectedProtocol)
            }
        }

        if let selectedExtensions = header(named: HTTPWSHeader.extensionName, in: headers) {
            let selections = try parseExtensionList(selectedExtensions)
            guard !selections.isEmpty, Set(selections.compactMap(extensionName).map { $0.lowercased() }).count == selections.count else {
                throw ValidationError.invalidExtension(selectedExtensions)
            }
            for selection in selections {
                guard try extensionSelection(selection, matchesAny: offer.extensions) else {
                    throw ValidationError.invalidExtension(selection)
                }
            }
        }
    }

    public static func validateServerRequest(
        method: String,
        httpVersion: String,
        headers: [String: String]
    ) throws -> ServerRequest {
        guard method == "GET" else {
            throw ValidationError.invalidMethod(method)
        }
        guard httpVersion == "HTTP/1.1" else {
            throw ValidationError.invalidHTTPVersion(httpVersion)
        }
        guard let host = header(named: HTTPWSHeader.hostName, in: headers),
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.contains(",") else {
            throw ValidationError.missingHeader(HTTPWSHeader.hostName)
        }
        guard headerContainsToken(named: HTTPWSHeader.upgradeName, token: HTTPWSHeader.upgradeValue, in: headers) else {
            throw ValidationError.invalidHeader(HTTPWSHeader.upgradeName)
        }
        guard headerContainsToken(named: HTTPWSHeader.connectionName, token: HTTPWSHeader.connectionValue, in: headers) else {
            throw ValidationError.invalidHeader(HTTPWSHeader.connectionName)
        }
        guard header(named: HTTPWSHeader.versionName, in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == HTTPWSHeader.versionValue else {
            throw ValidationError.invalidHeader(HTTPWSHeader.versionName)
        }
        guard let key = header(named: HTTPWSHeader.keyName, in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.contains(","),
              let decodedKey = Data(base64Encoded: key),
              decodedKey.count == 16 else {
            throw ValidationError.invalidKey
        }

        let protocols: [String]
        if let value = header(named: HTTPWSHeader.protocolName, in: headers) {
            protocols = try parseProtocolList(value)
        } else {
            protocols = []
        }

        let extensions: [String]
        if let value = header(named: HTTPWSHeader.extensionName, in: headers) {
            extensions = try parseExtensionList(value)
        } else {
            extensions = []
        }

        return ServerRequest(key: key, protocols: protocols, extensions: extensions)
    }

    public static func serverResponseHeaders(
        for request: ServerRequest,
        selectedProtocol: String? = nil,
        selectedExtensions: [String] = []
    ) throws -> [String: String] {
        var headers = [
            HTTPWSHeader.upgradeName: HTTPWSHeader.upgradeValue,
            HTTPWSHeader.connectionName: HTTPWSHeader.connectionValue,
            HTTPWSHeader.acceptName: acceptValue(forKey: request.key),
        ]

        if let selectedProtocol {
            guard isHTTPToken(selectedProtocol), request.protocols.contains(selectedProtocol) else {
                throw ValidationError.invalidProtocol(selectedProtocol)
            }
            headers[HTTPWSHeader.protocolName] = selectedProtocol
        }

        if !selectedExtensions.isEmpty {
            let selections = try selectedExtensions.flatMap(parseExtensionList)
            var selectedNames = Set<String>()
            for selectedExtension in selections {
                guard let name = extensionName(selectedExtension),
                      try extensionSelection(selectedExtension, matchesAny: request.extensions),
                      selectedNames.insert(name.lowercased()).inserted else {
                    throw ValidationError.invalidExtension(selectedExtension)
                }
            }
            headers[HTTPWSHeader.extensionName] = selections.joined(separator: ", ")
        }

        return headers
    }

    public static func clientOffer(for request: URLRequest, key: String) throws -> ClientOffer {
        let protocols: [String]
        if let value = request.value(forHTTPHeaderField: HTTPWSHeader.protocolName) {
            protocols = try parseProtocolList(value)
        } else {
            protocols = []
        }
        let extensions: [String]
        if let value = request.value(forHTTPHeaderField: HTTPWSHeader.extensionName) {
            extensions = try parseExtensionList(value)
        } else {
            extensions = []
        }
        return ClientOffer(key: key, protocols: protocols, extensions: extensions)
    }

    static func validateSwitchingProtocolsResponse(statusCode: Int, headers: [String: String]) throws {
        guard statusCode == HTTPWSHeader.switchProtocolCode else {
            throw ValidationError.invalidStatusCode(statusCode)
        }
        guard headerContainsToken(named: HTTPWSHeader.upgradeName, token: HTTPWSHeader.upgradeValue, in: headers) else {
            throw ValidationError.invalidHeader(HTTPWSHeader.upgradeName)
        }
        guard headerContainsToken(named: HTTPWSHeader.connectionName, token: HTTPWSHeader.connectionValue, in: headers) else {
            throw ValidationError.invalidHeader(HTTPWSHeader.connectionName)
        }
    }

    static func isValidHTTPHeader(name: String, value: String) -> Bool {
        isHTTPToken(name) && value.unicodeScalars.allSatisfy {
            $0.value == 0x09 || $0.value >= 0x20 && $0.value != 0x7F
        }
    }

    private static func parseProtocolList(_ value: String) throws -> [String] {
        let protocols = commaSeparatedValues(value)
        guard !protocols.isEmpty,
              protocols.allSatisfy(isHTTPToken),
              Set(protocols).count == protocols.count else {
            throw ValidationError.invalidProtocol(value)
        }
        return protocols
    }

    private static func parseExtensionList(_ value: String) throws -> [String] {
        guard let extensions = splitHTTPList(value, separator: ","),
              !extensions.isEmpty,
              extensions.allSatisfy(isValidExtension) else {
            throw ValidationError.invalidExtension(value)
        }
        return extensions
    }

    private static func extensionName(_ value: String) -> String? {
        splitHTTPList(value, separator: ";")?.first
    }

    private struct ParsedExtension {
        struct Parameter {
            let name: String
            let value: String?
        }

        let name: String
        let parameters: [Parameter]

        func parameter(named name: String) -> Parameter? {
            parameters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    private static func extensionSelection(
        _ selection: String,
        matchesAny rawOffers: [String]
    ) throws -> Bool {
        guard let selected = parsedExtension(selection) else { return false }
        let offers = try rawOffers
            .flatMap(parseExtensionList)
            .compactMap(parsedExtension)
            .filter { $0.name.caseInsensitiveCompare(selected.name) == .orderedSame }
        guard !offers.isEmpty else { return false }

        guard selected.name.caseInsensitiveCompare("permessage-deflate") == .orderedSame else {
            return true
        }
        return offers.contains { perMessageDeflateSelection(selected, matches: $0) }
    }

    private static func perMessageDeflateSelection(
        _ selection: ParsedExtension,
        matches offer: ParsedExtension
    ) -> Bool {
        let selectedNames = selection.parameters.map { $0.name.lowercased() }
        guard Set(selectedNames).count == selectedNames.count else { return false }

        for parameter in selection.parameters {
            switch parameter.name.lowercased() {
            case "client_no_context_takeover", "server_no_context_takeover":
                guard parameter.value == nil else { return false }
            case "client_max_window_bits", "server_max_window_bits":
                guard let value = windowBits(parameter.value) else { return false }
                if parameter.name.caseInsensitiveCompare("client_max_window_bits") == .orderedSame {
                    // RFC 7692 section 7.1.2.2: this response parameter is only
                    // legal when the offer included it. Its offered value is a hint,
                    // not a ceiling on the server's response value.
                    guard offer.parameter(named: "client_max_window_bits") != nil else {
                        return false
                    }
                } else if let offered = offer.parameter(named: "server_max_window_bits") {
                    // The server direction is constrained by the value in the offer.
                    guard let offeredValue = windowBits(offered.value), value <= offeredValue else {
                        return false
                    }
                }
            default:
                return false
            }
        }
        return true
    }

    private static func parsedExtension(_ value: String) -> ParsedExtension? {
        guard let parts = splitHTTPList(value, separator: ";"),
              let name = parts.first,
              isHTTPToken(name) else {
            return nil
        }
        let parameters = parts.dropFirst().compactMap { raw -> ParsedExtension.Parameter? in
            let pair = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pair.first else { return nil }
            let parameterName = String(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isHTTPToken(parameterName) else { return nil }
            let parameterValue: String?
            if pair.count == 2 {
                let rawValue = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let normalizedValue = normalizedExtensionParameterValue(rawValue) else {
                    return nil
                }
                parameterValue = normalizedValue
            } else {
                parameterValue = nil
            }
            return ParsedExtension.Parameter(name: parameterName, value: parameterValue)
        }
        guard parameters.count == parts.count - 1 else { return nil }
        return ParsedExtension(name: name, parameters: parameters)
    }

    private static func windowBits(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.first != "0" || value == "0",
              let bits = Int(value),
              (8...15).contains(bits) else {
            return nil
        }
        return bits
    }

    private static func isValidExtension(_ value: String) -> Bool {
        guard let parts = splitHTTPList(value, separator: ";"),
              let name = parts.first,
              isHTTPToken(name) else {
            return false
        }
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let parameterName = pair.first.map(String.init), isHTTPToken(parameterName) else {
                return false
            }
            if pair.count == 2 {
                let parameterValue = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedExtensionParameterValue(parameterValue) != nil else {
                    return false
                }
            }
        }
        return true
    }

    private static func splitHTTPList(_ value: String, separator: Character) -> [String]? {
        var result = [String]()
        var current = ""
        var inQuotes = false
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if inQuotes, character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == separator, !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !inQuotes, !isEscaped else { return nil }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        guard result.allSatisfy({ !$0.isEmpty }) else { return nil }
        return result
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(isHTTPTokenCharacter)
    }

    private static func isValidQuotedString(_ value: String) -> Bool {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return false }
        var isEscaped = false
        for scalar in value.dropFirst().dropLast().unicodeScalars {
            if isEscaped {
                guard scalar.value == 0x09 || (0x20...0x7E).contains(scalar.value) || scalar.value >= 0x80 else { return false }
                isEscaped = false
            } else if scalar == "\\" {
                isEscaped = true
            } else {
                guard scalar.value == 0x09 || scalar.value == 0x20 || scalar.value == 0x21 ||
                        (0x23...0x5B).contains(scalar.value) || (0x5D...0x7E).contains(scalar.value) || scalar.value >= 0x80 else {
                    return false
                }
            }
        }
        return !isEscaped
    }

    /// RFC 6455 section 9.1 requires a quoted extension value, after quoted-pair
    /// unescaping, to conform to the HTTP token grammar.
    static func normalizedExtensionParameterValue(_ value: String) -> String? {
        if isHTTPToken(value) { return value }
        guard isValidQuotedString(value) else { return nil }

        var result = ""
        var isEscaped = false
        for character in value.dropFirst().dropLast() {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        return isHTTPToken(result) ? result : nil
    }

    private static func isHTTPTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21, 0x23...0x27, 0x2A...0x2B, 0x2D...0x2E, 0x30...0x39,
             0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }
}

enum HTTPHeadParsingError: Swift.Error, Sendable {
    case headerTooLarge
    case invalidData
}

struct ParsedHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let leftover: Data
    let consumedFromChunk: Int
}

struct ParsedHTTPRequest: Sendable {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let leftover: Data
}

struct HTTPResponseAccumulator: Sendable {
    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> ParsedHTTPResponse? {
        let previousCount = buffer.count
        buffer.append(chunk)
        guard let headerEnd = HTTPHeadParser.headerEnd(in: buffer) else {
            try HTTPHeadParser.checkSize(buffer)
            return nil
        }

        let head = try HTTPHeadParser.response(from: Data(buffer.prefix(headerEnd)))
        let leftover = Data(buffer.dropFirst(headerEnd))
        let consumed = min(chunk.count, max(0, headerEnd - previousCount))
        buffer.removeAll(keepingCapacity: true)
        return ParsedHTTPResponse(
            statusCode: head.statusCode,
            headers: head.headers,
            leftover: leftover,
            consumedFromChunk: consumed
        )
    }
}

struct HTTPRequestAccumulator: Sendable {
    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> ParsedHTTPRequest? {
        buffer.append(chunk)
        guard let headerEnd = HTTPHeadParser.headerEnd(in: buffer) else {
            try HTTPHeadParser.checkSize(buffer)
            return nil
        }

        let head = try HTTPHeadParser.request(from: Data(buffer.prefix(headerEnd)))
        let leftover = Data(buffer.dropFirst(headerEnd))
        buffer.removeAll(keepingCapacity: true)
        return ParsedHTTPRequest(
            method: head.method,
            target: head.target,
            version: head.version,
            headers: head.headers,
            leftover: leftover
        )
    }
}

private enum HTTPHeadParser {
    static let maximumHeaderSize = 64 * 1024
    static let terminator: [UInt8] = [13, 10, 13, 10]

    struct Response {
        let statusCode: Int
        let headers: [String: String]
    }

    struct Request {
        let method: String
        let target: String
        let version: String
        let headers: [String: String]
    }

    static func checkSize(_ data: Data) throws {
        guard data.count <= maximumHeaderSize else { throw HTTPHeadParsingError.headerTooLarge }
    }

    static func headerEnd(in data: Data) -> Int? {
        guard data.count >= terminator.count else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in 3..<bytes.count where
                bytes[index - 3] == terminator[0] &&
                bytes[index - 2] == terminator[1] &&
                bytes[index - 1] == terminator[2] &&
                bytes[index] == terminator[3] {
                return index + 1
            }
            return nil
        }
    }

    static func response(from data: Data) throws -> Response {
        let (startLine, headers) = try fields(from: data)
        let parts = startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              parts[0] == "HTTP/1.1",
              parts[1].count == 3,
              parts[1].allSatisfy(\.isNumber),
              let statusCode = Int(parts[1]) else {
            throw HTTPHeadParsingError.invalidData
        }
        return Response(statusCode: statusCode, headers: headers)
    }

    static func request(from data: Data) throws -> Request {
        let (startLine, headers) = try fields(from: data)
        let parts = startLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !parts[2].isEmpty else {
            throw HTTPHeadParsingError.invalidData
        }
        return Request(
            method: String(parts[0]),
            target: String(parts[1]),
            version: String(parts[2]),
            headers: headers
        )
    }

    private static func fields(from data: Data) throws -> (String, [String: String]) {
        try checkSize(data)
        guard data.count >= terminator.count,
              Array(data.suffix(terminator.count)) == terminator,
              let string = String(data: data.dropLast(terminator.count), encoding: .utf8) else {
            throw HTTPHeadParsingError.invalidData
        }

        let lines = string.components(separatedBy: "\r\n")
        guard let startLine = lines.first, !startLine.isEmpty else {
            throw HTTPHeadParsingError.invalidData
        }

        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ",
                  line.first != "\t",
                  let colon = line.firstIndex(of: ":") else {
                throw HTTPHeadParsingError.invalidData
            }
            let rawName = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard isToken(rawName), isValidFieldValue(value) else {
                throw HTTPHeadParsingError.invalidData
            }
            let name = canonicalName(rawName)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return (startLine, headers)
    }

    private static func canonicalName(_ name: String) -> String {
        let knownNames = [
            HTTPWSHeader.upgradeName,
            HTTPWSHeader.hostName,
            HTTPWSHeader.connectionName,
            HTTPWSHeader.protocolName,
            HTTPWSHeader.versionName,
            HTTPWSHeader.extensionName,
            HTTPWSHeader.keyName,
            HTTPWSHeader.originName,
            HTTPWSHeader.acceptName,
        ]
        return knownNames.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x21, 0x23...0x27, 0x2A...0x2B, 0x2D...0x2E, 0x30...0x39,
                 0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidFieldValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }
}
