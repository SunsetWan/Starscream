import Foundation
import Security
import Testing
@testable import Starscream

@Suite
struct SecurityTests {
    @Test
    func `RFC 6455 accept example`() {
        let validator = FoundationSecurity()
        let error = validator.validate(
            headers: ["sEc-WeBsOcKeT-aCcEpT": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="],
            key: "dGhlIHNhbXBsZSBub25jZQ=="
        )

        #expect(error == nil)
    }

    @Test
    func `Missing accept header is rejected`() {
        let error = FoundationSecurity().validate(headers: [:], key: "test-key")

        let webSocketError = error as? WSError
        #expect(webSocketError?.type == .securityError)
        #expect(webSocketError?.code == CloseCode.protocolError.rawValue)
    }

    @Test
    func `Invalid accept header is rejected`() {
        let error = FoundationSecurity().validate(
            headers: ["Sec-WebSocket-Accept": "not-the-expected-value"],
            key: "test-key"
        )

        #expect(error != nil)
    }

    @Test
    func `Client identity rejects invalid PKCS12`() {
        let identity = WebSocketClientIdentity(pkcs12: Data("invalid".utf8), password: "secret")

        #expect(throws: (any Error).self) {
            try identity.makeIdentity()
        }
    }

    @Test
    func `System trust accepts a matching anchored certificate`() throws {
        let trust = try makeTrust(domain: "example.com")

        #expect(isSuccess(evaluate(.system, trust: trust, domain: "example.com")))
    }

    @Test
    func `System trust rejects a hostname mismatch`() throws {
        let trust = try makeTrust(domain: "not-example.com")

        #expect(!isSuccess(evaluate(.system, trust: trust, domain: "not-example.com")))
    }

    @Test
    func `Disabled policy explicitly bypasses a hostname mismatch`() throws {
        let trust = try makeTrust(domain: "not-example.com")

        #expect(isSuccess(evaluate(.disabled, trust: trust, domain: "not-example.com")))
    }

    @Test
    func `Certificate pinning accepts the anchored leaf and rejects another pin`() throws {
        let matchingTrust = try makeTrust(domain: "example.com")
        #expect(isSuccess(evaluate(
            .certificates([Self.certificateData]),
            trust: matchingTrust,
            domain: "example.com"
        )))

        let mismatchingTrust = try makeTrust(domain: "example.com")
        #expect(!isSuccess(evaluate(
            .certificates([Data("different certificate".utf8)]),
            trust: mismatchingTrust,
            domain: "example.com"
        )))
    }

    @Test
    func `Public key pinning accepts the anchored leaf and rejects another key`() throws {
        let publicKey = try FoundationSecurity.publicKeyData(from: Self.certificateData)
        let matchingTrust = try makeTrust(domain: "example.com")
        #expect(isSuccess(evaluate(
            .publicKeys([publicKey]),
            trust: matchingTrust,
            domain: "example.com"
        )))

        let mismatchingTrust = try makeTrust(domain: "example.com")
        #expect(!isSuccess(evaluate(
            .publicKeys([Data("different key".utf8)]),
            trust: mismatchingTrust,
            domain: "example.com"
        )))
    }

    @Test
    func `Empty pin sets fail closed`() throws {
        let certificateTrust = try makeTrust(domain: "example.com")
        #expect(!isSuccess(evaluate(
            .certificates([]),
            trust: certificateTrust,
            domain: "example.com"
        )))

        let publicKeyTrust = try makeTrust(domain: "example.com")
        #expect(!isSuccess(evaluate(
            .publicKeys([]),
            trust: publicKeyTrust,
            domain: "example.com"
        )))
    }

    private static let certificateData = Data(base64Encoded: "MIIDSTCCAjGgAwIBAgIUPqODNe4QnKN2Tnf/VSNgm1GC8bcwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLZXhhbXBsZS5jb20wHhcNMjYwODEyMTgyMTM4WhcNMjcwNjA4MTgyMTM4WjAWMRQwEgYDVQQDDAtleGFtcGxlLmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOUWxjTIe4u9Kh0pVBdVBECn926wvV9HmPGtV4ggXLRfEwDUwDR57uEw2XWRWbfIAIAknUbGh2p2MtWgc8Q1oJGRgGtykNRvUj0kBo22E0hdO2NSMQVnP9ewulH+6dnV9Pl8hZrcvbS1lEbTlwsOs+tkZ00cuk89FPm00k6AjUAAVtjOy1/YbVKyCojAMP+d+hHER9c8CkW3700/bgIoOQPJklOh0EPz/PCXul4CdgAPXdyWsoVpVRCb3tmjkJT2CiGVLQ+cDohJFY1y+4aaD23lyBt5ETwi8ru2f19J186Qol5++fkJ9JrmPM9lyTb3C5kgoeff1+2PoV4Bi2bqI00CAwEAAaOBjjCBizAdBgNVHQ4EFgQUMZYZcdU1usJQy+IEEM5iqvy/DCQwHwYDVR0jBBgwFoAUMZYZcdU1usJQy+IEEM5iqvy/DCQwFgYDVR0RBA8wDYILZXhhbXBsZS5jb20wDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDQYJKoZIhvcNAQELBQADggEBAH2htIMc+AzdDH5ZS6dSVsVzgXMMTG4K0RuMhKBM4E4ArX40EnG6T6N+gdcuozuXFRmtqCz+4xWZ4WEbTDZ+CtFaXhb13qnZtO1kV4Q8Tc/701fnP3wI1tm1CMKLYcgaclUATArfnWry0W2m6VWgpuZCOQj0csbfkiEjQjY6TggJ67kXqKT8M2OAwdXG2tQXXePHpuCJNnkyUg56MjzJFJN6csLXRIKNhWx8fEgnCs9aCEi/4NTyp8l2spMIPCt6Cuztl49p7cEQrq9rYZxqjaTpfqzBZqspoHSXx1gIiTDqAJI33olKSNnrUHp8LvjKhBG3fWQbyqr9qGIR0j/TF6w=")!

    private func makeTrust(domain: String) throws -> SecTrust {
        let certificate = try #require(SecCertificateCreateWithData(
            nil,
            Self.certificateData as CFData
        ))
        var optionalTrust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, domain as CFString),
            &optionalTrust
        )
        #expect(status == errSecSuccess)
        let trust = try #require(optionalTrust)
        #expect(SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess)
        // Keep this fixture deterministic after its short-lived leaf certificate expires.
        let verificationDate = Date(timeIntervalSince1970: 1_788_192_000) as CFDate
        #expect(SecTrustSetVerifyDate(trust, verificationDate) == errSecSuccess)
        return trust
    }

    private func evaluate(
        _ policy: CertificatePinningPolicy,
        trust: SecTrust,
        domain: String
    ) -> PinningState {
        let result = Locked<PinningState?>(nil)
        FoundationSecurity(policy: policy).evaluateTrust(trust: trust, domain: domain) { state in
            result.withLock { $0 = state }
        }
        return result.withLock { $0 }!
    }

    private func isSuccess(_ state: PinningState) -> Bool {
        if case .success = state { return true }
        return false
    }
}
