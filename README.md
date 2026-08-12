![starscream](https://raw.githubusercontent.com/daltoniam/starscream/assets/starscream.jpg)

Starscream is an RFC 6455 WebSocket client and server library written in Swift.

## Features

- RFC 6455 opening handshakes, framing, fragmentation, control frames, and close handling.
- TLS (`wss://`), certificate and public-key pinning, and mutual TLS support.
- HTTP CONNECT and SOCKS5 proxies, with optional proxy authentication.
- Per-message compression ([RFC 7692](https://datatracker.ietf.org/doc/html/rfc7692)).
- Swift 6 language mode with Complete strict-concurrency checking.
- Delegate and closure APIs with a configurable callback queue.
- Configurable frame, message, and decompressed-message limits that reject oversized input with close code `1009`.

## Quick start

Import Starscream and retain the socket for as long as the connection should remain open:

```swift
import Starscream

var request = URLRequest(url: URL(string: "ws://localhost:8080/")!)
request.timeoutInterval = 5

let socket = WebSocket(request: request)
socket.delegate = self
socket.connect()
```

Use `wss://` for TLS-protected connections.

### Receiving events

Implement `WebSocketDelegate` to receive every event through one method:

```swift
func didReceive(event: WebSocketEvent, client: WebSocketClient) {
    switch event {
    case .connected(let headers):
        print("WebSocket connected: \(headers)")
    case .disconnected(let reason, let code):
        print("WebSocket disconnected: \(reason), code \(code)")
    case .text(let string):
        print("Received text: \(string)")
    case .binary(let data):
        print("Received \(data.count) bytes")
    case .ping:
        break
    case .pong:
        break
    case .viabilityChanged(let isViable):
        print("Network viability changed: \(isViable)")
    case .reconnectSuggested(let shouldReconnect):
        print("Reconnect suggested: \(shouldReconnect)")
    case .cancelled:
        print("WebSocket cancelled")
    case .error(let error):
        print("WebSocket error: \(String(describing: error))")
    case .peerClosed:
        print("Peer closed the connection")
    }
}
```

Or use the closure API:

```swift
socket.onEvent = { event in
    // Handle the same WebSocketEvent cases here.
}
```

### Sending data and closing

```swift
socket.write(string: "Hello")
socket.write(data: Data([0x01, 0x02]))
socket.write(ping: Data())
socket.write(pong: Data())

socket.disconnect()
socket.disconnect(closeCode: CloseCode.goingAway.rawValue)
```

Starscream automatically replies to incoming ping frames. Disable that behavior only when the application needs to manage pong frames itself:

```swift
socket.respondToPingWithPong = false
```

### Headers, subprotocols, and timeouts

Configure the WebSocket handshake through `URLRequest`:

```swift
var request = URLRequest(url: URL(string: "wss://example.com/chat")!)
request.timeoutInterval = 10
request.setValue("chat, superchat", forHTTPHeaderField: "Sec-WebSocket-Protocol")
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

let socket = WebSocket(request: request)
```

Starscream supplies the RFC-required WebSocket headers. Do not override `Sec-WebSocket-Key`, `Sec-WebSocket-Version`, or `Upgrade` unless you are deliberately testing an invalid handshake.

## TLS and certificate pinning

The default `FoundationSecurity` policy performs the operating system's normal certificate-chain and hostname validation:

```swift
let socket = WebSocket(request: request)
```

### Pinning a certificate

Add the DER-encoded `.cer` file to the application target's resources, then load and pin it:

```swift
let certificateData = try FoundationSecurity.certificateData(
    named: "api-example-com",
    in: .main
)
let pinner = FoundationSecurity(policy: .certificates([certificateData]))
let socket = WebSocket(request: request, certPinner: pinner)
```

Certificate pinning still performs normal system trust and hostname validation before comparing a certificate in the evaluated chain with the supplied DER data.

### Pinning a public key

Starscream can derive the raw external key representation expected by `.publicKeys` from a bundled certificate:

```swift
let certificateData = try FoundationSecurity.certificateData(named: "api-example-com")
let publicKeyData = try FoundationSecurity.publicKeyData(from: certificateData)
let pinner = FoundationSecurity(policy: .publicKeys([publicKeyData]))
let socket = WebSocket(request: request, certPinner: pinner)
```

Ship at least one backup pin when your certificate rotation policy permits it. The data accepted by `.publicKeys` is the Security framework's external key representation, not an SPKI hash string.

### Self-signed certificates

Disabling trust evaluation accepts any server certificate and should be limited to controlled local development:

```swift
#if DEBUG
let pinner = FoundationSecurity(policy: .disabled)
let socket = WebSocket(request: request, certPinner: pinner)
#endif
```

Never use `.disabled` in a production build.

### Mutual TLS (client certificates)

Bundle a password-protected PKCS #12 identity and pass it to the connection:

```swift
let identityURL = Bundle.main.url(forResource: "websocket-client", withExtension: "p12")!
let identity = WebSocketClientIdentity(
    pkcs12: try Data(contentsOf: identityURL),
    password: clientCertificatePassword
)

let socket = WebSocket(request: request, clientIdentity: identity)
```

Keep PKCS #12 files and passwords out of source control. Prefer provisioning the identity through the Keychain or another protected delivery mechanism in production applications.

### TrustKit

Applications that already configure [TrustKit](https://github.com/datatheorem/TrustKit) can bridge its low-level validator to Starscream by implementing `CertificatePinning`. The adapter should call TrustKit's `evaluateTrust(_:forHostname:)`, map allow/block decisions to `PinningState`, and perform normal system validation when TrustKit reports that a domain is not pinned:

```swift
import Security
@preconcurrency import TrustKit

private enum TrustKitAdapterError: Error, Sendable {
    case missingDomain
    case blocked
}

final class TrustKitPinningAdapter: CertificatePinning, @unchecked Sendable {
    private let systemValidator = FoundationSecurity(policy: .system)

    func evaluateTrust(
        trust: SecTrust,
        domain: String?,
        completion: @escaping @Sendable (PinningState) -> Void
    ) {
        guard let domain else {
            completion(.failed(TrustKitAdapterError.missingDomain))
            return
        }

        let decision = TrustKit.sharedInstance().pinningValidator
            .evaluateTrust(trust, forHostname: domain)

        switch decision {
        case .shouldAllowConnection:
            completion(.success)
        case .shouldBlockConnection:
            completion(.failed(TrustKitAdapterError.blocked))
        case .domainNotPinned:
            systemValidator.evaluateTrust(trust: trust, domain: domain, completion: completion)
        @unknown default:
            completion(.failed(TrustKitAdapterError.blocked))
        }
    }
}

let socket = WebSocket(request: request, certPinner: TrustKitPinningAdapter())
```

See TrustKit's [manual low-level validation contract](https://github.com/datatheorem/TrustKit/blob/master/TrustKit/public/TSKPinningValidator.h) before deploying the adapter. A `domainNotPinned` result does not validate the certificate by itself.

## Proxies

Use an HTTP CONNECT proxy:

```swift
let proxy = WebSocketProxy.httpConnect(
    host: "proxy.example.com",
    port: 8080
)
let socket = WebSocket(request: request, proxy: proxy)
```

Or use a SOCKS5 proxy:

```swift
let proxy = WebSocketProxy.socks5(
    host: "127.0.0.1",
    port: 1080,
    username: "alice",
    password: proxyPassword
)
let socket = WebSocket(request: request, proxy: proxy)
```

On iOS 17 and later, Starscream configures either engine through `Network.ProxyConfiguration`. On iOS 15 and 16 it automatically uses the native engine, which supports only an unauthenticated HTTP CONNECT proxy with `usesTLS` left at its default value of `false`. SOCKS5, proxy credentials, and TLS to the proxy require iOS 17 or later. Unsupported iOS 15/16 configurations fail explicitly instead of opening a direct connection. The native fallback does not use a custom `compressionHandler`.

Proxy credentials are connection configuration; do not embed production secrets in the application binary.

## Compression

Per-message deflate is opt-in and is used only when the server accepts the extension during the handshake:

```swift
let compression = WSCompression()
let socket = WebSocket(request: request, compressionHandler: compression)
```

Compression can expose secrets through compressed-size side channels when attacker-controlled and sensitive data share a compression context. Leave it disabled for that traffic, and for payloads that are already compressed or effectively random.

## Resource limits

The custom engine defaults to 16 MiB per frame and 64 MiB per reassembled or decompressed message. Oversized peer input closes the connection with code `1009`. Use the same limits for framing and compression when an application needs a different policy:

```swift
let limits = WebSocketLimits(
    maximumFrameSize: 8 * 1024 * 1024,
    maximumMessageSize: 32 * 1024 * 1024,
    maximumDecompressedMessageSize: 32 * 1024 * 1024
)
let engine = WSEngine(
    transport: TCPTransport(),
    framer: WSFramer(limits: limits),
    compressionHandler: WSCompression(limits: limits)
)
let socket = WebSocket(request: request, engine: engine)
```

`URLSessionWebSocketTask` enforces the native engine's platform-managed limits; use the custom engine when the application requires Starscream's explicit values.

## Callback queues and concurrency

Starscream is built in Swift 6 language mode with Complete strict-concurrency checking. Connection and transport state are serialized internally. The API remains callback-based, and events are delivered on `DispatchQueue.main` by default.

Choose a dedicated callback queue when event processing should not run on the main queue:

```swift
let socket = WebSocket(request: request)
socket.callbackQueue = DispatchQueue(label: "com.example.websocket-events")
```

Delegate methods and `onEvent` execute on that queue. Avoid blocking it, and synchronize any mutable application state captured by callbacks.

## Protocol conformance and testing

Starscream's Swift Testing suite covers RFC 6455 handshake validation, masking, fragmentation, control-frame constraints, close handling, and malformed input. The repository also includes an Autobahn integration app at `examples/AutobahnTest` for broader wire-level conformance runs.

Autobahn results depend on the exact test-suite version and runtime configuration, so this project does not claim that every Autobahn case passes unless a release publishes the corresponding report.

Run the package tests with:

```bash
swift test --parallel
```

Run the Xcode unit tests with:

```bash
bundle exec fastlane test
```

Pull requests and pushes to `master` run both the Swift Package tests and an iOS simulator framework build/test job in GitHub Actions.

## Example projects

- `examples/SimpleTest` demonstrates a basic client connection.
- `examples/AutobahnTest` drives the Autobahn test suite.
- `examples/WebSocketsOrgEcho` shows CocoaPods integration.

## Requirements

- iOS 15 or later
- macOS 10.15 or later
- tvOS 13 or later
- watchOS 6 or later
- Swift 6 and Xcode 16 or later

## Installation

### Swift Package Manager

Add Starscream to the dependencies in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/daltoniam/Starscream.git", from: "5.0.0")
]
```

Then add `Starscream` to the target's dependencies.

### CocoaPods

Add Starscream to the application's `Podfile`:

```ruby
source 'https://github.com/CocoaPods/Specs.git'
platform :ios, '15.0'
use_frameworks!

target 'MyApp' do
  pod 'Starscream', '~> 5.0'
end
```

Then run `pod install` and open the generated workspace.

### Carthage

Add Starscream to the `Cartfile`:

```text
github "daltoniam/Starscream" >= 5.0.0
```

Follow Carthage's [framework integration instructions](https://github.com/Carthage/Carthage#adding-frameworks-to-an-application) to build and embed `Starscream.framework`.

## Migrating from 4.x

Starscream 5 is a major release because the package now builds in Swift 6 language mode with Complete strict-concurrency checking and raises the minimum iOS version to 15. Most applications only need to update callback captures so they are safe to send between concurrency domains.

Applications with custom Starscream components also need these source changes:

- Custom `Engine` implementations must conform to `Sendable`; completion handlers passed through engine and client write APIs are `@Sendable`.
- Custom `CertificatePinning` implementations must be `Sendable`, invoke an `@Sendable` completion, and handle `PinningState.failed` as an optional `Error`.
- Custom `CompressionHandler` implementations must be reference types and `Sendable`. `load(headers:)` reports whether negotiation succeeded, `decompress(data:isFinal:)` throws on invalid input, and `reset()` clears connection-scoped state.
- `WebSocket` is now a final, thread-safe facade. Put customization in an `Engine`, `Transport`, compression handler, certificate pinner, delegate, or event closure instead of subclassing it.

The stricter contracts prevent unsynchronized user-defined components from weakening the concurrency guarantees of the built-in engines.

### Xcode subproject

Add `Starscream.xcodeproj` to the application project, link `Starscream.framework`, and embed it in the application's Frameworks destination when required by the selected platform and linkage mode.

## License

Starscream is available under the Apache License 2.0. See [LICENSE](LICENSE) for details.

## Contact

- [Dalton Cherry](https://github.com/daltoniam)
- [Austin Cherry](https://github.com/acmacalister)
