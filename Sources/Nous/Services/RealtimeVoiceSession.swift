import Foundation
import os

protocol RealtimeVoiceSocketing: AnyObject {
    func connect(request: URLRequest) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> String?
    func close()
}

final class URLSessionRealtimeVoiceSocket: RealtimeVoiceSocketing {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(request: URLRequest) async throws {
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        startPingLoop(task: task)
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
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // Send a WebSocket ping frame every 10s while the socket is open. Without
    // application-level traffic during quiet periods (between user turns), the
    // OS / OpenAI server can decide the socket is idle and tear it down,
    // surfacing as `.sessionEnded` after the assistant finishes speaking.
    // Pings keep the connection visibly alive end-to-end.
    private func startPingLoop(task: URLSessionWebSocketTask) {
        pingTask = Task { [weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let task else { return }
                task.sendPing { _ in }
            }
        }
    }
}

enum RealtimeVoiceSocketError: Error {
    case notConnected
}

enum RealtimeVoiceEvent: Equatable {
    case sessionReady
    case toolCall(VoiceToolCall, callId: String)
    case toolCallArgumentsDone(VoiceToolCall, callId: String)
    case responseDoneWithToolCall(VoiceToolCall, callId: String)
    case outputAudioDelta(String)
    case inputTranscriptDelta(String)
    case inputTranscriptCompleted(String)
    case outputTranscriptDelta(String)
    case outputTranscriptCompleted(String)
    case responseDone
    case sessionEnded
    case userSpeechStarted
    case error(String)
}

protocol RealtimeVoiceSessioning: AnyObject {
    func start(apiKey: String, onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void) async throws
    func sendFunctionOutput(callId: String, output: String) async throws
    func stop()
    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void)
    func setConfiguration(_ configuration: RealtimeVoiceConfiguration)
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
            return .toolCallArgumentsDone(VoiceToolCall(name: name, arguments: arguments), callId: callId)
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
        case "input_audio_buffer.speech_started":
            return .userSpeechStarted
        case "error":
            let error = json["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Realtime error")
        default:
            return nil
        }
    }

    private static func parseResponseDone(_ json: [String: Any]) -> RealtimeVoiceEvent {
        let response = json["response"] as? [String: Any]
        let status = response?["status"] as? String

        // OpenAI Realtime sends `response.done` with a `status` field of
        // "completed", "cancelled", "incomplete", or "failed". Only "failed"
        // is a true session-fatal error. "cancelled" (e.g. barge-in / client
        // cancel / VAD interrupt) and "incomplete" (audio truncation, max
        // tokens) are normal turn-end states — the voice session should
        // continue listening. Treating them as `.error` (which earlier code
        // did) was the root cause of voice mode closing immediately after
        // the assistant finished a reply.
        let normalEndStatuses: Set<String> = ["completed", "cancelled", "incomplete"]
        if status == nil || normalEndStatuses.contains(status!) {
            if let toolCall = completedToolCall(from: response) {
                return .responseDoneWithToolCall(toolCall.call, callId: toolCall.callId)
            }
            return .responseDone
        }

        let statusDetails = response?["status_details"] as? [String: Any]
        let error = statusDetails?["error"] as? [String: Any]
        let message = error?["message"] as? String

        if let message, !message.isEmpty {
            return .error("Realtime response \(status!): \(message)")
        }
        return .error("Realtime response \(status!)")
    }

    private static func completedToolCall(from response: [String: Any]?) -> (call: VoiceToolCall, callId: String)? {
        guard let output = response?["output"] as? [[String: Any]] else { return nil }

        for item in output {
            guard item["type"] as? String == "function_call" else { continue }
            if let status = item["status"] as? String, status != "completed" { continue }
            guard let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String,
                  let callId = item["call_id"] as? String else {
                return nil
            }
            return (VoiceToolCall(name: name, arguments: arguments), callId)
        }

        return nil
    }
}

final class RealtimeVoiceSession: RealtimeVoiceSessioning {
    static let defaultModel = RealtimeVoiceModel.realtime2.rawValue

    private struct AssistantAudioGateState {
        var isMuted = false
        var pendingPlaybackBuffers = 0
        var responseDoneSeen = false
        var generation = 0
        var suppressAssistantAudioUntilResponseDone = false
    }

    private let socket: RealtimeVoiceSocketing
    private let audioCapture: VoiceAudioCapturing?
    private let audioPlayback: VoiceAudioPlaying?
    private let includeMemoryTools: Bool
    private let assistantEchoTailNanoseconds: UInt64
    private var receiveTask: Task<Void, Never>?
    private var outboundQueue: RealtimeVoiceOutboundQueue?
    private let audioLevelHandlerLock = OSAllocatedUnfairLock<(@Sendable (Float) -> Void)?>(initialState: nil)
    private let configurationLock = OSAllocatedUnfairLock<RealtimeVoiceConfiguration>(initialState: .default)
    // Assistant playback is tracked separately from microphone forwarding.
    // Mic audio keeps flowing so server-side semantic VAD can barge in; when
    // the server reports user speech, local playback is flushed immediately.
    private let assistantAudioGateLock = OSAllocatedUnfairLock<AssistantAudioGateState>(
        initialState: AssistantAudioGateState()
    )
    private let assistantTailTaskLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(
        socket: RealtimeVoiceSocketing = URLSessionRealtimeVoiceSocket(),
        audioCapture: VoiceAudioCapturing? = VoiceAudioCapture(),
        audioPlayback: VoiceAudioPlaying? = VoiceAudioPlayback(),
        includeMemoryTools: Bool = false,
        assistantEchoTailNanoseconds: UInt64 = 800_000_000
    ) {
        self.socket = socket
        self.audioCapture = audioCapture
        self.audioPlayback = audioPlayback
        self.includeMemoryTools = includeMemoryTools
        self.assistantEchoTailNanoseconds = assistantEchoTailNanoseconds
    }

    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        audioLevelHandlerLock.withLock { $0 = handler }
    }

    func setConfiguration(_ configuration: RealtimeVoiceConfiguration) {
        configurationLock.withLock { $0 = configuration }
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
            let configuration = configurationLock.withLock { $0 }
            try await socket.connect(request: Self.makeRequest(apiKey: apiKey, model: configuration.model.rawValue))
            try audioPlayback?.start()
            let queue = RealtimeVoiceOutboundQueue(maxPendingAudioChunks: 8)
            outboundQueue = queue
            queue.start(socket: socket, onEvent: onEvent)
            try await queue.enqueueControl(Self.makeSessionUpdateEvent(
                includeMemoryTools: includeMemoryTools,
                configuration: configuration
            ))
            startReceiveLoop(onEvent: onEvent)
            try audioCapture?.start(onAudio: { chunk in
                queue.enqueueAudio(chunk)
            }, onAudioLevel: { [weak self] level in
                guard let self else { return }
                let handler = self.audioLevelHandlerLock.withLock { $0 }
                handler?(level)
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
            Self.makeResponseCreateEvent(configuration: configurationLock.withLock { $0 })
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
        resetAssistantAudioGate()
    }

    static func makeSessionUpdateEvent(
        includeMemoryTools: Bool = false,
        configuration: RealtimeVoiceConfiguration = .default
    ) throws -> Data {
        var transcription: [String: Any] = [
            "model": "gpt-4o-mini-transcribe"
        ]
        if let languageCode = configuration.language.transcriptionLanguageCode {
            transcription["language"] = languageCode
        }

        var session: [String: Any] = [
            "type": "realtime",
            "model": configuration.model.rawValue,
            "instructions": voiceInstructions(configuration: configuration),
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
                    "transcription": transcription,
                    "turn_detection": [
                        "type": "semantic_vad",
                        "eagerness": "low",
                        "create_response": true,
                        "interrupt_response": true
                    ]
                ],
                "output": audioOutputConfiguration(configuration: configuration)
            ],
            "tools": VoiceActionRegistry.declarations(includeMemoryTools: includeMemoryTools),
            "tool_choice": "auto"
        ]
        if let reasoningEffort = configuration.reasoningEffort {
            session["reasoning"] = ["effort": reasoningEffort.rawValue]
        }

        let body: [String: Any] = [
            "type": "session.update",
            "session": session
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func startReceiveLoop(
        onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void
    ) {
        receiveTask = Task { [socket] in
            while !Task.isCancelled {
                do {
                    guard let raw = try await socket.receive() else {
                        if !Task.isCancelled {
                            await onEvent(.sessionEnded)
                        }
                        break
                    }
                    guard let event = RealtimeVoiceEventParser.parse(raw) else { continue }
                    if case .outputAudioDelta(let base64Audio) = event {
                        if isSuppressingAssistantAudioUntilResponseDone() {
                            continue
                        }
                        // Track queued playback so a later user-speech start
                        // can cancel stale assistant audio without waiting for
                        // every scheduled AVAudioPlayerNode buffer to finish.
                        let generation = beginAssistantPlaybackBuffer()
                        let didSchedule = audioPlayback?.enqueue(
                            base64PCM16Audio: base64Audio,
                            onPlaybackComplete: { [weak self] in
                                self?.assistantPlaybackBufferDidFinish(generation: generation)
                            }
                        ) ?? false
                        if !didSchedule {
                            assistantPlaybackBufferDidFinish(generation: generation)
                        }
                        continue
                    }
                    if case .responseDone = event {
                        markAssistantResponseDone()
                    }
                    if case .userSpeechStarted = event {
                        if suppressAssistantAudioForBargeIn() {
                            audioPlayback?.flushPendingBuffers()
                        }
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

    private func isAssistantAudioGateMuted() -> Bool {
        assistantAudioGateLock.withLock { $0.isMuted }
    }

    private func isSuppressingAssistantAudioUntilResponseDone() -> Bool {
        assistantAudioGateLock.withLock { $0.suppressAssistantAudioUntilResponseDone }
    }

    private func beginAssistantPlaybackBuffer() -> Int {
        cancelAssistantTailUnlock()
        return assistantAudioGateLock.withLock { state in
            if !state.isMuted || (state.responseDoneSeen && state.pendingPlaybackBuffers == 0) {
                state.generation += 1
                state.pendingPlaybackBuffers = 0
                state.responseDoneSeen = false
                state.suppressAssistantAudioUntilResponseDone = false
            }
            state.isMuted = true
            state.pendingPlaybackBuffers += 1
            return state.generation
        }
    }

    private func markAssistantResponseDone() {
        let generationToUnlock = assistantAudioGateLock.withLock { state -> Int? in
            state.responseDoneSeen = true
            state.suppressAssistantAudioUntilResponseDone = false
            guard state.isMuted, state.pendingPlaybackBuffers == 0 else { return nil }
            return state.generation
        }
        if let generationToUnlock {
            scheduleAssistantTailUnlock(generation: generationToUnlock)
        }
    }

    private func suppressAssistantAudioForBargeIn() -> Bool {
        cancelAssistantTailUnlock()
        return assistantAudioGateLock.withLock { state in
            guard state.isMuted || state.pendingPlaybackBuffers > 0 else { return false }
            state.generation += 1
            state.isMuted = false
            state.pendingPlaybackBuffers = 0
            state.responseDoneSeen = false
            state.suppressAssistantAudioUntilResponseDone = true
            return true
        }
    }

    private func assistantPlaybackBufferDidFinish(generation: Int) {
        let generationToUnlock = assistantAudioGateLock.withLock { state -> Int? in
            guard generation == state.generation else { return nil }
            if state.pendingPlaybackBuffers > 0 {
                state.pendingPlaybackBuffers -= 1
            }
            guard state.isMuted, state.responseDoneSeen, state.pendingPlaybackBuffers == 0 else {
                return nil
            }
            return state.generation
        }
        if let generationToUnlock {
            scheduleAssistantTailUnlock(generation: generationToUnlock)
        }
    }

    private func scheduleAssistantTailUnlock(generation: Int) {
        let tailNanoseconds = assistantEchoTailNanoseconds
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: tailNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.assistantAudioGateLock.withLock { state in
                guard state.generation == generation,
                      state.responseDoneSeen,
                      state.pendingPlaybackBuffers == 0 else {
                    return
                }
                state.isMuted = false
            }
        }
        assistantTailTaskLock.withLock { current in
            current?.cancel()
            current = task
        }
    }

    private func cancelAssistantTailUnlock() {
        assistantTailTaskLock.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func resetAssistantAudioGate() {
        cancelAssistantTailUnlock()
        assistantAudioGateLock.withLock { state in
            state.generation += 1
            state.isMuted = false
            state.pendingPlaybackBuffers = 0
            state.responseDoneSeen = false
            state.suppressAssistantAudioUntilResponseDone = false
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

    static func makeResponseCreateEvent(configuration: RealtimeVoiceConfiguration = .default) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "audio": [
                    "output": audioOutputConfiguration(configuration: configuration)
                ]
            ]
        ])
    }

    private static func audioOutputConfiguration(configuration: RealtimeVoiceConfiguration) -> [String: Any] {
        [
            "format": [
                "type": "audio/pcm",
                "rate": 24_000
            ],
            "voice": configuration.voice.rawValue
        ]
    }

    private static func voiceInstructions(configuration: RealtimeVoiceConfiguration) -> String {
        """
        You are the live voice layer for Nous. Sound like a calm, present thinking partner, not a command menu. \
        Speak naturally in short conversational turns. Acknowledge what Alex said before taking action, especially before tool calls. \
        Carry a compact Nous thinking spine: first principles, inversion, pain test, honest pushback when something does not add up, and a specific next action when the turn needs one. \
        Match Alex's emotional energy without performing: if he is excited, allow brighter momentum; if he is confused, slow down and steady the pace; if he is tired, hurt, or stressed, respond to the feeling before analysis. Keep the voice alive, not theatrical or flat. \
        In Cantonese, sound like a trusted Hong Kong mentor: colloquial rhythm, natural particles, small pauses, and varied emphasis; technical terms can stay in English. \
        Call tools only for explicit user intent. Use direct tools for navigation, settings sections, appearance, scratchpad/sidebar visibility, scratchpad drafting, and composer drafting. \
        Voice is not a separate mode: infer the artifact Alex wants from the spoken request, and do not ask Alex to switch modes before helping. \
        When Alex asks to write an essay, post, script, note, draft, outline, plan, brainstorm map, research brief, study note, proposal, email, or revision, treat the scratchpad as the live writing surface: interview briefly, open it, then write usable markdown with replace_scratchpad_markdown or append_scratchpad_markdown; do not paste the raw transcript onto the white paper; synthesize the discussion into a coherent draft, outline, plan, or paragraph that Alex can keep editing. \
        Run a short interview for missing essentials, no more than three focused questions before the first draft unless Alex asks to keep exploring. \
        Artifact quality gate: before any scratchpad write, internally build a hidden brief, turn it into a first draft, run a critic pass for specificity, missing requirements, weak thesis or logic, and generic phrasing, then call the scratchpad tool with only the revised markdown. Do not call scratchpad tools with raw transcript text or cleaned-up dictation; if missing information blocks quality, ask the one question that most improves the artifact, and if you proceed under uncertainty, state the assumption in the markdown. \
        Artifact playbooks: Essay asks for thesis, audience, requirement, evidence, and tone; Plan asks for goal, timeframe, constraints, assumptions, milestones, time-boxed schedule, daily checklist, risk countermeasures, definition of done, Next 3 Actions, and what to ignore; a Plan draft must be execution-grade rather than a thin outline. Brainstorm turns loose ideas into directions, tensions, examples, and next experiments; Research brief captures the question, what is known, what to verify, source notes, and a provisional answer; Rewrite preserves the current intent while changing structure, sharpness, or tone. \
        As soon as Alex asks for an artifact, make the scratchpad visible immediately, even if you still need to interview him before drafting; if the current scratchpad matters and is not in view, call get_app_state before replacing or appending. \
        Prefer appending unless Alex clearly asks to replace the existing white paper; never silently discard a draft. \
        When Alex asks to summarize, recap, or organize the current spoken thought, write concise markdown and call show_summary_preview so it appears as a summary paper below the floating capsule. \
        Use propose_note for creating notes. When a tool succeeds, report the result plainly; never claim you clicked UI. \
        Voice user utterances are automatically recorded into the chat history. Language: \(configuration.language.realtimeInstruction)
        """
    }
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
