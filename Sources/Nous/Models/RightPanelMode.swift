import Foundation

enum RightPanelMode: Equatable {
    case markdown
    case source
}

enum RightPanelSurfaceScope {
    static func modeAfterConversationChange(
        currentMode: RightPanelMode?,
        oldConversationId: UUID?,
        newConversationId: UUID?,
        isDraftBootstrap: Bool = false
    ) -> RightPanelMode? {
        if oldConversationId == nil,
           newConversationId != nil,
           isDraftBootstrap {
            return currentMode
        }
        return oldConversationId == newConversationId ? currentMode : nil
    }

    static func modeAfterTabChange(
        currentMode: RightPanelMode?,
        selectedTabIsChat: Bool
    ) -> RightPanelMode? {
        selectedTabIsChat ? currentMode : nil
    }

    static func modeAfterNewBlankConversation(currentMode: RightPanelMode?) -> RightPanelMode? {
        nil
    }
}
