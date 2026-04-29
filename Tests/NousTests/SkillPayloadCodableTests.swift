import XCTest
@testable import Nous

final class SkillPayloadCodableTests: XCTestCase {

    func testRoundTripPreservesAllFields() throws {
        let payload = SkillPayload(
            payloadVersion: 1,
            name: "stoic-cantonese-voice",
            description: "Stoic Cantonese mentor voice",
            source: .alex,
            trigger: SkillTrigger(
                kind: .always,
                modes: [.direction, .brainstorm, .plan],
                priority: 70
            ),
            action: SkillAction(
                kind: .promptFragment,
                content: "Speak plainly and avoid corporate-AI register."
            ),
            rationale: "Alex needs the voice to stay grounded.",
            antiPatternExamples: ["Sounds like a product manager"]
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SkillPayload.self, from: data)

        XCTAssertEqual(decoded, payload)
    }

    func testCamelCaseKeysDecodeWithDefaultDecoder() throws {
        let decoded = try JSONDecoder().decode(SkillPayload.self, from: Data(validPayloadJSON.utf8))

        XCTAssertEqual(decoded.payloadVersion, 1)
        XCTAssertEqual(decoded.name, "concrete-over-generic")
        XCTAssertEqual(decoded.trigger.modes, [.direction, .brainstorm])
        XCTAssertEqual(decoded.action.kind, .promptFragment)
    }

    func testMissingAntiPatternExamplesDefaultsToEmptyArray() throws {
        let json = """
        {
          "payloadVersion": 1,
          "name": "direct-when-disagreeing",
          "source": "alex",
          "trigger": {
            "kind": "always",
            "modes": ["direction"],
            "priority": 65
          },
          "action": {
            "kind": "promptFragment",
            "content": "Say disagreement plainly."
          }
        }
        """

        let decoded = try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.antiPatternExamples, [])
    }

    func testMissingDescriptionAndRationaleStillDecodes() throws {
        let json = """
        {
          "payloadVersion": 1,
          "name": "interleave-language",
          "source": "alex",
          "trigger": {
            "kind": "always",
            "modes": ["plan"],
            "priority": 60
          },
          "action": {
            "kind": "promptFragment",
            "content": "Use Cantonese for warmth and English for technical terms."
          },
          "antiPatternExamples": []
        }
        """

        let decoded = try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8))

        XCTAssertNil(decoded.description)
        XCTAssertNil(decoded.rationale)
    }

    func testMissingPayloadVersionFails() {
        let json = validPayloadJSON.replacingOccurrences(of: #"  "payloadVersion": 1,\#n"#, with: "")

        XCTAssertThrowsError(try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8)))
    }

    func testPayloadVersionZeroFails() {
        let json = validPayloadJSON.replacingOccurrences(of: #""payloadVersion": 1"#, with: #""payloadVersion": 0"#)

        XCTAssertThrowsError(try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8)))
    }

    func testPayloadVersionTwoFails() {
        let json = validPayloadJSON.replacingOccurrences(of: #""payloadVersion": 1"#, with: #""payloadVersion": 2"#)

        XCTAssertThrowsError(try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8)))
    }

    func testRegexTriggerKindFails() {
        let json = validPayloadJSON.replacingOccurrences(of: #""kind": "always""#, with: #""kind": "regex""#)

        XCTAssertThrowsError(try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8)))
    }

    func testIntentTriggerKindFails() {
        let json = validPayloadJSON.replacingOccurrences(of: #""kind": "always""#, with: #""kind": "intent""#)

        XCTAssertThrowsError(try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8)))
    }

    private var validPayloadJSON: String {
        """
        {
          "payloadVersion": 1,
          "name": "concrete-over-generic",
          "description": "Use concrete details",
          "source": "importedFromAnchor",
          "trigger": {
            "kind": "always",
            "modes": ["direction", "brainstorm"],
            "priority": 70
          },
          "action": {
            "kind": "promptFragment",
            "content": "Refer to specific files, function names, and real numbers."
          },
          "rationale": "Generic guidance is not useful enough.",
          "antiPatternExamples": ["You should improve the architecture."]
        }
        """
    }
}
