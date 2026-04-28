import XCTest
@testable import Nous

final class RealtimeVoiceSessionTests: XCTestCase {
    func testBuildsRealtimeRequestWithBearerTokenAndModel() throws {
        let request = RealtimeVoiceSession.makeRequest(apiKey: "sk-test", model: "gpt-realtime")

        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testSessionUpdateIncludesTextOutputAndTools() throws {
        let data = try RealtimeVoiceSession.makeSessionUpdateEvent()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let toolNames = try Self.toolNames(from: session)

        XCTAssertEqual(json["type"] as? String, "session.update")
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertNil(session["model"])
        XCTAssertEqual(session["output_modalities"] as? [String], ["text"])
        XCTAssertEqual(session["tool_choice"] as? String, "auto")
        XCTAssertFalse(toolNames.isEmpty)
        XCTAssertFalse(toolNames.contains("search_memory"))
        XCTAssertFalse(toolNames.contains("recall_recent_conversations"))
    }

    func testSessionUpdateIncludesMemoryToolsOnlyWhenRequested() throws {
        let data = try RealtimeVoiceSession.makeSessionUpdateEvent(includeMemoryTools: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let toolNames = try Self.toolNames(from: session)

        XCTAssertTrue(toolNames.contains("search_memory"))
        XCTAssertTrue(toolNames.contains("recall_recent_conversations"))
    }

    func testParsesFunctionCallArgumentsDone() throws {
        let raw = """
        {
          "type": "response.function_call_arguments.done",
          "name": "navigate_to_tab",
          "call_id": "call_123",
          "arguments": "{\\"tab\\":\\"galaxy\\"}"
        }
        """

        let event = try XCTUnwrap(RealtimeVoiceEventParser.parse(raw))

        XCTAssertEqual(event, .toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call_123"))
    }

    func testParsesResponseDoneAsThinkingComplete() throws {
        let raw = #"{"type":"response.done"}"#

        XCTAssertEqual(RealtimeVoiceEventParser.parse(raw), .responseDone)
    }

    func testParsesCompletedResponseDoneAsResponseDone() throws {
        let raw = #"{"type":"response.done","response":{"status":"completed"}}"#

        XCTAssertEqual(RealtimeVoiceEventParser.parse(raw), .responseDone)
    }

    func testParsesFailedResponseDoneAsError() throws {
        let raw = """
        {
          "type": "response.done",
          "response": {
            "status": "failed",
            "status_details": {
              "error": {
                "message": "Model request failed"
              }
            }
          }
        }
        """

        guard case .error(let message) = RealtimeVoiceEventParser.parse(raw) else {
            return XCTFail("Expected response.done with failed status to parse as an error.")
        }

        XCTAssertTrue(message.contains("failed"))
        XCTAssertTrue(message.contains("Model request failed"))
    }

    func testUnknownEventsAreIgnored() throws {
        XCTAssertNil(RealtimeVoiceEventParser.parse(#"{"type":"rate_limits.updated"}"#))
    }

    func testAudioAppendEventShape() throws {
        let data = try RealtimeVoiceSession.makeAudioAppendEvent(base64Audio: "abc123")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(json["audio"] as? String, "abc123")
    }

    func testFunctionOutputEventShape() throws {
        let data = try RealtimeVoiceSession.makeFunctionOutputEvent(callId: "call_123", output: "Opened Galaxy")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "conversation.item.create")
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_123")
        XCTAssertEqual(item["output"] as? String, "Opened Galaxy")
    }

    func testResponseCreateEventShape() throws {
        let data = try RealtimeVoiceSession.makeResponseCreateEvent()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try XCTUnwrap(json["response"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "response.create")
        XCTAssertEqual(response["output_modalities"] as? [String], ["text"])
    }

    func testStartConnectsAndSendsSessionUpdateWithoutAudioCapture() async throws {
        let socket = FakeRealtimeVoiceSocket()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: nil)

        try await session.start(apiKey: "sk-test") { _ in }
        try await Task.sleep(nanoseconds: 50_000_000)
        session.stop()

        XCTAssertEqual(socket.connectedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(socket.sentTypes, ["session.update"])
    }

    func testStartClosesSocketWhenSessionUpdateSendThrows() async throws {
        let socket = FakeRealtimeVoiceSocket(sendErrorAfterCount: 0)
        let session = RealtimeVoiceSession(socket: socket, audioCapture: nil)

        do {
            try await session.start(apiKey: "sk-test") { _ in }
            XCTFail("Expected start to rethrow the session.update send error.")
        } catch {
            XCTAssertEqual(error as? FakeRealtimeVoiceSocket.Error, .sendFailed)
        }

        XCTAssertNotNil(socket.connectedRequest)
        XCTAssertEqual(socket.closeCount, 2)
    }

    func testAudioChunksAreSentInCaptureOrderThroughSessionQueue() async throws {
        let socket = FakeRealtimeVoiceSocket(audioSendDelays: ["first": 100_000_000])
        let audioCapture = FakeVoiceAudioCapture()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: audioCapture)

        try await session.start(apiKey: "sk-test") { _ in }
        audioCapture.emit("first")
        audioCapture.emit("second")

        try await waitUntil { socket.sentAudioChunks.count == 2 }
        session.stop()

        XCTAssertEqual(socket.sentAudioChunks, ["first", "second"])
    }

    func testAudioChunksEmittedAfterStopAreNotSent() async throws {
        let socket = FakeRealtimeVoiceSocket()
        let audioCapture = FakeVoiceAudioCapture()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: audioCapture)

        try await session.start(apiKey: "sk-test") { _ in }
        session.stop()
        audioCapture.emit("after-stop")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(socket.sentAudioChunks.contains("after-stop"))
    }

    func testFunctionOutputWaitsBehindInFlightAudioOnSingleOutboundQueue() async throws {
        let socket = FakeRealtimeVoiceSocket(audioSendDelays: ["first": 100_000_000])
        let audioCapture = FakeVoiceAudioCapture()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: audioCapture)

        try await session.start(apiKey: "sk-test") { _ in }
        audioCapture.emit("first")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await session.sendFunctionOutput(callId: "call_123", output: "Opened Galaxy")
        session.stop()

        XCTAssertEqual(socket.sentTypes.prefix(4), [
            "session.update",
            "input_audio_buffer.append",
            "conversation.item.create",
            "response.create"
        ])
        XCTAssertEqual(socket.sentAudioChunks, ["first"])
    }

    func testFunctionOutputAndResponseCreateStayAdjacentWhenAudioArrivesDuringToolOutput() async throws {
        let socket = FakeRealtimeVoiceSocket(eventSendDelays: ["conversation.item.create": 100_000_000])
        let audioCapture = FakeVoiceAudioCapture()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: audioCapture)

        try await session.start(apiKey: "sk-test") { _ in }
        let outputTask = Task {
            try await session.sendFunctionOutput(callId: "call_123", output: "Opened Galaxy")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        audioCapture.emit("during-tool-output")
        try await outputTask.value
        try await waitUntil {
            socket.sentAudioChunks.contains("during-tool-output")
        }
        session.stop()

        XCTAssertEqual(socket.sentTypes.prefix(4), [
            "session.update",
            "conversation.item.create",
            "response.create",
            "input_audio_buffer.append"
        ])
    }

    func testAudioBacklogDropsStaleChunksWhenSocketStalls() async throws {
        let socket = FakeRealtimeVoiceSocket(audioSendDelays: ["chunk-0": 150_000_000])
        let audioCapture = FakeVoiceAudioCapture()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: audioCapture)

        try await session.start(apiKey: "sk-test") { _ in }
        for index in 0..<20 {
            audioCapture.emit("chunk-\(index)")
        }

        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            socket.sentAudioChunks.contains("chunk-19")
        }
        session.stop()

        XCTAssertLessThan(socket.sentAudioChunks.count, 20)
        XCTAssertEqual(socket.sentAudioChunks.first, "chunk-0")
        XCTAssertTrue(socket.sentAudioChunks.contains("chunk-19"))
    }

    func testSendFunctionOutputSendsOutputThenResponseCreate() async throws {
        let socket = FakeRealtimeVoiceSocket()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: nil)

        try await session.start(apiKey: "sk-test") { _ in }
        try await session.sendFunctionOutput(callId: "call_123", output: "Opened Galaxy")
        session.stop()

        XCTAssertEqual(socket.sentTypes, ["session.update", "conversation.item.create", "response.create"])
    }

    func testOldOutboundQueueFailureAfterRestartDoesNotCancelNewQueue() async throws {
        let socket = FakeRealtimeVoiceSocket(heldAudioChunks: ["old-audio"])
        let audioCapture = FakeVoiceAudioCapture()
        let session = RealtimeVoiceSession(socket: socket, audioCapture: audioCapture)

        try await session.start(apiKey: "sk-test") { _ in }
        audioCapture.emit("old-audio")
        try await socket.waitForHeldAudioSend("old-audio")

        session.stop()
        try await session.start(apiKey: "sk-test") { _ in }
        socket.failHeldAudioSend("old-audio")
        try await Task.sleep(nanoseconds: 50_000_000)

        try await session.sendFunctionOutput(callId: "call_123", output: "Opened Galaxy")
        session.stop()

        XCTAssertEqual(socket.sentTypes.suffix(2), ["conversation.item.create", "response.create"])
    }

    private static func toolNames(from session: [String: Any]) throws -> [String] {
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }
}

private final class FakeRealtimeVoiceSocket: RealtimeVoiceSocketing {
    enum Error: Swift.Error, Equatable {
        case sendFailed
    }

    var connectedRequest: URLRequest? {
        locked { _connectedRequest }
    }

    var sentData: [Data] {
        locked { _sentData }
    }

    var closeCount: Int {
        locked { _closeCount }
    }

    private let sendErrorAfterCount: Int?
    private let audioSendDelays: [String: UInt64]
    private let eventSendDelays: [String: UInt64]
    private let heldAudioChunks: Set<String>
    private let lock = NSLock()
    private var _connectedRequest: URLRequest?
    private var _sentData: [Data] = []
    private var _closeCount = 0
    private var heldAudioSends: [String: CheckedContinuation<Void, Swift.Error>] = [:]
    private var heldAudioWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        sendErrorAfterCount: Int? = nil,
        audioSendDelays: [String: UInt64] = [:],
        eventSendDelays: [String: UInt64] = [:],
        heldAudioChunks: Set<String> = []
    ) {
        self.sendErrorAfterCount = sendErrorAfterCount
        self.audioSendDelays = audioSendDelays
        self.eventSendDelays = eventSendDelays
        self.heldAudioChunks = heldAudioChunks
    }

    var sentTypes: [String] {
        let data = sentData
        return data.compactMap { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["type"] as? String
        }
    }

    var sentAudioChunks: [String] {
        let data = sentData
        return data.compactMap { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "input_audio_buffer.append" else {
                return nil
            }
            return json["audio"] as? String
        }
    }

    func connect(request: URLRequest) async throws {
        locked {
            _connectedRequest = request
        }
    }

    func send(_ data: Data) async throws {
        let sentCount = locked { _sentData.count }
        if let sendErrorAfterCount, sentCount >= sendErrorAfterCount {
            throw Error.sendFailed
        }

        if let chunk = audioChunk(from: data) {
            if heldAudioChunks.contains(chunk) {
                try await holdAudioSend(chunk)
            }
            if let delay = audioSendDelays[chunk] {
                try await Task.sleep(nanoseconds: delay)
            }
        }
        if let eventType = eventType(from: data), let delay = eventSendDelays[eventType] {
            try await Task.sleep(nanoseconds: delay)
        }
        locked {
            _sentData.append(data)
        }
    }

    func receive() async throws -> String? {
        nil
    }

    func close() {
        locked {
            _closeCount += 1
        }
    }

    func waitForHeldAudioSend(_ chunk: String) async throws {
        if locked({ heldAudioSends[chunk] != nil }) {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResume = locked {
                if heldAudioSends[chunk] != nil {
                    return true
                }
                heldAudioWaiters[chunk, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func failHeldAudioSend(_ chunk: String) {
        let continuation = locked {
            heldAudioSends.removeValue(forKey: chunk)
        }
        continuation?.resume(throwing: Error.sendFailed)
    }

    private func audioChunk(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "input_audio_buffer.append" else {
            return nil
        }
        return json["audio"] as? String
    }

    private func eventType(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["type"] as? String
    }

    private func holdAudioSend(_ chunk: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = locked {
                heldAudioSends[chunk] = continuation
                return heldAudioWaiters.removeValue(forKey: chunk) ?? []
            }
            waiters.forEach { $0.resume() }
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}

private final class FakeVoiceAudioCapture: VoiceAudioCapturing {
    private(set) var didStop = false
    private var onAudio: (@Sendable (String) -> Void)?

    func start(onAudio: @escaping @Sendable (String) -> Void) throws {
        self.onAudio = onAudio
    }

    func stop() {
        didStop = true
    }

    func emit(_ chunk: String) {
        onAudio?(chunk)
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping () -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
            XCTFail("Timed out waiting for condition.")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
