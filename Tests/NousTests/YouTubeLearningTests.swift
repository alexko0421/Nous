import Foundation
import XCTest
@testable import Nous

final class YouTubeLearningTests: XCTestCase {
    func testParsesYouTubeVideoIDsFromCommonURLShapes() throws {
        XCTAssertEqual(try YouTubeVideoID(urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ").rawValue, "dQw4w9WgXcQ")
        XCTAssertEqual(try YouTubeVideoID(urlString: "www.youtube.com/watch?v=dQw4w9WgXcQ").rawValue, "dQw4w9WgXcQ")
        XCTAssertEqual(try YouTubeVideoID(urlString: "https://youtu.be/dQw4w9WgXcQ?t=42").rawValue, "dQw4w9WgXcQ")
        XCTAssertEqual(try YouTubeVideoID(urlString: "https://www.youtube.com/shorts/dQw4w9WgXcQ").rawValue, "dQw4w9WgXcQ")
        XCTAssertEqual(try YouTubeVideoID(urlString: "https://www.youtube.com/embed/dQw4w9WgXcQ").rawValue, "dQw4w9WgXcQ")

        XCTAssertThrowsError(try YouTubeVideoID(urlString: "https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertThrowsError(try YouTubeVideoID(urlString: "https://www.youtube.com/watch?v=too-short"))
    }

    func testPlayerEmbedNormalizesSchemeStartTimeAndOrigin() throws {
        let embed = try YouTubePlayerEmbed(urlString: "www.youtube.com/watch?v=OQ0OOzOwsJY&t=1052s")
        let embedURL = try XCTUnwrap(URLComponents(url: embed.embedURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (embedURL.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(embed.videoID.rawValue, "OQ0OOzOwsJY")
        XCTAssertEqual(embed.startSeconds, 1052)
        XCTAssertEqual(embedURL.scheme, "https")
        XCTAssertEqual(embedURL.host, "www.youtube.com")
        XCTAssertEqual(embedURL.path, "/embed/OQ0OOzOwsJY")
        XCTAssertEqual(query["start"], "1052")
        XCTAssertEqual(query["playsinline"], "1")
        XCTAssertEqual(query["origin"], YouTubePlayerEmbed.embedOrigin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func testPlayerEmbedCanAutoplayFromSummaryStartAndForceReloads() throws {
        let videoID = try YouTubeVideoID(rawValue: "OQ0OOzOwsJY")
        let embed = YouTubePlayerEmbed(
            videoID: videoID,
            startSeconds: 182,
            autoplay: true,
            playbackRequestID: 7
        )
        let embedURL = try XCTUnwrap(URLComponents(url: embed.embedURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (embedURL.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(query["start"], "182")
        XCTAssertEqual(query["autoplay"], "1")
        XCTAssertTrue(embed.cacheKey.contains("playback=7"))
        XCTAssertTrue(embed.html.contains("allow=\"accelerometer; autoplay;"))
    }

    func testVoiceYouTubeURLResolverPrefersExplicitThenActiveBrowserThenCurrentPanelThenClipboard() {
        XCTAssertEqual(
            VoiceYouTubeURLResolver.resolve(
                explicitURL: "https://youtu.be/dQw4w9WgXcQ",
                activeBrowserURL: "https://youtu.be/xyz987LMN00",
                currentPanelURL: "https://youtu.be/OQ0OOzOwsJY",
                clipboardText: "https://youtu.be/abc123DEF45"
            ),
            "https://youtu.be/dQw4w9WgXcQ"
        )

        XCTAssertEqual(
            VoiceYouTubeURLResolver.resolve(
                explicitURL: nil,
                activeBrowserURL: "https://youtu.be/xyz987LMN00",
                currentPanelURL: "www.youtube.com/watch?v=OQ0OOzOwsJY",
                clipboardText: "https://youtu.be/abc123DEF45"
            ),
            "https://youtu.be/xyz987LMN00"
        )

        XCTAssertEqual(
            VoiceYouTubeURLResolver.resolve(
                explicitURL: nil,
                activeBrowserURL: nil,
                currentPanelURL: "www.youtube.com/watch?v=OQ0OOzOwsJY",
                clipboardText: "https://youtu.be/abc123DEF45"
            ),
            "www.youtube.com/watch?v=OQ0OOzOwsJY"
        )
    }

    func testVoiceYouTubeURLResolverFallsBackFromInvalidActiveBrowserAndCurrentPanel() {
        XCTAssertEqual(
            VoiceYouTubeURLResolver.resolve(
                explicitURL: nil,
                activeBrowserURL: "https://example.com/video",
                currentPanelURL: "www.youtube.com/watch?v=OQ0OOzOwsJY",
                clipboardText: "https://www.youtube.com/watch?v=abc123DEF45"
            ),
            "www.youtube.com/watch?v=OQ0OOzOwsJY"
        )

        XCTAssertEqual(
            VoiceYouTubeURLResolver.resolve(
                explicitURL: nil,
                activeBrowserURL: "not a youtube url",
                currentPanelURL: "not a youtube url",
                clipboardText: "https://www.youtube.com/watch?v=abc123DEF45"
            ),
            "https://www.youtube.com/watch?v=abc123DEF45"
        )
    }

    func testVoiceYouTubeURLResolverReturnsNilWhenNoValidCandidateExists() {
        XCTAssertNil(
            VoiceYouTubeURLResolver.resolve(
                explicitURL: nil,
                activeBrowserURL: "https://example.com/active",
                currentPanelURL: "https://example.com/video",
                clipboardText: "plain notes"
            )
        )
    }

    func testVoiceYouTubeURLRequestResolverDoesNotReadActiveBrowserWhenExplicitURLIsValid() {
        var didReadActiveBrowser = false

        let resolvedURL = VoiceYouTubeURLRequestResolver.resolve(
            explicitURL: "https://youtu.be/dQw4w9WgXcQ",
            activeBrowserURL: {
                didReadActiveBrowser = true
                return "https://youtu.be/xyz987LMN00"
            },
            currentPanelURL: "https://youtu.be/OQ0OOzOwsJY",
            clipboardText: { "https://youtu.be/abc123DEF45" }
        )

        XCTAssertEqual(resolvedURL, "https://youtu.be/dQw4w9WgXcQ")
        XCTAssertFalse(didReadActiveBrowser)
    }

    func testVoiceYouTubeURLRequestResolverReadsActiveBrowserAfterInvalidExplicitURL() {
        var didReadActiveBrowser = false

        let resolvedURL = VoiceYouTubeURLRequestResolver.resolve(
            explicitURL: "not a youtube url",
            activeBrowserURL: {
                didReadActiveBrowser = true
                return "https://youtu.be/xyz987LMN00"
            },
            currentPanelURL: "https://youtu.be/OQ0OOzOwsJY",
            clipboardText: { "https://youtu.be/abc123DEF45" }
        )

        XCTAssertEqual(resolvedURL, "https://youtu.be/xyz987LMN00")
        XCTAssertTrue(didReadActiveBrowser)
    }

    func testActiveBrowserTabURLReaderReadsSafariCurrentTabURL() throws {
        var capturedScript: String?
        let reader = ActiveBrowserTabURLReader(
            frontmostBundleIdentifier: { "com.apple.Safari" },
            runScript: { script in
                capturedScript = script
                return "\n https://youtu.be/dQw4w9WgXcQ \n"
            }
        )

        XCTAssertEqual(reader.currentActiveBrowserURL(), "https://youtu.be/dQw4w9WgXcQ")
        let script = try XCTUnwrap(capturedScript)
        XCTAssertTrue(script.contains("application id \"com.apple.Safari\""))
        XCTAssertTrue(script.contains("URL of current tab"))
    }

    func testActiveBrowserTabURLReaderReadsChromiumActiveTabURL() throws {
        var capturedScript: String?
        let reader = ActiveBrowserTabURLReader(
            frontmostBundleIdentifier: { "com.google.Chrome" },
            runScript: { script in
                capturedScript = script
                return "https://www.youtube.com/watch?v=OQ0OOzOwsJY"
            }
        )

        XCTAssertEqual(reader.currentActiveBrowserURL(), "https://www.youtube.com/watch?v=OQ0OOzOwsJY")
        let script = try XCTUnwrap(capturedScript)
        XCTAssertTrue(script.contains("application id \"com.google.Chrome\""))
        XCTAssertTrue(script.contains("URL of active tab of front window"))
    }

    func testActiveBrowserTabURLReaderIgnoresUnsupportedOrBlankSources() {
        var didRunScript = false
        let unsupportedReader = ActiveBrowserTabURLReader(
            frontmostBundleIdentifier: { "com.apple.finder" },
            runScript: { _ in
                didRunScript = true
                return "https://youtu.be/dQw4w9WgXcQ"
            }
        )

        XCTAssertNil(unsupportedReader.currentActiveBrowserURL())
        XCTAssertFalse(didRunScript)

        let blankReader = ActiveBrowserTabURLReader(
            frontmostBundleIdentifier: { "com.microsoft.edgemac" },
            runScript: { _ in " \n\t " }
        )

        XCTAssertNil(blankReader.currentActiveBrowserURL())
    }

    func testProjectDeclaresAppleEventsUsageForActiveBrowserURLCapture() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYAML = try String(
            contentsOf: repoRootURL.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(projectYAML.contains("NSAppleEventsUsageDescription"))
        XCTAssertTrue(projectYAML.contains("active browser tab"))
    }

    func testPlayerEmbedHTMLCarriesReferrerPolicyForWebKit() throws {
        let embed = try YouTubePlayerEmbed(urlString: "https://youtu.be/OQ0OOzOwsJY?t=17m32s")

        XCTAssertEqual(embed.startSeconds, 1052)
        XCTAssertTrue(embed.html.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
        XCTAssertTrue(embed.html.contains("<meta name=\"referrer\" content=\"strict-origin-when-cross-origin\">"))
        XCTAssertTrue(embed.html.contains(embed.embedURL.absoluteString))
        XCTAssertEqual(YouTubePlayerEmbed.embedOrigin.absoluteString, "https://nous.local/")
    }

    func testFetchesCaptionTrackAndParsesTimestampedXMLTranscript() async throws {
        let html = """
        <html>
        <head><title>Fallback Title - YouTube</title></head>
        <script>
        var ytInitialPlayerResponse = {
          "videoDetails": {"title": "Swift Concurrency Lesson"},
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ\\u0026lang=en",
                  "languageCode": "en",
                  "kind": "asr",
                  "name": {"simpleText": "English"}
                }
              ]
            }
          }
        };
        </script>
        </html>
        """
        let transcriptXML = """
        <transcript>
          <text start="0.0" dur="2.4">First &amp; line</text>
          <text start="2.4" dur="3.0">Second line</text>
        </transcript>
        """
        let service = YouTubeTranscriptService(
            httpClient: StubYouTubeHTTPClient { request in
                let url = try XCTUnwrap(request.url?.absoluteString)
                if url.contains("/watch") {
                    return html
                }
                if url.contains("/api/timedtext") {
                    return transcriptXML
                }
                XCTFail("Unexpected URL \(url)")
                return ""
            }
        )

        let transcript = try await service.fetchTranscript(from: "https://youtu.be/dQw4w9WgXcQ")

        XCTAssertEqual(transcript.videoID.rawValue, "dQw4w9WgXcQ")
        XCTAssertEqual(transcript.title, "Swift Concurrency Lesson")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "First & line")
        XCTAssertEqual(transcript.segments[0].startTime, 0)
        XCTAssertEqual(transcript.segments[0].endTime, 2.4, accuracy: 0.001)
    }

    func testThrowsCaptionUnavailableWhenNoCaptionTracksExist() async throws {
        let service = YouTubeTranscriptService(
            httpClient: StubYouTubeHTTPClient { _ in
                """
                <html>
                <script>var ytInitialPlayerResponse = {"videoDetails":{"title":"No Captions"}};</script>
                </html>
                """
            }
        )

        do {
            _ = try await service.fetchTranscript(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
            XCTFail("Expected captions unavailable")
        } catch let error as YouTubeTranscriptError {
            XCTAssertEqual(error, .captionsUnavailable)
        }
    }

    func testFetchesTranscriptFromInnertubePlayerWhenWatchPageCaptionTrackIsUnavailable() async throws {
        let watchHTML = """
        <html>
        <script>
        ytcfg.set({
          "INNERTUBE_API_KEY": "test-api-key",
          "INNERTUBE_CLIENT_VERSION": "2.20260506.01.00"
        });
        var ytInitialPlayerResponse = {
          "videoDetails": {
            "title": "How to Start a Cult",
            "lengthSeconds": "3926"
          }
        };
        </script>
        </html>
        """
        let playerJSON = """
        {
          "videoDetails": {
            "title": "How to Start a Cult",
            "lengthSeconds": "3926"
          },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=OQ0OOzOwsJY&lang=en&fmt=srv3",
                  "languageCode": "en",
                  "kind": "asr",
                  "name": {"runs": [{"text": "English (auto-generated)"}]}
                }
              ]
            }
          }
        }
        """
        let transcriptXML = """
        <?xml version="1.0" encoding="utf-8" ?><timedtext format="3">
          <body>
            <p t="160" d="3040"><s>Today</s><s t="240"> I</s><s t="520"> asked</s></p>
            <p t="3200" d="1800"><s>about</s><s t="220"> community</s></p>
          </body>
        </timedtext>
        """
        let service = YouTubeTranscriptService(
            httpClient: StubYouTubeHTTPClient { request in
                let url = try XCTUnwrap(request.url?.absoluteString)
                if url.contains("/watch") {
                    return watchHTML
                }
                if url.contains("/youtubei/v1/player") {
                    let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                    XCTAssertTrue(body.contains("\"clientName\":\"ANDROID\""))
                    XCTAssertTrue(body.contains("\"videoId\":\"OQ0OOzOwsJY\""))
                    return playerJSON
                }
                if url.contains("/api/timedtext") {
                    return transcriptXML
                }
                XCTFail("Unexpected URL \(url)")
                return ""
            }
        )

        let transcript = try await service.fetchTranscript(from: "https://www.youtube.com/watch?v=OQ0OOzOwsJY")

        XCTAssertEqual(transcript.title, "How to Start a Cult")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "Today I asked")
        XCTAssertEqual(transcript.segments[0].startTime, 0.16, accuracy: 0.001)
        XCTAssertEqual(transcript.segments[0].duration, 3.04, accuracy: 0.001)
    }

    func testFetchesVideoReferenceTitleAndDurationFromWatchPage() async throws {
        let service = YouTubeTranscriptService(
            httpClient: StubYouTubeHTTPClient { _ in
                """
                <html>
                <script>
                var ytInitialPlayerResponse = {
                  "videoDetails": {
                    "title": "How to Start a Cult",
                    "lengthSeconds": "3926"
                  }
                };
                </script>
                </html>
                """
            }
        )

        let video = try await service.fetchVideoReference(from: "https://www.youtube.com/watch?v=OQ0OOzOwsJY&t=1052s")

        XCTAssertEqual(video.title, "How to Start a Cult")
        XCTAssertEqual(video.duration, 3926)
        XCTAssertEqual(video.startSeconds, 1052)
        XCTAssertEqual(video.sourceURL.absoluteString, "https://www.youtube.com/watch?v=OQ0OOzOwsJY")
    }

    func testSummaryServiceParsesJSONSectionsAndKeepsInvalidOutputNonFatal() async throws {
        let transcript = YouTubeTranscript(
            videoID: try YouTubeVideoID(urlString: "https://youtu.be/dQw4w9WgXcQ"),
            title: "Learning Video",
            sourceURL: URL(string: "https://youtu.be/dQw4w9WgXcQ")!,
            segments: [
                YouTubeTranscriptSegment(startTime: 0, duration: 12, text: "First concept"),
                YouTubeTranscriptSegment(startTime: 12, duration: 8, text: "Second concept")
            ]
        )
        let valid = YouTubeLearningSummaryService(
            llmServiceProvider: {
                StaticYouTubeSummaryLLM(output: """
                [
                  {"title":"Opening idea","summary":"Explains the first concept.","startTime":0,"endTime":12},
                  {"title":"Second idea","summary":"Explains the second concept.","startTime":12,"endTime":20}
                ]
                """)
            }
        )
        let invalid = YouTubeLearningSummaryService(
            llmServiceProvider: { StaticYouTubeSummaryLLM(output: "not json") }
        )

        let sections = try await valid.generateSections(for: transcript)
        let invalidSections = try await invalid.generateSections(for: transcript)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "Opening idea")
        XCTAssertEqual(sections[0].summary, "Explains the first concept.")
        XCTAssertEqual(sections[0].startTime, 0)
        XCTAssertEqual(sections[0].endTime, 12)
        XCTAssertTrue(invalidSections.isEmpty)
    }

    @MainActor
    func testSummaryTimelineSegmentsUseSectionDurationAndStableColorIndexes() throws {
        let store = try NodeStore(path: ":memory:")
        let viewModel = YouTubeLearningViewModel(
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )
        viewModel.summarySections = [
            YouTubeSummarySection(
                title: "Opening idea",
                summary: "Explains the opening.",
                startTime: 0,
                endTime: 4
            ),
            YouTubeSummarySection(
                title: "Second idea",
                summary: "Explains the second part.",
                startTime: 12,
                endTime: 20
            )
        ]

        let segments = viewModel.summaryTimelineSegments

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startFraction, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].widthFraction, 0.2, accuracy: 0.001)
        XCTAssertEqual(segments[0].colorIndex, 0)
        XCTAssertFalse(segments[0].isSelected)
        XCTAssertEqual(segments[1].startFraction, 0.6, accuracy: 0.001)
        XCTAssertEqual(segments[1].widthFraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(segments[1].colorIndex, 1)
    }

    func testYouTubeLearningPanelListsAllSectionSummaries() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panelSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/YouTubeLearningPanel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(panelSource.contains("private var summaryTimeline"))
        XCTAssertTrue(panelSource.contains("summaryDetail(for:"))
        XCTAssertTrue(panelSource.contains("viewModel.selectSectionForPlayback(segment.section)"))
        XCTAssertTrue(panelSource.contains("viewModel.selectSectionForDiscussionAndPlayback(section)"))
        // Every section's title + summary is rendered as its own card so Alex
        // can scan the whole topic list without clicking through the timeline.
        XCTAssertTrue(panelSource.contains("ForEach(viewModel.summarySections) { section in"))
    }

    func testYouTubePrecisionLabelsRenderInPanelAndComposerChip() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panelSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/YouTubeLearningPanel.swift"),
            encoding: .utf8
        )
        let chipSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/AttachmentChip.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(panelSource.contains("evidencePill"))
        XCTAssertTrue(panelSource.contains("viewModel.currentEvidenceLabel"))
        XCTAssertTrue(chipSource.contains("context.evidenceLabel"))
        XCTAssertTrue(chipSource.contains("context.previewLine"))
    }

    func testSentMessageSourceChipRendersFromPersistedSourceMaterial() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )
        let chipSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/AttachmentChip.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(chatSource.contains("vm.sourceMaterials(for: msg)"))
        XCTAssertTrue(chatSource.contains("SourceMaterialMessageChip(material:"))
        XCTAssertTrue(chipSource.contains("struct SourceMaterialMessageChip"))
        XCTAssertTrue(chipSource.contains("material.previewLine"))
    }

    func testGeminiVideoAnalyzerUsesProAndPassesYouTubeURLAsLowResolutionFileDataPart() throws {
        let video = try YouTubeVideoReference(urlString: "https://youtu.be/OQ0OOzOwsJY?t=1052")
        let service = GeminiYouTubeVideoAnalysisService(apiKey: "test-key")

        let request = try service.makeURLRequest(for: video)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(contents.first)
        let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])
        let filePart = try XCTUnwrap(parts.first)
        let fileData = try XCTUnwrap(filePart["file_data"] as? [String: Any])
        let textPart = try XCTUnwrap(parts.last)
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent")
        XCTAssertEqual(request.timeoutInterval, 300)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertEqual(fileData["file_uri"] as? String, "https://www.youtube.com/watch?v=OQ0OOzOwsJY")
        XCTAssertNil(fileData["mime_type"])
        XCTAssertTrue((textPart["text"] as? String)?.contains("Analyze this YouTube video") == true)
        XCTAssertEqual(config["mediaResolution"] as? String, "MEDIA_RESOLUTION_LOW")
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")

        // Gemini 2.5 Pro is thinking-only (Budget 0 is rejected by the API). A
        // positive budget keeps reasoning from cannibalising the JSON output
        // budget — Pro needs both rooms to finish a complete sections array.
        let thinkingConfig = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinkingConfig["thinkingBudget"] as? Int, 1024)
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 16384)
    }

    func testSummaryServiceParsesStringTimestampsFromGeminiOutput() {
        // Gemini occasionally ignores prompt rules and returns "mm:ss" /
        // "hh:mm:ss" strings instead of numeric seconds; the decoder must
        // tolerate both so we don't drop the whole array.
        let output = """
        [
          {"title":"Opening","summary":"Intro.","startTime":"0:00","endTime":"10:25"},
          {"title":"Middle","summary":"Body.","startTime":"10:25","endTime":"1:00:30"},
          {"title":"End","summary":"Wrap.","startTime":3630,"endTime":3700}
        ]
        """
        let sections = YouTubeLearningSummaryService.parseSections(from: output)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].startTime, 0)
        XCTAssertEqual(sections[0].endTime, 625)
        XCTAssertEqual(sections[1].startTime, 625)
        XCTAssertEqual(sections[1].endTime, 3630)
        XCTAssertEqual(sections[2].startTime, 3630)
        XCTAssertEqual(sections[2].endTime, 3700)
    }

    func testGeminiVideoAnalyzerSurfacesHTTPErrorBody() async throws {
        let video = try YouTubeVideoReference(urlString: "https://youtu.be/OQ0OOzOwsJY")
        let service = GeminiYouTubeVideoAnalysisService(
            apiKey: "test-key",
            httpClient: StubGeminiVideoAnalysisHTTPClient(
                statusCode: 400,
                body: """
                {"error":{"code":400,"message":"Input video is too long for the selected media resolution.","status":"INVALID_ARGUMENT"}}
                """
            )
        )

        do {
            _ = try await service.generateSections(for: video)
            XCTFail("Expected Gemini HTTP failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Gemini video analysis failed"))
            XCTAssertTrue(error.localizedDescription.contains("Input video is too long"))
        }
    }

    func testGeminiVideoAnalyzerSurfacesTimeoutAsVideoAnalysisError() async throws {
        let video = try YouTubeVideoReference(urlString: "https://youtu.be/OQ0OOzOwsJY")
        let service = GeminiYouTubeVideoAnalysisService(
            apiKey: "test-key",
            httpClient: ThrowingGeminiVideoAnalysisHTTPClient(error: URLError(.timedOut))
        )

        do {
            _ = try await service.generateSections(for: video)
            XCTFail("Expected Gemini timeout failure")
        } catch let error as GeminiVideoAnalysisError {
            XCTAssertEqual(error, .timedOut(seconds: 300))
            XCTAssertTrue(error.localizedDescription.contains("Gemini video analysis timed out"))
        }
    }

    @MainActor
    func testLearningViewModelLoadsTranscriptPersistsSourceAndBuildsDiscussionContext() async throws {
        let store = try NodeStore(path: ":memory:")
        let viewModel = YouTubeLearningViewModel(
            transcriptService: transcriptServiceReturningTwoSegments(),
            summaryService: YouTubeLearningSummaryService(
                llmServiceProvider: {
                    StaticYouTubeSummaryLLM(output: """
                    [
                      {"title":"Opening idea","summary":"Explains the opening.","startTime":0,"endTime":4}
                    ]
                    """)
                }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "https://youtu.be/dQw4w9WgXcQ"
        viewModel.selectedSectionID = UUID()
        XCTAssertEqual(viewModel.videoID?.rawValue, "dQw4w9WgXcQ")
        await viewModel.load(projectId: nil)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.selectedSectionID)
        XCTAssertEqual(viewModel.videoID?.rawValue, "dQw4w9WgXcQ")
        XCTAssertEqual(viewModel.transcript?.title, "Swift Concurrency Lesson")
        XCTAssertEqual(viewModel.summarySections.count, 1)

        let section = try XCTUnwrap(viewModel.summarySections.first)
        let context = try XCTUnwrap(viewModel.discussionContext(for: section))
        XCTAssertEqual(context.summaryTitle, "Opening idea")
        XCTAssertTrue(context.transcriptExcerpt.contains("00:00 First & line"))

        let sourceNode = try XCTUnwrap(try store.fetchNode(id: context.sourceNodeId))
        XCTAssertEqual(sourceNode.type.rawValue, NodeType.source.rawValue)
        XCTAssertTrue(sourceNode.content.contains("00:00 First & line"))

        let metadata = try XCTUnwrap(try store.fetchSourceMetadata(nodeId: context.sourceNodeId))
        XCTAssertEqual(metadata.kind, .youtube)
        XCTAssertEqual(metadata.evidenceLevel, .transcriptBacked)
        XCTAssertEqual(context.evidenceLevel, .transcriptBacked)
        XCTAssertTrue(context.promptText.contains("Evidence: Transcript-backed"))
    }

    @MainActor
    func testSelectingSummarySetsDiscussionContextAndPlayerStart() async throws {
        let store = try NodeStore(path: ":memory:")
        let viewModel = YouTubeLearningViewModel(
            transcriptService: transcriptServiceReturningTwoSegments(),
            summaryService: YouTubeLearningSummaryService(
                llmServiceProvider: {
                    StaticYouTubeSummaryLLM(output: """
                    [
                      {"title":"Opening idea","summary":"Explains the opening.","startTime":0,"endTime":4},
                      {"title":"Second idea","summary":"Explains the second part.","startTime":2.4,"endTime":5.4}
                    ]
                    """)
                }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "https://youtu.be/dQw4w9WgXcQ"
        await viewModel.load(projectId: nil)
        let section = try XCTUnwrap(viewModel.summarySections.last)

        let context = try XCTUnwrap(viewModel.selectSectionForDiscussionAndPlayback(section))
        let embed = try XCTUnwrap(viewModel.playerEmbed)

        XCTAssertEqual(context.summaryTitle, "Second idea")
        XCTAssertEqual(viewModel.selectedSectionID, section.id)
        XCTAssertEqual(embed.startSeconds, 2)
        XCTAssertTrue(embed.autoplay)
        XCTAssertEqual(embed.playbackRequestID, 1)
    }

    @MainActor
    func testSelectingTimelineSectionCanImmediatelyCreateDiscussionContext() async throws {
        let store = try NodeStore(path: ":memory:")
        let viewModel = YouTubeLearningViewModel(
            transcriptService: transcriptServiceReturningTwoSegments(),
            summaryService: YouTubeLearningSummaryService(
                llmServiceProvider: {
                    StaticYouTubeSummaryLLM(output: """
                    [
                      {"title":"Opening idea","summary":"Explains the opening.","startTime":0,"endTime":4},
                      {"title":"Second idea","summary":"Explains the second part.","startTime":2.4,"endTime":5.4}
                    ]
                    """)
                }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "https://youtu.be/dQw4w9WgXcQ"
        await viewModel.load(projectId: nil)
        let section = try XCTUnwrap(viewModel.summarySections.last)

        let context = try XCTUnwrap(viewModel.selectSectionForDiscussionAndPlayback(section))
        let embed = try XCTUnwrap(viewModel.playerEmbed)

        XCTAssertEqual(viewModel.selectedSectionID, section.id)
        XCTAssertEqual(viewModel.selectedSummarySection?.id, section.id)
        XCTAssertEqual(embed.startSeconds, 2)
        XCTAssertTrue(embed.autoplay)
        XCTAssertEqual(embed.playbackRequestID, 1)
        XCTAssertEqual(context.summaryTitle, "Second idea")
        XCTAssertEqual(context.summary, "Explains the second part.")
    }

    @MainActor
    func testLearningViewModelKeepsTranscriptUsableWhenSummaryOutputIsInvalid() async throws {
        let store = try NodeStore(path: ":memory:")
        let viewModel = YouTubeLearningViewModel(
            transcriptService: transcriptServiceReturningTwoSegments(),
            summaryService: YouTubeLearningSummaryService(
                llmServiceProvider: { StaticYouTubeSummaryLLM(output: "not json") }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "https://youtu.be/dQw4w9WgXcQ"
        await viewModel.load(projectId: nil)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.transcript)
        XCTAssertTrue(viewModel.summarySections.isEmpty)
        XCTAssertTrue(viewModel.isSummaryUnavailable)
        XCTAssertEqual(viewModel.summaryUnavailableMessage, "Transcript loaded. Summary is unavailable for this video.")
    }

    @MainActor
    func testLearningViewModelShowsCaptionErrorWhenCaptionsAreUnavailable() async throws {
        let store = try NodeStore(path: ":memory:")
        let viewModel = YouTubeLearningViewModel(
            transcriptService: YouTubeTranscriptService(
                httpClient: StubYouTubeHTTPClient { _ in
                    """
                    <html>
                    <script>var ytInitialPlayerResponse = {"videoDetails":{"title":"No Captions"}};</script>
                    </html>
                    """
                }
            ),
            summaryService: YouTubeLearningSummaryService(
                llmServiceProvider: { StaticYouTubeSummaryLLM(output: "[]") }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        await viewModel.load(projectId: nil)

        XCTAssertNil(viewModel.transcript)
        XCTAssertTrue(viewModel.summarySections.isEmpty)
        XCTAssertTrue(viewModel.errorMessage?.contains("captions") == true)
    }

    @MainActor
    func testLearningViewModelNamesGeminiTimeoutWhenCaptionFallbackTimesOut() async throws {
        let store = try NodeStore(path: ":memory:")
        let viewModel = YouTubeLearningViewModel(
            transcriptService: YouTubeTranscriptService(
                httpClient: StubYouTubeHTTPClient { request in
                    let url = try XCTUnwrap(request.url?.absoluteString)
                    if url.contains("/watch") {
                        return """
                        <html>
                        <script>
                        var ytInitialPlayerResponse = {
                          "videoDetails": {"title": "How to Start a Cult"},
                          "captions": {
                            "playerCaptionsTracklistRenderer": {
                              "captionTracks": [
                                {"baseUrl": "https://www.youtube.com/api/timedtext?v=OQ0OOzOwsJY\\u0026lang=en"}
                              ]
                            }
                          }
                        };
                        </script>
                        </html>
                        """
                    }
                    if url.contains("/api/timedtext") {
                        return "<html>blocked</html>"
                    }
                    XCTFail("Unexpected URL \(url)")
                    return ""
                }
            ),
            summaryService: YouTubeLearningSummaryService(
                videoAnalysisServiceProvider: {
                    ThrowingYouTubeVideoAnalyzer(
                        error: GeminiVideoAnalysisError.timedOut(seconds: 300)
                    )
                }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "https://www.youtube.com/watch?v=OQ0OOzOwsJY&t=1052s"
        await viewModel.load(projectId: nil)

        XCTAssertNil(viewModel.transcript)
        XCTAssertTrue(viewModel.summarySections.isEmpty)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Captions could not be read. Gemini video analysis timed out after 5 minutes. Try again, or use a shorter video."
        )
    }

    @MainActor
    func testLearningViewModelFallsBackToGeminiVideoAnalysisWhenCaptionTrackCannotBeRead() async throws {
        let store = try NodeStore(path: ":memory:")
        let analyzer = CapturingYouTubeVideoAnalyzer(
            sections: [
                YouTubeSummarySection(
                    title: "Belief and belonging",
                    summary: "Explains how a group creates a shared worldview.",
                    startTime: 0,
                    endTime: 420
                ),
                YouTubeSummarySection(
                    title: "Recruiting momentum",
                    summary: "Breaks down how commitment escalates over time.",
                    startTime: 420,
                    endTime: 840
                )
            ]
        )
        let html = """
        <html>
        <script>
        var ytInitialPlayerResponse = {
          "videoDetails": {"title": "How to Start a Cult"},
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=OQ0OOzOwsJY\\u0026lang=en",
                  "languageCode": "en",
                  "name": {"simpleText": "English"}
                }
              ]
            }
          }
        };
        </script>
        </html>
        """
        let viewModel = YouTubeLearningViewModel(
            transcriptService: YouTubeTranscriptService(
                httpClient: StubYouTubeHTTPClient { request in
                    let url = try XCTUnwrap(request.url?.absoluteString)
                    if url.contains("/watch") {
                        return html
                    }
                    if url.contains("/api/timedtext") {
                        return "<html>blocked</html>"
                    }
                    XCTFail("Unexpected URL \(url)")
                    return ""
                }
            ),
            summaryService: YouTubeLearningSummaryService(
                videoAnalysisServiceProvider: { analyzer }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "www.youtube.com/watch?v=OQ0OOzOwsJY&t=1052s"
        await viewModel.load(projectId: nil)

        XCTAssertNil(viewModel.transcript)
        XCTAssertEqual(viewModel.summarySections.count, 2)
        XCTAssertTrue(viewModel.errorMessage?.contains("Gemini 2.5 Pro") == true)
        XCTAssertEqual(analyzer.capturedVideo?.sourceURL.absoluteString, "https://www.youtube.com/watch?v=OQ0OOzOwsJY")

        let section = try XCTUnwrap(viewModel.summarySections.first)
        let context = try XCTUnwrap(viewModel.discussionContext(for: section))
        XCTAssertEqual(context.summaryTitle, "Belief and belonging")
        XCTAssertTrue(context.transcriptExcerpt.contains("shared worldview"))

        let sourceNode = try XCTUnwrap(try store.fetchNode(id: context.sourceNodeId))
        XCTAssertEqual(sourceNode.type.rawValue, NodeType.source.rawValue)
        XCTAssertTrue(sourceNode.content.contains("Belief and belonging"))
        XCTAssertTrue(sourceNode.content.contains("Explains how a group creates a shared worldview."))

        let metadata = try XCTUnwrap(try store.fetchSourceMetadata(nodeId: context.sourceNodeId))
        XCTAssertEqual(metadata.kind, .youtube)
        XCTAssertEqual(metadata.evidenceLevel, .geminiVideoAnalysis)
        XCTAssertEqual(context.evidenceLevel, .geminiVideoAnalysis)
        XCTAssertFalse(context.isQuoteLevelReliable)
        XCTAssertTrue(context.promptText.contains("Evidence: Gemini video analysis"))
    }

    @MainActor
    func testLearningViewModelClampsGeminiFallbackSectionsToKnownVideoDuration() async throws {
        let store = try NodeStore(path: ":memory:")
        let analyzer = CapturingYouTubeVideoAnalyzer(
            sections: [
                YouTubeSummarySection(
                    title: "Opening",
                    summary: "Starts the conversation.",
                    startTime: 0,
                    endTime: 120
                ),
                YouTubeSummarySection(
                    title: "Near the end",
                    summary: "Runs into the real end of the video.",
                    startTime: 3_800,
                    endTime: 5_000
                ),
                YouTubeSummarySection(
                    title: "Impossible hours",
                    summary: "This should not be shown.",
                    startTime: 19_180,
                    endTime: 31_000
                )
            ]
        )
        let html = """
        <html>
        <script>
        var ytInitialPlayerResponse = {
          "videoDetails": {
            "title": "How to Start a Cult",
            "lengthSeconds": "3926"
          },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=OQ0OOzOwsJY\\u0026lang=en",
                  "languageCode": "en"
                }
              ]
            }
          }
        };
        </script>
        </html>
        """
        let viewModel = YouTubeLearningViewModel(
            transcriptService: YouTubeTranscriptService(
                httpClient: StubYouTubeHTTPClient { request in
                    let url = try XCTUnwrap(request.url?.absoluteString)
                    if url.contains("/watch") {
                        return html
                    }
                    if url.contains("/api/timedtext") {
                        return "<html>blocked</html>"
                    }
                    XCTFail("Unexpected URL \(url)")
                    return ""
                }
            ),
            summaryService: YouTubeLearningSummaryService(
                videoAnalysisServiceProvider: { analyzer }
            ),
            sourceIngestionService: makeSourceIngestionService(nodeStore: store)
        )

        viewModel.urlText = "https://www.youtube.com/watch?v=OQ0OOzOwsJY"
        await viewModel.load(projectId: nil)

        XCTAssertEqual(analyzer.capturedVideo?.duration, 3_926)
        XCTAssertEqual(viewModel.summarySections.map(\.title), ["Opening", "Near the end"])
        XCTAssertEqual(viewModel.summarySections.last?.endTime, 3_926)
        XCTAssertFalse(viewModel.summarySections.contains { $0.timeRangeLabel.contains("5:19:40") })

        let sourceNodeId = try XCTUnwrap(viewModel.discussionContext(for: viewModel.summarySections[0])?.sourceNodeId)
        let sourceNode = try XCTUnwrap(try store.fetchNode(id: sourceNodeId))
        XCTAssertFalse(sourceNode.content.contains("Impossible hours"))
    }
}

private func makeSourceIngestionService(nodeStore: NodeStore) -> SourceIngestionService {
    SourceIngestionService(
        nodeStore: nodeStore,
        vectorStore: VectorStore(nodeStore: nodeStore),
        embeddingProvider: EmbeddingService()
    )
}

private func transcriptServiceReturningTwoSegments() -> YouTubeTranscriptService {
    let html = """
    <html>
    <script>
    var ytInitialPlayerResponse = {
      "videoDetails": {"title": "Swift Concurrency Lesson"},
      "captions": {
        "playerCaptionsTracklistRenderer": {
          "captionTracks": [
            {
              "baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ\\u0026lang=en",
              "languageCode": "en",
              "name": {"simpleText": "English"}
            }
          ]
        }
      }
    };
    </script>
    </html>
    """
    let transcriptXML = """
    <transcript>
      <text start="0.0" dur="2.4">First &amp; line</text>
      <text start="2.4" dur="3.0">Second line</text>
    </transcript>
    """

    return YouTubeTranscriptService(
        httpClient: StubYouTubeHTTPClient { request in
            let url = try XCTUnwrap(request.url?.absoluteString)
            if url.contains("/watch") {
                return html
            }
            if url.contains("/api/timedtext") {
                return transcriptXML
            }
            XCTFail("Unexpected URL \(url)")
            return ""
        }
    )
}

private final class StubYouTubeHTTPClient: YouTubeTranscriptHTTPClient {
    let response: (URLRequest) throws -> String

    init(response: @escaping (URLRequest) throws -> String) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let data = Data(try response(request).utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )!
        return (data, response)
    }
}

private struct StaticYouTubeSummaryLLM: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

private struct StubGeminiVideoAnalysisHTTPClient: GeminiVideoAnalysisHTTPClient {
    let statusCode: Int
    let body: String

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}

private struct ThrowingGeminiVideoAnalysisHTTPClient: GeminiVideoAnalysisHTTPClient {
    let error: Error

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

private final class CapturingYouTubeVideoAnalyzer: YouTubeVideoAnalysisGenerating {
    let sections: [YouTubeSummarySection]
    private(set) var capturedVideo: YouTubeVideoReference?

    init(sections: [YouTubeSummarySection]) {
        self.sections = sections
    }

    func generateSections(for video: YouTubeVideoReference) async throws -> [YouTubeSummarySection] {
        capturedVideo = video
        return sections
    }
}

private struct ThrowingYouTubeVideoAnalyzer: YouTubeVideoAnalysisGenerating {
    let error: Error

    func generateSections(for video: YouTubeVideoReference) async throws -> [YouTubeSummarySection] {
        throw error
    }
}
