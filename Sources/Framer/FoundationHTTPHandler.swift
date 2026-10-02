//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FoundationHTTPHandler.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/25/19.
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
#if os(watchOS)
public typealias FoundationHTTPHandler = StringHTTPHandler
#else
public class FoundationHTTPHandler: HTTPHandler {
    private var accumulator = HTTPResponseAccumulator()
    weak var delegate: HTTPHandlerDelegate?
    
    public init() {
        
    }
    
    public func convert(request: URLRequest) -> Data {
        guard let url = request.url else { return Data() }
        let msg = CFHTTPMessageCreateRequest(
            kCFAllocatorDefault,
            (request.httpMethod ?? "GET") as CFString,
            url as CFURL,
            kCFHTTPVersion1_1
        ).takeRetainedValue()
        if let headers = request.allHTTPHeaderFields {
            for (aKey, aValue) in headers {
                CFHTTPMessageSetHeaderFieldValue(msg, aKey as CFString, aValue as CFString)
            }
        }
        if let body = request.httpBody {
            CFHTTPMessageSetBody(msg, body as CFData)
        }
        guard let data = CFHTTPMessageCopySerializedMessage(msg) else {
            return Data()
        }
        return data.takeRetainedValue() as Data
    }
    
    public func parse(data: Data) -> Int {
        do {
            guard let response = try accumulator.append(data) else { return -1 }
            guard response.statusCode == HTTPWSHeader.switchProtocolCode else {
                delegate?.didReceiveHTTP(event: .failure(HTTPUpgradeError.notAnUpgrade(response.statusCode, response.headers)))
                return response.consumedFromChunk
            }
            do {
                try WebSocketHandshake.validateSwitchingProtocolsResponse(
                    statusCode: response.statusCode,
                    headers: response.headers
                )
            } catch let error as WebSocketHandshake.ValidationError {
                delegate?.didReceiveHTTP(event: .failure(HTTPUpgradeError.invalidHandshake(error)))
                return response.consumedFromChunk
            }
            delegate?.didReceiveHTTP(event: .success(headers: response.headers, leftover: response.leftover))
            return response.consumedFromChunk
        } catch HTTPHeadParsingError.headerTooLarge {
            accumulator = HTTPResponseAccumulator()
            delegate?.didReceiveHTTP(event: .failure(HTTPUpgradeError.headerTooLarge))
        } catch {
            accumulator = HTTPResponseAccumulator()
            delegate?.didReceiveHTTP(event: .failure(HTTPUpgradeError.invalidData))
        }
        return -1
    }
    
    public func register(delegate: HTTPHandlerDelegate) {
        self.delegate = delegate
    }

    public func reset() {
        accumulator = HTTPResponseAccumulator()
    }
}
#endif
