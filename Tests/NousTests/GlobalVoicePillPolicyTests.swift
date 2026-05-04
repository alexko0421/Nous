import XCTest
@testable import Nous

final class GlobalVoicePillPolicyTests: XCTestCase {
    func testSettingsDoesNotShowStartVoiceButton() {
        XCTAssertFalse(GlobalVoicePillPolicy.shouldShowStartButton(selectedTab: .settings))
    }

    func testNotesStillShowsStartVoiceButton() {
        XCTAssertTrue(GlobalVoicePillPolicy.shouldShowStartButton(selectedTab: .notes))
    }
}
