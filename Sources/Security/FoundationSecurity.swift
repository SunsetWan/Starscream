//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FoundationSecurity.swift
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
import CryptoKit
@preconcurrency import Security

public enum FoundationSecurityError: Error, Sendable, Equatable {
    case invalidRequest
    case emptyPinSet
    case certificatePinMismatch
    case publicKeyPinMismatch
    case certificateHasNoPublicKey
    case publicKeyHasNoExternalRepresentation
}

public final class FoundationSecurity: Sendable {
    public let policy: CertificatePinningPolicy
    private let evaluationQueue = DispatchQueue(label: "com.vluxe.starscream.trust-evaluation")

    /// Compatibility initializer. Prefer `init(policy:)` for new code.
    public init(allowSelfSigned: Bool = false) {
        policy = allowSelfSigned ? .disabled : .system
    }

    public init(policy: CertificatePinningPolicy) {
        self.policy = policy
    }

    /// Loads DER-encoded certificate data from an application or test bundle.
    public static func certificateData(
        named name: String,
        withExtension fileExtension: String = "cer",
        in bundle: Bundle = .main
    ) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw FoundationSecurityError.invalidRequest
        }
        return try Data(contentsOf: url)
    }

    /// Returns the external representation used by `.publicKeys` pinning.
    public static func publicKeyData(from certificateData: Data) throws -> Data {
        guard
            let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
            let key = SecCertificateCopyKey(certificate)
        else {
            throw FoundationSecurityError.certificateHasNoPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) else {
            throw error?.takeRetainedValue() ?? FoundationSecurityError.publicKeyHasNoExternalRepresentation
        }
        return data as Data
    }
}

extension FoundationSecurity: CertificatePinning {
    /// Evaluates enabled policies on a private queue. Do not change `trust` until completion.
    public func evaluateTrust(
        trust: SecTrust,
        domain: String?,
        completion: @escaping @Sendable (PinningState) -> Void
    ) {
        if policy == .disabled {
            completion(.success)
            return
        }

        evaluationQueue.async {
            let policyStatus = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString?))
            guard policyStatus == errSecSuccess else {
                completion(.failed(NSError(domain: NSOSStatusErrorDomain, code: Int(policyStatus))))
                return
            }

            // Security requires this call and its callback to use the same queue.
            let status = SecTrustEvaluateAsyncWithError(trust, self.evaluationQueue) { trust, trusted, error in
                guard trusted else {
                    completion(.failed(error))
                    return
                }
                completion(self.checkPins(trust))
            }
            // A non-success status means Security will not call the callback.
            if status != errSecSuccess {
                completion(.failed(NSError(domain: NSOSStatusErrorDomain, code: Int(status))))
            }
        }
    }

    private func checkPins(_ trust: SecTrust) -> PinningState {
        switch policy {
        case .system, .disabled:
            return .success
        case .certificates(let pins):
            guard !pins.isEmpty else {
                return .failed(FoundationSecurityError.emptyPinSet)
            }
            let chainData = certificateChain(trust).map { SecCertificateCopyData($0) as Data }
            return chainData.contains(where: pins.contains) ? .success : .failed(FoundationSecurityError.certificatePinMismatch)
        case .publicKeys(let pins):
            guard !pins.isEmpty else {
                return .failed(FoundationSecurityError.emptyPinSet)
            }
            let keyData = certificateChain(trust).compactMap { certificate -> Data? in
                guard let key = SecCertificateCopyKey(certificate) else { return nil }
                var error: Unmanaged<CFError>?
                return SecKeyCopyExternalRepresentation(key, &error) as Data?
            }
            return keyData.contains(where: pins.contains) ? .success : .failed(FoundationSecurityError.publicKeyPinMismatch)
        }
    }

    private func certificateChain(_ trust: SecTrust) -> [SecCertificate] {
        #if os(iOS)
        return SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        #else
        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
            return SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        }
        return (0..<SecTrustGetCertificateCount(trust)).compactMap {
            SecTrustGetCertificateAtIndex(trust, $0)
        }
        #endif
    }
}

extension FoundationSecurity: HeaderValidator {
    public func validate(headers: [String: String], key: String) -> Error? {
        let acceptKey = headers.first { name, _ in
            name.caseInsensitiveCompare(HTTPWSHeader.acceptName) == .orderedSame
        }?.value
        let expected = "\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".sha1Base64()
        guard acceptKey == expected else {
            return WSError(
                type: .securityError,
                message: "missing or invalid Sec-WebSocket-Accept header",
                code: CloseCode.protocolError.rawValue
            )
        }
        return nil
    }
}

private extension String {
    func sha1Base64() -> String {
        let digest = Insecure.SHA1.hash(data: Data(utf8))
        return Data(digest).base64EncodedString()
    }
}
