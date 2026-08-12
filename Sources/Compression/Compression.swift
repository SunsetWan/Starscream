//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Compression.swift
//  Starscream
//
//  Created by Dalton Cherry on 2/4/19.
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

public protocol CompressionHandler: AnyObject, Sendable {
    /// Resets all connection-scoped compression state and loads a negotiated response.
    /// Returns `true` only when permessage-deflate was validly negotiated.
    @discardableResult
    func load(headers: [String: String]) -> Bool
    func reset()
    func decompress(data: Data, isFinal: Bool) throws -> Data
    func compress(data: Data) -> Data?
}
