import XCTest
@testable import Nous

final class PerConversationReflectionPromptTests: XCTestCase {

    // MARK: - Per-conversation prompt + schema

    func testPerConversationPromptEnforcesCorpusScope() {
        let prompt = PerConversationReflectionPrompt.systemPrompt
        XCTAssertTrue(prompt.contains("CORPUS SCOPE"),
                      "the corpus-scope rule must remain prominent — it's the load-bearing constraint that prevents trait-style claims")
        XCTAssertTrue(prompt.contains("In this conversation, you tend to..."),
                      "phrasing exemplar must scope to a single conversation")
        XCTAssertTrue(prompt.contains("Across multiple conversations"),
                      "cross-conversation language must be explicitly listed as REJECTED for this tier")
    }

    func testPerConversationPromptCapsClaimsAtOne() {
        let prompt = PerConversationReflectionPrompt.systemPrompt
        XCTAssertTrue(prompt.contains("at most 1") || prompt.contains("length 0 or 1"),
                      "this tier produces at most 1 claim — precision over breadth")
    }

    func testPerConversationSchemaShapeMatchesValidator() {
        let schema = PerConversationReflectionPrompt.responseSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        let claims = schema["claims"] as? [String: Any]
            ?? (schema["properties"] as? [String: Any])?["claims"] as? [String: Any]
        XCTAssertNotNil(claims, "schema must declare a claims array property")

        // Walk: properties.claims.maxItems
        let properties = try? XCTUnwrap(schema["properties"] as? [String: Any])
        let claimsProp = try? XCTUnwrap(properties?["claims"] as? [String: Any])
        XCTAssertEqual(claimsProp?["maxItems"] as? Int, 1,
                       "per-conversation tier caps at 1 claim, distinguishing it from weekly's 2")

        let itemSchema = try? XCTUnwrap(claimsProp?["items"] as? [String: Any])
        let itemProps = try? XCTUnwrap(itemSchema?["properties"] as? [String: Any])
        XCTAssertNotNil(itemProps?["claim"], "claim text field present")
        XCTAssertNotNil(itemProps?["confidence"], "confidence field present")
        XCTAssertNotNil(itemProps?["supporting_turn_ids"], "supporting_turn_ids field present")
        XCTAssertNotNil(itemProps?["why_non_obvious"], "why_non_obvious field present")
    }

    func testMinimumTurnCountReadsFromUserDefaults() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        // Unset → default
        XCTAssertEqual(
            PerConversationReflectionPrompt.minimumTurnCount(defaults: defaults),
            PerConversationReflectionPrompt.defaultMinimumTurnCount
        )

        // Configured → returned verbatim
        defaults.set(8, forKey: PerConversationReflectionPrompt.minimumTurnCountUserDefaultKey)
        XCTAssertEqual(PerConversationReflectionPrompt.minimumTurnCount(defaults: defaults), 8)
    }

    func testMinimumTurnCountFallsBackWhenZero() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        // Setting 0 (UserDefaults' "no value" sentinel for integers) must
        // fall back to the default — otherwise the trigger would fire on
        // every turn.
        defaults.set(0, forKey: PerConversationReflectionPrompt.minimumTurnCountUserDefaultKey)
        XCTAssertEqual(
            PerConversationReflectionPrompt.minimumTurnCount(defaults: defaults),
            PerConversationReflectionPrompt.defaultMinimumTurnCount
        )
    }

    // MARK: - Decision-pattern monthly prompt + schema

    func testDecisionPatternPromptScopesToInCorpusDecisionAtoms() {
        let prompt = DecisionPatternReflectionPrompt.systemPrompt
        XCTAssertTrue(prompt.contains("CORPUS SCOPE"))
        XCTAssertTrue(prompt.contains("Across the decisions you brought into Nous this month"),
                      "phrasing exemplar must reference 'decisions you brought into Nous' to keep the scope explicit")
        XCTAssertTrue(prompt.contains("REJECTED (single-atom claims"),
                      "single-atom rejection is what distinguishes this tier from the others")
    }

    func testDecisionPatternSchemaMatchesValidatorContract() {
        let schema = DecisionPatternReflectionPrompt.responseSchema
        let properties = try? XCTUnwrap(schema["properties"] as? [String: Any])
        let claimsProp = try? XCTUnwrap(properties?["claims"] as? [String: Any])
        XCTAssertEqual(claimsProp?["maxItems"] as? Int, 1)

        let itemSchema = try? XCTUnwrap(claimsProp?["items"] as? [String: Any])
        let itemProps = try? XCTUnwrap(itemSchema?["properties"] as? [String: Any])
        XCTAssertNotNil(itemProps?["claim"])
        XCTAssertNotNil(itemProps?["confidence"])
        XCTAssertNotNil(itemProps?["supporting_turn_ids"])
        XCTAssertNotNil(itemProps?["why_non_obvious"])
    }

    func testDecisionPatternIsDisabledByDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertFalse(DecisionPatternReflectionPrompt.isEnabled(defaults: defaults),
                       "decision-pattern monthly tier ships disabled — Block 7 telemetry must motivate enabling it")
    }

    func testDecisionPatternEnabledByUserDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(true, forKey: DecisionPatternReflectionPrompt.enabledUserDefaultKey)
        XCTAssertTrue(DecisionPatternReflectionPrompt.isEnabled(defaults: defaults))
    }

    // MARK: - Cross-tier invariants

    func testBothTiersShareValidatorContractWithWeeklyService() {
        // The point of locking in identical schema shape: downstream code
        // (ReflectionValidator, CitableEntry admission, MemoryQueryPlanner)
        // works for all three tiers without modification. Future commits
        // wire the services; this test guards that the design contract
        // doesn't drift.
        let weeklyFields = ["claim", "confidence", "supporting_turn_ids", "why_non_obvious"]

        for prompt in [
            PerConversationReflectionPrompt.responseSchema,
            DecisionPatternReflectionPrompt.responseSchema
        ] {
            let properties = prompt["properties"] as? [String: Any]
            let claimsProp = properties?["claims"] as? [String: Any]
            let itemSchema = claimsProp?["items"] as? [String: Any]
            let itemProps = itemSchema?["properties"] as? [String: Any] ?? [:]
            for field in weeklyFields {
                XCTAssertNotNil(itemProps[field],
                                "\(field) must exist in all reflection tier schemas to keep validator + admission paths uniform")
            }
        }
    }
}
