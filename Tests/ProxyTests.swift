import Testing
@testable import Starscream

@Suite
struct ProxyTests {
    @Test
    func `HTTP CONNECT proxy produces legacy URL session settings`() {
        let proxy = WebSocketProxy.httpConnect(
            host: "proxy.example.com",
            port: 8080
        )

        guard let dictionary = proxy.legacyURLSessionDictionary else {
            Issue.record("Expected plain unauthenticated HTTP CONNECT to be supported")
            return
        }

        #expect(dictionary["HTTPEnable"] as? Bool == true)
        #expect(dictionary["HTTPProxy"] as? String == "proxy.example.com")
        #expect(dictionary["HTTPPort"] as? Int == 8080)
    }

    @Test(arguments: [
        WebSocketProxy.socks5(host: "127.0.0.1", port: 1080),
        WebSocketProxy.httpConnect(
            host: "proxy.example.com",
            port: 8080,
            username: "alice",
            password: "secret"
        ),
        WebSocketProxy.httpConnect(
            host: "proxy.example.com",
            port: 8443,
            usesTLS: true
        )
    ])
    func `Unsupported legacy proxy configuration is rejected`(_ proxy: WebSocketProxy) {
        #expect(proxy.legacyURLSessionDictionary == nil)
    }
}
