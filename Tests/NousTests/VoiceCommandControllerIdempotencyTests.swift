import Testing
@testable import Nous
import Foundation

@MainActor
@Suite("VoiceCommandController confirmation idempotency")
struct VoiceCommandControllerIdempotencyTests {

    @Test("confirmPendingAction fires the handler exactly once even when called twice")
    func confirmFiresOnce() async throws {
        var sendCount = 0
        let controller = VoiceCommandController()
        controller.configure(.empty.with(sendMessage: { _ in sendCount += 1 }))

        // Simulate the controller having issued a needsConfirmation
        controller.pendingAction = .sendMessage(text: "hello")
        controller.pendingActionToken = UUID()
        controller.status = .needsConfirmation("Send 'hello'?")

        controller.confirmPendingAction()
        controller.confirmPendingAction() // second call must no-op

        #expect(sendCount == 1)
        #expect(controller.pendingAction == nil)
        #expect(controller.pendingActionToken == nil)
    }

    @Test("confirmWithToken using a stale token does not fire the handler")
    func staleConfirmDoesNotFire() async throws {
        var sendCount = 0
        let controller = VoiceCommandController()
        controller.configure(.empty.with(sendMessage: { _ in sendCount += 1 }))

        controller.pendingAction = .sendMessage(text: "hello")
        let staleToken = UUID()
        controller.pendingActionToken = staleToken
        controller.status = .needsConfirmation("Send 'hello'?")

        // Simulate surface switch / new pending action — token rotates
        controller.pendingActionToken = UUID()

        controller.confirmWithToken(staleToken)

        #expect(sendCount == 0)
        // Original pendingAction should still be there because confirm bailed out.
        #expect(controller.pendingAction != nil)
    }

    @Test("cancelPendingAction fires exactly once even when called twice")
    func cancelFiresOnce() async throws {
        let controller = VoiceCommandController()
        controller.pendingAction = .sendMessage(text: "hi")
        controller.pendingActionToken = UUID()
        controller.status = .needsConfirmation("Send 'hi'?")

        controller.cancelPendingAction()
        controller.cancelPendingAction() // no-op

        #expect(controller.pendingAction == nil)
        #expect(controller.pendingActionToken == nil)
    }
}

private extension VoiceActionHandlers {
    func with(sendMessage: @escaping (String) -> Void) -> VoiceActionHandlers {
        var copy = self
        copy.sendMessage = sendMessage
        return copy
    }
}
