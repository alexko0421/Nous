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

/// Exponentially-smoothed peak-RMS audio level in 0...1.
struct VoiceAudioLevelSmoother {
    private(set) var value: Float = 0
    private let alpha: Float = 0.2  // 0.8 prev + 0.2 current

    mutating func ingest(rms: Float) {
        let clamped = max(0, min(1, rms))
        value = (1 - alpha) * value + alpha * clamped
    }

    static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        return (sumSq / Float(samples.count)).squareRoot()
    }
}

protocol VoiceAudioCapturing: AnyObject {
    func start(
        onAudio: @escaping @Sendable (String) -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) throws
    func stop()
}

final class VoiceAudioCapture: VoiceAudioCapturing {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    func start(
        onAudio: @escaping @Sendable (String) -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) throws {
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
        let smootherBox = SmootherBox()
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

            let rms = VoiceAudioLevelSmoother.rms(samples: samples)
            let smoothed = smootherBox.ingest(rms: rms)
            onAudioLevel(smoothed)
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

/// Thread-safe smoother holder for the audio tap closure (which is @Sendable).
private final class SmootherBox: @unchecked Sendable {
    private let lock = NSLock()
    private var smoother = VoiceAudioLevelSmoother()

    func ingest(rms: Float) -> Float {
        lock.lock()
        defer { lock.unlock() }
        smoother.ingest(rms: rms)
        return smoother.value
    }
}

protocol VoiceAudioPlaying: AnyObject {
    func start() throws
    func enqueue(base64PCM16Audio: String)
    func stop()
    /// Cancel all queued playback buffers immediately. Engine stays running
    /// so the next enqueue plays without re-warmup. Used for barge-in:
    /// when the server signals the user started speaking, any assistant
    /// audio still sitting in the player's queue must not keep playing.
    func flushPendingBuffers()
}

final class VoiceAudioPlayback: VoiceAudioPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var isConfigured = false

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        self.format = format
    }

    func start() throws {
        if !isConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isConfigured = true
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        if !player.isPlaying {
            player.play()
        }
    }

    func enqueue(base64PCM16Audio: String) {
        guard let data = Data(base64Encoded: base64PCM16Audio),
              let buffer = Self.makeBuffer(fromPCM16LEData: data, format: format) else {
            return
        }

        if !engine.isRunning {
            try? start()
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        guard isConfigured else { return }
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
    }

    func flushPendingBuffers() {
        guard isConfigured, engine.isRunning else { return }
        // player.stop() cancels everything queued. player.play() puts the
        // node back in a state where the next scheduleBuffer plays immediately.
        player.stop()
        player.play()
    }

    private static func makeBuffer(fromPCM16LEData data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let bytes = [UInt8](data.prefix(sampleCount * MemoryLayout<Int16>.size))
        for index in 0..<sampleCount {
            let low = UInt16(bytes[index * 2])
            let high = UInt16(bytes[index * 2 + 1]) << 8
            let sample = Int16(bitPattern: low | high)
            channel[index] = sample == .min ? -1 : Float(sample) / Float(Int16.max)
        }

        return buffer
    }
}
