import Foundation

protocol RealtimeVoiceSocketing: AnyObject {
    func connect(request: URLRequest) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> String?
    func close()
}

final class URLSessionRealtimeVoiceSocket: RealtimeVoiceSocketing {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(request: URLRequest) async throws {
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ data: Data) async throws {
        guard let task else { throw RealtimeVoiceSocketError.notConnected }

        if let string = String(data: data, encoding: .utf8) {
            try await task.send(.string(string))
        } else {
            try await task.send(.data(data))
        }
    }

    func receive() async throws -> String? {
        guard let task else { throw RealtimeVoiceSocketError.notConnected }

        switch try await task.receive() {
        case .string(let string):
            return string
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

enum RealtimeVoiceSocketError: Error {
    case notConnected
}

enum RealtimeVoiceEvent: Equatable {
    case sessionReady
    case toolCall(VoiceToolCall, callId: String)
    case outputAudioDelta(String)
    case inputTranscriptDelta(String)
    case inputTranscriptCompleted(String)
    case outputTranscriptDelta(String)
    case outputTranscriptCompleted(String)
    case responseDone
    case error(String)
}

protocol RealtimeVoiceSessioning: AnyObject {
    func start(apiKey: String, onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void) async throws
    func sendFunctionOutput(callId: String, output: String) async throws
    func stop()
    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void)
}

extension RealtimeVoiceSessioning {
    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {}
}

enum RealtimeVoiceEventParser {
    static func parse(_ raw: String) -> RealtimeVoiceEvent? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "session.created", "session.updated":
            return .sessionReady
        case "response.function_call_arguments.done":
            guard let name = json["name"] as? String,
                  let arguments = json["arguments"] as? String,
                  let callId = json["call_id"] as? String else {
                return .error("Invalid tool call")
            }
            return .toolCall(VoiceToolCall(name: name, arguments: arguments), callId: callId)
        case "response.output_audio.delta", "response.audio.delta":
            guard let delta = json["delta"] as? String else {
                return .error("Invalid audio delta")
            }
            return .outputAudioDelta(delta)
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"] as? String else {
                return .error("Invalid input transcript delta")
            }
            return .inputTranscriptDelta(delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = json["transcript"] as? String else {
                return .error("Invalid input transcript completion")
            }
            return .inputTranscriptCompleted(transcript)
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            guard let delta = json["delta"] as? String else {
                return .error("Invalid output transcript delta")
            }
            return .outputTranscriptDelta(delta)
        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            guard let transcript = json["transcript"] as? String else {
                return .error("Invalid output transcript completion")
            }
            return .outputTranscriptCompleted(transcript)
        case "response.done":
            return parseResponseDone(json)
        case "error":
            let error = json["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Realtime error")
        default:
            return nil
        }
    }

    private static func parseResponseDone(_ json: [String: Any]) -> RealtimeVoiceEvent {
        let response = json["response"] as? [String: Any]
        guard let status = response?["status"] as? String,
              status != "completed" else {
            return .responseDone
        }

        let statusDetails = response?["status_details"] as? [String: Any]
        let error = statusDetails?["error"] as? [String: Any]
        let message = error?["message"] as? String

        if let message, !message.isEmpty {
            return .error("Realtime response \(status): \(message)")
        }
        return .error("Realtime response \(status)")
    }
}

final class RealtimeVoiceSession: RealtimeVoiceSessioning {
    static let defaultModel = "gpt-realtime-mini"

    private let socket: RealtimeVoiceSocketing
    private let audioCapture: VoiceAudioCapturing?
    private let audioPlayback: VoiceAudioPlaying?
    private let includeMemoryTools: Bool
    private var receiveTask: Task<Void, Never>?
    private var outboundQueue: RealtimeVoiceOutboundQueue?
    private var audioLevelHandler: (@Sendable (Float) -> Void)?

    init(
        socket: RealtimeVoiceSocketing = URLSessionRealtimeVoiceSocket(),
        audioCapture: VoiceAudioCapturing? = VoiceAudioCapture(),
        audioPlayback: VoiceAudioPlaying? = VoiceAudioPlayback(),
        includeMemoryTools: Bool = false
    ) {
        self.socket = socket
        self.audioCapture = audioCapture
        self.audioPlayback = audioPlayback
        self.includeMemoryTools = includeMemoryTools
    }

    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        self.audioLevelHandler = handler
    }

    static func makeRequest(apiKey: String, model: String = defaultModel) -> URLRequest {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func start(
        apiKey: String,
        onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void
    ) async throws {
        stop()

        do {
            try await socket.connect(request: Self.makeRequest(apiKey: apiKey))
            try audioPlayback?.start()
            let queue = RealtimeVoiceOutboundQueue(maxPendingAudioChunks: 8)
            outboundQueue = queue
            queue.start(socket: socket, onEvent: onEvent)
            try await queue.enqueueControl(Self.makeSessionUpdateEvent(includeMemoryTools: includeMemoryTools))
            startReceiveLoop(onEvent: onEvent)
            try audioCapture?.start(onAudio: { chunk in
                queue.enqueueAudio(chunk)
            }, onAudioLevel: { [weak self] level in
                self?.audioLevelHandler?(level)
            })
        } catch {
            stop()
            throw error
        }
    }

    func sendFunctionOutput(callId: String, output: String) async throws {
        guard let outboundQueue else { throw RealtimeVoiceSocketError.notConnected }

        try await outboundQueue.enqueueControls([
            Self.makeFunctionOutputEvent(callId: callId, output: output),
            Self.makeResponseCreateEvent()
        ])
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        let queue = outboundQueue
        outboundQueue = nil
        queue?.stop()
        audioCapture?.stop()
        audioPlayback?.stop()
        socket.close()
    }

    static func makeSessionUpdateEvent(
        model: String = defaultModel,
        includeMemoryTools: Bool = false
    ) throws -> Data {
        let body: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": voiceInstructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe"
                        ],
                        "turn_detection": [
                            "type": "semantic_vad"
                        ]
                    ],
                    "output": audioOutputConfiguration
                ],
                "tools": VoiceActionRegistry.declarations(includeMemoryTools: includeMemoryTools),
                "tool_choice": "auto"
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func startReceiveLoop(
        onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void
    ) {
        receiveTask = Task { [socket] in
            while !Task.isCancelled {
                do {
                    guard let raw = try await socket.receive() else { break }
                    guard let event = RealtimeVoiceEventParser.parse(raw) else { continue }
                    if case .outputAudioDelta(let base64Audio) = event {
                        audioPlayback?.enqueue(base64PCM16Audio: base64Audio)
                        continue
                    }
                    await onEvent(event)
                } catch {
                    if Task.isCancelled { break }
                    await onEvent(.error(error.localizedDescription))
                    break
                }
            }
        }
    }

    static func makeAudioAppendEvent(base64Audio: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ])
    }

    static func makeFunctionOutputEvent(callId: String, output: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ]
        ], options: [.sortedKeys])
    }

    static func makeResponseCreateEvent() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "audio": [
                    "output": audioOutputConfiguration
                ]
            ]
        ])
    }

    private static let audioOutputConfiguration: [String: Any] = [
        "format": [
            "type": "audio/pcm",
            "rate": 24_000
        ],
        "voice": "cedar"
    ]

    private static let voiceInstructions = """
    You are the voice control layer for Nous. Call tools only for explicit user intent. \
    Use direct tools for navigation, settings sections, appearance, scratchpad/sidebar visibility, and composer drafting. \
    Use propose_* tools for sending messages or creating notes. Never claim you clicked UI.
    """
}

private final class RealtimeVoiceOutboundQueue {
    private enum Item {
        case control([Data], CheckedContinuation<Void, Error>)
        case audio(String)
    }

    private let maxPendingAudioChunks: Int
    private let lock = NSLock()
    private var isRunning = false
    private var pendingItems: [Item] = []
    private var waiter: CheckedContinuation<Item?, Never>?
    private var sendTask: Task<Void, Never>?

    init(maxPendingAudioChunks: Int) {
        self.maxPendingAudioChunks = max(0, maxPendingAudioChunks)
    }

    func start(
        socket: RealtimeVoiceSocketing,
        onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void
    ) {
        stop()

        lock.lock()
        isRunning = true
        lock.unlock()

        sendTask = Task { [weak self, socket] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let item = await nextItem() else { break }

                do {
                    switch item {
                    case .control(let frames, _):
                        for frame in frames {
                            try await socket.send(frame)
                        }
                    case .audio(let chunk):
                        try await socket.send(RealtimeVoiceSession.makeAudioAppendEvent(base64Audio: chunk))
                    }
                    completeControlItem(item)
                } catch {
                    failControlItem(item, with: error)
                    if !Task.isCancelled {
                        await onEvent(.error(error.localizedDescription))
                    }
                    stop()
                    break
                }
            }
        }
    }

    func enqueueControl(_ data: Data) async throws {
        try await enqueueControls([data])
    }

    func enqueueControls(_ data: [Data]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(.control(data, continuation))
        }
    }

    func enqueueAudio(_ chunk: String) {
        enqueue(.audio(chunk))
    }

    func stop() {
        let itemsToCancel: [Item]
        let waiterToResume: CheckedContinuation<Item?, Never>?
        let taskToCancel: Task<Void, Never>?

        lock.lock()
        isRunning = false
        itemsToCancel = pendingItems
        pendingItems.removeAll()
        waiterToResume = waiter
        waiter = nil
        taskToCancel = sendTask
        sendTask = nil
        lock.unlock()

        taskToCancel?.cancel()
        waiterToResume?.resume(returning: nil)
        for item in itemsToCancel {
            failControlItem(item, with: CancellationError())
        }
    }

    private func enqueue(_ item: Item) {
        let waiterToResume: CheckedContinuation<Item?, Never>?
        let itemToResume: Item?

        lock.lock()
        guard isRunning else {
            lock.unlock()
            if case .control(_, let continuation) = item {
                continuation.resume(throwing: CancellationError())
            }
            return
        }

        if case .audio = item {
            removeOldestAudioIfNeeded()
        }

        if let waiter {
            self.waiter = nil
            waiterToResume = waiter
            itemToResume = item
        } else {
            waiterToResume = nil
            itemToResume = nil
            pendingItems.append(item)
        }
        lock.unlock()

        if let waiterToResume, let itemToResume {
            waiterToResume.resume(returning: itemToResume)
        }
    }

    private func nextItem() async -> Item? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !pendingItems.isEmpty {
                let item = pendingItems.removeFirst()
                lock.unlock()
                continuation.resume(returning: item)
            } else if isRunning {
                waiter = continuation
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }

    private func removeOldestAudioIfNeeded() {
        let pendingAudioCount = pendingItems.reduce(0) { count, item in
            if case .audio = item { return count + 1 }
            return count
        }
        guard pendingAudioCount >= maxPendingAudioChunks,
              let index = pendingItems.firstIndex(where: { item in
                  if case .audio = item { return true }
                  return false
              }) else {
            return
        }
        pendingItems.remove(at: index)
    }

    private func completeControlItem(_ item: Item) {
        if case .control(_, let continuation) = item {
            continuation.resume()
        }
    }

    private func failControlItem(_ item: Item, with error: Error) {
        if case .control(_, let continuation) = item {
            continuation.resume(throwing: error)
        }
    }
}
