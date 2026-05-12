import Foundation

protocol YouTubeVideoAnalysisGenerating {
    func generateSections(for video: YouTubeVideoReference) async throws -> [YouTubeSummarySection]
}

enum YouTubeLearningSummaryError: LocalizedError, Equatable {
    case geminiVideoAnalysisUnavailable
    case geminiVideoAnalysisEmpty

    var errorDescription: String? {
        switch self {
        case .geminiVideoAnalysisUnavailable:
            return "Add a Gemini API key to analyze videos when captions are unavailable."
        case .geminiVideoAnalysisEmpty:
            return "Gemini could not produce section summaries for this video."
        }
    }
}

enum GeminiVideoAnalysisError: LocalizedError, Equatable {
    case httpError(statusCode: Int, message: String?)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .httpError(statusCode, message):
            if let message, !message.isEmpty {
                return "Gemini video analysis failed (\(statusCode)): \(message)"
            }
            return "Gemini video analysis failed with HTTP \(statusCode)."
        case let .timedOut(seconds):
            let minutes = max(1, Int((seconds / 60).rounded(.up)))
            return "Gemini video analysis timed out after \(minutes) minutes. Try again, or use a shorter video."
        }
    }
}

struct YouTubeLearningSummaryService {
    private let llmServiceProvider: () -> (any LLMService)?
    private let videoAnalysisServiceProvider: () -> (any YouTubeVideoAnalysisGenerating)?

    init(
        llmServiceProvider: @escaping () -> (any LLMService)? = { nil },
        videoAnalysisServiceProvider: @escaping () -> (any YouTubeVideoAnalysisGenerating)? = { nil }
    ) {
        self.llmServiceProvider = llmServiceProvider
        self.videoAnalysisServiceProvider = videoAnalysisServiceProvider
    }

    init(llmServiceProvider: @escaping () -> (any LLMService)?) {
        self.init(
            llmServiceProvider: llmServiceProvider,
            videoAnalysisServiceProvider: { nil }
        )
    }

    init(videoAnalysisServiceProvider: @escaping () -> (any YouTubeVideoAnalysisGenerating)?) {
        self.init(
            llmServiceProvider: { nil },
            videoAnalysisServiceProvider: videoAnalysisServiceProvider
        )
    }

    func generateSections(for transcript: YouTubeTranscript) async throws -> [YouTubeSummarySection] {
        guard let llm = llmServiceProvider() else { return [] }
        let prompt = Self.prompt(for: transcript)
        let stream = try await llm.generate(
            messages: [LLMMessage(role: "user", content: prompt)],
            system: nil
        )
        var output = ""
        for try await chunk in stream {
            output += chunk
        }
        return Self.parseSections(from: output, duration: transcript.duration)
    }

    func generateSections(for video: YouTubeVideoReference) async throws -> [YouTubeSummarySection] {
        guard let analyzer = videoAnalysisServiceProvider() else {
            throw YouTubeLearningSummaryError.geminiVideoAnalysisUnavailable
        }
        let sections = Self.sanitizeSections(
            try await analyzer.generateSections(for: video),
            duration: video.duration
        )
        guard !sections.isEmpty else {
            throw YouTubeLearningSummaryError.geminiVideoAnalysisEmpty
        }
        return sections
    }

    static func parseSections(from output: String, duration: TimeInterval? = nil) -> [YouTubeSummarySection] {
        let jsonText = extractJSONArray(from: output)
        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SectionPayload].self, from: data) else {
            return []
        }

        let sections: [YouTubeSummarySection] = decoded.compactMap { payload in
            let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  !summary.isEmpty,
                  payload.startTime.isFinite,
                  payload.endTime.isFinite,
                  payload.endTime > payload.startTime else {
                return nil
            }
            return YouTubeSummarySection(
                title: title,
                summary: summary,
                startTime: payload.startTime,
                endTime: payload.endTime
            )
        }
        return sanitizeSections(sections, duration: duration)
    }

    private static func prompt(for transcript: YouTubeTranscript) -> String {
        let durationRule: String
        let sectionCountRule: String
        if let duration = transcript.duration {
            let seconds = Int(duration.rounded(.down))
            durationRule = "- Actual transcript spans \(seconds) seconds (\(YouTubeTranscriptSegment.timestamp(duration))). Every endTime must be <= \(seconds)."
            // ~1 section per 4–6 minutes so Alex can click any moment with
            // useful resolution. Earlier "5 to 10" produced 13-minute mega
            // sections on long videos that mashed three topics together.
            let lowerBound = max(3, Int((duration / 360).rounded(.up)))
            let upperBound = max(lowerBound + 1, Int((duration / 240).rounded(.up)))
            sectionCountRule = "- Aim for \(lowerBound)–\(upperBound) sections (roughly one section per 4–6 minutes). Do not collapse multiple distinct topics into one mega-section."
        } else {
            durationRule = "- startTime and endTime are seconds from the beginning of the video."
            sectionCountRule = "- Aim for one section per 4–6 minutes of content. Do not collapse multiple distinct topics into one mega-section."
        }

        // 200k chars ≈ 50k tokens — comfortably within Sonnet 4.6's window and
        // covers a ~3hr ASR transcript. The previous 16k cap silently dropped
        // everything past the first ~10–15 minutes on long videos.
        let transcriptText = String(transcript.timestampedText.prefix(200_000))

        return """
        Segment this YouTube transcript into concise learning sections that cover the entire video.
        Return only a JSON array. Each item must have:
        title, summary, startTime, endTime.

        Rules:
        \(durationRule)
        - startTime and endTime must be JSON numbers (seconds), not strings like "mm:ss".
        - Sections must collectively cover the full timeline with no gaps: the first section starts at 0 and each subsequent section's startTime equals the previous section's endTime.
        - Choose section boundaries at meaningful topic changes; ground each timestamp in the transcript timestamps below.
        \(sectionCountRule)
        - Each summary must include 1–2 specific facts actually said in the segment — names mentioned, numbers, claims made, decisions voiced, anecdotes told. Never write a thematic paraphrase like "they discuss college plans"; instead "Kai shares she signed with University of Miami for golf, plans a double major in management and marketing".
        - When a single phrase or moment crystallizes the section, quote it inline (e.g. 'she calls it "the worst part of school"').
        - Section titles should name the concrete topic, not a vague genre. Prefer "Kai's first DM to Logan in 2020" over "Personal anecdotes".
        - Do not include markdown or commentary outside the JSON.

        Video: \(transcript.title)

        Transcript:
        \(transcriptText)
        """
    }

    static func videoPrompt(for video: YouTubeVideoReference) -> String {
        let durationRule: String
        if let duration = video.duration {
            let seconds = Int(duration.rounded(.down))
            durationRule = "- Actual video duration is \(seconds) seconds (\(YouTubeTranscriptSegment.timestamp(duration))). Every endTime must be <= \(seconds)."
        } else {
            durationRule = "- startTime and endTime are seconds from the beginning of the video."
        }

        return """
        Analyze this YouTube video as a learning source.
        Break it into concise timestamped sections that capture what each part is about.
        Return only a JSON array. Each item must have:
        title, summary, startTime, endTime.

        Rules:
        \(durationRule)
        - startTime and endTime must be JSON numbers (seconds), not strings like "mm:ss".
        - Sections must collectively cover the full timeline with no gaps: the first section starts at 0 and each subsequent section's startTime equals the previous section's endTime.
        - Choose section boundaries at meaningful topic changes; double-check each timestamp against what is actually happening on-screen before finalising.
        - Make each summary concrete enough that Alex can click it and discuss that section.
        - Prefer 5 to 10 sections for long videos.
        - Do not include markdown or commentary outside the JSON.

        Video: \(video.title)
        URL: \(video.sourceURL.absoluteString)
        """
    }

    static func sanitizeSections(
        _ sections: [YouTubeSummarySection],
        duration: TimeInterval?
    ) -> [YouTubeSummarySection] {
        sections.compactMap { section in
            guard section.startTime.isFinite,
                  section.endTime.isFinite,
                  section.endTime > section.startTime else {
                return nil
            }

            let startTime = max(0, section.startTime)
            var endTime = max(startTime, section.endTime)
            if let duration, duration > 0 {
                guard startTime < duration else { return nil }
                endTime = min(endTime, duration)
            }
            guard endTime > startTime else { return nil }

            return YouTubeSummarySection(
                id: section.id,
                title: section.title,
                summary: section.summary,
                startTime: startTime,
                endTime: endTime
            )
        }
    }

    private static func extractJSONArray(from output: String) -> String {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start <= end else {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(output[start...end])
    }

    private struct SectionPayload: Decodable {
        let title: String
        let summary: String
        let startTime: TimeInterval
        let endTime: TimeInterval

        enum CodingKeys: String, CodingKey {
            case title, summary, startTime, endTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            summary = try container.decode(String.self, forKey: .summary)
            startTime = try Self.decodeTimestamp(container: container, key: .startTime)
            endTime = try Self.decodeTimestamp(container: container, key: .endTime)
        }

        private static func decodeTimestamp(
            container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws -> TimeInterval {
            // Gemini occasionally ignores the "numbers only" rule and returns
            // "mm:ss" / "hh:mm:ss" strings. Accept both forms.
            if let number = try? container.decode(TimeInterval.self, forKey: key) {
                return number
            }
            let raw = try container.decode(String.self, forKey: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let direct = TimeInterval(raw) { return direct }
            let parts = raw.split(separator: ":").map(String.init)
            guard !parts.isEmpty, parts.count <= 3,
                  let numbers = parts.map(TimeInterval.init) as [TimeInterval?]?,
                  !numbers.contains(nil) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Timestamp \(raw) is not a number or h:m:s string"
                )
            }
            let unwrapped = numbers.compactMap { $0 }
            let multipliers: [TimeInterval] = [1, 60, 3600]
            return zip(unwrapped.reversed(), multipliers)
                .map { $0.0 * $0.1 }
                .reduce(0, +)
        }
    }
}

protocol GeminiVideoAnalysisHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GeminiVideoAnalysisHTTPClient {}

struct GeminiYouTubeVideoAnalysisService: YouTubeVideoAnalysisGenerating {
    static let defaultModel = "gemini-2.5-pro"
    static let defaultTimeoutInterval: TimeInterval = 300

    let apiKey: String
    var model: String
    var timeoutInterval: TimeInterval
    private let httpClient: any GeminiVideoAnalysisHTTPClient

    init(
        apiKey: String,
        model: String = Self.defaultModel,
        timeoutInterval: TimeInterval = Self.defaultTimeoutInterval,
        httpClient: any GeminiVideoAnalysisHTTPClient = URLSession.shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutInterval = timeoutInterval
        self.httpClient = httpClient
    }

    func generateSections(for video: YouTubeVideoReference) async throws -> [YouTubeSummarySection] {
        let request = try makeURLRequest(for: video)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw GeminiVideoAnalysisError.timedOut(seconds: request.timeoutInterval)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GeminiVideoAnalysisError.httpError(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        let output = try Self.extractText(from: data)
        let sections = YouTubeLearningSummaryService.parseSections(from: output)
        guard !sections.isEmpty else {
            throw YouTubeLearningSummaryError.geminiVideoAnalysisEmpty
        }
        return sections
    }

    func makeURLRequest(for video: YouTubeVideoReference) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw YouTubeLearningSummaryError.geminiVideoAnalysisEmpty
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(for: video))
        return request
    }

    private static func requestBody(for video: YouTubeVideoReference) -> [String: Any] {
        [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "file_data": [
                                "file_uri": video.sourceURL.absoluteString
                            ]
                        ],
                        ["text": YouTubeLearningSummaryService.videoPrompt(for: video)]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0,
                "seed": 42,
                "maxOutputTokens": 16384,
                "responseMimeType": "application/json",
                "mediaResolution": "MEDIA_RESOLUTION_LOW",
                // Gemini 2.5 Pro is thinking-only (Budget 0 is rejected).
                "thinkingConfig": ["thinkingBudget": 1024]
            ]
        ]
    }

    private static func errorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.invalidResponse
        }
        return text
    }
}
