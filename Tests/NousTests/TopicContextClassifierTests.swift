import XCTest
@testable import Nous

final class TopicContextClassifierTests: XCTestCase {
    func testClassifiesObviousEducationText() {
        let classifier = TopicContextClassifier()

        let result = classifier.classify(
            text: "SMC class registration and F-1 visa status means I need a cleaner study plan."
        )

        XCTAssertEqual(result.primaryLane, .education)
        XCTAssertEqual(result.source, .deterministic)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.7)
        XCTAssertTrue(result.subtopicLabel.localizedCaseInsensitiveContains("school"))
    }

    func testClassifiesNousProductAndAIResearchAsPrimaryAndSecondary() {
        let classifier = TopicContextClassifier()

        let result = classifier.classify(
            text: "Nous should use agent operator research to improve memory and source recall."
        )

        XCTAssertEqual(result.primaryLane, .nousProduct)
        XCTAssertTrue(result.secondaryLanes.contains(.aiResearch))
        XCTAssertFalse(TopicContextLane.allCases.contains { lane in
            lane.rawValue.localizedCaseInsensitiveContains("galaxy")
        })
    }

    func testGenericSchoolProjectAppTextDoesNotClassifyAsNousProduct() {
        let classifier = TopicContextClassifier()

        let result = classifier.classify(
            text: "My school project needs a simple app UI for class."
        )

        XCTAssertEqual(result.primaryLane, .education)
    }

    func testFallsBackToGeneralForUnclearText() {
        let classifier = TopicContextClassifier()

        let result = classifier.classify(text: "okay yeah let's keep going")

        XCTAssertEqual(result.primaryLane, .general)
        XCTAssertEqual(result.secondaryLanes, [])
        XCTAssertLessThanOrEqual(result.confidence, 0.4)
    }
}
