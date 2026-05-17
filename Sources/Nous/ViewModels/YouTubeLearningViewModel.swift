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
    private let nodeStore: NodeStore?
    private var sourceMaterial: SourceMaterialContext?
    private var sourceTitle: String?
    private var sourceURL: String?
    private var videoDuration: TimeInterval?
    private var playbackStartSeconds: Int?
    private var playbackRequestID = 0
    private var loadTask: Task<Void, Never>?
    private var activeConversationId: UUID?
    private var loadedStates: [UUID: YouTubeLearningPanelState] = [:]

    init(
        transcriptService: YouTubeTranscriptService = YouTubeTranscriptService(),
        summaryService: YouTubeLearningSummaryService = YouTubeLearningSummaryService(),
        sourceIngestionService: SourceIngestionService,
        nodeStore: NodeStore? = nil
    ) {
        self.transcriptService = transcriptService
        self.summaryService = summaryService
        self.sourceIngestionService = sourceIngestionService
        self.nodeStore = nodeStore
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

    var sourceDisplayTitle: String {
        let title = sourceTitle ?? sourceMaterial?.title ?? "URL"
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "URL" : trimmed
    }

    var sourcePreview: SourceReaderPreview? {
        guard let sourceMaterial,
              playerEmbed == nil else {
            return nil
        }
        return SourceReaderPreview(
            title: sourceDisplayTitle,
            subtitle: Self.previewSubtitle(for: sourceMaterial, fallbackURL: sourceURL),
            body: Self.previewBody(for: sourceMaterial)
        )
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
        let targetConversationId = activeConversationId
        let task = Task {
            await performLoad(
                requestedURL: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                projectId: projectId,
                conversationId: targetConversationId
            )
        }
        loadTask = task
        await task.value
    }

    func activate(conversationId: UUID?) {
        if let previousId = activeConversationId {
            persist(state: currentPanelState, for: previousId)
            loadedStates[previousId] = currentPanelState
        }

        activeConversationId = conversationId

        guard let conversationId else {
            apply(state: .empty)
            return
        }

        let state = loadedStates[conversationId] ?? loadState(conversationId: conversationId)
        loadedStates[conversationId] = state
        apply(state: state)
    }

    func loadDocumentAttachments(_ attachments: [AttachedFileContext], projectId: UUID?) {
        let targetConversationId = activeConversationId
        if targetConversationId == activeConversationId {
            isLoading = false
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
        }

        do {
            let materials = try sourceIngestionService.ingestDocumentAttachments(
                attachments,
                projectId: projectId
            )
            guard let material = materials.first else {
                storeFailure(
                    requestedURL: "",
                    message: "That document could not be read yet.",
                    conversationId: targetConversationId
                )
                return
            }

            let displayName = material.originalFilename ?? material.title
            let state = YouTubeLearningPanelState(
                urlText: displayName,
                transcript: nil,
                summarySections: Self.sections(for: material),
                selectedSectionID: nil,
                sourceMaterial: material,
                sourceTitle: material.title,
                sourceURL: material.originalURL,
                videoDuration: nil,
                errorMessage: nil
            )
            store(state: state, for: targetConversationId)
        } catch {
            storeFailure(
                requestedURL: "",
                message: "That document could not be read yet.",
                conversationId: targetConversationId
            )
        }
    }

    private func performLoad(requestedURL: String, projectId: UUID?, conversationId: UUID?) async {
        guard !requestedURL.isEmpty else {
            storeFailure(
                requestedURL: requestedURL,
                message: "Paste a URL or document first.",
                conversationId: conversationId
            )
            return
        }

        if conversationId == activeConversationId {
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
        }

        guard Self.looksLikeYouTubeURL(requestedURL) else {
            await loadURLSource(
                requestedURL: requestedURL,
                projectId: projectId,
                conversationId: conversationId
            )
            return
        }

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

            let state = YouTubeLearningPanelState(
                urlText: requestedURL,
                transcript: loadedTranscript,
                summarySections: sections,
                selectedSectionID: nil,
                sourceMaterial: material,
                sourceTitle: loadedTranscript.title,
                sourceURL: loadedTranscript.sourceURL.absoluteString,
                videoDuration: loadedTranscript.duration,
                errorMessage: nil
            )
            store(state: state, for: conversationId)
        } catch {
            guard !Task.isCancelled else { return }
            await loadWithGeminiVideoAnalysis(
                requestedURL: requestedURL,
                projectId: projectId,
                conversationId: conversationId,
                captionError: error
            )
        }
    }

    private func loadURLSource(requestedURL: String, projectId: UUID?, conversationId: UUID?) async {
        guard let url = Self.normalizedSourceURL(from: requestedURL),
              SourceURLSafety.allowsNetworkFetch(url) else {
            storeFailure(
                requestedURL: requestedURL,
                message: "Paste a readable public URL or document source.",
                conversationId: conversationId
            )
            return
        }

        do {
            let materials = try await sourceIngestionService.ingestURLs([url], projectId: projectId)
            guard !Task.isCancelled else { return }
            guard let material = materials.first else {
                storeFailure(
                    requestedURL: requestedURL,
                    message: "That source could not be read yet.",
                    conversationId: conversationId
                )
                return
            }

            let state = YouTubeLearningPanelState(
                urlText: requestedURL,
                transcript: nil,
                summarySections: Self.sections(for: material),
                selectedSectionID: nil,
                sourceMaterial: material,
                sourceTitle: material.title,
                sourceURL: material.originalURL ?? url.absoluteString,
                videoDuration: nil,
                errorMessage: nil
            )
            store(state: state, for: conversationId)
        } catch is CancellationError {
            return
        } catch {
            storeFailure(
                requestedURL: requestedURL,
                message: "That source could not be read yet.",
                conversationId: conversationId
            )
        }
    }

    func discussionContext(for section: YouTubeSummarySection) -> SourceDiscussionContext? {
        guard let sourceMaterial else {
            return nil
        }

        let isVideoSource = Self.isVideoMaterial(sourceMaterial, sourceURL: sourceURL ?? urlText)
        let mappedSection = sourceSummaryMapSection(matching: section)
        let excerpt: String
        if let transcript {
            excerpt = transcript.excerpt(
                startTime: section.startTime,
                endTime: section.endTime
            )
        } else if isVideoSource {
            excerpt = Self.analysisExcerpt(for: section)
        } else {
            excerpt = mappedSection?.evidenceExcerpt ?? Self.sourceExcerpt(for: section, material: sourceMaterial)
        }

        return SourceDiscussionContext(
            sourceNodeId: sourceMaterial.sourceNodeId,
            title: sourceTitle ?? sourceMaterial.title,
            sourceURL: sourceURL ?? sourceMaterial.originalURL,
            originalFilename: sourceMaterial.originalFilename,
            startTime: section.startTime,
            endTime: section.endTime,
            locatorLabel: isVideoSource ? nil : mappedSection?.locatorLabel,
            summaryTitle: section.title,
            summary: section.summary,
            transcriptExcerpt: excerpt,
            summaryMap: sourceMaterial.summaryMap ?? Self.summaryMap(
                for: summarySections,
                transcript: transcript,
                evidenceLevel: sourceMaterial.evidenceLevel
            ),
            evidenceLevel: sourceMaterial.evidenceLevel,
            sourceLabel: isVideoSource ? "YouTube section" : "Source section"
        )
    }

    func selectSectionForPlayback(_ section: YouTubeSummarySection) {
        selectedSectionID = section.id
        if Self.isVideoMaterial(sourceMaterial, sourceURL: sourceURL ?? urlText) {
            playbackStartSeconds = max(0, Int(section.startTime.rounded(.down)))
            playbackRequestID += 1
        }
        persistActiveState()
    }

    func discussionContextForSelectedSection() -> SourceDiscussionContext? {
        guard let selectedSummarySection else { return nil }
        return discussionContext(for: selectedSummarySection)
    }

    func selectSectionForDiscussionAndPlayback(_ section: YouTubeSummarySection) -> SourceDiscussionContext? {
        selectSectionForPlayback(section)
        return discussionContext(for: section)
    }

    private func sourceSummaryMapSection(matching section: YouTubeSummarySection) -> SourceSummaryMapSection? {
        sourceMaterial?.summaryMap?.sections.first { mappedSection in
            mappedSection.title == section.title && mappedSection.summary == section.summary
        }
    }

    private func loadWithGeminiVideoAnalysis(
        requestedURL: String,
        projectId: UUID?,
        conversationId: UUID?,
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

            let state = YouTubeLearningPanelState(
                urlText: requestedURL,
                transcript: nil,
                summarySections: sections,
                selectedSectionID: nil,
                sourceMaterial: material,
                sourceTitle: video.title,
                sourceURL: video.sourceURL.absoluteString,
                videoDuration: video.duration ?? sections.map { $0.endTime }.max(),
                errorMessage: "Captions could not be read, so Gemini 2.5 Pro analyzed the video directly."
            )
            store(state: state, for: conversationId)
        } catch {
            storeFailure(
                requestedURL: requestedURL,
                message: Self.fallbackFailureMessage(captionError: captionError, analysisError: error),
                conversationId: conversationId
            )
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

    private func storeFailure(requestedURL: String, message: String, conversationId: UUID?) {
        store(
            state: YouTubeLearningPanelState(
                urlText: requestedURL,
                transcript: nil,
                summarySections: [],
                selectedSectionID: nil,
                sourceMaterial: nil,
                sourceTitle: nil,
                sourceURL: nil,
                videoDuration: nil,
                errorMessage: message
            ),
            for: conversationId
        )
    }

    private var currentPanelState: YouTubeLearningPanelState {
        YouTubeLearningPanelState(
            urlText: urlText,
            transcript: transcript,
            summarySections: summarySections,
            selectedSectionID: selectedSectionID,
            sourceMaterial: sourceMaterial,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            videoDuration: videoDuration,
            errorMessage: errorMessage
        )
    }

    private func apply(state: YouTubeLearningPanelState) {
        urlText = state.urlText
        transcript = state.transcript
        summarySections = state.summarySections
        selectedSectionID = state.selectedSectionID
        sourceMaterial = state.sourceMaterial
        sourceTitle = state.sourceTitle
        sourceURL = state.sourceURL
        videoDuration = state.videoDuration
        errorMessage = state.errorMessage
        playbackStartSeconds = nil
        playbackRequestID = 0
        isLoading = false
    }

    private func store(state: YouTubeLearningPanelState, for conversationId: UUID?) {
        if let conversationId {
            loadedStates[conversationId] = state
            persist(state: state, for: conversationId)
        }
        if conversationId == activeConversationId {
            apply(state: state)
        }
    }

    private func loadState(conversationId: UUID) -> YouTubeLearningPanelState {
        guard let nodeStore,
              let record = try? nodeStore.fetchYouTubeLearningPanelState(nodeId: conversationId) else {
            return .empty
        }
        return record.state
    }

    private func persistActiveState() {
        guard let activeConversationId else { return }
        let state = currentPanelState
        loadedStates[activeConversationId] = state
        persist(state: state, for: activeConversationId)
    }

    private func persist(state: YouTubeLearningPanelState, for conversationId: UUID) {
        do {
            if state.shouldPersist {
                try nodeStore?.saveYouTubeLearningPanelState(
                    YouTubeLearningPanelStateRecord(
                        nodeId: conversationId,
                        state: state,
                        updatedAt: Date()
                    )
                )
            } else {
                try nodeStore?.deleteYouTubeLearningPanelState(nodeId: conversationId)
            }
        } catch {
            NSLog("YouTubeLearningViewModel persist failed: %@", error.localizedDescription)
        }
    }

    private static func looksLikeYouTubeURL(_ value: String) -> Bool {
        if (try? YouTubeVideoID(urlString: value)) != nil { return true }
        let lowercased = value.lowercased()
        return lowercased.contains("youtube.com") || lowercased.contains("youtu.be")
    }

    private static func normalizedSourceURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func sections(for material: SourceMaterialContext) -> [YouTubeSummarySection] {
        if let summaryMap = material.summaryMap, !summaryMap.isEmpty {
            return summaryMap.sections.map { section in
                YouTubeSummarySection(
                    title: section.title,
                    summary: section.summary,
                    startTime: Double(max(0, section.partNumber - 1)),
                    endTime: Double(max(1, section.partNumber))
                )
            }
        }

        return material.chunks.prefix(5).enumerated().compactMap { index, chunk in
            let summary = clippedPreviewLine(chunk.text)
            guard !summary.isEmpty else { return nil }
            return YouTubeSummarySection(
                title: "Part \(index + 1)",
                summary: summary,
                startTime: Double(index),
                endTime: Double(index + 1)
            )
        }
    }

    private static func previewSubtitle(for material: SourceMaterialContext, fallbackURL: String?) -> String {
        if let filename = material.originalFilename,
           !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filename
        }
        if let rawURL = material.originalURL ?? fallbackURL,
           let url = URL(string: rawURL),
           let host = url.host,
           !host.isEmpty {
            return host.removingWWWPrefix()
        }
        return "Source"
    }

    private static func previewBody(for material: SourceMaterialContext) -> String {
        if let map = material.summaryMap,
           let section = map.sections.first {
            return [section.locatorLabel, section.evidenceExcerpt ?? section.summary]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }
        if let chunk = material.chunks.first {
            return clippedPreviewBody(chunk.text)
        }
        return material.previewLine
    }

    private static func sourceExcerpt(for section: YouTubeSummarySection, material: SourceMaterialContext) -> String {
        let matchingChunk = material.chunks.first { chunk in
            chunk.text.contains(section.summary)
        }
        return matchingChunk.map { clippedPreviewBody($0.text, limit: 900) } ?? section.summary
    }

    private static func isVideoMaterial(_ material: SourceMaterialContext?, sourceURL: String?) -> Bool {
        if material?.evidenceLevel == .transcriptBacked || material?.evidenceLevel == .geminiVideoAnalysis {
            return true
        }
        guard let sourceURL else { return false }
        return looksLikeYouTubeURL(sourceURL)
    }

    private static func clippedPreviewLine(_ text: String, limit: Int = 240) -> String {
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clippedPreviewBody(_ text: String, limit: Int = 700) -> String {
        let normalized = SourceTextExtractor.normalizeWhitespace(text)
            .components(separatedBy: .newlines)
            .joined(separator: "\n")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func summaryMap(
        for sections: [YouTubeSummarySection],
        transcript: YouTubeTranscript?,
        evidenceLevel: SourceEvidenceLevel
    ) -> SourceSummaryMap? {
        guard !sections.isEmpty else { return nil }
        return SourceSummaryMap(
            sections: sections.enumerated().map { index, section in
                SourceSummaryMapSection(
                    partNumber: index + 1,
                    title: section.title,
                    summary: section.summary,
                    locatorLabel: section.timeRangeLabel,
                    evidenceExcerpt: evidenceExcerpt(
                        for: section,
                        transcript: transcript,
                        evidenceLevel: evidenceLevel
                    )
                )
            }
        )
    }

    private static func evidenceExcerpt(
        for section: YouTubeSummarySection,
        transcript: YouTubeTranscript?,
        evidenceLevel: SourceEvidenceLevel
    ) -> String? {
        guard evidenceLevel.isQuoteLevelReliable,
              let transcript else {
            return nil
        }

        let excerpt = transcript.excerpt(
            startTime: section.startTime,
            endTime: section.endTime,
            maxCharacters: 600
        )
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fallbackFailureMessage(captionError: Error, analysisError: Error) -> String {
        if captionError is YouTubeVideoIDError {
            return captionError.localizedDescription
        }
        return "Captions could not be read. \(analysisError.localizedDescription)"
    }
}

private extension String {
    func removingWWWPrefix() -> String {
        hasPrefix("www.") ? String(dropFirst(4)) : self
    }
}
