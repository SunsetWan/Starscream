//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  StringHTTPHandler.swift
//  Starscream
//
//  Created by Dalton Cherry on 8/25/19.
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

public class StringHTTPHandler: HTTPHandler {
    private var accumulator = HTTPResponseAccumulator()
    weak var delegate: HTTPHandlerDelegate?
    
    public init() {
        
    }
    
    public func convert(request: URLRequest) -> Data {
        guard let url = request.url else {
            return Data()
        }
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? url.path
        if path.isEmpty {
            path = "/"
        }
        if let query = components?.percentEncodedQuery {
            path += "?" + query
        }
        
        var httpBody = "\(request.httpMethod ?? "GET") \(path) HTTP/1.1\r\n"
        if let headers = request.allHTTPHeaderFields {
            for (key, val) in headers {
                httpBody += "\(key): \(val)\r\n"
            }
        }
        httpBody += "\r\n"
        
        guard var data = httpBody.data(using: .utf8) else {
            return Data()
        }
        
        if let body = request.httpBody {
            data.append(body)
        }
        
        return data
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
