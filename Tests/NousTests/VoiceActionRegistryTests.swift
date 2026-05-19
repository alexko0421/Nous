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

    func testNavigateToTabDoesNotExposeRetiredGalaxySurface() throws {
        let declarations = VoiceActionRegistry.declarations(includeMemoryTools: false)
        let navigate = try Self.declaration(named: "navigate_to_tab", in: declarations)
        let parameters = try XCTUnwrap(navigate["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let tab = try XCTUnwrap(properties["tab"] as? [String: Any])
        let tabs = try XCTUnwrap(tab["enum"] as? [String])

        XCTAssertEqual(tabs, ["chat", "notes", "settings"])
    }

    func testRiskMetadataMatchesExpectedMap() {
        let expectedRisks: [String: VoiceActionRisk] = [
            "get_app_state": .readOnly,
            "search_memory": .readOnly,
            "recall_recent_conversations": .readOnly,
            "navigate_to_tab": .direct,
            "set_sidebar_visibility": .direct,
            "set_scratchpad_visibility": .direct,
            "replace_scratchpad_markdown": .direct,
            "append_scratchpad_markdown": .direct,
            "set_appearance_mode": .direct,
            "open_settings_section": .direct,
            "set_composer_text": .direct,
            "append_composer_text": .direct,
            "clear_composer": .direct,
            "start_new_chat": .direct,
            "show_summary_preview": .direct,
            "dismiss_summary_preview": .direct,
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
                "sidebar_visible",
                "scratchpad_visible",
                "scratchpad_markdown",
                "active_conversation_title",
                "right_panel_mode",
                "youtube_url_text",
                "active_source_title",
                "active_source_time_range",
                "active_source_summary_title",
                "active_source_evidence_level"
            ]
        )
        XCTAssertEqual(json["current_tab"] as? String, "settings")
        XCTAssertEqual(json["settings_section"] as? String, "models")
        XCTAssertEqual(json["composer_text"] as? String, "Review voice control")
        XCTAssertEqual(json["sidebar_visible"] as? Bool, true)
        XCTAssertEqual(json["scratchpad_visible"] as? Bool, false)
        XCTAssertEqual(json["scratchpad_markdown"] as? String, "")
        XCTAssertEqual(json["active_conversation_title"] as? String, "Voice mode")
    }

    func testScratchpadWritingToolsDescribeArtifactSafeguards() throws {
        let declarations = VoiceActionRegistry.declarations(includeMemoryTools: false)
        let replace = try Self.declaration(named: "replace_scratchpad_markdown", in: declarations)
        let append = try Self.declaration(named: "append_scratchpad_markdown", in: declarations)
        let replaceDescription = try XCTUnwrap(replace["description"] as? String)
        let appendDescription = try XCTUnwrap(append["description"] as? String)

        XCTAssertTrue(replaceDescription.contains("complete markdown artifact"))
        XCTAssertTrue(replaceDescription.contains("explicitly asks"))
        XCTAssertTrue(replaceDescription.contains("synthesize"))
        XCTAssertTrue(replaceDescription.contains("not raw transcript"))
        XCTAssertTrue(replaceDescription.contains("quality gate"))
        XCTAssertTrue(replaceDescription.contains("revised artifact"))
        XCTAssertTrue(replaceDescription.contains("not cleaned-up dictation"))
        XCTAssertTrue(replaceDescription.contains("plan"))
        XCTAssertTrue(appendDescription.contains("without discarding existing content"))
        XCTAssertTrue(appendDescription.contains("default"))
        XCTAssertTrue(appendDescription.contains("synthesized"))
        XCTAssertTrue(appendDescription.contains("quality gate"))
        XCTAssertTrue(appendDescription.contains("revised artifact"))
        XCTAssertTrue(appendDescription.contains("research notes"))
        XCTAssertTrue(appendDescription.contains("incremental artifact work"))
    }

    private static func declaration(named name: String, in declarations: [[String: Any]]) throws -> [String: Any] {
        try XCTUnwrap(declarations.first { declaration in
            declaration["name"] as? String == name
        })
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
        "replace_scratchpad_markdown",
        "append_scratchpad_markdown",
        "set_appearance_mode",
        "open_settings_section",
        "set_composer_text",
        "append_composer_text",
        "clear_composer",
        "start_new_chat",
        "show_summary_preview",
        "dismiss_summary_preview",
        "propose_note",
        "confirm_pending_action",
        "cancel_pending_action"
    ]
}
