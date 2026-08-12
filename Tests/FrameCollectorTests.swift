import Foundation
import Testing
@testable import Starscream

@Suite
struct FrameCollectorTests {
    @Test
    func `Control frames can interleave with a fragmented message`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(.textFrame, payload: Data("hel".utf8), isFinal: false))
        collector.add(frame: frame(.ping, payload: Data([0xCA, 0xFE])))
        collector.add(frame: frame(.continueFrame, payload: Data("lo".utf8)))

        #expect(delegate.events.count == 2)
        #expect(try #require(delegate.events[0].pingData) == Data([0xCA, 0xFE]))
        #expect(try #require(delegate.events[1].text) == "hello")
    }

    @Test
    func `Continuation without a message fails and resets state`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(.continueFrame, payload: Data([0x01])))
        try expectError(delegate.events.first, code: CloseCode.protocolError.rawValue)

        collector.add(frame: frame(.binaryFrame, payload: Data([0x02])))
        #expect(try #require(delegate.events.last?.binary) == Data([0x02]))
    }

    @Test
    func `New data opcode during a fragmented message fails and resets state`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(.binaryFrame, payload: Data([0x01]), isFinal: false))
        collector.add(frame: frame(.textFrame, payload: Data("bad".utf8)))

        try expectError(delegate.events.first, code: CloseCode.protocolError.rawValue)
        collector.add(frame: frame(.textFrame, payload: Data("good".utf8)))
        #expect(try #require(delegate.events.last?.text) == "good")
    }

    @Test
    func `UTF-8 may span fragment boundaries`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(.textFrame, payload: Data([0xF0, 0x9F]), isFinal: false))
        collector.add(frame: frame(.continueFrame, payload: Data([0x98, 0x80])))

        #expect(try #require(delegate.events.first?.text) == "😀")
    }

    @Test
    func `Invalid UTF-8 text uses the encoding close code`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(.textFrame, payload: Data([0xC3]), isFinal: false))
        collector.add(frame: frame(.continueFrame, payload: Data([0x28])))

        try expectError(delegate.events.first, code: CloseCode.encoding.rawValue)
    }

    @Test
    func `Invalid UTF-8 close reason uses the encoding close code`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(
            .connectionClose,
            payload: Data([0xFF]),
            closeCode: CloseCode.normal.rawValue
        ))

        try expectError(delegate.events.first, code: CloseCode.encoding.rawValue)
        #expect(delegate.events.count == 1)
    }

    @Test(arguments: [
        CloseCode.noStatusReceived.rawValue,
        CloseCode.normal.rawValue,
    ])
    func `Close without a reason preserves an empty reason`(code: UInt16) throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(
            .connectionClose,
            closeCode: code
        ))

        let close = try #require(delegate.events.first?.close)
        #expect(close.reason.isEmpty)
        #expect(close.code == code)
    }

    @Test
    func `Decompression failure is reported instead of falling back to wire bytes`() throws {
        let (collector, delegate) = makeCollector()
        delegate.decompression = { _, _ in throw TestDecompressionError.invalidStream }

        collector.add(frame: frame(
            .textFrame,
            payload: Data("not actually compressed".utf8),
            needsDecompression: true
        ))

        try expectError(delegate.events.first, code: CloseCode.protocolError.rawValue)
        #expect(delegate.events.count == 1)
    }

    @Test
    func `Fragmented compressed message decompresses every data fragment`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(
            .textFrame,
            payload: Data("hel".utf8),
            isFinal: false,
            needsDecompression: true
        ))
        collector.add(frame: frame(.pong, payload: Data([0x01])))
        collector.add(frame: frame(.continueFrame, payload: Data("lo".utf8)))

        #expect(delegate.decompressionFinalFlags == [false, true])
        #expect(try #require(delegate.events.last?.text) == "hello")
    }

    @Test
    func `Reset clears payload and compression state`() throws {
        let (collector, delegate) = makeCollector()
        collector.add(frame: frame(
            .textFrame,
            payload: Data("discard".utf8),
            isFinal: false,
            needsDecompression: true
        ))

        collector.reset()
        collector.add(frame: frame(.binaryFrame, payload: Data([0x01, 0x02])))

        #expect(delegate.decompressionFinalFlags == [false])
        #expect(try #require(delegate.events.first?.binary) == Data([0x01, 0x02]))
    }

    @Test
    func `Fragmented messages stop at the configured message limit`() throws {
        let (collector, delegate) = makeCollector()

        collector.add(frame: frame(
            .binaryFrame,
            payload: Data([1, 2, 3]),
            isFinal: false,
            maximumMessageSize: 4
        ))
        collector.add(frame: frame(
            .continueFrame,
            payload: Data([4, 5]),
            maximumMessageSize: 4
        ))

        try expectError(delegate.events.first, code: CloseCode.messageTooBig.rawValue)
    }

    @Test
    func `Decompressed output is checked against the message limit`() throws {
        let (collector, delegate) = makeCollector(maximumMessageSize: 4)
        delegate.decompression = { _, _ in Data("12345".utf8) }

        collector.add(frame: frame(
            .textFrame,
            payload: Data([0x00]),
            needsDecompression: true
        ))

        try expectError(delegate.events.first, code: CloseCode.messageTooBig.rawValue)
    }

    private func makeCollector(
        maximumMessageSize: Int = WebSocketLimits.default.maximumMessageSize
    ) -> (FrameCollector, CollectorDelegate) {
        let collector = FrameCollector(maximumMessageSize: maximumMessageSize)
        let delegate = CollectorDelegate()
        collector.delegate = delegate
        return (collector, delegate)
    }

    private func frame(
        _ opcode: FrameOpCode,
        payload: Data = Data(),
        isFinal: Bool = true,
        needsDecompression: Bool = false,
        closeCode: UInt16 = CloseCode.normal.rawValue,
        maximumMessageSize: Int = WebSocketLimits.default.maximumMessageSize
    ) -> Frame {
        Frame(
            isFin: isFinal,
            needsDecompression: needsDecompression,
            isMasked: false,
            opcode: opcode,
            payloadLength: UInt64(payload.count),
            payload: payload,
            closeCode: closeCode,
            maximumMessageSize: maximumMessageSize
        )
    }

    private func expectError(
        _ event: FrameCollector.Event?,
        code: UInt16
    ) throws {
        let webSocketError = try #require(event?.webSocketError)
        #expect(webSocketError.code == code)
    }
}

private struct CollectorClose: Sendable {
    let reason: String
    let code: UInt16
}

private extension FrameCollector.Event {
    var text: String? {
        guard case .text(let text) = self else { return nil }
        return text
    }

    var binary: Data? {
        guard case .binary(let data) = self else { return nil }
        return data
    }

    var pingData: Data? {
        guard case .ping(let data?) = self else { return nil }
        return data
    }

    var close: CollectorClose? {
        guard case .closed(let reason, let code) = self else { return nil }
        return CollectorClose(reason: reason, code: code)
    }

    var webSocketError: WSError? {
        guard case .error(let error) = self else { return nil }
        return error as? WSError
    }
}

private enum TestDecompressionError: Error {
    case invalidStream
}

private final class CollectorDelegate: FrameCollectorDelegate {
    var events: [FrameCollector.Event] = []
    var decompressionFinalFlags: [Bool] = []
    var decompression: (Data, Bool) throws -> Data = { data, _ in data }

    func didForm(event: FrameCollector.Event) {
        events.append(event)
    }

    func decompress(data: Data, isFinal: Bool) throws -> Data {
        decompressionFinalFlags.append(isFinal)
        return try decompression(data, isFinal)
    }
}
