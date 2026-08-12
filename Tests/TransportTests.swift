//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  TransportTests.swift
//  Starscream
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
#if canImport(Network)
@preconcurrency import Network
#endif
import Testing
@testable import Starscream

@Suite("Transport connection generations")
struct TransportGenerationTests {
    #if canImport(Network)
    @Test
    func `TCP transport ignores a state callback saved from the previous connection`() throws {
        let staleConnection = NWConnection(
            host: NWEndpoint.Host("203.0.113.1"),
            port: try #require(NWEndpoint.Port(rawValue: 65_000)),
            using: .tcp
        )
        let transport = TCPTransport(connection: staleConnection)
        let recorder = TransportEventRecorder()
        transport.register(delegate: recorder)
        let staleStateHandler = try #require(staleConnection.stateUpdateHandler)

        transport.connect(
            url: try #require(URL(string: "ws://192.0.2.1:65001")),
            timeout: 5,
            certificatePinning: nil
        )
        recorder.removeAll()

        staleStateHandler(.ready)

        #expect(!recorder.events.contains(.connected))
        transport.disconnect()
    }

    @Test
    func `TCP write without a current connection completes exactly once`() async {
        let transport = TCPTransport()
        let result = Locked((count: 0, receivedExpectedError: false))

        transport.write(data: Data("payload".utf8)) { error in
            result.withLock {
                $0.count += 1
                $0.receivedExpectedError = error is TCPTransportError
            }
        }

        await settleTransportCallbacks()
        let snapshot = result.withLock { $0 }
        #expect(snapshot.count == 1)
        #expect(snapshot.receivedExpectedError)
    }
    #endif

    @Test
    func `Foundation transport ignores events from a replaced stream`() throws {
        let transportBox = Locked<FoundationTransport?>(nil)
        let firstInput = Locked<InputStream?>(nil)
        let connectionCount = Locked(0)
        let recorder = TransportEventRecorder()

        let transport = FoundationTransport { inputStream, _ in
            let count = connectionCount.withLock { count -> Int in
                count += 1
                return count
            }
            let currentTransport = transportBox.withLock { $0 }
            if count == 1 {
                firstInput.withLock { $0 = inputStream }
                currentTransport?.disconnect()
            } else if count == 2, let staleInput = firstInput.withLock({ $0 }) {
                currentTransport?.stream(staleInput, handle: .errorOccurred)
            }
        }
        transportBox.withLock { $0 = transport }
        transport.register(delegate: recorder)

        transport.connect(
            url: try #require(URL(string: "ws://203.0.113.1:65000")),
            timeout: 5,
            certificatePinning: nil
        )
        transport.connect(
            url: try #require(URL(string: "ws://192.0.2.1:65001")),
            timeout: 5,
            certificatePinning: nil
        )

        #expect(!recorder.events.contains(.failedWithoutError))
        transport.disconnect()
    }

    @Test
    func `Foundation transport fails closed when pinning has no peer trust`() throws {
        let capturedInput = Locked<InputStream?>(nil)
        let recorder = TransportEventRecorder()
        let transport = FoundationTransport { inputStream, _ in
            capturedInput.withLock { $0 = inputStream }
        }
        transport.register(delegate: recorder)
        transport.connect(
            url: try #require(URL(string: "ws://203.0.113.1:65000")),
            timeout: 5,
            certificatePinning: TransportTestPinner()
        )

        let inputStream = try #require(capturedInput.withLock { $0 })
        transport.stream(inputStream, handle: .openCompleted)

        #expect(recorder.events.contains(.missingPeerTrust))
        #expect(!recorder.events.contains(.connected))
        transport.disconnect()
    }

    @Test
    func `Foundation write queued for an old connection cannot use the replacement stream`() async throws {
        let transportBox = Locked<FoundationTransport?>(nil)
        let connectionCount = Locked(0)
        let completion = Locked((count: 0, rejectedAsStale: false))
        let secondURL = try #require(URL(string: "ws://192.0.2.1:65001"))

        let transport = FoundationTransport { _, _ in
            let count = connectionCount.withLock { count -> Int in
                count += 1
                return count
            }
            guard count == 1, let currentTransport = transportBox.withLock({ $0 }) else {
                return
            }

            currentTransport.write(data: Data("old-generation".utf8)) { error in
                completion.withLock {
                    $0.count += 1
                    if case FoundationTransportError.invalidOutputStream? = error as? FoundationTransportError {
                        $0.rejectedAsStale = true
                    }
                }
            }
            currentTransport.connect(url: secondURL, timeout: 5, certificatePinning: nil)
        }
        transportBox.withLock { $0 = transport }

        transport.connect(
            url: try #require(URL(string: "ws://203.0.113.1:65000")),
            timeout: 5,
            certificatePinning: nil
        )

        try await eventuallyForTransport { completion.withLock { $0.count == 1 } }
        await settleTransportCallbacks()
        let snapshot = completion.withLock { $0 }
        #expect(snapshot.count == 1)
        #expect(snapshot.rejectedAsStale)
        transport.disconnect()
    }

    @Test
    func `Foundation timeout from an old connection cannot fail its replacement`() async throws {
        let capturedInputs = Locked<[InputStream]>([])
        let recorder = TransportEventRecorder()
        let transport = FoundationTransport { inputStream, _ in
            capturedInputs.withLock { $0.append(inputStream) }
        }
        transport.register(delegate: recorder)

        transport.connect(
            url: try #require(URL(string: "ws://203.0.113.1:65000")),
            timeout: 0.1,
            certificatePinning: nil
        )
        let firstInput = try #require(capturedInputs.withLock { $0.first })
        transport.stream(firstInput, handle: .openCompleted)

        transport.connect(
            url: try #require(URL(string: "ws://192.0.2.1:65001")),
            timeout: 2,
            certificatePinning: nil
        )
        recorder.removeAll()

        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(!recorder.events.contains(.timedOut))
        transport.disconnect()
    }
}

private final class TransportEventRecorder: TransportEventClient, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case connected
        case cancelled
        case failedWithoutError
        case failed
        case missingPeerTrust
        case timedOut
        case received
        case peerClosed
        case waiting
        case viability(Bool)
        case shouldReconnect(Bool)
    }

    private let storage = Locked<[Event]>([])

    var events: [Event] {
        storage.withLock { $0 }
    }

    func removeAll() {
        storage.withLock { $0.removeAll() }
    }

    func connectionChanged(state: ConnectionState) {
        let event: Event
        switch state {
        case .connected:
            event = .connected
        case .waiting:
            event = .waiting
        case .cancelled:
            event = .cancelled
        case .failed(let error):
            if error == nil {
                event = .failedWithoutError
            } else if case FoundationTransportError.missingPeerTrust? = error as? FoundationTransportError {
                event = .missingPeerTrust
            } else if case FoundationTransportError.timeout? = error as? FoundationTransportError {
                event = .timedOut
            } else {
                event = .failed
            }
        case .viability(let isViable):
            event = .viability(isViable)
        case .shouldReconnect(let shouldReconnect):
            event = .shouldReconnect(shouldReconnect)
        case .receive:
            event = .received
        case .peerClosed:
            event = .peerClosed
        }
        storage.withLock { $0.append(event) }
    }
}

private final class TransportTestPinner: CertificatePinning, Sendable {
    func evaluateTrust(
        trust: SecTrust,
        domain: String?,
        completion: @escaping @Sendable (PinningState) -> Void
    ) {
        completion(.success)
    }
}

private enum TransportTestWaitError: Error {
    case timedOut
}

private func eventuallyForTransport(
    attempts: Int = 200,
    condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw TransportTestWaitError.timedOut
}

private func settleTransportCallbacks() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}
