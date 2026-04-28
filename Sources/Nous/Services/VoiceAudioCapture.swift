import AVFoundation
import Foundation

enum VoiceAudioEncoder {
    static func pcm16Data(fromMonoFloatSamples samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clamped = min(max(sample, -1.0), 1.0)
            let encoded: Int16
            if clamped <= -1.0 {
                encoded = .min
            } else if clamped >= 1.0 {
                encoded = .max
            } else {
                encoded = Int16(clamped * Float(Int16.max))
            }

            var littleEndian = encoded.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data
    }

    static func base64PCM16(fromMonoFloatSamples samples: [Float]) -> String {
        pcm16Data(fromMonoFloatSamples: samples).base64EncodedString()
    }
}

protocol VoiceAudioCapturing: AnyObject {
    func start(onAudio: @escaping @Sendable (String) -> Void) throws
    func stop()
}

final class VoiceAudioCapture: VoiceAudioCapturing {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    func start(onAudio: @escaping @Sendable (String) -> Void) throws {
        stop()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceAudioCaptureError.cannotCreateConverter
        }

        self.converter = converter
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            let frameCapacity = AVAudioFrameCount(
                max(1, ceil(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate))
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
                return
            }

            var didProvideInput = false
            var conversionError: NSError?
            converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
                if didProvideInput {
                    status.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                status.pointee = .haveData
                return buffer
            }

            guard conversionError == nil,
                  convertedBuffer.frameLength > 0,
                  let channel = convertedBuffer.floatChannelData?[0] else {
                return
            }

            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(convertedBuffer.frameLength)))
            let chunk = VoiceAudioEncoder.base64PCM16(fromMonoFloatSamples: samples)
            if !chunk.isEmpty {
                onAudio(chunk)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        converter = nil
    }
}

enum VoiceAudioCaptureError: Error {
    case cannotCreateConverter
}
