import XCTest
@testable import Nous

final class SafetyGuardrailsTests: XCTestCase {

    func testHighRiskDetectionRecognizesCantoneseAndChinesePhrases() {
        XCTAssertTrue(SafetyGuardrails.isHighRiskQuery("我想自殺。"))
        XCTAssertTrue(SafetyGuardrails.isHighRiskQuery("我真係唔想活落去。"))
        XCTAssertTrue(SafetyGuardrails.isHighRiskQuery("最近有人對我家暴。"))
    }

    func testSensitiveMemoryDetectionRecognizesChinesePhrases() {
        XCTAssertTrue(SafetyGuardrails.containsSensitiveMemory("我最近有驚恐發作，同埋開始食藥。"))
        XCTAssertTrue(SafetyGuardrails.containsSensitiveMemory("我之前有創傷，仲未正式治療。"))
    }

    func testHardMemoryOptOutRecognizesCantoneseAndChinesePhrases() {
        XCTAssertTrue(SafetyGuardrails.containsHardMemoryOptOut("呢段唔好記住。"))
        XCTAssertTrue(SafetyGuardrails.containsHardMemoryOptOut("这个不要保存。"))
        XCTAssertTrue(SafetyGuardrails.containsHardMemoryOptOut("當冇講過。"))
    }

    func testConsentBoundaryRecognizesChinesePhrases() {
        XCTAssertTrue(SafetyGuardrails.requiresConsentForSensitiveMemory(
            boundaryLines: ["敏感內容先問再存。"]
        ))
        XCTAssertTrue(SafetyGuardrails.requiresConsentForSensitiveMemory(
            boundaryLines: ["關於敏感嘢要問過我先。"]
        ))
    }
}
