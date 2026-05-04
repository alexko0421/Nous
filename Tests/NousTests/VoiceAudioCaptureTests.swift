import XCTest
@testable import Nous

final class VoiceAudioCaptureTests: XCTestCase {
    func testPCM16DataClampsAndEncodesLittleEndianSamples() {
        let data = VoiceAudioEncoder.pcm16Data(fromMonoFloatSamples: [-2.0, -1.0, 0.0, 1.0, 2.0])
        let bytes = [UInt8](data)

        XCTAssertEqual(bytes, [
            0x00, 0x80,
            0x00, 0x80,
            0x00, 0x00,
            0xFF, 0x7F,
            0xFF, 0x7F
        ])
    }

    func testBase64PCM16ReturnsNonEmptyStringForNonEmptySamples() {
        let base64 = VoiceAudioEncoder.base64PCM16(fromMonoFloatSamples: [0.0, 0.5, -0.5])

        XCTAssertFalse(base64.isEmpty)
    }
}
