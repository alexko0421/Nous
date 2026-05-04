import Foundation
@testable import Nous

final class FakeRealtimeVoiceSession: RealtimeVoiceSessioning {
    struct FunctionOutput: Equatable {
        let callId: String
        let output: String
    }

    var startedAPIKeys: [String] = []
    var functionOutputs: [FunctionOutput] = []
    var configurations: [RealtimeVoiceConfiguration] = []
    var stopCallCount = 0
    var sendFunctionOutputError: Error?
    var sendFunctionOutputGate: SendFunctionOutputGate?
    var startGates: [StartGate] = []

    private var onEvent: (@MainActor (RealtimeVoiceEvent) async -> Void)?
    private var audioLevelHandler: (@Sendable (Float) -> Void)?
    var audioLevelHandlerForTest: (@Sendable (Float) -> Void)? { audioLevelHandler }

    func start(
        apiKey: String,
        onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void
    ) async throws {
        startedAPIKeys.append(apiKey)
        self.onEvent = onEvent
        if !startGates.isEmpty {
            let startGate = startGates.removeFirst()
            try await startGate.suspendUntilReleased()
        }
    }

    func sendFunctionOutput(callId: String, output: String) async throws {
        if let sendFunctionOutputGate {
            try await sendFunctionOutputGate.suspendUntilReleased()
        }
        if let sendFunctionOutputError {
            throw sendFunctionOutputError
        }
        functionOutputs.append(.init(callId: callId, output: output))
    }

    func stop() {
        stopCallCount += 1
    }

    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        self.audioLevelHandler = handler
    }

    func setConfiguration(_ configuration: RealtimeVoiceConfiguration) {
        configurations.append(configuration)
    }

    func emitAudioLevel(_ level: Float) {
        audioLevelHandler?(level)
    }

    func emit(_ event: RealtimeVoiceEvent) async {
        await onEvent?(event)
    }
}

actor StartGate {
    private var isInFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseError: Error?

    func waitUntilInFlight() async {
        guard !isInFlight else { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func suspendUntilReleased() async throws {
        isInFlight = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }

        if let releaseError {
            throw releaseError
        }
    }

    func release(error: Error?) {
        releaseError = error
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor SendFunctionOutputGate {
    private var isInFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseError: Error?

    func waitUntilInFlight() async {
        guard !isInFlight else { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func suspendUntilReleased() async throws {
        isInFlight = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }

        if let releaseError {
            throw releaseError
        }
    }

    func release(error: Error?) {
        releaseError = error
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
