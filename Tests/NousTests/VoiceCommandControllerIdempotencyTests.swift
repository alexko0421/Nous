import Testing
@testable import Nous
import Foundation

@MainActor
@Suite("VoiceCommandController confirmation idempotency")
struct VoiceCommandControllerIdempotencyTests {

    @Test("confirmPendingAction fires the handler exactly once even when called twice")
    func confirmFiresOnce() async throws {
        var createCount = 0
        let controller = VoiceCommandController()
        controller.configure(.empty.with(createNote: { _, _ in createCount += 1 }))

        // Simulate the controller having issued a needsConfirmation
        controller.pendingAction = .createNote(title: "Test note", body: "hello")
        controller.pendingActionToken = UUID()
        controller.status = .needsConfirmation("Create note?")

        controller.confirmPendingAction()
        controller.confirmPendingAction() // second call must no-op

        #expect(createCount == 1)
        #expect(controller.pendingAction == nil)
        #expect(controller.pendingActionToken == nil)
    }

    @Test("confirmWithToken using a stale token does not fire the handler")
    func staleConfirmDoesNotFire() async throws {
        var createCount = 0
        let controller = VoiceCommandController()
        controller.configure(.empty.with(createNote: { _, _ in createCount += 1 }))

        controller.pendingAction = .createNote(title: "Test note", body: "hello")
        let staleToken = UUID()
        controller.pendingActionToken = staleToken
        controller.status = .needsConfirmation("Create note?")

        // Simulate surface switch / new pending action — token rotates
        controller.pendingActionToken = UUID()

        controller.confirmWithToken(staleToken)

        #expect(createCount == 0)
        // Original pendingAction should still be there because confirm bailed out.
        #expect(controller.pendingAction != nil)
    }

    @Test("cancelPendingAction fires exactly once even when called twice")
    func cancelFiresOnce() async throws {
        let controller = VoiceCommandController()
        controller.pendingAction = .createNote(title: "Test note", body: "hi")
        controller.pendingActionToken = UUID()
        controller.status = .needsConfirmation("Create note?")

        controller.cancelPendingAction()
        controller.cancelPendingAction() // no-op

        #expect(controller.pendingAction == nil)
        #expect(controller.pendingActionToken == nil)
    }
}

private extension VoiceActionHandlers {
    func with(createNote: @escaping (String, String) -> Void) -> VoiceActionHandlers {
        var copy = self
        copy.createNote = createNote
        return copy
    }
}
