import XCTest
@testable import Nous

final class VoiceAudioLevelSmoothingTests: XCTestCase {
    func test_smoothingFactor_blends80PercentPrev20PercentCurrent() {
        var smoother = VoiceAudioLevelSmoother()
        XCTAssertEqual(smoother.value, 0, accuracy: 0.0001)
        smoother.ingest(rms: 0.5)
        // 0.8 * 0 + 0.2 * 0.5 = 0.1
        XCTAssertEqual(smoother.value, 0.1, accuracy: 0.0001)
        smoother.ingest(rms: 0.5)
        // 0.8 * 0.1 + 0.2 * 0.5 = 0.18
        XCTAssertEqual(smoother.value, 0.18, accuracy: 0.0001)
    }

    func test_clampsToZeroAndOne() {
        var smoother = VoiceAudioLevelSmoother()
        smoother.ingest(rms: -1.0)
        XCTAssertGreaterThanOrEqual(smoother.value, 0.0)
        smoother.ingest(rms: 5.0)
        XCTAssertLessThanOrEqual(smoother.value, 1.0)
    }

    func test_rmsOfFloatSamples_zeroForSilence() {
        let silence = [Float](repeating: 0, count: 480)
        XCTAssertEqual(VoiceAudioLevelSmoother.rms(samples: silence), 0, accuracy: 0.0001)
    }

    func test_rmsOfFloatSamples_nonzeroForTone() {
        let tone = (0..<480).map { i in sin(Float(i) * 0.1) * 0.5 }
        let rms = VoiceAudioLevelSmoother.rms(samples: tone)
        XCTAssertGreaterThan(rms, 0.1)
        XCTAssertLessThan(rms, 0.5)
    }
}
