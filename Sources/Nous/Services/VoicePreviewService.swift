import AVFoundation
import Foundation

protocol VoicePreviewing {
    func preview(apiKey: String, voice: VoiceOutputVoice, language: VoiceLanguage) async throws
}

enum VoicePreviewError: Error {
    case missingAPIKey
    case invalidResponse
}

final class OpenAIVoicePreviewService: VoicePreviewing {
    private let session: URLSession
    private var player: AVAudioPlayer?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func preview(apiKey: String, voice: VoiceOutputVoice, language: VoiceLanguage) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw VoicePreviewError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts",
            "voice": voice.rawValue,
            "input": language.previewText,
            "instructions": language.previewInstructions,
            "response_format": "mp3"
        ], options: [.sortedKeys])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            throw VoicePreviewError.invalidResponse
        }

        try await MainActor.run {
            let player = try AVAudioPlayer(data: data)
            self.player = player
            player.prepareToPlay()
            player.play()
        }
    }
}
