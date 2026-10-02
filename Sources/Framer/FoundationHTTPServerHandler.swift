//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FoundationHTTPHandler.swift
//  Starscream
//
//  Created by Dalton Cherry on 4/2/19.
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

public class FoundationHTTPServerHandler: HTTPServerHandler {
    private var accumulator = HTTPRequestAccumulator()
    private var pendingRequest: WebSocketHandshake.ServerRequest?
    weak var delegate: HTTPServerDelegate?
    
    public func register(delegate: HTTPServerDelegate) {
        self.delegate = delegate
    }
    
    public func createResponse(headers: [String: String]) -> Data {
        guard let pendingRequest else { return Data() }
        do {
            let selectedProtocol = WebSocketHandshake.header(named: HTTPWSHeader.protocolName, in: headers)
            let selectedExtensions = WebSocketHandshake.header(named: HTTPWSHeader.extensionName, in: headers).map { [$0] } ?? []
            var responseHeaders = try WebSocketHandshake.serverResponseHeaders(
                for: pendingRequest,
                selectedProtocol: selectedProtocol,
                selectedExtensions: selectedExtensions
            )

            let reservedNames = [
                HTTPWSHeader.upgradeName,
                HTTPWSHeader.connectionName,
                HTTPWSHeader.acceptName,
                HTTPWSHeader.protocolName,
                HTTPWSHeader.extensionName,
            ]
            for (name, value) in headers where !reservedNames.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
                guard WebSocketHandshake.isValidHTTPHeader(name: name, value: value) else {
                    return Data()
                }
                responseHeaders[name] = value
            }

            let preferredOrder = [
                HTTPWSHeader.upgradeName,
                HTTPWSHeader.connectionName,
                HTTPWSHeader.acceptName,
                HTTPWSHeader.protocolName,
                HTTPWSHeader.extensionName,
            ]
            var message = "HTTP/1.1 101 Switching Protocols\r\n"
            for name in preferredOrder {
                if let value = responseHeaders.removeValue(forKey: name) {
                    message += "\(name): \(value)\r\n"
                }
            }
            for name in responseHeaders.keys.sorted() {
                if let value = responseHeaders[name] {
                    message += "\(name): \(value)\r\n"
                }
            }
            message += "\r\n"
            return Data(message.utf8)
        } catch {
            return Data()
        }
    }
    
    public func parse(data: Data) {
        do {
            guard let request = try accumulator.append(data) else { return }
            pendingRequest = nil
            do {
                pendingRequest = try WebSocketHandshake.validateServerRequest(
                    method: request.method,
                    httpVersion: request.version,
                    headers: request.headers
                )
            } catch let error as WebSocketHandshake.ValidationError {
                delegate?.didReceive(event: .failure(HTTPUpgradeError.invalidHandshake(error)))
                return
            }
            delegate?.didReceive(event: .success(headers: request.headers, leftover: request.leftover))
        } catch HTTPHeadParsingError.headerTooLarge {
            accumulator = HTTPRequestAccumulator()
            delegate?.didReceive(event: .failure(HTTPUpgradeError.headerTooLarge))
        } catch {
            accumulator = HTTPRequestAccumulator()
            delegate?.didReceive(event: .failure(HTTPUpgradeError.invalidData))
        }
    }
}
