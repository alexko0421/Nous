import Foundation
import Observation

@Observable
@MainActor
final class VoiceCommandController {
    var status: VoiceModeStatus = .idle
    var pendingAction: VoicePendingAction?
    var isActive: Bool = false

    private var handlers: VoiceActionHandlers = .empty

    func configure(_ handlers: VoiceActionHandlers) {
        self.handlers = handlers
    }

    func markListening() {
        isActive = true
        status = .listening
    }

    func stop() {
        isActive = false
        pendingAction = nil
        status = .idle
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

    private func rejectIfPendingActionExists() throws {
        guard pendingAction == nil else {
            status = .needsConfirmation("Confirm current action first")
            throw VoiceToolError.pendingActionAlreadyExists
        }
    }
}
