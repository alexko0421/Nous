import Foundation
import Observation

enum VoiceSessionError: Error, Equatable {
    case missingOpenAIKey
}

@Observable
@MainActor
final class VoiceCommandController {
    var status: VoiceModeStatus = .idle
    var pendingAction: VoicePendingAction?
    var isActive: Bool = false

    private var handlers: VoiceActionHandlers = .empty
    private let session: RealtimeVoiceSessioning
    private let memory: VoiceMemorySearching?
    private var memoryContextProvider: () -> VoiceMemoryContext? = { nil }
    private var lastToolOutput: String?
    private var sessionGeneration = 0

    init(
        session: RealtimeVoiceSessioning? = nil,
        memory: VoiceMemorySearching? = nil
    ) {
        self.session = session ?? RealtimeVoiceSession(includeMemoryTools: memory != nil)
        self.memory = memory
    }

    func configure(_ handlers: VoiceActionHandlers) {
        self.handlers = handlers
    }

    func setMemoryContextProvider(_ provider: @escaping () -> VoiceMemoryContext?) {
        memoryContextProvider = provider
    }

    func markListening() {
        isActive = true
        status = .listening
    }

    func start(apiKey: String) async throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            failVoiceSession(message: "Add OpenAI API key")
            throw VoiceSessionError.missingOpenAIKey
        }

        sessionGeneration += 1
        let generation = sessionGeneration
        markListening()
        do {
            try await session.start(apiKey: trimmedAPIKey) { [weak self] event in
                guard let self else { return }
                await self.handleRealtimeEvent(event, generation: generation)
            }
        } catch {
            guard generation == sessionGeneration, isActive else { throw error }
            failVoiceSession(message: "Voice unavailable")
            throw error
        }
    }

    func stop() {
        sessionGeneration += 1
        session.stop()
        isActive = false
        pendingAction = nil
        status = .idle
    }

    func handleRealtimeEvent(_ event: RealtimeVoiceEvent) async {
        await handleRealtimeEvent(event, generation: sessionGeneration)
    }

    private func handleRealtimeEvent(_ event: RealtimeVoiceEvent, generation: Int) async {
        guard generation == sessionGeneration, isActive else { return }

        switch event {
        case .sessionReady:
            status = .listening

        case .toolCall(let call, let callId):
            do {
                lastToolOutput = nil
                try await handleToolCall(call)
                let output = lastToolOutput ?? status.displayText
                lastToolOutput = nil
                await sendFunctionOutput(callId: callId, output: output, generation: generation)
            } catch {
                lastToolOutput = nil
                restorePendingConfirmationStatus()
                await sendFunctionOutput(callId: callId, output: "Voice command rejected", generation: generation)
            }

        case .responseDone:
            if pendingAction == nil {
                status = .listening
            }

        case .error:
            failVoiceSession(message: "Voice unavailable")
        }
    }

    func handleToolCall(_ call: VoiceToolCall) async throws {
        let args = try Self.decodeArguments(call.arguments)

        switch call.name {
        case "navigate_to_tab":
            let raw = try requiredString("tab", in: args)
            guard let target = VoiceNavigationTarget(rawValue: raw) else {
                status = .error("Voice command rejected")
                throw VoiceToolError.invalidArgument("tab")
            }
            handlers.navigate(target)
            status = .action(target.actionTitle)

        case "set_sidebar_visibility":
            handlers.setSidebarVisible(try requiredBool("visible", in: args))
            status = .action("Updated sidebar")

        case "set_scratchpad_visibility":
            let visible = try requiredBool("visible", in: args)
            handlers.setScratchPadVisible(visible)
            status = .action(visible ? "Opening Scratchpad" : "Closing Scratchpad")

        case "set_composer_text":
            handlers.setComposerText(try requiredString("text", in: args))
            status = .action("Drafting message")

        case "append_composer_text":
            handlers.appendComposerText(try requiredString("text", in: args))
            status = .action("Drafting message")

        case "clear_composer":
            handlers.clearComposer()
            status = .action("Cleared draft")

        case "start_new_chat":
            handlers.startNewChat()
            status = .action("New chat")

        case "search_memory":
            guard let memory else {
                completeMemoryToolOutput("Memory unavailable.", fallbackStatus: .error("Memory unavailable"))
                return
            }
            status = .action("Searching memory")
            let query = try requiredString("query", in: args)
            let limit = try optionalInt("limit", in: args, default: 3, range: 1...5)
            guard let context = memoryContextProvider() else {
                completeMemoryToolOutput("No active conversation memory context.")
                return
            }
            do {
                completeMemoryToolOutput(try memory.searchMemory(query: query, limit: limit, context: context))
            } catch {
                completeMemoryToolOutput("Memory unavailable.", fallbackStatus: .error("Memory unavailable"))
            }

        case "recall_recent_conversations":
            guard let memory else {
                completeMemoryToolOutput("Memory unavailable.", fallbackStatus: .error("Memory unavailable"))
                return
            }
            status = .action("Recalling recent chats")
            let limit = try optionalInt("limit", in: args, default: 3, range: 1...5)
            guard let context = memoryContextProvider() else {
                completeMemoryToolOutput("No active conversation memory context.")
                return
            }
            do {
                completeMemoryToolOutput(try memory.recallRecentConversations(limit: limit, context: context))
            } catch {
                completeMemoryToolOutput("Memory unavailable.", fallbackStatus: .error("Memory unavailable"))
            }

        case "propose_send_message":
            try rejectIfPendingActionExists()
            pendingAction = .sendMessage(text: try requiredString("text", in: args))
            status = .needsConfirmation("Confirm send?")

        case "propose_note":
            try rejectIfPendingActionExists()
            pendingAction = .createNote(
                title: try requiredString("title", in: args),
                body: try requiredString("body", in: args)
            )
            status = .needsConfirmation("Create note?")

        case "confirm_pending_action":
            confirmPendingAction()

        case "cancel_pending_action":
            cancelPendingAction()

        default:
            status = .error("Voice command rejected")
            throw VoiceToolError.unknownTool(call.name)
        }
    }

    func confirmPendingAction() {
        guard let pendingAction else { return }
        self.pendingAction = nil

        switch pendingAction {
        case .sendMessage(let text):
            handlers.sendMessage(text)
            status = .action("Sent")
        case .createNote(let title, let body):
            handlers.createNote(title, body)
            status = .action("Created note")
        }
    }

    func cancelPendingAction() {
        pendingAction = nil
        status = .action("Cancelled")
    }

    private static func decodeArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw VoiceToolError.invalidJSON
        }
        return dict
    }

    private func requiredString(_ key: String, in args: [String: Any]) throws -> String {
        guard args.keys.contains(key) else { throw VoiceToolError.missingArgument(key) }
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceToolError.invalidArgument(key)
        }
        return value
    }

    private func requiredBool(_ key: String, in args: [String: Any]) throws -> Bool {
        guard args.keys.contains(key) else { throw VoiceToolError.missingArgument(key) }
        guard let value = args[key] as? Bool else { throw VoiceToolError.invalidArgument(key) }
        return value
    }

    private func optionalInt(
        _ key: String,
        in args: [String: Any],
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard args.keys.contains(key) else { return defaultValue }
        if let int = args[key] as? Int {
            return min(max(int, range.lowerBound), range.upperBound)
        }
        guard let double = args[key] as? Double else {
            throw VoiceToolError.invalidArgument(key)
        }
        guard double.isFinite else {
            return double.sign == .minus ? range.lowerBound : range.upperBound
        }
        guard double.rounded(.towardZero) == double else {
            throw VoiceToolError.invalidArgument(key)
        }
        if double < Double(range.lowerBound) { return range.lowerBound }
        if double > Double(range.upperBound) { return range.upperBound }
        return Int(double)
    }

    private func completeMemoryToolOutput(
        _ output: String,
        fallbackStatus: VoiceModeStatus? = nil
    ) {
        lastToolOutput = output
        if pendingAction != nil {
            restorePendingConfirmationStatus()
        } else if let fallbackStatus {
            status = fallbackStatus
        }
    }

    private func rejectIfPendingActionExists() throws {
        guard pendingAction == nil else {
            status = .needsConfirmation("Confirm current action first")
            throw VoiceToolError.pendingActionAlreadyExists
        }
    }

    private func sendFunctionOutput(callId: String, output: String, generation: Int) async {
        do {
            try await session.sendFunctionOutput(callId: callId, output: output)
        } catch {
            guard generation == sessionGeneration, isActive else { return }
            failVoiceSession(message: "Voice unavailable")
        }
    }

    private func failVoiceSession(message: String) {
        sessionGeneration += 1
        session.stop()
        isActive = false
        pendingAction = nil
        status = .error(message)
    }

    private func restorePendingConfirmationStatus() {
        guard let pendingAction else { return }

        switch pendingAction {
        case .sendMessage:
            status = .needsConfirmation("Confirm send?")
        case .createNote:
            status = .needsConfirmation("Create note?")
        }
    }
}
