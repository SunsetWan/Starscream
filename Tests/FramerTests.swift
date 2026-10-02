import Foundation
import Testing
@testable import Starscream

@Suite
struct FramerTests {
    @Test
    func `Client rejects every masked server frame including pong`() async throws {
        let events = try await parse([maskedFrame(opcode: .pong, payload: Data())])

        try expectError(events.first, code: CloseCode.protocolError.rawValue)
    }

    @Test
    func `Server requires masked client frames`() async throws {
        let events = try await parse([Data([0x81, 0x00])], isServer: true)

        try expectError(events.first, code: CloseCode.protocolError.rawValue)
    }

    @Test
    func `Server unmasks client payload`() async throws {
        let events = try await parse([
            maskedFrame(opcode: .textFrame, payload: Data("hello".utf8)),
        ], isServer: true)

        let frame = try #require(events.first?.frame)
        #expect(frame.isMasked)
        #expect(frame.payload == Data("hello".utf8))
    }

    @Test(arguments: [UInt8(0xA1), UInt8(0x91)])
    func `RSV2 and RSV3 are rejected even when compression is enabled`(
        firstByte: UInt8
    ) async throws {
        let events = try await parse(
            [Data([firstByte, 0x00])],
            compressionEnabled: true
        )

        try expectError(events.first, code: CloseCode.protocolError.rawValue)
    }

    @Test
    func `RSV1 requires negotiated compression and an initial data opcode`() async throws {
        try expectError(
            try await parse([Data([0xC1, 0x00])]).first,
            code: CloseCode.protocolError.rawValue
        )
        try expectError(
            try await parse(
                [Data([0xC9, 0x00])],
                compressionEnabled: true
            ).first,
            code: CloseCode.protocolError.rawValue
        )
        try expectError(
            try await parse(
                [Data([0xC0, 0x00])],
                compressionEnabled: true
            ).first,
            code: CloseCode.protocolError.rawValue
        )

        let events = try await parse(
            [Data([0xC1, 0x00])],
            compressionEnabled: true
        )
        #expect(try #require(events.first?.frame).needsDecompression)
    }

    @Test
    func `Reserved opcode is rejected`() async throws {
        let events = try await parse([Data([0x83, 0x00])])

        try expectError(events.first, code: CloseCode.protocolError.rawValue)
    }

    @Test(arguments: [
        [UInt8(0x09), 0x00],
        [UInt8(0x89), 0x7E],
    ])
    func `Fragmented or extended-length control frame is rejected`(
        wireBytes: [UInt8]
    ) async throws {
        let events = try await parse([Data(wireBytes)])

        try expectError(events.first, code: CloseCode.protocolError.rawValue)
    }

    @Test
    func `Non-minimal extended lengths are rejected`() async throws {
        var encodedAs16Bit = Data([0x82, 0x7E, 0x00, 0x7D])
        encodedAs16Bit.append(Data(repeating: 0xAA, count: 125))
        try expectError(
            try await parse([encodedAs16Bit]).first,
            code: CloseCode.protocolError.rawValue
        )

        var encodedAs64Bit = Data([0x82, 0x7F])
        encodedAs64Bit.append(contentsOf: uint64Bytes(65_535))
        try expectError(
            try await parse([encodedAs64Bit]).first,
            code: CloseCode.protocolError.rawValue
        )
    }

    @Test
    func `64-bit length with its most significant bit set is rejected`() async throws {
        var data = Data([0x82, 0x7F, 0x80])
        data.append(Data(repeating: 0, count: 7))

        try expectError(
            try await parse([data]).first,
            code: CloseCode.protocolError.rawValue
        )
    }

    @Test
    func `Minimal 64-bit payload length is accepted`() async throws {
        let payload = Data(repeating: 0xAA, count: 65_536)
        var wire = Data([0x82, 0x7F])
        wire.append(contentsOf: uint64Bytes(UInt64(payload.count)))
        wire.append(payload)

        let frame = try #require(try await parse([wire]).first?.frame)
        #expect(frame.payloadLength == 65_536)
        #expect(frame.payload == payload)
    }

    @Test
    func `Declared frame length is rejected before its payload is buffered`() async throws {
        let events = try await parse(
            [Data([0x82, 0x05])],
            limits: WebSocketLimits(maximumFrameSize: 4, maximumMessageSize: 8)
        )

        try expectError(events.first, code: CloseCode.messageTooBig.rawValue)
    }

    @Test
    func `Writer rejects a payload above the configured frame limit`() throws {
        let framer = WSFramer(
            isServer: true,
            limits: WebSocketLimits(maximumFrameSize: 4, maximumMessageSize: 8)
        )

        try expectWriteError(
            framer.createWriteFrameResult(
                opcode: .binaryFrame,
                payload: Data(repeating: 0, count: 5),
                isCompressed: false
            ),
            code: CloseCode.messageTooBig.rawValue
        )
    }

    @Test
    func `Masked close is interpreted only after unmasking its payload`() async throws {
        var closePayload = Data([0x03, 0xE8])
        closePayload.append(Data("bye".utf8))

        let events = try await parse([
            maskedFrame(opcode: .connectionClose, payload: closePayload),
        ], isServer: true)

        let frame = try #require(events.first?.frame)
        #expect(frame.closeCode == CloseCode.normal.rawValue)
        #expect(frame.payload == Data("bye".utf8))
        #expect(frame.payloadLength == 3)
    }

    @Test
    func `Empty close uses the no-status-received sentinel`() async throws {
        let frame = try #require(
            try await parse([Data([0x88, 0x00])]).first?.frame
        )

        #expect(frame.closeCode == CloseCode.noStatusReceived.rawValue)
        #expect(frame.payload.isEmpty)
    }

    @Test
    func `One-byte close payload is rejected`() async throws {
        let events = try await parse([
            maskedFrame(opcode: .connectionClose, payload: Data([0x03])),
        ], isServer: true)

        try expectError(events.first, code: CloseCode.protocolError.rawValue)
    }

    @Test(arguments: [
        UInt16(999), 1004, 1005, 1006, 1015, 1016, 2999, 5000,
    ])
    func `Invalid close code is rejected`(code: UInt16) async throws {
        let events = try await parse([
            maskedFrame(
                opcode: .connectionClose,
                payload: closePayload(code: code)
            ),
        ], isServer: true)

        try expectError(events.first, code: CloseCode.protocolError.rawValue)
    }

    @Test(arguments: [UInt16(1000), 1014, 3000, 4999])
    func `Valid close code is accepted`(code: UInt16) async throws {
        let events = try await parse([
            maskedFrame(
                opcode: .connectionClose,
                payload: closePayload(code: code)
            ),
        ], isServer: true)

        #expect(try #require(events.first?.frame).closeCode == code)
    }

    @Test
    func `Close code 1010 is client-only`() async throws {
        let serverClose = Data([0x88, 0x02, 0x03, 0xF2])
        try expectError(
            try await parse([serverClose]).first,
            code: CloseCode.protocolError.rawValue
        )

        let clientClose = maskedFrame(
            opcode: .connectionClose,
            payload: closePayload(code: CloseCode.mandatoryExtension.rawValue)
        )
        let receivedByServer = try #require(
            try await parse([clientClose], isServer: true).first?.frame
        )
        #expect(receivedByServer.closeCode == CloseCode.mandatoryExtension.rawValue)

        try expectWriteError(WSFramer(isServer: true).createWriteFrameResult(
            opcode: .connectionClose,
            payload: closePayload(code: CloseCode.mandatoryExtension.rawValue),
            isCompressed: false
        ))
        _ = try WSFramer().createWriteFrameResult(
            opcode: .connectionClose,
            payload: closePayload(code: CloseCode.mandatoryExtension.rawValue),
            isCompressed: false
        ).get()
    }

    @Test(arguments: [1, 2, 3, 4, 17, 129])
    func `Streaming parser handles extended frame split at every boundary`(
        split: Int
    ) async throws {
        var wire = Data([0x82, 0x7E, 0x00, 0x7E])
        let payload = Data((0..<126).map(UInt8.init))
        wire.append(payload)

        let events = try await parse([
            Data(wire.prefix(split)),
            Data(wire.dropFirst(split)),
        ])

        #expect(try #require(events.first?.frame).payload == payload)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 7, 8, 9, 133])
    func `Streaming parser handles masked frame split across the mask key`(
        split: Int
    ) async throws {
        let payload = Data((0..<126).map(UInt8.init))
        let wire = maskedFrame(opcode: .binaryFrame, payload: payload)

        let events = try await parse([
            Data(wire.prefix(split)),
            Data(wire.dropFirst(split)),
        ], isServer: true)

        #expect(try #require(events.first?.frame).payload == payload)
    }

    @Test
    func `Streaming parser emits every coalesced frame`() async throws {
        var wire = Data([0x81, 0x01, 0x41])
        wire.append(Data([0x82, 0x02, 0x01, 0x02]))

        let events = try await parse([wire], expectedEventCount: 2)

        #expect(events.count == 2)
        let first = try #require(events.first?.frame)
        let second = try #require(events.last?.frame)
        #expect(first.opcode == .textFrame)
        #expect(first.payload == Data([0x41]))
        #expect(second.opcode == .binaryFrame)
        #expect(second.payload == Data([0x01, 0x02]))
    }

    @Test
    func `Reset discards partial frame state`() async throws {
        let events = try await confirmation(
            "frame after reset",
            expectedCount: 1
        ) { confirm in
            let (stream, continuation) = AsyncStream<FrameEvent>.makeStream()
            let recorder = FramerRecorder { event in
                continuation.yield(event)
            }
            let framer = WSFramer()
            framer.register(delegate: recorder)

            framer.add(data: Data([0x81]))
            framer.reset()
            framer.add(data: Data([0x81, 0x00]))

            return try await collect(
                from: stream,
                continuation: continuation,
                expectedCount: 1,
                confirmation: confirm
            )
        }

        #expect(try #require(events.first?.frame).payload.isEmpty)
    }

    @Test
    func `Register waits for queued frames before replacing the delegate`() async throws {
        let oldPayloads = Locked([Data]())
        let newPayloads = Locked([Data]())
        let firstCallbackStarted = Locked(false)
        let releaseFirstCallback = DispatchSemaphore(value: 0)
        let registrationStarted = Locked(false)
        let registrationReturned = Locked(false)
        let oldDelegate = FramerRecorder { event in
            guard case .frame(let frame) = event else { return }
            oldPayloads.withLock { $0.append(frame.payload) }
            if frame.payload == Data("first".utf8) {
                firstCallbackStarted.withLock { $0 = true }
                releaseFirstCallback.wait()
            }
        }
        let newDelegate = FramerRecorder { event in
            guard case .frame(let frame) = event else { return }
            newPayloads.withLock { $0.append(frame.payload) }
        }
        let framer = WSFramer()
        let framerBox = Locked(framer)
        framer.register(delegate: oldDelegate)
        framer.add(data: Data([0x81, 0x05]) + Data("first".utf8))
        try await eventuallyForFramer { firstCallbackStarted.withLock { $0 } }
        framer.add(data: Data([0x81, 0x06]) + Data("second".utf8))

        DispatchQueue.global().async {
            registrationStarted.withLock { $0 = true }
            framerBox.withLock { $0.register(delegate: newDelegate) }
            registrationReturned.withLock { $0 = true }
        }
        try await eventuallyForFramer { registrationStarted.withLock { $0 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!registrationReturned.withLock { $0 })

        releaseFirstCallback.signal()
        try await eventuallyForFramer {
            registrationReturned.withLock { $0 }
                && oldPayloads.withLock { $0.count == 2 }
        }
        #expect(oldPayloads.withLock { $0 } == [Data("first".utf8), Data("second".utf8)])
        #expect(newPayloads.withLock { $0 }.isEmpty)
    }

    @Test
    func `Reset does not return until earlier queued parsing has finished`() async throws {
        let firstCallbackStarted = Locked(false)
        let releaseFirstCallback = DispatchSemaphore(value: 0)
        let resetStarted = Locked(false)
        let resetReturned = Locked(false)
        let delegate = FramerRecorder { event in
            guard case .frame = event else { return }
            firstCallbackStarted.withLock { $0 = true }
            releaseFirstCallback.wait()
        }
        let framer = WSFramer()
        let framerBox = Locked(framer)
        framer.register(delegate: delegate)
        framer.add(data: Data([0x81, 0x00]))
        try await eventuallyForFramer { firstCallbackStarted.withLock { $0 } }

        DispatchQueue.global().async {
            resetStarted.withLock { $0 = true }
            framerBox.withLock { $0.reset() }
            resetReturned.withLock { $0 = true }
        }
        try await eventuallyForFramer { resetStarted.withLock { $0 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!resetReturned.withLock { $0 })

        releaseFirstCallback.signal()
        try await eventuallyForFramer { resetReturned.withLock { $0 } }
    }

    @Test
    func `Writer masks client frames and leaves server frames unmasked`() throws {
        let payload = Data("hello".utf8)
        let clientData = try WSFramer().createWriteFrameResult(
            opcode: .textFrame,
            payload: payload,
            isCompressed: false
        ).get()
        let serverData = try WSFramer(isServer: true).createWriteFrameResult(
            opcode: .textFrame,
            payload: payload,
            isCompressed: false
        ).get()

        #expect(clientData[1] & 0x80 != 0)
        #expect(serverData[1] & 0x80 == 0)
        #expect(Data(serverData.dropFirst(2)) == payload)
    }

    @Test
    func `Writer accepts Data with a nonzero start index`() throws {
        let payload = Data([0xFF, 0x01, 0x02, 0x03]).dropFirst()

        let frame = try WSFramer(isServer: true).createWriteFrameResult(
            opcode: .binaryFrame,
            payload: payload,
            isCompressed: false
        ).get()

        #expect(Data(frame.dropFirst(2)) == Data([0x01, 0x02, 0x03]))
    }

    @Test(arguments: WriteFailureCase.invalidControlFrames)
    func `Writer rejects invalid control frame`(testCase: WriteFailureCase) throws {
        try expectWriteError(
            WSFramer(isServer: true).createWriteFrameResult(
                opcode: testCase.opcode,
                payload: testCase.payload,
                isCompressed: testCase.isCompressed
            ),
            code: testCase.expectedCode
        )
    }

    @Test
    func `Writer accepts a control payload of exactly 125 bytes`() throws {
        _ = try WSFramer(isServer: true).createWriteFrameResult(
            opcode: .ping,
            payload: Data(repeating: 0, count: 125),
            isCompressed: false
        ).get()
    }

    @Test(arguments: WriteFailureCase.invalidOpcodesAndCloseCodes)
    func `Writer rejects reserved opcode or invalid close code`(
        testCase: WriteFailureCase
    ) throws {
        try expectWriteError(
            WSFramer(isServer: true).createWriteFrameResult(
                opcode: testCase.opcode,
                payload: testCase.payload,
                isCompressed: testCase.isCompressed
            ),
            code: testCase.expectedCode
        )
    }

    @Test(arguments: PayloadLengthCase.boundaries)
    func `Writer uses shortest payload length encoding at boundary`(
        testCase: PayloadLengthCase
    ) throws {
        let frame = try writeFrame(
            WSFramer(isServer: true),
            payloadLength: testCase.payloadLength
        )

        #expect(frame[1] & 0x7F == testCase.marker)
        #expect(Array(frame.dropFirst(2).prefix(testCase.extensionBytes.count)) == testCase.extensionBytes)
    }

    @Test(arguments: WriteFailureCase.invalidUTF8Frames)
    func `Writer rejects invalid UTF-8`(testCase: WriteFailureCase) throws {
        try expectWriteError(
            WSFramer(isServer: true).createWriteFrameResult(
                opcode: testCase.opcode,
                payload: testCase.payload,
                isCompressed: testCase.isCompressed
            ),
            code: testCase.expectedCode
        )
    }

    @Test
    func `Writer sets RSV1 only when compression is enabled`() throws {
        let framer = WSFramer(isServer: true)
        try expectWriteError(framer.createWriteFrameResult(
            opcode: .textFrame,
            payload: Data([0x01]),
            isCompressed: true
        ))

        framer.updateCompression(supports: true)
        let frame = try framer.createWriteFrameResult(
            opcode: .textFrame,
            payload: Data([0x01]),
            isCompressed: true
        ).get()
        #expect(frame[0] & 0x40 != 0)
    }

    private func parse(
        _ chunks: [Data],
        isServer: Bool = false,
        compressionEnabled: Bool = false,
        limits: WebSocketLimits = .default,
        expectedEventCount: Int = 1
    ) async throws -> [FrameEvent] {
        try await confirmation(
            "parsed \(expectedEventCount) frame event(s)",
            expectedCount: expectedEventCount
        ) { confirm in
            let (stream, continuation) = AsyncStream<FrameEvent>.makeStream()
            let recorder = FramerRecorder { event in
                continuation.yield(event)
            }
            let framer = WSFramer(isServer: isServer, limits: limits)
            framer.updateCompression(supports: compressionEnabled)
            framer.register(delegate: recorder)

            for chunk in chunks {
                framer.add(data: chunk)
            }

            return try await collect(
                from: stream,
                continuation: continuation,
                expectedCount: expectedEventCount,
                confirmation: confirm
            )
        }
    }

    private func collect(
        from stream: AsyncStream<FrameEvent>,
        continuation: AsyncStream<FrameEvent>.Continuation,
        expectedCount: Int,
        confirmation: Confirmation
    ) async throws -> [FrameEvent] {
        var events: [FrameEvent] = []
        for await event in stream {
            events.append(event)
            confirmation()
            if events.count == expectedCount {
                continuation.finish()
                return events
            }
        }
        throw FramerTestError.eventStreamEndedEarly
    }

    private func expectError(_ event: FrameEvent?, code: UInt16) throws {
        let webSocketError = try #require(event?.webSocketError)
        #expect(webSocketError.code == code)
    }

    private func expectWriteError(
        _ result: Result<Data, Error>,
        code: UInt16 = CloseCode.protocolError.rawValue
    ) throws {
        let webSocketError = try #require(result.webSocketError)
        #expect(webSocketError.code == code)
    }

    private func maskedFrame(
        opcode: FrameOpCode,
        payload: Data,
        isFinal: Bool = true
    ) -> Data {
        let key = [UInt8(0x12), 0x34, 0x56, 0x78]
        var bytes = [UInt8((isFinal ? 0x80 : 0x00) | opcode.rawValue)]
        if payload.count < 126 {
            bytes.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            bytes.append(0x80 | 126)
            bytes.append(UInt8(payload.count >> 8))
            bytes.append(UInt8(payload.count & 0xFF))
        } else {
            bytes.append(0x80 | 127)
            bytes.append(contentsOf: uint64Bytes(UInt64(payload.count)))
        }
        bytes.append(contentsOf: key)
        for (index, byte) in payload.enumerated() {
            bytes.append(byte ^ key[index % key.count])
        }
        return Data(bytes)
    }

    private func closePayload(code: UInt16) -> Data {
        Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    }

    private func uint64Bytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { shift in
            UInt8((value >> UInt64((7 - shift) * 8)) & 0xFF)
        }
    }

    private func writeFrame(_ framer: WSFramer, payloadLength: Int) throws -> Data {
        try framer.createWriteFrameResult(
            opcode: .binaryFrame,
            payload: Data(repeating: 0xAA, count: payloadLength),
            isCompressed: false
        ).get()
    }
}

private enum FramerWaitError: Error {
    case timedOut
}

private func eventuallyForFramer(
    attempts: Int = 200,
    condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw FramerWaitError.timedOut
}

private enum FramerTestError: Error {
    case eventStreamEndedEarly
}

struct WriteFailureCase: Sendable {
    let opcode: FrameOpCode
    let payload: Data
    let isCompressed: Bool
    let expectedCode: UInt16

    static let invalidControlFrames = [
        WriteFailureCase(
            opcode: .ping,
            payload: Data(repeating: 0, count: 126),
            isCompressed: false,
            expectedCode: CloseCode.protocolError.rawValue
        ),
        WriteFailureCase(
            opcode: .pong,
            payload: Data(),
            isCompressed: true,
            expectedCode: CloseCode.protocolError.rawValue
        ),
        WriteFailureCase(
            opcode: .connectionClose,
            payload: Data([0x03]),
            isCompressed: false,
            expectedCode: CloseCode.protocolError.rawValue
        ),
    ]

    static let invalidOpcodesAndCloseCodes = [
        WriteFailureCase(
            opcode: .unknown,
            payload: Data(),
            isCompressed: false,
            expectedCode: CloseCode.protocolError.rawValue
        ),
        WriteFailureCase(
            opcode: .connectionClose,
            payload: Data([0x03, 0xED]),
            isCompressed: false,
            expectedCode: CloseCode.protocolError.rawValue
        ),
    ]

    static let invalidUTF8Frames = [
        WriteFailureCase(
            opcode: .textFrame,
            payload: Data([0xFF]),
            isCompressed: false,
            expectedCode: CloseCode.encoding.rawValue
        ),
        WriteFailureCase(
            opcode: .connectionClose,
            payload: Data([0x03, 0xE8, 0xFF]),
            isCompressed: false,
            expectedCode: CloseCode.encoding.rawValue
        ),
    ]
}

struct PayloadLengthCase: Sendable {
    let payloadLength: Int
    let marker: UInt8
    let extensionBytes: [UInt8]

    static let boundaries = [
        PayloadLengthCase(payloadLength: 125, marker: 125, extensionBytes: []),
        PayloadLengthCase(payloadLength: 126, marker: 126, extensionBytes: [0x00, 0x7E]),
        PayloadLengthCase(payloadLength: 65_535, marker: 126, extensionBytes: [0xFF, 0xFF]),
        PayloadLengthCase(
            payloadLength: 65_536,
            marker: 127,
            extensionBytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]
        ),
    ]
}

private extension FrameEvent {
    var frame: Frame? {
        guard case .frame(let frame) = self else { return nil }
        return frame
    }

    var webSocketError: WSError? {
        guard case .error(let error) = self else { return nil }
        return error as? WSError
    }
}

private extension Result<Data, Error> {
    var webSocketError: WSError? {
        guard case .failure(let error) = self else { return nil }
        return error as? WSError
    }
}

private final class FramerRecorder: FramerEventClient, Sendable {
    private let handler: @Sendable (FrameEvent) -> Void

    init(handler: @escaping @Sendable (FrameEvent) -> Void) {
        self.handler = handler
    }

    func frameProcessed(event: FrameEvent) {
        handler(event)
    }
}
