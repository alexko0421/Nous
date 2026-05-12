import Foundation

enum YouTubeTranscriptError: LocalizedError, Equatable {
    case invalidResponse
    case captionsUnavailable
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "YouTube did not return a usable page."
        case .captionsUnavailable:
            return "This video does not expose captions that Nous can read yet."
        case .transcriptUnavailable:
            return "The caption track could not be read."
        }
    }
}

protocol YouTubeTranscriptHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: YouTubeTranscriptHTTPClient {}

struct YouTubeTranscriptService {
    private let httpClient: any YouTubeTranscriptHTTPClient

    init(httpClient: any YouTubeTranscriptHTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchTranscript(from urlString: String) async throws -> YouTubeTranscript {
        let videoID = try YouTubeVideoID(urlString: urlString)
        let sourceURL = URL(string: "https://www.youtube.com/watch?v=\(videoID.rawValue)")!
        let watchHTML = try await fetchString(from: sourceURL)
        let title = Self.extractTitle(from: watchHTML) ?? "YouTube Video"
        if let captionURL = Self.bestCaptionURL(from: watchHTML),
           let segments = try? await fetchSegments(from: captionURL),
           !segments.isEmpty {
            return YouTubeTranscript(
                videoID: videoID,
                title: title,
                sourceURL: sourceURL,
                segments: segments
            )
        }

        guard let captionURL = try await bestCaptionURLFromInnertubePlayer(
            videoID: videoID,
            watchHTML: watchHTML
        ) else {
            throw YouTubeTranscriptError.captionsUnavailable
        }

        let segments = try await fetchSegments(from: captionURL)
        guard !segments.isEmpty else { throw YouTubeTranscriptError.transcriptUnavailable }

        return YouTubeTranscript(
            videoID: videoID,
            title: title,
            sourceURL: sourceURL,
            segments: segments
        )
    }

    func fetchVideoReference(from urlString: String) async throws -> YouTubeVideoReference {
        let videoID = try YouTubeVideoID(urlString: urlString)
        let sourceURL = URL(string: "https://www.youtube.com/watch?v=\(videoID.rawValue)")!
        let watchHTML = try await fetchString(from: sourceURL)
        return try YouTubeVideoReference(
            urlString: urlString,
            title: Self.extractTitle(from: watchHTML),
            duration: Self.extractDuration(from: watchHTML)
        )
    }

    private func fetchSegments(from captionURL: URL) async throws -> [YouTubeTranscriptSegment] {
        let captionText = try await fetchString(from: captionURL)
        return try Self.parseTranscript(captionText)
    }

    private func fetchString(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        return try await fetchString(for: request)
    }

    private func fetchString(for request: URLRequest) async throws -> String {
        let (data, response) = try await httpClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw YouTubeTranscriptError.invalidResponse
        }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw YouTubeTranscriptError.invalidResponse
        }
        return text
    }

    private func bestCaptionURLFromInnertubePlayer(
        videoID: YouTubeVideoID,
        watchHTML: String
    ) async throws -> URL? {
        guard let apiKey = Self.extractQuotedValue("INNERTUBE_API_KEY", from: watchHTML),
              let requestURL = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)") else {
            return nil
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "20.10.38"
                ]
            ],
            "videoId": videoID.rawValue
        ]
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/123.0.0.0 Mobile Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let playerText = try await fetchString(for: request)
        guard let data = playerText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Self.bestCaptionURL(fromPlayerResponse: object)
    }

    private static func extractQuotedValue(_ key: String, from html: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #""\#(escapedKey)"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
              ),
              let valueRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[valueRange])
    }

    static func parseTranscript(_ text: String) throws -> [YouTubeTranscriptSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" {
            return try parseJSON3Transcript(trimmed)
        }
        return parseXMLTranscript(trimmed)
    }

    private static func bestCaptionURL(from html: String) -> URL? {
        guard let playerJSON = extractPlayerResponseJSON(from: html),
              let data = playerJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return bestCaptionURL(fromPlayerResponse: object)
    }

    private static func bestCaptionURL(fromPlayerResponse object: [String: Any]) -> URL? {
        let renderer: [String: Any]?
        if let captions = object["captions"] as? [String: Any] {
            renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any]
        } else {
            renderer = object["playerCaptionsTracklistRenderer"] as? [String: Any]
        }
        guard let tracks = renderer?["captionTracks"] as? [[String: Any]] else {
            return nil
        }
        let selected = tracks.first { ($0["languageCode"] as? String)?.hasPrefix("en") == true }
            ?? tracks.first
        guard let rawBaseURL = selected?["baseUrl"] as? String else { return nil }
        return URL(string: rawBaseURL.replacingOccurrences(of: "\\u0026", with: "&"))
    }

    private static func extractPlayerResponseJSON(from html: String) -> String? {
        guard let markerRange = html.range(of: "ytInitialPlayerResponse") else { return nil }
        guard let start = html[markerRange.upperBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInString = false
        var isEscaped = false
        var cursor = start

        while cursor < html.endIndex {
            let char = html[cursor]
            if isEscaped {
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "\"" {
                isInString.toggle()
            } else if !isInString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(html[start...cursor])
                    }
                }
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func extractTitle(from html: String) -> String? {
        if let playerJSON = extractPlayerResponseJSON(from: html),
           let data = playerJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let videoDetails = object["videoDetails"] as? [String: Any],
           let title = videoDetails["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        guard let range = html.range(
            of: "(?is)<title\\b[^>]*>(.*?)</title>",
            options: .regularExpression
        ) else { return nil }
        let raw = String(html[range])
            .replacingOccurrences(of: "(?is)</?title\\b[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: " - YouTube", with: "")
        let title = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func extractDuration(from html: String) -> TimeInterval? {
        guard let playerJSON = extractPlayerResponseJSON(from: html),
              let data = playerJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let videoDetails = object["videoDetails"] as? [String: Any] else {
            return nil
        }

        if let raw = videoDetails["lengthSeconds"] as? String,
           let duration = TimeInterval(raw),
           duration > 0 {
            return duration
        }

        if let duration = videoDetails["lengthSeconds"] as? TimeInterval,
           duration > 0 {
            return duration
        }

        if let number = videoDetails["lengthSeconds"] as? NSNumber {
            let duration = number.doubleValue
            return duration > 0 ? duration : nil
        }

        return nil
    }

    private static func parseXMLTranscript(_ xml: String) -> [YouTubeTranscriptSegment] {
        let timedTextSegments = parseTimedTextParagraphTranscript(xml)
        if !timedTextSegments.isEmpty {
            return timedTextSegments
        }

        let pattern = #"<text\b([^>]*)>(.*?)</text>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: nsRange).compactMap { match in
            guard let attributesRange = Range(match.range(at: 1), in: xml),
                  let textRange = Range(match.range(at: 2), in: xml),
                  let start = attribute("start", in: String(xml[attributesRange]))
                    .flatMap(TimeInterval.init) else {
                return nil
            }
            let duration = attribute("dur", in: String(xml[attributesRange]))
                .flatMap(TimeInterval.init) ?? 0
            let text = cleanCaptionText(String(xml[textRange]))
            guard !text.isEmpty else { return nil }
            return YouTubeTranscriptSegment(startTime: start, duration: duration, text: text)
        }
    }

    private static func parseTimedTextParagraphTranscript(_ xml: String) -> [YouTubeTranscriptSegment] {
        let pattern = #"<p\b([^>]*)>(.*?)</p>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: nsRange).compactMap { match in
            guard let attributesRange = Range(match.range(at: 1), in: xml),
                  let textRange = Range(match.range(at: 2), in: xml),
                  let startMS = attribute("t", in: String(xml[attributesRange]))
                    .flatMap(TimeInterval.init) else {
                return nil
            }

            let durationMS = attribute("d", in: String(xml[attributesRange]))
                .flatMap(TimeInterval.init) ?? 0
            let text = cleanCaptionText(String(xml[textRange]))
            guard !text.isEmpty else { return nil }
            return YouTubeTranscriptSegment(
                startTime: startMS / 1_000,
                duration: durationMS / 1_000,
                text: text
            )
        }
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = #"\b\#(name)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: attributes,
                range: NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
              ),
              let range = Range(match.range(at: 1), in: attributes) else {
            return nil
        }
        return String(attributes[range])
    }

    private static func parseJSON3Transcript(_ text: String) throws -> [YouTubeTranscriptSegment] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else {
            return []
        }
        return events.compactMap { event in
            guard let startMS = event["tStartMs"] as? Double,
                  let segments = event["segs"] as? [[String: Any]] else {
                return nil
            }
            let durationMS = event["dDurationMs"] as? Double ?? 0
            let text = segments.compactMap { $0["utf8"] as? String }.joined()
            let cleaned = cleanCaptionText(text)
            guard !cleaned.isEmpty else { return nil }
            return YouTubeTranscriptSegment(
                startTime: startMS / 1_000,
                duration: durationMS / 1_000,
                text: cleaned
            )
        }
    }

    private static func cleanCaptionText(_ text: String) -> String {
        decodeEntities(
            text
                .replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
        )
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        let pattern = #"&#(\d+);"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result)
            )
            for match in matches.reversed() {
                guard let wholeRange = Range(match.range(at: 0), in: result),
                      let numberRange = Range(match.range(at: 1), in: result),
                      let scalarValue = UInt32(result[numberRange]),
                      let scalar = UnicodeScalar(scalarValue) else { continue }
                result.replaceSubrange(wholeRange, with: String(Character(scalar)))
            }
        }
        return result
    }
}
