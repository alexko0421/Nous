import Foundation
import Observation

@Observable
@MainActor
final class YouTubeLearningViewModel {
    var urlText: String = ""
    var transcript: YouTubeTranscript?
    var summarySections: [YouTubeSummarySection] = []
    var errorMessage: String?
    var isLoading: Bool = false
    var selectedSectionID: UUID?

    private let transcriptService: YouTubeTranscriptService
    private let summaryService: YouTubeLearningSummaryService
    private let sourceIngestionService: SourceIngestionService
    private var sourceMaterial: SourceMaterialContext?
    private var sourceTitle: String?
    private var sourceURL: String?
    private var videoDuration: TimeInterval?
    private var playbackStartSeconds: Int?
    private var playbackRequestID = 0
    private var loadTask: Task<Void, Never>?

    init(
        transcriptService: YouTubeTranscriptService = YouTubeTranscriptService(),
        summaryService: YouTubeLearningSummaryService = YouTubeLearningSummaryService(),
        sourceIngestionService: SourceIngestionService
    ) {
        self.transcriptService = transcriptService
        self.summaryService = summaryService
        self.sourceIngestionService = sourceIngestionService
    }

    var isSummaryUnavailable: Bool {
        transcript != nil && summarySections.isEmpty
    }

    var currentEvidenceLevel: SourceEvidenceLevel? {
        sourceMaterial?.evidenceLevel
    }

    var currentEvidenceLabel: String? {
        currentEvidenceLevel?.label
    }

    var summaryUnavailableMessage: String? {
        isSummaryUnavailable ? "Transcript loaded. Summary is unavailable for this video." : nil
    }

    var selectedSummarySection: YouTubeSummarySection? {
        guard let selectedSectionID else { return nil }
        return summarySections.first { $0.id == selectedSectionID }
    }

    var displayedSummarySection: YouTubeSummarySection? {
        selectedSummarySection ?? summarySections.first
    }

    var summaryTimelineSegments: [YouTubeSummaryTimelineSegment] {
        let transcriptDuration = transcript?.segments.map(\.endTime).max() ?? 0
        let summaryDuration = summarySections.map(\.endTime).max() ?? 0
        let knownVideoDuration = videoDuration ?? 0
        let totalDuration = max(max(max(transcriptDuration, summaryDuration), knownVideoDuration), 1)

        return summarySections.enumerated().map { index, section in
            YouTubeSummaryTimelineSegment(
                section: section,
                totalDuration: totalDuration,
                colorIndex: index,
                isSelected: section.id == selectedSectionID
            )
        }
    }

    var videoID: YouTubeVideoID? {
        if let transcript {
            return transcript.videoID
        }
        return try? YouTubeVideoID(urlString: urlText)
    }

    var playerEmbed: YouTubePlayerEmbed? {
        if let videoID, let playbackStartSeconds {
            return YouTubePlayerEmbed(
                videoID: videoID,
                startSeconds: playbackStartSeconds,
                autoplay: true,
                playbackRequestID: playbackRequestID
            )
        }
        if let embed = try? YouTubePlayerEmbed(urlString: urlText) {
            return embed
        }
        if let transcript {
            return YouTubePlayerEmbed(videoID: transcript.videoID)
        }
        return nil
    }

    func load(projectId: UUID?) async {
        loadTask?.cancel()
        let task = Task {
            await performLoad(requestedURL: urlText.trimmingCharacters(in: .whitespacesAndNewlines), projectId: projectId)
        }
        loadTask = task
        await task.value
    }

    private func performLoad(requestedURL: String, projectId: UUID?) async {
        guard !requestedURL.isEmpty else {
            resetForFailure("Paste a YouTube URL first.")
            return
        }

        isLoading = true
        errorMessage = nil
        transcript = nil
        summarySections = []
        selectedSectionID = nil
        sourceMaterial = nil
        sourceTitle = nil
        sourceURL = nil
        videoDuration = nil
        playbackStartSeconds = nil
        playbackRequestID = 0
        defer { isLoading = false }

        do {
            let loadedTranscript = try await transcriptService.fetchTranscript(from: requestedURL)
            guard !Task.isCancelled else { return }
            let material = try sourceIngestionService.ingestExtractedSource(
                title: loadedTranscript.title,
                text: loadedTranscript.timestampedText,
                kind: .youtube,
                originalURL: loadedTranscript.sourceURL.absoluteString,
                originalFilename: nil,
                evidenceLevel: .transcriptBacked,
                projectId: projectId
            )
            let sections = try await summaryService.generateSections(for: loadedTranscript)
            guard !Task.isCancelled else { return }

            transcript = loadedTranscript
            sourceMaterial = material
            sourceTitle = loadedTranscript.title
            sourceURL = loadedTranscript.sourceURL.absoluteString
            videoDuration = loadedTranscript.duration
            summarySections = sections
        } catch {
            guard !Task.isCancelled else { return }
            await loadWithGeminiVideoAnalysis(
                requestedURL: requestedURL,
                projectId: projectId,
                captionError: error
            )
        }
    }

    func discussionContext(for section: YouTubeSummarySection) -> SourceDiscussionContext? {
        guard let sourceMaterial else {
            return nil
        }

        let excerpt: String
        if let transcript {
            excerpt = transcript.excerpt(
                startTime: section.startTime,
                endTime: section.endTime
            )
        } else {
            excerpt = Self.analysisExcerpt(for: section)
        }

        return SourceDiscussionContext(
            sourceNodeId: sourceMaterial.sourceNodeId,
            title: sourceTitle ?? sourceMaterial.title,
            sourceURL: sourceURL ?? sourceMaterial.originalURL,
            startTime: section.startTime,
            endTime: section.endTime,
            summaryTitle: section.title,
            summary: section.summary,
            transcriptExcerpt: excerpt,
            evidenceLevel: sourceMaterial.evidenceLevel
        )
    }

    func selectSectionForPlayback(_ section: YouTubeSummarySection) {
        selectedSectionID = section.id
        playbackStartSeconds = max(0, Int(section.startTime.rounded(.down)))
        playbackRequestID += 1
    }

    func discussionContextForSelectedSection() -> SourceDiscussionContext? {
        guard let selectedSummarySection else { return nil }
        return discussionContext(for: selectedSummarySection)
    }

    func selectSectionForDiscussionAndPlayback(_ section: YouTubeSummarySection) -> SourceDiscussionContext? {
        selectSectionForPlayback(section)
        return discussionContext(for: section)
    }

    private func loadWithGeminiVideoAnalysis(
        requestedURL: String,
        projectId: UUID?,
        captionError: Error
    ) async {
        do {
            let video = try await videoReferenceForFallback(requestedURL)
            let sections = try await summaryService.generateSections(for: video)
            let material = try sourceIngestionService.ingestExtractedSource(
                title: video.title,
                text: Self.analysisText(for: video, sections: sections),
                kind: .youtube,
                originalURL: video.sourceURL.absoluteString,
                originalFilename: nil,
                evidenceLevel: .geminiVideoAnalysis,
                projectId: projectId
            )

            transcript = nil
            sourceMaterial = material
            sourceTitle = video.title
            sourceURL = video.sourceURL.absoluteString
            videoDuration = video.duration ?? sections.map { $0.endTime }.max()
            summarySections = sections
            errorMessage = "Captions could not be read, so Gemini 2.5 Pro analyzed the video directly."
        } catch {
            resetForFailure(Self.fallbackFailureMessage(captionError: captionError, analysisError: error))
        }
    }

    private func videoReferenceForFallback(_ requestedURL: String) async throws -> YouTubeVideoReference {
        do {
            return try await transcriptService.fetchVideoReference(from: requestedURL)
        } catch let error as YouTubeVideoIDError {
            throw error
        } catch {
            return try YouTubeVideoReference(urlString: requestedURL)
        }
    }

    private func resetForFailure(_ message: String) {
        transcript = nil
        summarySections = []
        selectedSectionID = nil
        sourceMaterial = nil
        sourceTitle = nil
        sourceURL = nil
        videoDuration = nil
        playbackStartSeconds = nil
        playbackRequestID = 0
        errorMessage = message
    }

    private static func analysisText(
        for video: YouTubeVideoReference,
        sections: [YouTubeSummarySection]
    ) -> String {
        let sectionText = sections.map { section in
            """
            \(section.timeRangeLabel) \(section.title)
            \(section.summary)
            """
        }.joined(separator: "\n\n")

        return """
        YouTube video analysis
        URL: \(video.sourceURL.absoluteString)

        \(sectionText)
        """
    }

    private static func analysisExcerpt(for section: YouTubeSummarySection) -> String {
        """
        \(section.timeRangeLabel) \(section.title)
        \(section.summary)
        """
    }

    private static func fallbackFailureMessage(captionError: Error, analysisError: Error) -> String {
        if captionError is YouTubeVideoIDError {
            return captionError.localizedDescription
        }
        return "Captions could not be read. \(analysisError.localizedDescription)"
    }
}
