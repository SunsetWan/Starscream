//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  NativeEngineTests.swift
//  Starscream
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Starscream

@Suite("NativeEngine lifecycle")
struct NativeEngineTests {
    @Test
    func `Callbacks from a retired session cannot affect a reconnect`() async throws {
        let harness = NativeEngineHarness()
        let recorder = NativeEngineRecorder()
        let engine = NativeEngine(dependencies: harness.dependencies)
        engine.register(delegate: recorder)

        engine.start(request: nativeTestRequest(path: "first"))
        try await eventuallyNative { harness.connections.count == 1 }
        let first = try #require(harness.connections.first)

        engine.start(request: nativeTestRequest(path: "second"))
        try await eventuallyNative { harness.connections.count == 2 }
        let second = try #require(harness.connections.last)

        engine.urlSession(first.session, webSocketTask: first.task, didOpenWithProtocol: "old")
        engine.urlSession(
            first.session,
            webSocketTask: first.task,
            didCloseWith: .goingAway,
            reason: Data("stale".utf8)
        )
        engine.urlSession(
            first.session,
            task: first.task,
            didCompleteWithError: NativeEngineTestError()
        )
        engine.urlSession(second.session, webSocketTask: second.task, didOpenWithProtocol: "new")

        try await eventuallyNative { recorder.events == [.connected("new")] }
        await settleNative()
        #expect(recorder.events == [.connected("new")])
    }

    @Test
    func `Close and completion callbacks deliver one terminal event`() async throws {
        let harness = NativeEngineHarness()
        let recorder = NativeEngineRecorder()
        let engine = NativeEngine(dependencies: harness.dependencies)
        engine.register(delegate: recorder)
        engine.start(request: nativeTestRequest())
        try await eventuallyNative { harness.connections.count == 1 }
        let connection = try #require(harness.connections.first)
        engine.urlSession(
            connection.session,
            webSocketTask: connection.task,
            didOpenWithProtocol: nil
        )
        try await eventuallyNative { recorder.events == [.connected("")] }

        engine.urlSession(
            connection.session,
            webSocketTask: connection.task,
            didCloseWith: .normalClosure,
            reason: Data("done".utf8)
        )
        engine.urlSession(
            connection.session,
            task: connection.task,
            didCompleteWithError: NativeEngineTestError()
        )

        try await eventuallyNative {
            recorder.events == [.connected(""), .disconnected("done", 1_000)]
        }
        await settleNative()
        #expect(recorder.events == [.connected(""), .disconnected("done", 1_000)])
    }

    @Test
    func `Graceful stop uses requested code and ignores later callbacks`() async throws {
        let harness = NativeEngineHarness()
        let recorder = NativeEngineRecorder()
        let engine = NativeEngine(dependencies: harness.dependencies)
        engine.register(delegate: recorder)
        engine.start(request: nativeTestRequest())
        try await eventuallyNative { harness.connections.count == 1 }
        let connection = try #require(harness.connections.first)
        engine.urlSession(
            connection.session,
            webSocketTask: connection.task,
            didOpenWithProtocol: nil
        )
        try await eventuallyNative { recorder.events == [.connected("")] }

        engine.stop(closeCode: CloseCode.goingAway.rawValue)
        try await eventuallyNative {
            harness.requestedCloseCodes == [.goingAway]
        }
        engine.urlSession(
            connection.session,
            task: connection.task,
            didCompleteWithError: URLError(.cancelled)
        )
        engine.urlSession(
            connection.session,
            webSocketTask: connection.task,
            didCloseWith: .normalClosure,
            reason: nil
        )

        try await eventuallyNative {
            recorder.events == [.connected(""), .disconnected("", CloseCode.goingAway.rawValue)]
        }
        await settleNative()
        #expect(
            recorder.events
                == [.connected(""), .disconnected("", CloseCode.goingAway.rawValue)]
        )
    }

    @Test
    func `Force stop is idempotent and suppresses cancellation callbacks`() async throws {
        let harness = NativeEngineHarness()
        let recorder = NativeEngineRecorder()
        let engine = NativeEngine(dependencies: harness.dependencies)
        engine.register(delegate: recorder)
        engine.start(request: nativeTestRequest())
        try await eventuallyNative { harness.connections.count == 1 }
        let connection = try #require(harness.connections.first)

        engine.forceStop()
        engine.forceStop()
        engine.urlSession(
            connection.session,
            task: connection.task,
            didCompleteWithError: URLError(.cancelled)
        )
        engine.urlSession(
            connection.session,
            webSocketTask: connection.task,
            didCloseWith: .abnormalClosure,
            reason: nil
        )

        try await eventuallyNative { recorder.events == [.cancelled] }
        await settleNative()
        #expect(recorder.events == [.cancelled])
    }

    @Test
    func `Send failure and URLSession completion deliver one error`() async throws {
        let harness = NativeEngineHarness(suspendSends: true)
        let recorder = NativeEngineRecorder()
        let completionCount = Locked(0)
        let engine = NativeEngine(dependencies: harness.dependencies)
        engine.register(delegate: recorder)
        engine.start(request: nativeTestRequest())
        try await eventuallyNative { harness.connections.count == 1 }
        let connection = try #require(harness.connections.first)
        engine.urlSession(
            connection.session,
            webSocketTask: connection.task,
            didOpenWithProtocol: nil
        )
        try await eventuallyNative { recorder.events == [.connected("")] }

        engine.write(string: "fail") {
            completionCount.withLock { $0 += 1 }
        }
        try await eventuallyNative { harness.pendingSendCount == 1 }
        harness.failNextSend()
        try await eventuallyNative {
            completionCount.withLock { $0 == 1 }
                && recorder.events == [.connected(""), .error]
        }
        engine.urlSession(
            connection.session,
            task: connection.task,
            didCompleteWithError: NativeEngineTestError()
        )

        await settleNative()
        #expect(completionCount.withLock { $0 } == 1)
        #expect(recorder.events == [.connected(""), .error])
    }

    @Test
    func `A stale send failure completes once without failing the new connection`() async throws {
        let harness = NativeEngineHarness(suspendSends: true)
        let recorder = NativeEngineRecorder()
        let completionCount = Locked(0)
        let engine = NativeEngine(dependencies: harness.dependencies)
        engine.register(delegate: recorder)
        engine.start(request: nativeTestRequest(path: "first"))
        try await eventuallyNative { harness.connections.count == 1 }
        let first = try #require(harness.connections.first)
        engine.urlSession(first.session, webSocketTask: first.task, didOpenWithProtocol: "first")
        try await eventuallyNative { recorder.events == [.connected("first")] }

        engine.write(string: "pending") {
            completionCount.withLock { $0 += 1 }
        }
        try await eventuallyNative { harness.pendingSendCount == 1 }

        engine.start(request: nativeTestRequest(path: "second"))
        try await eventuallyNative { harness.connections.count == 2 }
        let second = try #require(harness.connections.last)
        engine.urlSession(second.session, webSocketTask: second.task, didOpenWithProtocol: "second")
        harness.failNextSend()

        try await eventuallyNative {
            completionCount.withLock { $0 == 1 }
                && recorder.events == [.connected("first"), .connected("second")]
        }
        await settleNative()
        #expect(completionCount.withLock { $0 } == 1)
        #expect(recorder.events == [.connected("first"), .connected("second")])
    }
}

private final class NativeEngineHarness: @unchecked Sendable {
    private let connectionStorage = Locked([NativeEngine.Connection]())
    private let requestedCloseCodeStorage = Locked([URLSessionWebSocketTask.CloseCode]())
    private let sendContinuations = Locked([CheckedContinuation<Void, Error>]())
    private let shouldSuspendSends: Bool

    init(suspendSends: Bool = false) {
        shouldSuspendSends = suspendSends
    }

    var connections: [NativeEngine.Connection] {
        connectionStorage.withLock { $0 }
    }

    var requestedCloseCodes: [URLSessionWebSocketTask.CloseCode] {
        requestedCloseCodeStorage.withLock { $0 }
    }

    var pendingSendCount: Int {
        sendContinuations.withLock { $0.count }
    }

    var dependencies: NativeEngine.Dependencies {
        NativeEngine.Dependencies(
            makeConnection: { [weak self] configuration, _, request in
                let session = URLSession(configuration: configuration)
                let connection = NativeEngine.Connection(
                    session: session,
                    task: session.webSocketTask(with: request)
                )
                self?.connectionStorage.withLock { $0.append(connection) }
                return connection
            },
            resume: { _ in },
            cancel: { _ in },
            cancelWithCloseCode: { [weak self] _, closeCode in
                self?.requestedCloseCodeStorage.withLock { $0.append(closeCode) }
            },
            invalidate: { $0.invalidateAndCancel() },
            send: { [weak self] _, _ in
                guard let self, self.shouldSuspendSends else { return }
                try await withCheckedThrowingContinuation { continuation in
                    self.sendContinuations.withLock { $0.append(continuation) }
                }
            },
            sendPing: { _ in },
            receive: { _ in
                try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
                throw CancellationError()
            }
        )
    }

    func failNextSend() {
        let continuation = sendContinuations.withLock { storage in
            storage.isEmpty ? nil : storage.removeFirst()
        }
        continuation?.resume(throwing: NativeEngineTestError())
    }
}

private final class NativeEngineRecorder: EngineDelegate, @unchecked Sendable {
    private let storage = Locked([NativeEngineEvent]())

    var events: [NativeEngineEvent] {
        storage.withLock { $0 }
    }

    func didReceive(event: WebSocketEvent) {
        storage.withLock { $0.append(NativeEngineEvent(event)) }
    }
}

private enum NativeEngineEvent: Equatable, Sendable {
    case connected(String)
    case disconnected(String, UInt16)
    case error
    case cancelled
    case peerClosed
    case other

    init(_ event: WebSocketEvent) {
        switch event {
        case .connected(let headers):
            self = .connected(headers[HTTPWSHeader.protocolName] ?? "")
        case .disconnected(let reason, let code):
            self = .disconnected(reason, code)
        case .error:
            self = .error
        case .cancelled:
            self = .cancelled
        case .peerClosed:
            self = .peerClosed
        case .text, .binary, .pong, .ping, .viabilityChanged, .reconnectSuggested:
            self = .other
        }
    }
}

private struct NativeEngineTestError: Error, Sendable {}

private func nativeTestRequest(path: String = "socket") -> URLRequest {
    URLRequest(url: URL(string: "ws://example.com/\(path)")!)
}

private func eventuallyNative(
    timeout: TimeInterval = 1,
    condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("Timed out waiting for NativeEngine state")
            return
        }
        try await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
    }
}

private func settleNative() async {
    try? await Task<Never, Never>.sleep(nanoseconds: 20_000_000)
}
