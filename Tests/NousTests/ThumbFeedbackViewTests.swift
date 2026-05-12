import XCTest
import SwiftUI
@testable import Nous

final class ThumbFeedbackViewTests: XCTestCase {
    func testInitialVerdictIsUnset() {
        var verdict = ThumbVerdict.unset
        var note = ""
        var calls: [(ThumbVerdict, String)] = []
        _ = ThumbFeedbackView(
            verdict: Binding(get: { verdict }, set: { verdict = $0 }),
            note: Binding(get: { note }, set: { note = $0 }),
            style: .galaxy,
            telemetry: nil,
            onChange: { v, n in calls.append((v, n)) }
        )
        XCTAssertEqual(verdict, .unset)
        XCTAssertTrue(calls.isEmpty)
    }

    func testTelemetryStripPresenceMatchesStyle() {
        _ = ThumbFeedbackView(
            verdict: .constant(.unset),
            note: .constant(""),
            style: .galaxy,
            telemetry: TelemetryStrip(
                similarity: 0.78,
                judgePath: .llm,
                confidence: 0.82,
                judgedAt: Date(),
                priorVerdictCount: 1
            ),
            onChange: { _, _ in }
        )

        _ = ThumbFeedbackView(
            verdict: .constant(.unset),
            note: .constant(""),
            style: .chat,
            telemetry: nil,
            onChange: { _, _ in }
        )
    }

    func testStyleEnumValues() {
        XCTAssertNotEqual(ThumbFeedbackView.Style.galaxy, ThumbFeedbackView.Style.chat)
    }
}
