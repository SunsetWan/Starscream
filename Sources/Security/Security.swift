//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Security.swift
//  Starscream
//
//  Created by Dalton Cherry on 3/16/19.
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
import Network
import Security

public enum SecurityErrorCode: UInt16, Sendable {
    case acceptFailed = 1
    case pinningFailed = 2
}

public enum PinningState: Sendable {
    case success
    case failed((any Error)?)
}

// CertificatePinning protocol provides an interface for Transports to handle Certificate
// or Public Key Pinning.
public protocol CertificatePinning: AnyObject, Sendable {
    func evaluateTrust(
        trust: SecTrust,
        domain: String?,
        completion: @escaping @Sendable (PinningState) -> Void
    )
}

// validates the "Sec-WebSocket-Accept" header as defined 1.3 of the RFC 6455
// https://tools.ietf.org/html/rfc6455#section-1.3
public protocol HeaderValidator: AnyObject, Sendable {
    func validate(headers: [String: String], key: String) -> Error?
}

/// The TLS policy applied before a WebSocket connection is allowed to open.
public enum CertificatePinningPolicy: Sendable, Equatable {
    /// Use the operating system's normal certificate and hostname validation.
    case system

    /// Require normal trust validation and a DER certificate match somewhere in the evaluated
    /// certificate chain.
    case certificates([Data])

    /// Require normal trust validation and a public-key match somewhere in the evaluated chain.
    /// Keys use the external representation returned by `SecKeyCopyExternalRepresentation`.
    case publicKeys([Data])

    /// Explicitly disable trust validation. This is intended only for local development.
    case disabled
}

public enum ClientIdentityError: Error, Sendable, Hashable {
    case invalidPKCS12(OSStatus)
    case missingIdentity
}

public enum WebSocketProxyError: Error, Sendable, Equatable {
    case unsupportedOnThisOS
    case invalidPort
}

/// A PKCS #12 identity used for mutual TLS (client-certificate authentication).
///
/// Keeping the serialized bytes rather than a `SecIdentity` makes this value safe to pass between
/// networking isolation domains. The identity is imported only when a connection is configured.
public struct WebSocketClientIdentity: Sendable, Equatable {
    public let pkcs12: Data
    public let password: String

    public init(pkcs12: Data, password: String) {
        self.pkcs12 = pkcs12
        self.password = password
    }

    func makeIdentity() throws -> SecIdentity {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var importedItems: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options, &importedItems)
        guard status == errSecSuccess else {
            throw ClientIdentityError.invalidPKCS12(status)
        }
        guard
            let items = importedItems as? [[String: Any]],
            let identityValue = items.first?[kSecImportItemIdentity as String]
        else {
            throw ClientIdentityError.missingIdentity
        }
        return identityValue as! SecIdentity
    }
}

/// Explicit proxy settings for a WebSocket connection.
public struct WebSocketProxy: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case httpConnect
        case socks5
    }

    public let kind: Kind
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?
    public let usesTLS: Bool

    public init(
        kind: Kind,
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil,
        usesTLS: Bool = false
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.usesTLS = usesTLS
    }

    public static func httpConnect(
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil,
        usesTLS: Bool = false
    ) -> Self {
        Self(
            kind: .httpConnect,
            host: host,
            port: port,
            username: username,
            password: password,
            usesTLS: usesTLS
        )
    }

    public static func socks5(
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil
    ) -> Self {
        Self(
            kind: .socks5,
            host: host,
            port: port,
            username: username,
            password: password
        )
    }
}

extension WebSocketProxy {
    /// URLSession's iOS 15–16 fallback supports only an unauthenticated, plaintext HTTP CONNECT
    /// proxy. Rich proxy configuration uses Network.ProxyConfiguration on iOS 17 and newer.
    var legacyURLSessionDictionary: [AnyHashable: Any]? {
        guard kind == .httpConnect,
              username == nil,
              password == nil,
              !usesTLS else {
            return nil
        }
        return [
            "HTTPEnable": true,
            "HTTPProxy": host,
            "HTTPPort": Int(port),
        ]
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    func networkConfiguration() throws -> Network.ProxyConfiguration {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw WebSocketProxyError.invalidPort
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        let configuration: Network.ProxyConfiguration
        switch kind {
        case .httpConnect:
            configuration = Network.ProxyConfiguration(
                httpCONNECTProxy: endpoint,
                tlsOptions: usesTLS ? NWProtocolTLS.Options() : nil
            )
        case .socks5:
            configuration = Network.ProxyConfiguration(socksv5Proxy: endpoint)
        }
        if let username, let password {
            configuration.applyCredential(username: username, password: password)
        }
        return configuration
    }
}
