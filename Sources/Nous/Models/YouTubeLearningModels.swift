import Foundation

enum YouTubeVideoIDError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedHost
    case missingVideoID
    case invalidVideoID

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That does not look like a YouTube URL."
        case .unsupportedHost:
            return "Only YouTube video URLs are supported."
        case .missingVideoID:
            return "The YouTube URL does not contain a video ID."
        case .invalidVideoID:
            return "The YouTube video ID is not valid."
        }
    }
}

struct YouTubeVideoID: Hashable, Codable {
    let rawValue: String

    init(rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw YouTubeVideoIDError.invalidVideoID }
        self.rawValue = rawValue
    }

    init(urlString: String) throws {
        guard let components = URLComponents(string: Self.normalizedURLString(urlString)),
              let host = components.host?.lowercased() else {
            throw YouTubeVideoIDError.invalidURL
        }

        let candidate: String?
        if host == "youtu.be" {
            candidate = components.path.split(separator: "/").first.map(String.init)
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let pathParts = components.path.split(separator: "/").map(String.init)
            if components.path == "/watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if ["shorts", "embed", "live"].contains(pathParts.first ?? "") {
                candidate = pathParts.dropFirst().first
            } else {
                candidate = nil
            }
        } else {
            throw YouTubeVideoIDError.unsupportedHost
        }

        guard let candidate, !candidate.isEmpty else { throw YouTubeVideoIDError.missingVideoID }
        try self.init(rawValue: candidate)
    }

    static func normalizedURLString(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+\-.]*://"#,
            options: .regularExpression
        ) != nil {
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }

        let lowercased = trimmed.lowercased()
        let hostLikePrefix = lowercased
            .split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" })
            .first
            .map(String.init)

        if let hostLikePrefix,
           hostLikePrefix == "youtu.be" ||
            hostLikePrefix == "youtube.com" ||
            hostLikePrefix.hasSuffix(".youtube.com") {
            return "https://\(trimmed)"
        }

        return trimmed
    }

    private static func isValid(_ value: String) -> Bool {
        guard value.count == 11 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

enum VoiceYouTubeURLResolver {
    static func resolve(
        explicitURL: String?,
        activeBrowserURL: String?,
        currentPanelURL: String?,
        clipboardText: String?
    ) -> String? {
        [explicitURL, activeBrowserURL, currentPanelURL, clipboardText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { candidate in
                guard !candidate.isEmpty else { return false }
                return (try? YouTubeVideoID(urlString: candidate)) != nil
            }
    }
}

enum VoiceYouTubeURLRequestResolver {
    static func resolve(
        explicitURL: String?,
        activeBrowserURL: () -> String?,
        currentPanelURL: String?,
        clipboardText: () -> String?
    ) -> String? {
        if let explicitURL = VoiceYouTubeURLResolver.resolve(
            explicitURL: explicitURL,
            activeBrowserURL: nil,
            currentPanelURL: nil,
            clipboardText: nil
        ) {
            return explicitURL
        }

        return VoiceYouTubeURLResolver.resolve(
            explicitURL: nil,
            activeBrowserURL: activeBrowserURL(),
            currentPanelURL: currentPanelURL,
            clipboardText: clipboardText()
        )
    }
}

struct YouTubePlayerEmbed: Equatable {
    static let embedOrigin = URL(string: "https://nous.local/")!

    let videoID: YouTubeVideoID
    let startSeconds: Int?
    let autoplay: Bool
    let playbackRequestID: Int

    init(
        videoID: YouTubeVideoID,
        startSeconds: Int? = nil,
        autoplay: Bool = false,
        playbackRequestID: Int = 0
    ) {
        self.videoID = videoID
        self.startSeconds = startSeconds
        self.autoplay = autoplay
        self.playbackRequestID = playbackRequestID
    }

    init(urlString: String) throws {
        let normalized = YouTubeVideoID.normalizedURLString(urlString)
        guard let components = URLComponents(string: normalized) else {
            throw YouTubeVideoIDError.invalidURL
        }
        videoID = try YouTubeVideoID(urlString: normalized)
        startSeconds = Self.startSeconds(from: components)
        autoplay = false
        playbackRequestID = 0
    }

    var embedURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/embed/\(videoID.rawValue)"

        var queryItems = [
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "origin", value: Self.embedOrigin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        ]
        if let startSeconds, startSeconds > 0 {
            queryItems.append(URLQueryItem(name: "start", value: String(startSeconds)))
        }
        if autoplay {
            queryItems.append(URLQueryItem(name: "autoplay", value: "1"))
        }
        components.queryItems = queryItems
        return components.url ?? URL(string: "about:blank")!
    }

    var cacheKey: String {
        "\(embedURL.absoluteString)#playback=\(playbackRequestID)"
    }

    var html: String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="strict-origin-when-cross-origin">
          <style>
            html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #222; }
            iframe { border: 0; width: 100%; height: 100%; display: block; }
          </style>
        </head>
        <body>
          <iframe
            src="\(embedURL.absoluteString)"
            title="YouTube video player"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            referrerpolicy="strict-origin-when-cross-origin"
            allowfullscreen>
          </iframe>
        </body>
        </html>
        """
    }

    private static func startSeconds(from components: URLComponents) -> Int? {
        let rawValue = components.queryItems?
            .first { $0.name == "t" || $0.name == "start" }?
            .value
        return rawValue.flatMap(parseTimestamp)
    }

    private static func parseTimestamp(_ rawValue: String) -> Int? {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let seconds = Int(trimmed) {
            return max(0, seconds)
        }

        let pattern = #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
              ),
              match.range.location != NSNotFound else {
            return nil
        }

        var total = 0
        var hasComponent = false
        let multipliers = [3600, 60, 1]
        for index in 1...3 {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let valueRange = Range(range, in: trimmed),
                  let value = Int(trimmed[valueRange]) else {
                continue
            }
            hasComponent = true
            total += value * multipliers[index - 1]
        }
        return hasComponent ? total : nil
    }
}

struct YouTubeVideoReference: Equatable {
    let videoID: YouTubeVideoID
    let sourceURL: URL
    let originalURL: String
    let startSeconds: Int?
    let duration: TimeInterval?
    let title: String

    init(
        urlString: String,
        title: String? = nil,
        duration: TimeInterval? = nil
    ) throws {
        let normalized = YouTubeVideoID.normalizedURLString(urlString)
        let embed = try YouTubePlayerEmbed(urlString: normalized)
        videoID = embed.videoID
        sourceURL = Self.canonicalWatchURL(for: embed.videoID)
        originalURL = normalized
        startSeconds = embed.startSeconds
        self.duration = duration.flatMap { $0 > 0 ? $0 : nil }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = trimmedTitle.isEmpty ? "YouTube Video" : trimmedTitle
    }

    static func canonicalWatchURL(for videoID: YouTubeVideoID) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID.rawValue)")!
    }
}

struct YouTubeTranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let duration: TimeInterval
    let text: String

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        duration: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.text = text
    }

    var endTime: TimeInterval {
        startTime + duration
    }

    var timestampedText: String {
        "\(Self.timestamp(startTime)) \(text)"
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let seconds = wholeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct YouTubeTranscript: Codable, Equatable {
    let videoID: YouTubeVideoID
    let title: String
    let sourceURL: URL
    let segments: [YouTubeTranscriptSegment]

    var timestampedText: String {
        segments.map(\.timestampedText).joined(separator: "\n")
    }

    var duration: TimeInterval? {
        let endTime = segments.map(\.endTime).max() ?? 0
        return endTime > 0 ? endTime : nil
    }

    func excerpt(startTime: TimeInterval, endTime: TimeInterval, maxCharacters: Int = 4_000) -> String {
        let selected = segments.filter { segment in
            segment.endTime > startTime && segment.startTime < endTime
        }
        let text = selected.map(\.timestampedText).joined(separator: "\n")
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct YouTubeSummarySection: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let summary: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.startTime = startTime
        self.endTime = endTime
    }

    var timeRangeLabel: String {
        "\(YouTubeTranscriptSegment.timestamp(startTime))-\(YouTubeTranscriptSegment.timestamp(endTime))"
    }
}

struct YouTubeSummaryTimelineSegment: Identifiable, Equatable {
    let id: UUID
    let section: YouTubeSummarySection
    let startFraction: Double
    let widthFraction: Double
    let colorIndex: Int
    let isSelected: Bool

    init(
        section: YouTubeSummarySection,
        totalDuration: TimeInterval,
        colorIndex: Int,
        isSelected: Bool
    ) {
        id = section.id
        self.section = section
        self.colorIndex = colorIndex
        self.isSelected = isSelected

        let safeDuration = max(totalDuration, 1)
        let start = max(0, section.startTime)
        let end = max(start, section.endTime)
        let unclampedStart = start / safeDuration
        startFraction = min(1, max(0, unclampedStart))
        widthFraction = min(1 - startFraction, max(0.025, (end - start) / safeDuration))
    }
}

struct SourceReaderPreview: Codable, Equatable {
    let title: String
    let subtitle: String
    let body: String
}

struct YouTubeLearningPanelState: Codable, Equatable {
    var urlText: String
    var transcript: YouTubeTranscript?
    var summarySections: [YouTubeSummarySection]
    var selectedSectionID: UUID?
    var sourceMaterial: SourceMaterialContext?
    var sourceTitle: String?
    var sourceURL: String?
    var videoDuration: TimeInterval?
    var errorMessage: String?

    static let empty = YouTubeLearningPanelState(
        urlText: "",
        transcript: nil,
        summarySections: [],
        selectedSectionID: nil,
        sourceMaterial: nil,
        sourceTitle: nil,
        sourceURL: nil,
        videoDuration: nil,
        errorMessage: nil
    )

    var shouldPersist: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            transcript != nil ||
            !summarySections.isEmpty ||
            sourceMaterial != nil ||
            errorMessage != nil
    }
}

struct SourceDiscussionContext: Equatable {
    let sourceNodeId: UUID
    let title: String
    let sourceURL: String?
    let originalFilename: String?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let locatorLabel: String?
    let summaryTitle: String
    let summary: String
    let transcriptExcerpt: String
    let summaryMap: SourceSummaryMap?
    let evidenceLevel: SourceEvidenceLevel
    let sourceLabel: String

    init(
        sourceNodeId: UUID,
        title: String,
        sourceURL: String?,
        originalFilename: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        locatorLabel: String? = nil,
        summaryTitle: String,
        summary: String,
        transcriptExcerpt: String,
        summaryMap: SourceSummaryMap? = nil,
        evidenceLevel: SourceEvidenceLevel = .unknown,
        sourceLabel: String = "YouTube section"
    ) {
        self.sourceNodeId = sourceNodeId
        self.title = title
        self.sourceURL = sourceURL
        self.originalFilename = originalFilename
        self.startTime = startTime
        self.endTime = endTime
        self.locatorLabel = locatorLabel
        self.summaryTitle = summaryTitle
        self.summary = summary
        self.transcriptExcerpt = transcriptExcerpt
        self.summaryMap = summaryMap
        self.evidenceLevel = evidenceLevel
        self.sourceLabel = sourceLabel
    }

    var timeRangeLabel: String {
        if let locatorLabel, !locatorLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return locatorLabel
        }
        return "\(YouTubeTranscriptSegment.timestamp(startTime))-\(YouTubeTranscriptSegment.timestamp(endTime))"
    }

    var evidenceLabel: String {
        evidenceLevel.label
    }

    var isQuoteLevelReliable: Bool {
        evidenceLevel.isQuoteLevelReliable
    }

    var previewLine: String {
        let candidates = [summary, transcriptExcerpt]
        for candidate in candidates {
            let line = candidate
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            if !line.isEmpty { return line }
        }
        return title
    }

    var promptText: String {
        """
        \(sourceLabel): \(summaryTitle) (\(timeRangeLabel))
        Evidence: \(evidenceLabel)
        Summary: \(summary)

        \(excerptHeading):
        \(transcriptExcerpt)
        """
    }

    private var excerptHeading: String {
        if sourceLabel == "YouTube section" {
            return isQuoteLevelReliable ? "Transcript excerpt" : "Analysis excerpt"
        }
        return "Source excerpt"
    }

    func sourceMaterialContext() -> SourceMaterialContext {
        return SourceMaterialContext(
            sourceNodeId: sourceNodeId,
            title: title,
            originalURL: sourceURL,
            originalFilename: originalFilename,
            chunks: [
                SourceChunkContext(
                    sourceNodeId: sourceNodeId,
                    ordinal: 0,
                    text: promptText,
                    similarity: nil
                )
            ],
            summaryMap: summaryMap,
            evidenceLevel: evidenceLevel
        )
    }
}
