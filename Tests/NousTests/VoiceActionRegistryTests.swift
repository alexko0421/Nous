import XCTest
@testable import Nous

final class VoiceActionRegistryTests: XCTestCase {
    func testBaseCatalogIncludesAppStateAndDirectToolsWithoutMemoryTools() throws {
        let declarations = VoiceActionRegistry.declarations(includeMemoryTools: false)
        let names = try Self.toolNames(from: declarations)

        XCTAssertEqual(names, Self.baseToolNames)
    }

    func testMemoryToolsAreIncludedOnlyWhenRequested() throws {
        let declarations = VoiceActionRegistry.declarations(includeMemoryTools: true)
        let names = try Self.toolNames(from: declarations)

        XCTAssertEqual(names, Self.baseToolNames.union(["search_memory", "recall_recent_conversations"]))
    }

    func testEveryDeclaredToolHasRiskMetadata() throws {
        let declarations = VoiceActionRegistry.declarations(includeMemoryTools: true)
        let names = try Self.toolNames(from: declarations)

        for name in names {
            XCTAssertNotNil(VoiceActionRegistry.risk(for: name), "\(name) is missing risk metadata")
        }
    }

    func testRiskMetadataMatchesExpectedMap() {
        let expectedRisks: [String: VoiceActionRisk] = [
            "get_app_state": .readOnly,
            "search_memory": .readOnly,
            "recall_recent_conversations": .readOnly,
            "navigate_to_tab": .direct,
            "set_sidebar_visibility": .direct,
            "set_scratchpad_visibility": .direct,
            "set_appearance_mode": .direct,
            "open_settings_section": .direct,
            "set_composer_text": .direct,
            "append_composer_text": .direct,
            "clear_composer": .direct,
            "start_new_chat": .direct,
            "propose_note": .confirmationRequired,
            "confirm_pending_action": .confirmationRequired,
            "cancel_pending_action": .confirmationRequired
        ]

        for (name, expectedRisk) in expectedRisks {
            XCTAssertEqual(VoiceActionRegistry.risk(for: name), expectedRisk)
        }
        XCTAssertNil(VoiceActionRegistry.risk(for: "click_at_point"))
        // propose_send_message was removed 2026-04-29 (voice is now direct chat).
        XCTAssertNil(VoiceActionRegistry.risk(for: "propose_send_message"))
    }

    func testAppSnapshotEncodesStableJSON() throws {
        let snapshot = VoiceAppSnapshot(
            currentTab: .settings,
            settingsSection: .models,
            composerText: "Review voice control",
            selectedProjectName: "New York",
            sidebarVisible: true,
            scratchpadVisible: false,
            activeConversationTitle: "Voice mode"
        )

        let data = try XCTUnwrap(snapshot.jsonString().data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(json.keys),
            [
                "current_tab",
                "settings_section",
                "composer_text",
                "selected_project_name",
                "sidebar_visible",
                "scratchpad_visible",
                "active_conversation_title"
            ]
        )
        XCTAssertEqual(json["current_tab"] as? String, "settings")
        XCTAssertEqual(json["settings_section"] as? String, "models")
        XCTAssertEqual(json["composer_text"] as? String, "Review voice control")
        XCTAssertEqual(json["selected_project_name"] as? String, "New York")
        XCTAssertEqual(json["sidebar_visible"] as? Bool, true)
        XCTAssertEqual(json["scratchpad_visible"] as? Bool, false)
        XCTAssertEqual(json["active_conversation_title"] as? String, "Voice mode")
    }

    private static func toolNames(from declarations: [[String: Any]]) throws -> Set<String> {
        Set(try declarations.map { declaration in
            try XCTUnwrap(declaration["name"] as? String)
        })
    }

    private static let baseToolNames: Set<String> = [
        "get_app_state",
        "navigate_to_tab",
        "set_sidebar_visibility",
        "set_scratchpad_visibility",
        "set_appearance_mode",
        "open_settings_section",
        "set_composer_text",
        "append_composer_text",
        "clear_composer",
        "start_new_chat",
        "propose_note",
        "confirm_pending_action",
        "cancel_pending_action"
    ]
}
